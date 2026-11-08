// Neovim's UI protocol (ext_linegrid + ext_multigrid) applied to a plain model. No drawing here.
import Foundation
import TaudotShared

public struct Cell: Equatable, Sendable {
  /// The cell's text: one grapheme, or "" for the right half of a double-width character.
  public var text: String
  public var hl: Int32
  public init(_ text: String = " ", hl: Int32 = 0) { self.text = text; self.hl = hl }
}

nonisolated(unsafe) private var rowVersionCounter: UInt64 = 0
@inline(__always) func nextRowVersion() -> UInt64 { rowVersionCounter &+= 1; return rowVersionCounter }

/// One grid row. `version` changes whenever the cells do, so renderers can cache by it.
public struct Row: Sendable {
  public var cells: [Cell] { didSet { version = nextRowVersion() } }
  public private(set) var version: UInt64
  public init(width: Int) { cells = Array(repeating: Cell(), count: width); version = nextRowVersion() }
  public var text: String { cells.map(\.text).joined() }
}

public struct HlAttr: Equatable, Sendable {
  public var fg: UInt32?, bg: UInt32?, sp: UInt32?
  public var bold = false, italic = false, reverse = false, strikethrough = false
  public var underline = false, undercurl = false, underdouble = false, underdotted = false, underdashed = false
  public var blend = 0
  public init() {}

  init(_ v: Value) {
    for (k, x) in v.mapPairs ?? [] {
      switch k.string ?? "" {
      case "foreground": fg = x.int.map { UInt32(truncatingIfNeeded: $0) }
      case "background": bg = x.int.map { UInt32(truncatingIfNeeded: $0) }
      case "special": sp = x.int.map { UInt32(truncatingIfNeeded: $0) }
      case "bold": bold = x.bool ?? false
      case "italic": italic = x.bool ?? false
      case "reverse": reverse = x.bool ?? false
      case "strikethrough": strikethrough = x.bool ?? false
      case "underline": underline = x.bool ?? false
      case "undercurl": undercurl = x.bool ?? false
      case "underdouble": underdouble = x.bool ?? false
      case "underdotted": underdotted = x.bool ?? false
      case "underdashed": underdashed = x.bool ?? false
      case "blend": blend = x.int ?? 0
      default: break
      }
    }
  }
}

public struct CursorShape: Sendable, Equatable {
  public enum Kind: String, Sendable { case block, horizontal, vertical }
  public var kind: Kind = .block
  public var cellPercentage = 100
  public var attrId = 0
  public var name = ""
  public var blinkon = 0
}

public final class Grid {
  public let id: Int
  public private(set) var width: Int
  public private(set) var height: Int
  public var rows: [Row]

  init(id: Int, width: Int, height: Int) {
    self.id = id; self.width = width; self.height = height
    rows = (0..<height).map { _ in Row(width: width) }
  }

  func resize(width w: Int, height h: Int) {
    if w != width { for i in rows.indices {
      var c = rows[i].cells
      if w < c.count { c.removeLast(c.count - w) } else { c += Array(repeating: Cell(), count: w - c.count) }
      rows[i].cells = c
    } }
    if h < rows.count { rows.removeLast(rows.count - h) }
    while rows.count < h { rows.append(Row(width: w)) }
    width = w; height = h
  }

  func clear() { for i in rows.indices { rows[i] = Row(width: width) } }

  /// `grid_scroll`: move the region's rows by `rows` (positive: content moves up).
  func scroll(top: Int, bot: Int, left: Int, right: Int, rows n: Int) {
    if left == 0 && right == width {
      if n > 0 {
        for r in top..<(bot - n) { rows[r] = rows[r + n] }
      } else if n < 0 {
        for r in stride(from: bot - 1, through: top - n, by: -1) { rows[r] = rows[r + n] }
      }
    } else {
      if n > 0 {
        for r in top..<(bot - n) { rows[r].cells.replaceSubrange(left..<right, with: rows[r + n].cells[left..<right]) }
      } else if n < 0 {
        for r in stride(from: bot - 1, through: top - n, by: -1) { rows[r].cells.replaceSubrange(left..<right, with: rows[r + n].cells[left..<right]) }
      }
    }
  }
}

