// While the margin is hidden: the cards of the threads under the cursor, floating over the editor next to their text.
import AppKit

/// Holds the floating card (and its switcher).
final class FloatStack: NSView {
  override var isFlipped: Bool { true }
}

/// "‹ 1 of 2 comments ›": several threads at one place show one card at a time.
final class FloatSwitcher: NSView {
  let label = NSTextField(labelWithString: "")
  let prev = NSButton(title: "", target: nil, action: nil), next = NSButton(title: "", target: nil, action: nil)
  var onStep: ((Int) -> Void)?
  static let height: CGFloat = 24
  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerRadius = 8
    label.font = .systemFont(ofSize: 11, weight: .medium)
    label.textColor = .secondaryLabelColor
    label.alignment = .center
    for (b, sym, d) in [(prev, "chevron.left", -1), (next, "chevron.right", 1)] {
      b.isBordered = false
      b.image = NSImage(systemSymbolName: sym, accessibilityDescription: d < 0 ? "Previous comment here" : "Next comment here")
      b.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
      b.contentTintColor = .secondaryLabelColor
      let h = ButtonHandler { [weak self] in self?.onStep?(d) }
      b.target = h
      b.action = #selector(ButtonHandler.fire)
      objc_setAssociatedObject(b, &ButtonHandler.key, h, .OBJC_ASSOCIATION_RETAIN)
      addSubview(b)
    }
    addSubview(label)
  }
  required init?(coder: NSCoder) { fatalError() }
  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }
  override func updateLayer() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      layer?.backgroundColor = (dark ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 1, alpha: 1)).cgColor
      layer?.borderWidth = 0.5
      layer?.borderColor = NSColor.separatorColor.cgColor
    }
  }
  func show(_ i: Int, of n: Int) { label.stringValue = "\(i + 1) of \(n) comments here" }
  override func layout() {
    super.layout()
    prev.frame = NSRect(x: 4, y: 2, width: 20, height: 20)
    next.frame = NSRect(x: bounds.width - 24, y: 2, width: 20, height: 20)
    let h = label.fittingSize.height
    label.frame = NSRect(x: 26, y: (bounds.height - h) / 2, width: bounds.width - 52, height: h)
  }
}

@MainActor final class FloatingCards {
  unowned let margin: ReviewMarginView
  let stack = FloatStack()
  /// Shown or fading out, newest first.
  private(set) var order: [ReviewItem] = []
  private(set) var cards: [String: ReviewCardView] = [:]
  private var heights: [String: CGFloat] = [:]
  /// Below the text (true) or above it: chosen when the cards appear or their threads change, kept while scrolling;
  /// once a scroll has settled, it flips if its side has no room and the other has.
  private(set) var below = true
  private var sideKey: [String] = []
  /// The text moved (a scroll) at this time; while it keeps moving, nothing but the cards' position changes: no
  /// leaving (the scroll drags Neovim's cursor out of the range), no new set, no side flip. `settle` runs after.
  private var lastScroll: CFTimeInterval = -1
  private var lastAnchor: CGFloat?
  private var settleTimer: Timer?
  var settleDelay: TimeInterval = 0.25
  var now: () -> CFTimeInterval = CACurrentMediaTime
  var scrolling: Bool { lastScroll >= 0 && now() - lastScroll < settleDelay }
  /// TAUDOT_MARGIN_TRACE_FLOAT=<file>: a line per event (show, leave, flip, hidden off screen, held while scrolling).
  static let traceFile: FileHandle? = {
    guard let p = ProcessInfo.processInfo.environment["TAUDOT_MARGIN_TRACE_FLOAT"] else { return nil }
    FileManager.default.createFile(atPath: p, contents: nil)
    return FileHandle(forWritingAtPath: p)
  }()
  static func trace(_ s: String) {
    traceFile?.write(String(format: "%.4f %@\n", CACurrentMediaTime(), s).data(using: .utf8)!)
  }
  private var leaveTimer: Timer?
  /// A comment just sent from the floating draft: it stays until the cursor moves elsewhere.
  var pinned: String?
  private var lastX: CGFloat?
  /// Cards shown (or appearing); fadingOut: going.
  private var active = false
  private var fadingOut = false
  /// Fade in and out (s); how long the cursor must have left before the cards go (typing never flickers them).
  var fade: TimeInterval = 0.12
  var leaveDelay: TimeInterval = 0.15

