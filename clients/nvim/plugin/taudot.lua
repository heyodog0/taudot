if vim.g.loaded_taudot then
  return
end
vim.g.loaded_taudot = true

vim.api.nvim_create_user_command('Taudot', function(opts)
  require('taudot').command(opts)
end, {
  nargs = '*',
  range = true,
  complete = function(arglead, cmdline)
    return require('taudot').complete(arglead, cmdline)
  end,
  desc = 'Taudot: open, status, comments, comment, reply, resolve, accept, reject, track, ...',
})

-- :Texsync, the command's name before the rename (2026-11-04), still works.
vim.api.nvim_create_user_command('Texsync', function(opts)
  require('taudot').command(opts)
end, {
  nargs = '*',
  range = true,
  complete = function(arglead, cmdline)
    return require('taudot').complete(arglead, cmdline:gsub('^(%s*)Texsync', '%1Taudot'))
  end,
  desc = 'Old name of :Taudot',
})

vim.keymap.set('n', '<Plug>(TaudotOpen)', function()
  require('taudot').open(vim.fn.expand('%:p:h'))
end, { desc = 'Taudot: open the project of this file' })
vim.keymap.set('n', '<Plug>(TaudotStatus)', function()
  require('taudot').status()
end, { desc = 'Taudot: status' })
vim.keymap.set('n', '<Plug>(TaudotComments)', function()
  require('taudot').comments()
end, { desc = 'Taudot: comments to quickfix' })
vim.keymap.set('n', '<Plug>(TaudotThread)', function()
  require('taudot').thread()
end, { desc = 'Taudot: comment thread under the cursor' })

-- Review. In visual mode they act on the selection.
local function sub(name)
  return function()
    require('taudot').subcommands[name]({}, nil, nil, false)
  end
end
local map = vim.keymap.set
map('x', '<Plug>(TaudotComment)', ':Taudot comment<CR>', { silent = true, desc = 'Taudot: comment on the selection' })
map('n', '<Plug>(TaudotReply)', sub('reply'), { desc = 'Taudot: reply to the comment here' })
map('n', '<Plug>(TaudotResolve)', sub('resolve'), { desc = 'Taudot: resolve the comment here' })
map('n', '<Plug>(TaudotAccept)', sub('accept'), { desc = 'Taudot: accept the tracked change here' })
map('n', '<Plug>(TaudotReject)', sub('reject'), { desc = 'Taudot: reject the tracked change here' })
map('x', '<Plug>(TaudotAccept)', ':Taudot accept<CR>', { silent = true, desc = 'Taudot: accept tracked changes in the lines' })
map('x', '<Plug>(TaudotReject)', ':Taudot reject<CR>', { silent = true, desc = 'Taudot: reject tracked changes in the lines' })
map('n', '<Plug>(TaudotTrack)', sub('track'), { desc = 'Taudot: track my edits on/off' })

-- SyncTeX link with the PDF preview pane, when taudot-layout.sh started us beside one.
if vim.env.TAUDOT_PREVIEW_SOCKET and vim.env.TAUDOT_PREVIEW_SOCKET ~= '' then
  require('taudot.preview').start()
end
