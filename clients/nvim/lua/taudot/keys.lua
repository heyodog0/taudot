-- Review mappings under config.mapping_prefix (default <leader>a). A key the user already mapped is never replaced:
-- it is skipped and listed in :checkhealth taudot.

local api = vim.api
local config = require('taudot.config')

local M = {}

-- "mode lhs" -> what is there instead. Read by health.lua.
M.skipped = {}

local function ts()
  return require('taudot')
end
local function review()
  return require('taudot.review')
end

-- { mode(s), key after the prefix, rhs, desc }
M.global = {
  { 'n', 'p', function() require('taudot.panel').toggle() end, 'review panel' },
  { 'n', 'l', function() require('taudot.picker').comments() end, 'list comments' },
  { 'n', 'L', function() require('taudot.picker').changes() end, 'list tracked changes' },
  { 'n', 't', function() review().track() end, 'track my edits on/off' },
  { 'n', 'i', function() review().inline() end, 'comment text at line ends on/off' },
  { 'n', 's', function() ts().status() end, 'status' },
  { 'n', 'o', function() ts().open(vim.fn.expand('%:p:h')) end, 'open the project of this file' },
}

M.buffer_local = {
  { 'n', 'c', function() review().comment_word() end, 'comment on the word' },
  { 'x', 'c', ':Taudot comment<CR>', 'comment on the selection' },
  { 'n', 'r', function() review().reply() end, 'reply to the comment here' },
  { 'n', 'R', function() review().toggle() end, 'resolve or reopen the comment here' },
  { 'n', 'd', function() review().delete_thread() end, 'delete the comment thread here' },
  { 'n', 'e', function() review().edit_message() end, 'edit my message here' },
  { 'n', 'a', function() review().accept() end, 'accept the tracked change here' },
  { 'x', 'a', ':Taudot accept<CR>', 'accept tracked changes in the lines' },
  { 'n', 'x', function() review().reject() end, 'reject the tracked change here' },
  { 'x', 'x', ':Taudot reject<CR>', 'reject tracked changes in the lines' },
}

-- Without the prefix: ]r / [r, like ]c / [d (counts work: 3]r).
M.buffer_plain = {
  { 'n', ']r', function() require('taudot.gui').jump(1, vim.v.count1) end, 'next comment or tracked change' },
  { 'n', '[r', function() require('taudot.gui').jump(-1, vim.v.count1) end, 'previous comment or tracked change' },
  -- Then on to the next item. ga / gx keep their built-in meaning (show the character, open the link) where there
  -- is no tracked change. Resolve is gC: gR is often taken (peek references).
  { 'n', 'ga', function() require('taudot.gui').verb('accept', 'ga') end, 'accept the tracked change here, then next' },
  { 'n', 'gx', function() require('taudot.gui').verb('reject', 'gx') end, 'reject the tracked change here, then next' },
  { 'n', 'gC', function() require('taudot.gui').verb('resolve') end, 'resolve the comment here, then next' },
}

-- What occupies mode/lhs (in the current buffer), unless it is one of ours.
local function taken(mode, lhs)
  local m = vim.fn.maparg(lhs, mode, false, true)
  if vim.tbl_isempty(m) then
    return nil
  end
  if type(m.desc) == 'string' and m.desc:sub(1, 8) == 'taudot:' then
    return nil
  end
  return m.desc or m.rhs or (m.callback and 'a Lua function') or '?'
end

local function set(list, buf, prefix)
  prefix = prefix or config.options.mapping_prefix
  for _, k in ipairs(list) do
    local lhs = prefix .. k[2]
    local other = taken(k[1], lhs)
    local key = k[1] .. ' ' .. lhs
    if other then
      M.skipped[key] = other
    else
      M.skipped[key] = nil
      local opts = { desc = 'Taudot: ' .. k[4], silent = true }
      if buf then
        opts.buffer = buf
      end
      vim.keymap.set(k[1], lhs, k[3], opts)
    end
  end
end

function M.global_maps()
  if config.options.mappings then
    set(M.global)
  end
end

function M.buffer(buf)
  if not config.options.mappings then
    return
  end
  api.nvim_buf_call(buf, function()
    set(M.buffer_local, buf)
    set(M.buffer_plain, buf, '')
  end)
end

return M
