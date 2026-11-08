-- Review actions: comment, reply, resolve or reopen, delete, accept and reject, track. Everything goes through the
-- engine (docs/api.md, Review); this module only asks and shows. Each action has a form that takes its target (used by
-- the panel and the pickers) and a form that finds it under the cursor (commands and mappings).

local api = vim.api
local ui = require('taudot.ui')
local Buffer = require('taudot.buffer')
local input = require('taudot.input')

local M = {}

local function notify(msg, level)
  vim.notify('Taudot: ' .. msg, level or vim.log.levels.INFO)
end

local function project()
  return require('taudot').project()
end

-- Call the engine; report errors. cb(result) only on success.
local function call(method, params, cb)
  local p = project()
  if not p or not p.client then
    return notify('no project open', vim.log.levels.WARN)
  end
  params.project_id = params.project_id or p.project_id
  p.client:request(method, params, function(err, res)
    if err then
      return notify(method .. ': ' .. tostring(err.message), vim.log.levels.ERROR)
    end
    if cb then
      cb(res)
    end
  end)
end
M.call = call

local function current()
  local b = Buffer.by_buf[api.nvim_get_current_buf()]
  if not b then
    notify('this buffer is not a taudot doc', vim.log.levels.WARN)
  end
  return b
end

local function short(s, n)
  s = (s or ''):gsub('%s+', ' ')
  if vim.fn.strchars(s) > n then
    return vim.fn.strcharpart(s, 0, n - 1) .. '…'
  end
  return s
end
M.short = short

-- The text for an action: given in args, else written in the input float.
local function write(args, title, default, cb)
  local t = table.concat(args or {}, ' ')
  if t ~= '' then
    return cb(t)
  end
  input.open({ title = title, default = default, on_submit = cb })
end

-- ---- redraw -------------------------------------------------------------------------------------------------------

-- Inline text and the panel follow ranges, threads and presence. Many notifications in a row redraw once.
local redraw_queued = false
function M.redraw()
  if redraw_queued then
    return
  end
  redraw_queued = true
  vim.schedule(function()
    redraw_queued = false
    local p = project()
    local panel = require('taudot.panel')
    local inline = require('taudot.config').options.inline and not panel.is_open()
    for _, b in pairs(Buffer.by_buf) do
      ui.draw_inline(b.buf, inline and b.comments or {}, p and p.threads)
    end
    panel.refresh()
  end)
end

-- ---- threads ------------------------------------------------------------------------------------------------------

-- Fill project.threads from the engine. done(res) when the answer is in.
function M.refresh(done)
  local p = project()
  if not p or not p.client then
    return
  end
  p.client:request('thread.list', { project_id = p.project_id }, function(err, res)
    if err or not res then
      return
    end
    p.threads_supported = res.supported
    if res.supported then
      p.threads = p.threads or {}
      for _, t in ipairs(res.threads) do
        p.threads[t.thread_id] = t
      end
    end
    M.redraw()
    if done then
      done(res)
    end
  end)
end

-- thread.changed from the engine.
function M.on_thread_changed(p)
  local proj = project()
  if not proj then
    return
  end
  proj.threads = proj.threads or {}
  proj.threads[p.thread_id] = p.thread ~= vim.NIL and p.thread or nil
  M.redraw()
end

function M.thread(thread_id)
  local p = project()
  return p and p.threads and p.threads[thread_id]
end

local function who(u)
  return u and u.name ~= vim.NIL and u.name or '?'
end

-- The thread's first author, else the range's.
function M.thread_author(r)
  local t = M.thread(r.thread_id)
  local m = t and t.messages and t.messages[1]
  return m and m.user or r.author
end

-- ---- actions on a given target ------------------------------------------------------------------------------------

-- r: a comment range or thread.list entry ({thread_id, text, ...}).
function M.reply_to(r, args, done)
  write(args, 'Reply to ' .. who(M.thread_author(r)), nil, function(text)
    call('thread.reply', { thread_id = r.thread_id, text = text }, done)
  end)
