import AppKit
import Foundation
import Testing
@testable import TaudotNeovim
@testable import TaudotShared
@testable import TaudotPDF
@testable import TaudotEditor

// MARK: font size in the Neovim mode (editfix bug 1)

@MainActor func editfixWait(_ cond: @escaping () -> Bool) async {
  for _ in 0..<500 where !cond() { try? await Task.sleep(for: .milliseconds(10)) }
}

@Test(arguments: [Theme.neovimID, "dusk"]) @MainActor func neovimModeFontSizeFromSettings(theme: String) async throws {
  let suite = "taudot.tests.\(UUID().uuidString)"
  let d = try #require(UserDefaults(suiteName: suite))
  defer { d.removePersistentDomain(forName: suite) }
  let s = TaudotSettings(d)
  s.editorTheme = theme; s.lineSpace = 0
  let nv = try Neovim(args: ["--clean", "-n"])
  defer { nv.terminate() }
  let v = EditorView(nvim: nv, frame: NSRect(x: 0, y: 0, width: 640, height: 480))
  try await v.attach()
  await editfixWait { v.ui.grids[1]?.width == v.cols }
  _ = try await nv.execLua(s.neovimLua(), [])
  try await Task.sleep(for: .milliseconds(300))
  let lh0 = v.lineHeight, cols0 = v.cols
  s.fontSize = 18
  _ = try await nv.execLua(s.neovimLua(), [])
  await editfixWait { v.lineHeight > lh0 && v.ui.grids[1]?.width == v.cols }
  #expect(v.lineHeight > lh0, "\(theme): line height \(lh0) → \(v.lineHeight)")
  #expect(v.cols < cols0)
  #expect(v.ui.grids[1]?.width == v.cols)
}

// MARK: a PDF click's highlight fades by itself (editfix bug 3)



/// Clicking from line to line in the PDF: each click marks its line and the editor's cursor lands there (its report
/// is not deliberate), so the old rule "stays while the cursor is on its line" kept it on for good. Now it fades.
@MainActor @Test func pdfClickHighlightFadesAfterClicksInARow() async throws {
  TaudotPDFPane.followsForTest = false
  let hold = TaudotPDFPane.clickMarkHold
  TaudotPDFPane.clickMarkHold = 0.3
  defer { TaudotPDFPane.followsForTest = nil; TaudotPDFPane.clickMarkHold = hold }
  let pdf = TaudotPDFPane()
  pdf.pane.setSizes([CGSize(width: 612, height: 792)])
  for i in 0..<6 {
    let y = 100 + CGFloat(i) * 40
    // what syncClick does: the mark on the clicked word and line, then the editor jumps there
    pdf.pane.reveal(page: 0, rects: [CGRect(x: 200, y: y, width: 30, height: 10)], lines: [CGRect(x: 108, y: y, width: 396, height: 9)])
    pdf.clickMarked("main.tex", 10 + i)
    // the editor's cursor report for that line (cursor-follow, not deliberate)
    pdf.cursorMoved(path: "main.tex", line: 10 + i, column: 3, deliberate: false)
    #expect(pdf.pane.markShown, "click \(i): the mark shows")
    try await Task.sleep(for: .milliseconds(100))  // faster than the hold: still shown
    #expect(pdf.pane.markShown)
  }
  try await Task.sleep(for: .milliseconds(600))
  #expect(!pdf.pane.markShown && pdf.markFor == nil, "after the clicks, the highlight is gone")
  // a deliberate jump from the editor (⌘⌥J) still stays while the cursor is on its line
  pdf.cursorMoved(path: "main.tex", line: 40, column: 0, deliberate: true)
  pdf.pane.reveal(page: 0, rects: [CGRect(x: 200, y: 600, width: 30, height: 10)], lines: [CGRect(x: 108, y: 600, width: 396, height: 9)])
  try await Task.sleep(for: .milliseconds(600))
  #expect(pdf.pane.markShown && pdf.markFor?.line == 40)
}

/// ⌘+ / ⌘− / ⌘0 (View ▸ Bigger, Smaller, Actual Size): one point from what the editor shows, kept in 9…28, persisted
/// like the Settings value; then each mode re-lays out (the Neovim grid: neovimModeFontSizeFromSettings).
@MainActor @Test func fontSizeKeysStepAndPersist() throws {
  let suite = "taudot.tests.\(UUID().uuidString)"
  let d = try #require(UserDefaults(suiteName: suite))
  defer { d.removePersistentDomain(forName: suite) }
  let s = TaudotSettings(d)
  s.stepFontSize(by: 1, current: 15)  // unset: from what the editor shows (the guifont's 15)
  #expect(s.fontSize == 16 && TaudotSettings(d).fontSize == 16)
  s.stepFontSize(by: -1, current: 99)  // set: from the setting
  #expect(s.fontSize == 15)
  for _ in 0..<30 { s.stepFontSize(by: 1, current: 0) }
  #expect(s.fontSize == 28)
  for _ in 0..<30 { s.stepFontSize(by: -1, current: 0) }
  #expect(s.fontSize == 9)
  s.resetFontSize()
  #expect(TaudotSettings(d).fontSize == 0)
}

@MainActor @Test(arguments: [true, false]) func nativeModeFontSizeRelaysOut(metal: Bool) async throws {
  let w = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
  let v = NativeEditorView(frame: w.contentView!.bounds, metal: metal)
  w.contentView!.addSubview(v)
  let text = (0..<80).map { "line \($0) some words" }.joined(separator: "\n")
  v.show(NativeDoc(docID: "d", path: "main.tex", text: text, seq: 0, conn: nil), buffer: 1)
  v.layoutSubtreeIfNeeded()
  try await Task.sleep(for: .milliseconds(100))
  let lh0 = v.lineHeight, y0 = try #require(v.y(ofLine: 10))
  var bigger = v.style
  bigger.fontSize += 4
  v.apply(style: bigger)
  v.layoutSubtreeIfNeeded()
  try await Task.sleep(for: .milliseconds(100))
  #expect(v.lineHeight > lh0)
  let y1 = try #require(v.y(ofLine: 10)), y11 = try #require(v.y(ofLine: 11))
  #expect(y11 - y1 > lh0 + 1, "lines 10 and 11 \(y11 - y1) apart, line height \(v.lineHeight) (was at \(y0))")
}
