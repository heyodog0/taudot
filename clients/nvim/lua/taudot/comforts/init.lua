-- Overleaf's editing comforts in Neovim: completion from the engine (complete.lua), \begin auto-close and rename
-- (envs.lua), Cmd-/ comments (comment.lua) and folding (fold.lua). All behind config.options.comforts (on unless set
-- to false). The plugin's attach calls M.attach(buf, b) once a buffer is synced; everything but completion also
-- works on a plain .tex buffer with b = nil.

local M = {}

function M.enabled()
  return require('taudot.config').options.comforts ~= false
end

local function highlights()
  vim.api.nvim_set_hl(0, 'TaudotCompleteKind', { link = 'Comment', default = true })
  vim.api.nvim_set_hl(0, 'TaudotFoldCount', { link = 'Comment', default = true })
end

---@param buf integer
---@param b table?  taudot.buffer of a synced doc
function M.attach(buf, b)
  if not M.enabled() or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  if not vim.b[buf].taudot_comforts then
    vim.b[buf].taudot_comforts = true
    highlights()
    require('taudot.comforts.comment').attach(buf)
    require('taudot.comforts.envs').attach(buf)
    require('taudot.comforts.fold').attach(buf)
  end
  if b then
    require('taudot.comforts.complete').attach(buf, b)
  end
end

return M
