// The reply field shared by the review margin's cards and the PDF's note cards: it wraps, grows by whole lines, and
// keeps one line centred in its box. ↩ sends, ⇧↩/⌥↩ is a new line, Esc gives up.
import AppKit

/// The reply field: ↩ (or ⌘↩) sends, ⇧↩ or ⌥↩ is a new line, Esc gives up.
public final class ReplyTextView: NSTextView {
  public var onSend: (() -> Void)?
  public var onCancel: (() -> Void)?
  public var onResize: (() -> Void)?
  public var placeholder = "Reply"

  public override func keyDown(with event: NSEvent) {
    if event.keyCode == 36 || event.keyCode == 76, !hasMarkedText() {
      let m = event.modifierFlags.intersection([.shift, .option, .command, .control])
      if m.contains(.shift) || m.contains(.option) {
        insertNewlineIgnoringFieldEditor(nil)
      } else {
        onSend?()
      }
      return
    }
    if event.keyCode == 53 {
      onCancel?()
      return
    }
    super.keyDown(with: event)
  }
  public override func didChangeText() {
    super.didChangeText()
    needsDisplay = true
    onResize?()
  }
  public override func draw(_ rect: NSRect) {
    super.draw(rect)
    if string.isEmpty {
      let attrs: [NSAttributedString.Key: Any] = [.font: font ?? .systemFont(ofSize: 13), .foregroundColor: NSColor.placeholderTextColor]
      let pad = textContainer?.lineFragmentPadding ?? 5
      (placeholder as NSString).draw(at: NSPoint(x: textContainerInset.width + pad, y: textContainerInset.height), withAttributes: attrs)
    }
  }
  /// The field's height for one line; the text sits in its middle and the field grows by whole lines below that.
  public static let minHeight: CGFloat = 30
  /// One line's height in this font, as the layout manager lays it.
  public var lineHeight: CGFloat {
    let f = font ?? .systemFont(ofSize: 13)
    return layoutManager?.defaultLineHeight(for: f) ?? ceil(f.ascender - f.descender + f.leading)
  }
  /// The same space above the first line and below the last, so one line is centred in `minHeight`.
  public func centreText() {
    let v = max(2, (Self.minHeight - lineHeight) / 2)
    if textContainerInset.height != v { textContainerInset = NSSize(width: textContainerInset.width, height: v) }
  }
  /// Height of the text, for the card's layout.
  public var contentHeight: CGFloat {
    guard let lm = layoutManager, let tc = textContainer else { return Self.minHeight }
    lm.ensureLayout(for: tc)
    // An empty field still has one line (the insertion point's).
    let used = string.isEmpty ? lineHeight : max(lineHeight, lm.usedRect(for: tc).height)
    return used + textContainerInset.height * 2
  }
}

/// The rounded box around a reply field. Flipped, and it keeps the text view at its own size: a text view that
/// sizes itself to its text would otherwise sit at the bottom of the box (AppKit's y goes up), the text low.
public final class ReplyBox: NSView {
  public override var isFlipped: Bool { true }
  public override func layout() {
    super.layout()
    subviews.first?.frame = bounds
  }
}

