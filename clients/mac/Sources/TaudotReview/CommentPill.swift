// The floating "Comment ⌥⌘M" pill under the end of a selection, over the editor (add-comment-f1.png).
import AppKit

@MainActor final class CommentPill: NSView {
  var onClick: (() -> Void)?
  private let background = NSVisualEffectView()
  private let icon = NSImageView()
  private let title = NSTextField(labelWithString: "Comment")
  private let shortcut = NSTextField(labelWithString: "⌥⌘M")
  private var hover = false { didSet { needsDisplay = true; updateLayer() } }

  static let height: CGFloat = 30

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerRadius = 9
    layer?.masksToBounds = false
    background.material = .popover
    background.blendingMode = .withinWindow
    background.state = .active
    background.wantsLayer = true
    background.layer?.cornerRadius = 9
    background.layer?.masksToBounds = true
    addSubview(background)
    icon.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: nil)
    icon.symbolConfiguration = .init(pointSize: 13, weight: .medium)
    icon.contentTintColor = .controlAccentColor
    title.font = .systemFont(ofSize: 13, weight: .semibold)
    shortcut.font = .systemFont(ofSize: 12)
    shortcut.textColor = .tertiaryLabelColor
    [icon, title, shortcut].forEach(addSubview)
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    setAccessibilityLabel("Comment")
    setAccessibilityHelp("Comment on the selection (⌥⌘M)")
    toolTip = "Comment on the selection (⌥⌘M)"
    addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    setFrameSize(intrinsicSize)
  }
  required init?(coder: NSCoder) { fatalError() }
  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }

  var intrinsicSize: NSSize {
    NSSize(width: 12 + 18 + 6 + title.fittingSize.width + 10 + shortcut.fittingSize.width + 12, height: Self.height)
  }

  override func layout() {
    super.layout()
    background.frame = bounds
    let h = bounds.height
    icon.frame = NSRect(x: 12, y: (h - 18) / 2, width: 18, height: 18)
    let tw = title.fittingSize
    title.frame = NSRect(x: icon.frame.maxX + 6, y: (h - tw.height) / 2, width: tw.width, height: tw.height)
    let sw = shortcut.fittingSize
    shortcut.frame = NSRect(x: title.frame.maxX + 10, y: (h - sw.height) / 2, width: sw.width, height: sw.height)
  }

  override func updateLayer() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.borderWidth = 0.5
      layer?.borderColor = NSColor.separatorColor.cgColor
      layer?.shadowColor = NSColor.black.cgColor
      layer?.shadowOpacity = 0.3
      layer?.shadowRadius = 6
      layer?.shadowOffset = CGSize(width: 0, height: -2)
      layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 9, cornerHeight: 9, transform: nil)
      background.layer?.backgroundColor = hover ? NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor : nil
    }
  }

  override func mouseEntered(with event: NSEvent) { hover = true }
  override func mouseExited(with event: NSEvent) { hover = false }
  // A click must not take focus from the editor (the selection lives there): act on mouse down.
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override var acceptsFirstResponder: Bool { false }
  override func mouseDown(with event: NSEvent) { onClick?() }
  override func accessibilityPerformPress() -> Bool { onClick?(); return true }
  // Clicks anywhere on the pill land on the pill, not its labels.
  override func hitTest(_ point: NSPoint) -> NSView? {
    let p = superview.map { convert(point, from: $0) } ?? point
    return bounds.contains(p) && !isHidden && alphaValue > 0.01 ? self : nil
  }
}
