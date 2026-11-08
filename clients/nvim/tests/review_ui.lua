-- Review UI against the mock engine (run by tests/run.sh): mappings, inline text, the panel and its keys, the input
-- float, the picker fallback.
local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(root)
vim.cmd('runtime plugin/taudot.lua')
vim.o.termguicolors = true
vim.g.mapleader = ' '

local api = vim.api
local ts = require('taudot')
local Buffer = require('taudot.buffer')
local ui = require('taudot.ui')
local panel = require('taudot.panel')
local keys = require('taudot.keys')
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
local function feed(k)
  api.nvim_feedkeys(api.nvim_replace_termcodes(k, true, false, true), 'mx', false)
end
local function has_line(lines, pat)
  for _, l in ipairs(lines) do
    if l:find(pat, 1, true) then
      return true
    end
  end
  return false
end

-- 1. Mappings: on by default, never over one of the user's.
vim.keymap.set('n', '<leader>ar', '<Cmd>echo "mine"<CR>', { desc = 'my own reply key' })
ts.setup({})
check(vim.fn.maparg('<leader>ap', 'n', false, true).desc == 'Taudot: review panel', '<leader>ap is the panel')

vim.cmd.edit(folder .. '/main.tex')
local buf = api.nvim_get_current_buf()
local opened
ts.open(folder, function(err)
  opened = err or true
end)
check(wait(3000, function() return opened end) and opened == true, 'project opens')
check(wait(2000, function() return Buffer.by_buf[buf] end), 'main.tex attaches')
local b = Buffer.by_buf[buf]
check(vim.fn.maparg('<leader>ar', 'n', false, true).desc == 'my own reply key', 'my <leader>ar is kept')
check(keys.skipped['n <leader>ar'] ~= nil, 'and listed as skipped')
check(vim.fn.maparg('<leader>aR', 'n', false, true).desc ~= nil, '<leader>aR (resolve) is mapped in the doc')
vim.cmd('checkhealth taudot')
local health = table.concat(api.nvim_buf_get_lines(0, 0, -1, false), '\n')
check(health:find('<leader>ar is already mapped', 1, true) ~= nil, 'checkhealth lists the skipped key')
vim.cmd('bwipeout')
api.nvim_set_current_buf(buf)

-- 2. Inline text on the bot's comment.
local function comment_ranges()
  return vim.tbl_filter(function(r) return r.kind == 'comment' end, b.ranges or {})
