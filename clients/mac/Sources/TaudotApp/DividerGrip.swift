// A grip over each thin divider of a split view: the 1 pt line was a hard target, and the PDF pane's hover reset the
// cursor to an arrow next to it (the resize cursor flickered). Each grip is a 12 pt band centred on its divider, above
// the panes, that owns the mouse there: the resize cursor, a soft line on hover (stronger while dragging), and the drag
// itself (through the split view's delegate limits, so it moves as the divider would).
import AppKit

@MainActor final class DividerGrips {
  let split: NSSplitView
  private var grips: [Grip] = []
  static let width: CGFloat = 12

  init(_ split: NSSplitView) { self.split = split }

  /// Follow every frame change of the split and its panes (window resizes, autosaved positions, animated toggles,
  /// drags), not only the delegate's resize notification: a grip left at a stale place sat beside its divider.
  private var watching: Set<ObjectIdentifier> = []
  private func watch(_ v: NSView) {
    guard watching.insert(ObjectIdentifier(v)).inserted else { return }
    v.postsFrameChangedNotifications = true
    NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: v, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.layout() }
    }
  }

  /// Place (and add, the first time) a grip on each divider; hidden where the divider is.
  func layout() {
    guard let host = split.superview else { return }
    watch(split)
    split.subviews.forEach(watch)
    let n = max(0, split.subviews.count - 1)
    while grips.count < n {
      let g = Grip(split: split, index: grips.count)
      host.addSubview(g, positioned: .above, relativeTo: split)
      grips.append(g)
    }
    for (i, g) in grips.enumerated() {
      let hidden = i >= n || (split.delegate?.splitView?(split, shouldHideDividerAt: i) ?? false)
        || split.subviews[i].isHidden || (i + 1 < split.subviews.count && split.subviews[i + 1].isHidden)
      g.isHidden = hidden
      guard !hidden else { continue }
      let a = split.subviews[i].frame, d = split.dividerThickness, w = Self.width
      let r = split.isVertical
        ? NSRect(x: a.maxX + d / 2 - w / 2, y: 0, width: w, height: split.bounds.height)
        : NSRect(x: 0, y: a.maxY + d / 2 - w / 2, width: split.bounds.width, height: w)
      let f = host.convert(r, from: split)
      if g.frame != f { g.frame = f; g.window?.invalidateCursorRects(for: g) }
    }
  }

  /// Whether a point (window coordinates) is on one of the grips.
  func contains(windowPoint p: NSPoint) -> Bool {
    grips.contains { !$0.isHidden && $0.bounds.contains($0.convert(p, from: nil)) }
  }

  final class Grip: NSView {
    weak var split: NSSplitView?
    let index: Int
    private let line = CALayer()
    private var hovered = false { didSet { restyle() } }
    private var dragging = false { didSet { restyle() } }
    private var grabOffset: CGFloat = 0

    init(split: NSSplitView, index: Int) {
      self.split = split
      self.index = index
      super.init(frame: .zero)
      wantsLayer = true
      line.opacity = 0
      line.cornerRadius = 1
      layer?.addSublayer(line)
      setAccessibilityElement(true)
      setAccessibilityRole(.splitter)
      setAccessibilityLabel("Resize panes")
    }
    required init?(coder: NSCoder) { fatalError() }

    var vertical: Bool { split?.isVertical ?? true }
    var cursor: NSCursor { vertical ? .resizeLeftRight : .resizeUpDown }

    override func layout() {
      super.layout()
      CATransaction.begin(); CATransaction.setDisableActions(true)
      line.frame = vertical
        ? NSRect(x: bounds.midX - 1, y: 0, width: 2, height: bounds.height)
        : NSRect(x: 0, y: bounds.midY - 1, width: bounds.width, height: 2)
      CATransaction.commit()
    }
    override var frame: NSRect { didSet { needsLayout = true } }

    private func restyle() {
      effectiveAppearance.performAsCurrentDrawingAppearance {
        line.backgroundColor = (dragging ? NSColor.controlAccentColor : NSColor.secondaryLabelColor).cgColor
      }
      let target: Float = dragging ? 0.9 : hovered ? 0.45 : 0
      let a = CABasicAnimation(keyPath: "opacity")
      a.fromValue = line.presentation()?.opacity ?? line.opacity
      a.toValue = target
      a.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : (target > line.opacity ? 0.12 : 0.25)
      a.timingFunction = CAMediaTimingFunction(name: .easeOut)
      line.opacity = target
      line.add(a, forKey: "opacity")
    }

    override func updateTrackingAreas() {
      super.updateTrackingAreas()
      trackingAreas.forEach(removeTrackingArea)
      addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                                     owner: self))
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }
    override func cursorUpdate(with event: NSEvent) { cursor.set() }
    override func mouseEntered(with event: NSEvent) { hovered = true; cursor.set() }
    override func mouseMoved(with event: NSEvent) { cursor.set() }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with e: NSEvent) {
      guard let split, index < split.subviews.count else { return }
      dragging = true
      cursor.set()
      let p = split.convert(e.locationInWindow, from: nil)
      let edge = vertical ? split.subviews[index].frame.maxX : split.subviews[index].frame.maxY
      grabOffset = (vertical ? p.x : p.y) - edge
    }
    override func mouseDragged(with e: NSEvent) {
      guard let split, index < split.subviews.count else { return }
      let p = split.convert(e.locationInWindow, from: nil)
      var pos = (vertical ? p.x : p.y) - grabOffset
      // the limits the delegate gives a dragged divider
      let lo = vertical ? split.subviews[index].frame.minX : split.subviews[index].frame.minY
      let next = split.subviews[index + 1].frame
      let hi = (vertical ? next.maxX : next.maxY) - split.dividerThickness
      let minC = split.delegate?.splitView?(split, constrainMinCoordinate: lo, ofSubviewAt: index) ?? lo
      let maxC = split.delegate?.splitView?(split, constrainMaxCoordinate: hi, ofSubviewAt: index) ?? hi
      pos = min(max(pos, minC), maxC)
      split.setPosition(pos, ofDividerAt: index)
      cursor.set()
    }
    override func mouseUp(with e: NSEvent) {
      dragging = false
      hovered = bounds.contains(convert(e.locationInWindow, from: nil))
    }
  }
}
