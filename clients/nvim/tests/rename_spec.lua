-- nvim --headless --clean -l tests/rename_spec.lua
-- The names from before the rename to Taudot (2026-11-04) still work: require('texsync'), require('texsync.<x>'),
-- :Texsync, TEXSYNC_* variables.
vim.opt.rtp:prepend(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h'))
vim.cmd('runtime plugin/taudot.lua')
vim.env.TEXSYNC_PROBE = 'x'
assert(require('texsync') == require('taudot'), 'require texsync')
assert(require('texsync.ot') == require('taudot.ot'), 'require texsync.ot')
assert(vim.env.TAUDOT_PROBE == 'x', 'TEXSYNC_* read as TAUDOT_*')
assert(vim.fn.exists(':Texsync') == 2 and vim.fn.exists(':Taudot') == 2, ':Texsync and :Taudot')
print('rename ok')
