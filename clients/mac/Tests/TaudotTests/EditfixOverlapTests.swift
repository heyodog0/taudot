// editfix bug 2: "sometimes lines overlapped one another in the native editor, but it fixed itself after". A storm of
// what changes line heights and wrap widths (window resizes, font changes, remote edits above and in view, scrolls)
// while every frame the Metal editor draws is checked: no two drawn visual lines may overlap.
import AppKit
import Foundation
import Testing
@testable import TaudotEditor
@testable import TaudotShared

@MainActor final class OpBox { var op = "" }

@MainActor @Test func metalLinesNeverOverlapDuringStorm() async throws {
  let w = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 700, height: 500), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
  let v = NativeEditorView(frame: w.contentView!.bounds, metal: true)
  v.autoresizingMask = [.width, .height]
  w.contentView!.addSubview(v)
  var text = ""
  for i in 0..<300 { text += i % 4 == 0 ? "% para \(i) " + String(repeating: "words that wrap at the edge ", count: 1 + i % 7) + "\n" : "line \(i)\n" }
  let doc = NativeDoc(docID: "d", path: "main.tex", text: text, seq: 0, conn: nil)
  v.show(doc, buffer: 1)
  v.layoutSubtreeIfNeeded()
  let mv = try #require(v.metalView)
  let last = OpBox()
  var bad: [String] = []
  var frames = 0
  mv.onFrame = {
    frames += 1
    let lh = v.textLayout!.lineHeight
    if let k = v.textLayout!.staleCum(), bad.count < 10 { bad.append("after \(last.op) frame \(frames): stale count at paragraph \(k) (laid \(v.textLayout!.paras[k].laid), lines \(v.textLayout!.paras[k].lines))") }
    let ls = mv.drawnLines.sorted { $0.top < $1.top }
    for (a, b) in zip(ls, ls.dropFirst()) where b.top - a.top < lh - 0.01 {
      if bad.count < 10 { bad.append("after \(last.op) frame \(frames): (\(a.k),\(a.l)) at \(a.top) and (\(b.k),\(b.l)) at \(b.top), line height \(lh)") }
    }
  }
  let opNames = ["resize", "style", "edit", "edit", "scroll", "jump"]
  var seq = 0
  var rng = SystemRandomNumberGenerator()
  func spin() async { try? await Task.sleep(for: .milliseconds(Int.random(in: 0...6, using: &rng))) }
  for step in 0..<400 {
    let op = Int.random(in: 0..<6, using: &rng)
    last.op = opNames[op]
    switch op {
    case 0:
      w.setContentSize(NSSize(width: CGFloat.random(in: 300...900, using: &rng), height: CGFloat.random(in: 250...700, using: &rng)))
    case 1:
      var s = v.style
      s.fontSize = CGFloat(Int.random(in: 10...20, using: &rng))
      s.lineSpacing = CGFloat(Int.random(in: 0...6, using: &rng))
      v.apply(style: s)
    case 2, 3:
      // a remote edit: a line or a wrapped paragraph in, or one out, above or in view
      let n = doc.text.count
      let pos = Int.random(in: 0..<max(1, n), using: &rng)
      seq += 1
      if Bool.random(using: &rng) {
        let ins = Bool.random(using: &rng) ? "new \(step)\n" : String(repeating: "remote words wrap ", count: Int.random(in: 1...12, using: &rng)) + "\n"
        doc.changed(["seq": seq, "edits": [["pos": pos, "del": 0, "ins": ins]]])
      } else {
        doc.changed(["seq": seq, "edits": [["pos": pos, "del": min(40, n - pos), "ins": ""]]])
      }
    case 4:
      let clip = v.scroll.contentView
      clip.scroll(to: NSPoint(x: 0, y: CGFloat.random(in: 0...max(0, v.documentHeight - clip.bounds.height), using: &rng)))
      v.scroll.reflectScrolledClipView(clip)
    default:
      v.jump(line: Int.random(in: 1...250, using: &rng), col: 0)
    }
    await spin()
  }
  try await Task.sleep(for: .milliseconds(200))
  #expect(frames > 100)
  #expect(bad.isEmpty, "\(bad.joined(separator: "\n"))")
}

/// The cause, alone: laying out a paragraph whose real line count differs from its estimate must move the
/// paragraphs after it (before: the count before the next paragraph kept the estimate).
@MainActor @Test func layingOutAParagraphMovesTheNextOne() {
  // narrow words wrap to more lines than the estimate (characters × "M" width / width) guesses
  let long = String(repeating: "iiii ", count: 40) + String(repeating: "WWWWWWWWWWWWWWWWWWWWWWWWWWWWWW ", count: 6)
  let text = (0..<20).map { $0 == 5 ? long : "short \($0)" }.joined(separator: "\n") as NSString
  let lay = TextLayout(text: NSMutableString(string: text as String), font: .monospacedSystemFont(ofSize: 13, weight: .regular),
                       lineSpacing: 3, origin: .zero, width: 200)
  let lay2 = TextLayout(text: NSMutableString(string: text as String), font: .systemFont(ofSize: 13), lineSpacing: 3, origin: .zero, width: 200)
  for l in [lay, lay2] {
    _ = l.totalLines  // counts from estimates
    let p = l.ensure(5)
    #expect(l.linesBefore(6) == l.linesBefore(5) + p.lines, "paragraph 5: \(p.lines) lines, next starts \(l.linesBefore(6) - l.linesBefore(5)) after")
    #expect(l.staleCum() == nil)
  }
}
