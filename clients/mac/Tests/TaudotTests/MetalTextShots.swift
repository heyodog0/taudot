// metaltext: the same doc in both native editors, written as PNGs for comparing (METALTEXT_SHOTS=<dir>).
import AppKit
import Foundation
import Testing
@testable import TaudotEditor
@testable import TaudotShared

@MainActor func metalTextPNG(_ img: CGImage, _ path: String) {
  let rep = NSBitmapImageRep(cgImage: img)
  try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["METALTEXT_SHOTS"] != nil))
func metalTextShots() async throws {
  let dir = ProcessInfo.processInfo.environment["METALTEXT_SHOTS"]!
  try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
  let text = try String(contentsOfFile: (ProcessInfo.processInfo.environment["TAUDOT_PERF_DOC"] ?? "") + "/main.tex", encoding: .utf8)
  for theme in ["dusk", "paper"] {
    for metal in [false, true] {
      let w = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
      w.orderFront(nil)
      let v = NativeEditorView(frame: w.contentView!.bounds, metal: metal)
      v.autoresizingMask = [.width, .height]
      w.contentView!.addSubview(v)
      var st = EditorStyle()
      if let t = Theme.named(theme) { st.theme = t }
      v.apply(style: st)
      v.show(NativeDoc(docID: "d", path: "main.tex", text: text, seq: 1, conn: nil), buffer: 1)
      w.makeFirstResponder(v.textView)
      for _ in 0..<400 where !v.laidOutAhead { try await Task.sleep(for: .milliseconds(5)) }
      v.jump(line: 177, col: 4)
      let loc = v.caret
      v.textView.setSelectedRange(NSRange(location: loc + 20, length: 30))
      // the rest drawn over the text: find marks (one current), a comment tint, a tracked change, a line note
      let ns = v.textView.string as NSString
      var marks: [NSRange] = []
      var r = ns.range(of: "model", options: [], range: NSRange(location: loc, length: min(4000, ns.length - loc)))
      while r.location != NSNotFound && marks.count < 6 {
        marks.append(r)
        r = ns.range(of: "model", options: [], range: NSRange(location: r.upperBound, length: min(4000, ns.length - r.upperBound)))
      }
      v.setFindMarks(marks, current: marks.isEmpty ? nil : 0)
      v.setTints([(NSRange(location: loc + 120, length: 40), NSColor.systemYellow, 0.3, true),
                  (NSRange(location: loc + 200, length: 25), NSColor.systemGreen, 0.3, false)])
      v.lineNotes = [LineNote(line: 178, id: "n", barColor: .systemPink, text: "Ann: is this the right citation?")]
      v.layoutSubtreeIfNeeded()
      w.displayIfNeeded()
      try await Task.sleep(for: .milliseconds(50))
      let name = "\(dir)/\(theme)-\(metal ? "metal" : "textkit").png"
      if metal, let mv = v.metalView, let img = mv.snapshot() {
        metalTextPNG(img, name)
      } else if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: name))
      }
      print("METALTEXT_SHOT \(name) top line \(v.visibleLines) clip \(v.scroll.contentView.bounds.minY) y177 \(v.y(ofLine: 176) ?? -1) caret \(v.textView.firstRect(forCharacterRange: NSRange(location: loc, length: 0), actualRange: nil))")
      w.orderOut(nil)
    }
  }
}

/// `commentsHidden` drops comment tints (both editors) and keeps tracked-change ones.
@MainActor @Test func commentsHiddenDropsCommentTints() {
  for metal in [false, true] {
    let v = NativeEditorView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), metal: metal)
    v.show(NativeDoc(docID: "d", path: "main.tex", text: "one two three four\n", seq: 0, conn: nil), buffer: 1)
    v.setTints([(NSRange(location: 0, length: 3), .systemBlue, 0.22, true), (NSRange(location: 4, length: 3), .systemGreen, 0.3, false)])
    #expect(v.tintRanges.count == 2)
    v.commentsHidden = true
    #expect(v.tintRanges == [NSRange(location: 4, length: 3)], "metal \(metal)")
    v.commentsHidden = false
    #expect(v.tintRanges.count == 2)
  }
}
