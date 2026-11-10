import AppKit
import Foundation
import Testing
@testable import TaudotNeovim
@testable import TaudotShared
@testable import TaudotPDF

// MARK: font size in the Neovim mode (editfix bug 1)

@MainActor func editfixWait(_ cond: @escaping () -> Bool) async {
  for _ in 0..<500 where !cond() { try? await Task.sleep(for: .milliseconds(10)) }
}

@Test @MainActor func neovimModeFontSizeFromSettings() async throws {
  let suite = "taudot.tests.\(UUID().uuidString)"
  let d = try #require(UserDefaults(suiteName: suite))
  defer { d.removePersistentDomain(forName: suite) }
  let s = TaudotSettings(d)
  s.editorTheme = "dusk"; s.lineSpace = 0
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
  #expect(v.lineHeight > lh0, "line height \(lh0) → \(v.lineHeight)")
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
