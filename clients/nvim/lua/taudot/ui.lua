-- Drawing: author colours that fade, unconfirmed text, collaborator cursors, comments.
--
-- Colours come from the user's colourscheme. Every group is a `default` link to an existing group, so a colourscheme
-- or the user can override it. The fade steps are blended at runtime from the author group's colour and Normal's
-- background, never from hard-coded values.

local api = vim.api
local config = require('taudot.config')

local M = {}

M.ns = {
  author = api.nvim_create_namespace('taudot.author'),
  unconfirmed = api.nvim_create_namespace('taudot.unconfirmed'),
  cursor = api.nvim_create_namespace('taudot.cursor'),
  comment = api.nvim_create_namespace('taudot.comment'),
  inline = api.nvim_create_namespace('taudot.inline'),
}

local FADE_STEPS = 6
-- Comment tint: from faint (step 0, cursor elsewhere) to bright (TINT_STEPS, cursor inside), in TINT_MS.
local TINT_STEPS = 4
local TINT_LO, TINT_HI = 0.09, 0.28
M.tint_ms = 120
local authors = {} -- user_id -> index
local n_authors = 0

local function link(name, to)
  api.nvim_set_hl(0, name, { link = to, default = true })
end

local function resolved(name)
  return api.nvim_get_hl(0, { name = name, link = false })
end

local function blend(fg, bg, alpha)
  local function ch(c, shift)
    return math.floor(c / 2 ^ shift) % 256
  end
  local out = 0
  for _, shift in ipairs({ 16, 8, 0 }) do
    local v = math.floor(ch(fg, shift) * alpha + ch(bg, shift) * (1 - alpha) + 0.5)
    out = out + v * 2 ^ shift
  end
  return out
end

-- The terminal's own background, asked with OSC 11. Used when the colourscheme leaves Normal's background unset
-- (transparent), so fades can still blend into what is really on screen, which in Rex is the theme's background.
M.term_bg = nil
local asked = false

