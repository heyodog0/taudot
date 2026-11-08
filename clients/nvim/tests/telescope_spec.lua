-- The Telescope pickers against the mock engine (run by tests/run.sh when Telescope and plenary are found).
local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(root)
vim.opt.rtp:append(vim.env.TELESCOPE_DIR)
vim.opt.rtp:append(vim.env.PLENARY_DIR)
vim.cmd('runtime plugin/taudot.lua')
vim.o.termguicolors = true

local api = vim.api
local ts = require('taudot')
local Buffer = require('taudot.buffer')
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

ts.setup({})
-- Headless is 80 columns: show the preview anyway.
require('telescope').setup({ defaults = { layout_config = { preview_cutoff = 1 } } })
vim.cmd.edit(folder .. '/main.tex')
local buf = api.nvim_get_current_buf()
local opened
ts.open(folder, function(err) opened = err or true end)
check(wait(3000, function() return opened end) and opened == true, 'project opens')
check(wait(2000, function() return Buffer.by_buf[buf] end), 'main.tex attaches')
local b = Buffer.by_buf[buf]
check(wait(8000, function()
  for _, r in ipairs(b.ranges) do
    if r.kind == 'comment' and not r.resolved then return true end
  end
end), 'an open comment')

local action_state = require('telescope.actions.state')
local function prompt()
  for _, w in ipairs(api.nvim_list_wins()) do
    local bb = api.nvim_win_get_buf(w)
    if vim.bo[bb].filetype == 'TelescopePrompt' then return bb end
  end
end
vim.cmd('Taudot comments')
check(wait(3000, function() return prompt() ~= nil end), ':Taudot comments opens Telescope')
local pb = prompt()
local picker = pb and action_state.get_current_picker(pb)
check(wait(3000, function() return picker and picker.manager and picker.manager:num_results() > 0 end), 'it lists the threads')
local e
wait(2000, function() e = action_state.get_selected_entry(); return e ~= nil end)
check(e and e.value.kind == 'comment', 'entries are threads')
local prev = picker and picker.previewer and picker.previewer.state and picker.previewer.state.bufnr
local plines = {}
wait(2000, function()
  prev = picker.previewer.state and picker.previewer.state.bufnr
  plines = prev and api.nvim_buf_get_lines(prev, 0, -1, false) or {}
  return #plines > 2
end)
local ptext = table.concat(plines, '\n')
check(ptext:find('main.tex:', 1, true) and ptext:find('Comment on', 1, true) and not ptext:find('**', 1, true), 'preview: the file, then the thread')
-- <C-e> resolves the selected thread.
local tid = e and e.value.thread_id
api.nvim_feedkeys(api.nvim_replace_termcodes('<C-e>', true, false, true), 'x', false)
check(wait(3000, function()
  local t = ts.project().threads[tid]
  return t and t.resolved
end), '<C-e> resolves it')
require('taudot.review').set_resolved({ thread_id = tid }, b.doc_id, false)
wait(2000, function() return not ts.project().threads[tid].resolved end)
require('telescope.actions').close(pb)

print(failures == 0 and 'ALL OK' or (failures .. ' FAILED'))
vim.cmd(failures == 0 and 'qa!' or 'cq!')
