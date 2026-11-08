-- Run through tests/run.sh, which starts the mock engine.
local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(root)
vim.cmd('runtime plugin/taudot.lua')
vim.o.termguicolors = true

local api = vim.api
local ts = require('taudot')
local Buffer = require('taudot.buffer')
local ui = require('taudot.ui')
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
local function mock_log()
  return table.concat(vim.fn.readfile(vim.env.MOCK_LOG), '\n')
end

ts.setup({ comment_K = true })
vim.cmd.edit(folder .. '/main.tex')
local buf = api.nvim_get_current_buf()
local opened
ts.open(folder, function(err)
  opened = err or true
end)
check(wait(3000, function() return opened end) and opened == true, 'project opens: ' .. tostring(opened))
check(wait(2000, function() return Buffer.by_buf[buf] end), 'main.tex attaches')
local b = Buffer.by_buf[buf]

-- An engine client of our own to read the engine's copy.
local probe
require('taudot.rpc').connect(vim.env.TAUDOT_SOCKET, { on_notify = function() end, on_close = function() end },
  function(err, c) probe = c or err end)
wait(2000, function() return probe end)
local function engine_doc()
  local res
  probe:request('doc.open', { project_id = 'mock', path = 'main.tex' }, function(_, r) res = r end)
  wait(2000, function() return res end)
  return res
end
-- The buffer and the engine agree once nothing is in flight and both are at the same seq.
local function converged(ms)
  local ok = wait(ms or 6000, function()
    if b.inflight or b.pending then return false end
    local e = engine_doc()
    return e and e.seq == b.seq and e.text == Buffer.buffer_text(buf)
  end)
  return ok
end

-- 1. Remote edits appear, coloured.
local before = Buffer.buffer_text(buf)
check(wait(6000, function() return Buffer.buffer_text(buf) ~= before end), 'bot edits appear in the buffer')
check(wait(2000, function()
  return #api.nvim_buf_get_extmarks(buf, ui.ns.author, 0, -1, {}) > 0
end), 'remote text gets an author highlight')
local marks = api.nvim_buf_get_extmarks(buf, ui.ns.author, 0, -1, { details = true })
check(marks[1] and marks[1][4].hl_group:match('^TaudotFade%d_%d$') ~= nil, 'highlight is a fade step group')
local hl = marks[1] and api.nvim_get_hl(0, { name = marks[1][4].hl_group }) or {}
check(hl.bg ~= nil, 'fade group has a blended background')
check(wait(5000, function()
  return #api.nvim_buf_get_extmarks(buf, ui.ns.cursor, 0, -1, {}) > 0
end), 'bot cursor is drawn')
check(ts.statusline():find('AL', 1, true) ~= nil, 'statusline shows AL online: ' .. ts.statusline())

