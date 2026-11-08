-- Run through tests/ce_reconnect.sh.
local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(root)
vim.cmd('runtime plugin/taudot.lua')

local api = vim.api
local ts = require('taudot')
local Buffer = require('taudot.buffer')
local folder, sock, home = vim.env.TAUDOT_FOLDER, vim.env.TAUDOT_SOCKET, vim.env.TAUDOT_HOME
local failures = 0
local function check(cond, what)
  print((cond and 'ok   ' or 'FAIL ') .. what)
  if not cond then failures = failures + 1 end
end
local function wait(ms, f) return vim.wait(ms, f, 20) end
local function count(s, pat)
  local n, i = 0, 1
  while true do
    local j = s:find(pat, i, true)
    if not j then return n end
    n, i = n + 1, j + 1
  end
end

local engine, runs = nil, 0
local function start_engine()
  runs = runs + 1
  engine = vim.system({ vim.env.TAUDOT_ENGINE, 'serve', '--url', vim.env.TAUDOT_URL, '--env-file', vim.env.TAUDOT_ENV_FILE,
    '--user', 'user1', '--home', home }, { stdout = false, stderr = false })
  vim.fn.writefile({ tostring(engine.pid) }, home .. '/../engine.pid')
  return wait(15000, function() return vim.uv.fs_stat(sock) ~= nil end)
end

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

check(start_engine(), 'engine up')
local opened
ts.setup({})
ts.open(folder, function(err) opened = err or true end)
check(wait(30000, function() return opened end) and opened == true, 'project opens: ' .. tostring(opened))
vim.cmd.edit(folder .. '/main.tex')
local buf = api.nvim_get_current_buf()
check(wait(5000, function() return Buffer.by_buf[buf] end), 'main.tex attaches')
local b = Buffer.by_buf[buf]
check(ask({ cmd = 'open', project = vim.env.TAUDOT_PROJECT, file = 'main.tex' }, 120000).ok == true, 'Bob opens main.tex')

-- before \end{document}
local function add_line(s)
  local n = api.nvim_buf_line_count(buf)
  api.nvim_buf_set_lines(buf, n - 1, n - 1, false, { s })
end
local function synced()
  return not b.inflight and not b.pending and b.engine_state and b.engine_state.unconfirmed == 0
end

for round, sig in ipairs({ 9, 2 }) do
  local tag = ('r%d'):format(round)
  add_line(tag .. ' AAA confirmed on Overleaf')
  vim.wait(300)
  check(wait(20000, synced), tag .. ': first edit on Overleaf')
  add_line(tag .. ' BBB just typed')
  vim.wait(80)  -- sent, maybe acknowledged, not on Overleaf yet
  engine:kill(sig)
  engine:wait()
  if sig == 9 then vim.uv.fs_unlink(sock) end
  check(wait(5000, function() return b.project.client == nil end), tag .. ': connection lost (signal ' .. sig .. ')')
  add_line(tag .. ' CCC typed while the engine is down')
  check(ask({ cmd = 'type', pos = 0, text = '% ' .. tag .. ' REMOTE from Bob\n' }, 30000).ok ~= false, tag .. ': Bob types meanwhile')
  check(start_engine(), tag .. ': engine back')
  add_line(tag .. ' DDD typed while reconnecting')
  check(wait(60000, function() return (b.rebases or 0) >= round and synced() end), tag .. ': reconnected, all on Overleaf')
  local r = {}
  for _ = 1, 30 do
    r = ask({ cmd = 'server' }, 10000)
    if r.browser and r.browser:find(tag .. ' DDD', 1, true) then break end
    vim.wait(500)
  end
  local text = r.browser or ''
  for _, w in ipairs({ 'AAA', 'BBB', 'CCC', 'DDD', 'REMOTE' }) do
    check(count(text, tag .. ' ' .. w) == 1, tag .. ': ' .. w .. ' once on Overleaf (' .. count(text, tag .. ' ' .. w) .. ')')
  end
  check(text == Buffer.buffer_text(buf), tag .. ": Neovim's buffer == Overleaf's" .. (text == Buffer.buffer_text(buf) and '' or (': ' .. vim.inspect(text):sub(1, 400))))
  check(not b.error, tag .. ': no error left')
end
ask({ cmd = 'close' })
print(failures == 0 and 'ALL OK' or (failures .. ' FAILED'))
vim.cmd(failures == 0 and 'qa!' or 'cq!')
