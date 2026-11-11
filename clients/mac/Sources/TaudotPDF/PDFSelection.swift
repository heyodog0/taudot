// Commenting from the PDF: drag over words to select them, a Comment pill appears under the selection, and its draft
// card (Return sends) becomes a new comment on the source range the words came from (inverse word matching).
//
// While dragging, the selection follows SyncTeX's typeset lines (instant); when the mouse comes up it snaps to the
// words read off the page, and each end is matched back to a source word, as a double-click is.
import AppKit
import QuartzCore

/// A new comment's place in the source, from a selection on the PDF: 1-based lines, UTF-8 byte columns (Neovim's),
/// the end exclusive — as `PDFComment`.
public struct PDFCommentDraft: Sendable, Equatable {
  public var path: String
  public var line: Int
  public var column: Int
  public var endLine: Int
  public var endColumn: Int
  /// The source text selected, its whitespace collapsed.
  public var quote: String
  public init(path: String, line: Int, column: Int, endLine: Int, endColumn: Int, quote: String) {
    self.path = path; self.line = line; self.column = column; self.endLine = endLine; self.endColumn = endColumn
    self.quote = quote
  }
}

public enum SelectionGeometry {
  /// The two ends of a drag in reading order: by line (`rows`, top to bottom), then by x on one line.
  public static func ordered(_ a: CGPoint, _ b: CGPoint, rows: [CGRect]) -> (CGPoint, CGPoint) {
    let ra = rowIndex(a, rows), rb = rowIndex(b, rows)
    if let ra, let rb, ra != rb { return ra < rb ? (a, b) : (b, a) }
    if ra == nil || rb == nil, abs(a.y - b.y) > 4 { return a.y < b.y ? (a, b) : (b, a) }
    return a.x <= b.x ? (a, b) : (b, a)
  }

  /// The typeset line holding a point (vertically), nearest if between two.
  public static func rowIndex(_ p: CGPoint, _ rows: [CGRect]) -> Int? {
    if let i = rows.firstIndex(where: { $0.minY - 1 <= p.y && p.y <= $0.maxY + 1 }) { return i }
    return rows.indices.min { abs(rows[$0].midY - p.y) < abs(rows[$1].midY - p.y) }
  }

  /// While dragging: from the start point to the end of its line, whole lines between, the last line's start to the
  /// end point. `rows` top to bottom; the ends in reading order.
  public static func provisional(rows: [CGRect], start: CGPoint, end: CGPoint) -> [CGRect] {
    guard let a = rowIndex(start, rows), let b = rowIndex(end, rows), a <= b else { return [] }
    var out: [CGRect] = []
    for i in a...b {
      let r = rows[i]
      let x0 = i == a ? min(max(start.x, r.minX), r.maxX) : r.minX
      let x1 = i == b ? max(min(end.x, r.maxX), r.minX) : r.maxX
      if x1 > x0 + 0.5 { out.append(CGRect(x: x0, y: r.minY, width: x1 - x0, height: r.height)) }
    }
    return out
  }

  /// When the mouse comes up: the words selected (indices into `words`, in reading order), from the first word that
  /// ends after the start point on its line to the last that begins before the end point on its line.
  public static func pick(words: [WordMatch.PageWord], rows: [CGRect], start: CGPoint, end: CGPoint) -> (from: Int, to: Int)? {
    guard let a = rowIndex(start, rows), let b = rowIndex(end, rows), a <= b else { return nil }
    func row(_ r: CGRect) -> Int? { rowIndex(CGPoint(x: r.midX, y: r.midY), rows) }
    var from: Int?, to: Int?
    for (i, w) in words.enumerated() {
      // a word hyphenated over a line break: its first half on one line, its second on the next
      guard let first = w.rects.first, let last = w.rects.last, let rf = row(first), let rl = row(last) else { continue }
      if from == nil, rf > a || (rf == a && first.maxX > start.x) { from = i }
      if rl < b || (rl == b && last.minX < end.x) { to = i }
    }
    guard let f = from, let t = to, f <= t else { return nil }
    return (f, t)
  }
}

/// What's drawn for a selection: the highlight inside the page's layer (so it moves with the page), and the pill and
/// draft card as subviews of the pane, kept beside the selection's end when the pages scroll or zoom.
@MainActor final class SelectionOverlay {
  private unowned let view: PDFPaneView
  private var layers: [CALayer] = []
  private(set) var page: Int?
  private(set) var rects: [CGRect] = []
  private(set) var draft: PDFCommentDraft?
  private(set) var pill: SelectionPill?
  private(set) var card: PinnedCard?
  private var escMonitor: Any?
  var onSend: ((PDFCommentDraft, String) -> Void)?
  /// Bumped by every `clear` (Esc, a click elsewhere, a send): a word read that started before must not bring the
  /// selection back.
  private(set) var clears = 0

  init(view: PDFPaneView) { self.view = view }

  var isEmpty: Bool { page == nil }

  /// The highlight (while dragging, and once snapped to words); no pill until `offer`.
  func show(page: Int, rects: [CGRect]) {
    guard page < view.pages.count else { return }
    if self.page != page || card != nil || pill != nil { clear() }
    self.page = page
    self.rects = rects
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layers.forEach { $0.removeFromSuperlayer() }
    var accent = NSColor.selectedTextBackgroundColor.cgColor
    view.effectiveAppearance.performAsCurrentDrawingAppearance { accent = NSColor.selectedTextBackgroundColor.cgColor }
    layers = rects.map { r in
      let l = CALayer()
      l.zPosition = 7
      l.frame = r.insetBy(dx: -1, dy: -1)
      l.backgroundColor = accent.copy(alpha: 0.45)
      l.cornerRadius = 2
      view.pages[page].layer.addSublayer(l)
      return l
    }
    CATransaction.commit()
    watchEsc()
  }

