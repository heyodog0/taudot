-- taudot: Neovim client of the taudot engine (docs/api.md). Holds no state of its own beyond what it draws.

-- TEXSYNC_* environment variables (names before the rename, 2026-11-04) still work, for one release.
for k, v in pairs(vim.fn.environ()) do
  local rest = k:match('^TEXSYNC_(.+)$')
  if rest and vim.env['TAUDOT_' .. rest] == nil then
    vim.env['TAUDOT_' .. rest] = v
  end
end

local api = vim.api
local config = require('taudot.config')
local rpc = require('taudot.rpc')
local ui = require('taudot.ui')
local Buffer = require('taudot.buffer')
local review = require('taudot.review')

local M = {}

-- The one open project. Fields: client, project_id, folder, docs (path -> doc_id), connection, users, me.
local project = nil
local did_setup = false

local function notify(msg, level)
  vim.notify('Taudot: ' .. msg, level or vim.log.levels.INFO)
end

function M.setup(opts)
  config.set(opts)
  did_setup = true
  ui.define_highlights()
  local group = api.nvim_create_augroup('taudot', { clear = true })
  api.nvim_create_autocmd('ColorScheme', { group = group, callback = ui.define_highlights })
  api.nvim_create_autocmd('BufReadPost', {
    group = group,
    callback = function(ev)
      if project then
        M.attach(ev.buf)
      end
    end,
  })
  require('taudot.keys').global_maps()
end

local function ensure_setup()
  if not did_setup then
    M.setup()
  end
end

-- ---- project ------------------------------------------------------------------------------------------------------

local Project = {}
Project.__index = Project

-- Redraw the statusline after a state change.
function Project:changed()
  vim.cmd.redrawstatus({ bang = true })
end

local function on_notify(method, p)
  if not project then
    return
  end
  if method == 'doc.changed' then
    for _, b in pairs(Buffer.by_buf) do
      if b.doc_id == p.doc_id then
        -- Cursors and ranges are extmarks: they move with the text on their own.
        b:on_changed(p)
      end
    end
    -- Line numbers in the panel move with the text.
    require('taudot.panel').refresh_later()
  elseif method == 'ranges.changed' then
    for _, b in pairs(Buffer.by_buf) do
      if b.doc_id == p.doc_id then
        b:set_ranges(p.ranges, p.seq)
      end
    end
  elseif method == 'thread.changed' then
    review.on_thread_changed(p)
  elseif method == 'review.track' then
    project.track_changes = p.on
    project:changed()
  elseif method == 'presence.changed' then
    project.users = p.users or {}
    for _, b in pairs(Buffer.by_buf) do
      b:draw_cursors(project.users)
    end
    project:changed()
    review.redraw()
  elseif method == 'doc.state' then
    for _, b in pairs(Buffer.by_buf) do
      if b.doc_id == p.doc_id then
        b:on_state(p)
      end
    end
    project:changed()
  elseif method == 'engine.lagged' then
    Buffer.resync_all()
  elseif method == 'project.tree' then
    for _, b in pairs(Buffer.by_buf) do
      b:on_tree(p.change or {})
    end
  elseif method == 'project.connection' then
    project.connection = p.connection
    project:changed()
  end
end

local connect

-- Each connect has a generation, and its callbacks act only while the project is still the one it was for and no
-- later connect (or close) has replaced it: a slow connect from before a :Taudot close / reopen / reconnect, or the
-- late close of a client already replaced, must not touch the project that is there now.
local function current(p, gen)
  return project == p and p.gen == gen and not p.closing
end

local function retry_later(p, gen)
  if not config.options.reconnect or not current(p, gen) then
    return
  end
  p.retry = math.min((p.retry or 500) * 2, 8000)
  vim.defer_fn(function()
    if current(p, gen) and not p.client then
      connect(function() end)
    end
  end, p.retry)
end

