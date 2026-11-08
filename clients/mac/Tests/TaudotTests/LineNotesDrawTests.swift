// The end-of-line comment notes drawn by the native editor (both TextKit and Metal): after the line's text, on the
// last visual line of a wrapped line, the bar in its colour, gone while comments are hidden, never part of the text.
import AppKit
import Foundation
import Testing
@testable import TaudotEditor
@testable import TaudotShared

@MainActor @Test func lineNotesDrawnAfterTheLine() async throws {
  for metal in [false, true] {
    let w = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 420, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
    let v = NativeEditorView(frame: w.contentView!.bounds, metal: metal)
    v.autoresizingMask = [.width, .height]
    w.contentView!.addSubview(v)
    let long = String(repeating: "wrapping words ", count: 8)  // two visual lines or more at this width
    let text = long + "\n\nshort line\nlast\n"
    v.show(NativeDoc(docID: "d", path: "main.tex", text: text, seq: 0, conn: nil), buffer: 1)
    w.makeFirstResponder(v.textView)
    v.layoutSubtreeIfNeeded()
    let red = NSColor(srgbRed: 1, green: 0.1, blue: 0.1, alpha: 1)
    v.lineNotes = [LineNote(line: 0, id: "a", barColor: red, text: "Bob: wrapped one"),
                   LineNote(line: 2, id: "b", barColor: red, text: "Ann: look here", more: " (+1)")]
    w.displayIfNeeded()
    let mode = metal ? "metal" : "textkit"
    let origins = Dictionary(v.lineNoteOrigins.map { ($0.line, $0.origin) }, uniquingKeysWith: { a, _ in a })
    let o0 = try #require(origins[0], "\(mode): note on line 0")
    let o2 = try #require(origins[2], "\(mode): note on line 2")
    // line 2's note starts where "short line" ends; line 0's on its last visual line, below its first
    let y0 = try #require(v.y(ofLine: 0)), y2 = try #require(v.y(ofLine: 2))
    #expect(v.convert(o0, from: v.canvas).y > y0 + v.lineHeight / 2, "\(mode): wrapped line's note on its last visual line")
    let dy = v.convert(o2, from: v.canvas).y - y2
    #expect(dy > -0.5 && dy < v.style.lineSpacing + 0.5, "\(mode): line 2's note on its line (\(dy))")
    let cw = ("M" as NSString).size(withAttributes: [.font: v.font]).width
    #expect(abs(o2.x - (v.textView.textContainerOrigin.x + 5 + 10 * cw)) < 2, "\(mode): after the 10 characters of 'short line' (\(o2.x))")
    // pixels: the bar in red right after the line's text
    func reds() -> Int {
      let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
      v.cacheDisplay(in: v.bounds, to: rep)
      let sc = CGFloat(rep.pixelsWide) / rep.size.width
      let p = v.convert(o2, from: v.canvas)
      var n = 0
      for y in Int(p.y * sc)..<Int((p.y + v.lineHeight) * sc) { for x in Int(p.x * sc)..<Int((p.x + 4 * cw) * sc) {
        if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.redComponent > 0.6, c.greenComponent < 0.4, c.blueComponent < 0.4 { n += 1 }
      } }
      return n
    }
    #expect(reds() > 10, "\(mode): the bar drawn")
    // not text: the storage is what was shown
    #expect(v.textView.string == text)
    // hidden with the comments, back after
    v.commentsHidden = true
    w.displayIfNeeded()
    #expect(v.lineNoteOrigins.isEmpty && reds() == 0, "\(mode): hidden")
    v.commentsHidden = false
    w.displayIfNeeded()
    #expect(reds() > 10, "\(mode): back")
    v.lineNotes = []
    w.displayIfNeeded()
    #expect(reds() == 0, "\(mode): cleared")
  }
}