  /// The selection mapped to the source: the Comment pill under its end.
  func offer(_ d: PDFCommentDraft) {
    draft = d
    pill?.removeFromSuperview()
    let p = SelectionPill()
    p.onClick = { [weak self] in self?.openDraft() }
    view.addSubview(p)
    pill = p
    reposition()
  }

  /// The pill's click: a draft card at the selection, its field focused; Return sends.
  func openDraft() {
    guard let d = draft else { return }
    pill?.removeFromSuperview()
    pill = nil
    let c = PDFComment(id: "draft", path: d.path, line: d.line, author: "New comment", color: nil, firstMessage: "")
    let color = NSColor.controlAccentColor
    let card = PinnedCard(NoteCard(c, color: color, quote: d.quote), color: color, placeholder: "Add a comment", resolvable: false)
    card.onSend = { [weak self] text in
      guard let self, let d = self.draft else { return }
      self.onSend?(d, text)
      self.clear()
    }
    view.addSubview(card)
    self.card = card
    reposition()
    view.window?.makeFirstResponder(card.field)
  }

  func clear() {
    clears += 1
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layers.forEach { $0.removeFromSuperlayer() }
    CATransaction.commit()
    layers = []
    pill?.removeFromSuperview()
    card?.removeFromSuperview()
    pill = nil
    card = nil
    page = nil
    rects = []
    draft = nil
    if let m = escMonitor { NSEvent.removeMonitor(m) }
    escMonitor = nil
  }

  /// Esc gives the selection (and its draft) up; the key still goes on to whoever has focus.
  private func watchEsc() {
    guard escMonitor == nil else { return }
    escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
      if e.keyCode == 53, let self, e.window === self.view.window { self.clear() }
      return e
    }
  }

  /// The pill and the card follow the selection's end; hidden while it is out of view.
  func reposition() {
    guard let page, page < view.pages.count, let last = rects.last else { return }
    let p = view.pages[page]
    let end = view.pagesView.convert(last.offsetBy(dx: p.origin.x, dy: p.origin.y), to: view)
    let visible = view.convert(view.scroll.contentView.bounds, from: view.scroll.contentView)
    for v in [pill as NSView?, card as NSView?].compactMap({ $0 }) {
      v.isHidden = !visible.intersects(end)
      let size = v.fittingSize.width > 0 ? v.fittingSize : v.frame.size
      // the pane isn't flipped: under the selection's last line is a smaller y
      var x = min(max(view.bounds.minX + 4, end.maxX - size.width / 2), view.bounds.maxX - size.width - 4)
      var y = end.minY - 6 - size.height
      if y < view.bounds.minY + 4 { y = end.maxY + 6 }  // no room under it: above
      if v === card { x = min(max(view.bounds.minX + 4, end.maxX - 40), view.bounds.maxX - size.width - 4) }
      y = min(max(y, view.bounds.minY + 4), view.bounds.maxY - size.height - 4)
      v.frame = NSRect(x: x.rounded(), y: y.rounded(), width: size.width.rounded(.up), height: size.height.rounded(.up))  // (not .integral: see NotesOverlay.placeCard)
    }
  }
}

/// "Comment", under a selection on the PDF (the editor's pill, without its shortcut).
final class SelectionPill: NSView {
  var onClick: (() -> Void)?
  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.shadowColor = NSColor.black.cgColor
    layer?.shadowOpacity = 0.25
    layer?.shadowRadius = 6
    layer?.shadowOffset = CGSize(width: 0, height: -1)
    let fx = NSVisualEffectView()
    fx.material = .popover
    fx.blendingMode = .withinWindow
    fx.state = .active
    fx.wantsLayer = true
    fx.layer?.cornerRadius = 9
    fx.layer?.masksToBounds = true
    fx.layer?.borderWidth = 0.5
    fx.layer?.borderColor = NSColor.separatorColor.cgColor
    let icon = NSImageView(image: NSImage(systemSymbolName: "text.bubble", accessibilityDescription: nil)!)
    icon.symbolConfiguration = .init(pointSize: 13, weight: .medium)
    icon.contentTintColor = .controlAccentColor
    let title = NSTextField(labelWithString: "Comment")
    title.font = .systemFont(ofSize: 13, weight: .semibold)
    let row = NSStackView(views: [icon, title])
    row.spacing = 6
    row.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 14)
    for v in [fx, row] as [NSView] {
      v.translatesAutoresizingMaskIntoConstraints = false
      addSubview(v)
      NSLayoutConstraint.activate([
        v.leadingAnchor.constraint(equalTo: leadingAnchor), v.trailingAnchor.constraint(equalTo: trailingAnchor),
        v.topAnchor.constraint(equalTo: topAnchor), v.bottomAnchor.constraint(equalTo: bottomAnchor),
      ])
    }
    heightAnchor.constraint(equalToConstant: 30).isActive = true
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    setAccessibilityLabel("Comment")
    toolTip = "Comment on the selection"
  }
  required init?(coder: NSCoder) { fatalError() }
  override func mouseDown(with e: NSEvent) {}
  override func mouseUp(with e: NSEvent) {
    if bounds.contains(convert(e.locationInWindow, from: nil)) { onClick?() }
  }
  override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
