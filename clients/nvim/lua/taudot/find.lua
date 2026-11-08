-- The Mac app's find bar, driven by Neovim's own search (docs/agents/find.md). The bar sends Vim patterns; this
-- module puts them in the search register, moves the cursor as incsearch does, and counts with searchcount(), so
-- n / N, *, :noh, the `/` history and the bar always agree. Only search gets the bar: `:` keeps Neovim's command line.
--
-- From the GUI (nvim_exec_lua):
--   attach(chan)           map / and ? (normal and visual mode) to open the bar, unless the user mapped them
--   open(dir)              the bar opened ('/' or '?'): remember the window, cursor and 'hlsearch'.
--                          Returns {last = @/, history = [newest first]}
--   search(pat)            live, as typed: from where the bar opened. Returns a count (below)
--   step(forward)          the next / previous match from the cursor (document order). Returns a count
--   replace(pat, rep, all) one (the match at the cursor, then on to the next) or every match, through :s, so undo,
--                          marks and the engine see ordinary edits; all is one undo step. Returns a count + replaced
--   passive(on)            the bar stays up while the editor has the keys (after Enter on /): n / N update its count
--   close(keep)            the bar closed. keep: the cursor stays on the match (Esc and Enter, as Vim); else back
--                          to where it was (no match). The pattern goes in the `/` history.
-- count: {current, total, incomplete, error?}
-- To the GUI: taudot_find_open {dir, visual}  (/ or ? pressed), taudot_find_count {count} (the cursor moved while
-- the bar is up), taudot_find_close {} (Esc in normal mode while the bar is passive, or insert mode began).

local api = vim.api

local M = {}

M.chan = nil
local S = nil -- the open bar: {win, buf, origin = {row, col}, view, hls, pat, dir, passive}
local group = api.nvim_create_augroup('taudot.find', { clear = true })
local esc_mapped = false

local function notify(name, payload)
  if M.chan then
    pcall(vim.rpcnotify, M.chan, name, payload)
  end
end

-- A window the bar searches in: the current one unless it is a float or a special buffer; then the GUI's main
-- text window.
local function main_win()
  local win = api.nvim_get_current_win()
  local cfg = api.nvim_win_get_config(win)
  local bt = vim.bo[api.nvim_win_get_buf(win)].buftype
  if cfg.relative == '' and (bt == '' or bt == 'help' or bt == 'nofile') then
    return win
  end
  local ok, gui = pcall(require, 'taudot.gui')
  if ok and gui.target then
    local w = gui.target()
    if w and api.nvim_win_is_valid(w) then
      return w
    end
  end
  return win
end