public struct WindowInfo: Sendable {
  public enum Kind: Sendable, Equatable { case normal, floating, message, external }
  public var grid: Int
  public var win: Int = 0
  public var kind: Kind = .normal
  /// Position on grid 1, in cells (floats: as Neovim computed it, `screen_row`/`screen_col`).
  public var row: Double = 0, col: Double = 0
  public var width = 0, height = 0
  public var hidden = false
  /// Placed by `win_pos` (a split), not a float or message grid.
  public var placed = false
  public var zindex = 0, compindex = 0
  // win_viewport
  public var topline = 0, botline = 0, curline = 0, curcol = 0, lineCount = 0
  // win_viewport_margins (winbar, borders)
  public var marginTop = 0, marginBottom = 0, marginLeft = 0, marginRight = 0
}

/// The whole UI as Neovim describes it. Apply redraw batches; on `flush`, `onFlush` runs.
@MainActor public final class UIModel {
  public private(set) var grids: [Int: Grid] = [:]
  public private(set) var windows: [Int: WindowInfo] = [:]
  public private(set) var hl: [Int: HlAttr] = [0: HlAttr()]
  public private(set) var hlGroups: [String: Int] = [:]
  public private(set) var defaultFg: UInt32 = 0xd0d0d0
  public private(set) var defaultBg: UInt32 = 0x1c1c1c
  public private(set) var defaultSp: UInt32 = 0xff0000
  public private(set) var cursorGrid = 1, cursorRow = 0, cursorCol = 0
  public private(set) var modes: [CursorShape] = []
  public private(set) var modeIndex = 0
  public private(set) var modeName = "normal"
  public private(set) var options: [String: Value] = [:]
  public private(set) var busy = false
  /// Bumped when highlight definitions or default colours change.
  public private(set) var hlGeneration = 0
  /// Full-window `grid_scroll` rows per grid since the last flush (screen rows, exact).
  public private(set) var gridScrolls: [Int: Int] = [:]
  /// The rows (top, bottom) of the last full-width `grid_scroll` per grid since the last flush.
  public private(set) var gridScrollSpan: [Int: (Int, Int)] = [:]
  public private(set) var title = ""

  /// Scroll deltas seen since the last flush, per grid (from `win_viewport`).
  public private(set) var pendingScroll: [Int: Int] = [:]
  /// Grids whose content or position changed since the last flush.
  public private(set) var dirty = Set<Int>()
  /// Grids destroyed or closed since the last flush.
  public private(set) var closed = Set<Int>()
  public private(set) var optionsChanged = false

  /// Called at the end of each `flush`; the pending sets are cleared right after.
  public var onFlush: ((UIModel) -> Void)?
  public var onEvent: ((String, [Value]) -> Void)?

  public init() {}

  public var cursorShape: CursorShape { modeIndex < modes.count ? modes[modeIndex] : CursorShape() }

  public func attr(_ id: Int32) -> HlAttr { hl[Int(id)] ?? hl[0]! }

  /// Resolved colours (reverse applied).
  public func colors(_ id: Int32) -> (fg: UInt32, bg: UInt32, sp: UInt32) {
    let a = attr(id)
    var fg = a.fg ?? defaultFg, bg = a.bg ?? defaultBg
    if a.reverse { swap(&fg, &bg) }
    return (fg, bg, a.sp ?? fg)
  }

  public func apply(_ batches: [Value]) {
    for b in batches {
      guard let a = b.array, let name = a.first?.string else { continue }
      for args in a.dropFirst() { event(name, args.array ?? []) }
    }
  }

