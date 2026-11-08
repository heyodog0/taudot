-- Typing like a person in the app's Neovim, for Tests/pdf_typing.sh (run through TAUDOT_EXEC). PDF_TYPING picks
-- the part: "race" (keystrokes in the abstract at intervals around txp-headless's 500 ms idle aux rerun, which used to
-- leave TeXpresso with no pages for good), "human" (a minute of editing: words, newlines, multibyte text, undo/redo,
-- a pasted paragraph, a caption, a broken brace), or "both" (default). Line numbers assume a long paper (400+ lines).
-- Ends by inserting ZEBRAFINAL in one edit; TYPE_LOG gets a line per step.
local api, uv = vim.api, vim.loop
local log = io.open(os.getenv('TYPE_LOG') or '/dev/null', 'a')
local function say(s) log:write(string.format('%.3f %s\n', uv.hrtime() / 1e9, s)); log:flush() end
local part = os.getenv('PDF_TYPING') or 'both'
local steps = {}
local function keys(k, ms) table.insert(steps, { k = k, ms = ms or 120 }) end
local function typ(s)  -- one character at a time (UTF-8 aware), 50-160 ms apart
  for ch in s:gmatch('[%z\1-\127\194-\244][\128-\191]*') do keys(ch, 50 + math.random(110)) end
end
local function pause(ms) table.insert(steps, { k = '', ms = ms }) end
local function cmd(c, ms) table.insert(steps, { c = c, ms = ms or 300 }) end
local function mark(s) table.insert(steps, { say = s, ms = 0 }) end
math.randomseed(tonumber(os.getenv('TYPE_SEED') or '7'))

if part ~= 'human' then
  mark('race: keystrokes in the abstract around the idle rerun'); cmd('normal! 163G0w', 500); keys('i', 300)
  local n = 0
  for w = tonumber(os.getenv('RACE_FROM') or '450'), tonumber(os.getenv('RACE_TO') or '1300'), 25 do n = n + 1; keys(n % 2 == 1 and 'x' or '<BS>', w) end
  keys('<Esc>', 3000)
end
if part ~= 'race' then
  mark('abstract 163: type'); cmd('normal! 163G0', 800); keys('3w', 200); keys('i', 200)
  typ('quickly typed abstract words, '); keys('\27', 1500)
  mark('abstract: delete, newline'); keys('dw', 400); keys('dw', 400); keys('o', 300); typ('A new abstract sentence.'); keys('\27', 2500)
  mark('abstract: undo'); keys('u', 600); keys('u', 600); keys('u', 2000)
  mark('paragraph 177: append words'); cmd('normal! 177G$', 800); keys('a', 200)
  typ(' We typed this by hand, quickly.'); keys('\27', 400)
  mark('wander with the cursor'); for _ = 1, 6 do keys('j', 350) end; for _ = 1, 4 do keys('w', 250) end; for _ = 1, 3 do keys('k', 400) end
  mark('new line with multibyte text'); keys('o', 300); typ('Café — naïve “quotes” → 3×4 ≤ 5. Ünïcödé ﬁne.'); keys('\27', 500)
  mark('delete words, undo, redo'); keys('0', 200); for _ = 1, 3 do keys('dw', 300) end; keys('u', 500); keys('u', 500); keys('\18', 500)
  mark('delete the new line'); keys('dd', 600)
  mark('paste a paragraph'); cmd('normal! 172G', 500); keys('yap', 300); cmd('normal! 190G', 400); keys('p', 1500)
  mark('type in the pasted paragraph'); keys('A', 200); typ(' More text in the copy.'); keys('\27', 600)
  mark('caption 618'); cmd('normal! 618G0', 600); keys('f.', 200); keys('a', 200); typ(' Also a typed note'); keys('\27', 800)
  mark('break a brace'); cmd('normal! 361G0', 500); keys('A', 200); typ(' \\textbf{broken'); keys('\27', 4000)
  mark('fix the brace'); keys('A', 200); typ('}'); keys('\27', 2000)
  mark('undo a lot'); for _ = 1, 8 do keys('u', 250) end; pause(1500)
  mark('redo some'); for _ = 1, 4 do keys('\18', 250) end; pause(1500)
  mark('fast typing burst'); cmd('normal! 200G$', 400); keys('a', 100); for _ = 1, 3 do for ch in ('abc def ghi '):gmatch('.') do keys(ch, 25) end end; keys('\27', 300)
  mark('backspace burst'); keys('a', 100); for _ = 1, 12 do keys('\8', 30) end; keys('\27', 3000)
end
mark('final edit'); table.insert(steps, { final = true, ms = 0 })

local i = 0
local function step()
  i = i + 1
  local s = steps[i]
  if not s then return end
  if s.say then say(s.say)
  elseif s.final then
    local row = api.nvim_win_get_cursor(0)[1]
    api.nvim_buf_set_text(0, row - 1, 0, row - 1, 0, { 'ZEBRAFINAL ' })
    say('end')
    return
  elseif s.c then vim.cmd(s.c)
  elseif s.k ~= '' then api.nvim_feedkeys(api.nvim_replace_termcodes(s.k, true, false, true), 'mt', false) end
  vim.defer_fn(step, s.ms)
end
vim.defer_fn(function() say('start'); step() end, tonumber(os.getenv('START_MS') or '9000'))
