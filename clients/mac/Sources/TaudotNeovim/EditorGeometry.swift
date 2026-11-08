// EditorGeometry: where buffer lines are on screen, for the margin. It describes exactly the frame `render()` drew.
//
// Lines are kept in the scroll ring's absolute rows (`SmoothScroll.base + k`), which move with the rows themselves,
// so a scroll never has to shift the map. Neovim pushes a map from WinScrolled / TextChanged (`taudot_geom`). Those
// autocommands run before the redraw they caused is flushed, so a pushed map is applied at the next flush, together
// with the rows it describes. `y(ofLine:)` then uses the offset and window position the last frame was drawn with,
// and `onChange` fires right after each frame.
import AppKit
import TaudotShared

/// A window's line map as Neovim computed it: rows from the window's first text row (negative above it), for the
/// lines within two screens of the view.
struct LineMap {
  var win: Int
  var buf: Int
  var top: Int
  var rows: [(line: Int, row: Int)]

  init?(_ a: [Value]) {
    guard a.count >= 4, let w = a[0].int, let b = a[1].int, let t = a[2].int else { return nil }
    win = w; buf = b; top = t
    rows = []
    var i = 4
    while i + 1 < a.count { rows.append((a[i].int ?? 0, a[i + 1].int ?? 0)); i += 2 }
  }
}

/// The current grid as the last frame drew it.
struct DrawnGeometry {
  var grid: Int
  var base: Int
  var offset: Double
  var y: Float, top: Int, height: Int, ch: Float
  /// The window's left edge and the cell width (pixels), for x(ofColumn:).
  var x: Float = 0, cw: Float = 0
}

extension EditorView {
  public var lineHeight: CGFloat { font.cellHeight / scale }

  /// The first screen row of a line, in ring rows (k) of the drawn frame, or nil.
  func drawnRow(ofLine line: Int) -> Int? {
    guard let d = drawnGeometry, let map = lineAbs[d.grid], !map.isEmpty else { return nil }
    if let a = map[line] { return a - d.base }
    // Beyond the mapped lines (two screens each way): estimate without wraps, within a screen.
    var minL = Int.max, maxL = Int.min
    for l in map.keys { minL = min(minL, l); maxL = max(maxL, l) }
    if line > maxL && line - maxL <= d.height { return map[maxL]! + (line - maxL) - d.base }
    if line < minL && minL - line <= d.height { return map[minL]! - (minL - line) - d.base }
    return nil
  }

  public func y(ofLine line: Int) -> CGFloat? {
    guard let d = drawnGeometry, let k = drawnRow(ofLine: line) else { return nil }
    // The same expression render() places row k with.
    let px = (d.y + (Float(d.top) + Float(Double(k) - d.offset)) * d.ch).rounded()
    return CGFloat(px) / scale
  }

  public var visibleLines: ClosedRange<Int> {
    if let d = drawnGeometry, let map = lineAbs[d.grid], !map.isEmpty {
      // Lines whose rows are at least partly inside the drawn window.
      var first = Int.max, last = Int.min
      for (l, a) in map {
        let y = Double(a - d.base) - d.offset
        let next = map[l + 1].map { Double($0 - d.base) - d.offset } ?? (y + 1)
        if next > 0 && y < Double(d.height) { first = min(first, l); last = max(last, l) }
      }
      if first <= last { return first...last }
    }
    guard let w = ui.windows[currentGrid] else { return 0...0 }
    let top = w.topline, bot = max(w.topline, min(w.botline, max(w.lineCount, 1)) - 1)
    return top...bot
  }

  public func onChange(_ handler: @escaping @MainActor () -> Void) { geometryHandlers.append(handler) }

  func geometryChanged() { for h in geometryHandlers { h() } }

  /// render(): remember how the current grid was drawn.
  func recordDrawn(grid: Int, scroll: SmoothScroll?, y: Float, top: Int, height: Int, x: Float = 0) {
    drawnGeometry = DrawnGeometry(grid: grid, base: scroll?.base ?? 0, offset: scroll?.drawnOffset ?? 0, y: y, top: top,
                                  height: height, ch: ch, x: x, cw: cw)
  }

  /// The left edge of a screen column of the current window (0 = its first cell, the number column included), in
  /// the view's coordinates, as the last frame drew it.
  public func x(ofColumn c: Int) -> CGFloat? {
    guard let d = drawnGeometry else { return nil }
    return CGFloat((d.x + Float(c) * d.cw).rounded()) / scale
  }

  /// Install the autocommands that push line maps (after attach).
  func installGeometry() async {
    nvim.notify("taudot_geom") { [weak self] a in
      guard let self, let m = LineMap(a) else { return }
      self.pendingMaps[m.win] = m
    }
    guard let chan = try? await nvim.channelID() else { return }
    _ = try? await nvim.execLua(geometryLua, [.int(Int64(chan))])
  }

  /// On flush: maps pushed since the last flush describe the rows this flush brought.
  func applyPendingMaps() {
    guard !pendingMaps.isEmpty else { return }
    for (win, m) in pendingMaps {
      guard let (grid, w) = ui.windows.first(where: { $0.value.win == win }).map({ ($0.key, $0.value) }), let g = ui.grids[grid] else { continue }
      let top = min(w.marginTop, g.height), bot = max(top, g.height - w.marginBottom)
      let base = scrolls[grid].map { $0.height == bot - top ? $0.base : 0 } ?? 0
      var abs: [Int: Int] = [:]
      for (l, r) in m.rows { abs[l] = base + r }
      lineAbs[grid] = abs
      buffers[grid] = m.buf
    }
    pendingMaps.removeAll()
    needsFrame = true
  }

