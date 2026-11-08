-- The review panel: a narrow split on the right with the current doc's comments and tracked changes as cards, in
-- text order, like Overleaf's Review panel. It follows the editor's cursor, and moving in it moves the editor.

local api = vim.api
local config = require('taudot.config')
local ui = require('taudot.ui')
local Buffer = require('taudot.buffer')

local M = {}

local ns = api.nvim_create_namespace('taudot.panel')
local ns_current = api.nvim_create_namespace('taudot.panel.current')

-- buf, win: the panel. source: the Buffer shown. cards: { first, last (0-based lines), item, key }.
local state = { cards = {}, show_resolved = false }
M.state = state

local function review()
  return require('taudot.review')
end

function M.is_open()
  return state.win ~= nil and api.nvim_win_is_valid(state.win)
end

local function name(u)
  return u and u.name ~= vim.NIL and u.name or '?'
end

local function key_of(r)
  return r.kind .. ':' .. tostring(r.thread_id or r.id)
end

-- Words of s in lines at most width cells wide.
local function wrap(s, width)
  local out = {}
  for _, para in ipairs(vim.split(s or '', '\n', { plain = true })) do
    local line = ''
    for word in para:gmatch('%S+') do
      while vim.fn.strdisplaywidth(word) > width do
        if line ~= '' then
          out[#out + 1] = line
          line = ''
        end
        out[#out + 1] = vim.fn.strcharpart(word, 0, width)
        word = vim.fn.strcharpart(word, width)
      end
      if line == '' then
        line = word
      elseif vim.fn.strdisplaywidth(line .. ' ' .. word) <= width then
        line = line .. ' ' .. word
      else
        out[#out + 1] = line
        line = word
      end
    end
    out[#out + 1] = line
  end
  return out
end

-- The window that shows the source buffer: the previous window if it does, else any.
local function source_win()
  local b = state.source
  if not b then
    return nil
  end
  local prev = vim.fn.win_getid(vim.fn.winnr('#'))
  if prev ~= 0 and api.nvim_win_is_valid(prev) and api.nvim_win_get_buf(prev) == b.buf then
    return prev
  end
  local w = vim.fn.bufwinid(b.buf)
  return w ~= -1 and w or nil
end

-- ---- drawing ------------------------------------------------------------------------------------------------------

local function build(b, width)
  local lines, hls, cards = {}, {}, {}
  local function add(text, group, from, to)
    lines[#lines + 1] = text
    if group then
      hls[#hls + 1] = { #lines - 1, from or 0, to or -1, group }
    end
    return #lines - 1
  end
  local function hl(line, from, to, group)
    hls[#hls + 1] = { line, from, to, group }
  end
  local p = require('taudot').project()
  local inner = math.max(10, width - 4)

  if not b then
    add(' Review', 'TaudotPanelTitle')
    add('')
    for _, l in ipairs(wrap('Open a file of the project to see its comments and tracked changes.', inner)) do
      add('  ' .. l, 'TaudotPanelHint')
    end
    return lines, hls, cards
  end

  local items = b:review_items(state.show_resolved)
  local n_comments, n_changes, n_resolved = 0, 0, 0
  for _, it in ipairs(items) do
    if it.r.kind == 'comment' then
      n_comments = n_comments + 1
    else
      n_changes = n_changes + 1
    end
  end
  for _, r in ipairs(b.ranges) do
    if r.kind == 'comment' and r.resolved then
      n_resolved = n_resolved + 1
    end
  end

  add(' Review · ' .. b.path, 'TaudotPanelTitle')
  local counts = ('%d comment%s · %d change%s'):format(n_comments, n_comments == 1 and '' or 's', n_changes,
    n_changes == 1 and '' or 's')
  if n_resolved > 0 and not state.show_resolved then
    counts = counts .. (' · %d resolved (H)'):format(n_resolved)
  end
  add(' ' .. counts, 'TaudotPanelHint')
  -- Who else is here, in their colours.
  local here = {}
  for _, u in ipairs(p and p.users or {}) do
    if u.user_id ~= p.me and not here[u.user_id] then
      here[u.user_id] = true
      here[#here + 1] = u
    end
  end
  if #here > 0 then
    local text, spans = ' ', {}
    for i, u in ipairs(here) do
      local s = '● ' .. name(u)
      spans[#spans + 1] = { #text, #text + #'●', 'TaudotCursorLabel' .. ui.author_index(u) }
      text = text .. s .. (i < #here and '  ' or '')
    end
    local l = add(text)
    for _, s in ipairs(spans) do
      hl(l, s[1], s[2], s[3])
    end
  end
  add(string.rep('─', width), 'TaudotPanelSeparator')

  if #items == 0 then
    add('')
    add('  No comments or tracked changes here.', 'TaudotPanelHint')
  end

  for _, it in ipairs(items) do
    local r = it.r
    local first = #lines
    local where = (' · l. %d'):format(it.row + 1)
    if r.kind == 'comment' then
      local t = p and p.threads and p.threads[r.thread_id]
      local msgs = t and t.messages or {}
      local author = review().thread_author(r)
      local idx = ui.author_index(author)
      local ts = msgs[1] and msgs[1].ts or r.ts
      local head = ('● %s · %s%s'):format(name(author), ui.ago(ts), where)
      local l = add(head)
      hl(l, 0, #'●', 'TaudotCursorLabel' .. idx)
      hl(l, #'● ', #'● ' + #name(author), 'TaudotCursorLabel' .. idx)
      hl(l, #'● ' + #name(author), -1, 'TaudotPanelTime')
      for _, q in ipairs(wrap('“' .. r.text .. '”', inner)) do
        add('  ' .. q, r.resolved and 'TaudotPanelResolved' or 'TaudotPanelQuote')
      end
      for i, m in ipairs(msgs) do
        local indent = '  '
        if i > 1 then
          local who = name(m.user)
          local ml = add('  ↳ ' .. who .. ' · ' .. ui.ago(m.ts))
          local from = #'  ↳ '
          hl(ml, from, from + #who, 'TaudotCursorLabel' .. ui.author_index(m.user))
          hl(ml, from + #who, -1, 'TaudotPanelTime')
          indent = '    '
        end
        for _, w in ipairs(wrap(m.text, inner - #indent + 2)) do
          add(indent .. w, r.resolved and 'TaudotPanelResolved' or 'TaudotPanelText')
        end
      end
      if #msgs == 0 and p and p.threads_supported == false then
        add('  (this server keeps no messages)', 'TaudotPanelHint')
      end
      if r.resolved or (t and t.resolved) then
        local by = t and t.resolved_by ~= vim.NIL and t.resolved_by and (' by ' .. name(t.resolved_by)) or ''
        add('  ✓ resolved' .. by, 'TaudotPanelResolved')
      end
    else
      local idx = ui.author_index(r.author)
      local verb = r.kind == 'tracked_insert' and 'added' or 'deleted'
      local head = ('▎ %s %s · %s%s'):format(name(r.author), verb, ui.ago(r.ts), where)
      local l = add(head)
      hl(l, 0, #'▎', 'TaudotCursorLabel' .. idx)
      hl(l, #'▎ ', #'▎ ' + #name(r.author), 'TaudotCursorLabel' .. idx)
      hl(l, #'▎ ' + #name(r.author), -1, 'TaudotPanelTime')
      local sign = r.kind == 'tracked_insert' and '+ ' or '− '
      for i, q in ipairs(wrap(r.text, inner - 2)) do
        local ql = add('  ' .. (i == 1 and sign or '  ') .. q)
        hl(ql, 2 + #(i == 1 and sign or '  '), -1, r.kind == 'tracked_insert' and 'TaudotPanelInsert' or 'TaudotPanelDelete')
      end
    end
    cards[#cards + 1] = { first = first, last = #lines - 1, item = it, key = key_of(r) }
    add(string.rep('─', width), 'TaudotPanelSeparator')
  end

  add('')
  for _, l in ipairs(wrap('<CR> go · r reply · R resolve/reopen · a accept · x reject · d delete · H resolved · q close', inner)) do
    add('  ' .. l, 'TaudotPanelHint')
  end
  return lines, hls, cards
end

local function card_at_line(line)
  for i, c in ipairs(state.cards) do
    if line >= c.first and line <= c.last then
      return c, i
    end
  end
end

local function mark_current(i)
  api.nvim_buf_clear_namespace(state.buf, ns_current, 0, -1)
  state.current = i and state.cards[i] and state.cards[i].key or nil
  local c = i and state.cards[i]
  if c then
    api.nvim_buf_set_extmark(state.buf, ns_current, c.first, 0, {
      end_row = c.last + 1,
      hl_group = 'TaudotPanelCurrent',
      hl_eol = true,
      priority = 50,
    })
  end
end

local function render()
  if not M.is_open() then
    return
  end
  local b = state.source
  if b and (b.detached or not api.nvim_buf_is_valid(b.buf)) then
    b, state.source = nil, nil
  end
  local width = api.nvim_win_get_width(state.win)
  local lines, hls, cards = build(b, width)
  local buf = state.buf
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, h in ipairs(hls) do
    local line = lines[h[1] + 1] or ''
    local to = h[3] == -1 and #line or math.min(h[3], #line)
    if to > h[2] then
      api.nvim_buf_set_extmark(buf, ns, h[1], h[2], { end_row = h[1], end_col = to, hl_group = h[4] })
    end
  end
  state.cards = cards
  -- Keep the highlighted card, and the panel's cursor on the same card when the panel has focus.
  local cur_i
  for i, c in ipairs(cards) do
    if c.key == state.current then
      cur_i = i
    end
  end
  mark_current(cur_i)
  if api.nvim_get_current_win() == state.win and state.cursor_key then
    for _, c in ipairs(cards) do
      if c.key == state.cursor_key then
        state.syncing = true
        pcall(api.nvim_win_set_cursor, state.win, { c.first + 1, 0 })
        state.syncing = false
      end
    end
  end
end

function M.refresh()
  if M.is_open() then
    render()
  end
end

local timer
function M.refresh_later()
  if not M.is_open() then
    return
  end
  timer = timer or vim.uv.new_timer()
  timer:stop()
  timer:start(150, 0, vim.schedule_wrap(M.refresh))
end

-- ---- following ----------------------------------------------------------------------------------------------------

-- The editor's cursor moved in b: highlight the card under it, and bring the nearest card into view.
function M.follow(b)
  if not M.is_open() or state.syncing then
    return
  end
  if state.source ~= b then
    state.source = b
    render()
  end
  local cur = api.nvim_win_get_cursor(0)
  local row = cur[1] - 1
  local here = {}
  for _, r in ipairs(b:ranges_here()) do
    here[key_of(r)] = true
  end
  local hit, near
  for i, c in ipairs(state.cards) do
    if here[c.key] and not hit then
      hit = i
    end
    if not near and c.item.end_row >= row then
      near = i
    end
  end
  mark_current(hit)
  local target = state.cards[hit or near or #state.cards]
  if target then
    pcall(api.nvim_win_set_cursor, state.win, { target.first + 1, 0 })
  end
end

-- The panel's cursor moved: move the editor to the card's text.
local function on_panel_moved()
  if state.syncing then
    return
  end
  local c, i = card_at_line(api.nvim_win_get_cursor(state.win)[1] - 1)
  if not c then
    return
  end
  state.cursor_key = c.key
  mark_current(i)
  local w = source_win()
  if w then
    pcall(api.nvim_win_set_cursor, w, { c.item.row + 1, c.item.col })
    api.nvim_win_call(w, function()
      vim.cmd('normal! zv')
    end)
  end
end

-- ---- actions ------------------------------------------------------------------------------------------------------

local function card_here()
  if api.nvim_get_current_win() ~= state.win then
    return nil
  end
  local c = card_at_line(api.nvim_win_get_cursor(state.win)[1] - 1)
  if not c then
    vim.notify('Taudot: no card here', vim.log.levels.INFO)
  end
  return c
end

local function on_comment(f)
  return function()
    local c = card_here()
    if not c then
      return
    end
    if c.item.r.kind ~= 'comment' then
      return vim.notify('Taudot: this is a tracked change, not a comment')
    end
    f(c.item.r, state.source)
  end
end

local function on_change(method)
  return function()
    local c = card_here()
    if not c then
      return
    end
    if c.item.r.kind == 'comment' then
      return vim.notify('Taudot: this is a comment, not a tracked change')
    end
    review().decide(method, state.source.doc_id, { c.item.r.id })
  end
end

function M.jump()
  local c = card_here()
  local w = source_win()
  if not c or not w then
    return
  end
  api.nvim_set_current_win(w)
  api.nvim_win_set_cursor(w, { c.item.row + 1, c.item.col })
  vim.cmd('normal! zv')
end

function M.toggle_resolved()
  state.show_resolved = not state.show_resolved
  render()
end

local function panel_keys(buf)
  local function k(lhs, f, desc)
    vim.keymap.set('n', lhs, f, { buffer = buf, nowait = true, silent = true, desc = 'taudot panel: ' .. desc })
  end
  k('<CR>', M.jump, 'go to the text')
  k('r', on_comment(function(r)
    review().reply_to(r)
  end), 'reply')
  k('R', on_comment(function(r, b)
    review().toggle_resolved(r, b.doc_id)
  end), 'resolve or reopen')
  k('d', on_comment(function(r, b)
    review().delete_thread_of(r, b.doc_id)
  end), 'delete thread')
  k('a', on_change('change.accept'), 'accept')
  k('x', on_change('change.reject'), 'reject')
  k('H', M.toggle_resolved, 'show or hide resolved')
  k('q', M.close, 'close')
end

-- ---- open and close -----------------------------------------------------------------------------------------------

local function panel_buf()
  if state.buf and api.nvim_buf_is_valid(state.buf) then
    return state.buf
  end
  -- A panel buffer left from an earlier load of this module: replace it.
  local old = vim.fn.bufnr('^taudot://review$')
  if old ~= -1 then
    pcall(api.nvim_buf_delete, old, { force = true })
  end
  local buf = api.nvim_create_buf(false, true)
  pcall(api.nvim_buf_set_name, buf, 'taudot://review')
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = 'taudot-review'
  panel_keys(buf)
  api.nvim_create_autocmd('CursorMoved', { buffer = buf, callback = on_panel_moved })
  state.buf = buf
  return buf
end

function M.open()
  if M.is_open() then
    return
  end
  local from = api.nvim_get_current_win()
  state.source = Buffer.by_buf[api.nvim_get_current_buf()] or state.source
  local buf = panel_buf()
  vim.cmd('botright vertical ' .. config.options.panel.width .. 'split')
  local win = api.nvim_get_current_win()
  api.nvim_win_set_buf(win, buf)
  state.win = win
  local wo = vim.wo[win]
  wo.number, wo.relativenumber, wo.signcolumn, wo.foldcolumn = false, false, 'no', '0'
  wo.wrap, wo.list, wo.spell, wo.cursorline = false, false, false, false
  wo.winfixwidth = true
  wo.fillchars = 'eob: '
  wo.statuscolumn = ''
  wo.winhighlight = 'Normal:NormalFloat'
  local group = api.nvim_create_augroup('taudot.panel', { clear = true })
  api.nvim_create_autocmd('WinClosed', {
    group = group,
    pattern = tostring(win),
    callback = function()
      state.win = nil
      api.nvim_del_augroup_by_name('taudot.panel')
      review().redraw()
    end,
  })
  api.nvim_create_autocmd('BufEnter', {
    group = group,
    callback = function(ev)
      local b = Buffer.by_buf[ev.buf]
      if b and b ~= state.source then
        state.source = b
        render()
      end
    end,
  })
  api.nvim_create_autocmd('WinResized', {
    group = group,
    callback = function()
      for _, w in ipairs(vim.v.event.windows or {}) do
        if w == state.win then
          return render()
        end
      end
    end,
  })
  if api.nvim_win_is_valid(from) then
    api.nvim_set_current_win(from)
  end
  render()
  if state.source and api.nvim_get_current_buf() == state.source.buf then
    M.follow(state.source)
  end
  -- Inline text is off while the panel is open.
  review().redraw()
end

function M.close()
  if M.is_open() then
    api.nvim_win_close(state.win, true)
  end
  state.win = nil
  review().redraw()
end

function M.toggle()
  if M.is_open() then
    M.close()
  else
    M.open()
  end
end

-- For tests: the panel's lines.
function M.lines()
  if not state.buf or not api.nvim_buf_is_valid(state.buf) then
    return {}
  end
  return api.nvim_buf_get_lines(state.buf, 0, -1, false)
end

return M