-- 2. Local edits reach the engine, while the bot types.
api.nvim_win_set_cursor(0, { 10, 0 })
vim.cmd('normal! Ofrom nvim é😀')
wait(200, function() return b.pending or b.inflight end)
check(b:unconfirmed() > 0 or b.inflight ~= nil, 'local edit is unconfirmed at first')
check(#api.nvim_buf_get_extmarks(buf, ui.ns.unconfirmed, 0, -1, {}) > 0, 'unconfirmed text is underlined')
check(converged(), 'buffer and engine converge after a local edit')
check(engine_doc().text:find('from nvim é😀', 1, true) ~= nil, 'engine has the local text, unicode intact')
check(mock_log():find('ME main.tex', 1, true) ~= nil, 'mock log shows our edit')
check(#api.nvim_buf_get_extmarks(buf, ui.ns.unconfirmed, 0, -1, {}) == 0, 'underline cleared once confirmed')

-- 3. Concurrent typing in many places, with the engine's latency forcing transforms on both sides.
math.randomseed(3)
for i = 1, 60 do
  local n = api.nvim_buf_line_count(buf)
  local row = math.random(0, n - 1)
  local line = api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
  local col = math.random(0, #line)
  -- stay on character boundaries
  while col > 0 and col < #line and line:byte(col + 1) >= 0x80 and line:byte(col + 1) < 0xC0 do
    col = col - 1
  end
  if i % 7 == 0 and #line > 2 then
    api.nvim_buf_set_text(buf, row, 0, row, 1, {})
  elseif i % 11 == 0 then
    api.nvim_buf_set_lines(buf, row, row, false, { 'new line ' .. i })
  else
    api.nvim_buf_set_text(buf, row, col, row, col, { tostring(i % 10) })
  end
  wait(math.random(5, 40), function() return false end)
end
check(converged(8000), 'buffer and engine converge after concurrent typing')
if tonumber(vim.env.LATENCY or '120') > 0 then
  check(mock_log():find('(from ', 1, true) ~= nil, 'the engine transformed at least one stale edit')
end
check((b.transformed or 0) > 0, "the client transformed remote edits past its own: " .. tostring(b.transformed))

-- 3b. Edits at the end of the file, where the final newline lives.
local function last() return api.nvim_buf_line_count(buf) end
api.nvim_win_set_cursor(0, { last(), 0 })
vim.cmd("normal! Goappended last line")
vim.cmd("normal! Go")
vim.cmd("normal! Gdd")
vim.cmd("normal! GddGddu")
vim.cmd("normal! ggOfirst line")
vim.cmd("normal! ggJ")
vim.cmd("normal! 3GVjd")
vim.cmd("normal! Gp")
check(converged(8000), "converge after edits at the start and end of the file")

check((b.fallbacks or 0) == 0, 'span tracking never fell back to a whole-text diff: ' .. tostring(b.fallbacks or 0))

-- 4. No echo loop: once we stop, our edits stop.
local function my_lines()
  local n = 0
  for _ in mock_log():gmatch('ME main%.tex') do n = n + 1 end
  return n
end
local n1 = my_lines()
wait(1500, function() return false end)
check(my_lines() == n1, 'no echo: no more ME edits after we stop typing (' .. n1 .. ')')

-- 5. Comments: a highlight, a sign, a thread.
check(wait(8000, function()
  return #api.nvim_buf_get_extmarks(buf, ui.ns.comment, 0, -1, {}) > 0
end), 'bot comment is drawn')
local cm
for _, m in ipairs(api.nvim_buf_get_extmarks(buf, ui.ns.comment, 0, -1, { details = true })) do
  if (m[4].hl_group or ''):match('^TaudotComment') and m[4].sign_text then cm = cm or m end
end
check(cm and cm[4].sign_text ~= nil and cm[4].hl_group:match('^TaudotCommentTint') ~= nil, 'comment has a sign and highlight')
if cm and (cm[4].end_row > cm[2] or cm[4].end_col > cm[3]) then
  api.nvim_win_set_cursor(0, { cm[2] + 1, cm[3] })
  check(b:show_thread(), 'K finds the thread under the cursor')
end

-- 5b. Review: the bot's tracked insertion, then comments and tracked changes from here.
local review = require('taudot.review')
local function ranges_of(kind)
  return vim.tbl_filter(function(r) return r.kind == kind end, b.ranges or {})
end
-- Put the cursor on a range, where its extmark is now (b.ranges positions are as of the last ranges.changed).
local function goto_range(id)
  for _, m in ipairs(api.nvim_buf_get_extmarks(buf, ui.ns.comment, 0, -1, {})) do
    local r = b.comments[m[1]]
    if r and r.id == id then
      api.nvim_win_set_cursor(0, { m[2] + 1, m[3] })
      return true
    end
  end
end
local function marks_with(group_pat)
  local n = 0
  for _, m in ipairs(api.nvim_buf_get_extmarks(buf, ui.ns.comment, 0, -1, { details = true })) do
    local g = m[4].hl_group or (m[4].virt_text and m[4].virt_text[1][2]) or ''
    if g:match(group_pat) then n = n + 1 end
  end
  return n
end
check(wait(8000, function() return #ranges_of('tracked_insert') > 0 end), 'bot tracked insertion arrives')
check(marks_with('^TaudotTrackedInsert%d$') > 0, 'tracked insertion drawn in the author colour')
local ti = ranges_of('tracked_insert')[1]
if ti then
  goto_range(ti.id)
  local lines = ui.review_lines(b:ranges_here(), ts.project().threads)
  check(table.concat(lines, '\n'):find('Inserted** by Ada Lovelace', 1, true) ~= nil, 'K says who inserted it: ' .. (lines[1] or ''))
end

-- Comment on a selection (a word on line 3), as :'<,'>Taudot comment would.
check(converged(8000), 'converged before commenting')
local row, line, ws, we
for i, l in ipairs(api.nvim_buf_get_lines(buf, 0, -1, false)) do
  ws, we = l:find('%f[%w\\]%a%a%a%a+')
  if ws and i > 2 then
    row, line = i, l
    break
  end
end
api.nvim_win_set_cursor(0, { row, ws - 1 })
vim.cmd('normal! v' .. (we - ws) .. 'l\27')
vim.cmd("'<,'>Taudot comment is this right?")
local word = line:sub(ws, we)
local mine
check(wait(3000, function()
  for _, r in ipairs(ranges_of('comment')) do
    if r.text == word then mine = r end
  end
  return mine ~= nil
end), 'my comment on "' .. word .. '" is drawn')
local threads = function() return ts.project().threads or {} end
check(wait(2000, function()
  local t = mine and threads()[mine.thread_id]
  return t and t.messages[1] and t.messages[1].text == 'is this right?'
end), 'its thread has the message')
if mine then
  goto_range(mine.id)
  vim.cmd('Taudot reply yes it is')
  check(wait(2000, function() return #threads()[mine.thread_id].messages == 2 end), 'reply added')
  -- Two of the messages are mine: pick the second when asked.
  local orig_select = vim.ui.select
  vim.ui.select = function(items, _, cb) cb(items[#items]) end
  vim.cmd('Taudot edit-message yes, it is')
  check(wait(2000, function() return threads()[mine.thread_id].messages[2].text == 'yes, it is' end), 'own message edited')
  vim.ui.select = orig_select
  local lines = ui.review_lines(b:ranges_here(), threads())
  check(table.concat(lines, '\n'):find('yes, it is', 1, true) ~= nil, 'K shows the thread')
  vim.cmd('Taudot resolve')
  check(wait(2000, function() return threads()[mine.thread_id].resolved end), 'resolved')
  check(wait(2000, function()
    for _, r in ipairs(ranges_of('comment')) do
      if r.thread_id == mine.thread_id then return r.resolved end
    end
  end), 'range says resolved')
  check(wait(1000, function()
    for _, m in ipairs(api.nvim_buf_get_extmarks(buf, ui.ns.comment, 0, -1, { details = true })) do
      if b.comments[m[1]] and b.comments[m[1]].thread_id == mine.thread_id then return false end
    end
    return true
  end), 'resolved comment is hidden')
  vim.cmd('Taudot comments qf')
  wait(1000, function() return #vim.fn.getqflist() > 0 end)
  local qf = vim.fn.getqflist()
  local has = function(list)
    for _, it in ipairs(list) do
      if it.text:find('is this right?', 1, true) then return true end
    end
  end
  check(not has(qf), 'review list hides resolved threads')
  vim.cmd('Taudot comments all qf')
  wait(1000, function() return has(vim.fn.getqflist()) end)
  check(has(vim.fn.getqflist()) and vim.fn.getqflist()[1].text:find('·', 1, true) ~= nil, 'comments all lists it, with author and time')
  vim.cmd('cclose')
end

-- Track my own edits, then reject them.
vim.cmd('Taudot track on')
check(wait(2000, function() return ts.statusline():find('TC', 1, true) ~= nil end), 'statusline shows TC')
api.nvim_win_set_cursor(0, { 2, 0 })
vim.cmd('normal! IZZTRACK ')
local mine_ins
check(wait(4000, function()
  for _, r in ipairs(ranges_of('tracked_insert')) do
    if r.text == 'ZZTRACK ' and r.author.user_id == ts.project().me then mine_ins = r end
  end
  return mine_ins ~= nil
end), 'my edit shows as a tracked insertion')
vim.cmd('Taudot track off')
if mine_ins then
  goto_range(mine_ins.id)
  vim.cmd('Taudot reject')
  check(wait(3000, function() return not Buffer.buffer_text(buf):find('ZZTRACK', 1, true) end), 'reject removes my tracked insertion')
end
-- Accept the bot's.
ti = ranges_of('tracked_insert')[1]
if ti then
  goto_range(ti.id)
  local id = ti.id
  vim.cmd('Taudot accept')
  check(wait(3000, function()
    for _, x in ipairs(ranges_of('tracked_insert')) do
      if x.id == id then return false end
    end
    return true
  end), 'accepted change is gone')
end
check(converged(8000), 'converged after review actions')

-- 6. Fades finish.
-- The bot keeps typing, so check that nothing older than the fade is left. It types in bursts (a phrase, then a
-- pause, some rounds a comment or a deletion), so wait for one of its edits to be fading now (up to 8 s) rather
-- than look at one instant, which could fall between bursts (0 live, a flaky failure).
wait(8000, function() return #ui._fading > 0 end)
local stale = 0
for _, f in ipairs(ui._fading) do
  if vim.uv.now() - f.born > require('taudot.config').options.fade_ms + 600 then stale = stale + 1 end
end
check(#ui._fading > 0 and stale == 0, ('author highlights fade out (%d live, %d stale)'):format(#ui._fading, stale))

-- 7. Disk and buffer state.
vim.cmd('silent write')
check(not vim.bo[buf].modified, ':w is handled by taudot')

-- 8. Health check runs.
local ok_h, herr = pcall(vim.cmd, 'checkhealth taudot')
check(ok_h, 'checkhealth taudot runs ' .. tostring(herr or ''))
local health = table.concat(api.nvim_buf_get_lines(0, 0, -1, false), '\n')
check(health:find('engine answers', 1, true) ~= nil, 'health sees the engine')

print(failures == 0 and 'ALL OK' or (failures .. ' FAILED'))
vim.cmd(failures == 0 and 'qa!' or 'cq!')
