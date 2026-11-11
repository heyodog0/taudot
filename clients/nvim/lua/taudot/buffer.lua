-- One attached buffer: sends local edits from on_bytes, applies remote ones behind an echo guard.
--
-- Text model: the doc is the buffer's lines joined with "\n", plus a final "\n" when 'eol' is set. That is how
-- on_bytes counts bytes, so its byte offsets are doc offsets.
--
-- OT state, borrowed from the browser client: `inflight` is the one doc.edit waiting for its result, `pending` is
-- what was typed since. Both are ops (taudot.ot). A remote edit is written against `seq`, which includes neither,
-- so it is transformed past inflight and then pending before it is applied.

local api = vim.api
local ot = require('taudot.ot')
local ui = require('taudot.ui')
local config = require('taudot.config')

local M = {}
M.__index = M

---@type table<integer, table>
M.by_buf = {}

local function split_lines(s)
  return vim.split(s, '\n', { plain = true })
end

function M.buffer_text(buf)
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  local s = table.concat(lines, '\n')
  if vim.bo[buf].eol or vim.bo[buf].fixeol then
    s = s .. '\n'
  end
  return s
end

local function doc_len(buf)
  return api.nvim_buf_get_offset(buf, api.nvim_buf_line_count(buf))
end

-- Byte offset -> (row, col), or nil when past the end. An offset equal to the length is the start of the line after
-- the last one, which a buffer can't address: callers handle that.
function M.pos_to_rc(buf, pos)
  local n = api.nvim_buf_line_count(buf)
  if pos < 0 or pos > api.nvim_buf_get_offset(buf, n) then
    return nil
  end
  local lo, hi = 0, n - 1
  while lo < hi do
    local mid = math.floor((lo + hi + 1) / 2)
    if api.nvim_buf_get_offset(buf, mid) <= pos then
      lo = mid
    else
      hi = mid - 1
    end
  end
  local row = lo
  local col = pos - api.nvim_buf_get_offset(buf, row)
  local len = #(api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or '')
  if col > len then
    -- the final newline: report end of the last line
    col = len
  end
  return row, col
end

-- Every change to the doc's text here (`self.text`), in order: the user's (settle), the remote ones applied, a
-- rebase's, the first text. `edits`: byte offsets, applied one after another; nil: the whole text. The Mac app's
-- `taudot.app` (when loaded) hands them to its PDF pane, which typesets the buffer's own text without the engine round
-- trip (pdfpipe); `released` when the buffer stops being the doc.
--
-- The app's copy must equal the buffer, also when the buffer drifted from the doc (a remote edit applied wrongly):
-- then the buffer's own text goes whole (`text`), and so does every change after it until the doc's text is the
-- buffer's again (a settle or the rebase), since edits are made against the doc's text, not the app's copy.
local function text_changed(self, edits, text)
  local app = package.loaded['taudot.app']
  if not (app and app.text) then
    return
  end
  if text then
    self.fed_whole = true
    pcall(app.text, self, nil, text)
  elseif self.fed_whole or not edits then
    self.fed_whole = nil
    pcall(app.text, self, nil, self.text)
  else
    pcall(app.text, self, edits)
  end
end

local function released(self)
  local app = package.loaded['taudot.app']
  if app and app.text_released then
    pcall(app.text_released, self)
  end
end

---@param project table   init.lua's project: { client, project_id, folder }
function M.new(project, buf, doc)
  local self = setmetatable({
    project = project,
    buf = buf,
    doc_id = doc.doc_id,
    path = doc.path,
    seq = doc.seq,
    inflight = nil,
    pending = nil,
    applying = false,
    detached = false,
    comments = {}, -- extmark id -> range
    ranges = {},
    send_timer = nil,
    cursor_timer = nil,
    state = 'idle',
  }, M)
  M.by_buf[buf] = self
  return self
end

