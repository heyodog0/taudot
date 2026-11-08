-- :Taudot comments and :Taudot changes: every thread or tracked change in the project, in Telescope when it is
-- installed (with a preview and actions), else vim.ui.select, else the quickfix list.

local api = vim.api
local config = require('taudot.config')
local ui = require('taudot.ui')
local Buffer = require('taudot.buffer')

local M = {}

local function notify(msg, level)
  vim.notify('Taudot: ' .. msg, level or vim.log.levels.INFO)
end

local function review()
  return require('taudot.review')
end

local function project()
  return require('taudot').project()
end

local function name(u)
  return u and u.name ~= vim.NIL and u.name or '?'
end

local function attached(path)
  for _, b in pairs(Buffer.by_buf) do
    if b.path == path then
      return b
    end
  end
end

-- The buffer of a project path, loaded.
local function load(path)
  local p = project()
  local bufnr = vim.fn.bufadd(p.folder .. '/' .. path)
  vim.fn.bufload(bufnr)
  return bufnr
end

-- Where a range is now: its live extmark in an attached buffer, else mapped from the engine's seq, else as given.
local function place(item, start, stop, seq, match)
  local b = attached(item.path)
  item.bufnr = b and b.buf or load(item.path)
  if b then
    for id, r in pairs(b.comments) do
      if match(r) then
        item.range = r
        local m = api.nvim_buf_get_extmark_by_id(b.buf, ui.ns.comment, id, { details = true })
        if m[1] then
          item.row, item.col = m[1], m[2]
          item.end_row, item.end_col = m[3].end_row or m[1], m[3].end_col or m[2]
          return item
        end
      end
    end
    start, stop = b:map_from(start, seq) or start, b:map_from(stop, seq) or stop
  end
  item.row, item.col = Buffer.pos_to_rc(item.bufnr, start)
  item.end_row, item.end_col = Buffer.pos_to_rc(item.bufnr, stop)
  item.row, item.col = item.row or 0, item.col or 0
  item.end_row, item.end_col = item.end_row or item.row, item.end_col or item.col
  return item
end

-- ---- items --------------------------------------------------------------------------------------------------------

