// The editor: Neovim's grids drawn with Metal, smooth scrolling, the cursor, and EditorGeometry for the margin.
import AppKit
import Metal
import QuartzCore
import TaudotShared

struct RowEntry {
  var bg: [RectInstance] = []
  var glyphs: [GlyphInstance] = []
  var deco: [RectInstance] = []
  var used = 0
}

@MainActor public final class EditorView: NSView, EditorGeometry {
  public let nvim: Neovim
  public let ui = UIModel()
  let renderer: Renderer
  var font: FontSet
  /// The editor font's size in points (from `guifont`).
  public var fontPointSize: CGFloat { font.size }
  var atlas: GlyphAtlas
  let metalLayer = CAMetalLayer()
  /// How frames reach the screen: `.surface` (default) renders into an IOSurface and sets it as the layer's contents
  /// in the run-loop turn's Core Animation transaction, the same one that moves the margin's cards, so text and cards
  /// change in the same screen frame. `.metal` presents a CAMetalLayer drawable on its own (TAUDOT_PRESENT=metal),
  /// `.metalSync` with the transaction (TAUDOT_PRESENT=sync); both can show the text a frame after the cards.
  public enum PresentMode: String { case surface, metal, metalSync = "sync" }
  public let presentMode: PresentMode
  public var presentsWithTransaction: Bool { presentMode != .metal }
  let surfaceLayer = CALayer()
  var surfaces: [FrameSurface] = []
  var surfaceSize = (0, 0)
  var shownSurface = -1
  var frameTarget: CFTimeInterval = 0
  public internal(set) var scrolls: [Int: SmoothScroll] = [:]
  var rowCache: [UInt64: RowEntry] = [:]
  var rowCacheKey = (font: 0, atlas: -1, hl: -1)
  var fontGeneration = 0
  var frameCounter = 0
  var link: CADisplayLink?
  var needsFrame = true
  var lastTick: CFTimeInterval = 0
  var lastRender: CFTimeInterval = 0
  public private(set) var attached = false
  public private(set) var cols = 0, rows = 0
  var scale: CGFloat = 2

  // Cursor animation: offsets (pixels) from the target, springing to 0.
  var cursorDX = Spring(), cursorDY = Spring()
  var cursorTarget: SIMD2<Float>? = nil
  var cursorLength = 0.04
  public var focused = true { didSet { needsFrame = true; wake() } }

  /// Seconds for a scroll animation to (nearly) settle.
  public var scrollAnimationLength = 0.15
  /// Option as Meta (Alt), for the left Option key (or both when the event doesn't say which).
  public var optionAsMeta = true
  /// The right Option key as Meta. Off: it types the character macOS gives (accents, dead keys).
  public var rightOptionAsMeta = false

  /// Measurements (see FrameStats).
  public let stats = FrameStats()
  /// Called after every flush has been applied (the app uses it for the title).
  public var onFlush: (() -> Void)?

  // EditorGeometry state
  public internal(set) var currentGrid = 0
  public var buffer: Int { buffers[currentGrid] ?? 0 }
  var buffers: [Int: Int] = [:]
  /// Per grid: buffer line → the scroll ring's absolute row (`SmoothScroll.base + k`) of the line's first screen row.
  /// Absolute rows move with the ring, so the map stays right through scrolls without being shifted.
  var lineAbs: [Int: [Int: Int]] = [:]
  /// Maps Neovim pushed (window → map), applied at the next flush: the push comes before the redraw it describes.
  var pendingMaps: [Int: LineMap] = [:]
  /// What the last `render()` drew for the current grid; `y(ofLine:)` answers for exactly that frame.
  var drawnGeometry: DrawnGeometry?
  var geometryHandlers: [@MainActor () -> Void] = []
  var lineMapPending = false
  var lineMapKey: [Int] = []
  /// Flushes that scrolled the current grid since the fallback map request was sent (its answer is then stale).
  var lineMapScrolls = 0
  /// For tests: the scrolled rows of the current grid as the last frame drew them (y in points, text).
  public var debugDrawn: [(y: CGFloat, text: String)] = []

