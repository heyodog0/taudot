-- Run through tests/ce_review.sh: the real engine on Overleaf CE, Bob in a browser.
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
  return vim.wait(ms, f, 20)
end
local function finish()
  print(failures == 0 and 'ALL OK' or (failures .. ' FAILED'))
  vim.cmd(failures == 0 and 'qa!' or 'cq!')
end

-- Bob's process: JSON lines both ways.
local replies = {}
local partial = ''
local bob = vim.system(vim.split(vim.env.TAUDOT_BOB, ' '), {
  stdin = true,
  cwd = root .. '/../../harness',
  stdout = function(_, data)
    if not data then return end
    partial = partial .. data
    while true do
      local nl = partial:find('\n')
      if not nl then break end
      replies[#replies + 1] = vim.json.decode(partial:sub(1, nl - 1))
      partial = partial:sub(nl + 1)
    end
  end,
  stderr = function(_, data)
    if data then io.stderr:write(data) end
  end,
})
local function ask(cmd, ms)
  local n = #replies
  bob:write(vim.json.encode(cmd) .. '\n')
  wait(ms or 30000, function() return #replies > n end)
  local r = replies[n + 1]
  if not r or not r.ok then
    print('bob ' .. cmd.cmd .. ' failed: ' .. vim.inspect(r))
  end
  return r or {}
end

-- 1. Neovim opens the project through the engine, which mirrors it into the folder.
local opened
ts.setup({})
ts.open(folder, function(err) opened = err or true end)
check(wait(30000, function() return opened end) and opened == true, 'project opens: ' .. tostring(opened))
vim.cmd.edit(folder .. '/main.tex')
local buf = api.nvim_get_current_buf()
check(wait(5000, function() return Buffer.by_buf[buf] end), 'main.tex attaches')
local b = Buffer.by_buf[buf]
if not b then return finish() end
local function text() return Buffer.buffer_text(buf) end
-- UTF-16 index of a byte offset in the buffer (the test text is ASCII up to where we look, but be exact).
local function u16(byte) return vim.str_utfindex(text(), 'utf-16', byte) end

-- 2. Bob opens the doc in the browser; his cursor shows up in Neovim with his initials.
local r = ask({ cmd = 'open', project = vim.env.TAUDOT_PROJECT, file = 'main.tex' }, 180000)
check(r.ok, 'Bob opens the project in the browser')
if not r.ok then
  return finish()
end
local target = text():find('\\begin{document}', 1, true)
ask({ cmd = 'cursor', pos = u16(target - 1) })
check(wait(10000, function()
  for _, m in ipairs(api.nvim_buf_get_extmarks(buf, ui.ns.cursor, 0, -1, { details = true })) do
    local vt = m[4].virt_text
    if vt and vt[1][1]:find('B', 1, true) then return true end
  end
end), "Bob's cursor is drawn with his initials")
local cm = api.nvim_buf_get_extmarks(buf, ui.ns.cursor, 0, -1, { details = true })[1]
local want_row = select(1, Buffer.pos_to_rc(buf, target - 1))
check(cm and cm[2] == want_row and cm[3] == 0, ('at the right place (row %s, want %d)'):format(cm and cm[2], want_row))

-- 3. Bob types; it appears.
ask({ cmd = 'type', pos = u16(target - 1), text = 'Bob was here. ' })
check(wait(10000, function() return text():find('Bob was here. ', 1, true) ~= nil end), "Bob's typing appears")

-- history-ot (ce_review.sh --history-ot): tracked changes have no server IDs, and accepting is an op, so it works on CE.
local hot = vim.env.TAUDOT_HISTORY_OT == '1'
local function server_changes(s, kind)
  local out = {}
  if hot then
    for _, ch in ipairs(s.ranges and s.ranges.trackedChanges or {}) do
      if ch.tracking.type == kind then
        out[#out + 1] = { text = s.text:sub(ch.range.pos + 1, ch.range.pos + ch.range.length), user = ch.tracking.userId }
      end
    end
  else
    for _, ch in ipairs(s.ranges and s.ranges.changes or {}) do
      if (kind == 'insert' and ch.op.i) or (kind == 'delete' and ch.op.d) then
        out[#out + 1] = { text = ch.op.i or ch.op.d, user = ch.metadata.user_id, id = ch.id }
      end
    end
  end
  return out
end

-- 4. A comment range from Bob (raw socket: CE's editor has no review panel).
local word_at = text():find('\\section', 1, true) or text():find('\\maketitle', 1, true)
ask({ cmd = 'comment', pos = u16(word_at - 1), len = 8, thread = 'abcdefabcdefabcdef000001' })
local function ranges_of(kind)
  return vim.tbl_filter(function(x) return x.kind == kind end, b.ranges or {})
end
check(wait(10000, function() return #ranges_of('comment') == 1 end), "Bob's comment range arrives")
local c = ranges_of('comment')[1]
check(c and c.text == text():sub(word_at, word_at + 7), 'over the right text: ' .. (c and c.text or '?'))
check(c and c.author and c.author.name == 'Bob', 'by Bob')
local function has_mark(group)
  for _, m in ipairs(api.nvim_buf_get_extmarks(buf, ui.ns.comment, 0, -1, { details = true })) do
    if m[4].hl_group == group or (m[4].virt_text and m[4].virt_text[1][2] == group) then return m end
  end
end
check(has_mark('TaudotComment') ~= nil, 'drawn as a comment, with a sign')

-- 5. Tracked changes from Bob: an insertion and a deletion.
local ins_at = text():find('\\maketitle', 1, true)
ask({ cmd = 'track_insert', pos = u16(ins_at - 1), text = 'NEWTEXT ', tc = 'aaaaaaaaaaaaaaaaaa' })
check(wait(10000, function() return #ranges_of('tracked_insert') == 1 end), "Bob's tracked insertion arrives")
local ti = ranges_of('tracked_insert')[1]
check(ti and (hot or ti.id == 'aaaaaaaaaaaaaaaaaa000001') and ti.author.name == 'Bob', 'with the server change ID, by Bob')
local idx = ui.author_index(ti and ti.author)
check(has_mark('TaudotTrackedInsert' .. idx) ~= nil, 'drawn in his colour')
local del_at = text():find('Bob was here', 1, true)
local d = ask({ cmd = 'track_delete', pos = u16(del_at - 1), len = 4, tc = 'bbbbbbbbbbbbbbbbbb' })
check(wait(10000, function() return #ranges_of('tracked_delete') == 1 end), "Bob's tracked deletion arrives")
local td = ranges_of('tracked_delete')[1]
check(td and td.text == d.deleted and not text():find('Bob was here', 1, true), 'text gone, kept as the deletion: ' .. tostring(td and td.text))
local dm = has_mark('TaudotTrackedDelete' .. idx)
check(dm and dm[4].virt_text[1][1] == d.deleted, 'shown inline, struck through')

-- 6. K on them.
local function goto_range(id)
  for _, m in ipairs(api.nvim_buf_get_extmarks(buf, ui.ns.comment, 0, -1, {})) do
    local x = b.comments[m[1]]
    if x and x.id == id then
      api.nvim_win_set_cursor(0, { m[2] + 1, m[3] })
      return true
    end
  end
end
goto_range(ti.id)
local lines = table.concat(ui.review_lines(b:ranges_here(), ts.project().threads), '\n')
check(lines:find('**Inserted** by Bob', 1, true) ~= nil, 'K: inserted by Bob')
goto_range(c.id)
lines = table.concat(ui.review_lines(b:ranges_here(), ts.project().threads), '\n')
check(lines:find('no comment threads', 1, true) ~= nil, 'K on the comment says CE has no threads')

-- 7. Reject Bob's deletion from Neovim: the text comes back for everyone.
goto_range(td.id)
vim.cmd('Taudot reject')
check(wait(10000, function() return text():find('Bob was here', 1, true) ~= nil end), 'reject puts the text back here')
local live
check(wait(10000, function()
  local s = ask({ cmd = 'server' })
  live = s.browser
  return #server_changes(s, 'delete') == 0 and s.text and s.text:find('Bob was here', 1, true) ~= nil
end), 'and on the server, the deletion gone')
if live and live:find('Bob was here', 1, true) then
  check(true, "and in Bob's browser")
elseif hot then
  -- CE 6.3's editor doesn't show text whose tracked deletion was cleared until it reloads (observed).
  local r2 = ask({ cmd = 'reopen', project = vim.env.TAUDOT_PROJECT, file = 'main.tex' }, 120000)
  check(r2.browser and r2.browser:find('Bob was here', 1, true) ~= nil, "in Bob's browser after a reload (CE's editor misses it live)")
else
  check(false, "and in Bob's browser")
end

-- 8. Accepting fails clearly on CE.
local msgs = {}
local orig = vim.notify
vim.notify = function(m, ...) msgs[#msgs + 1] = m; return orig(m, ...) end
goto_range(ti.id)
vim.cmd('Taudot accept')
if hot then
  check(wait(10000, function()
    local s = ask({ cmd = 'server' })
    return #server_changes(s, 'insert') == 0 and s.text:find('NEWTEXT', 1, true) ~= nil
  end), 'accept works on CE for history-ot (an op): the insertion stays, untracked')
  check(wait(5000, function() return #ranges_of('tracked_insert') == 0 end), 'and its mark goes here')
else
  check(wait(5000, function() return #msgs > 0 end) and msgs[#msgs]:find("can't accept", 1, true) ~= nil, 'accept on CE says why not: ' .. tostring(msgs[#msgs]))
end

-- 9. Commenting from Neovim fails clearly on CE.
api.nvim_win_set_cursor(0, { 1, 0 })
vim.cmd('normal! vll\27')
vim.cmd("'<,'>Taudot comment hello")
check(wait(5000, function() return msgs[#msgs]:find('no comment threads', 1, true) ~= nil end), 'comment on CE says why not: ' .. tostring(msgs[#msgs]))
vim.notify = orig

-- 10. My own tracked edit reaches the server as a tracked change, by me.
vim.cmd('Taudot track on')
local row = select(1, Buffer.pos_to_rc(buf, text():find('\\maketitle', 1, true) - 1))
api.nvim_win_set_cursor(0, { row + 1, 0 })
vim.cmd('normal! IALICE ')
check(wait(15000, function()
  local s = ask({ cmd = 'server' })
  for _, ch in ipairs(server_changes(s, 'insert')) do
    if ch.text == 'ALICE ' and ch.user == ts.project().me then return true end
  end
end), 'my edit is a tracked change on the server, by me')
check(wait(5000, function()
  for _, x in ipairs(ranges_of('tracked_insert')) do
    if x.text == 'ALICE ' then return true end
  end
end), 'and shows here as mine')
vim.cmd('Taudot track off')

-- 11. Everyone agrees.
check(wait(10000, function()
  local s = ask({ cmd = 'server' })
  return s.text == text():gsub('\n$', '') or s.text == text()
end), 'Neovim and the server have the same text')

ask({ cmd = 'close' })
finish()