  func event(_ name: String, _ e: [Value]) {
    @inline(__always) func i(_ k: Int) -> Int { k < e.count ? (e[k].int ?? 0) : 0 }
    switch name {
    case "grid_line": gridLine(e)
    case "grid_resize":
      let id = i(0)
      if let g = grids[id] { g.resize(width: i(1), height: i(2)) } else { grids[id] = Grid(id: id, width: i(1), height: i(2)) }
      if id == 1 { windows[1, default: WindowInfo(grid: 1)].width = i(1); windows[1]!.height = i(2) }
      dirty.insert(id)
    case "grid_clear": grids[i(0)]?.clear(); dirty.insert(i(0))
    case "grid_destroy": grids[i(0)] = nil; windows[i(0)] = nil; closed.insert(i(0))
    case "grid_cursor_goto": cursorGrid = i(0); cursorRow = i(1); cursorCol = i(2)
    case "grid_scroll":
      grids[i(0)]?.scroll(top: i(1), bot: i(2), left: i(3), right: i(4), rows: i(5))
      if i(3) == 0, let g = grids[i(0)], i(4) == g.width { gridScrolls[i(0), default: 0] += i(5); gridScrollSpan[i(0)] = (i(1), i(2)) }
      dirty.insert(i(0))
    case "hl_attr_define": hl[i(0)] = HlAttr(e.count > 1 ? e[1] : .null); hlGeneration += 1
    case "hl_group_set": if let n = e.first?.string { hlGroups[n] = i(1) }
    case "default_colors_set":
      defaultFg = UInt32(truncatingIfNeeded: i(0) < 0 ? 0xd0d0d0 : i(0))
      defaultBg = UInt32(truncatingIfNeeded: i(1) < 0 ? 0x1c1c1c : i(1))
      defaultSp = UInt32(truncatingIfNeeded: i(2) < 0 ? 0xff0000 : i(2))
      for g in grids.keys { dirty.insert(g) }
      hlGeneration += 1
    case "win_pos":
      var w = windows[i(0)] ?? WindowInfo(grid: i(0))
      w.win = i(1); w.kind = .normal; w.row = Double(i(2)); w.placed = true; w.col = Double(i(3)); w.width = i(4); w.height = i(5)
      w.hidden = false; w.zindex = 0
      windows[i(0)] = w; dirty.insert(i(0))
    case "win_float_pos":
      var w = windows[i(0)] ?? WindowInfo(grid: i(0))
      w.win = i(1); w.kind = .floating; w.hidden = false; w.placed = false
      w.zindex = i(7); w.compindex = i(8)
      if e.count > 10 {
        w.row = e[9].double ?? 0; w.col = e[10].double ?? 0
      } else {
        // Older Neovim: anchor relative to anchor_grid.
        let ag = windows[i(3)]
        let g = grids[i(0)]
        var r = (ag?.row ?? 0) + (e[4].double ?? 0), c = (ag?.col ?? 0) + (e[5].double ?? 0)
        let anchor = e[2].string ?? "NW"
        if anchor.hasPrefix("S") { r -= Double(g?.height ?? 0) }
        if anchor.hasSuffix("E") { c -= Double(g?.width ?? 0) }
        w.row = r; w.col = c
      }
      if let g = grids[i(0)] { w.width = g.width; w.height = g.height }
      windows[i(0)] = w; dirty.insert(i(0))
    case "win_external_pos": windows[i(0), default: WindowInfo(grid: i(0))].kind = .external
    case "win_hide": windows[i(0)]?.hidden = true; dirty.insert(i(0))
    case "win_close": windows[i(0)] = nil; closed.insert(i(0))
    case "msg_set_pos":
      var w = windows[i(0)] ?? WindowInfo(grid: i(0))
      w.kind = .message; w.row = Double(i(1)); w.col = 0; w.hidden = false; w.placed = false
      w.zindex = e.count > 4 ? i(4) : 200; w.compindex = e.count > 5 ? i(5) : 0
      if let g = grids[i(0)] { w.width = g.width; w.height = g.height }
      windows[i(0)] = w; dirty.insert(i(0))
    case "win_viewport":
      var w = windows[i(0)] ?? WindowInfo(grid: i(0))
      w.win = i(1); w.topline = i(2); w.botline = i(3); w.curline = i(4); w.curcol = i(5); w.lineCount = i(6)
      windows[i(0)] = w
      let d = e.count > 7 ? i(7) : 0
      if d != 0 { pendingScroll[i(0), default: 0] += d }
    case "win_viewport_margins":
      var w = windows[i(0)] ?? WindowInfo(grid: i(0))
      w.marginTop = i(2); w.marginBottom = i(3); w.marginLeft = i(4); w.marginRight = i(5)
      windows[i(0)] = w
    case "mode_info_set":
      modes = (e.count > 1 ? e[1].array ?? [] : []).map { m in
        var s = CursorShape()
        if let k = m["cursor_shape"]?.string, let kind = CursorShape.Kind(rawValue: k) { s.kind = kind }
        s.cellPercentage = m["cell_percentage"]?.int ?? 100
        s.attrId = m["attr_id"]?.int ?? 0
        s.name = m["name"]?.string ?? ""
        s.blinkon = m["blinkon"]?.int ?? 0
        return s
      }
    case "mode_change": modeName = e.first?.string ?? ""; modeIndex = i(1)
    case "option_set": if let k = e.first?.string, e.count > 1 { options[k] = e[1]; optionsChanged = true }
    case "busy_start": busy = true
    case "busy_stop": busy = false
    case "set_title": title = e.first?.string ?? ""
    case "flush":
      // Keep float sizes in step with their grids.
      for (id, w) in windows where w.kind != .normal { if let g = grids[id] { windows[id]!.width = g.width; windows[id]!.height = g.height } }
      onFlush?(self)
      pendingScroll.removeAll(keepingCapacity: true)
      gridScrolls.removeAll(keepingCapacity: true)
      gridScrollSpan.removeAll(keepingCapacity: true)
      dirty.removeAll(keepingCapacity: true)
      closed.removeAll(keepingCapacity: true)
      optionsChanged = false
    default: break
    }
    onEvent?(name, e)
  }

