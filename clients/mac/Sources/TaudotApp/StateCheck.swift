// TAUDOT_STATECHECK=FILE (Tests/shell_statefix.sh): the window's state machines from docs/state-machines.md (A1, A2,
// A12…), each driven through its traced sequence in the real window, in the background. TAUDOT_STATECHECK_ONLY=A12,A1
// runs a subset. Lines start with "ok" or "FAIL" and the item's id.
import AppKit
import TaudotNeovim
import TaudotPDF

@MainActor final class StateCheck {
  /// Only the first window runs it (A4 opens another).
  static var started = false
  static func claim() -> Bool { defer { started = true }; return !started }
  let p: ProjectWindow
  let out: URL
  var lines: [String] = []
  init(_ p: ProjectWindow, out: URL) { self.p = p; self.out = out }
  func sleep(_ s: Double) async { try? await Task.sleep(for: .milliseconds(Int(s * 1000))) }
  func check(_ id: String, _ ok: Bool, _ what: String) { lines.append("\(ok ? "ok  " : "FAIL") \(id) \(what)") }
  func wait(_ s: Double, _ f: () -> Bool) async { var t = 0.0; while !f() && t < s { await sleep(0.05); t += 0.05 } }
  var fr: NSResponder? { p.window.firstResponder }
  var only: Set<String>? {
    ProcessInfo.processInfo.environment["TAUDOT_STATECHECK_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
  }
  func wants(_ id: String) -> Bool { only?.contains(id) ?? true }

  func run() async {
    await wait(30) { p.editorStarted }
    check("--", p.editorStarted, "editor started (\(p.mode))")
    if wants("A12") { await a12() }
    if wants("A1") { await a1() }
    if wants("A2") { await a2() }
    // (last: it may leave this window's editor stopped)
    if wants("A11") { await a11() }
    if wants("A15") { await a15() }
    if wants("A10") { await a10() }
    if wants("A13") { await a13() }
    if wants("A14") { await a14() }
    if wants("A17") { await a17() }
    if wants("A25") { a25() }
    if wants("A26") { await a26() }
    if wants("A6") { await a6() }
    if wants("A4") { await a4() }
    try? (lines.joined(separator: "\n") + "\n").write(to: out, atomically: true, encoding: .utf8)
    NSApp.terminate(nil)
  }

  /// A12: while History's read-only diff covers the editor, nothing gives the hidden live editor the keys: ⌘2, an
  /// issue row, a comment clicked on the PDF, inverse search, the margin giving the keys back. Those that move the
  /// editor's cursor leave History (the editor shows again, with the keys); ⌘2 gives the keys to the diff.
  func a12() async {
    guard p.history != nil else { check("A12", false, "history wired"); return }
    /// The bug: the editor has the keys while the diff covers it.
    func invisible() -> Bool { p.historyCoversEditor && fr === p.editorResponder }
    func enter() async {
      p.showSidebarHistory(nil)
      await wait(2) { p.historyCoversEditor }
      await sleep(0.1)  // HistoryPane focuses its table one turn after it takes the keys
    }
    func step(_ what: String, _ act: () -> Void) async {
      await enter()
      guard p.historyCoversEditor else { check("A12", false, "\(what): History not open"); return }
      act()
      let now = fr.map { String(describing: type(of: $0)) } ?? "nil"
      let early = invisible()
      await sleep(0.3)
      let covered = p.historyCoversEditor
      check("A12", !early && !invisible() && (covered || fr === p.editorResponder),
            "\(what): \(covered ? "History open" : "History left"), keys to \(now) then \(fr.map { String(describing: type(of: $0)) } ?? "nil")")
    }
    await step("⌘2") { _ = pressMenu(p, "2") }
    await step("issue row") { p.jump(to: TeXIssue(.error, file: p.mainFile, line: 3, message: "Undefined control sequence")) }
    await step("comment clicked on the PDF") { p.pdf.onCommentClick?("statecheck") }
    await step("inverse search") { p.pdf.onInverseSearchWord?(p.mainFile ?? "main.tex", 2, nil) }
    await step("⌥⌘↓ next comment") { p.nextComment(nil) }
    await step("the margin gives the keys back") { p.margin.onFocusEditor?() }
    // ⌘2 then typing: the live text must not change under the diff.
    await enter()
    if p.historyCoversEditor, p.native == nil {
      let before = (try? await p.nvim.execLua("return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\\n')", []))?.string
      _ = pressMenu(p, "2")
      await sleep(0.2)
      if let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: p.window.windowNumber,
                                   context: nil, characters: "ix", charactersIgnoringModifiers: "ix", isARepeat: false, keyCode: 34) {
        p.window.sendEvent(ev)
      }
      await sleep(0.4)
      let after = (try? await p.nvim.execLua("return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\\n')", []))?.string
      check("A12", before == after, "⌘2 then typing under the diff leaves the live text alone (\(before?.prefix(30) ?? "nil") → \(after?.prefix(30) ?? "nil"), keys to \(fr.map { String(describing: type(of: $0)) } ?? "nil"))")
      p.nvim.input("<Esc>u")
    }
    p.leaveHistory()
    await sleep(0.3)
  }