  /// Fallback for changes no autocommand reports (folds) and the first map: ask for it. Its answer is only used if the
  /// view can't have moved in between (no scroll reached the current grid, no push waiting, same topline).
  func requestLineMap() {
    guard let w = ui.windows[currentGrid], w.win != 0, let g = ui.grids[currentGrid] else { return }
    let key = [w.win, w.topline, w.botline, w.lineCount, g.width, g.height]
    guard key != lineMapKey || lineAbs[currentGrid] == nil, !lineMapPending else { return }
    lineMapKey = key
    lineMapPending = true
    lineMapScrolls = 0
    let grid = currentGrid
    Task { @MainActor in
      let v = try? await nvim.execLua("return require('taudot.geom').fallback(...)", [.int(Int64(w.win))])
      lineMapPending = false
      // nil: Neovim has a scroll not pushed yet (its push will come); ask again on a later flush.
      guard let a = v?.array, let m = LineMap(a) else { lineMapKey = []; return }
      guard grid == currentGrid, lineMapScrolls == 0, fingerReplies == 0, pendingMaps.isEmpty,
            ui.windows[grid]?.topline == m.top else {
        lineMapKey = []
        if lineAbs[grid] == nil { requestLineMap() }
        return
      }
      pendingMaps[m.win] = m
      applyPendingMaps()
      wake()
    }
  }
}

/// `taudot.geom`: map(win) returns {win, buf, top, skip, line, row, ...} (0-based lines; rows from the window's
/// first text row, so the topline's first row is -skip with smoothscroll; folds as one row; virtual lines above a line
/// before it). Lines within two window heights above and below. Autocommands push it as `taudot_geom`.
let geometryLua = """
local api = vim.api
local chan = ...
local M = {}
function M.map(win)
  if not api.nvim_win_is_valid(win) then return nil end
  local buf = api.nvim_win_get_buf(win)
  local H = api.nvim_win_get_height(win)
  local out = { win, buf, 0, 0 }
  api.nvim_win_call(win, function()
    local view = vim.fn.winsaveview()
    local top = view.topline
    local skip = 0
    if (view.skipcol or 0) > 0 and vim.wo.wrap then
      skip = api.nvim_win_text_height(win, { start_row = top - 1, end_row = top - 1, end_vcol = view.skipcol }).all
      skip = skip - api.nvim_win_text_height(win, { start_row = top - 1, end_row = top - 1, end_vcol = 0 }).all
    end
    out[3] = top - 1; out[4] = skip
    local n = api.nvim_buf_line_count(buf)
    local function h(l) return api.nvim_win_text_height(win, { start_row = l - 1, end_row = l - 1 }).all end
    local function above(l) return api.nvim_win_text_height(win, { start_row = l - 1, end_row = l - 1, end_vcol = 0 }).all end
    local row, l = -skip, top
    while l <= n and row < 2 * H do
      local fe = vim.fn.foldclosedend(l)
      if fe ~= -1 then
        for k = l, fe do out[#out + 1] = k - 1; out[#out + 1] = row end
        row = row + 1; l = fe + 1
      else
        out[#out + 1] = l - 1; out[#out + 1] = row + (l == top and 0 or above(l))
        row = row + h(l); l = l + 1
      end
    end
    row, l = -skip, top - 1
    while l >= 1 and row > -2 * H do
      local fs = vim.fn.foldclosed(l)
      if fs ~= -1 then
        row = row - 1
        for k = fs, l do out[#out + 1] = k - 1; out[#out + 1] = row end
        l = fs - 1
      else
        row = row - h(l)
        out[#out + 1] = l - 1; out[#out + 1] = row + above(l)
        l = l - 1
      end
    end
  end)
  return out
end
-- The view (topline, skipcol) each window's last map described.
M.seen = {}
local function view(win)
  local v = api.nvim_win_call(win, vim.fn.winsaveview)
  return v.topline .. ':' .. (v.skipcol or 0)
end
-- The client's fallback request. nil while the window has scrolled since the last map without its WinScrolled having
-- run yet (a scroll made by an API call just before): the push and the flush with those rows are still to come, and
-- a map of the new view applied now would sit on the old rows.
function M.fallback(win)
  if not api.nvim_win_is_valid(win) then return nil end
  local now = view(win)
  if M.seen[win] and M.seen[win] ~= now then return nil end
  local m = M.map(win)
  if m then M.seen[win] = now end
  return m
end
function M.push(win)
  local m = M.map(win)
  if m then M.seen[win] = view(win) end
  if m then vim.rpcnotify(chan, 'taudot_geom', unpack(m)) end
end
local g = api.nvim_create_augroup('taudot_geom', { clear = true })
api.nvim_create_autocmd('WinScrolled', { group = g, callback = function()
  for k in pairs(vim.v.event) do
    local w = tonumber(k)
    if w then pcall(M.push, w) end
  end
end })
api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI', 'TextChangedP', 'BufWinEnter', 'WinEnter', 'VimResized' },
  { group = g, callback = function() pcall(M.push, api.nvim_get_current_win()) end })
package.loaded['taudot.geom'] = M
"""
