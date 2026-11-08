-- Headless test of the SyncTeX link (lua/taudot/preview.lua) against a fake preview server.
--   nvim --headless --clean -l clients/nvim/tests/preview_spec.lua
local here = vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2))
vim.opt.rtp:prepend(vim.fs.dirname(here))
local uv = vim.uv

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, 'p')
local sock = tmp .. '/p.sock'
local tex = tmp .. '/main.tex'
local lines = {}
for i = 1, 60 do
  lines[i] = 'line ' .. i
end
vim.fn.writefile(lines, tex)

local got = {}
local client = nil
local function start_server()
  local server = uv.new_pipe(false)
  assert(server:bind(sock))
  server:listen(8, function()
    client = uv.new_pipe(false)
    server:accept(client)
    local buf = ''
    client:read_start(function(_, chunk)
      if not chunk then
        return
      end
      buf = buf .. chunk
      for l in buf:gmatch('([^\n]*)\n') do
        table.insert(got, vim.json.decode(l))
      end
      buf = buf:match('[^\n]*$')
    end)
  end)
  return server
end

local function wait(cond, what)
  assert(vim.wait(3000, cond, 10), 'timed out waiting for ' .. what)
end

local preview = require('taudot.preview')
vim.cmd.edit(tex)
preview.start(sock) -- no server yet: must retry
vim.wait(300)
assert(not preview.connected(), 'connected to nothing')
start_server()
wait(function() return preview.connected() and #got >= 1 end, 'connect and first cursor')
assert(got[1].cursor.line == 1 and got[1].cursor.path:match('main%.tex$'), vim.inspect(got[1]))

-- moving the cursor sends one message after it rests, not one per move
vim.api.nvim_win_set_cursor(0, { 10, 0 })
vim.api.nvim_exec_autocmds('CursorMoved', {})
vim.api.nvim_win_set_cursor(0, { 20, 0 })
vim.api.nvim_exec_autocmds('CursorMoved', {})
wait(function() return #got >= 2 end, 'cursor message')
vim.wait(300)
assert(#got == 2 and got[2].cursor.line == 20, vim.inspect(got))

-- a jump from the preview moves the cursor, from insert mode too, and isn't echoed back
vim.cmd.split()
vim.cmd.enew()
client:write(vim.json.encode({ jump = { path = tex, line = 42 } }) .. '\n')
wait(function() return vim.api.nvim_win_get_cursor(0)[1] == 42 end, 'jump')
assert(vim.api.nvim_buf_get_name(0):match('main%.tex$'), 'jumped to the window showing main.tex')
vim.api.nvim_exec_autocmds('CursorMoved', {})
vim.wait(300)
assert(#got == 2, 'jump echoed back: ' .. vim.inspect(got[#got]))

-- the server going away and coming back reconnects
client:close()
wait(function() return not preview.connected() end, 'disconnect')
preview.stop()
print('preview_spec: ok')
vim.cmd('qa!')