  /// A1: the Claude panel's fade vs ⌘J. Whoever has the keys can be seen: ⌘J twice within the 160 ms fade shows the
  /// panel again (not a fading panel that keeps the keyboard); a fade overtaken by docking and showing again doesn't
  /// hide the docked pane when it ends.
  func a1() async {
    p.setClaudeMode(docked: false)
    func keysVisible() -> Bool {
      guard let c = p.claude, fr === c.view else { return true }
      return p.claudeShown && !c.view.isHiddenOrHasHiddenAncestor
    }
    func state() -> String {
      guard let c = p.claude else { return "no claude" }
      let keys = fr === c.view ? "claude" : fr.map { String(describing: type(of: $0)) } ?? "nil"
      return "shown \(p.claudeShown) fading \(p.claudeFading) view hidden \(c.view.isHiddenOrHasHiddenAncestor) keys \(keys)"
    }
    p.toggleClaude(nil)
    await wait(5) { p.claudeShown && fr === p.claude?.view }
    await sleep(0.4)
    check("A1", p.claudeShown && fr === p.claude?.view, "⌘J shows the floating panel with the keys (\(state()))")
    p.toggleClaude(nil)
    await sleep(0.05)
    p.toggleClaude(nil)
    await sleep(0.5)
    check("A1", keysVisible() && p.claudeShown, "⌘J twice within the fade: shown again, with the keys (\(state()))")
    // Hide (fade running), dock, show: the old fade's end must not hide the docked pane.
    p.toggleClaude(nil)
    await sleep(0.03)
    p.setClaudeMode(docked: true)
    p.focus(pane: 3)
    await sleep(0.5)
    check("A1", keysVisible() && p.claudeShown && p.dockedNow, "hide, dock, show within the fade: the docked pane stays (\(state()))")
    p.setClaudeMode(docked: false)
    if p.claudeShown { p.toggleClaude(nil) }
    await sleep(0.4)
    check("A1", keysVisible(), "hidden at the end, keys not in it (\(state()))")
  }

