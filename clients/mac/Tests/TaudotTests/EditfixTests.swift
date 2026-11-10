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

// MARK: an orphaned Neovim never spins (editfix bug 5)

/// Starts Neovim from a shell that then exits (as a crashed app does), its event loop blocked in Lua; returns its pid.
/// Blocked in `vim.uv.sleep` rather than spinning: the same for Neovim (neither the closed pipe nor SIGTERM is seen
/// until Lua returns), without loading a core under the suite's timing checks, and over by itself after 3 s.
func orphanBusyNvim(watchdog: Bool) throws -> pid_t {
  let sh = Process()
  sh.executableURL = URL(fileURLWithPath: "/bin/sh")
  // its stdin stays open until the loop runs, so only our exit can end it (an idle Neovim exits on EOF anyway)
  sh.arguments = ["-c", "sleep 0.4 | \"$0\" --embed --headless --clean -n --cmd \"$1\" -c 'lua vim.uv.sleep(3000)' >/dev/null 2>&1 & echo $!; sleep 0.6",
                  NeovimProcess.findNvim(), watchdog ? "lua " + NeovimProcess.watchdogLua : "lua x = 1"]
  let out = Pipe()
  sh.standardOutput = out
  try sh.run()
  sh.waitUntilExit()
  let s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
  return pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
}

@Test func orphanedNeovimExits() async throws {
  // without the watchdog: still there after its parent (stuck in a loop, the quit tests' leftovers spun at 100% CPU)
  let control = try orphanBusyNvim(watchdog: false)
  #expect(control > 0)
  try await Task.sleep(for: .milliseconds(200))  // its parent exited 0.2 s before the helper returned
  #expect(kill(control, 0) == 0, "the control Neovim should outlive its parent")
  kill(control, SIGKILL)
  // with it: gone within a second of its parent
  let pid = try orphanBusyNvim(watchdog: true)
  #expect(pid > 0)
  var gone = false
  for _ in 0..<50 where !gone { try await Task.sleep(for: .milliseconds(20)); gone = kill(pid, 0) != 0 }
  if !gone { kill(pid, SIGKILL) }
  #expect(gone, "an orphaned Neovim blocked in Lua must exit within a second")
}

// MARK: scrolling a terminal (the Claude pane, editfix bug 6)

/// A view on a Neovim whose only window is a terminal running `cmd`, in Terminal mode, as the Claude pane sets it up.
@MainActor func terminalView(_ cmd: String) async throws -> (Neovim, EditorView) {
  let nv = try Neovim(args: ["--clean", "-n"])
  let v = EditorView(nvim: nv, frame: NSRect(x: 0, y: 0, width: 600, height: 300))
  v.typingResumesTerminal = true
  try await v.attach()
  await editfixWait { v.ui.grids[1]?.width == v.cols }
  _ = try await nv.execLua("vim.cmd.terminal((...)); vim.cmd('startinsert')", [.string(cmd)])
  return (nv, v)
}

@MainActor func termState(_ nv: Neovim) async -> (mode: String, top: Int, last: Int) {
  let a = (try? await nv.execLua("return { vim.api.nvim_get_mode().mode, vim.fn.line('w0'), vim.fn.line('$') }", []))?.array ?? []
  return (a.first?.string ?? "", a.count > 1 ? a[1].int ?? 0 : 0, a.count > 2 ? a[2].int ?? 0 : 0)
}

@Test @MainActor func terminalScrollsBackAndTypingReturns() async throws {
  // 200 lines of output, then a prompt that echoes what's typed (the fake claude)
  let (nv, v) = try await terminalView("seq 1 200; exec cat")
  defer { nv.terminate() }
  var s = await termState(nv)
  for _ in 0..<200 where s.last < 200 { try await Task.sleep(for: .milliseconds(10)); s = await termState(nv) }
  try await Task.sleep(for: .milliseconds(200))
  let bottom = await termState(nv)
  #expect(bottom.mode == "t" && bottom.last >= 200)
  // a trackpad scroll up, over the terminal
  for (dy, phase) in [(40.0, 1 as Int64), (40, 2), (40, 2), (40, 2), (0, 4)] {
    if let e = trackpadEvent(v, dy: dy, phase: phase, momentum: 0) { v.scrollWheel(with: e) }
    try await Task.sleep(for: .milliseconds(30))
  }
  try await Task.sleep(for: .milliseconds(300))
  let up = await termState(nv)
  #expect(up.mode == "nt", "a scroll leaves Terminal mode (mode \(up.mode))")
  #expect(up.top < bottom.top - 3, "earlier lines show (top line \(bottom.top) → \(up.top))")
  // the drawn grid shows them too
  let shown = v.ui.grids.values.flatMap { $0.rows.map(\.text) }.joined(separator: "\n")
  #expect(shown.contains("\n\(up.top + 1)") || shown.contains("\(up.top)\n") || shown.hasPrefix("\(up.top)"), "the grid shows line \(up.top)")
  // typing goes back to the prompt, and the key reaches the program
  v.keyDown(with: keyEvent("x"))
  v.keyDown(with: keyEvent("\r", code: 36))
  try await Task.sleep(for: .milliseconds(300))
  let back = await termState(nv)
  #expect(back.mode == "t", "typing returns to Terminal mode (mode \(back.mode))")
  #expect(back.top >= bottom.top, "and to the bottom (top line \(back.top), was \(bottom.top))")
  let text = (try await nv.execLua("return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\\n')", [])).string ?? ""
  #expect(text.contains("\nx\nx"), "the program got the typed x (echoed by cat): …\(text.suffix(60).debugDescription)")
}

/// A program that asked for the mouse (as full-screen TUIs do) gets the wheel itself; Terminal mode stays.
@Test @MainActor func terminalWheelGoesToAMouseProgram() async throws {
  let (nv, v) = try await terminalView("seq 1 200; printf '\\033[?1000h'; exec cat")
  defer { nv.terminate() }
  try await Task.sleep(for: .milliseconds(500))
  for (dy, phase) in [(40.0, 1 as Int64), (40, 2), (0, 4)] {
    if let e = trackpadEvent(v, dy: dy, phase: phase, momentum: 0) { v.scrollWheel(with: e) }
    try await Task.sleep(for: .milliseconds(30))
  }
  try await Task.sleep(for: .milliseconds(300))
  #expect(await termState(nv).mode == "t")
}
