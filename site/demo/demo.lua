-- Demo helpers, loaded into the app's Neovim: type a string at a human pace (InsertCharPre and the plugin see
-- real typed keys), and park the cursor on a line.
_G.demo = {}
function demo.type(s, base)
  base = base or 55
  local chars, i = vim.fn.split(s, [[\zs]]), 0
  local function step()
    i = i + 1
    if i > #chars then return end
    vim.api.nvim_feedkeys(chars[i], 'nt', false)
    local c = chars[i]
    local d = base + math.random(0, 45) + ((c == ' ' and 30) or (c:match('[,.]') and 140) or 0)
    vim.defer_fn(step, d)
  end
  step()
end
function demo.at(pat, toend)
  local ls = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  for n, l in ipairs(ls) do
    local s = l:find(pat, 1, true)
    if s then
      vim.api.nvim_win_set_cursor(0, { n, toend and #l - 1 or s - 1 })
      return n
    end
  end
end