  /// A2: a pane animation overtaken by another (two toggles within its 200 ms) still ends: the first one's pane is
  /// hidden, not left "visible" at width 0 and unfocusable; a zoom taken mid-animation restores the end state.
  func a2() async {
    func layout() -> String {
      "sidebar \(p.sidebar.isHidden ? "hidden" : "\(Int(p.sidebar.frame.width))") pdf \(p.pdf.view.isHidden ? "hidden" : "\(Int(p.pdf.view.frame.width))") hiding \(p.panesHiding.sorted())"
    }
    if p.sidebar.isHidden { p.setPane(p.sidebar, hidden: false, animated: false) }
    if p.pdf.view.isHidden { p.setPane(p.pdf.view, hidden: false, animated: false) }
    await sleep(0.3)
    check("A2", !p.sidebar.isHidden && !p.pdf.view.isHidden, "start: three panes (\(layout()))")
    let full = p.pdf.view.frame.width
    // Hide the sidebar, and 50 ms later the PDF.
    p.setPane(p.sidebar, hidden: true)
    await sleep(0.05)
    p.setPane(p.pdf.view, hidden: true)
    await sleep(0.5)
    check("A2", p.sidebar.isHidden && p.pdf.view.isHidden && p.panesHiding.isEmpty,
          "two hides within the animation: both hidden, nothing left hiding (\(layout()))")
    // Back: the sidebar must be focusable again.
    p.setPane(p.sidebar, hidden: false)
    await sleep(0.4)
    p.focus(pane: 0)
    check("A2", p.focusable(0) && p.focusedPane == 0, "the sidebar shown again takes the focus (\(layout()))")
    // A zoom mid-animation: the PDF opening, ⌘E 50 ms in, ⌘E again: the PDF back at its full width.
    p.focus(pane: 1)
    p.setPane(p.pdf.view, hidden: false)
    await sleep(0.05)
    p.toggleZoom(nil)
    await sleep(0.4)
    p.toggleZoom(nil)
    await sleep(0.4)
    check("A2", !p.pdf.view.isHidden && abs(p.pdf.view.frame.width - full) <= 2 && p.panesHiding.isEmpty,
          "⌘E during an animation, then ⌘E: the PDF at its full width, \(Int(full)) (\(layout()))")
  }

  /// A4: ⌘Q cancelled in one window leaves every window as it was: none open with its editor already stopped.
  /// A second window on the same folder with a modified scratch buffer; the save question answered Cancel.
  func a4() async {
    guard let app = NSApp.delegate as? AppDelegate else { check("A4", false, "app delegate"); return }
    setenv("TAUDOT_EDITOR_MODE", "neovim", 1)  // the second window asks (a Neovim one with a modified scratch buffer)
    app.open(p.folder)
    guard let q = app.projects.last, q !== p else { check("A4", false, "a second window"); return }
    await wait(30) { q.editorStarted }
    guard q.editorStarted else { check("A4", false, "second window's editor started"); return }
    if q.native == nil { try? await q.nvim.command("enew | call setline(1, 'not saved')") }
    setenv("TAUDOT_QUIT_ANSWER", "cancel", 1)
    _ = app.applicationShouldTerminate(NSApp)
    await sleep(3)
    func live(_ w: ProjectWindow) -> String {
      let up = w.native.map { _ in !w.closing } ?? (w.nvim.isRunning && !w.closing)
      return w.window.isVisible ? (up ? "open, editor up" : "OPEN WITH ITS EDITOR STOPPED") : "closed"
    }
    let states = [p, q].map(live)
    check("A4", states.allSatisfy { $0 == "open, editor up" } && !app.quitting,
          "⌘Q cancelled in the second window, all as they were (\(p.mode), \(q.mode)): \(states.joined(separator: ", "))")
    // Let the end of the check quit.
    setenv("TAUDOT_QUIT_ANSWER", "discard", 1)
  }

  /// A11: the issues list's settle timer. A run with a new error, then a provisional pass ("Rerun to get…") with
  /// nothing new: the error still shows when the wait ends, and BibTeX's list isn't blocked after. A restart forgets
  /// that the old process had a log.
  func a11() async {
    let m = IssuesModel()
    m.settle = 0.2
    m.rerunWait = 0.3
    m.summary("main.tex:3: Undefined control sequence.")
    m.runDone()
    m.summary("Label(s) may have changed. Rerun to get cross-references right.")
    m.runDone()
    await sleep(0.8)
    check("A11", m.shown.contains { $0.message.hasPrefix("Undefined control sequence") },
          "a new error, then a rerun pass with nothing new: the error shows (\(m.shown.map(\.message)))")
    m.bibIssues([BibTeXIssue(severity: .warning, message: "I didn't find a database entry for \"knuth\"", key: "knuth")])
    check("A11", m.shown.contains { $0.message.contains("knuth") }, "BibTeX's list shows after (\(m.shown.count) issues)")
    m.driverLine("[\"append-lines\", \"log\", \"This is pdfTeX\"]")
    let had = m.hasLog
    m.restarted()
    check("A11", !m.hasLog, "a restart forgets the old log (had one: \(had))")
  }

