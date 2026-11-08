-- Run through tests/ce_emoji.sh: the real engine on Overleaf CE, Bob in a browser. An emoji typed in Neovim must end
-- up as two U+FFFD everywhere (docs/protocol.md, Astral characters), with Neovim's buffer matching Overleaf's.
local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(root)
vim.cmd('runtime plugin/taudot.lua')

local api = vim.api
local ts = require('taudot')
local Buffer = require('taudot.buffer')
local folder = vim.env.TAUDOT_FOLDER
local failures = 0
local function check(cond, what)
  print((cond and 'ok   ' or 'FAIL ') .. what)
  if not cond then failures = failures + 1 end
end
local function wait(ms, f) return vim.wait(ms, f, 20) end

local replies, partial = {}, ''
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
})
local function ask(cmd, ms)
  local n = #replies
  bob:write(vim.json.encode(cmd) .. '\n')
  wait(ms or 60000, function() return #replies > n end)
  return replies[n + 1] or {}
end

local opened
ts.setup({})
ts.open(folder, function(err) opened = err or true end)
check(wait(30000, function() return opened end) and opened == true, 'project opens: ' .. tostring(opened))
vim.cmd.edit(folder .. '/main.tex')
local buf = api.nvim_get_current_buf()
check(wait(5000, function() return Buffer.by_buf[buf] end), 'main.tex attaches')
local b = Buffer.by_buf[buf]
check(ask({ cmd = 'open', project = vim.env.TAUDOT_PROJECT, file = 'main.tex' }, 120000).ok == true, 'Bob opens main.tex')

-- Type "x😀y é" at the end of line 7 (\maketitle), as on_bytes sees typing.
local line = api.nvim_buf_get_lines(buf, 6, 7, false)[1]
api.nvim_buf_set_text(buf, 6, #line, 6, #line, { ' x😀y é' })
local fffd = '\u{FFFD}\u{FFFD}'
local want = line .. ' x' .. fffd .. 'y é'
check(wait(15000, function() return api.nvim_buf_get_lines(buf, 6, 7, false)[1] == want end),
  'the buffer gets the replacement back: ' .. vim.inspect(api.nvim_buf_get_lines(buf, 6, 7, false)[1]))
check(wait(15000, function() return b.state == 'idle' and b:unconfirmed() == 0 end), 'edits confirmed')
-- Keep typing after it: positions must still agree.
api.nvim_buf_set_text(buf, 6, #want, 6, #want, { ' z' })
check(wait(15000, function() return b.state == 'idle' and b:unconfirmed() == 0 end), 'later edit confirmed')
-- The engine batches edits like the browser (up to 2 s): poll Overleaf until it has them.
local r = {}
for _ = 1, 30 do
  r = ask({ cmd = 'server' }, 10000)
  if r.browser and r.browser:find(' z', 1, true) then break end
  vim.wait(500)
end
local text = Buffer.buffer_text(buf)
check(r.browser == text, "Neovim's buffer == Overleaf's editor" .. (r.browser == text and '' or (': ' .. vim.inspect(r.browser))))
check(r.browser and r.browser:find(' x' .. fffd .. 'y é z', 1, true) ~= nil, 'Overleaf has the U+FFFD pair')
ask({ cmd = 'close' })
print(failures == 0 and 'ALL OK' or (failures .. ' FAILED'))
vim.cmd(failures == 0 and 'qa!' or 'cq!')
