-- nvim --headless --clean -l tests/outside_spec.lua
-- Outside edits (editfix item 9): a remote edit's inserted text is tinted and a deletion's place marked, both fading;
-- an edit made on disk (the engine's `source: "disk"`) gets the disk colour (author index 0); the Mac app's
-- `taudot.app` hears each one (`outside`) after the text, with the edits in the buffer's text.
vim.opt.rtp:prepend(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h'))
vim.cmd('runtime plugin/taudot.lua')
require('taudot').setup({ fade_ms = 600 })

local api = vim.api
local buffer = require('taudot.buffer')
local ui = require('taudot.ui')
local failures = 0
local function check(cond, what)
  if not cond then
    print('FAIL ' .. what)
    failures = failures + 1
  end
  return cond
end
vim.notify = function() end

local heard = {}
package.loaded['taudot.app'] = {
  text = function() end,
  text_released = function() end,
  outside = function(b, edits, author, origin, source)
    heard[#heard + 1] = { path = b.path, edits = edits, author = author, origin = origin, source = source, text = b.text }
  end,
}
local client = { closed = false }
function client:request(_, _, cb) if cb then vim.schedule(function() cb(nil, {}) end) end end
local project = { client = client, project_id = 'p', folder = '/tmp', changed = function() end }

local buf = api.nvim_create_buf(true, false)
api.nvim_buf_set_name(buf, '/tmp/outside-spec.tex')
api.nvim_set_current_buf(buf)
local b = buffer.new(project, buf, { doc_id = 'd', path = 'main.tex', seq = 0 })
b:start('hello world\nsecond line here\n')

local function marks()
  local out = {}
  for _, m in ipairs(api.nvim_buf_get_extmarks(buf, ui.ns.author, 0, -1, { details = true })) do
    out[#out + 1] = { row = m[2], col = m[3], end_row = m[4].end_row, end_col = m[4].end_col, hl = m[4].hl_group }
  end
  return out
end

-- a disk edit: an insert on line 1 and a delete on line 2
b:on_changed({ seq = 1, origin = 'local', source = 'disk', author = { user_id = 'me' },
  edits = { { pos = 6, del = 0, ins = 'brave ' }, { pos = 25, del = 5, ins = '' } } })
check(buffer.buffer_text(buf) == 'hello brave world\nsecond here\n', 'the edit applied: ' .. buffer.buffer_text(buf))
local m = marks()
local ins, del
for _, x in ipairs(m) do
  if x.hl:match('^TaudotFade') then ins = x elseif x.hl:match('^TaudotDeleted') then del = x end
end
check(ins and ins.hl == 'TaudotFade0_1' and ins.row == 0 and ins.col == 6 and ins.end_col == 12,
  'the inserted text tinted in the disk colour: ' .. vim.inspect(ins))
check(del and del.hl == 'TaudotDeleted0_1' and del.row == 1 and del.col == 6 and del.end_col == 8,
  'the deletion\'s place marked in the disk colour: ' .. vim.inspect(del))
check(#heard == 1 and heard[1].source == 'disk' and heard[1].path == 'main.tex' and #heard[1].edits == 2
  and heard[1].text == buffer.buffer_text(buf), 'the app heard it after the text: ' .. vim.inspect(heard))

-- a collaborator's edit: their own colour, not the disk one
b:on_changed({ seq = 2, origin = 'remote', author = { user_id = 'u2', name = 'Bo' }, edits = { { pos = 0, del = 0, ins = 'Oh ' } } })
local co
for _, x in ipairs(marks()) do
  if x.row == 0 and x.col == 0 and x.hl:match('^TaudotFade') then co = x end
end
check(co and co.hl ~= 'TaudotFade0_1' and co.hl:match('_1$'), 'a collaborator\'s insert in their colour: ' .. vim.inspect(co))
check(#heard == 2 and heard[2].origin == 'remote' and heard[2].source == nil, 'the app heard the collaborator\'s too')

-- all of it fades
vim.wait(1500, function() return #marks() == 0 end, 20)
check(#marks() == 0, 'faded: ' .. vim.inspect(marks()))
check(api.nvim_get_hl(0, { name = 'TaudotDeleted0_1' }).underdouble == true, 'the deletion mark is a double underline')

b:detach()
print(failures == 0 and 'ok   outside: disk edits tinted in their colour, deletions marked, both fade; the app hears them' or ('FAIL ' .. failures))
vim.cmd(failures == 0 and 'qa!' or 'cq!')
