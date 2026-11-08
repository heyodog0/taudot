// Review comments drawn on the pages: a small sticky note in the margin per comment, in its author's colour, and a
// faint tint with an underline over the quoted words. The layers live inside each page's layer, so they move and
// scale with the page every frame, like the tiles. Hover shows a card; a click reports the comment and pulses it.
import AppKit
import QuartzCore
import TaudotShared

@MainActor final class NotesOverlay {
  static let shownKey = "taudot.pdfShowComments"

  private unowned let view: PDFPaneView
  private(set) var notes: [PlacedNote] = []
  private(set) var comments: [String: PDFComment] = [:]
  private var layers: [String: (marker: CALayer, tints: [CALayer])] = [:]
  private var size: CGFloat = 0
  /// Each marker's rect on its page, laid out for `size`.
  private(set) var rects: [String: CGRect] = [:]
  /// The hover card: a view of the pane that hit-testing skips (HoverCardView, as History's), never an NSPopover,
  /// whose window took the mouse from the pages (they saw it leave, closed it, saw it come back: a flicker). It shows
  /// the comment as it is now (`set` refreshes it) and goes when the window stops being key.
  private var card: HoverCardView?
  private var popoverID: String?
  nonisolated(unsafe) private var resignObserver: Any?
  var onClick: ((String) -> Void)?
  /// The pinned card's Reply (Return) and Resolve.
  var onReply: ((String, String) -> Void)?
  var onResolve: ((String) -> Void)?
  var onShownChanged: ((Bool) -> Void)?

