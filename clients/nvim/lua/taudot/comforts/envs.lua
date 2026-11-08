-- \begin{…} auto-close and rename.
--
-- Typing (or skipping over, with autopairs) the `}` of `\begin{figure}` puts `\end{figure}` on a line below, at the
-- same indent, and leaves the cursor after the `}` so `[t]` can still follow. Enter on such a line (or on any
-- `\begin` line whose environment is not closed) opens an indented line inside. Renaming the environment of a
-- `\begin` renames its `\end`. Both work from the buffer alone, so they work the same in every mode.

local api = vim.api

local M = {}

local MAX_LINES = 5000

-- Per buffer: last cursor { row, col, lines }, and the begin being renamed { row, scol, name, mark }.
local state = {}
local ns = api.nvim_create_namespace('taudot.envs')

local function esc(s)
  return (s:gsub('%p', '%%%0'))
end

-- Is the environment begun on `row` (0-based) closed further down? `col` is the byte just after its `\begin{env}`.
-- Counts nested begins of the same name.
function M.find_end(buf, row, col, env)
  local depth = 1
  local total = api.nvim_buf_line_count(buf)
  local last = math.min(total, row + MAX_LINES)
  local lines = api.nvim_buf_get_lines(buf, row, last, false)
  local pat_b, pat_e = '\\begin%s*{' .. esc(env) .. '}', '\\end%s*{' .. esc(env) .. '}'
  for i, line in ipairs(lines) do
    local from = (i == 1) and col + 1 or 1
    local code = line:gsub('([^\\])%%.*$', '%1')
    if code:sub(1, 1) == '%' then
      code = ''
    end
    while true do
      local bs, be = code:find(pat_b, from)
      local es, ee = code:find(pat_e, from)
      if not bs and not es then
        break
      end
      if bs and (not es or bs < es) then
        depth = depth + 1
        from = be + 1
      else
        depth = depth - 1
        if depth == 0 then
          return row + i - 1, es + #code:sub(es, ee):match('^\\end%s*{') - 1
        end
        from = ee + 1
      end
    end
  end
end

local function indent_unit(buf)
  if vim.bo[buf].expandtab then
    local sw = vim.fn.shiftwidth()
    return string.rep(' ', sw > 0 and sw or 2)
  end
  return '\t'
end

-- Put `\end{env}` below `row` (0-based) unless the environment begun there is already closed.
function M.close(buf, row, col, env, at)
  if M.find_end(buf, row, col, env) then
    return false
  end
  local line = api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
  local indent = line:match('^%s*')
  api.nvim_buf_set_lines(buf, at or row + 1, at or row + 1, false, { indent .. "\\end{" .. env .. "}" })
  return true
end

-- The `\begin{name}` on `line` whose braces hold byte column `col` (0-based): start of `\begin`, of name, name.
local function begin_at(line, col)
  for s, ns_, name, ne in line:gmatch('()\\begin{()([^{}]*)()}') do
    if col >= ns_ - 1 and col <= ne - 1 then
      return s - 1, ns_ - 1, name
    end
  end
end

-- Just typed the `}` of a `\begin{env}`: close it.
local function after_brace(buf, row, col, line)
  local pre = line:sub(1, col)
  local env = pre:match('\\begin{([^{}]+)}$')
  if env then
    M.close(buf, row, col, env)
  end
end