  static let maxWidth: CGFloat = 320
  static let gap: CGFloat = 6
  static let space: CGFloat = 6  // from the text

  /// All the threads here (newest first) and the one shown.
  private(set) var here: [ReviewItem] = []
  private(set) var page = 0
  let switcher = FloatSwitcher(frame: .zero)
  var pageCount: Int { here.count }
  /// The thread a jump landed on: shown first once the cursor gets there.
  private var wantedFirst: String?
  func show(_ id: String) {
    if let i = here.firstIndex(where: { $0.id == id }), i != page { page = i; set([here[page]]); place() } else { wantedFirst = id }
  }

  /// Show the next (1) or previous (-1) thread at this place.
  func step(_ d: Int) {
    guard here.count > 1 else { return }
    page = (page + d + here.count) % here.count
    set([here[page]])
    place()
  }

  init(margin: ReviewMarginView) {
    self.margin = margin
    switcher.isHidden = true
    switcher.onStep = { [weak self] d in self?.step(d) }
    stack.addSubview(switcher)
    stack.wantsLayer = true
    stack.isHidden = true
    stack.alphaValue = 0
    stack.setAccessibilityIdentifier("taudot-floating-comments")
  }

  var isShowing: Bool { active && !order.isEmpty }
  var shownIDs: [String] { isShowing ? order.map(\.id) : [] }
  func card(_ id: String) -> ReviewCardView? { cards[id] }

  /// The items to float now: the margin hidden, the cursor in the shown buffer and in their ranges, no selection
  /// being made (the Comment pill's place). Newest first.
  private func wanted() -> [ReviewItem] {
    let m = margin
    guard m.paneHidden else { return [] }
    // A new comment being written: its draft alone, at the selection.
    if let d = m.draftItem { return [d] }
    guard m.floatingEnabled && !m.inlineHidden else { return [] }
    guard m.cursor.buf == m.state.buf else { return [] }
    if let p = pinned, let it = m.state.items.first(where: { $0.id == p }) { return [it] }
    guard m.cursor.visual == nil else { return [] }
    let here = Set(m.cursor.here)
    return m.state.items
      .filter { here.contains($0.id) && (m.showResolved || !$0.resolved) && m.kinds.shows($0.kind) }
      .sorted { ($0.ts ?? .distantPast, $0.id) > ($1.ts ?? .distantPast, $1.id) }
  }

  /// A card the user is writing in keeps floating wherever the cursor goes.
  private func busy(_ c: ReviewCardView) -> Bool {
    guard let r = c.reply else { return false }
    return !r.string.isEmpty || (r.window != nil && r.window?.firstResponder === r)
  }