  func gridLine(_ e: [Value]) {
    guard e.count >= 4, let gid = e[0].int, let g = grids[gid], let row = e[1].int, row < g.height,
          var col = e[2].int, let data = e[3].array else { return }
    var cells = g.rows[row].cells
    var hlid: Int32 = 0
    for c in data {
      guard let ca = c.array, let text = ca.first?.string else { continue }
      if ca.count > 1, let h = ca[1].int { hlid = Int32(h) }
      let rep = ca.count > 2 ? (ca[2].int ?? 1) : 1
      for _ in 0..<rep where col < cells.count {
        cells[col] = Cell(text, hl: hlid)
        col += 1
      }
    }
    g.rows[row].cells = cells
    dirty.insert(gid)
  }

  // MARK: options

  public var guifont: String? { options["guifont"]?.string.flatMap { $0.isEmpty ? nil : $0 } }
  public var linespace: Int { options["linespace"]?.int ?? 0 }

  /// Windows to draw, bottom first: grid 1, normal windows, then message and floats by zindex.
  public var drawOrder: [WindowInfo] {
    let ws = windows.values.filter { !$0.hidden && $0.kind != .external && grids[$0.grid] != nil }
    return ws.sorted { a, b in
      func layer(_ w: WindowInfo) -> Int { w.grid == 1 ? 0 : w.kind == .normal ? 1 : 2 }
      if layer(a) != layer(b) { return layer(a) < layer(b) }
      if a.zindex != b.zindex { return a.zindex < b.zindex }
      if a.compindex != b.compindex { return a.compindex < b.compindex }
      return a.grid < b.grid
    }
  }
}