  /// A15: the Claude panel's dock/undock morph overtaken: the last request wins (dock, then float 50 ms later: it
  /// floats, at its floating place, its grid no longer held); ⌘J during a morph hides it for good.
  func a15() async {
    p.setClaudeMode(docked: false)
    p.focus(pane: 3)
    await wait(5) { p.claudeShown }
    await sleep(0.5)
    guard let c = p.claude else { check("A15", false, "claude started"); return }
    func state() -> String {
      "docked \(p.dockedNow) shown \(p.claudeShown) float hidden \(p.claudeFloat.isHidden) frame \(p.claudeFloat.frame.integral) want \(p.claudeFloat.frameFor(p.editorBox.bounds).integral) held \(c.view.holdGridSize)"
    }
    p.morphClaude(docked: true)
    await sleep(0.05)
    p.morphClaude(docked: false)
    await sleep(0.6)
    let want = p.claudeFloat.frameFor(p.editorBox.bounds)
    check("A15", !p.dockedNow && p.claudeShown && !p.claudeFloat.isHidden && p.claudeFloat.frame.integral == want.integral && !c.view.holdGridSize,
          "dock then float within the morph: floating (\(state()))")
    p.morphClaude(docked: true)
    await sleep(0.05)
    p.toggleClaude(nil)
    await sleep(0.6)
    check("A15", !p.claudeShown && c.view.isHiddenOrHasHiddenAncestor && !c.view.holdGridSize,
          "⌘J during the dock morph: hidden (\(state()))")
    p.setClaudeMode(docked: false)
    p.focus(pane: 1)
  }

  /// A10: Claude exiting while its pane is zoomed (⌘E) unzooms without starting a fresh, hidden claude.
  func a10() async {
    p.setClaudeMode(docked: false)
    p.focus(pane: 3)
    await wait(5) { p.claude?.exited == false && p.claudeShown }
    await sleep(0.5)
    guard let c0 = p.claude, let job = await c0.job() else { check("A10", false, "claude started"); return }
    p.toggleZoom(nil)
    await sleep(0.4)
    check("A10", p.zoom != nil && p.zoom?.pane == 1, "the Claude pane zoomed")
    kill(pid_t(job.pid), SIGTERM)  // the fake claude this run started
    await wait(5) { c0.exited }
    await sleep(1)
    let same = p.claude === c0
    check("A10", c0.exited && same && !p.claudeShown && p.zoom == nil,
          "claude exited while zoomed: unzoomed, no new claude (\(same ? "same pane" : "A NEW CLAUDE STARTED"), shown \(p.claudeShown), zoom \(p.zoom != nil))")
    // Zoomed on Neovim (the zoom hides Claude, to show it again on the way back); claude exits; ⌘E.
    p.focus(pane: 3)
    await wait(5) { p.claude?.exited == false && p.claudeShown }
    await sleep(0.5)
    guard let c1 = p.claude, let job1 = await c1.job() else { check("A10", false, "claude restarted by ⌘J"); return }
    p.focus(pane: 1)
    p.toggleZoom(nil)
    await sleep(0.4)
    kill(pid_t(job1.pid), SIGTERM)
    await wait(5) { c1.exited }
    await sleep(0.5)
    p.toggleZoom(nil)
    await sleep(1)
    let started = p.claude !== c1
    check("A10", !started && !p.claudeShown,
          "claude exited during a Neovim zoom, then ⌘E: \(started ? "A NEW CLAUDE STARTED" : "no new claude") (shown \(p.claudeShown))")
    p.focus(pane: 1)
  }