end
check(wait(8000, function() return #comment_ranges() > 0 end), 'bot comment arrives')
local function inline_marks()
  return api.nvim_buf_get_extmarks(buf, ui.ns.inline, 0, -1, { details = true })
end
check(wait(2000, function() return #inline_marks() > 0 end), 'inline text drawn')
local im = inline_marks()[1]
local itext = im and table.concat(vim.tbl_map(function(c) return c[1] end, im[4].virt_text), '') or ''
check(itext:find('Ada Lovelace: Is', 1, true) ~= nil, 'inline text says who and what: ' .. itext)

-- 3. The panel: <leader>ap opens it, cards for the comment and the tracked change, inline text off.
-- A tracked change of my own (the e2e run may have accepted the bot's).
vim.cmd('Taudot track on')
wait(1000, function() return ts.project().track_changes end)
local last = api.nvim_buf_line_count(buf)
api.nvim_buf_set_text(buf, last - 1, 0, last - 1, 0, { 'tracked words ' })
check(wait(4000, function()
  for _, r in ipairs(b.ranges) do
    if r.kind == 'tracked_insert' and r.author.user_id == 'u-me' then return true end
  end
end), 'my tracked insertion arrives')
vim.cmd('Taudot track off')
feed("<leader>ap")
check(panel.is_open(), '<leader>ap opens the panel')
check(api.nvim_get_current_buf() == buf, 'focus stays in the editor')
check(api.nvim_win_get_width(panel.state.win) == 44, 'panel is 44 columns wide')
check(wait(1000, function() return #inline_marks() == 0 end), 'inline text off while the panel is open')
local lines = panel.lines()
check(has_line(lines, 'Review · main.tex'), 'panel title names the file')
check(has_line(lines, '● Ada Lovelace'), 'comment card with the author')
check(has_line(lines, 'the right word here?'), 'comment card with the message')
check(has_line(lines, 'You added'), 'tracked change card')
check(has_line(lines, '+ tracked words'), 'tracked change card shows the text')
check(#panel.state.cards >= 2, 'cards in the panel: ' .. #panel.state.cards)
local rows = vim.tbl_map(function(c) return c.item.row end, panel.state.cards)
local sorted = vim.deepcopy(rows)
table.sort(sorted)
check(vim.deep_equal(rows, sorted), 'cards in line order')

-- 4. Comment through the input float; the panel updates by itself.
local row, ws, we, word
for i, l in ipairs(api.nvim_buf_get_lines(buf, 0, -1, false)) do
  local s, e = l:find('%f[%w\\]%a%a%a%a%a+')
  if s and i > 2 and not l:find('citation', 1, true) then
    local taken = false
    for _, r in ipairs(comment_ranges()) do
      local rr = Buffer.pos_to_rc(buf, r.start)
      if rr == i - 1 then taken = true end
    end
    if not taken then
      row, ws, we, word = i, s, e, l:sub(s, e)
      break
    end
  end
end
wait(4000, function() return not b.inflight and not b.pending end)
api.nvim_win_set_cursor(0, { row, ws - 1 })
vim.cmd('normal! v' .. (we - ws) .. 'l\27')
require('taudot.review').comment({})
local fwin = api.nvim_get_current_win()
local fcfg = api.nvim_win_get_config(fwin)
check(fcfg.relative ~= '', 'input float opens')
local title = fcfg.title and table.concat(vim.tbl_map(function(c) return c[1] end, fcfg.title), '') or ''
check(title:find('Comment on “' .. word .. '”', 1, true) ~= nil, 'its title quotes the text: ' .. title)
check(vim.bo.filetype == 'markdown', 'input is markdown')
api.nvim_buf_set_lines(0, 0, -1, false, { 'two lines:', 'is this the word?' })
feed('<C-s>')
check(api.nvim_get_current_buf() == buf, '<C-s> sends and closes the float')
local threads = function() return ts.project().threads or {} end
local mine
check(wait(3000, function()
  for _, r in ipairs(comment_ranges()) do
    if r.text == word then mine = r end
  end
  return mine and threads()[mine.thread_id] ~= nil
end), 'my comment arrives')
check(mine and threads()[mine.thread_id].messages[1].text == 'two lines:\nis this the word?', 'multi-line message kept')
check(wait(2000, function() return has_line(panel.lines(), 'is this the word?') end), 'panel shows my comment live')

-- 5. Following: the cursor on my comment highlights its card.
local function my_card()
  for i, c in ipairs(panel.state.cards) do
    if c.item.r.thread_id == mine.thread_id then return c, i end
  end
end
api.nvim_win_set_cursor(0, { row, ws })
panel.follow(b)
local card = my_card()
check(card and panel.state.current == card.key, 'card under the cursor is highlighted')
check(card and api.nvim_win_get_cursor(panel.state.win)[1] == card.first + 1, 'and scrolled to in the panel')

-- Moving in the panel moves the editor.
local other
for _, c in ipairs(panel.state.cards) do
  if c.key ~= card.key then other = c end
end
local ewin = api.nvim_get_current_win()
api.nvim_set_current_win(panel.state.win)
api.nvim_win_set_cursor(panel.state.win, { other.first + 1, 0 })
api.nvim_exec_autocmds('CursorMoved', { buffer = panel.state.buf })
check(api.nvim_win_get_cursor(ewin)[1] == other.item.row + 1, 'moving in the panel moves the editor')

-- 6. Panel keys: r replies (float, <CR> in normal mode sends), R resolves, H shows resolved.
card = my_card()
api.nvim_win_set_cursor(panel.state.win, { card.first + 1, 0 })
feed('r')
fcfg = api.nvim_win_get_config(0)
title = fcfg.title and table.concat(vim.tbl_map(function(c) return c[1] end, fcfg.title), '') or ''
check(title:find('Reply to You', 1, true) ~= nil, 'r opens "Reply to You": ' .. title)
api.nvim_buf_set_lines(0, 0, -1, false, { 'answering myself' })
feed('<CR>')
check(api.nvim_win_get_config(0).relative == '', 'reply float closed')
check(wait(2000, function() return #threads()[mine.thread_id].messages == 2 end), 'reply sent')
check(wait(2000, function() return has_line(panel.lines(), '↳ You') and has_line(panel.lines(), 'answering myself') end), 'reply shows in the card')
api.nvim_set_current_win(panel.state.win)
card = my_card()
api.nvim_win_set_cursor(panel.state.win, { card.first + 1, 0 })
feed('R')
check(wait(2000, function() return threads()[mine.thread_id].resolved end), 'R resolves')
check(wait(2000, function() return my_card() == nil end), 'resolved card hidden')
feed('H')
check(my_card() ~= nil and has_line(panel.lines(), '✓ resolved'), 'H shows resolved cards')
card = my_card()
api.nvim_win_set_cursor(panel.state.win, { card.first + 1, 0 })
feed('R')
check(wait(2000, function() return not threads()[mine.thread_id].resolved end), 'R on a resolved card reopens')
feed('H')

-- 7. Input float: q cancels and sends nothing.
api.nvim_set_current_win(panel.state.win)
card = my_card()
check(wait(2000, function() card = my_card(); return card ~= nil end), 'reopened card is back')
api.nvim_win_set_cursor(panel.state.win, { card.first + 1, 0 })
feed('r')
api.nvim_buf_set_lines(0, 0, -1, false, { 'never mind' })
feed('q')
vim.wait(300)
check(#threads()[mine.thread_id].messages == 2, 'q cancels the reply')

-- q closes the panel; inline text comes back.
api.nvim_set_current_win(panel.state.win)
feed('q')
check(not panel.is_open(), 'q closes the panel')
check(wait(1000, function() return #inline_marks() > 0 end), 'inline text back after closing')

-- 8. Picker fallback (no Telescope here): vim.ui.select with every open thread; picking one jumps there.
local orig = vim.ui.select
local got
vim.ui.select = function(items, opts, cb)
  got = { items = items, opts = opts, cb = cb }
end
vim.cmd('Taudot comments')
check(wait(2000, function() return got ~= nil end), ':Taudot comments falls back to vim.ui.select')
local fmt = got and vim.tbl_map(got.opts.format_item, got.items) or {}
check(#fmt >= 2 and has_line(fmt, 'Ada Lovelace ·') and has_line(fmt, '(+1)'), 'entries: author, time, replies: ' .. (fmt[#fmt] or ''))
api.nvim_win_set_cursor(0, { 1, 0 })
local pick
for _, it in ipairs(got and got.items or {}) do
  if it.thread_id == mine.thread_id then pick = it end
end
got.cb(pick)
check(api.nvim_win_get_cursor(0)[1] == row, 'picking jumps to the comment')
got = nil
vim.cmd('Taudot changes')
check(wait(2000, function() return got ~= nil end), ':Taudot changes lists tracked changes')
fmt = got and vim.tbl_map(got.opts.format_item, got.items) or {}
check(has_line(fmt, 'You added'), 'my tracked insertion: ' .. (fmt[1] or ''))
-- Panel keys a and x on change cards: x rejects mine.
feed('<leader>ap')
local ccard
for _, c in ipairs(panel.state.cards) do
  if c.item.r.kind == 'tracked_insert' and c.item.r.author.user_id == 'u-me' then ccard = c end
end
api.nvim_set_current_win(panel.state.win)
api.nvim_win_set_cursor(panel.state.win, { ccard.first + 1, 0 })
feed('x')
check(wait(3000, function() return not Buffer.buffer_text(buf):find('tracked words', 1, true) end), 'x on a change card rejects it')
check(wait(2000, function() return not has_line(panel.lines(), 'You added') end), 'and its card goes')
feed('q')
vim.ui.select = orig

-- Cleanup for the next runs of the mock: delete my thread.
vim.fn.confirm = function() return 1 end
require('taudot.review').delete_thread_of(mine, b.doc_id)
check(wait(2000, function() return threads()[mine.thread_id] == nil end), 'thread deleted')

print(failures == 0 and 'ALL OK' or (failures .. ' FAILED'))
vim.cmd(failures == 0 and 'qa!' or 'cq!')