-- Connect (or reconnect) and open the project, then (re)subscribe every attached buffer.
connect = function(done)
  local p = project
  p.gen = (p.gen or 0) + 1
  local gen = p.gen
  p.connection = 'connecting'
  local mine
  local function on_close(err)
    -- only the live client's close counts
    if not current(p, gen) or p.client ~= mine then
      return
    end
    p.client = nil
    p.connection = 'offline'
    -- who was here is unknown until the reconnect asks again (E17)
    p.users = {}
    for _, b in pairs(Buffer.by_buf) do
      b:draw_cursors({})
    end
    p:changed()
    notify('lost the engine' .. (err and (': ' .. tostring(err)) or ''), vim.log.levels.WARN)
    retry_later(p, gen)
  end
  rpc.connect(config.socket(), { on_notify = on_notify, on_close = on_close }, function(err, client)
    if not current(p, gen) then
      if client then
        client:close()
      end
      return done('superseded')
    end
    if err then
      p.connection = 'offline'
      p:changed()
      -- after a lost connection, keep trying until the engine is back
      if p.retry then
        retry_later(p, gen)
      end
      return done('cannot reach the engine at ' .. config.socket() .. ': ' .. err)
    end
    mine = client
    p.client = client
    local function fail(msg)
      -- this attempt is over: drop its client, and try again if the project was connected before
      if p.client == client then
        p.client = nil
        p.connection = 'offline'
        client:close()
        p:changed()
        if p.retry then
          retry_later(p, gen)
        end
      end
      done(msg)
    end
    client:request('engine.info', nil, function(e1, info)
      if not current(p, gen) then
        return done('superseded')
      end
      if e1 then
        return fail('engine.info failed: ' .. vim.inspect(e1))
      end
      p.engine = info
      local tries = 0
      local open_project
      open_project = function()
      client:request('project.open', { folder = p.folder }, function(e2, res)
        if not current(p, gen) or p.client ~= client then
          return done('superseded')
        end
        if e2 then
          -- The engine may be logging in, or the server may rate-limit it for a moment: try again a few times.
          tries = tries + 1
          if tries <= 5 then
            notify(('project.open failed (%s), retrying'):format(tostring(e2.message)), vim.log.levels.WARN)
            return vim.defer_fn(open_project, 500 * 2 ^ (tries - 1))
          end
          return fail('project.open failed: ' .. tostring(e2.message))
        end
        p.retry = nil
        p.me = res.me and res.me.user_id or p.me
        p.project_id = res.project_id
        p.folder = res.folder or p.folder
        p.docs = {}
        for _, d in ipairs(res.docs or {}) do
          p.docs[d.path] = d.doc_id
        end
        -- Presence and thread notifications come with the project subscription.
        client:request('activity.subscribe', { project_id = res.project_id })
        review.refresh()
        p.connection = 'online'
        client:request('project.status', { project_id = res.project_id }, function(_, st)
          if st and current(p, gen) then
            p.connection = st.connection or 'online'
            p.users = st.users or {}
            p.track_changes = st.track_changes
            for _, b in pairs(Buffer.by_buf) do
              b:draw_cursors(p.users)
            end
            p:changed()
          end
        end)
        -- Buffers attached before a reconnect: the engine may be a new one (its seqs start over) or have reopened
        -- the doc, so each re-opens its doc and puts what it kept on top of the engine's text (Buffer:rebase).
        if p.instance and info.instance and p.instance ~= info.instance then
          notify('the engine restarted; merging your unsent edits', vim.log.levels.INFO)
        end
        p.instance = info.instance
        for _, b in pairs(Buffer.by_buf) do
          b.doc_id = p.docs[b.path] or b.doc_id
          b.rebasing = false
          b:rebase()
        end
        p:changed()
        done(nil)
      end)
      end
      open_project()
    end)
  end)
end

-- :Taudot open [folder]
function M.open(folder, cb)
  ensure_setup()
  cb = cb or function(err)
    if err then
      notify(err, vim.log.levels.ERROR)
    end
  end
  folder = vim.fs.normalize(vim.fn.fnamemodify(folder ~= nil and folder ~= '' and folder or vim.fn.getcwd(), ':p'))
  folder = folder:gsub('/$', '')
  if project then
    if project.folder == folder then
      return cb(nil)
    end
    M.close()
  end
  local p = setmetatable({ folder = folder, users = {}, me = 'u-me', connection = 'connecting' }, Project)
  project = p
  connect(function(err)
    if err then
      if project == p then
        project = nil
      end
      return cb(err)
    end
    for _, buf in ipairs(api.nvim_list_bufs()) do
      if api.nvim_buf_is_loaded(buf) then
        M.attach(buf)
      end
    end
    notify(('opened %s (%d docs)'):format(project.folder, vim.tbl_count(project.docs)))
    cb(nil)
  end)
end