end

function M.set_resolved(r, doc_id, resolved, done)
  call(resolved and 'thread.resolve' or 'thread.reopen', { thread_id = r.thread_id, doc_id = doc_id }, function(res)
    notify(resolved and 'resolved' or 'reopened')
    if done then
      done(res)
    end
  end)
end

function M.toggle_resolved(r, doc_id, done)
  local t = M.thread(r.thread_id)
  local resolved = (t and t.resolved) or r.resolved
  M.set_resolved(r, doc_id, not resolved, done)
end

function M.delete_thread_of(r, doc_id, done)
  local q = ('Delete the thread on “%s” for everyone?'):format(short(r.text, 40))
  if vim.fn.confirm(q, '&Delete\n&Cancel', 2) ~= 1 then
    return
  end
  call('thread.delete', { thread_id = r.thread_id, doc_id = doc_id }, function(res)
    notify('thread deleted')
    if done then
      done(res)
    end
  end)
end

-- method: 'change.accept' or 'change.reject'.
function M.decide(method, doc_id, ids, done)
  call(method, { doc_id = doc_id, ids = ids }, function(res)
    local n = #ids
    notify(('%s %d change%s'):format(method == 'change.accept' and 'accepted' or 'rejected', n, n == 1 and '' or 's'))
    if done then
      done(res)
    end
  end)
end

-- ---- actions on what is under the cursor --------------------------------------------------------------------------

-- The comment ranges under the cursor; pick one if there are several.
local function pick_comment(cb)
  local b = current()
  if not b then
    return
  end
  local found = vim.tbl_filter(function(r)
    return r.kind == 'comment'
  end, b:ranges_here())
  if #found == 0 then
    return notify('no comment under the cursor')
  elseif #found == 1 then
    return cb(found[1], b)
  end
  vim.ui.select(found, {
    prompt = 'Thread',
    format_item = function(r)
      return '“' .. r.text .. '”'
    end,
  }, function(r)
    if r then
      cb(r, b)
    end
  end)
end