-- Called once doc.open returned. Makes the buffer match the engine and starts listening.
function M:start(text)
  local buf = self.buf
  if M.buffer_text(buf) ~= text then
    self.applying = true
    local lines = split_lines(text)
    if lines[#lines] == '' and #lines > 1 then
      table.remove(lines)
      vim.bo[buf].eol = true
    else
      vim.bo[buf].eol = false
      vim.bo[buf].fixeol = false
    end
    local view = vim.fn.winsaveview()
    api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.fn.winrestview(view)
    self.applying = false
  end
  self.text = M.buffer_text(buf)
  self.len = doc_len(buf)
  text_changed(self, nil)
  -- The engine's text at self.seq (without our unconfirmed edits): what a rebase diffs against.
  self.base = text
  if self.text ~= text or self.len ~= #text then
    vim.notify(('Taudot: %s: buffer is %d bytes, engine says %d'):format(self.path, self.len, #text), vim.log.levels.WARN)
  end
  vim.bo[buf].modified = false

  api.nvim_buf_attach(buf, false, {
    on_bytes = function(...)
      return self:on_bytes(...)
    end,
    on_detach = function()
      self.detached = true
      released(self)
    end,
    on_reload = function()
      -- :e! re-read the file. Resync from the engine.
      vim.schedule(function()
        self:resync()
      end)
    end,
  })

  local group = api.nvim_create_augroup('taudot.buf.' .. buf, { clear = true })
  api.nvim_create_autocmd('BufWriteCmd', {
    group = group,
    buffer = buf,
    callback = function()
      -- The engine owns the file on disk.
      vim.bo[buf].modified = false
      vim.api.nvim_echo({ { ('Taudot: %s is synced by the engine'):format(self.path) } }, false, {})
    end,
  })
  api.nvim_create_autocmd('FileChangedShell', {
    group = group,
    buffer = buf,
    callback = function()
      vim.v.fcs_choice = ''
    end,
  })
  api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI' }, {
    group = group,
    buffer = buf,
    callback = function()
      self:schedule_cursor()
      require('taudot.panel').follow(self)
    end,
  })
  api.nvim_create_autocmd({ 'BufWipeout', 'BufDelete' }, {
    group = group,
    buffer = buf,
    callback = function()
      self:detach()
    end,
  })
  if config.options.comment_K then
    vim.keymap.set('n', 'K', function()
      if not self:show_thread() then
        if #vim.lsp.get_clients({ bufnr = buf }) > 0 then
          vim.lsp.buf.hover()
        else
          vim.cmd('normal! K')
        end
      end
    end, { buffer = buf, desc = 'Taudot: comment thread, else hover' })
  end
  if config.options.hover then
    api.nvim_create_autocmd('CursorHold', {
      group = group,
      buffer = buf,
      callback = function()
        if api.nvim_get_current_buf() == buf and #self:ranges_here() > 0 then
          ui.show_review(self:ranges_here(), self.project.threads, { focusable = false })
        end
      end,
    })
  end
  require('taudot.keys').buffer(buf)
end

function M:detach()
  if self.detached then
    return
  end
  self.detached = true
  M.by_buf[self.buf] = nil
  released(self)
  pcall(api.nvim_del_augroup_by_name, 'taudot.buf.' .. self.buf)
  for _, ns in pairs(ui.ns) do
    pcall(api.nvim_buf_clear_namespace, self.buf, ns, 0, -1)
  end
end

-- ---- local edits --------------------------------------------------------------------------------------------------

-- on_bytes only records which byte ranges changed. The new text is read later, in settle(), once the buffer is in a
-- consistent state: during undo, Neovim sends several on_bytes after the buffer already holds the final text, so
-- reading text inside the callback can read the wrong thing.
--
-- spans describe the current buffer in terms of `self.text` (the doc as of the last settle): { s = start, n = len }
-- is n bytes copied from self.text at s, { n = len } is n new bytes.
local function replace(spans, off, del, ins)
  local out, pos = {}, 0
  local stop = off + del
  local placed = false
  local function add(sp)
    local last = out[#out]
    if sp.n == 0 then
      return
    end
    if last and not last.s and not sp.s then
      last.n = last.n + sp.n
    elseif last and last.s and sp.s and last.s + last.n == sp.s then
      last.n = last.n + sp.n
    else
      out[#out + 1] = sp
    end
  end
  for _, sp in ipairs(spans) do
    local a, b = pos, pos + sp.n
    -- part before the replaced range
    if a < off then
      local k = math.min(b, off) - a
      add({ s = sp.s, n = k })
    end
    if not placed and b >= off then
      add({ n = ins })
      placed = true
    end
    -- part after the replaced range
    if b > stop then
      local k = b - math.max(a, stop)
      add({ s = sp.s and (sp.s + sp.n - k), n = k })
    end
    pos = b
  end
  if not placed then
    add({ n = ins })
  end
  return out, pos
end

function M:on_bytes(_, _, _, _, _, off, _, _, oeb, _, _, neb)
  if self.detached then
    return true
  end
  if self.applying then
    return
  end
  local spans = self.spans or { { s = 0, n = #self.text } }
  local total
  spans, total = replace(spans, off, oeb, neb)
  if off + oeb > total then
    self.broken = ('on_bytes past the end (%d > %d)'):format(off + oeb, total)
  end
  self.spans = spans
  if not self.settle_scheduled then
    self.settle_scheduled = true
    vim.schedule(function()
      self:settle()
    end)
  end
end

-- Turn the recorded spans and the buffer's current text into one op, add it to pending, and schedule a send.
function M:settle()
  self.settle_scheduled = false
  local spans = self.spans
  if not spans or self.detached then
    return
  end
  self.spans = nil
  local buf = self.buf
  local old, new = self.text, M.buffer_text(buf)
  local comps, si, ti = {}, 0, 0
  local marks = {}
  local bad = self.broken
  self.broken = nil
  for _, sp in ipairs(spans) do
    if sp.s then
      if sp.s > si then
        comps[#comps + 1] = -(sp.s - si)
      end
      if not bad and old:sub(sp.s + 1, sp.s + sp.n) ~= new:sub(ti + 1, ti + sp.n) then
        bad = 'kept text does not match'
      end
      comps[#comps + 1] = sp.n
      si = sp.s + sp.n
    else
      comps[#comps + 1] = new:sub(ti + 1, ti + sp.n)
      marks[#marks + 1] = { ti, ti + sp.n }
    end
    ti = ti + sp.n
  end
  if #old > si then
    comps[#comps + 1] = -(#old - si)
  end
  if not bad and ti ~= #new then
    bad = ('buffer is %d bytes, changes add up to %d'):format(#new, ti)
  end
  if bad then
    -- Don't guess and send a wrong edit. Diff the whole text instead: still correct, just coarser.
    vim.notify(('Taudot: %s: %s, sending a diff instead'):format(self.path, bad), vim.log.levels.DEBUG)
    comps, marks = ot.diff_comps(old, new)
    self.fallbacks = (self.fallbacks or 0) + 1
  end
  local op = ot.from_comps(comps)
  assert(op.base == #old and op.target == #new, 'settle: op does not fit')
  self.text, self.len = new, #new
  text_changed(self, ot.to_edits(op))
  self.pending = self.pending and ot.compose(self.pending, op) or op
  for _, m in ipairs(marks) do
    local sr, sc = M.pos_to_rc(buf, m[1])
    local er, ec = M.pos_to_rc(buf, m[2])
    if sr and er then
      ui.mark_unconfirmed(buf, sr, sc, er, ec)
    end
  end
  self:schedule_send()
end

function M:schedule_send()
  if self.send_timer then
    return
  end
  self.send_timer = vim.defer_fn(function()
    self.send_timer = nil
    self:flush()
  end, config.options.send_delay)
end

function M:flush()
  if self.inflight or not self.pending or self.detached or self.rebasing then
    return
  end
  local client = self.project.client
  if not client or client.closed then
    return -- kept in pending until we reconnect
  end
  self.inflight, self.pending = self.pending, nil
  local edits = ot.to_edits(self.inflight)
  if #edits == 0 then
    self.inflight = nil
    return
  end
  self.state = 'inflight'
  self.project:changed()
  client:request('doc.edit', { doc_id = self.doc_id, seq = self.seq, edits = edits }, function(err, res)
    if err then
      if err.code == -1 or client.closed then
        -- The connection went: the engine may or may not have applied it. Keep it in flight so the reconnect's
        -- rebase can tell (folding it into pending here would send an applied edit twice).
        return
      end
      -- Refused: not applied. Put it back in front of whatever was typed since.
      if self.inflight then
        self.pending = self.pending and ot.compose(self.inflight, self.pending) or self.inflight
        self.inflight = nil
      end
      if tostring(err.message):find('read-only', 1, true) then
        -- The engine stopped sending this doc (Overleaf keeps refusing an edit): a rebase would only be refused
        -- again, in a loop. Keep the edits and say so.
        self.state = 'idle'
        self:fail(tostring(err.message))
        return
      end
      -- The engine doesn't know our seq (it restarted, or reopened the doc) or refused the edit: start again from
      -- its text, keeping ours. If that fails too, the error stays on the statusline.
      self:fail('doc.edit failed: ' .. tostring(err.message))
      self:rebase()
      return
    end
    self:ack(res.seq)
  end)
end

function M:ack(seq)
  -- A result past seq + 1: a change below it never reached us (the engine's notes lagged) or will come late, when
  -- it would be dropped as already seen. Either way, resync from the engine's text once this is booked.
  local skipped = seq > self.seq + 1
  if seq ~= self.seq + 1 then
    vim.notify(('Taudot: %s: ack for seq %d, expected %d'):format(self.path, seq, self.seq + 1), vim.log.levels.WARN)
  end
  self.seq = seq
  if self.inflight then
    -- the text before it, until Overleaf has it (doc.state unconfirmed 0): an engine killed before sending it to
    -- Overleaf or backing it up loses it, and a rebase then finds the server without it
    self.unflushed = self.unflushed or {}
    self.unflushed[#self.unflushed + 1] = self.base
    self.base = ot.apply_string(self.base, ot.to_edits(self.inflight))
  end
  self.inflight = nil
  self.error = nil
  if skipped then
    -- (pending isn't sent at this seq: the buffer lacks the skipped change; the rebase sends it)
    self.state = 'idle'
    self.project:changed()
    return self:resync()
  end
  if self.pending then
    self:flush()
  else
    self.state = 'idle'
    if api.nvim_buf_is_valid(self.buf) then
      ui.clear_unconfirmed(self.buf)
      vim.bo[self.buf].modified = false
    end
  end
  self.project:changed()
end

-- engine.lagged: notifications were lost; every buffer starts again from the engine's text.
function M.resync_all()
  for _, b in pairs(M.by_buf) do
    b:resync()
  end
end

-- A rename or move of the doc, or of a folder above it (E16): the new path, else nil.
local function moved_path(path, change)
  if change.op ~= 'moved' or type(change.from) ~= 'string' or type(change.path) ~= 'string' then
    return nil
  end
  if path == change.from then
    return change.path
  end
  if change.type == 'folder' and path:sub(1, #change.from + 1) == change.from .. '/' then
    return change.path .. path:sub(#change.from + 1)
  end
end

-- project.tree from the engine: a doc deleted on Overleaf stops syncing (its text stays in the buffer; the engine
-- keeps a copy of unsent edits and says where).
function M:on_tree(change)
  local to = (change.id == self.doc_id or change.type == 'folder') and moved_path(self.path, change)
  if to then
    -- The engine renamed the file on disk too: the buffer follows, and rebases reopen the doc by its new path.
    self.path = to
    local folder = self.project.folder
    if folder and api.nvim_buf_is_valid(self.buf) then
      pcall(api.nvim_buf_set_name, self.buf, folder .. '/' .. to)
      pcall(function() vim.bo[self.buf].modified = false end)
    end
    self.project:changed()
    return
  end
  if change.op == 'removed' and change.id == self.doc_id then
    local unsent = self:unconfirmed() > 0
    self:detach()
    self.error = ('deleted on Overleaf%s; no longer synced'):format(unsent and ' with unsent edits' or '')
    vim.notify(('Taudot: %s was %s'):format(self.path, self.error), vim.log.levels.WARN)
    self.project:changed()
  end
end

-- doc.state from the engine.
function M:on_state(p)
  self.engine_state = p
  -- Overleaf has every edit the engine confirmed, as of the state's seq: one sent before our last acked edit (notes
  -- and results travel separately) says nothing about it. An engine without seq in doc.state never clears it.
  if p.unconfirmed == 0 and not self.inflight and type(p.seq) == 'number' and p.seq >= self.seq then
    self.unflushed = nil
  end
end

function M:unconfirmed()
  return ot.count(self.inflight) + ot.count(self.pending)
end

-- ---- remote edits -------------------------------------------------------------------------------------------------

function M:on_changed(p)
  if p.seq <= self.seq then
    return -- already have it (replay after reconnect)
  end
  if p.seq ~= self.seq + 1 then
    vim.notify(('Taudot: %s: got seq %d after %d. Resyncing.'):format(self.path, p.seq, self.seq), vim.log.levels.WARN)
    return self:resync()
  end
  if self.rebasing then
    return -- the rebase's doc.open has these; it subscribes from its seq
  end
  self:settle()
  local base = (self.inflight and self.inflight.base) or (self.pending and self.pending.base) or self.len
  local ok, remote = pcall(ot.from_edits, p.edits, base)
  if not ok then
    vim.notify('Taudot: bad remote edit: ' .. tostring(remote) .. '. Resyncing.', vim.log.levels.WARN)
    return self:resync()
  end
  -- Server ops go first on ties, matching the engine's transform of our stale edits.
  if self.inflight or self.pending then
    self.transformed = (self.transformed or 0) + 1
  end
  if self.inflight then
    remote, self.inflight = ot.transform(remote, self.inflight)
  end
  if self.pending then
    remote, self.pending = ot.transform(remote, self.pending)
  end
  self.seq = p.seq
  self.base = ot.apply_string(self.base, p.edits)
  self.unflushed = nil -- texts before a remote edit: no longer a base we can diff against
  local edits = ot.to_edits(remote)
  -- (a disk edit: an editor or an agent outside Neovim changed the file; its own colour)
  self:apply(edits, p.source == 'disk' and { user_id = 'disk', name = 'on disk' } or p.author)
  self.text = ot.apply_string(self.text, edits)
  self.len = remote.target
  local now = M.buffer_text(self.buf)
  if self.text == now then
    text_changed(self, edits)
    -- the Mac app marks it (the PDF, the changes list, follow); after the text, which its copy needs first
    local app = package.loaded['taudot.app']
    if app and app.outside and #edits > 0 then
      pcall(app.outside, self, edits, p.author, p.origin, p.source)
    end
  else
    text_changed(self, nil, now)
    vim.notify(('Taudot: %s: buffer drifted from the doc. Resyncing.'):format(self.path), vim.log.levels.WARN)
    self:resync()
  end
end

-- Apply edits to the buffer without them coming back through on_bytes.
function M:apply(edits, author)
  local buf = self.buf
  self.applying = true
  local ok, err = pcall(function()
    for _, e in ipairs(edits) do
      self:apply_one(e, author)
    end
  end)
  self.applying = false
  if not ok then
    vim.notify('Taudot: applying a remote edit failed: ' .. tostring(err), vim.log.levels.ERROR)
    self:resync()
  end
  if api.nvim_buf_is_valid(buf) and not self.pending and not self.inflight then
    vim.bo[buf].modified = false
  end
end

function M:apply_one(e, author)
  local buf = self.buf
  local total = doc_len(buf)
  local stop = e.pos + e.del
  if stop > total then
    error(('edit past the end (%d > %d)'):format(stop, total))
  end
  local has_eol = vim.bo[buf].eol or vim.bo[buf].fixeol
  if has_eol and (stop == total and (e.del > 0 or e.pos == total)) then
    -- The edit touches the final newline, which isn't a buffer position. Rewrite the tail lines.
    local n = api.nvim_buf_line_count(buf)
    local row = M.pos_to_rc(buf, math.min(e.pos, total - 1))
    local start = api.nvim_buf_get_offset(buf, row)
    local old = table.concat(api.nvim_buf_get_lines(buf, row, n, false), '\n') .. '\n'
    local new = old:sub(1, e.pos - start) .. e.ins .. old:sub(stop - start + 1)
    local lines = split_lines(new)
    if lines[#lines] == '' then
      table.remove(lines)
    else
      vim.bo[buf].eol = false
      vim.bo[buf].fixeol = false
    end
    if #lines == 0 then
      lines = { '' }
    end
    api.nvim_buf_set_lines(buf, row, n, false, lines)
    if #e.ins == 0 and e.del > 0 then
      local dr, dc = M.pos_to_rc(buf, math.min(e.pos, doc_len(buf)))
      if dr then
        ui.mark_deleted(buf, dr, dc, author)
      end
    end
    if #e.ins > 0 then
      local sr, sc = M.pos_to_rc(buf, e.pos)
      local er, ec = M.pos_to_rc(buf, e.pos + #e.ins)
      if sr and er then
        ui.mark_remote(buf, sr, sc, er, ec, author)
      end
    end
    return
  end
  local sr, sc = M.pos_to_rc(buf, e.pos)
  local er, ec = M.pos_to_rc(buf, stop)
  local lines = split_lines(e.ins)
  api.nvim_buf_set_text(buf, sr, sc, er, ec, lines)
  if #e.ins > 0 then
    local end_row = sr + #lines - 1
    local end_col = (#lines == 1 and sc or 0) + #lines[#lines]
    ui.mark_remote(buf, sr, sc, end_row, end_col, author)
  elseif e.del > 0 then
    ui.mark_deleted(buf, sr, sc, author)
  end
end

-- Something doesn't add up (a seq gap, a drifted buffer, a reload): start again from the engine's copy, keeping
-- what was typed.
function M:resync()
  self:rebase()
end

-- An error that leaves edits unsent: on the statusline (and the app's status bar) until the next ack.
function M:fail(msg)
  self.error = msg
  vim.notify(('Taudot: %s: %s'):format(self.path, msg), vim.log.levels.ERROR)
  self.project:changed()
end

local function changed_bytes(a, b)
  local n = 0
  for _, e in ipairs(ot.to_edits(ot.diff(a, b))) do
    n = n + e.del + #e.ins
  end
  return n
end

-- Re-open the doc and put our unconfirmed edits on top of the engine's text: after a reconnect (the engine may be a
-- new one, its seq starting over), or when the engine refuses our seq. Ours = diff(last confirmed text -> buffer);
-- theirs = diff(last confirmed text -> engine's text); theirs is applied to the buffer, ours (transformed past it)
-- is sent at the engine's seq. An edit that was in flight when the connection went may have been applied: when the
-- engine's text is closer to the confirmed text with it, it counts as confirmed (so it isn't sent twice).
function M:rebase(done)
  done = done or function() end
  local client = self.project.client
  if self.detached or self.rebasing or not client or client.closed then
    return done('not connected')
  end
  self.rebasing = true
  self:settle()
  client:request('doc.open', { project_id = self.project.project_id, path = self.path }, function(err, res)
    if self.detached then
      self.rebasing = false
      return done('detached')
    end
    if err and (err.code == -1 or client.closed) then
      self.rebasing = false
      return done('connection closed') -- the reconnect rebases again
    end
    if err or type(res) ~= 'table' or type(res.text) ~= 'string' then
      self.rebasing = false
      self:fail('reopening the doc failed: ' .. tostring(err and err.message or 'no text') .. '; your edits are kept, not synced')
      return done('doc.open failed')
    end
    self:settle()
    local mine = M.buffer_text(self.buf)
    -- Which of our edits does the engine have? The confirmed text, with the one in flight (it may have been applied),
    -- or without the confirmed ones Overleaf hadn't confirmed yet (a killed engine may have lost them): the closest
    -- to the engine's text, the most recent on a tie.
    local cands = {}
    for _, t in ipairs(self.unflushed or {}) do
      cands[#cands + 1] = t
    end
    local base = self.base or self.text
    cands[#cands + 1] = base
    if self.inflight then
      cands[#cands + 1] = ot.apply_string(base, ot.to_edits(self.inflight))
    end
    local best
    for i = #cands, 1, -1 do
      local d = cands[i] == res.text and 0 or changed_bytes(cands[i], res.text)
      if not best or d < best then
        best, base = d, cands[i]
      end
    end
    local ok, perr = pcall(function()
      local ours = ot.diff(base, mine)
      local theirs = ot.diff(base, res.text)
      local theirs2, ours2 = ot.transform(theirs, ours)
      local edits = ot.to_edits(theirs2)
      local want = ot.apply_string(mine, edits)
      self.doc_id, self.seq, self.base = res.doc_id or self.doc_id, res.seq, res.text
      self.inflight, self.unflushed = nil, nil
      self.pending = #ot.to_edits(ours2) > 0 and ours2 or nil
      if #edits > 0 then
        self.applying = true
        local aok, aerr = pcall(function()
          for _, e in ipairs(edits) do
            self:apply_one(e, nil)
          end
        end)
        self.applying = false
        if not aok then
          -- write the merged text whole
          local lines = split_lines(want)
          if lines[#lines] == '' and #lines > 1 then
            table.remove(lines)
          end
          self.applying = true
          api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)
          self.applying = false
          vim.notify('Taudot: ' .. self.path .. ': ' .. tostring(aerr) .. '; rewrote the buffer', vim.log.levels.DEBUG)
        end
      end
      self.spans = nil
      self.text = M.buffer_text(self.buf)
      self.len = #self.text
      text_changed(self, nil)
      if self.text ~= want then
        error(('the buffer is not the merged text (%d vs %d bytes)'):format(#self.text, #want))
      end
      if ot.apply_string(res.text, ot.to_edits(self.pending or ot.identity(#res.text))) ~= self.text then
        error('our edits do not fit the engine\'s text')
      end
    end)
    self.rebasing = false
    if not ok then
      self:fail('could not merge with the engine\'s text: ' .. tostring(perr) .. '; your edits are kept, not synced')
      return done(perr)
    end
    self.error = nil
    self.rebases = (self.rebases or 0) + 1
    if not self.pending then
      self.state = 'idle'
    end
    if not self.pending and api.nvim_buf_is_valid(self.buf) then
      ui.clear_unconfirmed(self.buf)
      vim.bo[self.buf].modified = false
    end
    self.project:changed()
    client:request('doc.subscribe', { doc_id = self.doc_id, since_seq = self.seq }, function()
      self:flush()
      done(nil)
    end)
  end)
end

-- ---- cursors, comments, tracked changes ---------------------------------------------------------------------------

-- A byte offset the engine measured at its `seq`, as an offset into this buffer. The buffer is the engine's text at
-- self.seq plus our unacknowledged edits (inflight, then pending), so the position is moved through those. A position
-- measured at self.seq + 1 while an edit is in flight already counts that edit (the engine recorded it before the
-- result reached us). Nil when the position is from a text we can't place.
function M:map_from(pos, seq)
  if type(pos) ~= 'number' then
    return nil
  end
  self:settle()
  local ops
  if seq == nil or seq == vim.NIL or seq == self.seq then
    ops = { self.inflight, self.pending }
  elseif seq == self.seq + 1 and self.inflight then
    ops = { self.pending }
  else
    return nil
  end
  for i = 1, 2 do
    if ops[i] then
      pos = ot.map_pos(ops[i], pos, 'right')
    end
  end
  return pos
end

function M:schedule_cursor()
  if self.cursor_timer then
    return
  end
  self.cursor_timer = vim.defer_fn(function()
    self.cursor_timer = nil
    local client = self.project.client
    if self.detached or not client or client.closed or api.nvim_get_current_buf() ~= self.buf then
      return
    end
    self:settle()
    -- The engine measures positions at seq; ours includes edits it hasn't acknowledged, so send the position
    -- before them only when there are none (otherwise it lands a little off until the next move).
    local cur = api.nvim_win_get_cursor(0)
    local pos = api.nvim_buf_get_offset(self.buf, cur[1] - 1) + cur[2]
    if not self.inflight and not self.pending then
      client:request('presence.cursor', { doc_id = self.doc_id, pos = pos, seq = self.seq })
    else
      client:request('presence.cursor', { doc_id = self.doc_id, pos = pos })
    end
  end, config.options.cursor_delay)
end

function M:pos_mapper()
  return function(pos)
    return M.pos_to_rc(self.buf, pos)
  end
end

-- users: presence.changed users (api.md). Positions are mapped from each user's seq into this buffer.
function M:draw_cursors(users)
  local mine = {}
  for _, u in ipairs(users) do
    if u.doc_id == self.doc_id and type(u.pos) == 'number' and u.user_id ~= self.project.me then
      local pos = self:map_from(u.pos, u.seq)
      if pos then
        mine[#mine + 1] = vim.tbl_extend('force', u, { pos = pos })
      end
    end
  end
  ui.draw_cursors(self.buf, mine, self:pos_mapper())
end

-- ranges: api.md ranges measured at `seq`. Drawn as extmarks, which then move with the text on their own.
function M:set_ranges(ranges, seq)
  local placed = {}
  for _, r in ipairs(ranges or {}) do
    local s = self:map_from(r.start, seq)
    local e = self:map_from(r['end'], seq)
    if s and e then
      placed[#placed + 1] = vim.tbl_extend('force', r, { start = s, ['end'] = math.max(s, e) })
    end
  end
  self.ranges = placed
  self.comments = ui.draw_ranges(self.buf, placed, self:pos_mapper())
  require('taudot.review').redraw()
end

-- Comments and tracked changes in text order, each { r = range, row, col, end_row, end_col } at where they are now.
-- Resolved comments (not drawn unless show_resolved) only with include_resolved, at their last known place.
function M:review_items(include_resolved)
  local out, seen = {}, {}
  for _, m in ipairs(api.nvim_buf_get_extmarks(self.buf, ui.ns.comment, 0, -1, { details = true })) do
    local r = self.comments[m[1]]
    if r and (include_resolved or not r.resolved) then
      seen[r] = true
      local d = m[4]
      out[#out + 1] = { r = r, row = m[2], col = m[3], end_row = d.end_row or m[2], end_col = d.end_col or m[3] }
    end
  end
  if include_resolved then
    for _, r in ipairs(self.ranges) do
      if r.kind == 'comment' and r.resolved and not seen[r] then
        local row, col = M.pos_to_rc(self.buf, r.start)
        local er, ec = M.pos_to_rc(self.buf, r['end'])
        if row then
          out[#out + 1] = { r = r, row = row, col = col, end_row = er or row, end_col = ec or col }
        end
      end
    end
  end
  table.sort(out, function(a, b)
    if a.row ~= b.row then
      return a.row < b.row
    elseif a.col ~= b.col then
      return a.col < b.col
    end
    return (a.r.kind == 'comment' and 0 or 1) < (b.r.kind == 'comment' and 0 or 1)
  end)
  return out
end

-- Ranges under the cursor, or overlapping the lines first..last (1-based) when given.
function M:ranges_here(first, last)
  if first then
    local out = {}
    for _, m in ipairs(api.nvim_buf_get_extmarks(self.buf, ui.ns.comment, { first - 1, 0 }, { last - 1, -1 }, { details = true, overlap = true })) do
      local r = self.comments[m[1]]
      if r then
        out[#out + 1] = r
      end
    end
    return out
  end
  local cur = api.nvim_win_get_cursor(0)
  return ui.ranges_at(self.buf, self.comments, cur[1] - 1, cur[2])
end

-- K: the threads and tracked changes under the cursor in a float. False when there are none.
function M:show_thread()
  local found = self:ranges_here()
  if #found == 0 then
    return false
  end
  ui.show_review(found, self.project.threads)
  return true
end

return M