  init(view: PDFPaneView) {
    self.view = view
    resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) {
      [weak self] n in
      let w = n.object as? NSWindow
      let id = w.map(ObjectIdentifier.init)
      MainActor.assumeIsolated {
        guard let self, let win = self.view.window, id == ObjectIdentifier(win) else { return }
        self.closePopover()
      }
    }
    // posted on the main thread by `shown`'s setter; delivered at once (no queue)
    shownObserver = NotificationCenter.default.addObserver(forName: Self.shownChanged, object: nil, queue: nil) { [weak self] n in
      let from = (n.object as AnyObject?).map(ObjectIdentifier.init)
      MainActor.assumeIsolated {
        guard let self, from == ObjectIdentifier(self.defaults) else { return }
        self.applyShown()
      }
    }
    _ = applied
  }
  deinit {
    if let o = resignObserver { NotificationCenter.default.removeObserver(o) }
    if let o = shownObserver { NotificationCenter.default.removeObserver(o) }
  }

  /// Where the toggle is remembered (tests give their own).
  var defaults: UserDefaults = .standard { didSet { applied = shown } }
  /// Tests: each note's marker hidden or not.
  var markersHidden: [Bool] { notes.compactMap { layers[$0.id]?.marker.isHidden } }

  /// On by default; remembered, and the same in every window: a toggle in one is applied in all (each overlay
  /// draws, hides and hit-tests by the one setting, so no window keeps notes drawn but dead).
  var shown: Bool {
    get { defaults.object(forKey: Self.shownKey) as? Bool ?? true }
    set {
      guard newValue != shown else { return }
      defaults.set(newValue, forKey: Self.shownKey)
      NotificationCenter.default.post(name: Self.shownChanged, object: defaults)
      applyShown()
    }
  }
  static let shownChanged = Notification.Name("taudot.pdfShowCommentsChanged")
  /// The setting as this overlay last applied it.
  private lazy var applied: Bool = shown
  nonisolated(unsafe) private var shownObserver: Any?

  private func applyShown() {
    let on = shown
    for l in layers.values { for x in [l.marker] + l.tints { x.isHidden = !on } }
    guard on != applied else { return }
    applied = on
    if !on { closePopover(); unpin() }
    onShownChanged?(on)
  }

  /// Markers are this many page points: ~11 screen points at any zoom, never smaller than 9 page points.
  private var markerSize: CGFloat { min(40, max(9, 11 / max(view.scroll.magnification, 0.05))) }

  func set(_ notes: [PlacedNote], comments: [PDFComment]) {
    self.notes = notes
    self.comments = Dictionary(comments.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for l in layers.values { l.marker.removeFromSuperlayer(); l.tints.forEach { $0.removeFromSuperlayer() } }
    layers = [:]
    size = markerSize
    rects = layout()
    for n in notes where n.page < view.pages.count {
      let p = view.pages[n.page]
      let c = self.comments[n.id]
      let color = Self.color(c)
      let m = Self.markerLayer(color: color)
      m.frame = rects[n.id] ?? .zero
      Self.drawMarker(m, color: color)
      m.isHidden = !shown
      p.layer.addSublayer(m)
      var tints: [CALayer] = []
      for r in n.words {
        let t = Self.tintLayer(r, color: color)
        t.isHidden = !shown
        p.layer.addSublayer(t)
        tints.append(t)
      }
      layers[n.id] = (m, tints)
    }
    CATransaction.commit()
    if let id = popoverID {
      if layers[id] == nil { closePopover() } else if let n = notes.first(where: { $0.id == id }) {
        if hoverCardComment != self.comments[id] { showPopover(n) } else { placeCard() }
      }
    }
    if let id = pinned {
      if layers[id] == nil { unpin() } else {
        // its text may have changed (a reply): the card again
        // (not while a reply is being typed in it)
        if let c = self.comments[id], pinnedCard?.comment != c, pinnedCard?.field.string.isEmpty ?? true { pin(id) }
        else { reposition() }
      }
    }
  }

  /// After a zoom: markers keep their screen size.
  func rescale() {
    let s = markerSize
    guard abs(s - size) > 0.25 else { return }
    size = s
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    rects = layout()
    for n in notes where n.page < view.pages.count {
      guard let m = layers[n.id]?.marker else { continue }
      m.frame = rects[n.id] ?? .zero
      Self.drawMarker(m, color: Self.color(comments[n.id]))
    }
    CATransaction.commit()
    reposition()
  }

  /// The note under a point of the pages view, if comments are shown.
  func hit(_ pt: NSPoint) -> PlacedNote? {
    guard shown, let i = view.pages.firstIndex(where: { $0.rect.insetBy(dx: -40, dy: 0).contains(pt) }) else { return nil }
    let p = view.pages[i]
    let local = CGPoint(x: pt.x - p.origin.x, y: pt.y - p.origin.y)
    // the last drawn is on top
    return notes.last { $0.page == i && (rects[$0.id]?.insetBy(dx: -2, dy: -2).contains(local) ?? false) }
  }

  func hover(_ pt: NSPoint?) {
    guard let pt, let n = hit(pt) else {
      NSCursor.arrow.set()
      closePopover()
      return
    }
    NSCursor.pointingHand.set()
    // the pinned note already shows its card
    if n.id == pinned { closePopover() } else if popoverID != n.id { showPopover(n) }
  }

  /// A plain click on the pages: on a note, pins its card (or unpins it, if it was pinned) and reports it; anywhere
  /// else, unpins and lets the click through (false).
  func click(_ pt: NSPoint) -> Bool {
    guard let n = hit(pt) else {
      unpin()
      return false
    }
    closePopover()
    if pinned == n.id {
      unpin()
    } else {
      pin(n.id)
    }
    pulse(n.id)
    onClick?(n.id)
    return true
  }

  // ---- the pinned card --------------------------------------------------------------------------------------------

  /// The comment whose card is pinned open: one at a time, anchored beside its note in the pane (a subview, so it
  /// moves in the same frame as the pages when they scroll or zoom), until the note is clicked again, the PDF is
  /// clicked elsewhere, Esc is pressed, or the comment goes away.
  private(set) var pinned: String?
  private(set) var pinnedCard: PinnedCard?
  private var escMonitor: Any?

  func pin(_ id: String) {
    unpin()
    guard let c = comments[id], layers[id] != nil else { return }
    let card = PinnedCard(NoteCard(c, color: Self.color(c), thread: true), color: Self.color(c))
    card.onSend = { [weak self] text in self?.onReply?(id, text) }
    card.onResolve = { [weak self] in self?.onResolve?(id) }
    view.addSubview(card)
    pinned = id
    pinnedCard = card
    reposition()
    card.layoutSubtreeIfNeeded()
    card.content.scrollToNewest()
    // Esc closes it from anywhere in the window (focus is usually in Neovim after the jump), and still goes on to
    // whoever has focus: it isn't swallowed
    escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
      if e.keyCode == 53, let self, self.view.window != nil, e.window === self.view.window { self.unpin() }
      return e
    }
  }

  func unpin() {
    pinnedCard?.removeFromSuperview()
    pinnedCard = nil
    pinned = nil
    if let m = escMonitor { NSEvent.removeMonitor(m) }
    escMonitor = nil
  }

  /// Esc, as the monitor sees it (for tests).
  func escape() { if pinned != nil { unpin() } }

  /// Keeps the pinned card beside its note: after a scroll, a zoom, a resize, or the notes moving. Hidden while the
  /// note is out of view.
  func reposition() {
    placeCard()
    guard let id = pinned, let card = pinnedCard, let n = notes.first(where: { $0.id == id }), n.page < view.pages.count,
      let r = rects[id]
    else { return }
    let p = view.pages[n.page]
    let marker = view.pagesView.convert(r.offsetBy(dx: p.origin.x, dy: p.origin.y), to: view)
    let visible = view.convert(view.scroll.contentView.bounds, from: view.scroll.contentView)
    card.isHidden = !visible.intersects(marker) || !shown
    let size = card.fittingSize
    let gap: CGFloat = 8
    var x = n.side == .right ? marker.minX - gap - size.width : marker.maxX + gap
    // the pane's own coordinates are not flipped: y up
    var y = marker.midY - size.height + 22
    if x < view.bounds.minX + 4 || x + size.width > view.bounds.maxX - 4 {
      // no room beside the note (a narrow pane): under it, kept inside
      x = min(max(view.bounds.minX + 4, marker.midX - size.width / 2), view.bounds.maxX - size.width - 4)
      y = marker.minY - gap - size.height
    }
    y = min(max(y, view.bounds.minY + 4), view.bounds.maxY - size.height - 4)
    card.frame = NSRect(x: x, y: y, width: size.width, height: size.height).integral
  }

  func pulse(_ id: String) {
    guard let l = layers[id] else { return }
    let a = CAKeyframeAnimation(keyPath: "transform.scale")
    a.values = [1, 1.45, 1, 1.3, 1]
    a.keyTimes = [0, 0.25, 0.5, 0.75, 1]
    a.duration = 0.7
    l.marker.add(a, forKey: "pulse")
    for t in l.tints {
      let f = CABasicAnimation(keyPath: "backgroundColor")
      f.fromValue = (t.backgroundColor ?? .clear).copy(alpha: 0.35)
      f.toValue = t.backgroundColor
      f.duration = 0.9
      t.add(f, forKey: "pulse")
    }
  }

  private func layout() -> [String: CGRect] {
    let widths = view.pages.map(\.size.width)
    return NotePlacement.markers(notes, size: size, pageWidth: { $0 < widths.count ? widths[$0] : 612 })
  }

  // ---- popover ----------------------------------------------------------------------------------------------------

  /// For benches and screenshots too.
  func showPopover(_ n: PlacedNote) {
    closePopover()
    guard let c = comments[n.id], n.page < view.pages.count, view.window != nil else { return }
    let vc = NoteCard(c, color: Self.color(c))
    vc.view.layoutSubtreeIfNeeded()
    vc.view.setFrameSize(vc.view.fittingSize)
    let v = HoverCardView()
    v.show(vc)
    view.addSubview(v)
    card = v
    popoverID = n.id
    placeCard()
  }

  /// The hover card beside its note, toward the page (the pane's edge is near), else under it; inside the pane.
  private func placeCard() {
    guard let v = card, let id = popoverID, let n = notes.first(where: { $0.id == id }), n.page < view.pages.count,
      let r = rects[id]
    else { return }
    let p = view.pages[n.page]
    let marker = view.pagesView.convert(r.offsetBy(dx: p.origin.x, dy: p.origin.y), to: view)
    let size = v.frame.size, gap: CGFloat = 6
    var x = n.side == .right ? marker.minX - gap - size.width : marker.maxX + gap
    var y = marker.midY - size.height / 2
    if x < view.bounds.minX + 4 || x + size.width > view.bounds.maxX - 4 {
      x = min(max(view.bounds.minX + 4, marker.midX - size.width / 2), view.bounds.maxX - size.width - 4)
      y = marker.minY - gap - size.height
    }
    y = min(max(y, view.bounds.minY + 4), view.bounds.maxY - size.height - 4)
    v.frame.origin = NSPoint(x: x, y: y)
    v.frame = v.frame.integral
  }

  func closePopover() {
    card?.removeFromSuperview()
    card = nil
    popoverID = nil
  }

  var popoverShown: String? { popoverID }
  /// Tests: the comment the hover card shows, and whether it is a view of the pane (never a window of its own).
  var hoverCardComment: PDFComment? { card.flatMap { $0.content as? NoteCard }?.comment }
  var hoverCardInPane: Bool { card?.superview === view }

  // ---- drawing ----------------------------------------------------------------------------------------------------

  static func color(_ c: PDFComment?) -> NSColor {
    if let h = c?.color, let col = MarkColor.color(hex: h) { return col }
    // a stable hue from the author's name
    let name = c?.author ?? "?"
    var hash: UInt32 = 2166136261
    for b in name.utf8 { hash = (hash ^ UInt32(b)) &* 16777619 }
    return NSColor(calibratedHue: CGFloat(hash % 360) / 360, saturation: 0.6, brightness: 0.85, alpha: 1)
  }

  private static func markerLayer(color: NSColor) -> CAShapeLayer {
    let m = CAShapeLayer()
    m.zPosition = 6
    m.shadowColor = NSColor.black.cgColor
    m.shadowOpacity = 0.25
    m.shadowRadius = 1
    m.shadowOffset = CGSize(width: 0, height: 0.5)
    return m
  }

  /// A square note with its bottom-right corner folded, and two short lines of "writing".
  private static func drawMarker(_ m: CALayer, color: NSColor) {
    guard let m = m as? CAShapeLayer else { return }
    let s = m.bounds.width, f = s * 0.32, r = s * 0.12
    let body = CGMutablePath()
    body.move(to: CGPoint(x: r, y: 0))
    body.addLine(to: CGPoint(x: s - r, y: 0))
    body.addQuadCurve(to: CGPoint(x: s, y: r), control: CGPoint(x: s, y: 0))
    body.addLine(to: CGPoint(x: s, y: s - f))
    body.addLine(to: CGPoint(x: s - f, y: s))
    body.addLine(to: CGPoint(x: r, y: s))
    body.addQuadCurve(to: CGPoint(x: 0, y: s - r), control: CGPoint(x: 0, y: s))
    body.addLine(to: CGPoint(x: 0, y: r))
    body.addQuadCurve(to: CGPoint(x: r, y: 0), control: CGPoint(x: 0, y: 0))
    m.path = body
    m.fillColor = color.withAlphaComponent(0.92).cgColor
    m.shadowPath = body
    m.sublayers?.forEach { $0.removeFromSuperlayer() }
    let fold = CAShapeLayer()
    let fp = CGMutablePath()
    fp.move(to: CGPoint(x: s, y: s - f))
    fp.addLine(to: CGPoint(x: s - f, y: s - f))
    fp.addLine(to: CGPoint(x: s - f, y: s))
    fp.closeSubpath()
    fold.path = fp
    fold.fillColor = (color.blended(withFraction: 0.35, of: .black) ?? color).cgColor
    m.addSublayer(fold)
    let lines = CAShapeLayer()
    let lp = CGMutablePath()
    for (y, w) in [(0.32, 0.56), (0.52, 0.4)] {
      lp.move(to: CGPoint(x: s * 0.2, y: s * y))
      lp.addLine(to: CGPoint(x: s * (0.2 + w), y: s * y))
    }
    lines.path = lp
    lines.strokeColor = NSColor.white.withAlphaComponent(0.85).cgColor
    lines.lineWidth = max(0.6, s * 0.08)
    lines.lineCap = .round
    m.addSublayer(lines)
  }

  /// Lighter than the forward-search band (13%): an 8% tint and a hairline underline.
  private static func tintLayer(_ r: CGRect, color: NSColor) -> CALayer {
    let t = CALayer()
    t.zPosition = 5
    t.frame = r.insetBy(dx: -1, dy: -0.5)
    t.backgroundColor = color.withAlphaComponent(0.08).cgColor
    t.cornerRadius = 1.5
    let u = CALayer()
    u.frame = CGRect(x: 0, y: t.bounds.height - 0.9, width: t.bounds.width, height: 0.9)
    u.backgroundColor = color.withAlphaComponent(0.55).cgColor
    t.addSublayer(u)
    return t
  }
}

