// Google Docs' review bar: while reviewing, a small glass bar at the bottom of the editor ("Suggestion 4 of 73 ·
// Linus") with ↑ ↓, ✓ ✗ (each then moves on), Accept all / Reject all, the preview modes, and ✕.
import AppKit

public enum ReviewPosition {
  /// "Suggestion 4 of 73 · Linus", "Suggestions 4–9 of 73 · Linus" (a grouped card), "Comment 2 of 5 · Ada", from the
  /// item and the file's items as the filter shows them (raw suggestions, in text order).
  public static func text(_ cur: ReviewItem?, in items: [ReviewItem], kinds: ReviewKinds, showResolved: Bool) -> String {
    let shown = items.filter { kinds.shows($0.kind) && (showResolved || !$0.resolved) }
      .sorted { ($0.range.line, $0.range.col) < ($1.range.line, $1.range.col) }
    let sugg = shown.filter { $0.kind != .comment }, notes = shown.filter { $0.kind == .comment }
    guard let cur else {
      if !sugg.isEmpty { return sugg.count == 1 ? "1 suggestion" : "\(sugg.count) suggestions" }
      return notes.isEmpty ? "Nothing to review" : (notes.count == 1 ? "1 comment" : "\(notes.count) comments")
    }
    let who = cur.author.name.split(separator: " ").first.map(String.init) ?? cur.author.name
    if cur.kind == .comment {
      let i = (notes.firstIndex { $0.id == cur.id } ?? 0) + 1
      return "Comment \(i) of \(notes.count) · \(who)"
    }
    let ids = Set(cur.changeIDs)
    let idx = sugg.indices.filter { ids.contains(sugg[$0].id) }
    guard let a = idx.min(), let b = idx.max() else { return "\(sugg.count) suggestions" }
    return a == b ? "Suggestion \(a + 1) of \(sugg.count) · \(who)" : "Suggestions \(a + 1)–\(b + 1) of \(sugg.count) · \(who)"
  }
}

@MainActor public final class ReviewBar: NSView {
  public let label = NSTextField(labelWithString: "")
  private let glass = NSVisualEffectView()
  public private(set) var buttons: [String: NSButton] = [:]
  public let preview = NSSegmentedControl(labels: ["Markup", "Accepted", "Rejected"], trackingMode: .selectOne, target: nil, action: nil)
  public var onVerb: ((ReviewVerb) -> Void)?
  public var onAllInFile: ((_ accept: Bool) -> Void)?
  /// "off", "accepted", "rejected".
  public var onPreview: ((String) -> Void)?
  public var onClose: (() -> Void)?
  /// A comment shows Reply / Resolve; a suggestion ✓ ✗ and the file's Accept all / Reject all.
  public private(set) var isComment = false
  static let height: CGFloat = 40