-- :'<,'>Taudot comment [text]: comment on the selection (the last visual selection; whole lines in linewise mode).
function M.comment(args, line1, line2)
  local b = current()
  if not b then
    return
  end
  local buf = b.buf
  local s, e = vim.fn.getpos("'<"), vim.fn.getpos("'>")
  local mode = vim.fn.visualmode()
  local sr, sc, er, ec
  if line1 and s[2] ~= line1 then
    -- A plain range (:3,5Taudot comment): whole lines.
    sr, sc, er, ec = line1 - 1, 0, line2 - 1, #(api.nvim_buf_get_lines(buf, line2 - 1, line2, false)[1] or '')
  elseif mode == 'V' then
    sr, sc, er = s[2] - 1, 0, e[2] - 1
    ec = #(api.nvim_buf_get_lines(buf, er, er + 1, false)[1] or '')
  else
    sr, sc, er, ec = s[2] - 1, s[3] - 1, e[2] - 1, e[3] - 1
    local line = api.nvim_buf_get_lines(buf, er, er + 1, false)[1] or ''
    -- '> is the first byte of the last character: include all of it.
    local ch = line:sub(ec + 1):match('^[%z\1-\127\194-\244][\128-\191]*') or ''
    ec = math.min(#line, ec + math.max(1, #ch))
  end
  local start = api.nvim_buf_get_offset(buf, sr) + sc
  local stop = api.nvim_buf_get_offset(buf, er) + ec
  if stop <= start then
    return notify('select some text to comment on', vim.log.levels.WARN)
  end
  local quoted = table.concat(api.nvim_buf_get_text(buf, sr, sc, er, ec, {}), '\n')
  write(args, ('Comment on “%s”'):format(short(quoted, 30)), nil, function(text)
    if b.inflight or b.pending then
      -- Positions must be measured on a text the engine knows. Wait for our edits to be acknowledged.
      return notify('edits still being sent; try again in a moment', vim.log.levels.WARN)
    end
    -- The buffer may have changed while the comment was written: comment on the same text if it is still there.
    if api.nvim_buf_get_offset(buf, sr) + sc ~= start
      or table.concat(api.nvim_buf_get_text(buf, sr, sc, er, ec, {}), '\n') ~= quoted then
      return notify('the text changed while you wrote; select it again', vim.log.levels.WARN)
    end
    call('comment.add', { doc_id = b.doc_id, start = start, ['end'] = stop, seq = b.seq, text = text }, function()
      notify('comment added')
    end)
  end)
end

-- Normal mode <prefix>c: comment on the word under the cursor.
function M.comment_word()
  if not current() then
    return
  end
  vim.cmd('normal! viw\27')
  M.comment({})
end

function M.reply(args)
  pick_comment(function(r)
    M.reply_to(r, args)
  end)
end

M.resolve = function()
  pick_comment(function(r, b)
    M.set_resolved(r, b.doc_id, true)
  end)
end
M.reopen = function()
  pick_comment(function(r, b)
    M.set_resolved(r, b.doc_id, false)
  end)
end
function M.toggle()
  pick_comment(function(r, b)
    M.toggle_resolved(r, b.doc_id)
  end)
end

function M.delete_thread()
  pick_comment(function(r, b)
    M.delete_thread_of(r, b.doc_id)
  end)
end

-- Your own messages in the thread under the cursor; pick one.
local function pick_own_message(cb)
  pick_comment(function(r)
    local p = project()
    local t = p.threads and p.threads[r.thread_id]
    local own = vim.tbl_filter(function(m)
      return m.user and m.user.user_id == p.me
    end, t and t.messages or {})
    if #own == 0 then
      return notify('none of the messages here are yours')
    elseif #own == 1 then
      return cb(r, own[1])
    end
    vim.ui.select(own, {
      prompt = 'Message',
      format_item = function(m)
        return m.text:gsub('\n', ' ')
      end,
    }, function(m)
      if m then
        cb(r, m)
      end
    end)
  end)
end

function M.edit_message(args)
  pick_own_message(function(r, m)
    write(args, 'Edit your message', m.text, function(text)
      call('message.edit', { thread_id = r.thread_id, message_id = m.id, text = text })
    end)
  end)
end

function M.delete_message()
  pick_own_message(function(r, m)
    call('message.delete', { thread_id = r.thread_id, message_id = m.id })
  end)
end

-- :Taudot accept / reject: the tracked changes under the cursor, or in the range of lines.
local function change_action(method)
  return function(_, line1, line2, has_range)
    local b = current()
    if not b then
      return
    end
    local found = has_range and b:ranges_here(line1, line2) or b:ranges_here()
    local ids = {}
    for _, r in ipairs(found) do
      if r.kind ~= 'comment' then
        ids[#ids + 1] = r.id
      end
    end
    if #ids == 0 then
      return notify('no tracked change here')
    end
    M.decide(method, b.doc_id, ids)
  end
end
M.accept = change_action('change.accept')
M.reject = change_action('change.reject')

-- :Taudot track [on|off]: make your edits tracked changes. Without an argument, toggle.
function M.track(args)
  local p = project()
  if not p then
    return notify('no project open')
  end
  local want
  if args and args[1] == 'on' then
    want = true
  elseif args and args[1] == 'off' then
    want = false
  else
    want = not p.track_changes
  end
  call('review.track', { on = want }, function(res)
    p.track_changes = res.on
    p:changed()
    notify(res.on and 'your edits are now tracked changes' or 'your edits are no longer tracked')
  end)
end

-- :Taudot inline [on|off]: the end-of-line comment text.
function M.inline(args)
  local o = require('taudot.config').options
  if args and args[1] == 'on' then
    o.inline = true
  elseif args and args[1] == 'off' then
    o.inline = false
  else
    o.inline = not o.inline
  end
  M.redraw()
end

return M