-- A line was just opened below a `\begin` line: close it if needed and indent the new line inside.
local function after_newline(buf, row)
  if row == 0 then
    return
  end
  local prev = api.nvim_buf_get_lines(buf, row - 1, row, false)[1]
  local indent, env, rest = prev:match('^(%s*)\\begin{([^{}]+)}(.*)$')
  if not env or rest:find('\\end{', 1, true) then
    return
  end
  local cur = api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
  if cur:find('%S') then
    -- Enter in the middle of `\begin{x}text`: leave it.
    return
  end
  M.close(buf, row - 1, #prev - #rest, env, row + 1)
  local inner = indent .. indent_unit(buf)
  api.nvim_buf_set_lines(buf, row, row + 1, false, { inner })
  api.nvim_win_set_cursor(0, { row + 1, #inner })
end

-- Record the `\begin` under the cursor and where its `\end` is, so a rename can follow.
local function track(buf)
  local st = state[buf]
  local row, col = unpack(api.nvim_win_get_cursor(0))
  row = row - 1
  local line = api.nvim_get_current_line()
  local bs, nstart, name = begin_at(line, col)
  if not bs then
    st.pair = nil
    return
  end
  if st.pair and st.pair.row == row and st.pair.scol == nstart then
    return
  end
  local erow, ecol = M.find_end(buf, row, nstart + #name + 1, name)
  if not erow then
    st.pair = nil
    return
  end
  local mark = api.nvim_buf_set_extmark(buf, ns, erow, ecol, { id = st.pair and st.pair.mark or nil, right_gravity = false })
  st.pair = { row = row, scol = nstart, name = name, mark = mark }
end

local function rename(buf)
  local st = state[buf]
  local p = st.pair
  if not p then
    return
  end
  local row = api.nvim_win_get_cursor(0)[1] - 1
  if row ~= p.row then
    st.pair = nil
    return
  end
  local line = api.nvim_get_current_line()
  local name = line:sub(p.scol + 1):match('^([^{}]*)}')
  if not name or name == p.name then
    return
  end
  local m = api.nvim_buf_get_extmark_by_id(buf, ns, p.mark, {})
  if not m[1] then
    st.pair = nil
    return
  end
  local eline = api.nvim_buf_get_lines(buf, m[1], m[1] + 1, false)[1] or ''
  if eline:sub(m[2] + 1, m[2] + #p.name + 1) ~= p.name .. '}' then
    st.pair = nil
    return
  end
  api.nvim_buf_set_text(buf, m[1], m[2], m[1], m[2] + #p.name, { name })
  p.name = name
end

local function on_change(buf, moved_only)
  local st = state[buf]
  local row, col = unpack(api.nvim_win_get_cursor(0))
  row = row - 1
  local lines = api.nvim_buf_line_count(buf)
  local last = st.last
  st.last = { row = row, col = col, lines = lines }
  if not last then
    return
  end
  local line = api.nvim_get_current_line()
  if row == last.row and col == last.col + 1 and line:sub(col, col) == '}' then
    after_brace(buf, row, col, line)
  elseif row == last.row + 1 and lines == last.lines + 1 then
    after_newline(buf, row)
  end
  if not moved_only then
    rename(buf)
  end
  local r, c = unpack(api.nvim_win_get_cursor(0))
  st.last = { row = r - 1, col = c, lines = api.nvim_buf_line_count(buf) }
  track(buf)
end

function M.attach(buf)
  state[buf] = {}
  local group = api.nvim_create_augroup('taudot.envs.' .. buf, { clear = true })
  local function au(ev, cb)
    api.nvim_create_autocmd(ev, { group = group, buffer = buf, callback = cb })
  end
  au({ 'InsertEnter', 'CursorMoved' }, function()
    local r, c = unpack(api.nvim_win_get_cursor(0))
    state[buf].last = { row = r - 1, col = c, lines = api.nvim_buf_line_count(buf) }
    track(buf)
  end)
  au('CursorMovedI', function()
    on_change(buf, true)
  end)
  au('TextChangedI', function()
    on_change(buf, false)
  end)
  au('TextChanged', function()
    rename(buf)
    track(buf)
  end)
  au('BufWipeout', function()
    state[buf] = nil
  end)
end

-- For completion: the cursor is right after an environment name inside `\begin{`. Add the `}` (or step over one) and
-- close it.
function M.complete_begin(buf)
  local row, col = unpack(api.nvim_win_get_cursor(0))
  local line = api.nvim_get_current_line()
  if not line:sub(1, col):match('\\begin{[^{}]+$') then
    return
  end
  if line:sub(col + 1, col + 1) ~= '}' then
    api.nvim_buf_set_text(buf, row - 1, col, row - 1, col, { '}' })
  end
  api.nvim_win_set_cursor(0, { row, col + 1 })
  line = api.nvim_get_current_line()
  after_brace(buf, row - 1, col + 1, line)
  if state[buf] then
    state[buf].last = { row = row - 1, col = col + 1, lines = api.nvim_buf_line_count(buf) }
  end
end

return M
