-- nvim --headless --clean -l tests/comforts_spec.lua
-- Drives a child Neovim key by key (so TextChangedI and friends fire as when typing), with a fake engine that answers
-- complete.items from canned results.
local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
local fails = 0
local step = 'start'
io.stdout:setvbuf('no')
-- A hang anywhere fails the run instead of blocking it.
local watchdog = vim.uv.new_timer()
watchdog:start(90000, 0, function()
  io.stdout:write('\nFAIL timeout after: ' .. step .. '\n')
  os.exit(2)
end)

local child = vim.fn.jobstart({ 'nvim', '--embed', '--headless', '--clean', '--cmd', 'set rtp^=' .. root }, { rpc = true })

local function lua(code, ...)
  return vim.rpcrequest(child, 'nvim_exec_lua', code, { ... })
end

local function settle()
  vim.wait(30)
  vim.rpcrequest(child, 'nvim_eval', '1')
end

-- Type keys one at a time, the way a person does.
local function type(keys)
  for _, k in ipairs(vim.split(keys, '')) do
    vim.rpcrequest(child, 'nvim_input', k == '<' and '<lt>' or k)
    settle()
  end
end

local function key(k)
  vim.rpcrequest(child, 'nvim_input', k)
  settle()
end

local function lines()
  return lua('return vim.api.nvim_buf_get_lines(0, 0, -1, false)')
end

local function check(name, got, want)
  step = name
  if not vim.deep_equal(got, want) then
    fails = fails + 1
    print('FAIL ' .. name .. '\n  got:  ' .. vim.inspect(got) .. '\n  want: ' .. vim.inspect(want))
  else
    print('ok   ' .. name)
  end
end

local function reset(text, row, col)
  key('<Esc>')
  lua(
    [[
    local text, row, col = ...
    vim.api.nvim_buf_set_lines(0, 0, -1, false, text)
    vim.api.nvim_win_set_cursor(0, { row, col })
  ]],
    text,
    row,
    col
  )
end