-- Comment items from thread.list. cb(items, supported).
local function comment_items(all, cb)
  review().call('thread.list', {}, function(res)
    local items = {}
    for _, t in ipairs(res.threads) do
      if all or not t.resolved then
        local first = t.messages[1]
        local item = {
          kind = 'comment',
          thread_id = t.thread_id,
          doc_id = t.doc_id,
          path = t.path,
          text = t.text,
          resolved = t.resolved,
          author = first and first.user or t.author,
          ts = first and first.ts or t.ts,
          message = first and first.text or '',
          replies = math.max(0, #t.messages - 1),
          thread = t,
        }
        place(item, t.start, t['end'], t.seq, function(r)
          return r.thread_id == t.thread_id
        end)
        -- Without messages (Overleaf CE) who and when come from the range.
        if item.range then
          item.author = item.author or item.range.author
          item.ts = item.ts or item.range.ts
        end
        items[#items + 1] = item
      end
    end
    table.sort(items, function(a, b)
      if a.path ~= b.path then
        return a.path < b.path
      end
      return a.row < b.row or (a.row == b.row and a.col < b.col)
    end)
    cb(items, res.supported)
  end)
end

local function change_item(r, path, doc_id, seq)
  local item = {
    kind = r.kind,
    id = r.id,
    doc_id = doc_id,
    path = path,
    text = r.text,
    author = r.author,
    ts = r.ts,
  }
  return place(item, r.start, r['end'], seq, function(x)
    return x.id == r.id and x.kind == r.kind
  end)
end

-- Tracked changes in every doc: from attached buffers, else asked of the engine. cb(items).
local function change_items(cb)
  local p = project()
  local items, waiting = {}, 1
  local function done()
    waiting = waiting - 1
    if waiting > 0 then
      return
    end
    table.sort(items, function(a, b)
      if a.path ~= b.path then
        return a.path < b.path
      end
      return a.row < b.row or (a.row == b.row and a.col < b.col)
    end)
    cb(items)
  end
  for path, doc_id in pairs(p.docs or {}) do
    local b = attached(path)
    if b then
      for _, r in ipairs(b.ranges) do
        if r.kind ~= 'comment' then
          items[#items + 1] = change_item(r, path, doc_id, b.seq)
        end
      end
    else
      waiting = waiting + 1
      p.client:request('doc.ranges', { doc_id = doc_id }, function(err, res)
        if not err and res then
          for _, r in ipairs(res.ranges or {}) do
            if r.kind ~= 'comment' then
              items[#items + 1] = change_item(r, path, doc_id, nil)
            end
          end
        end
        done()
      end)
    end
  end
  done()
end

-- One line: "Bob · 3 min ago · “quoted” — first words (+2)".
function M.format(item)
  local quote = review().short(item.text, 30)
  if item.kind == 'comment' then
    local extra = item.replies > 0 and (' (+%d)'):format(item.replies) or ''
    return ('%s%s · %s · “%s” — %s%s'):format(item.resolved and '[resolved] ' or '', name(item.author), ui.ago(item.ts),
      quote, review().short(item.message, 40), extra)
  end
  local verb = item.kind == 'tracked_insert' and 'added' or 'deleted'
  return ('%s %s · %s · “%s”'):format(name(item.author), verb, ui.ago(item.ts), quote)
end

function M.jump(item)
  local b = attached(item.path)
  local bufnr = b and b.buf or item.bufnr
  if not api.nvim_buf_is_valid(bufnr) then
    bufnr = load(item.path)
  end
  local w = vim.fn.bufwinid(bufnr)
  if w ~= -1 then
    api.nvim_set_current_win(w)
  else
    api.nvim_set_current_buf(bufnr)
  end
  pcall(api.nvim_win_set_cursor, 0, { item.row + 1, item.col })
  vim.cmd('normal! zvzz')
end

-- ---- quickfix and vim.ui.select -----------------------------------------------------------------------------------

local function quickfix(title, items)
  local qf = {}
  for _, it in ipairs(items) do
    qf[#qf + 1] = { bufnr = it.bufnr, lnum = it.row + 1, col = it.col + 1, text = M.format(it), user_data = it.thread_id or it.id }
  end
  vim.fn.setqflist({}, ' ', { title = title, items = qf })
  if #qf > 0 then
    vim.cmd.copen()
  end
end

local function select(title, items)
  vim.ui.select(items, {
    prompt = title,
    format_item = function(it)
      return it.path .. ':' .. (it.row + 1) .. '  ' .. M.format(it)
    end,
    kind = 'taudot',
  }, function(it)
    if it then
      M.jump(it)
    end
  end)
end

-- ---- Telescope ----------------------------------------------------------------------------------------------------

local function telescope(title, items, opts)
  local pickers = require('telescope.pickers')
  local finders = require('telescope.finders')
  local conf = require('telescope.config').values
  local actions = require('telescope.actions')
  local action_state = require('telescope.actions.state')
  local previewers = require('telescope.previewers')
  local entry_display = require('telescope.pickers.entry_display')

  local displayer = entry_display.create({
    separator = ' ',
    items = { { width = 1 }, { width = 12 }, { width = 11 }, { width = 28 }, { remaining = true } },
  })
  local function finder(list)
    return finders.new_table({
      results = list,
      entry_maker = function(it)
        local idx = ui.author_index(it.author)
        local rest
        if it.kind == 'comment' then
          rest = review().short(it.message, 60) .. (it.replies > 0 and (' (+%d)'):format(it.replies) or '')
          if it.resolved then
            rest = '✓ ' .. rest
          end
        else
          rest = it.kind == 'tracked_insert' and 'added' or 'deleted'
        end
        return {
          value = it,
          ordinal = table.concat({ name(it.author), it.text, it.message or '', it.path }, ' '),
          display = function()
            return displayer({
              { it.kind == 'comment' and '●' or '▎', 'TaudotCursorLabel' .. idx },
              { name(it.author), 'TaudotCursorLabel' .. idx },
              { ui.ago(it.ts), 'TaudotPanelTime' },
              { '“' .. review().short(it.text, 26) .. '”', 'TaudotPanelQuote' },
              { rest, it.resolved and 'TaudotPanelResolved' or nil },
            })
          end,
          filename = api.nvim_buf_get_name(it.bufnr),
          lnum = it.row + 1,
          col = it.col + 1,
        }
      end,
    })
  end

  local previewer = previewers.new_buffer_previewer({
    title = opts.preview_title,
    define_preview = function(self, entry)
      local it = entry.value
      local pbuf = self.state.bufnr
      local from = math.max(0, it.row - 4)
      local to = it.end_row + 5
      local src = api.nvim_buf_is_valid(it.bufnr) and api.nvim_buf_get_lines(it.bufnr, from, to, false) or {}
      local lines = vim.list_extend({ it.path .. ':' .. (it.row + 1) }, src)
      lines[#lines + 1] = string.rep('─', 40)
      local more
      if it.kind == 'comment' then
        more = ui.review_lines({ { kind = 'comment', thread_id = it.thread_id, text = it.text, author = it.author } },
          { [it.thread_id] = it.thread })
      else
        more = ui.review_lines({ it }, nil)
      end
      -- The float's markdown, as plain text: bold lines are highlighted below.
      local bold = {}
      for i, l in ipairs(more) do
        local stripped = l:gsub('%*%*', ''):gsub('_%((.-)%)_', '(%1)')
        bold[#lines + i - 1] = l:match('^%*%*') ~= nil
        more[i] = stripped
      end
      vim.list_extend(lines, more)
      api.nvim_buf_set_lines(pbuf, 0, -1, false, lines)
      local pns = api.nvim_create_namespace('taudot.preview')
      api.nvim_buf_clear_namespace(pbuf, pns, 0, -1)
      pcall(api.nvim_buf_set_extmark, pbuf, pns, 0, 0, { end_row = 0, end_col = #lines[1], hl_group = 'TaudotPanelTime' })
      -- The range, shifted by the header line and the lines cut above.
      local group = it.kind == 'comment' and 'TaudotComment' or ('TaudotTrackedInsert' .. ui.author_index(it.author))
      if it.kind == 'tracked_delete' then
        group = 'TaudotTrackedDelete' .. ui.author_index(it.author)
      end
      local sr, er = it.row - from + 1, it.end_row - from + 1
      local ec = it.end_col
      if sr == er and it.col == ec then
        ec = math.min(#(lines[sr + 1] or ''), ec + 1)
      end
      pcall(api.nvim_buf_set_extmark, pbuf, pns, sr, it.col, { end_row = er, end_col = ec, hl_group = group })
      pcall(api.nvim_buf_set_extmark, pbuf, pns, #src + 1, 0, { end_row = #src + 1, end_col = 40, hl_group = 'TaudotPanelSeparator' })
      for i = #src + 2, #lines - 1 do
        local l = lines[i + 1]
        if bold[i] then
          pcall(api.nvim_buf_set_extmark, pbuf, pns, i, 0, { end_row = i, end_col = #l, hl_group = 'TaudotPanelTitle' })
        end
      end
    end,
  })

  local picker
  local function reload()
    opts.reload(function(list)
      if picker then
        picker:refresh(finder(list), { reset_prompt = false })
      end
    end)
  end

  picker = pickers.new({}, {
    prompt_title = title,
    finder = finder(items),
    sorter = conf.generic_sorter({}),
    previewer = previewer,
    attach_mappings = function(prompt_bufnr, map)
      local function selected()
        local e = action_state.get_selected_entry()
        return e and e.value
      end
      actions.select_default:replace(function()
        local it = selected()
        actions.close(prompt_bufnr)
        if it then
          M.jump(it)
        end
      end)
      for lhs, f in pairs(opts.keys) do
        map({ 'i', 'n' }, lhs, function()
          local it = selected()
          if it then
            f(it, prompt_bufnr, reload)
          end
        end)
      end
      return true
    end,
  })
  picker:find()
end

local function has_telescope()
  return pcall(require, 'telescope.pickers')
end

local function backend(args)
  for _, a in ipairs(args or {}) do
    if a == 'qf' then
      return 'quickfix'
    end
  end
  local want = config.options.picker
  if want == 'auto' then
    return has_telescope() and 'telescope' or 'select'
  elseif want == 'telescope' and not has_telescope() then
    return 'select'
  end
  return want
end

-- ---- entry points -------------------------------------------------------------------------------------------------

-- :Taudot comments [all] [qf]
function M.comments(args)
  local p = project()
  if not p or not p.client then
    return notify('no project open', vim.log.levels.WARN)
  end
  local all = vim.tbl_contains(args or {}, 'all')
  local how = backend(args)
  comment_items(all, function(items, supported)
    if not supported then
      notify('this server has no comment threads; listing comment ranges only')
    end
    local title = 'taudot comments' .. (all and ' (all)' or '')
    if how == 'quickfix' then
      if #items == 0 then
        return notify(all and 'no comments' or 'no open comments')
      end
      return quickfix(title, items)
    end
    if #items == 0 and how ~= 'telescope' then
      return notify(all and 'no comments' or 'no open comments')
    end
    if how == 'select' then
      return select('Comments', items)
    end
    telescope('Comments' .. (all and ' (with resolved)' or ''), items, {
      preview_title = 'Thread',
      reload = function(cb)
        comment_items(all, cb)
      end,
      keys = {
        ['<C-r>'] = function(it, prompt_bufnr)
          require('telescope.actions').close(prompt_bufnr)
          review().reply_to(it)
        end,
        ['<C-e>'] = function(it, _, reload)
          review().set_resolved(it, it.doc_id, not it.resolved, function()
            vim.defer_fn(reload, 200)
          end)
        end,
        ['<C-d>'] = function(it, _, reload)
          review().delete_thread_of(it, it.doc_id, function()
            vim.defer_fn(reload, 200)
          end)
        end,
        ['<C-a>'] = function(_, prompt_bufnr)
          require('telescope.actions').close(prompt_bufnr)
          M.comments(all and {} or { 'all' })
        end,
      },
    })
  end)
end

-- :Taudot changes [qf]
function M.changes(args)
  local p = project()
  if not p or not p.client then
    return notify('no project open', vim.log.levels.WARN)
  end
  local how = backend(args)
  change_items(function(items)
    if #items == 0 and how ~= 'telescope' then
      return notify('no tracked changes')
    end
    if how == 'quickfix' then
      return quickfix('taudot tracked changes', items)
    elseif how == 'select' then
      return select('Tracked changes', items)
    end
    local function decide(method)
      return function(it, _, reload)
        review().decide(method, it.doc_id, { it.id }, function()
          vim.defer_fn(reload, 200)
        end)
      end
    end
    telescope('Tracked changes', items, {
      preview_title = 'Change',
      reload = change_items,
      keys = { ['<C-y>'] = decide('change.accept'), ['<C-x>'] = decide('change.reject') },
    })
  end)
end

return M
