-- nvim --headless --clean -l tests/connect_spec.lua
-- E15 (docs/state-machines.md): the project's connect has a generation. A connect (or its client's close) from before
-- a :Taudot close / reopen / reconnect must not touch the project that replaced it. rpc.connect is stubbed: each test
-- completes the connects by hand, in the order it wants.
vim.opt.rtp:prepend(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h'))
vim.cmd('runtime plugin/taudot.lua')

local rpc = require('taudot.rpc')
local ts = require('taudot')
local failures = 0
local function check(cond, what)
  print((cond and 'ok   ' or 'FAIL ') .. what)
  if not cond then failures = failures + 1 end
end
local function wait(ms, f) return vim.wait(ms, f or function() return false end, 10) end

local pending = {}
local clients = {}
rpc.connect = function(_, handlers, cb)
  pending[#pending + 1] = { handlers = handlers, cb = cb }
end
local function fake_client(handlers, project_id)
  local c = { closed = false, sent = {} }
  function c:request(m, p, cb)
    self.sent[#self.sent + 1] = m
    if self.closed then
      if cb then cb({ code = -1, message = 'not connected' }) end
      return
    end
    local res = ({
      ['engine.info'] = { instance = 'i1' },
      ['project.open'] = { project_id = project_id, docs = {}, me = { user_id = 'u1' }, folder = p and p.folder },
      ['project.status'] = { connection = 'online', users = {} },
    })[m] or {}
    if cb then vim.schedule(function() cb(nil, res) end) end
  end
  function c:close()
    if self.closed then return end
    self.closed = true
    handlers.on_close(nil)
  end
  clients[#clients + 1] = c
  return c
end
local function complete(i, project_id, err)
  local p = pending[i]
  if err then return p.cb(err) end
  p.cb(nil, fake_client(p.handlers, project_id))
end

ts.setup({ reconnect = true })
local orig = vim.notify
vim.notify = function() end

-- a. open f1 (connect slow), close, open f2; f2's connect lands, then f1's fails: f2's project must stay.
local r1, r2
ts.open('/tmp/tdsm-f1', function(e) r1 = e or true end)
ts.close()
ts.open('/tmp/tdsm-f2', function(e) r2 = e or true end)
check(#pending == 2, 'two connects pending')
complete(2, 'p2')
wait(200, function() return r2 end)
complete(1, nil, 'ECONNREFUSED')
wait(100)
local p = ts.project()
check(r2 == true and p ~= nil and p.folder == '/tmp/tdsm-f2' and p.project_id == 'p2',
  'E15: a stale connect failing leaves the new project alone: ' .. vim.inspect(p and { p.folder, p.project_id }))

-- b. the old project's client closing late doesn't take the new project's client away
ts.close()
pending = {}
local r3
ts.open('/tmp/tdsm-f3', function(e) r3 = e or true end)
complete(1, 'p3')
wait(200, function() return r3 end)
local c3 = ts.project().client
ts.reconnect() -- closes c3 (as :Taudot reconnect does), connects again
complete(2, 'p3')
wait(200, function() return ts.project().client ~= c3 end)
local c4 = ts.project().client
-- c3's pipe reports its close again, late (EOF after the explicit close)
pending[1].handlers.on_close('engine closed the connection')
wait(100)
check(ts.project().client == c4 and ts.project().connection ~= 'offline', 'E15: a stale client close keeps the live client')

-- d. (E17) the engine goes: nobody is shown as here
ts.project().users = { { user_id = 'u2', name = 'Bob' } }
local live = ts.project().client
live:close()
check(#ts.project().users == 0 and ts.project().connection == 'offline', 'E17: presence cleared when the engine goes')

-- c. a connect that lands after :Taudot close is closed, not adopted
ts.close()
pending = {}
ts.open('/tmp/tdsm-f5', function() end)
ts.close()
complete(1, 'p5')
wait(100)
check(ts.project() == nil and clients[#clients].closed, 'E15: a connect landing after close is closed')

vim.notify = orig
print(failures == 0 and 'ALL OK' or ('FAILED ' .. failures))
vim.cmd(failures == 0 and 'qa!' or 'cq')