  /// A13: ⌘W twice (or ⌘W then ⌘Q) while the save question is up: one quit flow, one question.
  func a13() async {
    guard p.native == nil else { check("A13", true, "(native windows ask nothing)"); return }
    let b = (try? await p.nvim.execLua(
      "local b = vim.api.nvim_create_buf(true, false); vim.api.nvim_buf_set_lines(b, 0, -1, false, {'not saved'}); return b", []))?.int
    setenv("TAUDOT_QUIT_ANSWER", "cancel", 1)
    setenv("TAUDOT_QUIT_ANSWER_DELAY", "0.6", 1)
    p.asksMost = 0
    p.window.performClose(nil)
    await sleep(0.1)
    p.window.performClose(nil)
    await sleep(0.1)
    if let app = NSApp.delegate as? AppDelegate { _ = app.applicationShouldTerminate(NSApp) }
    await sleep(2)
    check("A13", p.asksMost == 1 && !p.closing && p.window.isVisible,
          "⌘W, ⌘W, ⌘Q within the question: \(p.asksMost) question(s) at once, window \(p.closing ? "closing" : "open")")
    unsetenv("TAUDOT_QUIT_ANSWER_DELAY")
    setenv("TAUDOT_QUIT_ANSWER", "discard", 1)
    if let b { _ = try? await p.nvim.execLua("vim.api.nvim_buf_delete(\(b), { force = true })", []) }
  }

  /// A14: Settings ▸ Reopen Windows in This Mode, the save question answered Cancel: the window stays as it is and
  /// no second window (in the other mode) opens on its folder.
  func a14() async {
    guard p.native == nil, let app = NSApp.delegate as? AppDelegate else { check("A14", true, "(needs a Neovim window)"); return }
    let b = (try? await p.nvim.execLua(
      "local b = vim.api.nvim_create_buf(true, false); vim.api.nvim_buf_set_lines(b, 0, -1, false, {'not saved'}); return b", []))?.int
    let before = app.projects.count
    setenv("TAUDOT_QUIT_ANSWER", "cancel", 1)
    setenv("TAUDOT_EDITOR_MODE", "native", 1)
    TaudotSettings.shared.editorMode = "native"
    app.reopenInEditorMode()
    await sleep(3)
    let extra = app.projects.filter { $0 !== p }
    check("A14", app.projects.count == before && !p.closing,
          "reopen in native mode, Cancel: \(app.projects.count) window(s) (\(app.projects.map(\.mode).joined(separator: ", ")))")
    for q in extra { q.closing = true; q.native?.stop(); q.window.close() }
    TaudotSettings.shared.editorMode = "neovim"
    setenv("TAUDOT_EDITOR_MODE", "neovim", 1)
    setenv("TAUDOT_QUIT_ANSWER", "discard", 1)
    if let b { _ = try? await p.nvim.execLua("vim.api.nvim_buf_delete(\(b), { force = true })", []) }
  }

  /// A17: a window opened (from Finder, the command line) while the launch's `service ensure` still runs waits for
  /// it before touching the engine, which that may restart. The ensure is a 1.5 s stand-in here.
  func a17() async {
    guard let app = NSApp.delegate as? AppDelegate else { check("A17", false, "app delegate"); return }
    let saved = ProjectWindow.engineReady
    ProjectWindow.engineReady = Task.detached { try? await Task.sleep(for: .seconds(1.5)); return "ok" }
    setenv("TAUDOT_EDITOR_MODE", "neovim", 1)
    unsetenv("TAUDOT_NO_PDF")
    app.open(p.folder)
    guard let q = app.projects.last, q !== p else { check("A17", false, "a second window"); return }
    await sleep(0.5)
    let early = q.engineTouched
    await wait(10) { q.editorStarted }
    check("A17", !early && q.engineTouched && q.editorStarted,
          "a window opened during the ensure waits for it (touched the engine before: \(early); started after: \(q.editorStarted))")
    ProjectWindow.engineReady = saved
    setenv("TAUDOT_NO_PDF", "1", 1)
    q.closing = true
    q.nvim?.terminate()
    q.window.close()
  }

