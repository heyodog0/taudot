-- Bridge to a GUI (the Mac app's review margin, docs/mac-app.md). A UI channel asks for it with
-- `require('taudot.gui').attach(chan)` (no chan: the first attached UI's); from then on it gets
--
--   taudot_review         {buf, path, file, doc_id, synced, reason, me, me_user?: {user_id, name, initials, color},
--                           supported, track, items: [item]}   (file: the buffer's absolute path, any buffer)
--       whenever the review state of the followed buffer changes, or the followed buffer changes. Followed: the
--       editor's main text window, the last current non-floating window with a normal buffer (buftype ""); a float
--       (which-key, notify, hover, Telescope) or a special buffer (the cmdline window, a picker) becoming current
--       changes nothing. Coalesced (at most once per event-loop tick) and never twice the same (reason aside). A
--       buffer that isn't a taudot doc sends synced = false, items = {}. A synced buffer that had items and has
--       none is sent empty only once that has lasted `empty_hold_ms` (and never while the project isn't online):
--       ranges reloading after a reconnect come back empty for a moment.
--   taudot_review_cursor  {buf, line, col, here: [id], visual?}  the cursor moved; `here`: the items under it;
--       `visual`: {line, col, end_line, end_col, end_wrap?, end_screen_col?, columns} while in visual mode (for the
--       Comment pill): end_wrap is the screen row of the selection's end within its (wrapped) line, end_screen_col
--       the grid column just right of its last character (0-based), columns the grid's width; nil when off screen.
--       `at` (when `here` isn't empty, for a floating card): {columns, cursor_wrap, items = {[id] = {start_wrap,
--       start_col, end_wrap}}}: screen rows within each position's wrapped line, screen columns 0-based.
--   taudot_review_start   {ok, buf, line, col, end_line, end_col, quote} or {ok = false, error}
--       `:Taudot comment` (`<leader>ac`) with no text while a GUI is attached: open the GUI's draft instead of
--       Neovim's prompt (the same capture as start_comment).
--   taudot_review_done    {req, ok, error?, result?}          an action with args.req finished.
--   taudot_review_landed {id}  a jump (]r [r, the GUI's next/previous) landed on item id: its card opens.
--   taudot_overview_changed {}  threads or ranges changed: an overview on screen asks again (act overview).
--   taudot_files          {comments = {[path] = n}, people = {[path] = [user + color]}}  for the file tree: open
--       threads per file and the collaborators in each (paths from the project root), when either changes.
--
-- item: {id, kind ('comment'|'tracked_insert'|'tracked_delete'), thread_id?, author: {user_id, name, initials},
--        color ('#rrggbb' or nil), ts, quote, messages: [{id, text, ts, user, mine}], line, col, end_line, end_col,
--        resolved, resolved_by?, resolved_at?}
-- Positions are 0-based buffer rows and byte columns, end exclusive, where the text is now. doc_row: the screen
-- rows above the item's line in the followed window, from the buffer's top (wraps, folds and virtual lines
-- counted), so the GUI can lay the cards out in document space and only translate them while scrolling.
--
-- Actions in: `gui.act(kind, id, args)` (through nvim_exec_lua). Returns {ok, error?} at once; with args.req the
-- engine's answer comes back as taudot_review_done. Kinds:
--   open {path} (edit a file in the main text window; the GUI's file tree) · select (highlight the item's text in
--   the editor; id nil clears) · reply {text} · resolve · reopen
--   delete (the thread; the GUI asks first) · edit_message {message_id, text} · delete_message {message_id}
--   accept · reject · goto (cursor to the item) · margin_shown {shown}: the GUI's margin is visible (inline
--   end-of-line notes go off, they'd duplicate the cards) or hidden again (they come back as they were)
--   preview {mode = 'accepted'|'rejected'|'off'}: the editor shows the text as if every suggestion were accepted
--       (rejected), read-only, with a banner (winbar); off restores the live view exactly. taudot_preview {mode}.
--   layout {stacked}: the GUI's stacked list (jumps then land with the line centred)
--   kinds {comments, suggestions}: the GUI's filter; the jumps (and ]r) skip what it hides
--   show_resolved {on}: the GUI's "show resolved" toggle (the jumps count resolved comments while on)
--   accept_many / reject_many {ids} (id ignored): tracked changes together (a grouped card, a whole file)
--   overview {req} (id ignored): answers (taudot_review_done result) {files = [{path, items}]}: every doc's comments
--       (resolved too) and tracked changes, docs in the sidebar's order. item: {id, kind, thread_id, path, line?,
--       quote, author, color, text (first message), replies, ts (last activity), resolved, mine}
--   reveal {path, req}: open path and land on item id there (as ]r does)
--   jump {dir = 1|-1, count?} (id ignored): to the next / previous open comment or change, across files (]r / [r)
--   comment (id ignored) {text, line, col, end_line, end_col, buf?}: a new comment on a range.
--   start_comment (id ignored): the GUI is opening a new-comment card. Captures the range: the live visual selection,
--       else the one just left ('< '> if visual mode ended under 10 s ago; kept as an extmark, so edits by others
--       move it). Leaves visual mode and
--       keeps the range highlighted (as a selected card's). Returns at once
--       {ok, buf, line, col, end_line, end_col, quote} or {ok = false, error = 'select text to comment'}.

local api = vim.api
local Buffer = require('taudot.buffer')
local review = require('taudot.review')
local ui = require('taudot.ui')

local M = {}

M.chans = {} -- chan -> true
local last_payload = {} -- chan -> encoded payload, to skip repeats
local last_cursor = {}
local queued, cursor_queued = false, false
local last_files = {}
local installed = false
local find -- defined with the actions
local request -- likewise

local function project()
  return require('taudot').project()
end

local function hex(n)
  return type(n) == 'number' and ('#%06x'):format(n) or nil
end

-- The author's colour as the Neovim client draws it.
local function color_of(user)
  local idx = ui.author_index(user)
  for _, g in ipairs({ 'TaudotCursorLabel' .. idx, 'TaudotAuthor' .. idx }) do
    local h = api.nvim_get_hl(0, { name = g, link = false })
    if h.fg then
      return hex(h.fg)
    end
  end
  return nil
end

local function user(u)
  if type(u) ~= 'table' then
    return { user_id = vim.NIL, name = '?', initials = '?' }
  end
  local name = u.name ~= vim.NIL and u.name or '?'
  local initials = u.initials
  if not initials or initials == vim.NIL or initials == '' then
    initials = ''
    for w in tostring(name):gmatch('%S+') do
      initials = initials .. vim.fn.strcharpart(w, 0, 1)
      if vim.fn.strchars(initials) >= 2 then
        break
      end
    end
    initials = initials:upper()
  end
  return { user_id = u.user_id or vim.NIL, name = name, initials = initials }
end

-- The review items of one taudot buffer, in text order.
-- Screen rows above each of `rows` (0-based buffer lines, ascending) in `win`, counted down the buffer once.
local function doc_rows(win, rows)
  local out, acc, from = {}, 0, 0
  for _, r in ipairs(rows) do
    if r > from then
      local ok, h = pcall(api.nvim_win_text_height, win, { start_row = from, end_row = r - 1 })
      acc = acc + (ok and h.all or (r - from))
      from = r
    end
    out[r] = acc
  end
  return out
end

-- Where a range starts on screen within its (wrapped) line: the screen row inside the line (0: its first) and the
-- column inside the text area (after the number/sign columns), exact with 'linebreak' and for lines off screen
-- (nvim_win_text_height counts rows without drawing them). Cached by text, column and width.
local start_cache, start_cache_key = {}, nil
function M.start_on_screen(win, row, col, text)
  local info = vim.fn.getwininfo(win)[1] or {}
  local width = (info.width or api.nvim_win_get_width(win)) - (info.textoff or 0)
  local key = width .. (vim.wo[win].wrap and 'w' or 'n')
  if key ~= start_cache_key then start_cache, start_cache_key = {}, key end
  local ck = col .. '\0' .. text
  local hit = start_cache[ck]
  if hit then return hit[1], hit[2] end
  -- strdisplaywidth in the window counts 'linebreak' padding (the blanks a moved word leaves at a row's end), so
  -- in those virtual columns every screen row is exactly `width` cells: row and column are a division.
  -- The padding before a word shows only once the word is in the prefix: measure to the end of the word that holds
  -- the column (up to the next 'breakat' character), then take off the cells after the column.
  local brk = {}
  for ch in vim.o.breakat:gmatch('.') do brk[ch] = true end
  local stop = col
  while stop < #text and not brk[text:sub(stop + 1, stop + 1)] do stop = stop + 1 end
  local tail = api.nvim_strwidth(text:sub(col + 1, stop))
  local vcol = api.nvim_win_call(win, function() return vim.fn.strdisplaywidth(text:sub(1, stop)) end) - tail
  local wrap, scol = 0, vcol
  if vim.wo[win].wrap and width > 0 then
    local sb = vim.o.showbreak ~= '' and api.nvim_strwidth(vim.o.showbreak) or 0
    if vcol >= width then
      -- (rows after the first hold width − showbreak cells of text)
      local rest = vcol - width
      local per = math.max(1, width - sb)
      wrap = 1 + math.floor(rest / per)
      scol = sb + rest % per
    end
  else
    scol = vcol - api.nvim_win_call(win, function() return vim.fn.winsaveview().leftcol end)
  end
  start_cache[ck] = { wrap, scol }
  return wrap, scol
end

function M.items(b)
  local p = project()
  local threads = p and p.threads or {}
  local me = p and p.me
  local out = {}
  local list = b:review_items(true)
  local win = M.target()
  local rows
  if win and api.nvim_win_get_buf(win) == b.buf then
    local ls = {}
    for _, it in ipairs(list) do ls[#ls + 1] = it.row end
    table.sort(ls)
    rows = doc_rows(win, ls)
  end
  for _, it in ipairs(list) do
    local r = it.r
    local item = {
      id = r.id,
      kind = r.kind,
      quote = r.text or '',
      ts = r.ts or vim.NIL,
      line = it.row,
      col = it.col,
      end_line = it.end_row,
      end_col = it.end_col,
      doc_row = rows and rows[it.row] or vim.NIL,
      start_line = vim.NIL,
      start_wrap = vim.NIL,
      start_scol = vim.NIL,
      resolved = false,
      messages = {},
    }
    if r.kind == 'comment' then
      local t = threads[r.thread_id]
      item.thread_id = r.thread_id
      local a = review.thread_author(r)
      item.author = user(a)
      item.resolved = (t and t.resolved == true) or (not t and r.resolved == true)
      if t then
        item.resolved_by = t.resolved_by ~= vim.NIL and t.resolved_by and user(t.resolved_by) or nil
        item.resolved_at = t.resolved_at
        for _, m in ipairs(t.messages or {}) do
          item.messages[#item.messages + 1] = {
            id = m.id,
            text = m.text or '',
            ts = m.ts or vim.NIL,
            user = user(m.user),
            mine = m.user ~= nil and m.user ~= vim.NIL and m.user.user_id == me,
          }
        end
        local first = t.messages and t.messages[1]
        if first and first.ts then
          item.ts = first.ts
        end
      end
      item.color = color_of(a)
    else
      item.author = user(r.author)
      item.color = color_of(r.author)
    end
    if rows then
      -- Where its text shows first: a range that starts at a line's end (or on an empty line) begins, on screen, on
      -- the next line that has some of it.
      local srow, scol0 = it.row, it.col
      local text = api.nvim_buf_get_lines(b.buf, srow, srow + 1, false)[1] or ''
      while srow < it.end_row and scol0 >= #text do
        srow, scol0 = srow + 1, 0
        text = api.nvim_buf_get_lines(b.buf, srow, srow + 1, false)[1] or ''
      end
      item.start_line = srow
      item.start_wrap, item.start_scol = M.start_on_screen(win, srow, scol0, text)
    end
    out[#out + 1] = item
  end
  return out
end

function M.payload(buf)
  if not buf then
    local _, t = M.target()
    buf = t or api.nvim_get_current_buf()
  end
  local b = Buffer.by_buf[buf]
  local p = project()
  if b and next(M.chans) ~= nil and vim.bo[buf].autoread ~= false then
    vim.bo[buf].autoread = false -- see FileChangedShell in install(): the buffer may have become a taudot doc just now
  end
  local out = {
    buf = buf,
    synced = b ~= nil,
    path = b and b.path or vim.NIL,
    file = (function()
      local n = api.nvim_buf_is_valid(buf) and api.nvim_buf_get_name(buf) or ''
      return n ~= '' and vim.fs.normalize(vim.fn.fnamemodify(n, ':p')) or vim.NIL
    end)(),
    doc_id = b and b.doc_id or vim.NIL,
    me = p and p.me or vim.NIL,
    me_user = vim.NIL,
    supported = p and p.threads_supported ~= false or false,
    track = p and p.track_changes == true or false,
    items = b and M.items(b) or {},
    textoff = (function()
      local w = M.target()
      local i = w and vim.fn.getwininfo(w)[1]
      return i and i.textoff or 0
    end)(),
    line_count = api.nvim_buf_is_valid(buf) and api.nvim_buf_line_count(buf) or 0,
  }
  -- Who I am, for a new comment's card: name, initials and the colour Neovim draws me with.
  -- (project.users holds the others; else any message of mine has my record.)
  local mine
  for _, u in ipairs(p and p.users or {}) do
    if u.user_id == p.me then mine = u end
  end
  if not mine and p and p.threads then
    for _, t in pairs(p.threads) do
      for _, m in ipairs(t.messages or {}) do
        if type(m.user) == 'table' and m.user.user_id == p.me then mine = m.user break end
      end
      if mine then break end
    end
  end
  if mine then
    out.me_user = user(mine)
    out.me_user.color = color_of(mine) or vim.NIL
  end
  return out
end

-- ---- inline notes while the margin shows -------------------------------------------------------------------------

M.inline_saved = nil -- the user's inline setting while the GUI's margin has turned it off
function M.margin_shown(shown)
  local o = require('taudot.config').options
  if shown and M.inline_saved == nil then
    M.inline_saved = o.inline
    o.inline = false
    review.redraw()
  elseif not shown and M.inline_saved ~= nil then
    o.inline = M.inline_saved
    M.inline_saved = nil
    review.redraw()
  end
  return { ok = true, inline = o.inline }
end

-- ---- the followed window -------------------------------------------------------------------------------------------

M.main_win = nil

-- A window the GUI can follow: not floating, a normal buffer.
local function normal_win(win)
  if not win or not api.nvim_win_is_valid(win) then
    return false
  end
  if api.nvim_win_get_config(win).relative ~= '' then
    return false
  end
  return vim.bo[api.nvim_win_get_buf(win)].buftype == ''
end

-- The window to follow and why: the current one when it is a normal window, else the last one that was.
function M.target()
  local cur = api.nvim_get_current_win()
  if normal_win(cur) then
    M.main_win = cur
    return cur, api.nvim_win_get_buf(cur)
  end
  if normal_win(M.main_win) then
    return M.main_win, api.nvim_win_get_buf(M.main_win)
  end
  -- None seen yet (a float from the start): any normal window showing a synced buffer, else none.
  for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
    if normal_win(w) and Buffer.by_buf[api.nvim_win_get_buf(w)] then
      M.main_win = w
      return w, api.nvim_win_get_buf(w)
    end
  end
  return nil, nil
end

function M.cursor_payload()
  local win, buf = M.target()
  if not win then
    return nil
  end
  local cur = api.nvim_win_get_cursor(win)
  local b = Buffer.by_buf[buf]
  local here = {}
  if b then
    -- ranges_here reads the current window's cursor: ask it in the followed window (a float may be current).
    local ok, rs = pcall(api.nvim_win_call, win, function()
      return b:ranges_here()
    end)
    for _, r in ipairs(ok and rs or {}) do
      here[#here + 1] = r.id
    end
  end
  local visual = win == api.nvim_get_current_win() and M.visual() or nil
  local out = { buf = buf, line = cur[1] - 1, col = cur[2], here = here, visual = visual or vim.NIL }
  if #here > 0 then
    out.at = M.screen_at(win, b, here, cur[1] - 1, cur[2])
  end
  return out
end

-- Screen row of (line, byte col) within its wrapped line, and its screen column (0-based), in win; nil off screen.
local function wrap_of(win, line, col)
  local text = api.nvim_buf_get_lines(api.nvim_win_get_buf(win), line, line + 1, false)[1] or ''
  local p = vim.fn.screenpos(win, line + 1, math.max(1, math.min(col + 1, #text)))
  if p.row == 0 then
    return nil
  end
  local first = vim.fn.screenpos(win, line + 1, 1).row
  if first == 0 then
    -- The line starts above the window (smoothscroll): its first rows are skipped.
    local top, skip = unpack(api.nvim_win_call(win, function()
      local v = vim.fn.winsaveview()
      return { v.topline, v.skipcol or 0 }
    end))
    if top ~= line + 1 or skip == 0 then
      return nil
    end
    local function th(vcol)
      return api.nvim_win_text_height(win, { start_row = line, end_row = line, end_vcol = vcol }).all
    end
    first = vim.fn.win_screenpos(win)[1] - (th(skip) - th(0))
  end
  return p.row - first, (col >= #text and #text > 0) and p.endcol or (p.col - 1)
end

-- For the GUI's floating card: where the items under the cursor and the cursor are on screen. {columns, cursor_wrap,
-- items = {[id] = {start_wrap, start_col, end_wrap}}} (rows within each position's wrapped line; any may be missing).
function M.screen_at(win, b, ids, line, col)
  local want = {}
  for _, id in ipairs(ids) do
    want[id] = true
  end
  local items = {}
  for _, it in ipairs(b and b:review_items(true) or {}) do
    local r = it.r
    if want[r.id] then
      local sw, sc = wrap_of(win, it.row, it.col)
      local last = math.max(it.col, it.end_col - 1)
      local ew = wrap_of(win, it.end_row, it.end_row == it.row and last or math.max(0, it.end_col - 1))
      items[r.id] = { start_wrap = sw, start_col = sc, end_wrap = ew }
    end
  end
  return { columns = vim.o.columns, cursor_wrap = (wrap_of(win, line, col)), items = items }
end

-- The visual selection while in visual mode, as {line, col, end_line, end_col} (end exclusive), else nil.
function M.visual()
  local mode = api.nvim_get_mode().mode
  local m = mode:sub(1, 1)
  if m ~= 'v' and m ~= 'V' and m ~= '\22' then
    return nil
  end
  local a, c = vim.fn.getpos('v'), vim.fn.getpos('.')
  local sr, sc, er, ec = a[2] - 1, a[3] - 1, c[2] - 1, c[3] - 1
  if sr > er or (sr == er and sc > ec) then
    sr, sc, er, ec = er, ec, sr, sc
  end
  local buf = api.nvim_get_current_buf()
  local last = api.nvim_buf_get_lines(buf, er, er + 1, false)[1] or ''
  if m == 'V' then
    sc, ec = 0, #last
  else
    -- the end is the first byte of the last character: include all of it
    local ch = last:sub(ec + 1):match('^[%z\1-\127\194-\244][\128-\191]*') or ''
    ec = math.min(#last, ec + math.max(1, #ch))
  end
  local out = { line = sr, col = sc, end_line = er, end_col = ec, columns = vim.o.columns }
  -- Where the end is on screen: its row within the wrapped line, and the column just after its last character.
  local last_byte = math.max(1, ec) -- 1-based byte of (the start of) the last character, or 1 on an empty line
  local e = vim.fn.screenpos(0, er + 1, last_byte)
  local first = vim.fn.screenpos(0, er + 1, 1)
  if e.row > 0 and first.row > 0 then
    out.end_wrap = e.row - first.row
    out.end_screen_col = (#last == 0) and (e.col - 1) or e.endcol
  end
  return out
end

-- Visual mode just ended: the buffer, when, and an extmark on the range (for start_comment's "just left").
M.left_visual = nil
M.just_left_ms = 10000
M.left_ns = api.nvim_create_namespace('taudot.gui.left_visual')

-- '< '> as a range, in `mode` ('v', 'V' or CTRL-V; block counts as its corners), end exclusive.
local function marks_range(buf, mode)
  local a, c = api.nvim_buf_get_mark(buf, '<'), api.nvim_buf_get_mark(buf, '>')
  if a[1] == 0 or c[1] == 0 then
    return nil
  end
  local sr, sc, er, ec = a[1] - 1, a[2], c[1] - 1, c[2]
  local last = api.nvim_buf_get_lines(buf, er, er + 1, false)[1] or ''
  if mode == 'V' then
    sc, ec = 0, #last
  else
    local ch = last:sub(ec + 1):match('^[%z\1-\127\194-\244][\128-\191]*') or ''
    ec = math.min(#last, ec + math.max(1, #ch))
  end
  return { line = sr, col = math.min(sc, #(api.nvim_buf_get_lines(buf, sr, sr + 1, false)[1] or '')), end_line = er, end_col = ec }
end

-- The range a new comment is about: the visual selection, or the one just left. nil when there is none.
function M.comment_range()
  local buf = api.nvim_get_current_buf()
  local r = M.visual()
  if not r then
    local l = M.left_visual
    if l and l.buf == buf and vim.uv.now() - l.at < M.just_left_ms then
      local m = api.nvim_buf_get_extmark_by_id(buf, M.left_ns, l.mark, { details = true })
      if m[1] then
        r = { line = m[1], col = m[2], end_line = m[3].end_row, end_col = m[3].end_col }
      end
    end
  end
  if not r or r.end_line < r.line or (r.end_line == r.line and r.end_col <= r.col) then
    return nil
  end
  r.buf = buf
  return r
end

-- a #rrggbb mixed with b at t (0..1)
local function mix(a, b, t)
  local function ch(x, i) return tonumber(x:sub(i, i + 1), 16) end
  local out = {}
  for _, i in ipairs({ 2, 4, 6 }) do
    out[#out + 1] = math.floor(ch(a, i) * (1 - t) + ch(b, i) * t + 0.5)
  end
  return ('#%02x%02x%02x'):format(out[1], out[2], out[3])
end

-- The draft's range while a new comment is written: underlined in my author colour on a tint of it (as the GUI's
-- card border), so it stays marked after visual mode ends.
local function draft_hl()
  local p = project()
  local mine = p and p.me and color_of(user(p.me)) or nil
  if not mine then
    api.nvim_set_hl(0, 'TaudotGuiDraft', { link = 'Visual' })
    return
  end
  local normal = api.nvim_get_hl(0, { name = 'Normal', link = false })
  local bg = hex(normal.bg) or (vim.o.background == 'light' and '#ffffff' or '#000000')
  api.nvim_set_hl(0, 'TaudotGuiDraft', { bg = mix(bg, mine, 0.28), sp = mine, underline = true })
end

local function highlight(buf, row, col, end_row, end_col, group)
  for _, b in pairs(Buffer.by_buf) do
    pcall(api.nvim_buf_clear_namespace, b.buf, M.sel_ns, 0, -1)
  end
  api.nvim_set_hl(0, 'TaudotGuiSelected', { link = 'Visual', default = true })
  pcall(api.nvim_buf_set_extmark, buf, M.sel_ns, row, col, { end_row = end_row, end_col = end_col, hl_group = group or 'TaudotGuiSelected', priority = 200 })
end

function M.start_comment()
  local r = M.comment_range()
  if not r then
    return { ok = false, error = 'select text to comment' }
  end
  if not Buffer.by_buf[r.buf] then
    return { ok = false, error = 'this buffer is not a taudot doc' }
  end
  local ok, text = pcall(api.nvim_buf_get_text, r.buf, r.line, r.col, r.end_line, r.end_col, {})
  r.quote = ok and table.concat(text, '\n') or ''
  local m = api.nvim_get_mode().mode:sub(1, 1)
  if m == 'v' or m == 'V' or m == '\22' then
    api.nvim_feedkeys(api.nvim_replace_termcodes('<Esc>', true, false, true), 'nx', false)
  end
  draft_hl()
  highlight(r.buf, r.line, r.col, r.end_line, r.end_col, 'TaudotGuiDraft')
  r.ok = true
  return r
end

-- A file from the GUI's file tree: edited in the main text window (not a float that has the cursor), which then
-- becomes current.
function M.open(path)
  if type(path) ~= 'string' or path == '' then
    return { ok = false, error = 'open needs a path' }
  end
  local win = M.target()
  if win and api.nvim_win_is_valid(win) then
    api.nvim_set_current_win(win)
  end
  local ok, err = pcall(vim.cmd.edit, vim.fn.fnameescape(path))
  if not ok then
    return { ok = false, error = tostring(err):gsub('^Vim%(%a+%):', '') }
  end
  return { ok = true }
end

-- The selected card's text, highlighted in the editor. id nil (or unknown) clears it.
M.sel_ns = api.nvim_create_namespace('taudot.gui.selected')
function M.select(id)
  for _, b in pairs(Buffer.by_buf) do
    pcall(api.nvim_buf_clear_namespace, b.buf, M.sel_ns, 0, -1)
  end
  if id == nil or id == vim.NIL then
    return { ok = true }
  end
  local r, b, it = find(id)
  if not r then
    return { ok = false, error = 'no comment or change ' .. tostring(id) }
  end
  api.nvim_set_hl(0, 'TaudotGuiSelected', { link = 'Visual', default = true })
  local opts = { end_row = it.end_row, end_col = it.end_col, hl_group = 'TaudotGuiSelected', priority = 200 }
  if it.end_row == it.row and it.end_col == it.col then
    -- a classic tracked delete: nothing in the text, mark the character after it
    local len = #(api.nvim_buf_get_lines(b.buf, it.row, it.row + 1, false)[1] or '')
    opts.end_col = math.min(len, it.col + 1)
  end
  pcall(api.nvim_buf_set_extmark, b.buf, M.sel_ns, it.row, it.col, opts)
  return { ok = true }
end

-- ---- jump from comment to comment (]r / [r, the app's ⌥⌘↓ / ⌥⌘↑) -----------------------------------------------
-- The open comments and tracked changes of the buffer in text order; past the last (first), on into the next
-- (previous) file of the project that has some, in the sidebar's order, and round. Resolved comments count only
-- while the GUI's "show resolved" is on (no GUI: config.show_resolved).

M.show_resolved = nil -- the GUI's toggle; nil without a GUI

local function resolved_shown()
  if M.show_resolved ~= nil then
    return M.show_resolved
  end
  return require('taudot.config').options.show_resolved == true
end

-- Finder's order of names: case aside, digit runs as numbers ("fig2" before "fig10").
local function name_lt(a, b)
  local la, lb = a:lower(), b:lower()
  local ia, ib = 1, 1
  while ia <= #la and ib <= #lb do
    local da, db = la:match('^%d+', ia), lb:match('^%d+', ib)
    if da and db then
      local na, nb = tonumber(da), tonumber(db)
      if na ~= nb then return na < nb end
      ia, ib = ia + #da, ib + #db
    else
      local ca, cb = la:sub(ia, ia), lb:sub(ib, ib)
      if ca ~= cb then return ca < cb end
      ia, ib = ia + 1, ib + 1
    end
  end
  if #la - ia ~= #lb - ib then return #la - ia < #lb - ib end
  return a < b
end

-- The sidebar's order of paths from the project root: in each folder its files, then its folders, each by name.
function M.path_lt(a, b)
  local pa, pb = vim.split(a, '/', { plain = true }), vim.split(b, '/', { plain = true })
  local i = 1
  while i < #pa and i < #pb and pa[i] == pb[i] do
    i = i + 1
  end
  local da, db = i < #pa, i < #pb -- component i is a folder
  if da ~= db then
    return db
  end
  return name_lt(pa[i], pb[i])
end

-- The GUI's Comments / Suggestions filter (nil: both): the jumps follow it.
M.kinds = nil
local function kind_shown(r)
  local k = M.kinds
  if not k then return true end
  if r.kind == 'comment' then return k.comments ~= false end
  return k.suggestions ~= false
end

local function counts(r)
  if not kind_shown(r) then
    return false
  end
  if r.kind ~= 'comment' then
    return true
  end
  local p = project()
  local t = p and p.threads and p.threads[r.thread_id]
  local resolved = (t and t.resolved == true) or (not t and r.resolved == true)
  return not resolved or resolved_shown()
end

-- The items to jump between in a buffer, in text order: {r, row, col, end_row, end_col}.
function M.jump_items(b)
  local out = {}
  if b.detached or not api.nvim_buf_is_valid(b.buf) then
    return out
  end
  for _, it in ipairs(b:review_items(resolved_shown())) do
    if counts(it.r) then
      out[#out + 1] = it
    end
  end
  return out
end

local function name_of(r)
  local u = r.kind == 'comment' and review.thread_author(r) or r.author
  return type(u) == 'table' and (u.name or u.email) or nil
end

M.center_on_land = false -- the GUI's stacked list: land with the line in the middle
local function third_down(win, row)
  local h = api.nvim_win_get_height(win)
  local want, top = math.floor(h / (M.center_on_land and 2 or 3)), row
  while top > 0 do
    local ok, th = pcall(api.nvim_win_text_height, win, { start_row = top - 1, end_row = row - 1 })
    if not ok or th.all > want then break end
    top = top - 1
  end
  vim.fn.win_execute(win, 'call winrestview({"topline": ' .. (top + 1) .. ', "topfill": 0})')
end

-- Cursor to the item's start, the view so its line sits a third down, the echo, the PDF told.
local function land(win, b, list, i, file_changed)
  local it = list[i]
  api.nvim_win_set_cursor(win, { it.row + 1, it.col })
  third_down(win, it.row)
  local what = it.r.kind == 'comment' and 'comment' or 'change'
  local msg = ('%s %d of %d'):format(what, i, #list)
  local who = name_of(it.r)
  if who then msg = msg .. ' · ' .. who end
  if file_changed and b.path then msg = msg .. ' · ' .. b.path end
  api.nvim_echo({ { msg } }, false, {})
  M.last_jump = { path = b.path, index = i, total = #list, id = it.r.id, message = msg }
  -- The GUI opens the landed-on item's card (as a click would).
  for c in pairs(M.chans) do pcall(vim.rpcnotify, c, 'taudot_review_landed', { id = it.r.id }) end
  local app = package.loaded['taudot.app']
  if type(app) == 'table' and type(app.cursor) == 'function' then
    pcall(app.cursor, false)
  end
  return M.last_jump
end

-- How many items each doc has (open buffers from their marks, the others from doc.ranges), then cb({[path] = n}).
local function file_counts(paths, cb)
  local p = project()
  local out, waiting = {}, 0
  local by_path = {}
  for _, b in pairs(Buffer.by_buf) do
    if b.path and not b.detached and api.nvim_buf_is_valid(b.buf) then by_path[b.path] = b end
  end
  local finished = false
  local function maybe()
    if waiting == 0 and not finished then
      finished = true
      cb(out)
    end
  end
  for _, path in ipairs(paths) do
    local b = by_path[path]
    if b then
      out[path] = #M.jump_items(b)
    elseif p and p.client and p.docs[path] then
      waiting = waiting + 1
      p.client:request('doc.ranges', { doc_id = p.docs[path] }, function(_, res)
        local n = 0
        for _, r in ipairs(res and res.ranges or {}) do
          if counts(r) then n = n + 1 end
        end
        out[path] = n
        waiting = waiting - 1
        maybe()
      end)
    end
  end
  maybe()
end

-- Open `path` in `win` and wait (up to 3 s) for its ranges; then cb(b) (nil if they never came).
local function open_doc(win, path, want, cb)
  local p = project()
  api.nvim_set_current_win(win)
  local ok = pcall(vim.cmd.edit, vim.fn.fnameescape(p.folder .. '/' .. path))
  if not ok then return cb(nil) end
  local buf = api.nvim_win_get_buf(win)
  local t0 = vim.uv.now()
  local function poll()
    local b = Buffer.by_buf[buf]
    if b and #M.jump_items(b) >= math.min(want, 1) then return cb(b) end
    if vim.uv.now() - t0 > 3000 then return cb(b) end
    vim.defer_fn(poll, 15)
  end
  poll()
end

-- Move `count` items forward (dir 1) or back (-1). cb(result) when landed: {path, index, total, id, message}, or
-- {error}. Returns at once (a jump into another file waits for it to load).
function M.jump(dir, count, cb)
  cb = cb or function() end
  count = math.max(1, tonumber(count) or 1)
  local win = M.target() or api.nvim_get_current_win()
  local buf = api.nvim_win_get_buf(win)
  local b = Buffer.by_buf[buf]
  local p = project()
  local function fail(msg)
    api.nvim_echo({ { msg, 'WarningMsg' } }, false, {})
    cb({ error = msg })
    return { error = msg }
  end
  local list = b and M.jump_items(b) or {}
  local cur = api.nvim_win_get_cursor(win)
  local crow, ccol = cur[1] - 1, cur[2]
  -- The items strictly past the cursor, nearest first. On the one landed on last, by its index: two items can
  -- start at the same place.
  local ahead = {}
  local from
  if M.last_jump and M.last_jump.id then
    for i, it in ipairs(list) do
      if it.r.id == M.last_jump.id and it.row == crow and it.col == ccol then from = i end
    end
  end
  if from then
    for i = from + dir, dir > 0 and #list or 1, dir do ahead[#ahead + 1] = i end
  elseif dir > 0 then
    for i, it in ipairs(list) do
      if it.row > crow or (it.row == crow and it.col > ccol) then ahead[#ahead + 1] = i end
    end
  else
    for i = #list, 1, -1 do
      local it = list[i]
      if it.row < crow or (it.row == crow and it.col < ccol) then ahead[#ahead + 1] = i end
    end
  end
  if #ahead >= count then
    return cb(land(win, b, list, ahead[count])) or M.last_jump
  end
  -- Off the end: the project's files in the sidebar's order, from the one after this, round to this one.
  local paths = {}
  for path in pairs(p and p.docs or {}) do paths[#paths + 1] = path end
  table.sort(paths, M.path_lt)
  if #paths == 0 or (b and not b.path) then
    if #list == 0 then return fail('no comments here') end
    local i = dir > 0 and ((count - #ahead - 1) % #list) + 1 or #list - ((count - #ahead - 1) % #list)
    return cb(land(win, b, list, i)) or M.last_jump
  end
  local here = dir > 0 and 0 or #paths + 1 -- not a doc: from the first (last) file
  for i, path in ipairs(paths) do
    if b and path == b.path then here = i end
  end
  local ring = {}
  for k = 1, #paths do
    ring[#ring + 1] = paths[((here - 1 + dir * k) % #paths) + 1]
  end -- ends with this file
  file_counts(ring, function(n)
    local total = 0
    for _, path in ipairs(ring) do total = total + (n[path] or 0) end
    if total == 0 then
      return fail('no open comments or changes in the project')
    end
    local left = (count - #ahead - 1) % total + 1 -- the left-th item along the ring
    for _, path in ipairs(ring) do
      local k = n[path] or 0
      if left <= k then
        local function at(nb)
          if not nb then return fail('could not open ' .. path) end
          local l = M.jump_items(nb)
          if #l == 0 then return fail('no comments in ' .. path) end
          local i = dir > 0 and math.min(left, #l) or math.max(1, #l - left + 1)
          cb(land(win, nb, l, i, not b or path ~= b.path))
        end
        if b and path == b.path then return at(b) end
        return open_doc(win, path, left, at)
      end
      left = left - k
    end
  end)
  return { ok = true, pending = true }
end

-- ---- verbs at the cursor (ga / gx / gC, the app's Review menu) ----------------------------------------------------

-- The item under the cursor that `verb` acts on: accept/reject take tracked changes, resolve comments. The one the
-- last jump landed on wins when several are here.
function M.item_here(verb)
  local win = M.target() or api.nvim_get_current_win()
  local b = Buffer.by_buf[api.nvim_win_get_buf(win)]
  if not b then return nil end
  local c = api.nvim_win_get_cursor(win)
  local row, col = c[1] - 1, c[2]
  local function inside(it)
    local after = row > it.row or (row == it.row and col >= it.col)
    local before = row < it.end_row or (row == it.end_row and (col < it.end_col or (it.end_row == it.row and it.end_col == it.col and col == it.col)))
    return after and before
  end
  local want = verb == 'resolve' and 'comment' or 'change'
  local hit
  for _, it in ipairs(b:review_items(false)) do
    local is = it.r.kind == 'comment' and 'comment' or 'change'
    if is == want and inside(it) then
      if M.last_jump and M.last_jump.id == it.r.id then return it, b end
      hit = hit or it
    end
  end
  return hit, b
end

-- Accept / reject the tracked change here, or resolve the comment here, then on to the next item (as ]r).
-- `fallback`: keys to run instead when there is nothing of that kind here (ga / gx keep their built-in meaning).
function M.verb(verb, fallback, cb)
  cb = cb or function() end
  local it, b = M.item_here(verb)
  if not it then
    if fallback then
      api.nvim_feedkeys(api.nvim_replace_termcodes(fallback, true, false, true), 'n', false)
      return cb({ fallback = true })
    end
    local msg = verb == 'resolve' and 'no comment here' or 'no tracked change here'
    api.nvim_echo({ { msg, 'WarningMsg' } }, false, {})
    return cb({ error = msg })
  end
  local method = verb == 'resolve' and 'thread.resolve' or ('change.' .. verb)
  local params = verb == 'resolve' and { thread_id = it.r.thread_id, doc_id = b.doc_id } or { doc_id = b.doc_id, ids = { it.r.id } }
  local ok, err = request(method, params, function(e)
    if e then
      api.nvim_echo({ { tostring(e.message or e), 'ErrorMsg' } }, false, {})
      return cb({ error = tostring(e.message or e) })
    end
    vim.schedule(function()
      M.last_jump = nil
      M.jump(1, 1, function(res) cb({ done = verb, next = res }) end)
    end)
  end)
  if not ok then cb({ error = err }) end
end

-- ---- preview: the text as if every suggestion were accepted (or rejected) ------------------------------------------

M.previewing = nil -- {mode, win, buf (the live one), view, winbar, scratch}

-- The buffer's text with the tracked changes applied: 'accepted' keeps insertions and drops deleted text (a
-- history-ot deletion still in the text); 'rejected' drops insertions and puts deleted text back. Pure: lines in,
-- lines out. items: {kind, row, col, end_row, end_col, text}.
function M.previewed_lines(lines, items, mode)
  local starts, acc = {}, 0
  for i, l in ipairs(lines) do
    starts[i] = acc
    acc = acc + #l + 1
  end
  local text = table.concat(lines, '\n')
  local function off(row, col) return (starts[row + 1] or acc) + col end
  local edits = {}
  for _, it in ipairs(items) do
    local a, b = off(it.row, it.col), off(it.end_row, it.end_col)
    if it.kind == 'tracked_insert' and mode == 'rejected' then
      edits[#edits + 1] = { a, b, '' }
    elseif it.kind == 'tracked_delete' then
      if b > a and mode == 'accepted' then
        edits[#edits + 1] = { a, b, '' } -- (history-ot: the deleted text is still in the buffer)
      elseif b == a and mode == 'rejected' then
        edits[#edits + 1] = { a, a, it.text or '' }
      end
    end
  end
  table.sort(edits, function(x, y) return x[1] > y[1] end)
  for _, e in ipairs(edits) do
    text = text:sub(1, e[1]) .. e[3] .. text:sub(e[2] + 1)
  end
  return vim.split(text, '\n', { plain = true })
end

-- mode: 'accepted' | 'rejected' | 'off' (back to the live text, exactly as it was).
function M.preview(mode)
  local pv = M.previewing
  if mode == 'off' or mode == nil then
    if not pv then return { ok = true, mode = 'off' } end
    M.previewing = nil
    if api.nvim_win_is_valid(pv.win) and api.nvim_buf_is_valid(pv.buf) then
      api.nvim_win_set_buf(pv.win, pv.buf)
      vim.wo[pv.win].winbar = pv.winbar
      api.nvim_win_call(pv.win, function() vim.fn.winrestview(pv.view) end)
    end
    if api.nvim_buf_is_valid(pv.scratch) then pcall(api.nvim_buf_delete, pv.scratch, { force = true }) end
    M.schedule('preview')
    for c in pairs(M.chans) do pcall(vim.rpcnotify, c, 'taudot_preview', { mode = 'off' }) end
    return { ok = true, mode = 'off' }
  end
  if mode ~= 'accepted' and mode ~= 'rejected' then
    return { ok = false, error = 'preview accepted, rejected or off' }
  end
  local win = pv and pv.win or M.target() or api.nvim_get_current_win()
  local live = pv and pv.buf or api.nvim_win_get_buf(win)
  local b = Buffer.by_buf[live]
  if not b then return { ok = false, error = 'this buffer is not a taudot doc' } end
  local items = {}
  for _, it in ipairs(b:review_items(false)) do
    if it.r.kind ~= 'comment' then
      items[#items + 1] = { kind = it.r.kind, row = it.row, col = it.col, end_row = it.end_row, end_col = it.end_col, text = it.r.text }
    end
  end
  local lines = M.previewed_lines(api.nvim_buf_get_lines(live, 0, -1, false), items, mode)
  local view = pv and pv.view or api.nvim_win_call(win, vim.fn.winsaveview)
  local scratch = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(scratch, 0, -1, false, lines)
  vim.bo[scratch].filetype = vim.bo[live].filetype
  vim.bo[scratch].modifiable = false
  vim.bo[scratch].bufhidden = 'wipe'
  pcall(api.nvim_buf_set_name, scratch, ('taudot-preview://%s/%s'):format(mode, b.path or 'doc'))
  local function back() M.preview('off') end
  for _, k in ipairs({ '<Esc>', 'q' }) do
    vim.keymap.set('n', k, back, { buffer = scratch, nowait = true, desc = 'Taudot: leave the preview' })
  end
  local old = pv and pv.scratch
  local winbar = pv and pv.winbar or vim.wo[win].winbar
  api.nvim_set_hl(0, 'TaudotPreviewBanner', { link = 'DiffChange', default = true })
  api.nvim_win_set_buf(win, scratch)
  vim.wo[win].winbar = ('%%#TaudotPreviewBanner#  Preview: every suggestion %s · read-only · Esc to go back  %%*'):format(mode)
  api.nvim_win_call(win, function() vim.fn.winrestview({ topline = view.topline, lnum = math.min(view.lnum, #lines), col = view.col }) end)
  if old and api.nvim_buf_is_valid(old) then pcall(api.nvim_buf_delete, old, { force = true }) end
  M.previewing = { mode = mode, win = win, buf = live, view = view, winbar = winbar, scratch = scratch }
  for c in pairs(M.chans) do pcall(vim.rpcnotify, c, 'taudot_preview', { mode = mode, path = b.path or vim.NIL }) end
  return { ok = true, mode = mode, lines = #lines }
end

-- ---- the overview: every comment and change in the project (the GUI's "All") -------------------------------------

local function ov_item(r, path, line)
  local p = project()
  local a = r.kind == 'comment' and review.thread_author(r) or r.author
  local t = r.kind == 'comment' and p and p.threads and p.threads[r.thread_id] or nil
  local msgs = t and t.messages or {}
  local lastm = msgs[#msgs]
  local resolved = r.kind == 'comment' and ((t and t.resolved == true) or (not t and r.resolved == true)) or false
  return {
    id = r.id,
    kind = r.kind,
    thread_id = r.thread_id or vim.NIL,
    path = path,
    line = line or vim.NIL,
    quote = r.text or '',
    author = user(a),
    color = color_of(a) or vim.NIL,
    text = msgs[1] and msgs[1].text or '',
    replies = math.max(0, #msgs - 1),
    ts = (lastm and lastm.ts) or r.ts or vim.NIL,
    resolved = resolved,
    mine = type(a) == 'table' and p ~= nil and a.user_id == p.me,
  }
end

-- cb({files = [{path, items = [item]}]}): the docs in the sidebar's order, each one's comments (resolved too) and
-- tracked changes in text order. Open buffers from their marks (with `line`); the others from doc.ranges.
function M.overview(cb)
  local p = project()
  if not p then
    return cb({ files = {} })
  end
  local paths = {}
  for path in pairs(p.docs or {}) do paths[#paths + 1] = path end
  table.sort(paths, M.path_lt)
  local open = {}
  for _, b in pairs(Buffer.by_buf) do
    if b.path and not b.detached and api.nvim_buf_is_valid(b.buf) then open[b.path] = b end
  end
  local per, waiting, finished = {}, 0, false
  local function maybe()
    if waiting > 0 or finished then return end
    finished = true
    local files = {}
    for _, path in ipairs(paths) do
      if per[path] and #per[path] > 0 then files[#files + 1] = { path = path, items = per[path] } end
    end
    cb({ files = files })
  end
  for _, path in ipairs(paths) do
    local b = open[path]
    if b then
      local l = {}
      for _, it in ipairs(b:review_items(true)) do l[#l + 1] = ov_item(it.r, path, it.row) end
      per[path] = l
    elseif p.client and p.docs[path] then
      waiting = waiting + 1
      p.client:request('doc.ranges', { doc_id = p.docs[path] }, function(_, res)
        local rs = vim.deepcopy(res and res.ranges or {})
        table.sort(rs, function(x, y) return (x.start or 0) < (y.start or 0) end)
        local l = {}
        for _, r in ipairs(rs) do l[#l + 1] = ov_item(r, path, nil) end
        per[path] = l
        waiting = waiting - 1
        maybe()
      end)
    end
  end
  maybe()
end

-- From the overview: open `path` and land on item `id` as ]r does. cb(result | {error}).
function M.reveal(path, id, cb)
  cb = cb or function() end
  local p = project()
  if not p or type(path) ~= 'string' then return cb({ error = 'no project' }) end
  local win = M.target() or api.nvim_get_current_win()
  local function at(b)
    if not b then return cb({ error = 'could not open ' .. path }) end
    local list = b:review_items(true)
    for i, it in ipairs(list) do
      if it.r.id == id then return cb(land(win, b, list, i, false)) end
    end
    return false
  end
  local cur = Buffer.by_buf[api.nvim_win_get_buf(win)]
  if cur and cur.path == path then
    if at(cur) == false then cb({ error = 'not in ' .. path .. ' any more' }) end
    return
  end
  open_doc(win, path, 1, function(b)
    if not b then return cb({ error = 'could not open ' .. path }) end
    -- (its ranges may still be on their way: wait for this one)
    local t0 = vim.uv.now()
    local function try()
      if at(b) ~= false then return end
      if vim.uv.now() - t0 > 3000 then return cb({ error = 'not in ' .. path .. ' any more' }) end
      vim.defer_fn(try, 15)
    end
    try()
  end)
end

local function send(name, payload, cache)
  if payload == nil then
    return
  end
  -- Never twice the same: compared without the reason.
  local reason = payload.reason
  payload.reason = nil
  local enc = vim.json.encode(payload)
  payload.reason = reason
  for chan in pairs(M.chans) do
    if cache[chan] ~= enc then
      cache[chan] = enc
      if not pcall(vim.rpcnotify, chan, name, payload) then
        M.detach(chan)
      end
    end
  end
end

M.empty_hold_ms = 500
local queued_reason
local last_sent = { buf = nil, count = 0 } -- the last taudot_review sent: its buffer and how many items
local hold_timer

-- An empty item list for the buffer that just had items: hold it (see the header).
local function held(p)
  if not p.synced or #p.items > 0 or last_sent.buf ~= p.buf or last_sent.count == 0 then
    return false
  end
  local proj = project()
  if proj and proj.connection ~= 'online' then
    return true -- reconnecting: the ranges will come back
  end
  if not hold_timer then
    hold_timer = vim.defer_fn(function()
      hold_timer = nil
      local now = M.payload()
      now.reason = 'empty-held'
      -- Still empty after the hold: it's real.
      if now.buf == last_sent.buf and #now.items == 0 then
        last_sent.count = 0
      end
      M.flush(now)
    end, M.empty_hold_ms)
  end
  return true
end

function M.flush(p)
  if held(p) then
    return
  end
  last_sent.buf, last_sent.count = p.buf, #p.items
  send('taudot_review', p, last_payload)
end

-- Send the followed buffer's review state on the next tick (many changes in one tick send once). reason: what
-- asked (for the GUI's trace).
function M.schedule(reason)
  if next(M.chans) == nil then
    return
  end
  if reason and not (queued_reason or ''):find(reason, 1, true) then
    queued_reason = queued_reason and (queued_reason .. ',' .. reason) or reason
  end
  if queued then
    return
  end
  queued = true
  vim.schedule(function()
    queued = false
    local p = M.payload()
    local why = queued_reason or '?'
    p.reason = why
    queued_reason = nil
    M.flush(p)
    send('taudot_files', M.files_payload(), last_files)
    if why:find('redraw', 1, true) or why:find('attach', 1, true) then
      -- Threads or ranges changed somewhere: the overview, if the GUI shows it, asks again.
      for c in pairs(M.chans) do pcall(vim.rpcnotify, c, 'taudot_overview_changed', {}) end
    end
  end)
end

-- For the GUI's file tree, per file (paths from the project root): open comment threads, and who is in it now.
-- {comments = {[path] = n}, people = {[path] = [{name, initials, color}]}}
local thread_paths = {} -- thread_id -> path, kept: thread.changed's thread doesn't carry it
function M.files_payload()
  local p = project()
  local comments, people = vim.empty_dict(), vim.empty_dict()
  if not p then
    return { comments = comments, people = people }
  end
  -- Where each thread is: thread.list's path, else an open buffer's range with it.
  for _, b in pairs(Buffer.by_buf) do
    for _, r in ipairs(b.ranges or {}) do
      if r.kind == 'comment' and r.thread_id and b.path then thread_paths[r.thread_id] = b.path end
    end
  end
  for id, t in pairs(p.threads or {}) do
    if type(t) == 'table' then
      if type(t.path) == 'string' then thread_paths[id] = t.path end
      local path = thread_paths[id]
      if path and not t.resolved then comments[path] = (comments[path] or 0) + 1 end
    end
  end
  local by_doc = {}
  for path, doc_id in pairs(p.docs or {}) do by_doc[doc_id] = path end
  for _, u in ipairs(p.users or {}) do
    local path = u.doc_id and by_doc[u.doc_id]
    if path and u.user_id ~= p.me then
      people[path] = people[path] or {}
      local seen = false
      for _, q in ipairs(people[path]) do if q.user_id == u.user_id then seen = true end end
      if not seen then
        local x = user(u)
        x.color = color_of(u) or vim.NIL
        table.insert(people[path], x)
      end
    end
  end
  return { comments = comments, people = people }
end

function M.schedule_cursor()
  if cursor_queued or next(M.chans) == nil then
    return
  end
  cursor_queued = true
  vim.schedule(function()
    cursor_queued = false
    send('taudot_review_cursor', M.cursor_payload(), last_cursor)
  end)
end

local function install()
  if installed then
    return
  end
  installed = true
  -- Ranges, threads and presence all end in review.redraw.
  local redraw = review.redraw
  review.redraw = function(...)
    redraw(...)
    M.schedule('redraw')
  end
  -- :Taudot comment (and <leader>ac) with no text: the GUI's draft card instead of Neovim's prompt.
  local comment = review.comment
  review.comment = function(args, ...)
    local text = type(args) == 'table' and table.concat(args, ' ') or ''
    if next(M.chans) == nil or text ~= '' then
      return comment(args, ...)
    end
    local r = M.start_comment()
    for chan in pairs(M.chans) do
      if not pcall(vim.rpcnotify, chan, 'taudot_review_start', r) then
        M.detach(chan)
      end
    end
  end
  -- init.lua's :Taudot table took the function when it loaded.
  local ok, ts = pcall(require, 'taudot')
  if ok and type(ts.subcommands) == 'table' and ts.subcommands.comment == comment then
    ts.subcommands.comment = review.comment
  end
  local group = api.nvim_create_augroup('taudot.gui', { clear = true })
  api.nvim_create_autocmd({ 'BufEnter', 'WinEnter', 'WinClosed', 'WinResized', 'VimResized', 'TextChanged', 'TextChangedI', 'ColorScheme' }, {
    group = group,
    callback = function(a)
      M.schedule(a.event)
      M.schedule_cursor()
    end,
  })
  api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI', 'ModeChanged' }, { group = group, callback = M.schedule_cursor })
  -- Wrapping changes the doc rows.
  api.nvim_create_autocmd('OptionSet', {
    group = group,
    pattern = { 'wrap', 'linebreak', 'breakindent', 'showbreak', 'number', 'relativenumber', 'signcolumn', 'foldcolumn', 'numberwidth' },
    callback = function() M.schedule('OptionSet') end,
  })
  -- A taudot buffer must not be reloaded from disk: the engine writes the file after our own edits, and a reload
  -- (autoread + checktime on FocusGained, which every trip into the margin and back fires) replaces the whole
  -- buffer and collapses every comment's extmark. The engine is the source of truth for these buffers: ignore.
  -- ('autoread' would reload an unchanged buffer without asking FileChangedShell: off, locally, on taudot buffers.)
  api.nvim_create_autocmd({ 'BufEnter', 'BufWinEnter' }, {
    group = group,
    callback = function(a)
      if next(M.chans) ~= nil and Buffer.by_buf[a.buf] then
        vim.bo[a.buf].autoread = false
      end
    end,
  })
  api.nvim_create_autocmd('FileChangedShell', {
    group = group,
    callback = function(a)
      if next(M.chans) ~= nil and Buffer.by_buf[a.buf] then
        vim.v.fcs_choice = ''
      else
        vim.v.fcs_choice = 'reload'
      end
    end,
  })
  api.nvim_create_autocmd('ModeChanged', {
    group = group,
    pattern = { '[vV\x16]*:*' },
    callback = function()
      local old = vim.v.event.old_mode:sub(1, 1)
      local new = vim.v.event.new_mode:sub(1, 1)
      if new == 'v' or new == 'V' or new == '\22' then
        return -- v to V and the like: still selecting
      end
      local buf = api.nvim_get_current_buf()
      if M.left_visual then
        pcall(api.nvim_buf_del_extmark, M.left_visual.buf, M.left_ns, M.left_visual.mark)
      end
      M.left_visual = nil
      local r = marks_range(buf, old)
      if r then
        local ok, id = pcall(api.nvim_buf_set_extmark, buf, M.left_ns, r.line, r.col, { end_row = r.end_line, end_col = r.end_col })
        if ok then
          M.left_visual = { buf = buf, at = vim.uv.now(), mark = id }
        end
      end
    end,
  })
end

-- chan: the UI's channel. Without it, the first attached UI's (nvim_exec_lua over RPC can't name its caller).
function M.attach(chan)
  if chan == nil or chan == vim.NIL then
    local u = api.nvim_list_uis()[1]
    chan = u and u.chan
    if not chan or chan == 0 then
      return false
    end
  end
  M.chans[chan] = true
  last_payload[chan], last_cursor[chan] = nil, nil
  install()
  last_sent.buf, last_sent.count = nil, 0
  for buf in pairs(Buffer.by_buf) do
    if api.nvim_buf_is_valid(buf) then
      vim.bo[buf].autoread = false
    end
  end
  M.schedule('attach')
  M.schedule_cursor()
  return true
end

function M.detach(chan)
  M.chans[chan] = nil
  if next(M.chans) == nil then
    M.margin_shown(false)
  end
  last_payload[chan], last_cursor[chan] = nil, nil
end

-- ---- actions ------------------------------------------------------------------------------------------------------

-- The item with this id in any taudot buffer: (range, buffer, item position).
find = function(id)
  for _, b in pairs(Buffer.by_buf) do
    for _, it in ipairs(b:review_items(true)) do
      if it.r.id == id or it.r.thread_id == id then
        return it.r, b, it
      end
    end
  end
end

local function done(chan, req)
  return function(err, res)
    if req == nil or req == vim.NIL then
      if err then
        vim.notify('Taudot: ' .. tostring(err.message or err), vim.log.levels.ERROR)
      end
      return
    end
    local out = { req = req, ok = err == nil }
    if err then
      out.error = tostring(err.message or err)
    else
      out.result = res
    end
    if chan then
      pcall(vim.rpcnotify, chan, 'taudot_review_done', out)
    else
      for c in pairs(M.chans) do
        pcall(vim.rpcnotify, c, 'taudot_review_done', out)
      end
    end
  end
end

request = function(method, params, cb)
  local p = project()
  if not p or not p.client then
    return false, 'no project open'
  end
  params.project_id = params.project_id or p.project_id
  p.client:request(method, params, cb)
  return true
end

-- comment.add once our own edits are acknowledged, so the offsets are measured on a text the engine knows.
local function add_comment(b, args, cb, tries)
  b:settle()
  if b.inflight or b.pending then
    if (tries or 0) > 100 then
      return cb({ message = 'edits still being sent; try again' })
    end
    return vim.defer_fn(function()
      add_comment(b, args, cb, (tries or 0) + 1)
    end, 30)
  end
  local buf = b.buf
  local ok, start = pcall(api.nvim_buf_get_offset, buf, args.line)
  local ok2, stop = pcall(api.nvim_buf_get_offset, buf, args.end_line)
  if not ok or not ok2 then
    return cb({ message = 'range is outside the buffer' })
  end
  start, stop = start + args.col, stop + args.end_col
  if stop <= start then
    return cb({ message = 'select some text to comment on' })
  end
  request('comment.add', { doc_id = b.doc_id, start = start, ['end'] = stop, seq = b.seq, text = args.text }, cb)
end

local function nonempty(s)
  return type(s) == 'string' and s:match('%S') ~= nil
end

-- kind, id, args: see the header. chan: who asked (taudot_review_done goes there; all GUIs when nil).
function M.act(kind, id, args, chan)
  args = type(args) == 'table' and args or {}
  local cb = done(chan, args.req)
  if kind == 'comment' then
    local b = Buffer.by_buf[args.buf or api.nvim_get_current_buf()]
    if not b then
      return { ok = false, error = 'this buffer is not a taudot doc' }
    end
    if not nonempty(args.text) then
      return { ok = false, error = 'empty comment' }
    end
    for _, k in ipairs({ 'line', 'col', 'end_line', 'end_col' }) do
      if type(args[k]) ~= 'number' then
        return { ok = false, error = 'comment needs ' .. k }
      end
    end
    if args.end_line < args.line or (args.end_line == args.line and args.end_col <= args.col) then
      return { ok = false, error = 'select some text to comment on' }
    end
    add_comment(b, args, cb)
    return { ok = true }
  end

  if kind == 'start_comment' then
    return M.start_comment()
  end
  if kind == 'margin_shown' then
    return M.margin_shown(args.shown == true)
  end
  if kind == 'select' then
    return M.select(id)
  end
  if kind == 'open' then
    return M.open(args.path)
  end
  if kind == 'preview' then
    return M.preview(args.mode)
  end
  if kind == 'layout' then
    M.center_on_land = args.stacked == true
    return { ok = true }
  end
  if kind == 'kinds' then
    M.kinds = { comments = args.comments ~= false, suggestions = args.suggestions ~= false }
    return { ok = true }
  end
  if kind == 'show_resolved' then
    M.show_resolved = args.on == true
    return { ok = true }
  end
  if kind == 'accept_many' or kind == 'reject_many' then
    -- {ids}: tracked changes (a grouped card, or a whole file), per doc in one request each
    local per = {}
    for _, cid in ipairs(type(args.ids) == 'table' and args.ids or {}) do
      local r, b = find(cid)
      if r and r.kind ~= 'comment' then
        per[b.doc_id] = per[b.doc_id] or {}
        table.insert(per[b.doc_id], r.id)
      end
    end
    if next(per) == nil then
      return { ok = false, error = 'no tracked changes to ' .. kind:gsub('_many', '') }
    end
    local method = kind == 'accept_many' and 'change.accept' or 'change.reject'
    local left, failed = vim.tbl_count(per), nil
    for doc_id, ids in pairs(per) do
      local ok, err = request(method, { doc_id = doc_id, ids = ids }, function(e, res)
        failed = failed or e
        left = left - 1
        if left == 0 then cb(failed, res) end
      end)
      if not ok then return { ok = false, error = err } end
    end
    return { ok = true }
  end
  if kind == 'overview' then
    M.overview(function(res) cb(nil, res) end)
    return { ok = true }
  end
  if kind == 'reveal' then
    M.reveal(args.path, id, function(res) cb(res.error, res) end)
    return { ok = true }
  end
  if kind == 'jump' then
    -- {dir = 1|-1, count?}: the result (taudot_review_done with args.req) once landed
    M.jump(args.dir == -1 and -1 or 1, args.count, function(res)
      cb(nil, res) -- (a miss is an answer, echoed already)
    end)
    return { ok = true }
  end

  local r, b, it = find(id)
  if not r and type(args.path) == 'string' then
    -- From the overview: an item in a file that isn't open. Threads by id; changes in that doc.
    local p = project()
    local doc_id = p and p.docs and p.docs[args.path]
    local t = p and p.threads and p.threads[id]
    if doc_id and (kind == 'accept' or kind == 'reject') then
      local ok, err = request('change.' .. kind, { doc_id = doc_id, ids = { id } }, cb)
      return ok and { ok = true } or { ok = false, error = err }
    elseif t and (kind == 'resolve' or kind == 'reopen' or kind == 'delete') then
      local ok, err = request('thread.' .. kind, { thread_id = id, doc_id = doc_id }, cb)
      return ok and { ok = true } or { ok = false, error = err }
    end
  end
  if not r then
    return { ok = false, error = 'no comment or change ' .. tostring(id) }
  end
  local is_comment = r.kind == 'comment'
  local ok, err
  if kind == 'goto' then
    local win = vim.fn.bufwinid(b.buf)
    if win == -1 then
      api.nvim_set_current_buf(b.buf)
      win = 0
    end
    pcall(api.nvim_win_set_cursor, win, { it.row + 1, it.col })
    return { ok = true }
  elseif kind == 'accept' or kind == 'reject' then
    if is_comment then
      return { ok = false, error = kind .. ' is for tracked changes' }
    end
    ok, err = request('change.' .. kind, { doc_id = b.doc_id, ids = { r.id } }, cb)
  elseif not is_comment then
    return { ok = false, error = kind .. ' is for comments' }
  elseif kind == 'reply' then
    if not nonempty(args.text) then
      return { ok = false, error = 'empty reply' }
    end
    ok, err = request('thread.reply', { thread_id = r.thread_id, text = args.text }, cb)
  elseif kind == 'resolve' or kind == 'reopen' or kind == 'delete' then
    ok, err = request('thread.' .. kind, { thread_id = r.thread_id, doc_id = b.doc_id }, cb)
  elseif kind == 'edit_message' then
    if not nonempty(args.text) or args.message_id == nil then
      return { ok = false, error = 'edit_message needs message_id and text' }
    end
    ok, err = request('message.edit', { thread_id = r.thread_id, message_id = args.message_id, text = args.text }, cb)
  elseif kind == 'delete_message' then
    if args.message_id == nil then
      return { ok = false, error = 'delete_message needs message_id' }
    end
    ok, err = request('message.delete', { thread_id = r.thread_id, message_id = args.message_id }, cb)
  else
    return { ok = false, error = 'unknown action ' .. tostring(kind) }
  end
  return ok and { ok = true } or { ok = false, error = err }
end

return M