  // Input state (EditorView+Input.swift)
  var markedText: NSAttributedString?
  var keyDownHandled = false
  var scrollAccum: [Int: Double] = [:]
  var fingerGrid = 0
  var fingerActiveUntil: CFTimeInterval = 0
  /// Rows asked of Neovim for the finger and not yet seen in `scroll_delta` (signed).
  /// Rows asked of Neovim (or moved by it) for the finger whose `scroll_delta` hasn't come yet (signed). Reset at
  /// every flush once no reply is outstanding, so a row Neovim didn't deliver can't stay counted (it did: the count
  /// stuck at 35, Neovim was no longer asked, and the finger ran 35 rows ahead).
  var fingerRequested = 0
  var fingerReplies = 0
  /// Bumped by each new gesture and each settle (A16): a scroll reply counts only for the gesture that asked.
  var fingerGesture = 0
  /// A trackpad gesture (fingers or momentum) is under way on `fingerGrid`.
  var fingerActive = false
  /// The gesture reached the end (+1) or the top (-1): further pushes that way do nothing until it turns.
  var fingerEdge = 0
  /// The window and line count the edge was found for; a scroll the other way or a changed line count forgets it.
  var edgeGrid = 0, edgeLines = 0
  /// The end-of-gesture request that brings Neovim back to the view has been sent.
  var fingerPullBack = false
  var mouseDownGrid = 0
  var lastMouseCell = (row: -1, col: -1)
  public var debugReasons: [String: Int] = [:]
  /// Trackpad scrolls that hit an end and sprang back (debugging, benches).
  public var debugSnapBacks = 0
  /// The cursor as last drawn, for the scroll trace: its distance (pt) from where its row is drawn (y) and from its
  /// cell (x), and its row in absolute terms (base + row) so a hop to another row shows.
  public var debugCursor: (offY: Double, offX: Double, abs: Int)?
  /// EditorGeometry: the cursor cell in the main text window as the last frame drew it (points, view coordinates),
  /// or nil when that window's cursor isn't drawn. While a float (cmdline, picker) has the cursor it keeps the main
  /// window's last cursor, moved with the text.
  public internal(set) var cursorRect: CGRect?
  var cursorAbs: (grid: Int, abs: Int, x: CGFloat, w: CGFloat)?
  /// Set to record, each frame, where the current window's scrolled rows were drawn (row version → y in pixels).
  public var traceRows = false
  /// With `traceRows`: rows of scrolled areas drawn blank (no row known for them), summed over frames.
  public var debugBlankRows = 0
  public var onFrameRendered: (() -> Void)?
  /// A key before Neovim sees it: return true to keep it from Neovim (the Claude pane's Esc-Esc).
  public var onKeyDown: ((NSEvent) -> Bool)?

  public init(nvim: Neovim, frame: NSRect = NSRect(x: 0, y: 0, width: 800, height: 600)) {
    self.nvim = nvim
    guard let r = Renderer() else { fatalError("Taudot: no Metal device") }
    renderer = r
    font = FontSet(guifont: nil, scale: 2)
    atlas = GlyphAtlas(device: r.device, font: font)
    let env = ProcessInfo.processInfo.environment
    presentMode = env["TAUDOT_PRESENT"].flatMap(PresentMode.init(rawValue:)) ?? (env["TAUDOT_PRESENT_SYNC"] != nil ? .metalSync : .surface)
    super.init(frame: frame)
    wantsLayer = true
    metalLayer.device = r.device
    metalLayer.pixelFormat = .bgra8Unorm
    metalLayer.framebufferOnly = true
    metalLayer.isOpaque = true
    metalLayer.displaySyncEnabled = true
    metalLayer.maximumDrawableCount = 3
    metalLayer.presentsWithTransaction = presentMode == .metalSync
    // Surface mode: a plain layer whose contents are the last finished frame; no implicit animation of contents.
    surfaceLayer.isOpaque = true
    surfaceLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
    surfaceLayer.contentsGravity = .topLeft
    layer = presentMode == .surface ? surfaceLayer : metalLayer
    layerContentsRedrawPolicy = .never
    nvim.onRedraw = { [weak self] batches in self?.redraw(batches) }
    ui.onFlush = { [weak self] m in self?.flushed(m) }
  }

  required init?(coder: NSCoder) { fatalError() }

  public override var isFlipped: Bool { true }
  public override var acceptsFirstResponder: Bool { true }
  public override var isOpaque: Bool { true }

  // MARK: attach and size

  /// Attach as Neovim's UI. Call once the view is in a window (for the scale).
  public func attach(extraOptions: [(String, Value)] = []) async throws {
    updateScale()
    let (c, r) = gridSize()
    cols = c; rows = r
    var opts: [(Value, Value)] = [(.string("ext_linegrid"), .bool(true)), (.string("ext_multigrid"), .bool(true)), (.string("rgb"), .bool(true))]
    opts += extraOptions.map { (.string($0.0), $0.1) }
    _ = try await nvim.request("nvim_ui_attach", [.int(Int64(c)), .int(Int64(r)), .map(opts)])
    await installGeometry()
    attached = true
    // The view may have changed size while we waited for Neovim (resizeGrid does nothing before `attached`).
    resizeGrid()
    startLink()
  }

  func gridSize() -> (Int, Int) {
    let w = bounds.width * scale, h = bounds.height * scale
    let cols = max(10, Int(w / font.cellWidth))
    return (maxColumns > 0 ? min(cols, maxColumns) : cols, max(3, Int(h / font.cellHeight)))
  }

  /// Settings ▸ Editor ▸ max text width: Neovim's grid is at most this many columns (text soft-wraps there; the rest
  /// of the view is background). 0: the view's width.
  public var maxColumns = 0 { didSet { if maxColumns != oldValue { resizeGrid(); needsFrame = true; wake() } } }

