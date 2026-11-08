-- Folding: sections, environments and runs of comment lines, from treesitter (the latex parser's `folds` query, or
-- our own when none is installed). Nothing is folded on open (foldlevel 99); `za` and friends work as usual. A fold
-- shows as `\section{Intro} · 42 lines`.

local api = vim.api

local M = {}

local QUERY = [[
[
  (part) (chapter) (section) (subsection) (subsubsection) (paragraph) (subparagraph)
  (generic_environment) (math_environment) (comment_environment) (displayed_equation)
] @fold
]]

-- buf -> { tick, levels }
local cache = {}

local function query()
  local ok, q = pcall(vim.treesitter.query.get, 'latex', 'folds')
  if ok and q then
    return q
  end
  ok, q = pcall(vim.treesitter.query.parse, 'latex', QUERY)
  return ok and q or nil
end

-- Fold ranges as { start_row, end_row } (0-based, inclusive), each spanning two lines or more.
function M.ranges(buf)
  local out = {}
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  local ok, parser = pcall(vim.treesitter.get_parser, buf, 'latex', { error = false })
  local q = ok and parser and query()
  if q then
    local root = parser:parse()[1]:root()
    for id, node in q:iter_captures(root, buf) do
      if q.captures[id] == 'fold' then
        local sr, _, er, ec = node:range()
        if ec == 0 and er > sr then
          er = er - 1
        end
        -- Sections run to the next one: leave out the blank lines before it.
        while er > sr and not (lines[er + 1] or ''):find('%S') do
          er = er - 1
        end
        if er > sr and not (lines[sr + 1] or ''):find('\\begin%s*{document}') then
          out[#out + 1] = { sr, er }
        end
      end
    end
  end
  -- Runs of two or more comment lines.
  local start
  for i = 1, #lines + 1 do
    local c = lines[i] and lines[i]:find('^%s*%%')
    if c and not start then
      start = i
    elseif not c and start then
      if i - 1 > start then
        out[#out + 1] = { start - 1, i - 2 }
      end
      start = nil
    end
  end
  return out, #lines
end

local function levels(buf)
  local tick = api.nvim_buf_get_changedtick(buf)
  local c = cache[buf]
  if c and c.tick == tick then
    return c.levels
  end
  local ranges, n = M.ranges(buf)
  local depth, starts = {}, {}
  for i = 0, n - 1 do
    depth[i] = 0
  end
  for _, r in ipairs(ranges) do
    for i = r[1], r[2] do
      depth[i] = depth[i] + 1
    end
    starts[r[1]] = true
  end
  local out = {}
  for i = 0, n - 1 do
    out[i + 1] = starts[i] and ('>' .. depth[i]) or tostring(depth[i])
  end
  cache[buf] = { tick = tick, levels = out }
  return out
end

function M.expr(lnum)
  return levels(api.nvim_get_current_buf())[lnum or vim.v.lnum] or '0'
end

-- `\section{Intro} · 42 lines`, as highlighted chunks.
function M.text()
  local first = vim.fn.getline(vim.v.foldstart)
  local n = vim.v.foldend - vim.v.foldstart + 1
  local head = vim.trim(first):gsub('%s*\\label%b{}%s*$', '')
  if #head > 80 then
    head = head:sub(1, 78 + vim.str_utf_start(head, 78) - 1) .. "…"
  end
  local indent = first:match('^%s*'):gsub('\t', string.rep(' ', vim.bo.tabstop))
  return { { indent .. head, 'Folded' }, { ' · ' .. n .. ' lines', 'TaudotFoldCount' } }
end

local function set(win)
  local wo = vim.wo[win][0]
  if wo.foldexpr:find("taudot", 1, true) then
    return
  end
  wo.foldmethod = 'expr'
  wo.foldexpr = "v:lua.require'taudot.comforts.fold'.expr()"
  wo.foldtext = "v:lua.require'taudot.comforts.fold'.text()"
  wo.foldlevel = 99
  wo.foldenable = true
end

function M.attach(buf)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    set(win)
  end
  local group = api.nvim_create_augroup('taudot.fold.' .. buf, { clear = true })
  api.nvim_create_autocmd('BufWinEnter', {
    group = group,
    buffer = buf,
    callback = function()
      set(api.nvim_get_current_win())
    end,
  })
  api.nvim_create_autocmd('BufWipeout', {
    group = group,
    buffer = buf,
    callback = function()
      cache[buf] = nil
    end,
  })
end

return M
