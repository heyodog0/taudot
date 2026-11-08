-- nvim --headless --clean -l tests/pdffeed_spec.lua
-- pdfpipe: every change to a doc's text in the buffer (taudot.buffer's text_changed) reaches the app's PDF pane, in
-- order, so the pane's copy equals the buffer after every step: typing, undo, remote edits transformed past ours in
-- flight and pending, acks, a rebase. The app is faked as package.loaded['taudot.app'], keeping that copy.
vim.opt.rtp:prepend(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h'))
vim.cmd('runtime plugin/taudot.lua')

local api = vim.api
local buffer = require('taudot.buffer')
local ot = require('taudot.ot')
local failures = 0
local function check(cond, what)
  if not cond then
    print('FAIL ' .. what)
    failures = failures + 1
  end
  return cond
end
vim.notify = function() end

-- the app: its copy of each doc, from the hook alone
local copy, released = {}, {}
package.loaded['taudot.app'] = {
  text = function(b, edits, text) -- as the Mac app's taudot.app
    if edits then
      copy[b.path] = ot.apply_string(copy[b.path], edits)
    else
      copy[b.path] = text or b.text
    end
  end,
  text_released = function(b) released[b.path] = true end,
}

-- the engine: doc.edit answered when the test says; doc.open (a rebase) gives `server_text`
local edit_cbs, server_text = {}, nil
local client = { closed = false }
function client:request(m, p, cb)
  if m == 'doc.edit' then
    edit_cbs[#edit_cbs + 1] = cb
  elseif m == 'doc.open' then
    vim.schedule(function() cb(nil, { doc_id = 'd', text = server_text, seq = 100 }) end)
  elseif cb then
    vim.schedule(function() cb(nil, {}) end)
  end
end
local project = { client = client, project_id = 'p', folder = '/tmp', changed = function() end }

local function random_edit(text)
  local starts = {}
  for i = 0, #text do
    local c = text:byte(i + 1)
    if not c or c < 0x80 or c >= 0xC0 then starts[#starts + 1] = i end
  end
  local a = starts[math.random(#starts)]
  local bs = {}
  for _, s in ipairs(starts) do
    if s >= a and s <= a + 6 then bs[#bs + 1] = s end
  end
  local b = bs[math.random(#bs)]
  local ins = ({ '', 'x', 'é', '🙂', 'ab\n', '\\emph{y}' })[math.random(6)]
  return { pos = a, del = b - a, ins = ins }
end

math.randomseed(tonumber(os.getenv('SEED') or '') or os.time())
for round = 1, 15 do
  local buf = api.nvim_create_buf(true, false)
  api.nvim_buf_set_name(buf, '/tmp/pdffeed-' .. round .. '.tex')
  api.nvim_set_current_buf(buf)
  local b = buffer.new(project, buf, { doc_id = 'd', path = 'main.tex', seq = 0 })
  b:start('\\section{Intro}\nhello wörld\n')
  check(copy['main.tex'] == b.text, 'round ' .. round .. ': the first text')
  edit_cbs = {}
  for step = 1, 80 do
    local r = math.random(10)
    if r <= 4 then -- typing
      local e = random_edit(buffer.buffer_text(buf))
      local sr, sc = buffer.pos_to_rc(buf, e.pos)
      local er, ec = buffer.pos_to_rc(buf, e.pos + e.del)
      api.nvim_buf_set_text(buf, sr, sc, er, ec, vim.split(e.ins, '\n', { plain = true }))
    elseif r == 5 then -- undo
      pcall(vim.cmd, 'silent! undo')
    elseif r <= 7 then -- a collaborator's edit on the engine's text at its seq
      b:settle()
      local e = random_edit(b.base or b.text)
      b:on_changed({ seq = b.seq + 1, edits = { e } })
    elseif r <= 9 then -- the engine confirms ours in flight
      local cb = table.remove(edit_cbs, 1)
      if cb then cb(nil, { seq = b.seq + 1 }) end
    else -- a reconnect's rebase onto the engine's text with a collaborator's edit
      b:settle()
      local e = random_edit(b.base or b.text)
      server_text = ot.apply_string(b.base or b.text, { e })
      edit_cbs = {}
      b.inflight = nil -- the engine never got it (else the rebase picks the closest base: also fine)
      local done = false
      b:rebase(function() done = true end)
      vim.wait(500, function() return done or not b.rebasing end, 5)
    end
    vim.wait(30, function() return not b.settle_scheduled end, 2)
    b:settle()
    if not check(copy['main.tex'] == buffer.buffer_text(buf), ('round %d step %d (%d): app %q buffer %q'):format(
        round, step, r, copy['main.tex'] or '', buffer.buffer_text(buf))) then
      break
    end
  end
  b:detach()
  check(released['main.tex'], 'round ' .. round .. ': released at detach')
  released = {}
  api.nvim_buf_delete(buf, { force = true })
end

print(failures == 0 and 'ok   pdffeed: the app\'s copy equals the buffer after every step' or ('FAIL ' .. failures))
vim.cmd(failures == 0 and 'qa!' or 'cq!')
