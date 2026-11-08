// statefix A9: the Vim engine's offsets (visual ends, marks, a pending operator) across a text replacement (another
// file shown) and remote edits. The selection must never be out of the text (the .sty crash's shape).
import AppKit
import Testing
@testable import TaudotEditor

@MainActor private func setup(_ text: String) -> (NativeEditorView, NSWindow, (String) -> Void) {
  let v = NativeEditorView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
  let w = NSWindow(contentRect: NSRect(x: -3000, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
  w.contentView = v
  v.show(NativeDoc(docID: "a", path: "a.tex", text: text, seq: 0, conn: nil), buffer: 1)
  v.vimEnabled = true
  w.makeFirstResponder(v.textView)
  return (v, w, { keys in for k in VimKey.parse(keys) { v.textView.keyDown(with: keyEvent(k.name, window: w)) } })
}

private let long = (1...40).map { "line \($0) of the first file" }.joined(separator: "\n") + "\n"

@MainActor @Test func a9VisualAcrossAFileSwitch() {
  let (v, _, type) = setup(long)
  type("20Gvjjj")  // a visual selection deep in a.tex
  #expect(v.vimEngine?.mode == .visual)
  v.show(NativeDoc(docID: "b", path: "b.tex", text: "short\n", seq: 0, conn: nil), buffer: 2)
  #expect(v.vimEngine?.mode == .normal, "another file: out of visual mode")
  let len = (v.textView.string as NSString).length
  type("l")
  #expect(NSMaxRange(v.textView.selectedRange()) <= len)
  type("gv")  // a.tex's last selection: not re-selected in b.tex
  #expect(NSMaxRange(v.textView.selectedRange()) <= len, "gv stays inside b.tex")
  #expect(v.vimEngine?.mode == .normal)
}

@MainActor @Test func a9MarksAndPendingOperatorAcrossAFileSwitch() {
  let (v, _, type) = setup(long)
  type("30Gma")
  type("d")  // an operator waiting for its motion
  v.show(NativeDoc(docID: "b", path: "b.tex", text: "one\ntwo\nthree\n", seq: 0, conn: nil), buffer: 2)
  type("j")  // in a.tex this would have been `dj`
  #expect(v.textView.string == "one\ntwo\nthree\n", "a.tex's pending d doesn't delete in b.tex")
  type("'a")  // a.tex's mark
  #expect(v.textView.selectedRange().location == 0 || v.textView.string == "one\ntwo\nthree\n")
  #expect(NSMaxRange(v.textView.selectedRange()) <= (v.textView.string as NSString).length)
}

/// Remote edits before a visual selection and a mark: both stay on their text.
@MainActor @Test func a9OffsetsFollowRemoteEdits() {
  let (v, _, type) = setup(long)
  guard let d = v.doc else { Issue.record("no doc"); return }
  type("30Gma")
  type("10Gvj")
  let s0 = (v.textView.string as NSString).substring(with: v.textView.selectedRange())
  d.changed(["seq": 1, "edits": [["pos": 0, "del": 0, "ins": "a new first line\n"]]])
  let s1 = (v.textView.string as NSString).substring(with: v.textView.selectedRange())
  #expect(s1 == s0, "the selection is the same text")
  type("j")  // extending it keeps the same anchor
  let s2 = (v.textView.string as NSString).substring(with: v.textView.selectedRange())
  #expect(s2.hasPrefix("line 10 of"), "anchored where it was: \(s2.prefix(20))")
  type("<Esc>'a")
  let at = v.textView.selectedRange().location
  let line = (v.textView.string as NSString).substring(with: (v.textView.string as NSString).lineRange(for: NSRange(location: at, length: 0)))
  #expect(line.hasPrefix("line 30 "), "'a is still on line 30's text: \(line)")
}