function M.query_terminal()
  if asked or not api.nvim_ui_send then
    return
  end
  if #api.nvim_list_uis() == 0 then
    -- started with -c or from a plugin manager before the UI attached: ask once it has
    if vim.v.vim_did_enter == 0 or not M._wait_ui then
      M._wait_ui = true
      api.nvim_create_autocmd('UIEnter', { once = true, callback = M.query_terminal })
    end
    return
  end
  asked = true
  api.nvim_create_autocmd('TermResponse', {
    group = api.nvim_create_augroup('taudot.termresponse', { clear = true }),
    callback = function(ev)
      local seq = type(ev.data) == 'table' and ev.data.sequence or vim.v.termresponse
      local r, g, b = (seq or ''):match('^\27%]11;rgb:(%x+)/(%x+)/(%x+)')
      if not r then
        return
      end
      local function c(h)
        return math.floor(tonumber(h, 16) / (16 ^ #h - 1) * 255 + 0.5)
      end
      M.term_bg = c(r) * 65536 + c(g) * 256 + c(b)
      vim.schedule(M.define_highlights)
      return true -- one answer is enough
    end,
  })
  -- An answer can get lost while Neovim is still starting up, so ask again a couple of times.
  local tries = 0
  local function ask()
    if M.term_bg or tries >= 4 then
      return
    end
    tries = tries + 1
    api.nvim_ui_send('\27]11;?\7')
    vim.defer_fn(ask, 400 * tries)
  end
  ask()
end

-- (Re)define every group. Runs on setup and on ColorScheme.
function M.define_highlights()
  local groups = config.options.author_groups
  for i, g in ipairs(groups) do
    link('TaudotAuthor' .. i, g)
  end
  link('TaudotUnconfirmed', 'TaudotUnconfirmedDefault')
  api.nvim_set_hl(0, 'TaudotUnconfirmedDefault', { underdotted = true })
  link('TaudotComment', 'DiagnosticUnderlineInfo')
  link('TaudotCommentSign', 'DiagnosticSignInfo')
  link('TaudotCommentResolved', 'Comment')
  link('TaudotTrackChanges', 'DiagnosticWarn')
  link('TaudotStatusOnline', 'DiagnosticOk')
  link('TaudotStatusBusy', 'DiagnosticWarn')
  link('TaudotStatusOffline', 'DiagnosticError')
  -- Review: inline text, panel cards, input float.
  link('TaudotInline', 'Comment')
  link('TaudotPanelTitle', 'Title')
  link('TaudotPanelTime', 'Comment')
  link('TaudotPanelQuote', 'String')
  link('TaudotPanelText', 'Normal')
  link('TaudotPanelSeparator', 'WinSeparator')
  link('TaudotPanelHint', 'Comment')
  link('TaudotPanelResolved', 'Comment')
  link('TaudotPanelCurrent', 'CursorLine')
  link('TaudotPanelInsert', 'DiffAdd')
  link('TaudotPanelDelete', 'DiffDelete')
  link('TaudotInputTitle', 'FloatTitle')
  link('TaudotInputFooter', 'Comment')

  local normal = resolved('Normal')
  local bg = normal.bg or M.term_bg
  if not normal.bg then
    M.query_terminal()
  end
  local tgc = vim.o.termguicolors
  for i = 1, #groups do
    local a = resolved('TaudotAuthor' .. i)
    local fg = a.fg or a.sp
    -- Fade: a background tint that thins out step by step, then nothing.
    for s = 1, FADE_STEPS do
      local name = ('TaudotFade%d_%d'):format(i, s)
      local alpha = 0.45 * (1 - (s - 1) / FADE_STEPS)
      if tgc and fg and bg then
        api.nvim_set_hl(0, name, { bg = blend(fg, bg, alpha) })
      elseif tgc and fg and normal.fg then
        -- No background to blend into (transparent colourscheme): fade the text colour back to Normal instead.
        api.nvim_set_hl(0, name, { fg = blend(fg, normal.fg, 1 - (s - 1) / FADE_STEPS), underline = s == 1 })
      elseif tgc and fg then
        api.nvim_set_hl(0, name, { fg = fg, underline = s <= FADE_STEPS / 2 })
      else
        -- 256-colour terminals: use the terminal's own ANSI palette, so the colours follow the terminal theme.
        local cterm = a.ctermfg or (i % 6) + 1
        api.nvim_set_hl(0, name, { ctermfg = cterm, underline = s <= FADE_STEPS / 2 })
      end
    end
    -- Cursor: the author colour as a block, label in the same colour.
    -- Tracked changes: inserts underlined in the author colour on a light tint, deletes struck through in it.
    if tgc and fg then
      api.nvim_set_hl(0, 'TaudotCursor' .. i, { fg = bg, bg = fg })
      api.nvim_set_hl(0, 'TaudotCursorLabel' .. i, { fg = fg, bold = true })
      api.nvim_set_hl(0, 'TaudotTrackedInsert' .. i, { sp = fg, underline = true, bg = bg and blend(fg, bg, 0.15) or nil })
      api.nvim_set_hl(0, 'TaudotTrackedDelete' .. i, { fg = fg, strikethrough = true })
    else
      local cterm = a.ctermfg or (i % 6) + 1
      api.nvim_set_hl(0, 'TaudotCursor' .. i, { ctermbg = cterm, ctermfg = 0 })
      api.nvim_set_hl(0, 'TaudotCursorLabel' .. i, { ctermfg = cterm, bold = true })
      api.nvim_set_hl(0, 'TaudotTrackedInsert' .. i, { ctermfg = cterm, underline = true })
      api.nvim_set_hl(0, 'TaudotTrackedDelete' .. i, { ctermfg = cterm, strikethrough = true })
    end
    -- Comments (comment_style): a tint in the author colour, faint to bright; the bar's sign, dim and bright.
    for s = 0, TINT_STEPS do
      local alpha = TINT_LO + (TINT_HI - TINT_LO) * s / TINT_STEPS
      local t, u
      if tgc and fg and bg then
        t = { bg = blend(fg, bg, alpha) }
        u = { bg = t.bg, sp = fg, underline = true }
      elseif tgc and fg then
        -- Nothing to blend into: an underline in the author colour, bold while inside.
        t = { sp = fg, underline = true, bold = s == TINT_STEPS }
        u = t
      else
        local cterm = a.ctermfg or (i % 6) + 1
        t = { ctermfg = s == TINT_STEPS and cterm or nil, underline = true }
        u = t
      end
      api.nvim_set_hl(0, ('TaudotCommentTint%d_%d'):format(i, s), t)
      api.nvim_set_hl(0, ('TaudotCommentTintU%d_%d'):format(i, s), u)
      if tgc and fg then
        api.nvim_set_hl(0, ('TaudotCommentBar%d_%d'):format(i, s), { fg = bg and blend(fg, bg, 0.45 + 0.55 * s / TINT_STEPS) or fg })
      else
        api.nvim_set_hl(0, ('TaudotCommentBar%d_%d'):format(i, s), { ctermfg = a.ctermfg or (i % 6) + 1, bold = s == TINT_STEPS })
      end
    end
  end
end

-- ---- comment styles -----------------------------------------------------------------------------------------------

-- A comment's groups at tint step s (0 faint .. TINT_STEPS bright) in the configured style: hl_group (nil: the
-- text isn't coloured) and the sign's group.
function M.comment_groups(r, s)
  local style = config.options.comment_style or 'tint'
  -- comments_hidden (the GUI's View ▸ Comments in the Text off): the range stays, uncoloured and unsigned
  if config.options.comments_hidden then
    return nil, nil
  end
  if r.resolved then
    return 'TaudotCommentResolved', 'TaudotCommentResolved'
  end
  if style == 'underline' then
    return 'TaudotComment', 'TaudotCommentSign'
  end
  local i = M.author_index(r.author)
  local sign = ('TaudotCommentBar%d_%d'):format(i, s)
  if style == 'bar' then
    return nil, sign
  elseif style == 'tint+underline' then
    return ('TaudotCommentTintU%d_%d'):format(i, s), sign
  end
  return ('TaudotCommentTint%d_%d'):format(i, s), sign
end

-- Brightening: per buffer, comment range id -> { step, target }. The extmarks' options, to set them again.
M.tint = {}
local mark_opts = {} -- buf -> extmark id -> { r, opts }
local tint_timer

local function restyle(buf, mid, entry, s)
  local hl, sign = M.comment_groups(entry.r, s)
  if entry.opts.hl_group == hl and entry.opts.sign_hl_group == sign then
    return
  end
  local m = api.nvim_buf_get_extmark_by_id(buf, M.ns.comment, mid, { details = true })
  if not m or not m[1] then
    return
  end
  entry.opts.hl_group, entry.opts.sign_hl_group = hl, sign
  local o = vim.tbl_extend('force', entry.opts, { id = mid, end_row = m[3].end_row, end_col = m[3].end_col })
  pcall(api.nvim_buf_set_extmark, buf, M.ns.comment, m[1], m[2], o)
end

local function tint_tick()
  local busy = false
  for buf, states in pairs(M.tint) do
    if not api.nvim_buf_is_valid(buf) then
      M.tint[buf], mark_opts[buf] = nil, nil
    else
      for mid, entry in pairs(mark_opts[buf] or {}) do
        local st = states[entry.r.id]
        if st and st.step ~= st.target then
          st.step = st.step + (st.target > st.step and 1 or -1)
          restyle(buf, mid, entry, st.step)
          busy = busy or st.step ~= st.target
        end
      end
      for id, st in pairs(states) do
        if st.step == 0 and st.target == 0 then
          states[id] = nil
        end
      end
    end
  end
  if not busy and tint_timer then
    tint_timer:stop()
  end
end

-- The cursor is at (row, col) in buf: comments that contain it brighten, the others fade back (one step per
-- tint_ms / TINT_STEPS; tint_ms 0 jumps).
function M.touch(buf, by_id, row, col)
  if not by_id or (config.options.comment_style or 'tint') == 'underline' then
    return
  end
  local inside = {}
  for _, r in ipairs(M.ranges_at(buf, by_id, row, col)) do
    if r.kind == 'comment' then
      inside[r.id] = true
    end
  end
  local states = M.tint[buf] or {}
  M.tint[buf] = states
  local moving = false
  for id in pairs(inside) do
    states[id] = states[id] or { step = 0, target = 0 }
  end
  for id, st in pairs(states) do
    st.target = inside[id] and TINT_STEPS or 0
    moving = moving or st.step ~= st.target
  end
  if not moving then
    return
  end
  if M.tint_ms <= 0 then
    for mid, entry in pairs(mark_opts[buf] or {}) do
      local st = states[entry.r.id]
      if st then
        st.step = st.target
        restyle(buf, mid, entry, st.step)
      end
    end
    return
  end
  tint_timer = tint_timer or vim.uv.new_timer()
  if not tint_timer:is_active() then
    local step = math.max(1, math.floor(M.tint_ms / TINT_STEPS))
    tint_timer:start(0, step, vim.schedule_wrap(tint_tick))
  end
end

local touch_group
local function touch_autocmds()
  if touch_group then
    return
  end
  touch_group = api.nvim_create_augroup('taudot.comment_touch', { clear = true })
  api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI', 'BufEnter', 'WinEnter' }, {
    group = touch_group,
    callback = function(ev)
      local b = require('taudot.buffer').by_buf[ev.buf]
      if b and b.comments and api.nvim_get_current_buf() == ev.buf then
        local cur = api.nvim_win_get_cursor(0)
        M.touch(ev.buf, b.comments, cur[1] - 1, cur[2])
      end
    end,
  })
end

function M.author_index(user)
  local id = user and user.user_id or '?'
  if not authors[id] then
    n_authors = n_authors + 1
    authors[id] = ((n_authors - 1) % #config.options.author_groups) + 1
  end
  return authors[id]
end

-- ---- fading remote edits ------------------------------------------------------------------------------------------

local fading = {} -- { buf, id, idx, born }
local fade_timer

local function fade_tick()
  local now = vim.uv.now()
  local dur = config.options.fade_ms
  local keep = {}
  for _, f in ipairs(fading) do
    if api.nvim_buf_is_valid(f.buf) then
      local step = math.floor((now - f.born) / dur * FADE_STEPS) + 1
      local m = api.nvim_buf_get_extmark_by_id(f.buf, M.ns.author, f.id, { details = true })
      if step > FADE_STEPS or not m[1] then
        pcall(api.nvim_buf_del_extmark, f.buf, M.ns.author, f.id)
      else
        local d = m[3]
        if d.end_row and (d.end_row > m[1] or d.end_col > m[2]) then
          pcall(api.nvim_buf_set_extmark, f.buf, M.ns.author, m[1], m[2], {
            id = f.id,
            end_row = d.end_row,
            end_col = d.end_col,
            hl_group = ('TaudotFade%d_%d'):format(f.idx, step),
            priority = 150,
          })
          keep[#keep + 1] = f
        else
          pcall(api.nvim_buf_del_extmark, f.buf, M.ns.author, f.id)
        end
      end
    end
  end
  fading = keep
  M._fading = fading
  if #fading == 0 and fade_timer then
    fade_timer:stop()
  end
end

-- Mark text a collaborator just inserted, [row, col) to [end_row, end_col).
function M.mark_remote(buf, row, col, end_row, end_col, author)
  if end_row == row and end_col == col then
    return
  end
  local idx = M.author_index(author)
  local ok, id = pcall(api.nvim_buf_set_extmark, buf, M.ns.author, row, col, {
    end_row = end_row,
    end_col = end_col,
    hl_group = ('TaudotFade%d_1'):format(idx),
    priority = 150,
  })
  if not ok then
    return
  end
  fading[#fading + 1] = { buf = buf, id = id, idx = idx, born = vim.uv.now() }
  M._fading = fading
  if not fade_timer then
    fade_timer = vim.uv.new_timer()
  end
  if not fade_timer:is_active() then
    local step = math.floor(config.options.fade_ms / FADE_STEPS)
    fade_timer:start(step, step, vim.schedule_wrap(fade_tick))
  end
end

-- ---- own unconfirmed text -----------------------------------------------------------------------------------------

-- Called from on_bytes. The mark grows as you keep typing at its end (end_right_gravity).
function M.mark_unconfirmed(buf, row, col, end_row, end_col)
  if not config.options.underline_unconfirmed or (end_row == row and end_col == col) then
    return
  end
  pcall(api.nvim_buf_set_extmark, buf, M.ns.unconfirmed, row, col, {
    end_row = end_row,
    end_col = end_col,
    hl_group = 'TaudotUnconfirmed',
    right_gravity = false,
    end_right_gravity = true,
    priority = 140,
  })
end

function M.clear_unconfirmed(buf)
  api.nvim_buf_clear_namespace(buf, M.ns.unconfirmed, 0, -1)
end

-- ---- cursors ------------------------------------------------------------------------------------------------------

-- users: list of { user_id, name, initials, pos } already filtered to this buffer. pos_to_rc maps a byte offset.
function M.draw_cursors(buf, users, pos_to_rc)
  api.nvim_buf_clear_namespace(buf, M.ns.cursor, 0, -1)
  for _, u in ipairs(users) do
    local row, col = pos_to_rc(u.pos)
    if row then
      local idx = M.author_index(u)
      local line = api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ''
      local opts = { priority = 200 }
      if col < #line then
        local len = #(line:sub(col + 1):match('^[%z\1-\127\194-\244][\128-\191]*') or ' ')
        opts.end_row, opts.end_col = row, col + len
        opts.hl_group = 'TaudotCursor' .. idx
      end
      local label = config.options.cursor_label
      if label ~= 'none' then
        local text = (col >= #line and '▏' or '') .. u.initials
        opts.virt_text = { { label == 'inline' and text or ' ' .. text, 'TaudotCursorLabel' .. idx } }
        opts.virt_text_pos = label == 'inline' and 'inline' or 'eol'
      end
      pcall(api.nvim_buf_set_extmark, buf, M.ns.cursor, row, col, opts)
    end
  end
end

-- ---- comments and tracked changes ---------------------------------------------------------------------------------

-- "3 min ago", "2 h ago", "4 Nov".
function M.ago(ts)
  if type(ts) ~= 'number' then
    return ''
  end
  local s = os.time() - math.floor(ts / 1000)
  if s < 60 then
    return 'just now'
  elseif s < 3600 then
    return ('%d min ago'):format(math.floor(s / 60))
  elseif s < 86400 then
    return ('%d h ago'):format(math.floor(s / 3600))
  end
  return os.date('%-d %b', math.floor(ts / 1000))
end

local function oneline(s)
  return (s or ''):gsub('\n', '↵')
end

-- ranges: api.md ranges with start/end already in this buffer's bytes. Returns { [extmark id] = range }.
-- Comments: highlight and sign (resolved ones only with show_resolved). Tracked inserts: author colour, underlined.
-- Tracked deletes: the deleted text inline, struck through, in the author colour.
function M.draw_ranges(buf, ranges, pos_to_rc)
  api.nvim_buf_clear_namespace(buf, M.ns.comment, 0, -1)
  touch_autocmds()
  local by_id = {}
  local opts_by_id = {}
  local states = M.tint[buf] or {}
  local show_resolved = config.options.show_resolved
  for _, r in ipairs(ranges or {}) do
    local sr, sc = pos_to_rc(r.start)
    local er, ec = pos_to_rc(r['end'])
    if sr and er then
      local opts
      if r.kind == 'comment' and (show_resolved or not r.resolved) then
        local hl, sign = M.comment_groups(r, states[r.id] and states[r.id].step or 0)
        opts = {
          end_row = er,
          end_col = ec,
          hl_group = hl,
          sign_text = not config.options.comments_hidden and config.options.signs.comment or nil,
          sign_hl_group = sign,
          priority = 120,
        }
      elseif r.kind == 'tracked_insert' then
        local idx = M.author_index(r.author)
        opts = {
          end_row = er,
          end_col = ec,
          hl_group = 'TaudotTrackedInsert' .. idx,
          sign_text = config.options.signs.change,
          sign_hl_group = 'TaudotCursorLabel' .. idx,
          priority = 125,
        }
      elseif r.kind == 'tracked_delete' then
        local idx = M.author_index(r.author)
        opts = {
          sign_text = config.options.signs.change,
          sign_hl_group = 'TaudotCursorLabel' .. idx,
          priority = 125,
        }
        if sr == er and sc == ec then
          -- Classic: the text is gone from the doc; show it where it was.
          opts.virt_text = { { oneline(r.text), 'TaudotTrackedDelete' .. idx } }
          opts.virt_text_pos = 'inline'
          opts.right_gravity = false
        else
          -- history-ot: the deleted text is still in the doc.
          opts.end_row, opts.end_col, opts.hl_group = er, ec, 'TaudotTrackedDelete' .. idx
        end
      end
      if opts then
        local ok, id = pcall(api.nvim_buf_set_extmark, buf, M.ns.comment, sr, sc, opts)
        if ok then
          by_id[id] = r
          if r.kind == 'comment' then
            opts.end_row, opts.end_col = nil, nil
            opts_by_id[id] = { r = r, opts = opts }
          end
        end
      end
    end
  end
  mark_opts[buf] = opts_by_id
  if api.nvim_get_current_buf() == buf then
    -- A comment drawn under the cursor starts bright.
    local cur = api.nvim_win_get_cursor(0)
    M.touch(buf, by_id, cur[1] - 1, cur[2])
  end
  return by_id
end

-- End-of-line text on each line where an open comment starts: "▍ Bob: first words… (+2)". by_id as draw_ranges
-- returns it; empty to clear. threads: thread_id -> thread, or nil.
function M.draw_inline(buf, by_id, threads)
  if not api.nvim_buf_is_valid(buf) then
    return
  end
  api.nvim_buf_clear_namespace(buf, M.ns.inline, 0, -1)
  if next(by_id) == nil then
    return
  end
  local done = {}
  for _, m in ipairs(api.nvim_buf_get_extmarks(buf, M.ns.comment, 0, -1, {})) do
    local r, row = by_id[m[1]], m[2]
    if r and r.kind == 'comment' and not r.resolved and not done[row] then
      done[row] = true
      local t = threads and threads[r.thread_id]
      local msgs = t and t.messages or {}
      local first = msgs[1]
      local author = first and first.user or r.author
      local text = first and first.text or ('“' .. r.text .. '”')
      text = text:gsub('%s+', ' ')
      if vim.fn.strchars(text) > 40 then
        text = vim.fn.strcharpart(text, 0, 39) .. '…'
      end
      local chunks = {
        { '  ' .. config.options.signs.comment .. ' ', 'TaudotCursorLabel' .. M.author_index(author) },
        { ('%s: %s'):format(author and author.name ~= vim.NIL and author.name or '?', text), 'TaudotInline' },
      }
      if #msgs > 1 then
        chunks[#chunks + 1] = { (' (+%d)'):format(#msgs - 1), 'TaudotInline' }
      end
      pcall(api.nvim_buf_set_extmark, buf, M.ns.inline, row, 0, { virt_text = chunks, virt_text_pos = 'eol', priority = 90 })
    end
  end
end

-- Ranges under (row, col): comments and tracked inserts that contain it, tracked deletes at it.
function M.ranges_at(buf, by_id, row, col)
  local out = {}
  local marks = api.nvim_buf_get_extmarks(buf, M.ns.comment, 0, -1, { details = true })
  for _, m in ipairs(marks) do
    local id, sr, sc, d = m[1], m[2], m[3], m[4]
    local r = by_id[id]
    if r then
      local after_start = row > sr or (row == sr and col >= sc)
      local er, ec = d.end_row or sr, d.end_col or sc
      local before_end = row < er or (row == er and col < ec)
      local at_point = er == sr and ec == sc and row == sr and (col == sc or col == sc - 1)
      if (after_start and before_end) or at_point then
        out[#out + 1] = r
      end
    end
  end
  return out
end

-- Kept for callers of the old name.
function M.comments_at(buf, by_id, row, col)
  return vim.tbl_filter(function(r)
    return r.kind == 'comment'
  end, M.ranges_at(buf, by_id, row, col))
end

local function name(u)
  return u and u.name ~= vim.NIL and u.name or '?'
end

-- Lines for a float: each comment's thread (messages with author and time), each tracked change with its author.
-- threads: thread_id -> thread (api.md), or nil when the server has none.
function M.review_lines(ranges, threads)
  local lines = {}
  for _, r in ipairs(ranges) do
    if #lines > 0 then
      lines[#lines + 1] = '---'
    end
    if r.kind == 'comment' then
      local t = threads and threads[r.thread_id]
      local head = ('**Comment** on “%s”'):format(oneline(r.text))
      if t and t.resolved then
        head = head .. ('  _(resolved%s)_'):format(t.resolved_by ~= vim.NIL and t.resolved_by and (' by ' .. name(t.resolved_by)) or '')
      end
      lines[#lines + 1] = head
      local msgs = t and t.messages or {}
      if #msgs == 0 then
        lines[#lines + 1] = ('%s · %s'):format(name(r.author), threads and 'no messages' or 'this server has no comment threads')
      end
      for _, m in ipairs(msgs) do
        lines[#lines + 1] = ('**%s** · %s'):format(name(m.user), M.ago(m.ts))
        for _, l in ipairs(vim.split(m.text or '', '\n', { plain = true })) do
          lines[#lines + 1] = '  ' .. l
        end
      end
    else
      local verb = r.kind == 'tracked_insert' and 'Inserted' or 'Deleted'
      lines[#lines + 1] = ('**%s** by %s · %s'):format(verb, name(r.author), M.ago(r.ts))
      lines[#lines + 1] = '  “' .. oneline(r.text) .. '”'
    end
  end
  return lines
end

function M.show_review(ranges, threads, opts)
  local lines = M.review_lines(ranges, threads)
  opts = vim.tbl_extend('force', { border = 'single', focus_id = 'taudot_thread' }, opts or {})
  return vim.lsp.util.open_floating_preview(lines, 'markdown', opts)
end

-- Old entry point (one list of comment ranges).
function M.show_thread(ranges)
  return M.show_review(ranges, nil)
end

return M