-- E54: Unmatched \( → "Unmatched \("
local function short(err)
  local s = tostring(err):gsub('^.-E%d+: ', ''):gsub('^Vim:', '')
  return (s:gsub('\n.*', ''))
end

local function valid(pat)
  local ok, err = pcall(vim.regex, pat)
  if ok then
    return nil
  end
  return short(err)
end

local function count(pat)
  local ok, c = pcall(vim.fn.searchcount, { pattern = pat, recompute = true, maxcount = 0, timeout = 150 })
  if not ok or type(c) ~= 'table' then
    return { current = 0, total = 0, incomplete = false }
  end
  return { current = c.current or 0, total = c.total or 0, incomplete = (c.incomplete or 0) ~= 0 }
end

local function in_win(f)
  if not S or not api.nvim_win_is_valid(S.win) then
    return { current = 0, total = 0, incomplete = false }
  end
  return api.nvim_win_call(S.win, f)
end

-- / and ? open the bar where it makes sense; elsewhere (a terminal, a prompt, a float) they are Neovim's own.
local function key(dir)
  return function()
    local win = api.nvim_get_current_win()
    local bt = vim.bo.buftype
    if not M.chan or api.nvim_win_get_config(win).relative ~= '' or (bt ~= '' and bt ~= 'help' and bt ~= 'nofile')
      or vim.fn.getcmdwintype() ~= '' then
      api.nvim_feedkeys(dir, 'n', false)
      return
    end
    local mode = api.nvim_get_mode().mode:sub(1, 1)
    notify('taudot_find_open', { dir = dir, visual = mode == 'v' or mode == 'V' or mode == '\22' })
  end
end

local function taken(mode, lhs)
  local m = vim.fn.maparg(lhs, mode, false, true)
  return not vim.tbl_isempty(m) and not (type(m.desc) == 'string' and m.desc:sub(1, 7) == 'Taudot:')
end

function M.attach(chan)
  if chan == nil or chan == vim.NIL then
    local u = api.nvim_list_uis()[1]
    chan = u and u.chan
  end
  M.chan = chan
  for _, d in ipairs({ '/', '?' }) do
    for _, mode in ipairs({ 'n', 'x' }) do
      if not taken(mode, d) then
        vim.keymap.set(mode, d, key(d), { desc = 'Taudot: find bar (' .. (d == '/' and 'forward' or 'backward') .. ')' })
      end
    end
  end
  return true
end

function M.open(dir)
  if S then
    M.close(true)
  end
  local win = main_win()
  local cur = api.nvim_win_get_cursor(win)
  S = {
    win = win,
    buf = api.nvim_win_get_buf(win),
    origin = cur,
    view = api.nvim_win_call(win, vim.fn.winsaveview),
    hls = vim.o.hlsearch,
    dir = dir == '?' and '?' or '/',
    pat = '',
    passive = false,
  }
  local hist = {}
  for i = 1, 50 do
    local h = vim.fn.histget('/', -i)
    if h == '' then
      break
    end
    hist[#hist + 1] = h
  end
  return { last = vim.fn.getreg('/'), history = hist, ic = vim.o.ignorecase, scs = vim.o.smartcase }
end

local function back_to_origin()
  if S and api.nvim_win_is_valid(S.win) and api.nvim_win_get_buf(S.win) == S.buf then
    api.nvim_win_call(S.win, function()
      vim.fn.winrestview(S.view)
    end)
  end
end

function M.search(pat)
  if not S then
    M.open('/')
  end
  S.pat = pat
  if pat == '' then
    back_to_origin()
    vim.v.hlsearch = 0
    return { current = 0, total = 0, incomplete = false }
  end
  local err = valid(pat)
  if err then
    return { current = 0, total = 0, incomplete = false, error = err }
  end
  vim.fn.setreg('/', pat)
  vim.o.hlsearch = true
  vim.v.hlsearch = 1
  vim.v.searchforward = S.dir == '/' and 1 or 0
  return in_win(function()
    api.nvim_win_set_cursor(0, S.origin)
    local pos = vim.fn.searchpos(pat, (S.dir == '?' and 'b' or '') .. 'nw')
    if pos[1] == 0 then
      vim.fn.winrestview(S.view)
    else
      api.nvim_win_set_cursor(0, { pos[1], pos[2] - 1 })
      vim.cmd('silent! normal! zv')
    end
    return count(pat)
  end)
end

function M.step(forward)
  if not S or S.pat == '' or valid(S.pat) then
    return { current = 0, total = 0, incomplete = false }
  end
  local pat = S.pat
  return in_win(function()
    vim.fn.search(pat, (forward and '' or 'b') .. 'w')
    vim.cmd('silent! normal! zv')
    return count(pat)
  end)
end

-- `/` in the pattern, escaped for :s's delimiter (one that a backslash already escapes stays).
local function delim(pat)
  local out, i = {}, 1
  while i <= #pat do
    local c = pat:sub(i, i)
    if c == '\\' then
      out[#out + 1] = pat:sub(i, i + 1)
      i = i + 2
    else
      out[#out + 1] = c == '/' and '\\/' or c
      i = i + 1
    end
  end
  return table.concat(out)
end

function M.replace(pat, rep, all)
  if not S then
    M.open('/')
  end
  S.pat = pat
  local err = valid(pat)
  if err or pat == '' then
    return { current = 0, total = 0, incomplete = false, error = err, replaced = 0 }
  end
  vim.fn.setreg('/', pat)
  return in_win(function()
    if vim.bo.modifiable == false or vim.bo.readonly then
      local c = count(pat)
      c.error, c.replaced = 'Read-only', 0
      return c
    end
    local p = delim(pat)
    if all then
      local n = count(pat).total
      local view = vim.fn.winsaveview()
      local g = vim.o.gdefault and '' or 'g'
      vim.cmd('silent keeppatterns keepjumps %s/' .. p .. '/' .. rep .. '/e' .. g)
      vim.fn.winrestview(view)
      local c = count(pat)
      c.replaced = n
      return c
    end
    -- One: the match at the cursor (else first go to the next one, as editors do).
    local cur = api.nvim_win_get_cursor(0)
    local at = vim.fn.searchpos(pat, 'cnw')
    if at[1] ~= cur[1] or at[2] - 1 ~= cur[2] then
      vim.fn.search(pat, 'w')
      local c = count(pat)
      c.replaced = 0
      return c
    end
    local lines = api.nvim_buf_line_count(0)
    local before = #api.nvim_get_current_line()
    local mend = vim.fn.searchpos(pat, 'cnez')
    vim.cmd('silent keeppatterns keepjumps s/\\%#\\%(' .. p .. '\\m\\)/' .. rep .. '/e')
    -- after the replacement: on to the next match from its end
    if api.nvim_buf_line_count(0) == lines and mend[1] == cur[1] then
      local mlen = mend[2] - cur[2] -- the match's bytes (to its last byte's start; good enough for the arithmetic)
      local after = #api.nvim_buf_get_lines(0, cur[1] - 1, cur[1], false)[1]
      local newlen = after - before + mlen
      if newlen > 0 then
        api.nvim_win_set_cursor(0, { cur[1], cur[2] + newlen - 1 })
        vim.fn.search(pat, 'w')
      else
        api.nvim_win_set_cursor(0, cur)
        vim.fn.search(pat, 'cw')
      end
    else
      api.nvim_win_set_cursor(0, { math.min(cur[1], api.nvim_buf_line_count(0)), 0 })
      vim.fn.search(pat, 'cw')
    end
    vim.cmd('silent! normal! zv')
    local c = count(pat)
    c.replaced = 1
    return c
  end)
end

local function unmap_esc()
  if esc_mapped then
    pcall(vim.keymap.del, 'n', '<Esc>')
    esc_mapped = false
  end
end

-- After Enter on `/`: the bar stays up, the editor has the keys; n / N (any move) update the bar's count, Esc or
-- insert mode closes it.
function M.passive(on)
  if not S then
    return false
  end
  S.passive = on
  api.nvim_clear_autocmds({ group = group })
  unmap_esc()
  if not on then
    return true
  end
  local last
  api.nvim_create_autocmd('CursorMoved', {
    group = group,
    callback = function()
      if not S or S.pat == '' then
        return
      end
      local c = count(S.pat)
      local k = c.current .. '/' .. c.total
      if k ~= last then
        last = k
        notify('taudot_find_count', c)
      end
    end,
  })
  api.nvim_create_autocmd('ModeChanged', {
    group = group,
    pattern = '*:[iR]*',
    callback = function()
      notify('taudot_find_close', {})
    end,
  })
  if not taken('n', '<Esc>') then
    vim.keymap.set('n', '<Esc>', function()
      notify('taudot_find_close', {})
    end, { desc = 'Taudot: close the find bar' })
    esc_mapped = true
  end
  return true
end

function M.close(keep)
  if not S then
    return true
  end
  api.nvim_clear_autocmds({ group = group })
  unmap_esc()
  local s = S
  S = nil
  if s.pat ~= '' and not valid(s.pat) then
    vim.fn.histadd('/', s.pat)
  end
  if not keep or s.pat == '' then
    S = s
    back_to_origin()
    S = nil
  elseif api.nvim_win_is_valid(s.win) then
    -- Where the search started goes in the jumplist, as with / (`` and <C-o> return there).
    api.nvim_win_call(s.win, function()
      local now = api.nvim_win_get_cursor(0)
      if now[1] ~= s.origin[1] or now[2] ~= s.origin[2] then
        api.nvim_win_set_cursor(0, s.origin)
        vim.cmd("normal! m'")
        api.nvim_win_set_cursor(0, now)
      end
    end)
  end
  -- 'hlsearch' as the user had it: off again if it was (the matches then stop showing, as after a / without it).
  if not s.hls then
    vim.o.hlsearch = false
  end
  return true
end

-- For checks.
function M.state()
  return S
end

return M
