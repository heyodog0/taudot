-- Cmd-/ toggles `% ` on the line or the selected lines, like Overleaf. `gc` keeps working (commentstring `% %s`).

local api = vim.api

local M = {}

-- Toggle comments on lines l1..l2 (1-based, inclusive). Returns the column shift on the first line (+2, -2, -1, 0).
function M.toggle(buf, l1, l2)
  local lines = api.nvim_buf_get_lines(buf, l1 - 1, l2, false)
  local all, indent = true, math.huge
  for _, l in ipairs(lines) do
    if l:find('%S') then
      if not l:find('^%s*%%') then
        all = false
      end
      indent = math.min(indent, #l:match('^%s*'))
    end
  end
  if indent == math.huge then
    return 0
  end
  local out = {}
  for i, l in ipairs(lines) do
    if not l:find('%S') then
      out[i] = l
    elseif all then
      out[i] = l:gsub('^(%s*)%% ?', '%1', 1)
    else
      out[i] = l:sub(1, indent) .. '% ' .. l:sub(indent + 1)
    end
  end
  -- Only the lines that changed, so the engine gets small edits.
  for i, l in ipairs(out) do
    if l ~= lines[i] then
      api.nvim_buf_set_lines(buf, l1 + i - 2, l1 + i - 1, false, { l })
    end
  end
  return #out[1] - #lines[1]
end

local function normal()
  local l = api.nvim_win_get_cursor(0)[1]
  M.toggle(0, l, l)
end

local function visual()
  local a, b = vim.fn.line('v'), vim.fn.line('.')
  M.toggle(0, math.min(a, b), math.max(a, b))
  api.nvim_feedkeys(vim.keycode('<Esc>'), 'nx', false)
end

local function insert()
  local row, col = unpack(api.nvim_win_get_cursor(0))
  local shift = M.toggle(0, row, row)
  api.nvim_win_set_cursor(0, { row, math.max(0, col + shift) })
end

local function map(buf, mode, lhs, rhs)
  if vim.fn.maparg(lhs, mode) == '' then
    vim.keymap.set(mode, lhs, rhs, { buffer = buf, desc = 'Taudot: toggle % comment' })
  end
end

function M.attach(buf)
  vim.bo[buf].commentstring = '% %s'
  map(buf, 'n', '<D-/>', normal)
  map(buf, 'x', '<D-/>', visual)
  map(buf, 'i', '<D-/>', insert)
end

return M