/// The hover card: author (in their colour), the first message, the reply count.
final class NoteCard: NSViewController {
  let comment: PDFComment
  private let color: NSColor
  private let quote: String
  /// The whole thread (a pinned card); else the first message and the reply count (a hover card).
  private let thread: Bool
  /// The thread's scroll view (a pinned card), scrolled to the newest reply.
  private(set) var scroll: NSScrollView?
  /// Shows the end of the thread: the newest reply.
  func scrollToNewest() {
    guard let sv = scroll, let doc = sv.documentView else { return }
    sv.layoutSubtreeIfNeeded()
    doc.scroll(NSPoint(x: 0, y: max(0, doc.bounds.height - sv.contentView.bounds.height)))
    sv.reflectScrolledClipView(sv.contentView)
  }
  static let width: CGFloat = 264
  /// Taller threads scroll.
  static let maxThread: CGFloat = 260

  init(_ c: PDFComment, color: NSColor, quote: String? = nil, thread: Bool = false) {
    comment = c
    self.color = color
    self.quote = quote ?? c.quote
    self.thread = thread
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError() }

  private static func dot(_ color: NSColor, _ size: CGFloat) -> NSView {
    let d = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
    d.wantsLayer = true
    d.layer?.backgroundColor = color.cgColor
    d.layer?.cornerRadius = size / 2
    d.widthAnchor.constraint(equalToConstant: size).isActive = true
    d.heightAnchor.constraint(equalToConstant: size).isActive = true
    return d
  }