-- Setup: a .tex buffer, comforts attached with a fake synced buffer.
lua([[
  vim.o.expandtab = true
  vim.o.shiftwidth = 2
  vim.cmd.edit(vim.fn.tempname() .. '.tex')
  local buf = vim.api.nvim_get_current_buf()
  local requests = {}
  _G.requests = requests
  local client = {
    request = function(_, method, params, cb)
      requests[#requests + 1] = { method = method, params = params }
      local b = params.before or ''
      local res = { from = params.pos, to = params.pos, context = vim.NIL, items = {} }
      if b:match('\\%a*$') then
        local n = #b:match('\\%a*$')
        res = { from = params.pos - n, to = params.pos, context = 'command', items = {
          { label = '\\section', kind = 'command', detail = '', insert = '\\section{}', cursor = 9 },
          { label = '\\cite', kind = 'command', detail = '', insert = '\\cite{}', cursor = 6 },
          { label = '\\textbf', kind = 'command', detail = '', insert = '\\textbf{}', cursor = 8 },
        } }
      elseif b:match('\\cite{[^}]*$') then
        local n = #b:match('([%w:]*)$')
        res = { from = params.pos - n, to = params.pos, context = 'cite', items = {
          { label = 'ho2020', kind = 'cite', detail = 'Ho & Jain 2020 · Denoising Diffusion', insert = 'ho2020' },
          { label = 'vaswani2017', kind = 'cite', detail = 'Vaswani et al. 2017 · Attention', insert = 'vaswani2017' },
        } }
      elseif b:match('\\begin{%a*$') then
        local n = #b:match('(%a*)$')
        res = { from = params.pos - n, to = params.pos, context = 'env', items = {
          { label = 'figure', kind = 'env', detail = '', insert = 'figure' },
          { label = 'itemize', kind = 'env', detail = '', insert = 'itemize' },
        } }
      end
      vim.defer_fn(function() cb(nil, res) end, 5)
    end,
  }
  local b = { doc_id = 'd1', project = { client = client, folder = vim.fn.getcwd() } }
  require('taudot.buffer').by_buf[buf] = b
  require('taudot.comforts').attach(buf, b)
]])

-- ---- completion ------------------------------------------------------------------------------------------------------

local function wait_pum()
  local ok = vim.wait(1000, function()
    return vim.rpcrequest(child, 'nvim_eval', 'pumvisible()') == 1
  end, 10)
  if not ok then
    return nil
  end
  return lua([[
    local info = vim.fn.complete_info({ 'items', 'selected' })
    local out = {}
    for _, it in ipairs(info.items) do out[#out + 1] = { it.word ~= '' and it.abbr or it.word, it.kind, it.menu } end
    return out
  ]])
end

reset({ 'see ' }, 1, 4)
key('A')
type('\\')
local pum = wait_pum()
check('popup on \\', pum and #pum, 3)
check('kind label', pum and pum[1][2], 'cmd')
type('sec')
check('popup still open after typing', vim.rpcrequest(child, 'nvim_eval', 'pumvisible()'), 1)
key('<Tab>')
settle()
check('Tab accepts \\section, cursor in braces', { lines()[1], lua('return vim.api.nvim_win_get_cursor(0)[2]') }, { 'see \\section{}', 13 })

reset({ 'x ' }, 1, 2)
key('A')
type('\\ci')
wait_pum()
key('<Tab>')
pum = wait_pum()
check('completing \\cite asks for keys', { lines()[1], pum and pum[1][1] }, { 'x \\cite{}', 'ho2020' })
key('<C-e>')

reset({ 'as in ' }, 1, 6)
key('A')
type('\\cite{')
pum = wait_pum()
check('popup on \\cite{', pum and pum[1], { 'ho2020', 'cite', 'Ho & Jain 2020 · Denoising Diffusion' })
type('vas')
key('<C-y>')
settle()
type(', ')
pum = wait_pum()
check('popup after , in cite', pum and #pum, 2)
key('<C-e>')
local req = lua('return _G.requests[#_G.requests]')
check('request carries before and pos', { req.method, req.params.before, req.params.pos }, { 'complete.items', 'as in \\cite{vaswani2017, ', 25 })
check('accepted key', lines()[1], 'as in \\cite{vaswani2017, ')

reset({ 'plain text' }, 1, 10)
key('A')
type(' {x}, more')
settle()
check('no popup in prose', vim.rpcrequest(child, 'nvim_eval', 'pumvisible()'), 0)

-- Completing an environment closes it.
reset({ '' }, 1, 0)
key('A')
type('\\begin{fi')
pum = wait_pum()
check('env popup', pum and pum[1][1], 'figure')
key('<C-y>')
vim.wait(100)
settle()
check('env completion closes', lines(), { '\\begin{figure}', '\\end{figure}' })

-- ---- \begin auto-close -------------------------------------------------------------------------------------------------

reset({ '  ' }, 1, 2)
key('A')
-- Type `}` by hand (no autopairs); the popup may show and is dismissed.
type('\\begin{table')
key('<C-e>')
type('}')
check('} closes', lines(), { '  \\begin{table}', '  \\end{table}' })
check('cursor stays after }', lua('return vim.api.nvim_win_get_cursor(0)'), { 1, 15 })
type('[t]')
key('<CR>')
check('Enter opens an indented line', lines(), { '  \\begin{table}[t]', '    ', '  \\end{table}' })
check('cursor inside', lua('return vim.api.nvim_win_get_cursor(0)'), { 2, 4 })

-- Autopairs-style: the `}` is already there and the cursor steps over it.
reset({ '\\begin{itemize}' }, 1, 14)
key('a')
key('<Left>')
key('<Right>')
check('stepping over } closes', lines(), { '\\begin{itemize}', '\\end{itemize}' })

-- Already closed: nothing added.
reset({ '\\begin{center}', 'x', '\\end{center}' }, 1, 13)
key('a')
key('<Left>')
key('<Right>')
check('closed env left alone', lines(), { '\\begin{center}', 'x', '\\end{center}' })

-- Enter on an unclosed begin line closes it too.
reset({ '\\begin{proof}' }, 1, 12)
key('A')
key('<CR>')
check('Enter closes and indents', lines(), { '\\begin{proof}', '  ', '\\end{proof}' })

-- Rename: changing the begin's name renames its end, nested ones of the same name counted.
reset({ '\\begin{figure}', '\\begin{figure}', 'x', '\\end{figure}', '\\end{figure}' }, 1, 10)
key('<Esc>')
key('ciw')
type('table')
key('<Esc>')
check('rename in insert mode', lines(), { '\\begin{table}', '\\begin{figure}', 'x', '\\end{figure}', '\\end{table}' })
reset({ '\\begin{align}', 'a', '\\end{align}' }, 1, 12)
key('i')
type('*')
check('rename with a typed *', lines(), { '\\begin{align*}', 'a', '\\end{align*}' })

-- ---- Cmd-/ ----------------------------------------------------------------------------------------------------------

reset({ '  a', '', '    b' }, 1, 0)
key('V')
key('G')
key('<D-/>')
check('comment selection', lines(), { '  % a', '', '  %   b' })
key('gg')
key('V')
key('G')
key('<D-/>')
check('uncomment selection', lines(), { '  a', '', '    b' })
reset({ 'hello' }, 1, 2)
key('i')
key('<D-/>')
check('insert-mode toggle keeps cursor on text', { lines()[1], lua('return vim.api.nvim_win_get_cursor(0)[2]') }, { '% hello', 4 })
key('<Esc>')
check('commentstring for gc', lua('return vim.bo.commentstring'), '% %s')

-- ---- folding ----------------------------------------------------------------------------------------------------------

local has_parser = lua("return pcall(vim.treesitter.language.add, 'latex') and vim.treesitter.language.add('latex') or false")
if not has_parser then
  -- The user's parser, as their config would put it on the runtimepath.
  local ts = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
  if vim.fn.isdirectory(ts) == 1 then
    lua('vim.opt.rtp:append(...)', ts)
  end
end
reset({
  '\\section{Intro}\\label{sec:intro}',
  'Text.',
  '% a comment',
  '% more',
  '\\begin{figure}',
  '  x',
  '\\end{figure}',
  '',
  '\\section{Next}',
  'y',
}, 1, 0)
key('<Esc>')
local folds = lua([[
  vim.cmd('normal! zx')
  local out = {}
  for l = 1, vim.api.nvim_buf_line_count(0) do out[l] = vim.fn.foldlevel(l) end
  return { levels = out, closed = vim.fn.foldclosed(1), wo = vim.wo.foldlevel }
]])
if lua("return pcall(vim.treesitter.get_parser, 0, 'latex')") then
  check('fold levels', folds.levels, { 1, 1, 2, 2, 2, 2, 2, 0, 1, 1 })
  check('nothing folded on open', { folds.closed, folds.wo }, { -1, 99 })
  local text = lua([[
    vim.cmd('1foldclose')
    vim.v.foldstart, vim.v.foldend = 1, 7
    return require('taudot.comforts.fold').text()
  ]])
  check('fold text', text, { { '\\section{Intro}', 'Folded' }, { ' · 7 lines', 'TaudotFoldCount' } })
else
  print('skip folding: no latex parser')
end

-- Speed on a real paper: TAUDOT_BENCH=<copy of a project> (main.tex).
local bench = os.getenv('TAUDOT_BENCH')
if bench and has_parser ~= nil then
  local ms = lua([[
    vim.cmd('noswapfile edit! ' .. vim.fn.fnameescape(...))
    local fold = require('taudot.comforts.fold')
    fold.attach(0)
    local t = vim.uv.hrtime()
    fold.expr(1)
    local cold = (vim.uv.hrtime() - t) / 1e6
    vim.api.nvim_buf_set_lines(0, 10, 10, false, { 'x' })
    t = vim.uv.hrtime()
    fold.expr(1)
    return { cold, (vim.uv.hrtime() - t) / 1e6, vim.api.nvim_buf_line_count(0) }
  ]], bench .. '/main.tex')
  print(('fold levels for %d lines: %.1f ms cold, %.1f ms after an edit'):format(ms[3], ms[1], ms[2]))
end

vim.fn.jobstop(child)
if fails > 0 then
  print(('FAIL %d'):format(fails))
  os.exit(1)
end
print('comforts: all passed')
