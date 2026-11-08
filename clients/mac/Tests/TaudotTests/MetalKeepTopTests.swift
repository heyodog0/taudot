// A font change keeps the line at the top of the view there (Metal: the editor does it, TextKit's measure can't).
import AppKit
import Foundation
import Testing
@testable import TaudotEditor
@testable import TaudotShared

@MainActor @Test func biggerFontKeepsTheTopLine() async throws {
  let w = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
  let v = NativeEditorView(frame: w.contentView!.bounds, metal: true)
  v.autoresizingMask = [.width, .height]
  w.contentView!.addSubview(v)
  var text = ""
  for i in 0..<400 { text += i % 3 == 0 ? "% line \(i) " + String(repeating: "long words wrap here ", count: 9) + "\n" : "line \(i) short\n" }
  v.show(NativeDoc(docID: "d", path: "main.tex", text: text, seq: 0, conn: nil), buffer: 1)
  v.layoutSubtreeIfNeeded()
  v.jump(line: 120, col: 0)
  for _ in 0..<40 { try await Task.sleep(nanoseconds: 20_000_000) }
  let clip = v.scroll.contentView
  // the top line mostly scrolled off (a long wrapped line above the one in view)
  clip.scroll(to: NSPoint(x: 0, y: clip.bounds.minY - 0.1 * v.lineHeight))
  v.scroll.reflectScrolledClipView(clip)
  func first() -> Int { v.textView.characterIndexForInsertion(at: NSPoint(x: 40, y: clip.bounds.minY + 4)) }
  let a = first(), yA = clip.bounds.minY
  var bigger = v.style
  bigger.fontSize += 2
  keepingTop(of: v) { v.apply(style: bigger) }
  for _ in 0..<40 { try await Task.sleep(nanoseconds: 20_000_000) }
  let b = first()
  #expect(abs(a - b) <= 2, "first char \(a) → \(b), top \(yA) → \(clip.bounds.minY)")
}

/// The shell's keepingTop (ProjectWindow), which measures with TextKit: the Metal editor must win over it.
@MainActor private func keepingTop(of v: NativeEditorView, _ change: () -> Void) {
  let clip = v.scroll.contentView, tv = v.textView
  let idx = tv.characterIndexForInsertion(at: NSPoint(x: tv.textContainerInset.width + 4, y: clip.bounds.minY + 2))
  func lineY(_ i: Int) -> CGFloat? {
    guard let tlm = tv.textLayoutManager, let tcm = tlm.textContentManager,
          let loc = tcm.location(tcm.documentRange.location, offsetBy: i) else { return nil }
    tlm.ensureLayout(for: NSTextRange(location: loc))
    guard let f = tlm.textLayoutFragment(for: loc) else { return nil }
    return f.layoutFragmentFrame.minY + tv.textContainerOrigin.y
  }
  let offset = lineY(idx).map { clip.bounds.minY - $0 } ?? 0
  change()
  func restore() {
    guard let y = lineY(idx) else { return }
    clip.scroll(to: NSPoint(x: clip.bounds.minX, y: max(0, y + offset)))
    v.scroll.reflectScrolledClipView(clip)
  }
  restore()
  DispatchQueue.main.async { MainActor.assumeIsolated { restore() } }
}

/// A narrower view (window resize, a scroller showing up) rewraps: the line at the top stays there.
@MainActor @Test func narrowerViewKeepsTheTopLine() async throws {
  let w = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
  let v = NativeEditorView(frame: w.contentView!.bounds, metal: true)
  v.autoresizingMask = [.width, .height]
  w.contentView!.addSubview(v)
  var text = ""
  for i in 0..<1500 { text += i % 3 == 0 ? "% line \(i) " + String(repeating: "long words wrap here ", count: 9) + "\n" : "line \(i) short\n" }
  v.show(NativeDoc(docID: "d", path: "main.tex", text: text, seq: 0, conn: nil), buffer: 1)
  v.layoutSubtreeIfNeeded()
  v.jump(line: 1200, col: 0)
  let clip = v.scroll.contentView
  func top() -> Int { v.textView.characterIndexForInsertion(at: NSPoint(x: 0, y: clip.bounds.minY + v.lineHeight / 2)) }
  let a = top()
  w.setContentSize(NSSize(width: 520, height: 500))
  v.layoutSubtreeIfNeeded()
  let b = top()
  // the same visual line on top: its start no further than a narrower line's length away
  #expect(b <= a && a - b < 60, "top line's start \(a) → \(b)")
}