  /// "Name  2 days ago": the name in the label colour, the time smaller and secondary.
  private static func head(_ name: String, _ time: Date?, color: NSColor) -> NSView {
    let l = NSTextField(labelWithString: "")
    let s = NSMutableAttributedString(string: name, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor])
    let t = PDFComment.ago(time)
    if !t.isEmpty { s.append(NSAttributedString(string: "  " + t, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])) }
    l.attributedStringValue = s
    l.lineBreakMode = .byTruncatingTail
    let h = NSStackView(views: [dot(color, 8), l])
    h.spacing = 6
    return h
  }

  private static func text(_ t: String, lines: Int) -> NSTextField {
    let m = NSTextField(wrappingLabelWithString: t)
    m.font = .systemFont(ofSize: 12)
    m.maximumNumberOfLines = lines
    m.preferredMaxLayoutWidth = 240
    m.lineBreakMode = .byWordWrapping
    m.cell?.truncatesLastVisibleLine = true
    m.isSelectable = true
    m.widthAnchor.constraint(equalToConstant: 240).isActive = true
    m.setContentCompressionResistancePriority(.required, for: .vertical)
    return m
  }

  private func msgColor(_ m: PDFCommentMessage) -> NSColor {
    m.color.flatMap { MarkColor.color(hex: $0) } ?? NotesOverlay.color(PDFComment(id: "", path: "", line: 0, author: m.author))
  }

  override func loadView() {
    let first = comment.messages.first
    var rows: [NSView] = [Self.head(comment.author, first?.time, color: color)]
    if !quote.isEmpty {
      let q = NSTextField(labelWithString: "“" + quote + "”")
      q.font = .systemFont(ofSize: 11)
      q.textColor = .secondaryLabelColor
      q.lineBreakMode = .byWordWrapping
      q.cell?.truncatesLastVisibleLine = true
      q.maximumNumberOfLines = 3
      q.preferredMaxLayoutWidth = 240
      q.widthAnchor.constraint(equalToConstant: 240).isActive = true
      rows.append(q)
    }
    let stack: NSStackView
    if thread {
      // the comment and every reply, in a scroll view when it's long
      var msgs: [NSView] = []
      if !comment.firstMessage.isEmpty { msgs.append(Self.text(comment.firstMessage, lines: 0)) }
      for m in comment.messages.dropFirst() {
        let row = NSStackView(views: [Self.head(m.author, m.time, color: msgColor(m)), Self.text(m.text, lines: 0)])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 2
        msgs.append(row)
      }
      let list = NSStackView(views: msgs)
      list.orientation = .vertical
      list.alignment = .leading
      list.spacing = 10
      let doc = FlippedView()
      list.translatesAutoresizingMaskIntoConstraints = false
      doc.addSubview(list)
      NSLayoutConstraint.activate([
        list.leadingAnchor.constraint(equalTo: doc.leadingAnchor), list.topAnchor.constraint(equalTo: doc.topAnchor),
        list.widthAnchor.constraint(equalToConstant: 240),
      ])
      let h = ceil(list.fittingSize.height)
      doc.frame = NSRect(x: 0, y: 0, width: 240, height: h)
      let sv = NSScrollView()
      sv.drawsBackground = false
      sv.hasVerticalScroller = h > Self.maxThread
      sv.autohidesScrollers = true
      sv.scrollerStyle = .overlay
      sv.documentView = doc
      sv.translatesAutoresizingMaskIntoConstraints = false
      sv.widthAnchor.constraint(equalToConstant: 240).isActive = true
      sv.heightAnchor.constraint(equalToConstant: min(h, Self.maxThread)).isActive = true
      scroll = sv
      rows.append(sv)
      stack = NSStackView(views: rows)
    } else {
      if !comment.firstMessage.isEmpty { rows.append(Self.text(comment.firstMessage, lines: 6)) }
      if comment.replies > 0 {
        let r = NSTextField(labelWithString: comment.replies == 1 ? "1 reply" : "\(comment.replies) replies")
        r.font = .systemFont(ofSize: 11, weight: .medium)
        r.textColor = .secondaryLabelColor
        rows.append(r)
      }
      stack = NSStackView(views: rows)
    }
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 6
    stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
    // a fixed width, so messages wrap instead of the card shrinking to their first words
    stack.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
    view = stack
  }
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }

/// A note's card pinned open on the PDF, or a new comment's draft: a popover-like panel with a bar in the author's
/// colour, its content, and a text field (Return sends) with, for a pinned comment, Resolve.
final class PinnedCard: NSView {
  let comment: PDFComment
  let content: NoteCard
  /// The reply field, the margin's own (wraps, grows by lines, ↩ sends, ⇧↩/⌥↩ new line).
  let field = ReplyTextView()
  private let fieldBox = ReplyBox()
  private var fieldHeight: NSLayoutConstraint!
  private(set) var resolveButton: NSButton?
  var onSend: ((String) -> Void)?
  var onResolve: (() -> Void)?

  /// `resolvable`: a comment's card (Reply + Resolve); else a draft (just the field).
  init(_ card: NoteCard, color: NSColor, placeholder: String = "Reply", resolvable: Bool = true) {
    comment = card.comment
    content = card
    super.init(frame: .zero)
    wantsLayer = true
    layer?.shadowColor = NSColor.black.cgColor
    layer?.shadowOpacity = 0.28
    layer?.shadowRadius = 8
    layer?.shadowOffset = CGSize(width: 0, height: -2)
    let fx = NSVisualEffectView()
    fx.material = .popover
    fx.state = .active
    fx.blendingMode = .withinWindow
    fx.wantsLayer = true
    fx.layer?.cornerRadius = 9
    fx.layer?.masksToBounds = true
    fx.layer?.borderWidth = 0.5
    fx.layer?.borderColor = NSColor.separatorColor.cgColor
    fx.translatesAutoresizingMaskIntoConstraints = false
    addSubview(fx)
    let bar = NSView()
    bar.wantsLayer = true
    bar.layer?.backgroundColor = color.cgColor
    bar.translatesAutoresizingMaskIntoConstraints = false
    fx.addSubview(bar)
    let v = card.view
    v.translatesAutoresizingMaskIntoConstraints = false
    fx.addSubview(v)
    field.placeholder = placeholder
    field.font = .systemFont(ofSize: 12)
    field.isRichText = false
    field.allowsUndo = true
    field.drawsBackground = false
    field.textContainerInset = NSSize(width: 3, height: 7)
    field.textContainer?.widthTracksTextView = true
    field.isVerticallyResizable = false
    field.isHorizontallyResizable = false
    field.centreText()
    field.setAccessibilityLabel(placeholder)
    field.onSend = { [weak self] in self?.send() }
    field.onResize = { [weak self] in self?.grow() }
    fieldBox.wantsLayer = true
    fieldBox.layer?.cornerRadius = 7
    fieldBox.layer?.borderWidth = 1
    fieldBox.layer?.borderColor = NSColor.separatorColor.cgColor
    fieldBox.layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.6).cgColor
    fieldBox.addSubview(field)
    fieldBox.translatesAutoresizingMaskIntoConstraints = false
    fieldHeight = fieldBox.heightAnchor.constraint(equalToConstant: ReplyTextView.minHeight)
    let hint = NSTextField(labelWithString: "↩ send · ⇧↩ new line")
    hint.font = .systemFont(ofSize: 10.5)
    hint.textColor = .tertiaryLabelColor
    var foot: [NSView] = [fieldBox, hint]
    if resolvable {
      let b = NSButton(title: "Resolve", image: NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: nil)!,
        target: self, action: #selector(resolve))
      b.bezelStyle = .rounded
      b.controlSize = .small
      b.imagePosition = .imageLeading
      b.contentTintColor = .systemBlue
      b.setAccessibilityLabel("Resolve")
      resolveButton = b
      foot.append(b)
    }
    // the field full width, the hint under it, then Resolve on its own row
    let footer = NSStackView(views: foot)
    footer.orientation = .vertical
    footer.alignment = .leading
    footer.spacing = 5
    footer.setCustomSpacing(8, after: hint)
    footer.translatesAutoresizingMaskIntoConstraints = false
    fx.addSubview(footer)
    NSLayoutConstraint.activate([
      fx.leadingAnchor.constraint(equalTo: leadingAnchor), fx.trailingAnchor.constraint(equalTo: trailingAnchor),
      fx.topAnchor.constraint(equalTo: topAnchor), fx.bottomAnchor.constraint(equalTo: bottomAnchor),
      bar.leadingAnchor.constraint(equalTo: fx.leadingAnchor), bar.topAnchor.constraint(equalTo: fx.topAnchor),
      bar.bottomAnchor.constraint(equalTo: fx.bottomAnchor), bar.widthAnchor.constraint(equalToConstant: 3),
      v.leadingAnchor.constraint(equalTo: bar.trailingAnchor), v.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
      v.topAnchor.constraint(equalTo: fx.topAnchor),
      footer.topAnchor.constraint(equalTo: v.bottomAnchor, constant: -2),
      footer.leadingAnchor.constraint(equalTo: bar.trailingAnchor, constant: 12),
      footer.trailingAnchor.constraint(equalTo: fx.trailingAnchor, constant: -12),
      footer.bottomAnchor.constraint(equalTo: fx.bottomAnchor, constant: -10),
      fieldBox.widthAnchor.constraint(equalTo: footer.widthAnchor),
      fieldHeight,
    ])
  }
  required init?(coder: NSCoder) { fatalError() }
  /// Clicks on the card stay on it (they don't reach the pages and unpin it).
  override func mouseDown(with e: NSEvent) {}

  @objc func send() {
    let text = field.string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    onSend?(text)
    field.string = ""
    grow()
  }
  @objc func resolve() { onResolve?() }

  /// The field grew or shrank with its text: the box takes the text's height, and the card follows with its top
  /// edge staying put (it grows downward).
  func grow() {
    fieldBox.layoutSubtreeIfNeeded()
    fieldHeight.constant = max(ReplyTextView.minHeight, ceil(field.contentHeight))
    layoutSubtreeIfNeeded()
    let h = fittingSize.height
    guard frame.height > 0, abs(h - frame.height) > 0.5 else { return }
    var f = frame
    if !(superview?.isFlipped ?? false) { f.origin.y -= h - f.height }
    f.size.height = h
    frame = f.integral
  }
}
