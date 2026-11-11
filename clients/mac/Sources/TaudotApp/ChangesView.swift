// The sidebar's Changes tab (editfix item 9): every outside edit since the project opened (a coauthor's, Claude's,
// another editor's), newest first, with where it is and what it did. A click jumps there; Undo puts the text back while
// it is still as the edit left it. "Follow edits" at the top is the View menu's toggle.
import AppKit
import TaudotEditor
import TaudotReview

@MainActor final class ChangesView: NSView {
  private let scroll = NSScrollView()
  private let stack = NSStackView()
  private let follow = NSButton(checkboxWithTitle: "Follow edits", target: nil, action: nil)
  private let empty = NSTextField(wrappingLabelWithString:
    "Edits made outside this window show here as they land: by Claude, another editor, or a coauthor.")
  var onJump: ((OutsideEdits.Change) -> Void)?
  var onUndo: ((OutsideEdits.Change) -> Void)?
  var onFollow: ((Bool) -> Void)?
  var following = false { didSet { follow.state = following ? .on : .off } }
  /// The rows shown, for checks: (who, summary, undo offered).
  private(set) var rowsForTest: [(who: String, summary: String, undo: Bool)] = []

  override init(frame: NSRect) {
    super.init(frame: frame)
    follow.controlSize = .small
    follow.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    follow.target = self
    follow.action = #selector(followClicked)
    follow.toolTip = "Scroll to each outside edit as it lands (not while you type) (View ▸ Follow Edits)"
    addSubview(follow)
    empty.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    empty.textColor = .secondaryLabelColor
    addSubview(empty)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 2
    let doc = FlippedView()
    doc.addSubview(stack)
    scroll.documentView = doc
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    scroll.autohidesScrollers = true
    addSubview(scroll)
  }
  required init?(coder: NSCoder) { fatalError() }
  override var isFlipped: Bool { true }

  override func layout() {
    super.layout()
    let top = ReviewMarginView.headerHeight + 6
    follow.sizeToFit()
    follow.frame.origin = NSPoint(x: 12, y: top)
    let y = follow.frame.maxY + 6
    scroll.frame = NSRect(x: 0, y: y, width: bounds.width, height: max(0, bounds.height - y))
    empty.frame = NSRect(x: 12, y: y + 4, width: max(40, bounds.width - 24), height: 60)
    layoutStack()
  }

  private func layoutStack() {
    let w = scroll.contentSize.width
    for v in stack.arrangedSubviews { (v as? Row)?.width = w }
    stack.frame = NSRect(x: 0, y: 0, width: w, height: stack.fittingSize.height)
    scroll.documentView?.frame = NSRect(x: 0, y: 0, width: w, height: stack.frame.height)
  }

  @objc private func followClicked() { onFollow?(follow.state == .on) }

  func update(_ m: OutsideEdits) {
    let list = m.list
    for v in stack.arrangedSubviews { stack.removeArrangedSubview(v); v.removeFromSuperview() }
    rowsForTest = []
    for c in list {
      let loc = m.line(of: c).map { "\(c.path):\($0.line)" } ?? c.path
      let undo = m.canUndo(c)
      let r = Row(c, place: loc, summary: OutsideEdits.summary(c), undo: undo)
      r.onClick = { [weak self] in self?.onJump?(c) }
      r.onUndo = { [weak self] in self?.onUndo?(c) }
      stack.addArrangedSubview(r)
      rowsForTest.append((c.who, OutsideEdits.summary(c), undo))
    }
    empty.isHidden = !list.isEmpty
    layoutStack()
  }

  /// One edit: a dot in its colour, who and where and when, what it did, Undo.
  final class Row: NSView {
    var onClick: (() -> Void)?
    var onUndo: (() -> Void)?
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let dot = NSView()
    private let undo = NSButton(title: "Undo", target: nil, action: nil)
    var width: CGFloat = 260 { didSet { needsLayout = true; invalidateIntrinsicContentSize() } }

    init(_ c: OutsideEdits.Change, place: String, summary: String, undo canUndo: Bool) {
      super.init(frame: .zero)
      dot.wantsLayer = true
      dot.layer?.backgroundColor = OutsideEdits.color(c).cgColor
      dot.layer?.cornerRadius = 4
      addSubview(dot)
      let f = RelativeDateTimeFormatter()
      f.unitsStyle = .abbreviated
      let age = Date().timeIntervalSince(c.time)
      title.stringValue = "\(c.who) · \(place) · \(age < 10 ? "just now" : f.localizedString(for: c.time, relativeTo: Date()))"
      title.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
      title.lineBreakMode = .byTruncatingTail
      addSubview(title)
      detail.stringValue = c.undone ? "undone" : summary
      detail.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize - 1, weight: .regular)
      detail.textColor = .secondaryLabelColor
      detail.lineBreakMode = .byTruncatingTail
      addSubview(detail)
      undo.bezelStyle = .inline
      undo.controlSize = .small
      undo.font = .systemFont(ofSize: NSFont.smallSystemFontSize - 1)
      undo.isHidden = !canUndo
      undo.toolTip = "Put back what this edit replaced"
      undo.target = self
      undo.action = #selector(undoClicked)
      addSubview(undo)
      toolTip = "Go to this edit"
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: width, height: 40) }
    override func layout() {
      super.layout()
      undo.sizeToFit()
      let right = undo.isHidden ? width - 10 : width - undo.frame.width - 14
      dot.frame = NSRect(x: 12, y: 8, width: 8, height: 8)
      title.frame = NSRect(x: 26, y: 3, width: max(20, right - 26), height: 16)
      detail.frame = NSRect(x: 26, y: 20, width: max(20, right - 26), height: 15)
      undo.frame.origin = NSPoint(x: width - undo.frame.width - 10, y: 10)
    }
    override func mouseDown(with e: NSEvent) { onClick?() }
    @objc private func undoClicked() { onUndo?() }
  }
}

private final class FlippedView: NSView { override var isFlipped: Bool { true } }
