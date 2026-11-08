-- lua/taudot/gui.lua against the mock engine (run by tests/gui.sh). vim.rpcnotify is replaced by a recorder, so the
-- "GUI" is this test; the real channel is covered from Swift (clients/mac/Tests).
local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(root)
vim.cmd('runtime plugin/taudot.lua')
vim.o.termguicolors = true

local api = vim.api
local ts = require('taudot')
local Buffer = require('taudot.buffer')
local gui = require('taudot.gui')
local folder = vim.env.TAUDOT_FOLDER

local failures = 0
local function check(cond, what)
  print((cond and 'ok   ' or 'FAIL ') .. what)
  if not cond then
    failures = failures + 1
  end
end
local function wait(ms, f)
  return vim.wait(ms, f, 10)
end

local CHAN = 4242
local got = {} -- name -> list of payloads
local real_notify = vim.rpcnotify
vim.rpcnotify = function(chan, name, payload)
  if chan ~= CHAN then
    return real_notify(chan, name, payload)
  end
  got[name] = got[name] or {}
  table.insert(got[name], vim.deepcopy(payload))
end
local function last(name)
  local l = got[name]
  return l and l[#l]
end
local function count(name)
  return got[name] and #got[name] or 0
end

ts.setup({})
vim.cmd.edit(folder .. '/main.tex')
local buf = api.nvim_get_current_buf()
local opened
ts.open(folder, function(err)
  opened = err or true
end)
check(wait(3000, function() return opened end) and opened == true, 'project opens')
check(wait(2000, function() return Buffer.by_buf[buf] end), 'main.tex attaches')
local b = Buffer.by_buf[buf]

-- 1. attach sends the state at once.
check(gui.attach(CHAN) == true, 'attach')
check(wait(1000, function() return count('taudot_review') > 0 end), 'first taudot_review sent')
check(last('taudot_review').buf == buf and last('taudot_review').path == 'main.tex', 'it names the buffer and path')
check(wait(1000, function() return count('taudot_review_cursor') > 0 end), 'first cursor sent')

-- 2. The bot's comment and tracked insertion arrive as items with positions, author, colour, messages.
local function find(kind)
  local p = last('taudot_review')
  for _, it in ipairs(p and p.items or {}) do
    if it.kind == kind and (kind ~= 'comment' or #it.messages > 0) then
      return it
    end
  end
end
check(wait(10000, function() return find('comment') and find('tracked_insert') end), 'bot comment and change arrive')
local c = find('comment')
local ins = find('tracked_insert')
if not (c and ins) then
  print(vim.inspect(last('taudot_review')))
  os.exit(1)
end
check(c.author.name == 'Ada Lovelace' and c.author.initials == 'AL', 'comment author: ' .. vim.inspect(c.author))
check(type(c.color) == 'string' and c.color:match('^#%x%x%x%x%x%x$') ~= nil, 'comment colour: ' .. tostring(c.color))
check(c.messages[1].text:find('the right word here?', 1, true) ~= nil, 'comment message')
check(c.messages[1].mine == false, 'not mine')
check(c.resolved == false and c.thread_id ~= nil, 'open, with thread id')
local line = api.nvim_buf_get_lines(buf, c.line, c.line + 1, false)[1]
check(line:sub(c.col + 1, c.end_col) == c.quote, ('comment position %d:%d-%d:%d covers its quote'):format(c.line, c.col, c.end_line, c.end_col))
local iline = api.nvim_buf_get_lines(buf, ins.line, ins.line + 1, false)[1]
check(iline:sub(ins.col + 1, ins.end_col) == ins.quote, 'insertion position covers its text: ' .. ins.quote)
check(type(ins.ts) == 'number', 'insertion has a time')

-- 3. Positions follow local edits: a new line above moves the items down.
local n = count('taudot_review')
api.nvim_buf_set_lines(buf, 0, 0, false, { '% a new first line' })
vim.api.nvim_exec_autocmds('TextChanged', { buffer = buf })
check(wait(1000, function()
  local x = find('comment')
  return x and x.line == c.line + 1
end), 'comment moved down a line after an edit above')
check(count('taudot_review') - n <= 3, 'coalesced: ' .. (count('taudot_review') - n) .. ' payload(s) for one edit')

-- No repeats: a cursor move alone sends no taudot_review.
n = count('taudot_review')
c = find('comment')
local nc = count('taudot_review_cursor')
api.nvim_win_set_cursor(0, { c.line + 1, c.col })
api.nvim_exec_autocmds('CursorMoved', { buffer = buf })
check(wait(1000, function() return count('taudot_review_cursor') > nc end), 'cursor move sends taudot_review_cursor')
local cur = last('taudot_review_cursor')
check(cur.line == c.line and vim.tbl_contains(cur.here, c.id), 'cursor payload lists the comment under it')
wait(100, function() return false end)
check(count('taudot_review') == n, 'cursor move alone resends no review state')

-- 4. Actions.
local function act(kind, id, args)
  return gui.act(kind, id, args or {})
end
local res = act('reply', c.id, { text = 'Yes, keep it.', req = 1 })
check(res.ok == true, 'reply accepted')
check(wait(3000, function() local x = find('comment'); return x and #x.messages == 2 end), 'reply shows in the next payload')
check(wait(3000, function() return last('taudot_review_done') end), 'done arrives')
local d = last('taudot_review_done')
check(d and d.req == 1 and d.ok == true, 'taudot_review_done for req 1')
check(find('comment').messages[2].mine == true, 'my reply is mine')

check(act('reply', c.id, { text = '  ' }).ok == false, 'empty reply refused')
check(act('accept', c.id).ok == false, 'accept on a comment refused')
check(act('resolve', 'nope').ok == false, 'unknown id refused')

local mid = find('comment').messages[2].id
check(act('edit_message', c.id, { message_id = mid, text = 'Yes, keep it!' }).ok, 'edit message')
check(wait(3000, function() return find('comment').messages[2].text == 'Yes, keep it!' end), 'edited text arrives')

check(act('resolve', c.id, { req = 2 }).ok, 'resolve')
check(wait(3000, function()
  local p = last('taudot_review')
  for _, it in ipairs(p.items) do
    if it.id == c.id then return it.resolved == true end
  end
end), 'item marked resolved (still sent, for the toggle)')
check(act('reopen', c.id).ok, 'reopen')
check(wait(3000, function() local x = find('comment'); return x and x.id == c.id and x.resolved == false end), 'reopened')

-- accept the bot's insertion: it leaves the list, the text stays.
local text = ins.quote
check(act('accept', ins.id, { req = 3 }).ok, 'accept')
check(wait(3000, function()
  local p = last('taudot_review')
  for _, it in ipairs(p.items) do
    if it.id == ins.id then return false end
  end
  return true
end), 'accepted change gone')
check(table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), '\n'):find(text, 1, true) ~= nil, 'its text stays')

-- new comment on a range
wait(3000, function() return not b.inflight and not b.pending end)
local row
for i, l in ipairs(api.nvim_buf_get_lines(buf, 0, -1, false)) do
  if l:match('^The ') then row = i - 1 end
end
local word = api.nvim_buf_get_lines(buf, row, row + 1, false)[1]:sub(1, 3)
check(act('comment', 0, { text = 'New from the GUI', line = row, col = 0, end_line = row, end_col = 3, req = 4 }).ok, 'comment')
check(wait(3000, function()
  for _, it in ipairs(last('taudot_review').items) do
    if it.kind == 'comment' and it.quote == word and it.messages[1] and it.messages[1].text == 'New from the GUI' then
      return it.line == row and it.col == 0 and it.end_col == 3
    end
  end
end), 'new comment arrives on "' .. word .. '"')
check(act('comment', 0, { text = 'x', line = row, col = 3, end_line = row, end_col = 3 }).ok == false, "empty range refused")

-- goto
act('goto', c.id)
check(api.nvim_win_get_cursor(0)[1] - 1 == find('comment').line, 'goto moves the cursor to the item')

-- select highlights the item's text; nil clears.
c = find('comment')
check(act('select', c.id).ok, 'select')
local sm = api.nvim_buf_get_extmarks(buf, gui.sel_ns, 0, -1, { details = true })
check(#sm == 1 and sm[1][2] == c.line and sm[1][3] == c.col and sm[1][4].end_col == c.end_col, 'selected text highlighted')
act('select', nil)
check(#api.nvim_buf_get_extmarks(buf, gui.sel_ns, 0, -1, {}) == 0, 'select nil clears')

-- visual mode: the cursor payload carries the selection
api.nvim_win_set_cursor(0, { row + 1, 0 })
nc = count('taudot_review_cursor')
api.nvim_feedkeys('vll', 'nx', false)
local vis = gui.visual()
api.nvim_feedkeys('\27', 'nx', false)
check(vis and vis.line == row and vis.col == 0 and vis.end_col == 3, 'visual selection: ' .. vim.inspect(vis))
check(gui.visual() == nil, 'no selection in normal mode')

-- start_comment: the range a new comment is about, multi-line (two lines, one of them wrapped), with its text.
vim.o.columns = 40
vim.wo.wrap = true
do
  local ls = api.nvim_buf_get_lines(buf, 0, -1, false)
  for i = #ls - 1, 1, -1 do
    if #ls[i] > 45 and #ls[i + 1] > 10 and not ls[i]:match('^\\') then row = i - 1 break end
  end
end
local row2 = row + 1
local l1 = api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
local l2 = api.nvim_buf_get_lines(buf, row2, row2 + 1, false)[1]
check(#l1 > 40, 'the first line wraps at 40 columns (' .. #l1 .. ' bytes)')
local function select_two_lines()
  api.nvim_win_set_cursor(0, { row + 1, 4 })
  api.nvim_feedkeys('vj', 'nx', false)
  api.nvim_win_set_cursor(0, { row2 + 1, 5 })
end
local want = l1:sub(5) .. '\n' .. l2:sub(1, 6)
-- 6a. live visual mode
select_two_lines()
local sc = act('start_comment')
check(sc.ok and sc.line == row and sc.col == 4 and sc.end_line == row2 and sc.end_col == 6, 'start_comment in visual mode: ' .. vim.inspect(sc))
check(sc.quote == want, 'its quote is the selected text: ' .. vim.inspect(sc.quote))
check(api.nvim_get_mode().mode == 'n', 'it leaves visual mode')
sm = api.nvim_buf_get_extmarks(buf, gui.sel_ns, 0, -1, { details = true })
check(#sm == 1 and sm[1][2] == row and sm[1][3] == 4 and sm[1][4].end_row == row2 and sm[1][4].end_col == 6, 'the range stays highlighted')
act('select', nil)
-- 6b. visual mode just left (focus moved, Esc, a click elsewhere), the cursor on another line
select_two_lines()
api.nvim_feedkeys('\27', 'nx', false)
api.nvim_win_set_cursor(0, { row2 + 2, 0 })
sc = act('start_comment')
check(sc.ok and sc.line == row and sc.col == 4 and sc.end_line == row2 and sc.end_col == 6 and sc.quote == want, 'start_comment just after leaving visual mode: ' .. vim.inspect(sc))
-- ... and an edit above it moves it with the text
select_two_lines()
api.nvim_feedkeys('\27', 'nx', false)
api.nvim_buf_set_lines(buf, 0, 0, false, { '% a line above' })
sc = act('start_comment')
check(sc.ok and sc.line == row + 1 and sc.end_line == row2 + 1 and sc.quote == want, 'the range just left follows an edit above: ' .. vim.inspect(sc))
api.nvim_buf_set_lines(buf, 0, 1, false, {})
-- 6c. the comment is sent on that range and anchors there
wait(3000, function() return not b.inflight and not b.pending end)
select_two_lines()
sc = act('start_comment')
check(act('comment', 0, { text = 'On two lines', line = sc.line, col = sc.col, end_line = sc.end_line, end_col = sc.end_col, req = 5 }).ok, 'comment on the multi-line range')
check(wait(3000, function()
  for _, it in ipairs(last('taudot_review').items) do
    if it.kind == 'comment' and it.messages[1] and it.messages[1].text == 'On two lines' then
      return it.line == row and it.col == 4 and it.end_line == row2 and it.end_col == 6 and it.quote == want
    end
  end
end), 'the new comment anchors on the multi-line range')
-- 6d. no selection: refused, no range
gui.left_visual = nil
api.nvim_win_set_cursor(0, { row + 1, 0 })
sc = act('start_comment')
check(sc.ok == false and sc.error == 'select text to comment', 'no selection: refused: ' .. vim.inspect(sc))
-- too long ago
select_two_lines()
api.nvim_feedkeys('\27', 'nx', false)
gui.left_visual.at = gui.left_visual.at - gui.just_left_ms - 1
check(act('start_comment').ok == false, 'a selection left long ago does not count')
act('select', nil)

-- 7. Where the selection ends on screen (the Comment pill): on the first line's second screen row (it wraps at 40).
-- Headless without a UI the grid stays 80 wide: a 40-column window on the left does the wrapping.
vim.cmd('vsplit')
api.nvim_win_set_width(0, 40)
vim.cmd('redraw')
api.nvim_win_set_cursor(0, { row + 1, 0 })
api.nvim_feedkeys('v', 'nx', false)
api.nvim_win_set_cursor(0, { row + 1, 44 })
vis = gui.visual()
api.nvim_feedkeys('\27', 'nx', false)
local w = vim.fn.screenpos(0, row + 1, 45)
check(vis.end_wrap == 1, 'end_wrap: the end is on the wrapped line\'s second row: ' .. vim.inspect(vis))
check(vis.end_screen_col == w.endcol and vis.columns == vim.o.columns, 'end_screen_col: just after the last character, columns ' .. tostring(vis.columns))
vim.cmd('close')

-- 8. :Taudot comment with no text, a GUI attached: the GUI's draft (taudot_review_start), no prompt.
local ns = count('taudot_review_start')
api.nvim_win_set_cursor(0, { row + 1, 4 })
api.nvim_feedkeys('vj', 'nx', false)
api.nvim_win_set_cursor(0, { row2 + 1, 5 })
api.nvim_feedkeys(':Taudot comment\r', 'nx', false)
check(wait(1000, function() return count('taudot_review_start') > ns end), ':Taudot comment sends taudot_review_start')
local st = last('taudot_review_start')
check(st and st.ok and st.line == row and st.col == 4 and st.end_line == row2 and st.end_col == 6, 'with the selection: ' .. vim.inspect(st))
sm = api.nvim_buf_get_extmarks(buf, gui.sel_ns, 0, -1, { details = true })
check(#sm == 1 and sm[1][4].hl_group == 'TaudotGuiDraft', 'the draft range is marked with TaudotGuiDraft')
act('select', nil)
-- the review prefix's normal-mode c (comment on the word) goes there too
ns = count('taudot_review_start')
api.nvim_win_set_cursor(0, { row + 1, 5 })
require('taudot.review').comment_word()
check(wait(1000, function() return count('taudot_review_start') > ns end) and last('taudot_review_start').ok, 'comment on the word opens the draft too')
act('select', nil)

-- 9. With a GUI attached, a taudot buffer isn't reloaded from disk (focus changes run checktime): the extmarks stay.
check(vim.bo[buf].autoread == false, 'autoread off on the taudot buffer')
local before = vim.deepcopy(gui.items(b))
local path = api.nvim_buf_get_name(buf)
wait(3000, function() return not b.inflight and not b.pending end)
vim.fn.writefile(api.nvim_buf_get_lines(buf, 0, -1, false), path) -- what the engine does after our edits
vim.uv.fs_utime(path, os.time() + 5, os.time() + 5)
vim.cmd('checktime')
local after = gui.items(b)
check(#after == #before and after[1].line == before[1].line and after[1].end_line == before[1].end_line,
  ('no reload on checktime: %s:%s → %s:%s'):format(before[1].line, before[1].end_line, after[1] and after[1].line, after[1] and after[1].end_line))

-- 10. Floats and special buffers don't take the margin away (the user's "comments disappear").
local function items_now() return #last('taudot_review').items end
check(wait(2000, function() return last('taudot_review').buf == buf and items_now() > 0 end), 'state of the commented buffer first')
local n0, cur0 = count('taudot_review'), count('taudot_review_cursor')
local items0 = items_now()
-- a float (which-key, notify, hover)
local fb = api.nvim_create_buf(false, true)
local fw = api.nvim_open_win(fb, true, { relative = 'editor', row = 2, col = 2, width = 30, height = 5 })
api.nvim_buf_set_lines(fb, 0, -1, false, { 'a float', 'over the text' })
api.nvim_win_set_cursor(fw, { 2, 3 })
vim.wait(200)
check(last('taudot_review').buf == buf and items_now() == items0, 'float: the payload still follows the commented buffer')
check(last('taudot_review_cursor').buf == buf, 'float: the cursor payload too')
api.nvim_win_close(fw, true)
-- a picker-like split: a special buffer in a normal window (Telescope's prompt, the cmdline window, help, quickfix)
vim.cmd('split')
local sb = api.nvim_create_buf(false, true)
vim.bo[sb].buftype = 'prompt'
api.nvim_win_set_buf(0, sb)
vim.wait(200)
check(last('taudot_review').buf == buf and items_now() == items0, 'special buffer: still the commented buffer')
vim.cmd('close')
-- the : cmdline
api.nvim_feedkeys(':echo 1\r', 'nx', false)
vim.wait(200)
check(last('taudot_review').buf == buf and items_now() == items0, ': cmdline: still the commented buffer')
local wrong = 0
for i = n0 + 1, count('taudot_review') do
  local p = got['taudot_review'][i]
  if p.buf ~= buf or #p.items == 0 then wrong = wrong + 1 end
end
check(wrong == 0, 'no payload in between named another buffer or came empty (' .. wrong .. ')')
check(last('taudot_review').reason ~= nil, 'payloads say why they were sent: ' .. tostring(last('taudot_review').reason))

-- 11. An empty list for the buffer that just had items is held: while reconnecting, indefinitely...
local proj = require('taudot').project()
local empty_sent = function() local p = last('taudot_review'); return p.buf == buf and #p.items == 0 end
proj.connection = 'connecting'
-- (the buffer's items read empty, as while its ranges reload)
b.review_items = function() return {} end
require('taudot.review').redraw()
vim.wait(gui.empty_hold_ms + 300)
check(not empty_sent(), 'reconnecting: no empty list sent')
-- ...online, for empty_hold_ms; then it is real.
proj.connection = 'online'
require('taudot.review').redraw()
vim.wait(gui.empty_hold_ms / 2)
check(not empty_sent(), 'online: not at once')
check(wait(gui.empty_hold_ms + 500, empty_sent), 'online: sent once it has lasted ' .. gui.empty_hold_ms .. ' ms')
check(last('taudot_review').reason:find('empty-held', 1, true) ~= nil, 'with reason empty-held')
-- ...and a list that comes back within the hold is never seen empty.
b.review_items = nil
require('taudot.review').redraw()
check(wait(1000, function() return #last('taudot_review').items > 0 end), 'items back')
local mark = count('taudot_review')
b.review_items = function() return {} end
require('taudot.review').redraw()
vim.wait(gui.empty_hold_ms / 3)
b.review_items = nil
require('taudot.review').redraw()
vim.wait(gui.empty_hold_ms + 200)
local empties = 0
for i = mark + 1, count('taudot_review') do
  local p = got['taudot_review'][i]
  if p.buf == buf and #p.items == 0 then empties = empties + 1 end
end
check(empties == 0 and #last('taudot_review').items > 0, 'a short empty spell is never sent (' .. empties .. ' empty)')

-- 12. doc_row: screen rows above the item's line from the buffer top, wraps counted; it follows the window's width.
local function first_item() return gui.items(b)[1] end
local it1 = first_item()
check(it1 and type(it1.doc_row) == 'number', 'items carry doc_row: ' .. tostring(it1 and it1.doc_row))
local want = it1.line == 0 and 0 or api.nvim_win_text_height(0, { start_row = 0, end_row = it1.line - 1 }).all
check(it1.doc_row == want, ('doc_row %s = rows above line %d (%d)'):format(tostring(it1.doc_row), it1.line, want))
-- a long line above it wraps: more rows
vim.cmd('vsplit')
api.nvim_win_set_width(0, 30)
vim.cmd('redraw')
local narrow = first_item()
check(narrow.doc_row >= it1.doc_row, ('narrower window: doc_row %d ≥ %d'):format(narrow.doc_row, it1.doc_row))
vim.cmd('close')

-- 13. margin_shown: inline notes off while the margin shows, back as they were after.
local opts = require('taudot.config').options
opts.inline = true
check(act('margin_shown', nil, { shown = true }).ok and opts.inline == false, 'margin shown: inline notes off')
act('margin_shown', nil, { shown = true })
check(act('margin_shown', nil, { shown = false }).ok and opts.inline == true, 'margin hidden: inline notes back on')
opts.inline = false
act('margin_shown', nil, { shown = true })
act('margin_shown', nil, { shown = false })
check(opts.inline == false, 'a user who had them off keeps them off')
opts.inline = true

-- 14. The floating card's screen positions: the cursor inside a comment sends `at` for it.
local function a_comment()
  for _, it in ipairs(gui.items(b)) do
    if it.kind == 'comment' and not it.resolved and it.end_line == it.line and it.end_col > it.col + 1 then return it end
  end
end
local cm = a_comment()
check(cm ~= nil, 'a comment to stand in')
api.nvim_win_set_cursor(0, { cm.line + 1, cm.col + 1 })
vim.cmd('redraw')
local cp = gui.cursor_payload()
local at = cp.at and cp.at.items and cp.at.items[cm.id]
check(vim.tbl_contains(cp.here, cm.id) and at ~= nil, 'cursor payload has at for the comment: ' .. vim.inspect(cp.at))
local sp = vim.fn.screenpos(0, cm.line + 1, cm.col + 1)
local first = vim.fn.screenpos(0, cm.line + 1, 1)
check(at and at.start_wrap == sp.row - first.row and at.start_col == sp.col - 1,
  ('start at row %s col %s (screenpos %d,%d)'):format(tostring(at and at.start_wrap), tostring(at and at.start_col), sp.row - first.row, sp.col - 1))
check(cp.at.columns == vim.o.columns and cp.at.cursor_wrap == sp.row - first.row, 'columns and the cursor row')
api.nvim_win_set_cursor(0, { 1, 0 })
check(gui.cursor_payload().at == nil or #gui.cursor_payload().here > 0, 'no at outside items')

-- 15. comment_style: the tint brightens while the cursor is inside, and fades back; bar colours no text.
local ui = require('taudot.ui')
local copts = require('taudot.config').options
local function hl_at(id)
  for _, m in ipairs(api.nvim_buf_get_extmarks(buf, ui.ns.comment, 0, -1, { details = true })) do
    local r = b.comments[m[1]]
    if r and r.id == id then return m[4].hl_group, m[4].sign_hl_group end
  end
end
check(copts.comment_style == 'tint', 'tint is the default style')
b:set_ranges(b.ranges, b.seq or 0)
ui.tint_ms = 0
api.nvim_win_set_cursor(0, { cm.line + 1, cm.col + 1 })
ui.touch(buf, b.comments, cm.line, cm.col + 1)
local hl_in = hl_at(cm.id)
check(hl_in and hl_in:match('^TaudotCommentTint%d+_4$') ~= nil, 'inside: bright tint ' .. tostring(hl_in))
ui.touch(buf, b.comments, 0, 0)
local hl_out = hl_at(cm.id)
check(hl_out and hl_out:match('^TaudotCommentTint%d+_0$') ~= nil, 'outside: faint tint ' .. tostring(hl_out))
local hin, hout = api.nvim_get_hl(0, { name = hl_in }), api.nvim_get_hl(0, { name = hl_out })
check(hin.bg and hout.bg and hin.bg ~= hout.bg, 'the two steps differ')
-- with a fade: steps one at a time
ui.tint_ms = 120
ui.touch(buf, b.comments, cm.line, cm.col + 1)
local seen = {}
wait(500, function()
  local h = hl_at(cm.id)
  seen[#seen + 1] = h and tonumber(h:match('_(%d+)$'))
  return seen[#seen] == 4
end)
check(seen[#seen] == 4 and #vim.tbl_filter(function(x) return x and x > 0 and x < 4 end, seen) > 0,
  'fades in through the steps: ' .. table.concat(vim.tbl_map(tostring, seen), ','))
for _, style in ipairs({ 'tint+underline', 'underline', 'bar' }) do
  copts.comment_style = style
  b:set_ranges(b.ranges, b.seq or 0)
  local h, sgn = hl_at(cm.id)
  local want = ({ ['tint+underline'] = '^TaudotCommentTintU', underline = '^TaudotComment$', bar = nil })[style]
  if style == 'bar' then
    check(h == nil and sgn and sgn:match('^TaudotCommentBar') ~= nil, 'bar: no text colour, a sign ' .. tostring(sgn))
  else
    check(h and h:match(want) ~= nil, style .. ': ' .. tostring(h))
  end
end
check(api.nvim_get_hl(0, { name = 'TaudotCommentTintU1_0' }).underline == true, 'tint+underline is underlined')
copts.comment_style = 'tint'
b:set_ranges(b.ranges, b.seq or 0)
-- comments_hidden: no colour and no sign, the range still found under the cursor; back when shown again
copts.comments_hidden = true
b:set_ranges(b.ranges, b.seq or 0)
local hh, hs = hl_at(cm.id)
local hsign
for _, m in ipairs(api.nvim_buf_get_extmarks(buf, ui.ns.comment, 0, -1, { details = true })) do
  local r = b.comments[m[1]]
  if r and r.id == cm.id then hsign = m[4].sign_text end
end
check(hh == nil and hs == nil and hsign == nil, 'hidden: no colour, no sign ' .. tostring(hh) .. ' ' .. tostring(hsign))
check(#vim.tbl_filter(function(r) return r.id == cm.id end, ui.ranges_at(buf, b.comments, cm.line, cm.col + 1)) == 1, 'hidden: still under the cursor')
copts.comments_hidden = false
b:set_ranges(b.ranges, b.seq or 0)
check((hl_at(cm.id) or ''):match('^TaudotCommentTint') ~= nil, 'shown again: tinted')
ui.tint_ms = 120

-- 16. The file tree: `file` is the followed buffer's absolute path; open edits a file in the main window.
check(vim.fn.resolve(gui.payload().file) == vim.fn.resolve(folder .. '/main.tex'), 'payload file: ' .. tostring(gui.payload().file))
local other = folder .. '/notes-tree.txt'
vim.fn.writefile({ 'plain' }, other)
local fl = api.nvim_open_win(api.nvim_create_buf(false, true), true, { relative = 'editor', row = 1, col = 1, width = 10, height = 2 })
check(act('open', nil, { path = other }).ok, 'open from the tree')
check(api.nvim_buf_get_name(0):match('notes%-tree%.txt$') ~= nil and api.nvim_win_get_config(0).relative == '', 'opened in the main window, not the float')
check(wait(1000, function() local p = last('taudot_review'); return p.file and p.file:match('notes%-tree%.txt$') ~= nil end), 'the GUI hears the new file')
pcall(api.nvim_win_close, fl, true)
check(act('open', nil, {}).ok == false, 'open needs a path')
vim.cmd('buffer ' .. buf)

-- 17. taudot_files: open threads per file, and the collaborators in each (the bot is in main.tex).
local fp = gui.files_payload()
check((fp.comments['main.tex'] or 0) >= 1, 'open comments in main.tex: ' .. vim.inspect(fp.comments))
check(wait(5000, function() local q = gui.files_payload().people['main.tex']; return q and #q > 0 end), 'the bot is in main.tex')
local person = (gui.files_payload().people['main.tex'] or {})[1] or {}
check(type(person.name) == 'string' and type(person.color) == 'string', 'a person with a name and colour: ' .. vim.inspect(person))
check(wait(2000, function() return last('taudot_files') ~= nil end), 'taudot_files sent to the GUI')

-- 18. Jumps: ]r / [r through the open comments and changes, counts, wrapping into the other files in the sidebar's
-- order, resolved ones skipped unless shown.
check(gui.path_lt('main.tex', 'sections/intro.tex') and gui.path_lt('appendix.tex', 'main.tex')
  and gui.path_lt('fig2.tex', 'fig10.tex') and gui.path_lt('a/z.tex', 'a/b/c.tex'), 'sidebar order: files, then folders, natural')
check(vim.fn.maparg(']r', 'n') ~= '' and vim.fn.maparg('[r', 'n') ~= '', ']r and [r mapped in a taudot buffer')
local mainwin = api.nvim_get_current_win()
local function cur() local c = api.nvim_win_get_cursor(mainwin); return c[1] - 1, c[2] end
local function at_item(it) local r, cc = cur(); return r == it.row and cc == it.col end
local function jumped(dir, n)
  local res
  gui.jump(dir, n, function(x) res = x end)
  wait(4000, function() return res ~= nil end)
  return res or {}
end
-- A comment in sections/intro.tex, then its buffer gone: the jumps must find it through doc.ranges.
vim.cmd.edit(folder .. '/sections/intro.tex')
local ibuf = api.nvim_get_current_buf()
check(wait(2000, function() return Buffer.by_buf[ibuf] end), 'intro.tex attaches')
check(act('comment', nil, { buf = ibuf, text = 'intro note', line = 0, col = 3, end_line = 0, end_col = 15 }).ok, 'a comment in intro.tex')
check(wait(5000, function() return #gui.jump_items(Buffer.by_buf[ibuf]) == 1 end), 'it is there')
local intro_id = gui.jump_items(Buffer.by_buf[ibuf])[1].r.thread_id
vim.cmd('buffer ' .. buf)
Buffer.by_buf[ibuf]:detach()
vim.cmd('bwipeout! ' .. ibuf)
local items = gui.jump_items(b)
check(#items >= 2, 'main.tex has items to jump between: ' .. #items)
api.nvim_win_set_cursor(mainwin, { 1, 0 })
local first = items[1].row == 0 and items[1].col == 0 and 2 or 1
local r1 = jumped(1, 1)
check(at_item(items[first]) and r1.index == first and r1.total == #items, ']r: the first one after the cursor')
check(type(r1.message) == 'string' and r1.message:match('^%a+ %d+ of %d+') ~= nil, 'echo: ' .. tostring(r1.message))
local c1 = vim.tbl_filter(function(it)
  local u = it.r.kind == 'comment' and require('taudot.review').thread_author(it.r)
  return type(u) == 'table' and u.name == 'Ada Lovelace'
end, items)[1]
check(c1 ~= nil, "the bot's comment is among them")
api.nvim_win_set_cursor(mainwin, { 1, 0 })
if first == 1 and #items >= 2 then
  check(at_item(items[2]) or jumped(1, 2).index == 2, 'count: 2]r skips one')
  check(at_item(items[2]), 'at the second')
  jumped(-1, 1)
  check(at_item(items[1]), '[r: back to the first')
end
-- The comment's echo names its author.
api.nvim_win_set_cursor(mainwin, { 1, 0 })
for _ = 1, #items do
  local r = jumped(1, 1)
  if r.id == c1.r.id then
    check(r.message:match('^comment %d+ of %d+ · Ada Lovelace') ~= nil, 'comment echo with author: ' .. r.message)
    break
  end
end
-- Off the end: on into sections/intro.tex (appendix.tex has none), then round to main.tex's first.
items = gui.jump_items(b)
api.nvim_win_set_cursor(mainwin, { items[#items].row + 1, items[#items].col })
local r2 = jumped(1, 1)
check(r2.path == 'sections/intro.tex' and r2.id == intro_id and api.nvim_buf_get_name(0):match('intro%.tex$') ~= nil, ']r past the last: the next file: ' .. vim.inspect(r2))
check(r2.message and r2.message:find('sections/intro.tex', 1, true) ~= nil, 'the echo names the file')
local r, cc = cur()
check(r == 0 and cc == 3, 'cursor at the comment start')
local r3 = jumped(1, 1)
check(r3.path == 'main.tex' and api.nvim_get_current_buf() == buf and r3.index == 1, 'and round to main.tex: ' .. vim.inspect(r3))
local r4 = jumped(-1, 1)
check(r4.path == 'sections/intro.tex', '[r before the first: back into intro.tex (appendix has none): ' .. vim.inspect(r4))
vim.cmd('buffer ' .. buf)
-- A count past everything wraps: (total)]r comes back to where it started.
items = gui.jump_items(b)
api.nvim_win_set_cursor(mainwin, { items[1].row + 1, items[1].col })
local r5 = jumped(1, #items + 1)
check(r5.path == 'main.tex' and at_item(items[1]), 'a count of all of them goes round: ' .. vim.inspect(r5))
-- Resolved: skipped, unless the GUI shows resolved.
local ib2
for bb, x in pairs(Buffer.by_buf) do if x.path == 'sections/intro.tex' then ib2 = bb end end
check(act('resolve', intro_id, {}).ok, 'resolve the intro comment')
check(wait(3000, function() local t = ts.project().threads[intro_id]; return t and t.resolved == true end), 'resolved')
if ib2 then vim.cmd('buffer ' .. buf); Buffer.by_buf[ib2]:detach(); pcall(vim.cmd, 'bwipeout! ' .. ib2) end
items = gui.jump_items(b)
api.nvim_win_set_cursor(mainwin, { items[#items].row + 1, items[#items].col })
local r6 = jumped(1, 1)
check(r6.path == 'main.tex' and r6.index == 1, 'resolved skipped: round to main.tex: ' .. vim.inspect(r6))
check(act('show_resolved', nil, { on = true }).ok, 'the GUI shows resolved')
items = gui.jump_items(b)
api.nvim_win_set_cursor(mainwin, { items[#items].row + 1, items[#items].col })
local r7 = jumped(1, 1)
check(r7.path == 'sections/intro.tex', 'shown: the resolved one counts: ' .. vim.inspect(r7))
act('show_resolved', nil, { on = false })
vim.cmd('buffer ' .. buf)
-- The keys: 3]r = three jumps.
items = gui.jump_items(b)
if #items >= 3 then
  api.nvim_win_set_cursor(mainwin, { 1, 0 })
  local want = items[first + 2]
  if want then
    api.nvim_feedkeys('3]r', 'xt', false)
    check(at_item(want), '3]r from the keyboard')
  end
end
-- From the GUI: act jump answers through taudot_review_done.
got['taudot_review_done'] = nil
check(act('jump', nil, { dir = 1, req = 77 }).ok, 'act jump')
check(wait(3000, function() local d = last('taudot_review_done'); return d and d.req == 77 and d.ok and d.result.index ~= nil end), 'its result comes back')
vim.cmd('buffer ' .. buf)

-- 19. The overview: every doc's comments and changes, in the sidebar's order; reveal lands on one in another file.
local ov
gui.overview(function(x) ov = x end)
check(wait(3000, function() return ov ~= nil end), 'overview answers')
local paths = vim.tbl_map(function(f) return f.path end, ov.files or {})
check(vim.deep_equal(paths, { 'main.tex', 'sections/intro.tex' }), 'files with items, sidebar order (appendix has none): ' .. vim.inspect(paths))
local intro_it = ov.files[2] and ov.files[2].items[1] or {}
check(intro_it.id == intro_id and intro_it.text == 'intro note' and intro_it.mine == true and intro_it.quote ~= '', 'the unopened file\'s comment, from doc.ranges: ' .. vim.inspect(intro_it))
local ada
for _, it in ipairs(ov.files[1].items) do if it.author and it.author.name == 'Ada Lovelace' and it.kind == 'comment' then ada = it end end
check(ada and type(ada.line) == 'number' and ada.color ~= vim.NIL and ada.mine == false and ada.replies >= 0, 'an open buffer\'s comment with its line: ' .. vim.inspect(ada))
check(gui.payload().line_count == api.nvim_buf_line_count(buf), 'payload line_count')
for bb, x in pairs(Buffer.by_buf) do if x.path == 'sections/intro.tex' then vim.cmd('buffer ' .. buf); x:detach(); pcall(vim.cmd, 'bwipeout! ' .. bb) end end
got['taudot_review_done'] = nil
check(act('reveal', intro_id, { path = 'sections/intro.tex', req = 91 }).ok, 'act reveal')
check(wait(4000, function() local d = last('taudot_review_done'); return d and d.req == 91 end), 'reveal answers')
local rd = last('taudot_review_done') or {}
local rr, rc = cur()
check(rd.ok and api.nvim_buf_get_name(0):match('intro%.tex$') ~= nil and rr == 0 and rc == 3, 'revealed: intro.tex at the comment: ' .. vim.inspect(rd))
got['taudot_overview_changed'] = nil
act('reopen', intro_id, {})
check(wait(3000, function() return count('taudot_overview_changed') > 0 end), 'a thread change pings the overview')
vim.cmd('buffer ' .. buf)

-- 20. From the overview, on a file that isn't open: resolve by thread id with args.path; accept_many over open docs.
for bb, x in pairs(Buffer.by_buf) do if x.path == 'sections/intro.tex' then vim.cmd('buffer ' .. buf); x:detach(); pcall(vim.cmd, 'bwipeout! ' .. bb) end end
check(act('resolve', intro_id, { path = 'sections/intro.tex' }).ok, 'resolve in an unopened file')
check(wait(3000, function() local t = ts.project().threads[intro_id]; return t and t.resolved == true end), '… resolved')
act('reopen', intro_id, { path = 'sections/intro.tex' })
check(act('accept_many', nil, { ids = {} }).ok == false, 'accept_many needs changes')
local chg = vim.tbl_filter(function(it) return it.r.kind ~= 'comment' end, b:review_items(true))
if #chg > 0 then
  local ids = vim.tbl_map(function(it) return it.r.id end, chg)
  got['taudot_review_done'] = nil
  check(act('accept_many', nil, { ids = ids, req = 93 }).ok, 'accept_many')
  check(wait(3000, function() local d = last('taudot_review_done'); return d and d.req == 93 and d.ok end), '… answered')
  check(wait(3000, function() return #vim.tbl_filter(function(it) return it.r.kind ~= 'comment' end, b:review_items(true)) == 0 end), '… all accepted')
end

-- 21. Verbs at the cursor (ga accept, gx reject, gC resolve, each then on), and the jumps following the filter.
vim.cmd('buffer ' .. buf)
require('taudot.review').track({ 'on' })
check(wait(3000, function() return ts.project().track_changes == true end), 'track changes on')
local function tracked(n)
  return wait(4000, function() return #vim.tbl_filter(function(it) return it.r.kind ~= 'comment' end, b:review_items(false)) >= n end)
end
-- Two insertions of mine on two body lines, far from the bot's comment.
local body = {}
for i, l in ipairs(api.nvim_buf_get_lines(buf, 0, -1, false)) do if #l > 30 and not l:match('^\\') then body[#body + 1] = i - 1 end end
local l1, l2 = body[#body - 3], body[#body - 1]
api.nvim_buf_set_text(buf, l1, 0, l1, 0, { 'ALPHA ' })
api.nvim_buf_set_text(buf, l2, 0, l2, 0, { 'BETA ' })
local function change_at0(row)
  for _, it in ipairs(b:review_items(false)) do if it.r.kind ~= 'comment' and it.row == row then return it end end
end
check(wait(4000, function() return change_at0(l1) ~= nil and change_at0(l2) ~= nil end), 'two tracked insertions')
check(vim.fn.maparg('ga', 'n') ~= '' and vim.fn.maparg('gx', 'n') ~= '' and vim.fn.maparg('gC', 'n') ~= '', 'ga gx gC mapped')
local function change_at(row)
  for _, it in ipairs(b:review_items(false)) do if it.r.kind ~= 'comment' and it.row == row then return it end end
end
api.nvim_win_set_cursor(mainwin, { l1 + 1, 1 })
local vr
gui.verb('accept', nil, function(x) vr = x end)
check(wait(4000, function() return vr ~= nil end) and vr.done == 'accept', 'accept here: ' .. vim.inspect(vr))
check(wait(3000, function() return change_at(l1) == nil end), '… the insertion is accepted')
check(api.nvim_buf_get_lines(buf, l1, l1 + 1, false)[1]:match('^ALPHA ') ~= nil, '… its text stays')
local r1, c1x = cur()
check(r1 ~= l1 or c1x ~= 1, '… and the cursor moved on (row ' .. r1 .. ')')
api.nvim_win_set_cursor(mainwin, { l2 + 1, 2 })
vr = nil
gui.verb('reject', nil, function(x) vr = x end)
check(wait(4000, function() return vr ~= nil end) and vr.done == 'reject', 'reject here')
check(wait(3000, function() return api.nvim_buf_get_lines(buf, l2, l2 + 1, false)[1]:match('^BETA ') == nil end), '… its text goes')
-- Nothing of that kind here: the built-in key instead (ga shows the character), nothing changes.
api.nvim_win_set_cursor(mainwin, { body[1] + 1, 0 })
vr = nil
gui.verb('accept', 'ga', function(x) vr = x end)
check(vr and vr.fallback == true, 'ga elsewhere falls back to the built-in')
-- gC on a comment resolves it.
local cm2 = vim.tbl_filter(function(it) return it.r.kind == 'comment' end, b:review_items(false))[1]
api.nvim_win_set_cursor(mainwin, { cm2.row + 1, cm2.col })
vr = nil
gui.verb('resolve', nil, function(x) vr = x end)
check(wait(4000, function() return vr ~= nil end) and vr.done == 'resolve', 'resolve here')
check(wait(3000, function() local t = ts.project().threads[cm2.r.thread_id]; return t and t.resolved == true end), '… resolved')
act('reopen', cm2.r.thread_id, {})
-- The filter: Suggestions only → the jumps skip comments; Comments only → they skip changes.
api.nvim_buf_set_text(buf, l2, 0, l2, 0, { 'GAMMA ' })
check(tracked(1), 'a tracked insertion again')
check(wait(3000, function() local t = ts.project().threads[cm2.r.thread_id]; return t and t.resolved == false end), 'reopened')
check(act('kinds', nil, { comments = false, suggestions = true }).ok, 'kinds: suggestions only')
check(#vim.tbl_filter(function(it) return it.r.kind == 'comment' end, gui.jump_items(b)) == 0 and #gui.jump_items(b) >= 1, 'jumps skip comments')
act('kinds', nil, { comments = true, suggestions = false })
check(#vim.tbl_filter(function(it) return it.r.kind ~= 'comment' end, gui.jump_items(b)) == 0 and #gui.jump_items(b) >= 1, 'jumps skip suggestions')
act('kinds', nil, { comments = true, suggestions = true })
require('taudot.review').track({ 'off' })
wait(2000, function() return ts.project().track_changes == false end)

-- 22. Preview: the text as if every suggestion were accepted / rejected, read-only, and back exactly.
local pl = gui.previewed_lines({ 'The careful reader', 'sees it.' }, {
  { kind = 'tracked_insert', row = 0, col = 4, end_row = 0, end_col = 12 },                -- "careful " added
  { kind = 'tracked_delete', row = 1, col = 4, end_row = 1, end_col = 4, text = 'all of ' }, -- "all of " deleted (classic)
}, 'rejected')
check(vim.deep_equal(pl, { 'The reader', 'seesall of  it.' }) or vim.deep_equal(pl, { 'The reader', 'sees all of it.' }), 'rejected: insertions out, deletions back: ' .. vim.inspect(pl))
local pa = gui.previewed_lines({ 'The careful reader', 'sees gone it.' }, {
  { kind = 'tracked_insert', row = 0, col = 4, end_row = 0, end_col = 12 },
  { kind = 'tracked_delete', row = 1, col = 5, end_row = 1, end_col = 10, text = 'gone ' },  -- history-ot: still in the text
}, 'accepted')
check(vim.deep_equal(pa, { 'The careful reader', 'sees it.' }), 'accepted: deleted text out: ' .. vim.inspect(pa))
vim.cmd('buffer ' .. buf)
require('taudot.review').track({ 'on' })
wait(3000, function() return ts.project().track_changes == true end)
local lp = body[#body - 2]
api.nvim_buf_set_text(buf, lp, 0, lp, 0, { 'PREVIEWME ' })
check(wait(4000, function() return change_at(lp) ~= nil end), 'a tracked insertion to preview')
require('taudot.review').track({ 'off' })
wait(2000, function() return ts.project().track_changes == false end)
api.nvim_win_set_cursor(mainwin, { lp + 1, 3 })
local view0 = vim.fn.winsaveview()
local tick0 = vim.b[buf].changedtick
local lines0 = api.nvim_buf_get_lines(buf, 0, -1, false)
got['taudot_preview'] = nil
local pr = act('preview', nil, { mode = 'rejected' })
check(pr.ok and api.nvim_win_get_buf(mainwin) ~= buf, 'preview rejected: another (scratch) buffer in the window')
local sb = api.nvim_win_get_buf(mainwin)
check(not vim.bo[sb].modifiable and vim.wo[mainwin].winbar:find('Preview', 1, true) ~= nil, 'read-only, with a banner')
check(api.nvim_buf_get_lines(sb, lp, lp + 1, false)[1]:find('PREVIEWME', 1, true) == nil, 'the insertion is gone in the preview: '
  .. vim.inspect(api.nvim_buf_get_lines(sb, lp, lp + 1, false)) .. vim.inspect(vim.tbl_map(function(it) return { it.r.kind, it.row, it.col, it.end_row, it.end_col, it.r.text } end,
  vim.tbl_filter(function(it) return it.r.kind ~= 'comment' end, b:review_items(false)))))
check(last('taudot_preview') and last('taudot_preview').mode == 'rejected', 'the GUI hears it')
act('preview', nil, { mode = 'accepted' })
check(api.nvim_buf_get_lines(api.nvim_win_get_buf(mainwin), lp, lp + 1, false)[1]:find('PREVIEWME', 1, true) ~= nil, 'accepted: it stays')
check(not api.nvim_buf_is_valid(sb), 'the first preview buffer is gone')
check(act('preview', nil, { mode = 'off' }).ok, 'preview off')
check(api.nvim_win_get_buf(mainwin) == buf and vim.deep_equal(vim.fn.winsaveview(), view0), 'back: the live buffer, the same view')
check(vim.b[buf].changedtick == tick0 and vim.deep_equal(api.nvim_buf_get_lines(buf, 0, -1, false), lines0), '… and its text untouched')
check(vim.wo[mainwin].winbar == '' and last('taudot_preview').mode == 'off', '… no banner; the GUI hears it')
-- Esc in the preview goes back too.
act('preview', nil, { mode = 'accepted' })
api.nvim_feedkeys(api.nvim_replace_termcodes('<Esc>', true, false, true), 'xt', false)
check(api.nvim_win_get_buf(mainwin) == buf and gui.previewing == nil, 'Esc leaves the preview')

-- 23. Where a range starts on screen (the connector's end): the same as screenpos for a line on screen, wrapped
-- with 'linebreak', and given for every item in the payload.
vim.cmd('buffer ' .. buf)
local cols0 = vim.o.columns
vim.o.columns = 50
vim.wo[mainwin].wrap = true
vim.wo[mainwin].linebreak = true
local long
for i, l in ipairs(api.nvim_buf_get_lines(buf, 0, -1, false)) do if #l > 70 then long = i - 1 break end end
api.nvim_win_set_cursor(mainwin, { long + 1, 0 })
vim.cmd('normal! zt')
vim.cmd('redraw')
local txt = api.nvim_buf_get_lines(buf, long, long + 1, false)[1]
local info = vim.fn.getwininfo(mainwin)[1]
local first = vim.fn.screenpos(mainwin, long + 1, 1)
local bad = {}
for _, c in ipairs({ 0, 10, 45, 60, 95, #txt - 3 }) do
  local w, sc = gui.start_on_screen(mainwin, long, c, txt)
  local p = vim.fn.screenpos(mainwin, long + 1, c + 1)
  local want_w, want_c = p.row - first.row, p.col - 1 - (info.wincol - 1) - info.textoff
  if w ~= want_w or sc ~= want_c then bad[#bad + 1] = ('col %d: %d,%d want %d,%d'):format(c, w, sc, want_w, want_c) end
end
check(#bad == 0, 'start on screen = screenpos: ' .. table.concat(bad, '; '))
local pl2 = gui.payload(buf)
check(type(pl2.textoff) == 'number' and pl2.items[1] and type(pl2.items[1].start_wrap) == 'number' and type(pl2.items[1].start_scol) == 'number', 'payload: textoff, start_wrap, start_scol')
-- A range starting at a line's end (a selection begun past the text): its start on screen is the next line.
local lend = long - 1
local lt = api.nvim_buf_get_lines(buf, lend, lend + 1, false)[1]
check(act('comment', nil, { buf = buf, text = 'from the end', line = lend, col = #lt, end_line = long, end_col = 5 }).ok, 'a comment from a line end')
check(wait(4000, function()
  for _, it in ipairs(gui.payload(buf).items) do if it.line == lend and it.col == #lt then return it.start_line == long and it.start_wrap == 0 and it.start_scol == 0 end end
end), 'its start on screen is the next line, column 0')
vim.o.columns = cols0

-- 5. A buffer that isn't a taudot doc sends no items.
vim.cmd('enew')
check(wait(1000, function() local p = last('taudot_review'); return p.buf ~= buf and #p.items == 0 end), 'other buffer: no items')
vim.cmd('buffer ' .. buf)
check(wait(1000, function() return last('taudot_review').buf == buf end), 'back: state again')

gui.detach(CHAN)
print(failures == 0 and 'all ok' or (failures .. ' failed'))
os.exit(failures == 0 and 0 or 1)