  public override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    glass.material = .hudWindow
    glass.blendingMode = .withinWindow
    glass.state = .active
    glass.wantsLayer = true
    glass.layer?.cornerRadius = Self.height / 2
    glass.layer?.masksToBounds = true
    glass.layer?.borderWidth = 0.5
    addSubview(glass)
    recolor()
    shadow = NSShadow()
    layer?.shadowOpacity = 0.25
    layer?.shadowRadius = 10
    layer?.shadowOffset = CGSize(width: 0, height: -3)
    label.font = .systemFont(ofSize: 12, weight: .medium)
    label.textColor = .labelColor
    label.lineBreakMode = .byTruncatingTail
    addSubview(label)
    func add(_ key: String, _ symbol: String?, _ title: String?, _ tip: String, _ f: @escaping () -> Void) {
      let b: NSButton
      if let symbol {
        b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage(), target: nil, action: nil)
        b.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
      } else {
        b = NSButton(title: title ?? "", target: nil, action: nil)
        b.font = .systemFont(ofSize: 12, weight: .medium)
      }
      b.isBordered = false
      b.toolTip = tip
      b.setAccessibilityLabel(tip)
      let h = ButtonHandler(f)
      b.target = h
      b.action = #selector(ButtonHandler.fire)
      objc_setAssociatedObject(b, &ButtonHandler.key, h, .OBJC_ASSOCIATION_RETAIN)
      addSubview(b)
      buttons[key] = b
    }
    add("previous", "chevron.up", nil, "Previous  ⌥⌘↑") { [weak self] in self?.onVerb?(.previous) }
    add("next", "chevron.down", nil, "Next  ⌥⌘↓") { [weak self] in self?.onVerb?(.next) }
    add("accept", "checkmark", nil, "Accept, then the next  ⌥⌘↩") { [weak self] in self?.onVerb?(.accept) }
    add("reject", "xmark", nil, "Reject, then the next  ⌥⌘⌫") { [weak self] in self?.onVerb?(.reject) }
    add("acceptAll", nil, "Accept all", "Accept every suggestion in this file") { [weak self] in self?.onAllInFile?(true) }
    add("rejectAll", nil, "Reject all", "Reject every suggestion in this file") { [weak self] in self?.onAllInFile?(false) }
    add("reply", nil, "Reply", "Reply  ⌥⌘↩") { [weak self] in self?.onVerb?(.reply) }
    add("resolve", nil, "Resolve", "Resolve, then the next  ⌥⌘R") { [weak self] in self?.onVerb?(.resolve) }
    add("close", "xmark.circle.fill", nil, "Stop reviewing") { [weak self] in self?.onClose?() }
    buttons["accept"]?.contentTintColor = .systemGreen
    buttons["reject"]?.contentTintColor = .systemRed
    buttons["close"]?.contentTintColor = .tertiaryLabelColor
    for k in ["previous", "next"] { buttons[k]?.contentTintColor = .secondaryLabelColor }
    preview.controlSize = .small
    preview.font = .systemFont(ofSize: 11)
    preview.selectedSegment = 0
    preview.target = self
    preview.action = #selector(previewClicked)
    preview.setToolTip("The text with its suggestions marked", forSegment: 0)
    preview.setToolTip("As if every suggestion were accepted (read-only)", forSegment: 1)
    preview.setToolTip("As if every suggestion were rejected (read-only)", forSegment: 2)
    addSubview(preview)
    isHidden = true
    show(text: "", comment: false)
  }
  required init?(coder: NSCoder) { fatalError() }
  public override var isFlipped: Bool { true }
  // Layer colours are resolved now, in this appearance: again when it changes (Settings ▸ Appearance).
  public override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    recolor()
  }
  private func recolor() {
    effectiveAppearance.performAsCurrentDrawingAppearance { glass.layer?.borderColor = NSColor.separatorColor.cgColor }
  }

  @objc private func previewClicked() { onPreview?(["off", "accepted", "rejected"][max(0, preview.selectedSegment)]) }

  public func show(text: String, comment: Bool) {
    label.stringValue = text
    isComment = comment
    for k in ["accept", "reject", "acceptAll", "rejectAll"] { buttons[k]?.isHidden = comment }
    for k in ["reply", "resolve"] { buttons[k]?.isHidden = !comment }
    layoutBar()
  }

  public func setPreview(_ mode: String) {
    preview.selectedSegment = mode == "accepted" ? 1 : mode == "rejected" ? 2 : 0
    // While previewing the text is read-only: no accepting from the bar.
    for k in ["accept", "reject", "acceptAll", "rejectAll", "reply", "resolve"] { buttons[k]?.isEnabled = mode == "off" }
  }

  /// Its width, from what it shows.
  private func layoutBar() {
    var x: CGFloat = 16
    let h = Self.height
    label.sizeToFit()
    let lw = min(220, label.frame.width)
    label.frame = NSRect(x: x, y: (h - label.frame.height) / 2, width: lw, height: label.frame.height)
    x += lw + 10
    let order = ["previous", "next", "accept", "reject", "reply", "resolve", "acceptAll", "rejectAll"]
    for k in order {
      guard let b = buttons[k], !b.isHidden else { continue }
      let w: CGFloat = b.image != nil ? 26 : ceil(b.fittingSize.width) + 8
      b.frame = NSRect(x: x, y: (h - 24) / 2, width: w, height: 24)
      x += w + (k == "next" || k == "reject" || k == "resolve" ? 10 : 2)
    }
    preview.sizeToFit()
    preview.frame.origin = NSPoint(x: x + 4, y: ((h - preview.frame.height) / 2).rounded())
    x = preview.frame.maxX + 8
    buttons["close"]?.frame = NSRect(x: x, y: (h - 24) / 2, width: 24, height: 24)
    x += 24 + 10
    setFrameSize(NSSize(width: x, height: h))
    glass.frame = bounds
    if let s = superview { place(in: s.bounds.size) }
  }

  /// Centred at the bottom of the editor.
  func place(in size: NSSize) {
    let w = min(frame.width, size.width - 24)
    let y = (superview?.isFlipped ?? false) ? size.height - Self.height - 16 : 16
    frame = NSRect(x: ((size.width - w) / 2).rounded(), y: y, width: w, height: Self.height)
    glass.frame = bounds
  }
  public override func resize(withOldSuperviewSize oldSize: NSSize) {
    if let s = superview { place(in: s.bounds.size) }
  }
  public override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    if let s = superview { place(in: s.bounds.size) }
  }
}