  /// A25: a crash report still being written when the app starts again (only its header line so far) isn't marked
  /// seen: the next launch shows it once it's whole.
  func a25() {
    let dir = p.folder.deletingLastPathComponent().appendingPathComponent("crash-a25")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    setenv("TAUDOT_CRASH_DIR", dir.path, 1)
    defer { unsetenv("TAUDOT_CRASH_DIR"); UserDefaults.standard.removeObject(forKey: CrashReport.seenKey) }
    UserDefaults.standard.set("taudot-app-2000-01-01-000000.ips", forKey: CrashReport.seenKey)
    let f = dir.appendingPathComponent("taudot-app-2026-11-06-230000.ips")
    try? "{\"app_name\":\"taudot-app\"}\n".write(to: f, atomically: true, encoding: .utf8)
    let first = CrashReport.next()
    try? "{\"app_name\":\"taudot-app\"}\n{\"captureTime\":\"2026-11-06 23:00:00\",\"exception\":{\"type\":\"EXC_CRASH\",\"signal\":\"SIGABRT\"}}\n"
      .write(to: f, atomically: true, encoding: .utf8)
    let second = CrashReport.next()
    check("A25", first == nil && second?.text.contains("SIGABRT") == true,
          "a half-written report: not shown \(first == nil ? "" : "(SHOWN?)")then shown when whole (\(second == nil ? "LOST" : "shown"))")
  }

  /// A26: a window closed while its grow animation runs leaves no card behind (off screen here: the window and the
  /// row's rect are right of every screen).
  func a26() async {
    guard let app = NSApp.delegate as? AppDelegate else { check("A26", false, "app delegate"); return }
    setenv("TAUDOT_EDITOR_MODE", "neovim", 1)
    for closeAfter in [0.0, 0.1, 0.33] {
      app.open(p.folder)
      guard let q = app.projects.last, q !== p else { check("A26", false, "a second window"); return }
      await sleep(0.3)
      let r = NSRect(origin: q.window.frame.origin, size: NSSize(width: 300, height: 40))
      q.grow(from: r)
      guard let c = q.growCard else { check("A26", false, "a card"); return }
      await sleep(closeAfter)
      q.closing = true
      q.window.close()
      await sleep(0.8)
      check("A26", !c.isVisible, "closed \(Int(closeAfter * 1000)) ms into the grow: card \(c.isVisible ? "STILL SHOWN" : "gone")")
      c.orderOut(nil)
    }
  }

  /// A6: a window closed while it starts does nothing more: a fresh folder's window waiting for its main file, closed,
  /// then the file appears: no PDF pane opened (a typesetter nobody stops), no commands to its gone editor.
  func a6() async {
    guard let app = NSApp.delegate as? AppDelegate else { check("A6", false, "app delegate"); return }
    let fresh = p.folder.deletingLastPathComponent().appendingPathComponent("fresh-a6")
    try? FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
    setenv("TAUDOT_EDITOR_MODE", "neovim", 1)
    app.open(fresh)
    guard let q = app.projects.last, q !== p else { check("A6", false, "a second window"); return }
    await wait(10) { q.emptyState != nil }
    await sleep(1)
    q.window.performClose(nil)
    await wait(5) { q.closing }
    check("A6", q.closing, "the waiting window closes")
    try? "\\documentclass{article}\\begin{document}x\\end{document}\n".write(
      to: fresh.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
    await sleep(2.5)
    check("A6", q.pdf.folder == nil && q.mainFile == nil,
          "its main file appearing after the close opens nothing (pdf \(q.pdf.folder?.lastPathComponent ?? "none"), main \(q.mainFile ?? "none"))")
  }
}
