// The PDF pane: TeXpresso's pages as tiles in Core Animation layers inside an NSScrollView.
//
// - Document coordinates are PDF points; NSScrollView's magnification is the zoom, so scrolling and pinching only move
//   and scale layers (Core Animation scales the bitmaps; nothing is drawn while moving).
// - Each page: a white layer with a shadow, a low-res underlay of the whole page, and sharp tiles rendered at the
//   current zoom × backing scale. Tiles are rendered for the view plus a screen around it; while a pinch is live
//   nothing is rendered, and when it ends the new scale's tiles replace the old ones page by page, in one frame.
// - A page TeXpresso reports changed keeps its old tiles on screen until all its new visible tiles have arrived.
import AppKit
import QuartzCore
import TaudotCursor
import TaudotShared

/// The flipped document view; its layer holds the page layers.
final class PagesView: NSView {
  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }
  /// Double-click, or Cmd-click (Skim and Overleaf's gesture). The pages have no text selection to fight with.
  var onDoubleClick: ((NSPoint) -> Void)?
  /// A plain click: true when it was handled (a comment note).
  var onClick: ((NSPoint) -> Bool)?
  /// The mouse over the pages (nil: it left).
  var onHover: ((NSPoint?) -> Void)?
  override func mouseDown(with e: NSEvent) {
    let pt = convert(e.locationInWindow, from: nil)
    if e.clickCount == 2 || (e.clickCount == 1 && e.modifierFlags.contains(.command)) {
      onDoubleClick?(pt)
    } else if e.clickCount == 1, onClick?(pt) == true {
      return
    } else {
      if e.clickCount == 1 { downAt = pt }
      super.mouseDown(with: e)
    }
  }
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
  }
  /// A drag over the pages (to select text): where it started, where it is, and whether the mouse came up.
  var onDrag: ((_ from: NSPoint, _ to: NSPoint, _ done: Bool) -> Void)?
  private var dragFrom: NSPoint?
  override func mouseDragged(with e: NSEvent) {
    let pt = convert(e.locationInWindow, from: nil)
    if dragFrom == nil, let start = downAt, hypot(pt.x - start.x, pt.y - start.y) > 3 { dragFrom = start }
    if let f = dragFrom { onDrag?(f, pt, false) }
    autoscroll(with: e)
  }
  /// A plain click that came up without a drag (a link: a cross-reference).
  var onTap: ((NSPoint) -> Void)?
  override func mouseUp(with e: NSEvent) {
    if let f = dragFrom { onDrag?(f, convert(e.locationInWindow, from: nil), true) }
    else if let d = downAt, e.clickCount == 1 { onTap?(d) }
    dragFrom = nil
    downAt = nil
  }
  private var downAt: NSPoint?
  override func mouseMoved(with e: NSEvent) {
    // not under the pointer (a divider's grip over the pane's edge): leave the cursor to what is
    if let c = window?.contentView, let top = c.hitTest(c.convert(e.locationInWindow, from: nil)), !top.isDescendant(of: self) {
      return
    }
    onHover?(convert(e.locationInWindow, from: nil))
  }
  override func mouseExited(with e: NSEvent) { onHover?(nil) }
  override func updateLayer() {}
  var onMenu: (() -> NSMenu)?
  override func menu(for event: NSEvent) -> NSMenu? { onMenu?() }
}

struct TileKey: Hashable {
  var ver: Int, scale: Double, tx: Int, ty: Int
}

/// What's on screen for one page.
@MainActor final class PageState {
  var size: CGSize
  var origin = CGPoint.zero  // top-left in document points
  var ver = 0  // bumped when TeXpresso says the page changed
  let layer = CALayer()
  let under = CALayer()
  var underVer = -1
  /// The content version last shown (swapped in) or, before any edit, the first: a swap to a newer one is an edit
  /// on screen (`onPageShown`), even when the page's tiles had been freed meanwhile; a zoom alone is not.
  var lastShownVer = 0
  /// When TeXpresso last reported it changed (CACurrentMediaTime), for settling: while typing, only what's in view
  /// is drawn again; the underlay and the tiles around the view wait until it has been still for `settle` s.
  var changedAt: CFTimeInterval = 0
  var underInflight = -1
  var tiles: [TileKey: CALayer] = [:]  // attached
  var ready: [TileKey: TileImage] = [:]  // rendered, waiting for the whole visible set
  var inflight: Set<TileKey> = []
  /// (ver, scale) of the tiles shown as current; others are stale and only stay until replaced
  var shown: (ver: Int, scale: Double)? = nil

  init(size: CGSize, paper: CGColor) {
    self.size = size
    layer.backgroundColor = paper
    layer.shadowColor = .black
    layer.shadowOpacity = 0.22
    layer.shadowRadius = 3
    layer.shadowOffset = CGSize(width: 0, height: 1)
    layer.anchorPoint = .zero
    under.anchorPoint = .zero
    under.contentsGravity = .resize
    layer.addSublayer(under)
  }

  var rect: CGRect { CGRect(origin: origin, size: size) }
}

let paneTrace = ProcessInfo.processInfo.environment["TAUDOT_PDF_TRACE"] != nil
func trace(_ s: @autoclosure () -> String) {
  if paneTrace { FileHandle.standardError.write(Data(String(format: "[%.3f] pane: ", CACurrentMediaTime()).utf8) + Data((s() + "\n").utf8)) }
}

