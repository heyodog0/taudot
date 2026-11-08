// Drawing the end-of-line comment notes (LineNotes.swift is the model): after the text of the note's line (its last
// visual line when wrapped), the bar in the author's colour and bold, the words in the theme's comment colour. Not
// part of the text: nothing selects, edits, copies or sends them. Hidden while `commentsHidden`. The TextKit editor
// draws them in an overlay over its text view; the Metal editor in its frame (MetalTextView).
import AppKit

extension NativeEditorView {
  /// The notes drawn now: none while comments are hidden in the text.
  var shownNotes: [LineNote] { commentsHidden ? [] : lineNotes }

  /// A note as drawn: the bar bold in its colour, the rest in the theme's comment colour.
  func noteString(_ n: LineNote) -> NSAttributedString {
    let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
    let s = NSMutableAttributedString(string: n.bar, attributes: [.font: bold, .foregroundColor: n.barColor])
    s.append(NSAttributedString(string: n.text + n.more, attributes: [.font: font, .foregroundColor: style.theme.color(\.comment)]))
    return s
  }

  /// Where each shown note on a laid-out line starts (the end of its line's text), in the canvas: for checks and the
  /// TextKit overlay.
  public var lineNoteOrigins: [(line: Int, origin: NSPoint)] {
    let st = starts16
    let n = (textView.string as NSString).length
    return shownNotes.compactMap { note in
      guard note.line >= 0, note.line < st.count else { return nil }
      let end = note.line + 1 < st.count ? st[note.line + 1] - 1 : n
      if let lay = textLayout {
        let r = lay.caretRect(end)
        return (note.line, NSPoint(x: r.minX, y: r.minY))
      }
      guard let w = window else { return nil }
      let screen = textView.firstRect(forCharacterRange: NSRange(location: end, length: 0), actualRange: nil)
      guard screen != .zero else { return nil }
      let r = canvas.convert(w.convertFromScreen(screen), from: nil)
      return (note.line, NSPoint(x: r.minX, y: r.minY))
    }
  }

  func lineNotesChanged() {
    if isMetal { metalView?.setNeedsRender(withCommit: true); return }
    let o = LineNotesOverlay.of(self)
    o.frame = canvas.bounds
    o.needsDisplay = true
  }
}

/// TextKit mode: the notes over the text view, at each line's end.
final class LineNotesOverlay: NSView {
  weak var owner: NativeEditorView?
  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  @MainActor static func of(_ e: NativeEditorView) -> LineNotesOverlay {
    if let o = e.canvas.subviews.lazy.compactMap({ $0 as? LineNotesOverlay }).first { return o }
    let o = LineNotesOverlay(frame: e.canvas.bounds)
    o.owner = e
    o.autoresizingMask = [.width, .height]
    e.canvas.addSubview(o)
    e.onChange { [weak o, weak e] in
      guard let o, let e, !e.lineNotes.isEmpty else { return }
      if o.frame != e.canvas.bounds { o.frame = e.canvas.bounds }
      o.needsDisplay = true
    }
    return o
  }

  override func draw(_ dirtyRect: NSRect) {
    MainActor.assumeIsolated {
      guard let e = owner else { return }
      let notes = Dictionary(e.shownNotes.map { ($0.line, $0) }, uniquingKeysWith: { a, _ in a })
      let lh = e.lineHeight
      for (line, p) in e.lineNoteOrigins {
        guard let n = notes[line], NSRect(x: p.x, y: p.y, width: bounds.width, height: lh).intersects(dirtyRect) else { continue }
        // (the line's top is above its spacing, which TextKit puts over the glyphs: on the text's own baseline)
        e.noteString(n).draw(at: NSPoint(x: p.x, y: p.y + e.style.lineSpacing))
      }
    }
  }
}
