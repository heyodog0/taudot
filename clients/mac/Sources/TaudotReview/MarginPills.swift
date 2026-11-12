// The review panel's Quiet design: the ↑ n above / ↓ n below pills and the
// connector setting.
import AppKit

/// Settings ▸ Comments ▸ Connectors.
public enum ConnectorMode: String, Sendable, CaseIterable {
  case none, selected, all
  public static let key = "taudot.comments.connectors"
  /// The saved choice (all by default: a soft line from every card on screen to its text).
  public static var saved: ConnectorMode { UserDefaults.standard.string(forKey: key).flatMap(ConnectorMode.init(rawValue:)) ?? .all }
  public var title: String { ["None", "Selected Only", "All"][Self.allCases.firstIndex(of: self)!] }
}

/// "↑ 2 above" / "↓ 3 below": a small capsule; click to go to the nearest one.
final class JumpPill: NSView {
  private let label = NSTextField(labelWithString: "")
  var onClick: (() -> Void)?
  var count = 0 { didSet { if count != oldValue { update() } } }
  let up: Bool
  init(up: Bool) {
    self.up = up
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 11
    label.font = .systemFont(ofSize: 11, weight: .medium)
    label.textColor = .secondaryLabelColor
    label.alignment = .center
    addSubview(label)
    update()
  }
  required init?(coder: NSCoder) { fatalError() }
  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }
  private func update() {
    label.stringValue = "\(up ? "↑" : "↓") \(count) \(up ? "above" : "below")"
    isHidden = count == 0
    toolTip = up ? "Go to the comment above" : "Go to the comment below"
    needsLayout = true
  }
  var fitWidth: CGFloat { ceil(label.fittingSize.width) + 20 }
  override func layout() {
    super.layout()
    let h = label.fittingSize.height
    label.frame = NSRect(x: 0, y: (bounds.height - h) / 2, width: bounds.width, height: h)
  }
  override func updateLayer() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      layer?.backgroundColor = (dark ? NSColor(white: 1, alpha: 0.09) : NSColor(white: 0, alpha: 0.06)).cgColor
      layer?.borderWidth = 0.5
      layer?.borderColor = NSColor.separatorColor.cgColor
    }
  }
  override func mouseDown(with event: NSEvent) { onClick?() }
  override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// The lines from cards to their text, over the panel and the editor: draws only, never takes a click or a scroll.
final class ConnectorOverlay: NSView {
  let mask = CAShapeLayer()
  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.mask = mask
    mask.actions = ReviewMarginView.noActions
  }
  required init?(coder: NSCoder) { fatalError() }
  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override func makeBackingLayer() -> CALayer {
    let l = CALayer()
    l.actions = ["sublayers": NSNull(), "contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
    return l
  }
}