  /// The cursor, the state or the margin's visibility changed.
  func update() {
    if active && scrolling {
      // Re-evaluated once the scroll settles.
      Self.trace("held while scrolling")
      return
    }
    var want = wanted()
    for it in order where !want.contains(where: { $0.id == it.id }) {
      if let c = cards[it.id], busy(c), let now = margin.state.items.first(where: { $0.id == it.id }) { want.append(now) }
    }
    if want.isEmpty {
      if !order.isEmpty && leaveTimer == nil && !fadingOut {
        let t = Timer(timeInterval: leaveDelay, repeats: false) { [weak self] _ in
          MainActor.assumeIsolated { self?.leave() }
        }
        RunLoop.main.add(t, forMode: .common)
        leaveTimer = t
      }
      return
    }
    leaveTimer?.invalidate()
    leaveTimer = nil
    let appearing = !active
    // Several threads at one place: one card and a switcher, not a stack over the text. The one shown stays shown
    // while it is still here (and a card being written in always is).
    let keep = wantedFirst ?? order.first.map(\.id)
    wantedFirst = nil
    here = want
    if let k = keep, let i = want.firstIndex(where: { $0.id == k }) {
      page = i
    } else if let inner = want.indices.max(by: { a, b in
      // (several threads here and none shown yet: the innermost, starting last, then ending first)
      let x = want[a].range, y = want[b].range
      if (x.line, x.col) != (y.line, y.col) { return (x.line, x.col) < (y.line, y.col) }
      return (x.endLine, x.endCol) > (y.endLine, y.endCol)
    }) {
      page = inner
    } else {
      page = 0
    }
    if let b = want.firstIndex(where: { w in cards[w.id].map(busy) ?? false }) { page = b }
    want = [want[page]]
    set(want)
    if appearing {
      Self.trace("show \(want.map(\.id))")
      sideKey = []
      active = true
      fadingOut = false
      place()
      NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = fade
        stack.animator().alphaValue = 1
      }
    } else {
      place()
    }
  }

  private func leave() {
    leaveTimer = nil
    guard active else { return }
    Self.trace("leave")
    active = false
    fadingOut = true
    NSAnimationContext.runAnimationGroup({ ctx in
      ctx.duration = fade
      stack.animator().alphaValue = 0
    }, completionHandler: { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.fadingOut else { return }
        self.fadingOut = false
        self.stack.isHidden = true
        self.set([])
      }
    })
  }

  /// Hide at once (the margin came back).
  func dismiss() {
    leaveTimer?.invalidate()
    leaveTimer = nil
    active = false
    fadingOut = false
    stack.isHidden = true
    stack.alphaValue = 0
    set([])
  }

  private func set(_ items: [ReviewItem]) {
    if items.map(\.id) != order.map(\.id) { lastAnchor = nil }
    let ids = Set(items.map(\.id))
    for (id, c) in cards where !ids.contains(id) {
      c.removeFromSuperview()
      cards[id] = nil
      heights[id] = nil
    }
    for it in items {
      if let c = cards[it.id] {
        let old = c.item
        c.update(it)
        if old != it { heights[it.id] = nil }
      } else {
        let c = ReviewCardView(item: it)
        c.isDraft = it.id == "draft"
        c.expanded = true
        c.isSelected = true
        c.solid = true
        let id = it.id
        c.onSelect = { [weak c] in c?.focusReply() }
        c.onAction = { [weak self] a in self?.margin.perform(a) }
        c.onResize = { [weak self] in
          self?.heights[id] = nil
          self?.place()
        }
        c.onCancel = { [weak self, weak c] typed in
          guard let self, let c else { return }
          let done = { [weak self, weak c] in
            c?.giveUp()
            self?.margin.focusEditor()
            self?.update()
          }
          if typed {
            self.margin.ask(c.isDraft ? "Discard this comment?" : "Discard this reply?", info: "What you typed is lost.", button: "Discard") { ok in if ok { done() } }
          } else {
            done()
          }
        }
        stack.addSubview(c)
        cards[id] = c
      }
      cards[it.id]?.canReply = margin.state.supported
    }
    order = items
  }

  /// A reply went through: clear its field.
  func replied(_ id: String) {
    cards[id]?.clearReply()
    cards[id]?.error = nil
  }
  func failed(_ id: String, _ message: String) -> Bool {
    guard let c = cards[id] else { return false }
    c.error = message
    heights[id] = nil
    place()
    return true
  }

  // ---- placement ------------------------------------------------------------------------------------------------

  /// Where the stack goes, in the editor view's coordinates (flipped or not, as the editor is). nil: off screen.
  func frame() -> NSRect? {
    let m = margin
    guard !order.isEmpty, let ed = m.editor, let g = m.geometry else { return nil }
    let lh = g.lineHeight
    let H = ed.bounds.height
    let w = min(Self.maxWidth, ed.bounds.width - 16)
    guard w > 80 else { return nil }
    for it in order where heights[it.id] == nil { heights[it.id] = cards[it.id]?.height(for: w) ?? 60 }
    let sw = here.count > 1 && !(order.first?.id == "draft") ? FloatSwitcher.height + Self.gap : 0
    let h = order.reduce(0) { $0 + (heights[$1.id] ?? 0) } + CGFloat(order.count - 1) * Self.gap + sw
    let at = m.cursor.at
    func row(_ line: Int, _ wrap: Int?) -> CGFloat? { g.y(ofLine: line).map { $0 + CGFloat(wrap ?? 0) * lh } }
    // The text to keep clear: every range, and the cursor's row.
    var top = CGFloat.infinity, bottom = -CGFloat.infinity
    let draftEnd = order[0].id == "draft" ? m.draftEnd : nil
    for it in order {
      let a = at?.items[it.id]
      if let y = row(it.range.line, a?.startWrap) { top = min(top, y) }
      if let y = row(it.range.endLine, a?.endWrap ?? draftEnd?.wrap) { bottom = max(bottom, y + lh) }
    }
    // (Only the text: the cursor is inside these ranges, and its row comes from an async payload that a fast scroll
    // outruns; the ranges' rows within their lines don't change while scrolling.)
    guard top.isFinite, bottom.isFinite else { return nil }
    let key = order.map(\.id)
    let fitsBelow = bottom + Self.space + h <= H - 4
    let fitsAbove = top - Self.space - h >= 4
    if key != sideKey {
      sideKey = key
      below = fitsBelow || !fitsAbove && (H - bottom >= top)
    } else if flipIfCramped, below ? (!fitsBelow && fitsAbove) : (!fitsAbove && fitsBelow) {
      // At rest where its side has no room and the other has: flip (never mid-scroll).
      Self.trace("flip to \(below ? "above" : "below")")
      below.toggle()
    }
    let y = below ? bottom + Self.space : top - Self.space - h
    guard y + h > 0, y < H else { return nil }
    // Left-aligned with the start of the newest range (its card's left edge a little before the text).
    let cell = ed.bounds.width / CGFloat(max(1, at?.columns ?? draftEnd?.columns ?? 80))
    // (the draft: where the Comment pill was, under the selection's end)
    var x: CGFloat
    let first = order[0]
    func clamp(_ v: CGFloat) -> CGFloat { min(max(8, v), ed.bounds.width - w - 8) }
    if active && scrolling && key == sideKey, let l = lastX {
      // While scrolling: where it was (the range's start may scroll out of view; nothing snaps to the edge).
      x = l
    } else if let c = draftEnd?.screenCol ?? at?.items[first.id]?.startCol {
      // (the editor's drawn column when it knows it: the same x as from the start column below)
      x = clamp((g.x(ofColumn: c) ?? CGFloat(c) * cell) - 12)
    } else if let c = (first.members.first ?? first).startCol ?? first.startCol,
              let px = g.x(ofColumn: m.state.textoff + c) {
      // The range's start column (gui.lua knows it off screen too), at the editor's drawn x.
      x = clamp(px - 12)
    } else if let l = lastX {
      x = l  // the comment just sent, before its column is known: where its draft was
    } else {
      x = 8
    }
    lastX = x
    return NSRect(x: x, y: ed.isFlipped ? y : H - y - h, width: w, height: h)
  }

  private var flipIfCramped = false

  /// The editor drew a new frame: if the cards' text moved, it's a scroll (a text edit comes with an update too).
  func geometryChanged() {
    guard active, let g = margin.geometry, let first = order.first else { return }
    let y = g.y(ofLine: first.range.line)
    defer { lastAnchor = y }
    guard let y, let a = lastAnchor, abs(y - a) > 0.01 else { return }
    lastScroll = now()
    settleTimer?.invalidate()
    let t = Timer(timeInterval: settleDelay, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.settle() } }
    RunLoop.main.add(t, forMode: .common)
    settleTimer = t
  }

  /// The scroll has been still for `settleDelay`: what was held happens now (the cursor's threads, the side).
  func settle() {
    settleTimer = nil
    lastScroll = -1
    guard active else { return }
    flipIfCramped = true
    place()
    flipIfCramped = false
    update()
  }

  /// Every geometry change (each frame of a scroll) and every update: frames only.
  func place() {
    guard active || fadingOut, let ed = margin.editor, let host = ed.superview else { return }
    // Scrolled out of the editor: hidden until it comes back.
    guard let f = frame() else {
      if !stack.isHidden { stack.isHidden = true; Self.trace("hidden: off screen") }
      return
    }
    if stack.isHidden { stack.isHidden = false }
    if stack.superview !== host { host.addSubview(stack, positioned: .above, relativeTo: ed) }
    let r = host.convert(f, from: ed)
    if stack.frame.minX != r.minX { Self.trace(String(format: "x %.1f", f.minX)) }
    if stack.frame != r { stack.frame = r }
    var y: CGFloat = 0
    let showSwitch = here.count > 1 && order.first?.id != "draft"
    switcher.isHidden = !showSwitch
    if showSwitch {
      switcher.show(page, of: here.count)
      let sf = NSRect(x: 0, y: 0, width: r.width, height: FloatSwitcher.height)
      if switcher.frame != sf { switcher.frame = sf }
      y = FloatSwitcher.height + Self.gap
    }
    for it in order {
      guard let c = cards[it.id] else { continue }
      let cf = NSRect(x: 0, y: y, width: r.width, height: heights[it.id] ?? 60)
      if c.frame != cf { c.frame = cf }
      y += cf.height + Self.gap
    }
  }
}