-- Attach a buffer if its file is one of the project's docs.
function M.attach(buf, cb)
  cb = cb or function() end
  if not project or not project.client or Buffer.by_buf[buf] then
    return cb('not attachable')
  end
  local name = api.nvim_buf_get_name(buf)
  if name == '' or vim.bo[buf].buftype ~= '' then
    return cb('not a file')
  end
  local real = vim.uv.fs_realpath(name) or name
  local root = vim.uv.fs_realpath(project.folder) or project.folder
  if real:sub(1, #root + 1) ~= root .. '/' then
    return cb('outside the project')
  end
  local path = real:sub(#root + 2)
  if not project.docs[path] then
    return cb('not a doc')
  end
  local client = project.client
  client:request('doc.open', { project_id = project.project_id, path = path }, function(err, res)
    if err then
      notify('doc.open ' .. path .. ': ' .. tostring(err.message), vim.log.levels.ERROR)
      return cb(err)
    end
    if Buffer.by_buf[buf] or not api.nvim_buf_is_valid(buf) then
      return cb('raced')
    end
    local b = Buffer.new(project, buf, { doc_id = res.doc_id, path = path, seq = res.seq })
    b:start(res.text)
    require('taudot.comforts').attach(buf, b)
    client:request('doc.subscribe', { doc_id = res.doc_id, since_seq = res.seq })
    client:request('doc.ranges', { doc_id = res.doc_id }, function(_, r)
      if r and not b.detached then
        b:set_ranges(r.ranges, r.seq)
      end
    end)
    b:draw_cursors(project.users or {})
    if config.options.prose then
      M.prose(buf)
    end
    project:changed()
    cb(nil, b)
  end)
end

function M.close()
  if not project then
    return
  end
  project.closing = true
  for _, b in pairs(Buffer.by_buf) do
    b:detach()
  end
  if project.client then
    project.client:close()
  end
  project = nil
  vim.cmd.redrawstatus({ bang = true })
end

function M.reconnect()
  if not project then
    return notify('no project open', vim.log.levels.WARN)
  end
  if project.client then
    local c = project.client
    project.client = nil
    c:close()
  end
  connect(function(err)
    notify(err or 'reconnected', err and vim.log.levels.ERROR or nil)
  end)
end

-- ---- info ---------------------------------------------------------------------------------------------------------

function M.project()
  return project
end

function M.buffers()
  return Buffer.by_buf
end

local function others()
  local out = {}
  for _, u in ipairs(project and project.users or {}) do
    if u.user_id ~= project.me then
      out[#out + 1] = u
    end
  end
  return out
end

-- For 'statusline': connection, unconfirmed edits, who else is here. Empty when no project is open.
function M.statusline()
  if not project then
    return ''
  end
  local unconfirmed = 0
  for _, b in pairs(Buffer.by_buf) do
    unconfirmed = unconfirmed + b:unconfirmed()
  end
  local conn = project.connection or 'offline'
  local err
  for _, b in pairs(Buffer.by_buf) do
    err = err or b.error
  end
  if err then
    return ('%%#TaudotStatusOffline#⚠ not synced%%* %s'):format(err:gsub('%%', '%%%%'):sub(1, 60))
  end
  local icon, group
  if conn == 'online' and unconfirmed == 0 then
    icon, group = '●', 'TaudotStatusOnline'
  elseif conn == 'online' or conn == 'connecting' then
    icon, group = '◐', 'TaudotStatusBusy'
  else
    icon, group = '○', 'TaudotStatusOffline'
  end
  local parts = { ('%%#%s#%s%%*'):format(group, icon) }
  if unconfirmed > 0 then
    parts[#parts + 1] = unconfirmed .. '↑'
  end
  if conn ~= 'online' then
    parts[#parts + 1] = conn
  end
  if project.track_changes then
    parts[#parts + 1] = '%#TaudotTrackChanges#TC%*'
  end
  local names = {}
  for _, u in ipairs(others()) do
    names[#names + 1] = ('%%#TaudotCursorLabel%d#%s%%*'):format(ui.author_index(u), u.initials)
  end
  if #names > 0 then
    parts[#parts + 1] = table.concat(names, ' ')
  end
  return table.concat(parts, ' ')
end

function M.status()
  if not project then
    return notify('no project open')
  end
  local lines = {
    ('project %s  %s'):format(project.project_id or '?', project.folder),
    ('engine  %s, api level %s, %s'):format(
      project.engine and project.engine.version or '?',
      project.engine and project.engine.api_level or '?',
      project.connection
    ),
  }
  for _, b in pairs(Buffer.by_buf) do
    lines[#lines + 1] = ('  %-30s seq %-5d %s, %d unconfirmed'):format(b.path, b.seq, b.state, b:unconfirmed())
  end
  local who = {}
  for _, u in ipairs(others()) do
    who[#who + 1] = ('%s (%s)'):format(u.name, u.initials)
  end
  lines[#lines + 1] = 'online  ' .. (#who > 0 and table.concat(who, ', ') or 'just you')
  lines[#lines + 1] = 'review  ' .. (project.track_changes and 'your edits are tracked' or 'your edits are not tracked')
    .. (project.threads_supported == false and ', no comment threads on this server' or '')
  vim.api.nvim_echo({ { table.concat(lines, '\n') } }, false, {})
end

-- :Taudot comments [all] [qf]: every thread in a picker (resolved ones with `all`, quickfix with `qf`).
function M.comments(args)
  require('taudot.picker').comments(args)
end

-- :Taudot changes [qf]: every tracked change in a picker.
function M.changes(args)
  require('taudot.picker').changes(args)
end

-- K without the mapping: threads and tracked changes under the cursor.
function M.thread()
  local b = Buffer.by_buf[api.nvim_get_current_buf()]
  if not b or not b:show_thread() then
    notify('no comment or tracked change here')
  end
end

-- ---- :Taudot -----------------------------------------------------------------------------------------------------

-- Each gets (args, line1, line2, has_range).
-- Prose settings for windows showing a synced buffer (config.prose), now and whenever the buffer is shown again.
function M.prose(buf)
  local function apply(win)
    for opt, val in pairs({ wrap = true, linebreak = true, breakindent = true, smoothscroll = true }) do
      api.nvim_set_option_value(opt, val, { scope = 'local', win = win })
    end
  end
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    apply(win)
  end
  if not vim.o.display:find('lastline') and not vim.o.display:find('truncate') then
    vim.opt.display:append('lastline')
  end
  api.nvim_create_autocmd('BufWinEnter', {
    group = api.nvim_create_augroup('taudot_prose_' .. buf, { clear = true }),
    buffer = buf,
    callback = function()
      apply(api.nvim_get_current_win())
    end,
  })
end

M.subcommands = {
  open = function(args)
    M.open(args[1])
  end,
  status = M.status,
  comments = M.comments,
  changes = M.changes,
  panel = function()
    require('taudot.panel').toggle()
  end,
  inline = review.inline,
  thread = M.thread,
  comment = review.comment,
  reply = review.reply,
  resolve = review.resolve,
  reopen = review.reopen,
  toggle = review.toggle,
  ['delete-thread'] = review.delete_thread,
  ['edit-message'] = review.edit_message,
  ['delete-message'] = review.delete_message,
  accept = review.accept,
  reject = review.reject,
  track = review.track,
  reconnect = M.reconnect,
  close = M.close,
}

function M.command(opts)
  ensure_setup()
  local sub = opts.fargs[1] or 'status'
  local f = M.subcommands[sub]
  if not f then
    return notify('unknown subcommand ' .. sub, vim.log.levels.ERROR)
  end
  f(vim.list_slice(opts.fargs, 2), opts.line1, opts.line2, (opts.range or 0) > 0)
end

function M.complete(arglead, cmdline)
  local words = vim.split(cmdline, '%s+', { trimempty = true })
  -- A range before the command name (:'<,'>Taudot) is part of the first word.
  local n = #words + (cmdline:match('%s$') and 1 or 0)
  local function filter(list)
    return vim.tbl_filter(function(s)
      return s:find(arglead, 1, true) == 1
    end, list)
  end
  if n <= 2 then
    local subs = vim.tbl_keys(M.subcommands)
    table.sort(subs)
    return filter(subs)
  end
  if words[2] == 'open' then
    return vim.fn.getcompletion(arglead, 'dir')
  elseif words[2] == 'track' then
    return filter({ 'on', 'off' })
  elseif words[2] == 'comments' then
    return filter({ 'all', 'qf' })
  elseif words[2] == 'changes' then
    return filter({ 'qf' })
  elseif words[2] == 'inline' then
    return filter({ 'on', 'off' })
  end
  return {}
end

return M