  func updateScale() {
    let s = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    metalLayer.contentsScale = s
    surfaceLayer.contentsScale = s
    if s != scale {
      scale = s
      rebuildFont()
    }
    metalLayer.drawableSize = CGSize(width: bounds.width * s, height: bounds.height * s)
  }

  func rebuildFont() {
    font = FontSet(guifont: ui.guifont, linespace: ui.linespace, scale: scale)
    atlas = GlyphAtlas(device: renderer.device, font: font)
    fontGeneration += 1
    rowCache.removeAll()
    needsFrame = true
  }

  /// While true (the app animates a split), the view's size changes don't resize Neovim's grid: the text keeps its
  /// layout and is drawn clipped or with background beside it; set false to resize once.
  public var holdGridSize = false { didSet { if !holdGridSize && oldValue { resizeGrid() } } }

  func resizeGrid() {
    // Not while hidden or squeezed to nothing (the editor column hidden): Neovim keeps its last real size.
    guard !holdGridSize, !isHiddenOrHasHiddenAncestor, bounds.width >= font.cellWidth / scale * 10 else { return }
    let (c, r) = gridSize()
    guard attached, c != cols || r != rows else { return }
    cols = c; rows = r
    nvim.send("nvim_ui_try_resize", [.int(Int64(c)), .int(Int64(r))])
  }