@MainActor public final class PDFPaneView: NSView {
  public static let tilePx = 1024
  static let underWidthPx = 480.0
  static let gap: CGFloat = 12, margin: CGFloat = 16

  let scroll = PDFScrollView()
  let pagesView = PagesView()
  let para = ParaLayer()  // the paragraph preview (ParaOverlay.swift)
  var pages: [PageState] = []
  var renderer: ((_ page: Int, _ scale: Double, _ x: Int, _ y: Int, _ w: Int, _ h: Int) async -> TileImage?)?
  var onLastPageInView: ((Int) -> Void)?
  var onDoubleClick: ((_ page: Int, _ x: Double, _ y: Double) -> Void)?
  /// Called when a page's new content (after `markChanged`) is first on screen.
  var onPageShown: ((Int) -> Void)?
  public var maxInflight = 4
  /// False: nothing can render now (no typesetter): no renders are asked for, none retried. A typesetter coming
  /// calls `queueRefresh`.
  var canRender: (() -> Bool)?
  /// A render not answered in this long gives its slot back (its late answer is dropped).
  nonisolated(unsafe) static var renderTimeout: Double = 10
  private var inflight = 0
  private var liveMagnify = false

  // ---- frame probes (pdfpipe, step 5): what one scroll or zoom step costs the main thread ----------------------------
  /// The magnification at the last step (a change: a zoom step, else a scroll step).
  private var frameMag: CGFloat = 0
  /// The step waiting for its turn to end: when the content moved, and whether it zoomed.
  private var frameStart: (t: Double, zoom: Bool)?
  nonisolated(unsafe) private var frameObserver: CFRunLoopObserver?
  /// Steps measured, for tests: (zoom, µs).
  public private(set) var frames: [(zoom: Bool, us: Int64)] = []

