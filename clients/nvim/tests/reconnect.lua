-- Run through tests/reconnect.sh.
local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(root)
vim.cmd('runtime plugin/taudot.lua')

local api = vim.api
local ts = require('taudot')
local Buffer = require('taudot.buffer')
local ot = require('taudot.ot')
local folder, sock = vim.env.TAUDOT_FOLDER, vim.env.TAUDOT_SOCKET

local failures = 0
local function check(cond, what)
  print((cond and 'ok   ' or 'FAIL ') .. what)
  if not cond then failures = failures + 1 end
end
local function wait(ms, f) return vim.wait(ms, f, 10) end
local function count(s, pat)
  local n = 0
  for _ in s:gmatch(pat) do n = n + 1 end
  return n
end

-- ---- 0. ot.diff: exact, and as fine as lines ---------------------------------------------------------------------
do
  local bad = 0
  math.randomseed(3)
  local alpha = { 'a', 'b', '\n', 'é', 'xy' }
  local function rnd()
    local t = {}
    for _ = 1, math.random(0, 12) do t[#t + 1] = alpha[math.random(#alpha)] end
    return table.concat(t)
  end
  for _ = 1, 2000 do
    local a, c = rnd(), rnd()
    local op = ot.diff(a, c)
    if op.base ~= #a or ot.apply_string(a, ot.to_edits(op)) ~= c then bad = bad + 1 end
  end
  check(bad == 0, 'ot.diff turns a into b (2000 random pairs)')
  local b0 = 'one\ntwo\nthree\nfour\nfive\n'
  local theirs, ours = ot.diff(b0, 'ONE\ntwo\nthree\nfour\nFIVE\n'), ot.diff(b0, 'one\ntwo\nthree!\nfour\nfive\n')
  local t2 = ot.transform(theirs, ours)
  check(ot.apply_string('one\ntwo\nthree!\nfour\nfive\n', ot.to_edits(t2)) == 'ONE\ntwo\nthree!\nfour\nFIVE\n',
    'ot.diff: an edit between two far-apart changes survives')
  t2 = ot.transform(ot.diff('abc\n', 'aXbc\n'), ot.diff('abc\n', 'abYc\n'))
  check(ot.apply_string('abYc\n', ot.to_edits(t2)) == 'aXbYc\n', 'ot.diff: two edits on one line both kept')
end

-- ---- 1. rebase cases, with a fake engine ------------------------------------------------------------------------
local function fake_buffer(text)
  local buf = api.nvim_create_buf(true, false)
  local lines = vim.split(text, '\n', { plain = true })
  if lines[#lines] == '' then table.remove(lines) end
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].eol = true
  local reply
  local client = { closed = false, sent = {} }
  function client:request(m, p, cb)
    self.sent[#self.sent + 1] = { m = m, p = p }
    if m == 'doc.open' then vim.schedule(function() cb(nil, reply) end)
    elseif m == 'doc.edit' then vim.schedule(function() cb(nil, { seq = p.seq + 1 }) end)
    elseif cb then vim.schedule(function() cb(nil, { seq = reply and reply.seq }) end) end
  end
  local project = { client = client, project_id = 'p', changed = function() end }
  local b = Buffer.new(project, buf, { doc_id = 'd', path = 'x.tex', seq = 7 })
  b:start(text)
  return b, buf, client, function(r) reply = r end
end
local function type_at(buf, row, s)
  local line = api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
  api.nvim_buf_set_lines(buf, row, row + 1, false, { line .. s })
end
local function edits_sent(client)
  for i = #client.sent, 1, -1 do
    if client.sent[i].m == 'doc.edit' then return client.sent[i].p end
  end
end
local base = 'one\ntwo\nthree\nfour\nfive\n'
do
  -- a. typed while away, the server changed elsewhere: both kept, ours sent at the new seq
  local b, buf, client, reply = fake_buffer(base)
  type_at(buf, 2, '!')
  b:settle()
  reply({ doc_id = 'd2', seq = 0, text = 'ONE\ntwo\nthree\nfour\nFIVE\n' })
  local done
  b:rebase(function(e) done = e or true end)
  wait(1000, function() return done end)
  check(done == true and Buffer.buffer_text(buf) == 'ONE\ntwo\nthree!\nfour\nFIVE\n', 'rebase: theirs applied, ours kept: ' .. vim.inspect(Buffer.buffer_text(buf)))
  b:flush()
  local e = edits_sent(client)
  check(e and e.seq == 0 and e.doc_id == 'd2' and ot.apply_string('ONE\ntwo\nthree\nfour\nFIVE\n', e.edits) == Buffer.buffer_text(buf), 'rebase: ours sent at the new seq')
  b:detach()
end
do
  -- b. an edit in flight that the old engine applied before it went: not sent twice
  local b, buf, client, reply = fake_buffer(base)
  type_at(buf, 0, 'X')
  b:settle()
  b.inflight, b.pending = b.pending, nil  -- as if sent, no answer
  type_at(buf, 1, 'Y')
  b:settle()
  reply({ doc_id = 'd', seq = 0, text = 'oneX\ntwo\nthree\nfour\nfive\n' })
  local done
  b:rebase(function(e) done = e or true end)
  wait(1000, function() return done end)
  b:flush()
  local e = edits_sent(client)
  local server = ot.apply_string('oneX\ntwo\nthree\nfour\nfive\n', e and e.edits or {})
  check(server == 'oneX\ntwoY\nthree\nfour\nfive\n', 'rebase: an applied in-flight edit is not sent again: ' .. vim.inspect(server))
  b:detach()
end
do
  -- c. an edit in flight that the old engine never applied: sent
  local b, buf, client, reply = fake_buffer(base)
  type_at(buf, 0, 'X')
  b:settle()
  b.inflight, b.pending = b.pending, nil
  reply({ doc_id = 'd', seq = 0, text = 'zero\n' .. base })
  local done
  b:rebase(function(e) done = e or true end)
  wait(1000, function() return done end)
  b:flush()
  local e = edits_sent(client)
  local server = ot.apply_string('zero\n' .. base, e and e.edits or {})
  check(server == 'zero\noneX\ntwo\nthree\nfour\nfive\n' and Buffer.buffer_text(buf) == server, 'rebase: an unapplied in-flight edit is sent: ' .. vim.inspect(server))
  b:detach()
end
do
  -- d. doc.edit refused (the engine doesn't know our seq): an error shows, then a rebase sends it again
  local b, buf, client, reply = fake_buffer(base)
  reply({ doc_id = 'd', seq = 3, text = base })
  local refused = 0
  local plain = client.request
  function client:request(m, p, cb)
    if m == 'doc.edit' and refused == 0 then
      refused = 1
      self.sent[#self.sent + 1] = { m = m, p = p }
      return vim.schedule(function() cb({ code = -32000, message = 'seq 7 is ahead of the doc (3)' }) end)
    end
    if m == 'doc.edit' then
      self.sent[#self.sent + 1] = { m = m, p = p }
      return vim.schedule(function() cb(nil, { seq = p.seq + 1 }) end)
    end
    return plain(self, m, p, cb)
  end
  local notified
  local orig = vim.notify
  vim.notify = function(msg, lvl) if lvl == vim.log.levels.ERROR then notified = msg end end
  type_at(buf, 4, '?')
  b:settle()
  b:flush()
  wait(1000, function() return b.seq == 4 end)
  vim.notify = orig
  check(notified and notified:find('doc.edit failed', 1, true) ~= nil, 'a refused doc.edit is reported: ' .. tostring(notified))
  local e = edits_sent(client)
  check(b.seq == 4 and e and e.seq == 3 and not b.error, 'then rebased and sent at the engine\'s seq')
  b:detach()
end

do
  -- e. an edit the engine confirmed but never got to Overleaf (killed): sent again; one Overleaf has: not
  local b, buf, client, reply = fake_buffer(base)
  type_at(buf, 0, 'L')  -- lost by the killed engine
  b:settle(); b:flush()
  wait(1000, function() return not b.inflight end)
  type_at(buf, 3, 'K')  -- kept: the engine reports Overleaf has everything after it (doc.state unconfirmed 0)
  b:settle(); b:flush()
  wait(1000, function() return not b.inflight end)
  check(b.unflushed and #b.unflushed == 2, 'acked edits remembered until Overleaf has them')
  reply({ doc_id = 'd', seq = 0, text = base })  -- the new engine: neither
  local done
  b:rebase(function(e) done = e or true end)
  wait(1000, function() return done end)
  b:flush()
  local e = edits_sent(client)
  local server = ot.apply_string(base, e and e.edits or {})
  check(server == 'oneL\ntwo\nthree\nfourK\nfive\n', 'rebase: confirmed edits the server lost are sent again: ' .. vim.inspect(server))
  b:detach()
end

do
  -- f. (E2) a doc.edit really sent, applied by the engine, then the connection closes before the result: the rpc
  -- fails the request with code -1. The reconnect's rebase must count it as applied, not send it again.
  local b, buf, client, reply = fake_buffer(base)
  local held
  local plain = client.request
  function client:request(m, p, cb)
    if m == 'doc.edit' then
      self.sent[#self.sent + 1] = { m = m, p = p }
      held = cb
      return
    end
    return plain(self, m, p, cb)
  end
  type_at(buf, 0, 'X')
  b:settle(); b:flush()
  check(held ~= nil and b.inflight ~= nil, 'E2: edit in flight')
  type_at(buf, 1, 'Y')
  b:settle()
  client.closed = true
  held({ code = -1, message = 'connection closed' })
  -- the reconnect: a new client, the engine has X
  local fresh = { closed = false, sent = {} }
  fresh.request = plain
  b.project.client = fresh
  reply({ doc_id = 'd', seq = 8, text = 'oneX\ntwo\nthree\nfour\nfive\n' })
  local done
  b:rebase(function(e) done = e or true end)
  wait(1000, function() return done end)
  b:flush()
  local e = edits_sent(fresh)
  local server = ot.apply_string('oneX\ntwo\nthree\nfour\nfive\n', e and e.edits or {})
  check(server == 'oneX\ntwoY\nthree\nfour\nfive\n' and Buffer.buffer_text(buf) == server,
    'E2: an applied in-flight edit failed by a closed connection is not doubled: ' .. vim.inspect(server))
  b:detach()
end

do
  -- g. (E3) the engine made the doc read-only (Overleaf keeps refusing an edit): no rebase/resend loop
  local b, buf, client, reply = fake_buffer(base)
  reply({ doc_id = 'd', seq = 7, text = base })
  local plain = client.request
  function client:request(m, p, cb)
    if m == 'doc.edit' then
      self.sent[#self.sent + 1] = { m = m, p = p }
      return vim.schedule(function() cb({ code = -32000, message = 'doc is read-only: Overleaf refused an edit 3 times' }) end)
    end
    return plain(self, m, p, cb)
  end
  local orig = vim.notify
  vim.notify = function() end
  type_at(buf, 2, '#')
  b:settle(); b:flush()
  wait(500, function() return false end)
  vim.notify = orig
  local n = 0
  for _, s in ipairs(client.sent) do n = n + 1 end
  check(n <= 2 and b.error and b.error:find('read-only', 1, true) and b.pending ~= nil,
    'E3: a read-only refusal is shown, edits kept, no loop (' .. n .. ' requests)')
  b:detach()
end

do
  -- h. (E9) a doc.state the engine sent before it had our edit arrives after the edit's result: it must not count
  -- the edit as on Overleaf (a killed engine would lose it, and the rebase would then remove it from the buffer)
  local b, buf, client, reply = fake_buffer(base)
  type_at(buf, 0, 'Z')
  b:settle(); b:flush()
  wait(1000, function() return not b.inflight end)
  check(b.seq == 8 and b.unflushed and #b.unflushed == 1, 'E9: acked edit remembered')
  b:on_state({ doc_id = 'd', state = 'idle', unconfirmed = 0, seq = 7 }) -- stale: from before the edit
  check(b.unflushed and #b.unflushed == 1, 'E9: a stale doc.state keeps it')
  b:on_state({ doc_id = 'd', state = 'idle', unconfirmed = 0, seq = 8 })
  check(b.unflushed == nil, 'E9: a current one clears it')
  reply({ doc_id = 'd', seq = 0, text = base })
  b.unflushed = { base }
  local done
  b:rebase(function(e) done = e or true end)
  wait(1000, function() return done end)
  check(Buffer.buffer_text(buf) == 'oneZ\ntwo\nthree\nfour\nfive\n', 'E9: and a rebase onto an engine without it keeps it')
  b:detach()
end

do
  -- i. (E12) the doc is deleted on Overleaf: the buffer stops syncing (no requests on a dead doc_id), text kept
  local b, buf, client = fake_buffer(base)
  local orig = vim.notify
  vim.notify = function() end
  type_at(buf, 1, '+')
  b:settle()
  b:on_tree({ op = 'removed', type = 'doc', id = 'other', path = 'y.tex' })
  check(not b.detached, 'E12: another doc removed: still attached')
  b:on_tree({ op = 'removed', type = 'doc', id = 'd', path = 'x.tex' })
  vim.notify = orig
  local n = #client.sent
  b:flush()
  type_at(buf, 2, '+')
  wait(300, function() return false end)
  check(b.detached and b.error and b.error:find('deleted', 1, true) and #client.sent == n
    and Buffer.buffer_text(buf) == 'one\ntwo+\nthree+\nfour\nfive\n', 'E12: deleted doc detached, nothing sent, text kept')
end

do
  -- j. (E8) a doc.edit result skips a seq: the change below it was lost (a lagged forwarder) or comes late (after
  -- the engine's 2 s wait). It must not be dropped as already seen: the buffer resyncs and gets it.
  local b, buf, client, reply = fake_buffer(base)
  local plain = client.request
  function client:request(m, p, cb)
    if m == 'doc.edit' then
      self.sent[#self.sent + 1] = { m = m, p = p }
      return vim.schedule(function() cb(nil, { seq = p.seq + 2 }) end) -- seq 8 was a collaborator's, never seen
    end
    return plain(self, m, p, cb)
  end
  reply({ doc_id = 'd', seq = 9, text = 'REMOTE\none!\ntwo\nthree\nfour\nfive\n' })
  local orig = vim.notify
  vim.notify = function() end
  type_at(buf, 0, '!')
  b:settle(); b:flush()
  wait(1000, function() return (b.rebases or 0) > 0 end)
  b:on_changed({ doc_id = 'd', seq = 8, edits = { { pos = 0, del = 0, ins = 'REMOTE\n' } } }) -- the late one
  vim.notify = orig
  check(Buffer.buffer_text(buf) == 'REMOTE\none!\ntwo\nthree\nfour\nfive\n' and b.seq == 9,
    'E8: a skipped seq resyncs, the late change is not applied twice: ' .. vim.inspect(Buffer.buffer_text(buf)))
  -- engine.lagged: every buffer resyncs
  local before = b.rebases
  Buffer.resync_all()
  wait(1000, function() return b.rebases > before end)
  check(b.rebases > before, 'E8: engine.lagged resyncs the buffers')
  b:detach()
end

do
  -- k. (E16) the doc renamed on Overleaf, then a folder above it moved: a rebase reopens it by its new path
  local b, buf, client, reply = fake_buffer(base)
  b:on_tree({ op = 'moved', type = 'doc', id = 'd', from = 'x.tex', path = 'sec/y.tex' })
  b:on_tree({ op = 'moved', type = 'folder', id = 'f', from = 'sec', path = 'parts' })
  b:on_tree({ op = 'moved', type = 'doc', id = 'other', from = 'parts/y.tex', path = 'z.tex' })
  reply({ doc_id = 'd', seq = 7, text = base })
  local done
  b:rebase(function(e) done = e or true end)
  wait(1000, function() return done end)
  local opened
  for _, s in ipairs(client.sent) do
    if s.m == 'doc.open' then opened = s.p.path end
  end
  check(b.path == 'parts/y.tex' and opened == 'parts/y.tex', 'E16: the buffer follows renames: ' .. tostring(b.path) .. ', reopened ' .. tostring(opened))
  b:detach()
end

-- ---- 2. the engine killed and restarted mid-typing (mock) ---------------------------------------------------------
local mock
local function start_mock()
  mock = vim.system({ 'deno', 'run', '-A', vim.env.MOCK_MAIN, '--folder', folder, '--socket', sock, '--latency', '400' })
  return wait(10000, function() return vim.uv.fs_stat(sock) ~= nil end)
end
check(start_mock(), 'mock engine up')
ts.setup({})
vim.cmd.edit(folder .. '/main.tex')
local buf = api.nvim_get_current_buf()
local opened
ts.open(folder, function(err) opened = err or true end)
check(wait(5000, function() return opened end) and opened == true, 'project opens')
check(wait(3000, function() return Buffer.by_buf[buf] end), 'main.tex attaches')
local b = Buffer.by_buf[buf]
local function add_line(s)
  local n = api.nvim_buf_line_count(buf)
  api.nvim_buf_set_lines(buf, n - 1, n - 1, false, { s })
end
add_line('AAA confirmed before the restart')
check(wait(5000, function() return b.seq > 0 and not b.inflight and not b.pending end), 'first edit confirmed')
-- (the mock keeps a confirmed edit by writing its file 300 ms later; the engine, in its backup, replayed on reopen)
check(wait(3000, function() return table.concat(vim.fn.readfile(folder .. '/main.tex'), '\n'):find('AAA', 1, true) ~= nil end), 'first edit on disk')
add_line('BBB in flight when the engine dies')
check(wait(2000, function() return b.inflight ~= nil end), 'second edit in flight')
mock:kill(9)
mock:wait()
vim.uv.fs_unlink(sock)
add_line('CCC typed while the engine is down')
wait(300, function() return false end)
-- a collaborator's edit while we're away: the file (Overleaf's copy, for the next engine) gets a line at the top
local disk = table.concat(vim.fn.readfile(folder .. '/main.tex'), '\n') .. '\n'
vim.fn.writefile(vim.split('% REMOTE line from a collaborator\n' .. disk, '\n', { plain = true }), folder .. '/main.tex', 'b')
check(start_mock(), 'a new engine starts')
add_line('DDD typed while reconnecting')
check(wait(20000, function() return (b.rebases or 0) >= 1 and not b.inflight and not b.pending and b.state ~= 'inflight' end), 'reconnected and caught up')
-- the engine's text, read by a client of our own
local probe
require('taudot.rpc').connect(sock, { on_notify = function() end, on_close = function() end }, function(_, c) probe = c end)
wait(3000, function() return probe end)
local res
probe:request('project.open', { folder = folder }, function()
  probe:request('doc.open', { project_id = 'mock', path = 'main.tex' }, function(_, r) res = r end)
end)
wait(3000, function() return res end)
local server = res and res.text or ''
for _, l in ipairs({ 'AAA', 'BBB', 'CCC', 'DDD', 'REMOTE' }) do
  check(count(server, l) == 1, l .. ' once on the engine')
end
check(server == Buffer.buffer_text(buf), 'buffer == engine')
check(not b.error and not ts.statusline():find('not synced', 1, true), 'no error left on the statusline')
mock:kill(15)
print(failures == 0 and 'ALL OK' or ('FAILED ' .. failures))
vim.cmd(failures == 0 and 'qa!' or 'cq')