  public override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    metalLayer.drawableSize = CGSize(width: newSize.width * scale, height: newSize.height * scale)
    resizeGrid()
    needsFrame = true
    wake()
  }

  public override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    updateScale()
    resizeGrid()
  }

  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    updateScale()
    startLink()
  }

  // MARK: the frame loop

  func startLink() {
    guard link == nil, window != nil else { return }
    // A window on no screen (measured runs place it right of every display: TAUDOT_MEASURE) gets no ticks from its
    // view's link: take the main screen's, so it still draws and presents.
    linkOnScreen = window?.screen == nil
    let l = window?.screen == nil ? (NSScreen.main?.displayLink(target: self, selector: #selector(tick(_:))) ?? displayLink(target: self, selector: #selector(tick(_:))))
      : displayLink(target: self, selector: #selector(tick(_:)))
    l.add(to: .main, forMode: .common)
    link = l
  }

  func wake() {
    // moved off every screen since the link was made (measured runs): a view's link stops ticking there
    if linkOnScreen != (window?.screen == nil), window != nil { link?.invalidate(); link = nil; startLink() }
    link?.isPaused = false
  }
  /// The link in use is the main screen's (the window was on no screen when it was made).
  var linkOnScreen = false

  @objc func tick(_ l: CADisplayLink) {
    if Neovim.stats != nil { Neovim.bump("tick") }
    if !advance(now: l.timestamp, target: l.targetTimestamp) { l.isPaused = true }
  }

  /// One frame: step the animations and draw if needed. Returns false when idle (the display link can pause).
  @discardableResult public func advance(now: CFTimeInterval, target: CFTimeInterval = 0) -> Bool {
    frameTarget = target
    let dt = lastTick == 0 ? 1.0 / 120 : min(max(now - lastTick, 0), 0.05)
    lastTick = now
    var animating = false
    var scrolled = false
    for k in scrolls.keys {
      if scrolls[k]!.step(dt, length: scrollAnimationLength, epsilon: 0.5 / Double(font.cellHeight)) { animating = true; if k == currentGrid { scrolled = true } }
    }
    animating = cursorDX.step(dt, length: cursorLength, epsilon: 0.5) || animating
    animating = cursorDY.step(dt, length: cursorLength, epsilon: 0.5) || animating
    if now < fingerActiveUntil { animating = true }
    if ProcessInfo.processInfo.environment["TAUDOT_DEBUG"] != nil {
      let why = "\(needsFrame ? "N" : "")\(scrolled ? "S" : "")\(cursorDX.position != 0 || cursorDY.position != 0 ? "C" : "")\(now < fingerActiveUntil ? "F" : "")\(animating ? "a" : "")"
      debugReasons[why, default: 0] += 1
    }
    if animating || needsFrame {
      if Neovim.stats != nil { Neovim.bump("render " + (needsFrame ? "needsFrame" : "animating")) }
      stats.tick(now: now, target: target, scrolling: scrolled || now < fingerActiveUntil)
      render()
      needsFrame = false
      // EditorGeometry now describes this frame: listeners move with it, in the same run-loop turn.
      geometryChanged()
    } else {
      lastTick = 0
      stats.idle()
      return false
    }
    return true
  }

  // MARK: redraw events

  func redraw(_ batches: [Value]) {
    if stats.pendingKey != nil { stats.redrawArrived() }
    ui.apply(batches)
  }

  func flushed(_ m: UIModel) {
    if m.optionsChanged && (font.linespace != m.linespace || FontSet(guifont: m.guifont, linespace: m.linespace, scale: scale).name != font.name
        || FontSet(guifont: m.guifont, linespace: m.linespace, scale: scale).size != font.size) {
      rebuildFont()
      resizeGrid()
    }
    for id in m.closed { scrolls[id] = nil }
    for (id, w) in m.windows where id != 1 && w.kind != .message {
      guard let g = m.grids[id] else { continue }
      let delta = m.pendingScroll[id] ?? 0
      guard m.dirty.contains(id) || delta != 0 || scrolls[id] == nil else { continue }
      let top = min(w.marginTop, g.height), bot = max(top, g.height - w.marginBottom)
      // While a trackpad gesture is on this window, its scrolling pays off the finger offset instead of animating.
      // While a trackpad gesture is on this window, or rows it asked for are still coming, Neovim's scrolling pays
      // off the finger offset instead of animating (the view is already there).
      let fromFinger = id == fingerGrid && delta != 0 && (fingerActive || fingerRequested != 0)
      if fromFinger && fingerRequested.signum() == delta.signum() {
        fingerRequested = delta.signum() * max(0, abs(fingerRequested) - abs(delta))
      }
      var rows = Array(g.rows[top..<bot])
      if !rows.isEmpty { rows[0] = withoutScrollMarker(rows[0]) }
      scrolls[id, default: SmoothScroll()].flush(rows[...], delta: delta, fromFinger: fromFinger)
      if delta != 0, ProcessInfo.processInfo.environment["TAUDOT_DEBUG"] != nil { FileHandle.standardError.write(String(format: "%.3f flush delta %d gridscroll %d finger %d requested %d\n", CACurrentMediaTime(), delta, m.gridScrolls[id] ?? 0, fromFinger ? 1 : 0, fingerRequested).data(using: .utf8)!) }
      if id == fingerGrid && fingerReplies == 0 { fingerRequested = 0 }
      if id == edgeGrid && delta != 0 && delta.signum() != fingerEdge { fingerEdge = 0 }
      if fromFinger { settleFingerIfDone() }
      if id == currentGrid && delta != 0 { lineMapScrolls += 1 }
    }
    // The current window: the cursor's, if it is a split (placed by win_pos). While a float has the cursor, the
    // geometry keeps following the text window under it.
    if let w = m.windows[m.cursorGrid], w.kind == .normal, w.placed, m.cursorGrid != 1 { currentGrid = m.cursorGrid }
    applyPendingMaps()
    // While its window scrolls (this flush moved it, or a trackpad gesture is on it), the cursor jumps with the text
    // instead of gliding: Neovim drags it along to keep scrolloff, and a glide after each of those hops slid it around.
    let cg = m.cursorGrid
    let scrolling = (m.pendingScroll[cg] ?? 0) != 0
      || (cg == fingerGrid && (fingerActive || fingerRequested != 0 || CACurrentMediaTime() < fingerActiveUntil))
    updateCursorTarget(snap: scrolling)
    requestLineMap()
    needsFrame = true
    if stats.pendingKey != nil { stats.flushed() }
    wake()
    onFlush?()
    dumpIfAsked()
  }

  var lastDump: CFTimeInterval = 0
  /// $TAUDOT_DUMP=<file>: the windows and grids, at most once a second (debugging).
  func dumpIfAsked() {
    guard let path = ProcessInfo.processInfo.environment["TAUDOT_DUMP"], CACurrentMediaTime() - lastDump > 1 else { return }
    lastDump = CACurrentMediaTime()
    var s = "view \(bounds.size) cols \(cols) rows \(rows) cursor grid \(ui.cursorGrid) \(ui.cursorRow),\(ui.cursorCol) current \(currentGrid)\n"
    for w in ui.drawOrder {
      let g = ui.grids[w.grid]
      s += "grid \(w.grid) win \(w.win) \(w.kind) at \(w.row),\(w.col) \(w.width)x\(w.height) grid \(g?.width ?? -1)x\(g?.height ?? -1) top \(w.topline) margins \(w.marginTop)/\(w.marginBottom) scroll \(scrolls[w.grid]?.offset ?? 0) h \(scrolls[w.grid]?.height ?? -1)\n"
      if let g { for r in 0..<min(3, g.height) { s += "  | \(g.rows[r].text.prefix(60))\n" } }
    }
    if let g = ui.grids[ui.cursorGrid], ui.cursorRow < g.height {
      let cells = g.rows[ui.cursorRow].cells
      var runs: [String] = []
      var start = 0
      for i in 1...cells.count where i == cells.count || cells[i].hl != cells[start].hl {
        runs.append("\(start)-\(i - 1):hl\(cells[start].hl)\(cells[start..<i].contains { $0.text != " " } ? "'" + cells[start..<i].map(\.text).joined().prefix(12) + "'" : "")")
        start = i
      }
      s += "cursor row runs: " + runs.joined(separator: " ") + "\n"
    }
    for (id, w) in ui.windows where w.hidden { s += "hidden grid \(id) win \(w.win)\n" }
    try? s.write(toFile: path, atomically: true, encoding: .utf8)
  }

  // MARK: drawing

  @inline(__always) var cw: Float { Float(font.cellWidth) }
  @inline(__always) var ch: Float { Float(font.cellHeight) }

  struct HlColors { var fg: SIMD4<Float>; var bg: SIMD4<Float>; var sp: SIMD4<Float>; var bgRaw: UInt32; var attr: HlAttr; var style: FontStyle }
  var hlCache: [Int32: HlColors] = [:]
  var hlCacheGen = -1

  func colors(_ id: Int32) -> HlColors {
    if hlCacheGen != ui.hlGeneration { hlCache.removeAll(); hlCacheGen = ui.hlGeneration }
    if let c = hlCache[id] { return c }
    let a = ui.attr(id)
    let (fg, bg, sp) = ui.colors(id)
    var style: FontStyle = []
    if a.bold { style.insert(.bold) }
    if a.italic { style.insert(.italic) }
    let c = HlColors(fg: rgba(fg), bg: rgba(bg), sp: rgba(sp), bgRaw: bg, attr: a, style: style)
    hlCache[id] = c
    return c
  }

  func buildRow(_ row: Row, floatBlend: Bool) -> RowEntry {
    var e = RowEntry()
    let cells = row.cells
    let cw = self.cw, ch = self.ch
    var runStart = 0
    var runColor: SIMD4<Float>? = nil
    func endRun(_ i: Int) {
      if let c = runColor, i > runStart { e.bg.append(RectInstance(rect: SIMD4(Float(runStart) * cw, 0, Float(i - runStart) * cw, ch), color: c, params: .zero)) }
    }
    let t = Float(font.underlineThickness)
    let ulY = Float(font.ascent + font.underlinePos)
    for i in 0..<cells.count {
      let cell = cells[i]
      let c = colors(cell.hl)
      var bg = c.bg
      if floatBlend && c.attr.blend > 0 { bg.w = 1 - Float(c.attr.blend) / 100 }
      if runColor != bg { endRun(i); runStart = i; runColor = bg }
      let x = Float(i) * cw
      if !cell.text.isEmpty && cell.text != " " {
        let wide = i + 1 < cells.count && cells[i + 1].text.isEmpty
        let g = atlas.entry(cell.text, c.style, cells: wide ? 2 : 1)
        if !g.empty {
          e.glyphs.append(GlyphInstance(rect: SIMD4(x + Float(g.dx), Float(g.dy), Float(g.w), Float(g.h)),
                                        uv: SIMD4(Float(g.x), Float(g.y), Float(g.w), Float(g.h)), color: c.fg,
                                        flags: SIMD4(g.color ? 1 : 0, 0, 0, 0)))
        }
      }
      let a = c.attr
      if a.underline || a.undercurl || a.underdouble || a.underdotted || a.underdashed || a.strikethrough {
        let sp = a.sp != nil ? c.sp : c.fg
        if a.underline { e.deco.append(RectInstance(rect: SIMD4(x, ulY, cw, t), color: sp, params: .zero)) }
        if a.underdouble {
          e.deco.append(RectInstance(rect: SIMD4(x, ulY - t, cw, t), color: sp, params: .zero))
          e.deco.append(RectInstance(rect: SIMD4(x, ulY + t, cw, t), color: sp, params: .zero))
        }
        if a.undercurl {
          let h = min(max(3 * t + 1, 4), ch - Float(font.ascent))
          e.deco.append(RectInstance(rect: SIMD4(x, min(ulY - t, ch - h), cw, h), color: sp, params: SIMD4(RectKind.undercurl.rawValue, t, cw, 0)))
        }
        if a.underdotted { e.deco.append(RectInstance(rect: SIMD4(x, ulY, cw, t), color: sp, params: SIMD4(RectKind.dotted.rawValue, t, 0, 0))) }
        if a.underdashed { e.deco.append(RectInstance(rect: SIMD4(x, ulY, cw, t), color: sp, params: SIMD4(RectKind.dashed.rawValue, t, 0, 0))) }
        if a.strikethrough {
          e.deco.append(RectInstance(rect: SIMD4(x, (Float(font.ascent) * 0.65).rounded(), cw, t), color: c.fg, params: .zero))
        }
      }
    }
    endRun(cells.count)
    return e
  }

  func rowEntry(_ row: Row, floatBlend: Bool) -> RowEntry {
    let key = row.version &* 2 &+ (floatBlend ? 1 : 0)
    if var e = rowCache[key] {
      if e.used != frameCounter { e.used = frameCounter; rowCache[key] = e }
      return e
    }
    var e = buildRow(row, floatBlend: floatBlend)
    e.used = frameCounter
    rowCache[key] = e
    return e
  }

  /// Pixel rect of a window.
  func windowRect(_ w: WindowInfo, _ g: Grid) -> (x: Float, y: Float, w: Float, h: Float) {
    (Float(w.col) * cw, Float(w.row) * ch, Float(g.width) * cw, Float(g.height) * ch)
  }

  func render() {
    frameCounter += 1
    lastRender = CACurrentMediaTime()
    let t0 = CACurrentMediaTime()
    if rowCacheKey != (fontGeneration, atlas.generation, ui.hlGeneration) {
      rowCache.removeAll(keepingCapacity: true)
      rowCacheKey = (fontGeneration, atlas.generation, ui.hlGeneration)
    }
    let atlasGen = atlas.generation
    let size = metalLayer.drawableSize
    renderer.begin(viewport: Float(size.width), Float(size.height))
    let defaultBg = rgba(ui.defaultBg)

    for w in ui.drawOrder {
      guard let g = ui.grids[w.grid] else { continue }
      let r = windowRect(w, g)
      let isFloat = w.kind == .floating
      let radius: Float = isFloat ? Float(6 * scale) : 0
      if isFloat {
        renderer.resetClip()
        let b = Float(10 * scale)
        renderer.rect(r.x - b, r.y - b + Float(3 * scale), r.w + 2 * b, r.h + 2 * b, SIMD4(0, 0, 0, 0.35), kind: .shadow, radius, b)
      }
      // Rows: (entry, y) in two regions, the fixed margins and the scrolled middle.
      let top = min(w.marginTop, g.height), bot = max(top, g.height - w.marginBottom)
      var fixed: [(RowEntry, Float)] = []
      var moving: [(RowEntry, Float)] = []
      for i in 0..<top { fixed.append((rowEntry(g.rows[i], floatBlend: isFloat), r.y + Float(i) * ch)) }
      for i in bot..<g.height { fixed.append((rowEntry(g.rows[i], floatBlend: isFloat), r.y + Float(i) * ch)) }
      let scroll = scrolls[w.grid].flatMap { $0.height == bot - top ? $0 : nil }
      if w.grid == currentGrid {
        recordDrawn(grid: w.grid, scroll: scroll, y: r.y, top: top, height: bot - top, x: r.x)
        if traceRows { debugDrawn = [] }
      }
      if let s = scroll {
        let vis = s.visible()
        for v in vis {
          let y = (r.y + (Float(top) + Float(v.y)) * ch).rounded()
          moving.append((rowEntry(v.row, floatBlend: isFloat), y))
          if traceRows && w.grid == currentGrid && v.y > -1 && v.y < Double(s.height) { debugDrawn.append((CGFloat(y) / scale, v.row.text)) }
        }
        if traceRows {
          // Rows of the scrolled area this frame has nothing to draw for (the user's blank-top report).
          let o = s.drawnOffset, first = Int(floor(o))
          let want = (first...(first + s.height)).filter { Double($0) - o > -1 && Double($0) - o < Double(s.height) }.count
          debugBlankRows += max(0, want - vis.filter { $0.y > -1 && $0.y < Double(s.height) }.count)
        }
      } else {
        for i in top..<bot { moving.append((rowEntry(g.rows[i], floatBlend: isFloat), r.y + Float(i) * ch)) }
      }
      for (rowsList, clipY, clipH, rad) in [(fixed, r.y, r.h, radius),
                                            (moving, r.y + Float(top) * ch, Float(bot - top) * ch, top == 0 && bot == g.height ? radius : 0)] {
        if rowsList.isEmpty { continue }
        renderer.setClip(r.x, clipY, r.w, clipH, radius: rad)
        // Blank the region first (rows that scrolled in from nowhere show the default background).
        if !isFloat { renderer.rect(r.x, clipY, r.w, clipH, defaultBg) }
        for (e, y) in rowsList { renderer.appendRects(e.bg[...], dx: r.x, dy: y) }
        for (e, y) in rowsList { renderer.appendGlyphs(e.glyphs[...], dx: r.x, dy: y) }
        for (e, y) in rowsList where !e.deco.isEmpty { renderer.appendRects(e.deco[...], dx: r.x, dy: y) }
      }
    }
    renderer.resetClip()
    drawCursor()
    if atlas.generation != atlasGen { needsFrame = true }  // the atlas filled up mid-frame: draw again
    pruneRowCache()
    if traceRows { onFrameRendered?() }
    let cpu = CACurrentMediaTime() - t0
    let st = stats
    let mark = st.frameStarted(cpu: cpu)
    let t1 = CACurrentMediaTime()
    if presentMode == .surface {
      present(surfaceFor: size, clear: defaultBg)
      // Shown at the next vsync with this run-loop turn's transaction.
      st.presented(mark, at: frameTarget > 0 ? frameTarget : CACurrentMediaTime())
    } else {
      renderer.end(layer: metalLayer, atlas: atlas, clear: defaultBg) { t in
        DispatchQueue.main.async { MainActor.assumeIsolated { st.presented(mark, at: t) } }
      }
    }
    st.submitted(CACurrentMediaTime() - t1)
  }

  /// Surface mode: render into a surface the window server isn't showing, wait for the GPU, then make it the layer's
  /// contents. The change commits with everything else this run-loop turn changed (the margin's cards).
  func present(surfaceFor size: CGSize, clear: SIMD4<Float>) {
    let w = Int(size.width), h = Int(size.height)
    if surfaceSize != (w, h) { surfaces = []; surfaceSize = (w, h); shownSurface = -1 }
    var i = surfaces.indices.first { $0 != shownSurface && !surfaces[$0].inUse }
    if i == nil, surfaces.count < 4, let s = FrameSurface(device: renderer.device, width: w, height: h) {
      surfaces.append(s); i = surfaces.count - 1
    }
    guard let i = i ?? surfaces.indices.first(where: { $0 != shownSurface }) else { return }
    renderer.end(surface: surfaces[i], atlas: atlas, clear: clear)
    surfaceLayer.contents = surfaces[i].surface
    shownSurface = i
  }

  func pruneRowCache() {
    if rowCache.count > 4 * max(rows, 50) * max(1, ui.windows.count) {
      let f = frameCounter
      rowCache = rowCache.filter { $0.value.used >= f - 2 }
    }
  }

  // MARK: cursor

  func cursorCell() -> (w: WindowInfo, g: Grid, row: Int, col: Int)? {
    guard let w = ui.windows[ui.cursorGrid], !w.hidden, let g = ui.grids[ui.cursorGrid],
          ui.cursorRow < g.height, ui.cursorCol < g.width else { return nil }
    return (w, g, ui.cursorRow, ui.cursorCol)
  }

  /// `snap`: no animation from the old place (the cursor moved because the view scrolled).
  func updateCursorTarget(snap: Bool = false) {
    guard let c = cursorCell() else { return }
    let r = windowRect(c.w, c.g)
    let t = SIMD2(r.x + Float(c.col) * cw, r.y + Float(c.row) * ch)
    if snap { cursorDX = Spring(); cursorDY = Spring() }
    if !snap, let old = cursorTarget, old != t {
      let d = old - t
      let curX = Float(cursorDX.position), curY = Float(cursorDY.position)
      cursorDX.position = Double(curX + d.x)
      cursorDY.position = Double(curY + d.y)
      cursorLength = (abs(d.x) <= 2 * cw + 0.5 && d.y == 0) ? 0.04 : 0.1
    }
    cursorTarget = t
  }

  /// IME preedit text, drawn over the cells at the cursor with an underline (Neovim doesn't see it until committed).
  func drawMarkedText() -> Bool {
    guard let marked = markedText?.string, !marked.isEmpty, let t = cursorTarget else { return false }
    let fg = rgba(ui.defaultFg), bg = rgba(ui.defaultBg)
    var x = t.x
    let thick = Float(font.underlineThickness)
    for c in marked {
      let s = String(c)
      let wide = c.unicodeScalars.contains { $0.properties.isEmojiPresentation || (0x1100...0x115F).contains($0.value) || (0x2E80...0xA4CF).contains($0.value) || (0xAC00...0xD7A3).contains($0.value) || (0xF900...0xFAFF).contains($0.value) || (0xFF00...0xFF60).contains($0.value) || (0xFFE0...0xFFE6).contains($0.value) }
      let w = cw * (wide ? 2 : 1)
      renderer.rect(x, t.y, w, ch, bg)
      renderer.glyph(atlas.entry(s, [], cells: wide ? 2 : 1), x: x, y: t.y, color: fg)
      renderer.rect(x, t.y + Float(font.ascent + font.underlinePos), w, thick, fg)
      x += w
    }
    renderer.rect(x, t.y, max(Float(scale), 2), ch, fg)
    return true
  }

  func drawCursor() {
    if traceRows { debugCursor = nil }
    if ui.cursorGrid != currentGrid {
      if let a = cursorAbs, a.grid == currentGrid, let d = drawnGeometry, d.grid == a.grid {
        let px = (d.y + (Float(d.top) + Float(Double(a.abs - d.base) - d.offset)) * d.ch).rounded()
        cursorRect = CGRect(x: a.x, y: CGFloat(px) / scale, width: a.w, height: CGFloat(ch) / scale)
      }
    }
    if drawMarkedText() { return }
    guard !ui.busy, let c = cursorCell(), let target = cursorTarget else { return }
    let cell = c.g.rows[c.row].cells[c.col]
    let wide = c.col + 1 < c.g.width && c.g.rows[c.row].cells[c.col + 1].text.isEmpty
    let shape = ui.cursorShape
    let cellColors = colors(cell.hl)
    var bg = cellColors.fg, fg = cellColors.bg
    if shape.attrId != 0 {
      let a = ui.attr(Int32(shape.attrId))
      if a.fg != nil || a.bg != nil || a.reverse {
        let cc = ui.colors(Int32(shape.attrId))
        bg = rgba(a.bg == nil && !a.reverse ? ui.colors(cell.hl).fg : cc.bg)
        fg = rgba(a.fg == nil && !a.reverse ? ui.colors(cell.hl).bg : cc.fg)
      }
    }
    // In the scrolled part of a window the cursor rides with its row: drawn where render() draws that row this frame
    // (same offset, same rounding), clipped like the rows.
    var rowY = target.y, abs = c.row, scrolled = false
    let top = min(c.w.marginTop, c.g.height), bot = max(top, c.g.height - c.w.marginBottom)
    if let s = scrolls[c.w.grid], s.height == bot - top, (top..<bot).contains(c.row) {
      rowY = (target.y - Float(s.drawnOffset) * ch).rounded(); abs = s.base + c.row - top; scrolled = true
      let r = windowRect(c.w, c.g)
      renderer.setClip(r.x, r.y + Float(top) * ch, r.w, Float(bot - top) * ch)
    }
    defer { renderer.resetClip() }
    let x = (target.x + Float(cursorDX.position)).rounded(), y = (rowY + Float(cursorDY.position)).rounded()
    if traceRows { debugCursor = (Double((y - rowY) / Float(scale)), Double((x - target.x) / Float(scale)), abs) }
    let w = cw * (wide ? 2 : 1)
    if c.w.grid == currentGrid {
      cursorRect = CGRect(x: CGFloat(x) / scale, y: CGFloat(y) / scale, width: CGFloat(w) / scale, height: CGFloat(ch) / scale)
      cursorAbs = scrolled ? (c.w.grid, abs, CGFloat(x) / scale, CGFloat(w) / scale) : nil
    }
    let pct = Float(max(shape.cellPercentage, 1)) / 100
    if !focused {
      let t = Float(max(1, scale))
      renderer.rect(x, y, w, t, bg); renderer.rect(x, y + ch - t, w, t, bg)
      renderer.rect(x, y, t, ch, bg); renderer.rect(x + w - t, y, t, ch, bg)
      return
    }
    switch shape.kind {
    case .block:
      renderer.rect(x, y, w, ch, bg)
      if !cell.text.isEmpty && cell.text != " " {
        let g = atlas.entry(cell.text, cellColors.style, cells: wide ? 2 : 1)
        renderer.glyph(g, x: x, y: y, color: fg)
      }
    case .vertical:
      renderer.rect(x, y, max(Float(scale), (cw * pct).rounded()), ch, bg)
    case .horizontal:
      let h = max(Float(scale), (ch * pct).rounded())
      renderer.rect(x, y + ch - h, w, h, bg)
    }
  }

}


extension EditorView {
  /// The text of the rows the next frame draws for a window, top to bottom, as `render()` places them (for tests:
  /// once settled it must equal Neovim's grid).
  public func drawnRows(grid id: Int) -> [String] {
    guard let w = ui.windows[id], let g = ui.grids[id] else { return [] }
    let top = min(w.marginTop, g.height), bot = max(top, g.height - w.marginBottom)
    var out: [(Double, String)] = []
    for i in 0..<top { out.append((Double(i), g.rows[i].text)) }
    for i in bot..<g.height { out.append((Double(i), g.rows[i].text)) }
    if let s = scrolls[id], s.height == bot - top {
      for v in s.visible() where v.y > -1 && v.y < Double(bot - top) { out.append((Double(top) + v.y, v.row.text)) }
    } else {
      for i in top..<bot { out.append((Double(i), g.rows[i].text)) }
    }
    return out.sorted { $0.0 < $1.0 }.map(\.1)
  }

  /// Neovim's own rows for a window.
  /// Neovim's rows as it sent them.
  public func gridRowsRaw(grid id: Int) -> [String] { ui.grids[id]?.rows.map(\.text) ?? [] }

  /// Neovim's rows as the app means to show them (the smoothscroll marker hidden).
  public func gridRows(grid id: Int) -> [String] {
    guard let g = ui.grids[id] else { return [] }
    let top = ui.windows[id].map { min($0.marginTop, g.height) } ?? 0
    return g.rows.enumerated().map { $0.offset == top ? withoutScrollMarker($0.element).text : $0.element.text }
  }

  /// Neovim's `smoothscroll` marker: `<<<` (NonText) over the first cells of the window's top row while its line is
  /// partly scrolled off. Our pixel scroll already shows the partly scrolled line, and a row kept in the scroll ring
  /// carried the marker with it, so copies of it showed in other rows during fast flicks: the cells are blanked.
  func withoutScrollMarker(_ r: Row) -> Row {
    let c = r.cells
    guard c.count > 3, c[0].text == "<", c[1].text == "<", c[2].text == "<", c[3].text != "<" else { return r }
    if let nt = ui.hlGroups["NonText"], c[0].hl != Int32(nt) { return r }
    var out = r
    for i in 0..<3 { out.cells[i] = Cell(" ", hl: c[3].hl) }
    return out
  }

  /// Whether the window's scroll animation and trackpad offset are at rest.
  public func scrollSettled(grid id: Int) -> Bool { (scrolls[id]?.offset ?? 0) == 0 && (scrolls[id]?.lag ?? 0) == 0 && fingerGrid != id }
}