  /// The content moved: `scrollFrame` / `zoomFrame` get the time from here to the end of this run-loop turn (the
  /// pane's refresh, layout, Core Animation's commit), recorded once per turn.
  private func frameMoved() {
    let zoom = scroll.magnification != frameMag
    frameMag = scroll.magnification
    if let f = frameStart { frameStart = (f.t, f.zoom || zoom); return }
    frameStart = (Latency.now, zoom)
    if frameObserver == nil {
      let o = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, Int.max) { [weak self] _, _ in
        MainActor.assumeIsolated { self?.frameEnded() }
      }
      CFRunLoopAddObserver(CFRunLoopGetMain(), o, .commonModes)
      frameObserver = o
    }
  }

  private func frameEnded() {
    guard let f = frameStart else { return }
    frameStart = nil
    let us = Int64((Latency.now - f.t) * 1e6)
    Latency.shared.record(f.zoom ? .zoomFrame : .scrollFrame, value: us)
    if frames.count < 4096 { frames.append((f.zoom, us)) }
  }
  private var fitWidth = true
  private var refreshQueued = false
  let forward = ForwardMark()
  let cursorDot = CursorDot()
  lazy var notes = NotesOverlay(view: self)
  lazy var selection = SelectionOverlay(view: self)
  /// History's changes on a version's pages (VersionPDF.swift); empty otherwise.
  lazy var changes = ChangesOverlay(view: self)
  /// A drag over the pages, in page points: (page, from, to, done). The pane maps it to words and a source range.
  var onSelect: ((_ page: Int, _ from: CGPoint, _ to: CGPoint, _ done: Bool) -> Void)?
  /// A plain click on a page, in page points (the pane follows a cross-reference there).
  var onTap: ((_ page: Int, _ x: Double, _ y: Double) -> Void)?

  // stats
  public private(set) var renderCount = 0
  public private(set) var renderMs: [Double] = []

  public override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    scroll.contentView = CenteringClipView()
    scroll.documentView = pagesView
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = true
    scroll.autohidesScrollers = true
    scroll.scrollerStyle = .overlay
    scroll.allowsMagnification = true
    scroll.minMagnification = 0.1
    scroll.maxMagnification = 10
    scroll.drawsBackground = true
    scroll.backgroundColor = NSColor.underPageBackgroundColor
    scroll.autoresizingMask = [.width, .height]
    scroll.frame = bounds
    scroll.contentView.postsBoundsChangedNotifications = true
    addSubview(scroll)
    pagesView.wantsLayer = true
    pagesView.layerContentsRedrawPolicy = .never
    pagesView.frame = .zero
    pagesView.onDoubleClick = { [weak self] p in self?.doubleClick(p) }
    pagesView.onMenu = { [weak self] in self?.contextMenu() ?? NSMenu() }
    pagesView.onClick = { [weak self] p in
      guard let self else { return false }
      if self.changes.click(p) { self.selection.clear(); return true }
      if self.notes.click(p) { self.selection.clear(); return true }
      self.selection.clear()  // a plain click on the page gives a selection up
      return false
    }
    pagesView.onDrag = { [weak self] a, b, done in self?.drag(a, b, done) }
    pagesView.onTap = { [weak self] pt in
      guard let self, let i = self.pages.firstIndex(where: { $0.rect.contains(pt) }) else { return }
      let p = self.pages[i]
      self.onTap?(i, pt.x - p.origin.x, pt.y - p.origin.y)
    }
    pagesView.onHover = { [weak self] p in
      guard let self else { return }
      if self.changes.hover(p) { self.notes.hover(nil); return }
      self.notes.hover(p)
    }
    forward.origin = { [weak self] i in self.map { i < $0.pages.count ? $0.pages[i].origin : .zero } ?? .zero }
    forward.magnification = { [weak self] in self?.scroll.magnification ?? 1 }
    cursorDot.origin = { [weak self] i in self.map { i < $0.pages.count ? $0.pages[i].origin : .zero } ?? .zero }
    let nc = NotificationCenter.default
    nc.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.frameMoved()
        self?.queueRefresh()
        self?.notes.rescale()
        self?.changes.rescale()
        self?.forward.rescale()
        self?.notes.reposition()
        self?.selection.reposition()
      }
    }
    nc.addObserver(forName: NSScrollView.willStartLiveMagnifyNotification, object: scroll, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.liveMagnify = true
        self?.fitWidth = false
      }
    }
    nc.addObserver(forName: NSScrollView.didEndLiveMagnifyNotification, object: scroll, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.liveMagnify = false
        self?.queueRefresh()
      }
    }
  }

  required init?(coder: NSCoder) { fatalError() }

  deinit { if let o = frameObserver { CFRunLoopObserverInvalidate(o) } }

  public override func layout() {
    super.layout()
    if fitWidth { fit() }
    forward.rescale()
    queueRefresh()
    notes.reposition()
    selection.reposition()
  }

  public override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    scroll.backgroundColor = NSColor.underPageBackgroundColor
  }

  public override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    queueRefresh()
  }

  // ---- layout ---------------------------------------------------------------------------------------------------

  var docWidth: CGFloat { (pages.map(\.size.width).max() ?? 612) + 2 * Self.margin }

  /// New page sizes (a `pages` event): keeps what's on screen where it is.
  func setSizes(_ sizes: [CGSize]) {
    let anchor = pages.isEmpty ? nil : topAnchor()
    let first = pages.isEmpty
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    while pages.count > sizes.count { pages.removeLast().layer.removeFromSuperlayer() }
    for (i, s) in sizes.enumerated() {
      if i < pages.count {
        if pages[i].size != s { pages[i].size = s; pages[i].ver += 1 }
      } else {
        let p = PageState(size: s, paper: pageStyle.paper)
        pages.append(p)
        pagesView.layer?.addSublayer(p.layer)
      }
    }
    let w = docWidth
    var y = Self.margin
    for p in pages {
      p.origin = CGPoint(x: ((w - p.size.width) / 2).rounded(), y: y)
      p.layer.frame = p.rect
      p.layer.shadowPath = CGPath(rect: CGRect(origin: .zero, size: p.size), transform: nil)
      p.under.frame = CGRect(origin: .zero, size: p.size)
      y += p.size.height + Self.gap
    }
    let h = y - Self.gap + Self.margin
    if pagesView.frame.size != CGSize(width: w, height: h) { pagesView.setFrameSize(CGSize(width: w, height: h)) }
    if forward.layer.superlayer == nil { pagesView.layer?.addSublayer(forward.layer) }
    forward.layer.frame = CGRect(x: 0, y: 0, width: w, height: h)
    if cursorDot.layer.superlayer == nil { pagesView.layer?.addSublayer(cursorDot.layer) }
    cursorDot.layer.frame = CGRect(x: 0, y: 0, width: w, height: h)
    CATransaction.commit()
    forward.relayout()
    cursorDot.relayout()
    if fitWidth { fit() }
    if let anchor { restore(anchor) }
    if first {
      scroll.contentView.setBoundsOrigin(NSPoint(x: scroll.contentView.bounds.minX, y: 0))
      scroll.reflectScrolledClipView(scroll.contentView)
    }
    queueRefresh()
  }

  private func fit() {
    let w = scroll.contentView.bounds.width * scroll.magnification  // view width in window points
    guard w > 0, !pages.isEmpty else { return }
    let m = scroll.frame.width / docWidth
    if abs(m - scroll.magnification) > 0.0005 { scroll.magnification = m }
  }

  /// The page at the top of the view and how far down it the view starts, to keep across relayouts.
  /// Where the view's top is: the page and how far down it (points), for the page cache.
  public var viewTop: (page: Int, y: Double)? { topAnchor().map { ($0.page, Double($0.dy)) } }
  public func setViewTop(page: Int, y: Double) { restore((page, CGFloat(y), scroll.contentView.bounds.minX)) }

  /// A page from the page cache, drawn under the page until its own underlay (from this run) replaces it.
  /// The pages on screen are another document's (a pane reused for another folder): none counts as rendered, so the
  /// cache's images may go up and every page is drawn again.
  func forgetRenders() {
    for p in pages {
      p.underVer = -1
      p.underInflight = -1
      p.ver += 1
      p.lastShownVer = p.ver  // another document's first drawing, not an edit
    }
    queueRefresh()
  }

  public func showCached(page: Int, image: CGImage) {
    guard page < pages.count, pages[page].underVer < 0 else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    pages[page].under.contents = image
    CATransaction.commit()
  }

  private func topAnchor() -> (page: Int, dy: CGFloat, x: CGFloat)? {
    let b = scroll.contentView.bounds
    guard let i = pages.firstIndex(where: { $0.rect.maxY + Self.gap > b.minY }) else { return nil }
    return (i, b.minY - pages[i].origin.y, b.minX)
  }

  private func restore(_ a: (page: Int, dy: CGFloat, x: CGFloat)) {
    guard a.page < pages.count else { return }
    let y = pages[a.page].origin.y + a.dy
    scroll.contentView.setBoundsOrigin(NSPoint(x: a.x, y: y))
    scroll.reflectScrolledClipView(scroll.contentView)
  }

  // ---- what to render -------------------------------------------------------------------------------------------

  var pixelScale: Double {
    Double(scroll.magnification * (window?.backingScaleFactor ?? 2))
  }

  /// The reader's page: white, sepia or dark (Settings ▸ PDF). The driver recolours renders (figures kept); here the
  /// page layers' own colour (seen before a page's first render), and the gaps between pages.
  public enum PageStyle: String, Sendable {
    case white, sepia, dark
    var paper: CGColor {
      switch self {
      case .white: .white
      case .sepia: CGColor(srgbRed: 0xf4 / 255.0, green: 0xec / 255.0, blue: 0xd8 / 255.0, alpha: 1)
      case .dark: CGColor(srgbRed: 0x1d / 255.0, green: 0x1f / 255.0, blue: 0x21 / 255.0, alpha: 1)
      }
    }
  }
  public private(set) var pageStyle: PageStyle = .white

  /// Applies a new style (the driver already has it): every page is drawn again, its old tiles staying until the
  /// new ones land, as for an edit. Dark pages get a dark pane around them (gaps, the issues strip over it).
  public func setPageStyle(_ s: PageStyle) {
    guard s != pageStyle else { return }
    pageStyle = s
    appearance = s == .dark ? NSAppearance(named: .darkAqua) : nil
    scroll.backgroundColor = NSColor.underPageBackgroundColor
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for p in pages { p.layer.backgroundColor = s.paper }
    CATransaction.commit()
    for i in pages.indices { markChanged(i) }
  }

  /// A page's content changed (TeXpresso's `changed` list): its tiles are stale but stay until new ones land.
  func markChanged(_ i: Int) {
    guard i < pages.count else { return }
    pages[i].ver += 1
    pages[i].changedAt = CACurrentMediaTime()
    trace("changed p\(i) ver \(pages[i].ver) shown \(String(describing: pages[i].shown))")
    queueRefresh()
    // and once it has settled: its underlay and the tiles around the view
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.settle + 0.02) { [weak self] in
      MainActor.assumeIsolated { self?.queueRefresh() }
    }
  }

  func queueRefresh() {
    guard !refreshQueued else { return }
    refreshQueued = true
    DispatchQueue.main.async { [weak self] in
      MainActor.assumeIsolated {
        self?.refreshQueued = false
        self?.refresh()
      }
    }
  }

  private var lastGoal = -1
  /// A changed page counts as still changing (typing) for this long.
  static let settle: CFTimeInterval = 0.4

  enum Job { case under(Int), tile(Int, TileKey) }

  /// Works out the renders the view needs, best first, and starts some; swaps in finished sets; frees far tiles.
  func refresh() { Latency.shared.section("pdf refresh") { refreshNow() } }

  private func refreshNow() {
    let t0 = CACurrentMediaTime()
    defer { let ms = (CACurrentMediaTime() - t0) * 1000; if ms > 1.5 { trace(String(format: "refresh %.1f ms", ms)) } }
    guard !pages.isEmpty else { return }
    let view = scroll.contentView.bounds
    let inView = pages.indices.filter { pages[$0].rect.intersects(view) }
    if let last = inView.last, last != lastGoal {
      lastGoal = last
      onLastPageInView?(last)
    }
    let around = view.insetBy(dx: 0, dy: -view.height)
    let near = pages.indices.filter { pages[$0].rect.intersects(around) }
    let keep = view.insetBy(dx: -view.width, dy: -view.height * 3)
    let s = pixelScale

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    var jobs: [(Double, Job)] = []
    let now = CACurrentMediaTime()
    for i in near {
      let p = pages[i]
      let dist = abs(p.rect.midY - view.midY) / max(view.height, 1)
      // a page being typed on, already drawn: only its tiles in view now (the rest when it settles)
      let busy = p.shown != nil && p.underVer >= 0 && now - p.changedAt < Self.settle
      if p.underVer != p.ver && p.underInflight != p.ver && !busy {
        // first: a page with nothing yet; a changed page's underlay waits for its tiles (they cover it)
        jobs.append((p.underVer < 0 ? dist - 10 : dist + 3, .under(i)))
      }
      if liveMagnify { continue }
      for k in neededTiles(i, s, in: around) where p.tiles[k] == nil && p.ready[k] == nil && !p.inflight.contains(k) {
        let r = tileRect(i, k).offsetBy(dx: p.origin.x, dy: p.origin.y)
        let visible = r.intersects(view)
        if busy && !visible { continue }
        jobs.append(((visible ? 0 : 5) + abs(r.midY - view.midY) / max(view.height, 1), .tile(i, k)))
      }
      swapIfComplete(i, s, view: view)
    }
    // free tiles far from the view, and stale ones the current set covers
    for (i, p) in pages.enumerated() where !p.tiles.isEmpty || !p.ready.isEmpty {
      if !p.rect.intersects(keep) {
        for l in p.tiles.values { l.removeFromSuperlayer() }
        p.tiles = [:]
        p.ready = [:]
        p.shown = nil
        continue
      }
      _ = i
    }
    CATransaction.commit()

    jobs.sort { $0.0 < $1.0 }
    guard canRender?() ?? true else { return }
    for (_, job) in jobs {
      if inflight >= maxInflight { break }
      start(job, s)
    }
  }

  private func tileRect(_ i: Int, _ k: TileKey) -> CGRect {
    let T = Double(Self.tilePx)
    let W = (pages[i].size.width * k.scale).rounded(.up), H = (pages[i].size.height * k.scale).rounded(.up)
    let x = Double(k.tx) * T, y = Double(k.ty) * T
    return CGRect(x: x / k.scale, y: y / k.scale, width: min(T, W - x) / k.scale, height: min(T, H - y) / k.scale)
  }

  /// Current-version tiles of page i at scale s that intersect `area` (document coordinates).
  private func neededTiles(_ i: Int, _ s: Double, in area: CGRect) -> [TileKey] {
    let p = pages[i]
    let r = p.rect.intersection(area)
    guard !r.isNull, r.width > 0, r.height > 0 else { return [] }
    let T = Double(Self.tilePx)
    let W = (p.size.width * s).rounded(.up), H = (p.size.height * s).rounded(.up)
    let x0 = Int(((r.minX - p.origin.x) * s) / T), x1 = Int(min((r.maxX - p.origin.x) * s, W - 1) / T)
    let y0 = Int(((r.minY - p.origin.y) * s) / T), y1 = Int(min((r.maxY - p.origin.y) * s, H - 1) / T)
    guard x1 >= x0, y1 >= y0 else { return [] }
    var out: [TileKey] = []
    for ty in max(0, y0)...y1 { for tx in max(0, x0)...x1 { out.append(TileKey(ver: p.ver, scale: s, tx: tx, ty: ty)) } }
    return out
  }

  /// One render's slot: given back once, by its answer or by the timeout, whichever comes first.
  private final class Slot { var open = true }

  /// Takes a slot for a render; `release` gives it back (on the timeout, `timedOut` runs and the answer is dropped).
  private func takeSlot(_ t0: CFTimeInterval, timedOut: @escaping () -> Void) -> Slot {
    inflight += 1
    let slot = Slot()
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.renderTimeout) { [weak self] in
      MainActor.assumeIsolated {
        guard let self, slot.open else { return }
        slot.open = false
        self.inflight -= 1
        trace("render timed out: slot freed")
        timedOut()
        self.retryLater()
      }
    }
    return slot
  }

  /// The answer came: false if the slot had timed out (drop the answer).
  private func release(_ slot: Slot, _ t0: CFTimeInterval) -> Bool {
    guard slot.open else { return false }
    slot.open = false
    done(t0)
    return true
  }

  private func start(_ job: Job, _ s: Double) {
    guard let renderer else { return }
    let t0 = CACurrentMediaTime()
    switch job {
    case .under(let i):
      let p = pages[i]
      let ver = p.ver
      p.underInflight = ver
      let slot = takeSlot(t0) { if p.underInflight == ver { p.underInflight = -1 } }
      let u = Self.underWidthPx / Double(p.size.width)
      let w = Int((p.size.width * u).rounded(.up)), h = Int((p.size.height * u).rounded(.up))
      Task {
        let img = await renderer(i, u, 0, 0, w, h)
        guard self.release(slot, t0) else { return }
        guard i < self.pages.count, self.pages[i] === p else { return }
        if p.underInflight == ver { p.underInflight = -1 }
        guard let img else { self.retryLater(); return }
        self.retryDelay = 0.1
        guard p.ver == ver else { self.queueRefresh(); return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        p.under.contents = img.surface
        p.underVer = ver
        CATransaction.commit()
        self.queueRefresh()
      }
    case .tile(let i, let k):
      let p = pages[i]
      p.inflight.insert(k)
      let slot = takeSlot(t0) { p.inflight.remove(k) }
      let T = Self.tilePx
      let W = Int((p.size.width * k.scale).rounded(.up)), H = Int((p.size.height * k.scale).rounded(.up))
      let x = k.tx * T, y = k.ty * T
      Task {
        let img = await renderer(i, k.scale, x, y, min(T, W - x), min(T, H - y))
        guard self.release(slot, t0) else { return }
        guard i < self.pages.count, self.pages[i] === p else { return }
        p.inflight.remove(k)
        trace("tile p\(i) \(k.tx),\(k.ty) v\(k.ver)/\(p.ver) s \(k.scale)/\(self.pixelScale) \(img == nil ? "nil" : "ok")")
        if let img, k.ver == p.ver, abs(k.scale - self.pixelScale) < 1e-9 { p.ready[k] = img }
        if img == nil { self.retryLater(); return }  // page rolled back by a rerun: try again shortly
        self.retryDelay = 0.1
        self.queueRefresh()
      }
    }
  }

  private var retryQueued = false
  /// Doubles while renders keep failing (up to 2 s), back to 0.1 s after one works.
  private var retryDelay = 0.1
  private func retryLater() {
    guard !retryQueued else { return }
    retryQueued = true
    let d = retryDelay
    retryDelay = min(2, retryDelay * 2)
    DispatchQueue.main.asyncAfter(deadline: .now() + d) { [weak self] in
      MainActor.assumeIsolated {
        self?.retryQueued = false
        self?.queueRefresh()
      }
    }
  }

  private func done(_ t0: CFTimeInterval) {
    inflight -= 1
    renderCount += 1
    renderMs.append((CACurrentMediaTime() - t0) * 1000)
  }

  /// When every current tile of page i that is in view is rendered, put them all on screen in one frame and drop
  /// the stale ones. Once a page shows its current set, later tiles (scrolling) go up as they come.
  private func swapIfComplete(_ i: Int, _ s: Double, view: CGRect) {
    let p = pages[i]
    let isCurrent = p.shown.map { $0.ver == p.ver && $0.scale == s } ?? false
    if !isCurrent {
      let need = neededTiles(i, s, in: view)
      guard !need.isEmpty, need.allSatisfy({ p.ready[$0] != nil || p.tiles[$0] != nil }) else { return }
      let firstShow = p.ver != p.lastShownVer
      for (k, l) in p.tiles where k.ver != p.ver || k.scale != s {
        l.removeFromSuperlayer()
        p.tiles[k] = nil
      }
      trace("swap p\(i) v\(p.ver) first \(firstShow)")
      p.shown = (p.ver, s)
      p.lastShownVer = p.ver
      attachReady(i)
      if firstShow { paraPageSwapped(i); onPageShown?(i) }
    } else {
      attachReady(i)
    }
  }

  private func attachReady(_ i: Int) {
    let t0 = CACurrentMediaTime()
    defer { let ms = (CACurrentMediaTime() - t0) * 1000; if ms > 1 { trace(String(format: "attach p%d %.1f ms", i, ms)) } }
    let p = pages[i]
    let backing = window?.backingScaleFactor ?? 2
    for (k, img) in p.ready where k.ver == p.ver {
      let l = CALayer()
      l.anchorPoint = .zero
      l.contentsGravity = .resize
      l.contents = img.surface
      l.isOpaque = true
      var r = tileRect(i, k)
      // line tiles up with device pixels: the page's origin in pixels is rounded, so shift by the remainder
      let px = p.origin.x * k.scale, py = p.origin.y * k.scale
      r.origin.x += (px.rounded() - px) / k.scale
      r.origin.y += (py.rounded() - py) / k.scale
      l.frame = r
      l.contentsScale = backing
      p.layer.addSublayer(l)
      p.tiles[k] = l
    }
    p.ready = p.ready.filter { $0.key.ver == p.ver && p.tiles[$0.key] == nil }
  }

  // ---- SyncTeX ----------------------------------------------------------------------------------------------------

  private func doubleClick(_ pt: NSPoint) {
    guard let i = pages.firstIndex(where: { $0.rect.contains(pt) }) else { return }
    let p = pages[i]
    onDoubleClick?(i, pt.x - p.origin.x, pt.y - p.origin.y)
  }

  /// Scroll so (page, y) is a third of the way down the view (unless it is already in the middle) and mark a line.
  func reveal(page: Int, y: Double, h: Double) {
    guard page < pages.count else { return }
    let line = CGRect(x: 0, y: y, width: pages[page].size.width, height: h)
    reveal(page: page, rects: [line], lines: [])
  }

  /// The rects shown by the last `reveal` (page points), for benches: the word (or line) boxes and the line bands.
  public private(set) var revealed: (page: Int, rects: [CGRect])?
  public private(set) var revealedLines: [CGRect] = []
  /// How marks went, for tests and benches (one jump, one animation): appeared, glided, stayed.
  public var markCounts: (appear: Int, glide: Int, stay: Int) { forward.counts }
  /// The mark is dimmed to an underline (idle), or gone.
  public var markDimmed: Bool { forward.dimmed }
  public var markShown: Bool { forward.mark != nil }
  /// The editor's cursor on the PDF (nil: hidden).
  public var caret: Caret? { cursorDot.caret }
  public var caretDraws: Int { cursorDot.draws }
  /// The dot or a ring is on the page (CursorMap's caret, or our estimate).
  public var caretVisible: Bool { cursorDot.visible }
  func showCaret(_ c: Caret?) { cursorDot.show(c) }

  /// What ~10 s without a move does (for benches and screenshots).
  public func dimMarkNow() { forward.dim() }

  /// The cursor left the document (another file, a line SyncTeX doesn't have): no mark.
  public func clearMark() {
    forward.clear()
    revealed = nil
    revealedLines = []
  }

  /// Scroll so the rects (page points; a word, or one typeset line) are in view, a third of the way down unless they
  /// already sit in the middle, and mark them: a soft box around each and, for `lines` (the typeset lines they are
  /// on), a faint band over the whole line with a tick in the margin. The mark stays; the next one glides there.
  func reveal(page: Int, rects: [CGRect], lines: [CGRect] = []) {
    trace("mark: page \(page + 1) words \(rects.map { Int($0.minY) }) lines \(lines.map { Int($0.minY) })")
    let all = rects + lines
    guard page < pages.count, let first = all.first else { return }
    let p = pages[page]
    let u = all.dropFirst().reduce(first) { $0.union($1) }
    let target = p.origin.y + u.minY
    let b = scroll.contentView.bounds
    if target < b.minY + b.height * 0.15 || target + u.height > b.maxY - b.height * 0.15
      || p.origin.x + u.maxX < b.minX || p.origin.x + u.minX > b.maxX {
      let newY = target - b.height / 3
      var newX = b.minX
      if p.origin.x + u.minX < b.minX || p.origin.x + u.maxX > b.maxX { newX = p.origin.x + u.midX - b.width / 2 }
      NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = 0.25
        ctx.allowsImplicitAnimation = true
        scroll.contentView.animator().setBoundsOrigin(NSPoint(x: newX, y: newY))
      }
      scroll.reflectScrolledClipView(scroll.contentView)
    }
    revealed = (page, rects.isEmpty ? lines : rects)
    revealedLines = lines
    // the chosen colour (right-click menu; the system accent by default). On a dark page (a dark beamer theme, a black
    // box) a faint tint of it vanishes: there it is lightened and laid on thicker.
    let dark = (lines.first ?? rects.first).flatMap { luminance(page: page, in: $0) }.map { $0 < 0.35 } ?? false
    var accent = MarkColor.current.cgColor
    effectiveAppearance.performAsCurrentDrawingAppearance { accent = MarkColor.current.cgColor }
    if dark, let c = NSColor(cgColor: accent)?.blended(withFraction: 0.35, of: .white) { accent = c.cgColor }
    let plan = forward.show(page: page, words: rects, lines: lines, color: accent, tint: MarkColor.Tint(dark: dark))
    trace("mark: \(plan)")
  }

  /// The mean luminance (0…1) of a page's low-res underlay inside `r` (page points); nil before it has been drawn.
  func luminance(page: Int, in r: CGRect) -> Double? {
    guard page < pages.count, let surf = pages[page].under.contents as? IOSurface else { return nil }
    let p = pages[page]
    let k = Double(surf.width) / p.size.width
    let x0 = max(0, Int(r.minX * k)), x1 = min(surf.width, Int((r.maxX * k).rounded(.up)))
    let y0 = max(0, Int(r.minY * k)), y1 = min(surf.height, Int((r.maxY * k).rounded(.up)))
    guard x1 > x0, y1 > y0 else { return nil }
    surf.lock(options: .readOnly, seed: nil)
    defer { surf.unlock(options: .readOnly, seed: nil) }
    let base = surf.baseAddress.assumingMemoryBound(to: UInt8.self), row = surf.bytesPerRow
    var sum = 0.0, n = 0
    for y in y0..<y1 {
      for x in stride(from: x0, to: x1, by: 2) {
        let px = base + y * row + x * 4  // BGRA
        sum += 0.0722 * Double(px[0]) + 0.7152 * Double(px[1]) + 0.2126 * Double(px[2])
        n += 1
      }
    }
    return n == 0 ? nil : sum / Double(n) / 255
  }

  // ---- highlight colour -------------------------------------------------------------------------------------------

  func contextMenu() -> NSMenu {
    let menu = NSMenu()
    let item = NSMenuItem(title: "Highlight Colour", action: nil, keyEquivalent: "")
    let sub = NSMenu()
    let now = MarkColor.stored
    for (i, c) in MarkColor.presets.enumerated() {
      let it = NSMenuItem(title: c.name, action: #selector(pickPreset(_:)), keyEquivalent: "")
      it.target = self
      it.tag = i
      it.state = now == c.key ? .on : .off
      it.image = MarkColor.swatch(c.key == "accent" ? .controlAccentColor : MarkColor.color(hex: c.key) ?? .controlAccentColor)
      sub.addItem(it)
    }
    sub.addItem(.separator())
    let custom = NSMenuItem(title: "Custom…", action: #selector(pickCustom(_:)), keyEquivalent: "")
    custom.target = self
    custom.state = MarkColor.presets.contains { $0.key == now } ? .off : .on
    sub.addItem(custom)
    item.submenu = sub
    let show = NSMenuItem(title: "Show Comments on PDF", action: #selector(toggleComments(_:)), keyEquivalent: "k")
    show.keyEquivalentModifierMask = [.command, .shift]
    show.target = self
    show.state = notes.shown ? .on : .off
    menu.addItem(show)
    menu.addItem(item)
    return menu
  }

  @objc func toggleComments(_ sender: Any?) { notes.shown.toggle() }

  @objc private func pickPreset(_ it: NSMenuItem) {
    MarkColor.stored = MarkColor.presets[it.tag].key
    showAgain()
  }

  @objc private func pickCustom(_ it: NSMenuItem) {
    let panel = NSColorPanel.shared
    panel.showsAlpha = false
    panel.color = MarkColor.current
    panel.setTarget(self)
    panel.setAction(#selector(customChanged(_:)))
    panel.orderFront(nil)
  }

  @objc private func customChanged(_ panel: NSColorPanel) {
    MarkColor.stored = MarkColor.hex(panel.color)
    showAgain()
  }

  /// Shows the last mark again in the new colour, as a preview, if it is still in view.
  private func showAgain() {
    guard let r = revealed, r.page < pages.count else { return }
    let rect = pages[r.page].rect, view = scroll.contentView.bounds
    guard view.intersects(rect.offsetBy(dx: 0, dy: 0)) else { return }
    let words = revealedLines == r.rects ? [] : r.rects
    let lines = revealedLines
    forward.clear(animated: false)  // drawn again in the new colour
    reveal(page: r.page, rects: words, lines: lines)
  }

  // ---- comment notes, for benches and tests ----------------------------------------------------------------------

  /// The centre of a comment's note in the pages view, if it is placed.
  public func notePoint(_ id: String) -> NSPoint? {
    guard let n = notes.notes.first(where: { $0.id == id }), n.page < pages.count, let r = notes.rects[id] else { return nil }
    let p = pages[n.page]
    return NSPoint(x: p.origin.x + r.midX, y: p.origin.y + r.midY)
  }
  /// What a plain click / the mouse at a point of the pages view does (true: a note took the click).
  public func clickPages(at pt: NSPoint) -> Bool { pagesView.onClick?(pt) ?? false }
  public func hoverPages(at pt: NSPoint?) { pagesView.onHover?(pt) }
  /// The comment whose hover card is open.
  public var noteCardShown: String? { notes.popoverShown }
  /// The comment whose card is pinned open (a click on its note), and where the card is in this view.
  public var notePinned: String? { notes.pinned }
  public var pinnedCardFrame: NSRect? { notes.pinnedCard.flatMap { $0.isHidden ? nil : $0.frame } }
  /// A drag in the pages view → page points of the page it started on (the end clamped onto that page).
  private func drag(_ a: NSPoint, _ b: NSPoint, _ done: Bool) {
    guard let i = pages.firstIndex(where: { $0.rect.contains(a) }) else { return }
    let p = pages[i]
    let to = CGPoint(x: min(max(b.x - p.origin.x, 0), p.size.width), y: min(max(b.y - p.origin.y, 0), p.size.height))
    onSelect?(i, CGPoint(x: a.x - p.origin.x, y: a.y - p.origin.y), to, done)
  }
  /// A drag from one point of the pages view to another, as the mouse does it (for tests and benches).
  public func dragPages(from a: NSPoint, to b: NSPoint) {
    drag(a, NSPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), false)
    drag(a, b, true)
  }
  /// The selection on the pages: its page and rects (page points), the draft it maps to, and what's shown.
  public var selectionRects: [CGRect] { selection.rects }
  public var selectionDraft: PDFCommentDraft? { selection.draft }
  public var commentPillFrame: NSRect? { selection.pill.flatMap { $0.isHidden ? nil : $0.frame } }
  public var draftCardFrame: NSRect? { selection.card.flatMap { $0.isHidden ? nil : $0.frame } }
  public func clickCommentPill() { selection.openDraft() }
  /// Types into the open draft card (or the pinned card) and presses Return.
  public func sendCardForTest(_ text: String, pinned: Bool = false) {
    guard let c = pinned ? notes.pinnedCard : selection.card else { return }
    c.field.string = text
    c.grow()
    c.send()
  }
  public func resolvePinnedForTest() { notes.pinnedCard?.resolve() }

  /// A point of a page (points from its top-left) in the pages view.
  public func pagePoint(_ page: Int, _ p: CGPoint) -> NSPoint {
    guard page < pages.count else { return .zero }
    return NSPoint(x: pages[page].origin.x + p.x, y: pages[page].origin.y + p.y)
  }
  /// A point of the pages view (as `notePoint` gives) in this view's coordinates.
  public func toPane(_ p: NSPoint) -> NSPoint { pagesView.convert(p, to: self) }
  /// What Esc does to a pinned card.
  public func escapeForTest() { notes.escape() }
  /// Scroll so (page, y points from its top) is a third of the way down the view.
  public func scrollTo(page: Int, y: CGFloat) {
    guard page < pages.count else { return }
    let b = scroll.contentView.bounds
    scroll.contentView.setBoundsOrigin(NSPoint(x: b.minX, y: pages[page].origin.y + y - b.height / 3))
    scroll.reflectScrolledClipView(scroll.contentView)
  }

  // ---- for benches ------------------------------------------------------------------------------------------------

  public var magnification: CGFloat { scroll.magnification }
  /// Pages intersecting the view.
  public var pagesInView: [Int] {
    let view = scroll.contentView.bounds
    return pages.indices.filter { pages[$0].rect.intersects(view) }
  }
  /// The page sizes laid out now.
  public var pageSizes: [CGSize] { pages.map(\.size) }
  public var clipView: NSClipView { scroll.contentView }
  public var scrollView: NSScrollView { scroll }
  /// Simulates a pinch: no renders while it lasts, like a live magnify gesture.
  public func setLiveMagnify(_ on: Bool) {
    liveMagnify = on
    if on { fitWidth = false } else { queueRefresh() }
  }
  /// A page in view has changed and still shows its old tiles.
  public var swapPending: Bool {
    let view = scroll.contentView.bounds
    return pages.contains { $0.rect.intersects(view) && $0.shown != nil && $0.shown!.ver != $0.ver }
  }
  /// Tiles pending or in flight (0 = settled).
  public var pendingWork: Int { inflight + pages.reduce(0) { $0 + $1.ready.count } }
  public var tileCount: Int { pages.reduce(0) { $0 + $1.tiles.count } }
  public var pageCount: Int { pages.count }
  /// Whether every visible page shows sharp tiles at the current scale.
  public var settled: Bool {
    let view = scroll.contentView.bounds, s = pixelScale
    return inflight == 0 && pages.indices.filter { pages[$0].rect.intersects(view) }.allSatisfy { i in
      neededTiles(i, s, in: view).allSatisfy { pages[i].tiles[$0] != nil }
    }
  }
}
