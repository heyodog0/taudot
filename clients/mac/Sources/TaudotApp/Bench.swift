// A short measured run (TAUDOT_BENCH=<output file>): a long scratch buffer, <C-d> scrolling, synthetic trackpad
// gestures with momentum, typing. Events go straight to the editor view, so it works without taking focus.
import AppKit
import TaudotReview
import TaudotNeovim
import TaudotEditor
import TaudotPDF
import TaudotShared

@MainActor final class Bench {
  let p: ProjectWindow
  let out: URL
  var report = ""

  init(_ p: ProjectWindow, out: URL) { self.p = p; self.out = out }

  func sleep(_ s: Double) async { try? await Task.sleep(for: .milliseconds(Int(s * 1000))) }

  func section(_ name: String) {
    report += "## \(name)\n\(p.editor.stats.summary())\nreasons \(p.editor.debugReasons) occlusion visible \(p.window.occlusionState.contains(.visible))\n\n"
    p.editor.debugReasons = [:]
    p.editor.stats.reset()
  }

  func scroll(_ dy: Double, phase: Int64, momentum: Int64) {
    guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(dy.rounded()), wheel2: 0, wheel3: 0) else { return }
    e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    e.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
    e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
    e.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: dy)
    e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: dy)
    let v: EditorView = p.editor
    let mid = v.window!.convertPoint(toScreen: v.convert(NSPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil))
    let primary = NSScreen.screens.first!.frame.height
    e.location = CGPoint(x: mid.x, y: primary - mid.y)
    if let ns = NSEvent(cgEvent: e) { v.scrollWheel(with: ns) }
  }

  /// One gesture: `n` finger events of `dy` points at 120 Hz, then momentum decaying from `dy`.
  func gesture(dy: Double, n: Int, momentum: Bool) async {
    scroll(0, phase: 128, momentum: 0)  // may-begin
    scroll(dy, phase: 1, momentum: 0)
    for _ in 0..<n { await sleep(1.0 / 120); scroll(dy, phase: 2, momentum: 0) }
    scroll(0, phase: 4, momentum: 0)
    if momentum {
      var m = dy
      scroll(m, phase: 0, momentum: 1)
      while abs(m) > 0.5 { await sleep(1.0 / 120); m *= 0.95; scroll(m, phase: 0, momentum: 2) }
      scroll(0, phase: 0, momentum: 3)
    }
    await sleep(0.4)
  }

  /// One mouse-wheel notch (line units, not continuous).
  func wheel(_ lines: Int32) {
    guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0) else { return }
    let v: EditorView = p.editor
    let mid = v.window!.convertPoint(toScreen: v.convert(NSPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil))
    e.location = CGPoint(x: mid.x, y: NSScreen.screens.first!.frame.height - mid.y)
    if let ns = NSEvent(cgEvent: e) { v.scrollWheel(with: ns) }
  }

  func key(_ chars: String, code: UInt16 = 0) {
    guard let w = p.window as NSWindow?,
          let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: w.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                   isARepeat: false, keyCode: code) else { return }
    p.editor.keyDown(with: e)
  }

  func run() async {
    let v: EditorView = p.editor, nv: Neovim = p.nvim
    while !v.attached { await sleep(0.1) }
    // Frames are only presented (and timed) while the window is on screen: bring it forward for the run.
    await sleep(1.5)
    report += "# taudot-app bench \(Date())\nscreen max fps \(v.window?.screen?.maximumFramesPerSecond ?? 0), grid \(v.cols)x\(v.rows), "
    report += "view \(Int(v.bounds.width))x\(Int(v.bounds.height)) pt, backing scale \(v.window?.backingScaleFactor ?? 0)\n\n"
    // A long scratch buffer (not a project file) with LaTeX-ish lines, some wrapping.
    _ = try? await nv.execLua("""
      vim.cmd('enew'); vim.bo.buftype = 'nofile'; vim.bo.filetype = 'tex'
      local words = {'the','\\\\emph{grid}','model','scrolls','by','pixels','$x^2$','and','\\\\cite{knuth}','smoothly','at','120','Hz'}
      local lines = {}
      for i = 1, 4000 do
        local n = (i * 7) % 23 + (i % 50 == 0 and 60 or 0)
        local t = {}
        for k = 1, n do t[#t + 1] = words[(i + k) % #words + 1] end
        lines[i] = (i % 40 == 0) and ('\\\\section{Part ' .. i .. '}') or table.concat(t, ' ')
      end
      vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
      """, [])
    await sleep(0.5)
    v.stats.reset()

    for _ in 0..<16 { v.nvim.input("<C-d>"); await sleep(0.3) }
    for _ in 0..<8 { v.nvim.input("<C-u>"); await sleep(0.3) }
    section("<C-d>/<C-u> every 300 ms (spring animation)")

    for _ in 0..<12 { v.nvim.input("<C-e>"); await sleep(0.05) }
    await sleep(0.4)
    section("<C-e> every 50 ms (retargeting mid-flight)")

    await gesture(dy: -6, n: 60, momentum: false)
    await gesture(dy: 5, n: 40, momentum: false)
    section("trackpad, slow drags (6 pt/event at 120 Hz)")

    await gesture(dy: -30, n: 20, momentum: true)
    await gesture(dy: 25, n: 15, momentum: true)
    section("trackpad, flicks with momentum")

    // Geometry while scrolling: sample y of the current top line over one <C-d>.
    var samples: [CGFloat] = []
    let top = v.visibleLines.lowerBound + 5
    v.onChange { if let y = v.y(ofLine: top), samples.last != y { samples.append(y) } }
    v.nvim.input("<C-d>")
    await sleep(0.5)
    report += "## EditorGeometry during one <C-d>\nline \(top): \(samples.count) distinct y values, first \(samples.first ?? -1), last \(samples.last ?? -1) pt\n\n"

    _ = try? await nv.command("normal! Go")
    try? await nv.command("startinsert")
    await sleep(0.3)
    v.stats.reset()
    for c in "the quick brown fox jumps over the lazy dog and keeps on typing" { key(String(c)); await sleep(0.08) }
    await sleep(0.3)
    section("typing, a key every 80 ms (key event → frame presented)")
    let line = (try? await nv.execLua("return vim.api.nvim_get_current_line()", []))?.string ?? ""
    report += "typed line: \(line)\n"
    try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? report.write(to: out, atomically: true, encoding: .utf8)
    try? await nv.command("qall!")
  }
}

/// TAUDOT_WIRECHECK=<file>: check the wiring in the running app (SyncTeX both ways, pane toggles) and write a report.
@MainActor final class WireCheck {
  let p: ProjectWindow
  let out: URL
  var lines: [String] = []
  init(_ p: ProjectWindow, out: URL) { self.p = p; self.out = out }
  func log(_ s: String) { lines.append(s) }
  func sleep(_ s: Double) async { try? await Task.sleep(for: .milliseconds(Int(s * 1000))) }

  func run() async {
    let nv: Neovim = p.nvim
    for _ in 0..<200 where p.pdf.syncTex == nil { await sleep(0.1) }
    log("synctex ready: \(p.pdf.syncTex != nil)")
    // Neovim → PDF: put the cursor on a line; cursor-follow should send taudot_app_cursor main.tex <line>.
    var got: (String, Int)?
    nv.notify("taudot_app_cursor") { a in got = (a[0].string ?? "", a[1].int ?? 0) }
    _ = try? await nv.execLua("vim.api.nvim_win_set_cursor(0, {31, 0})", [])
    for _ in 0..<40 where got == nil { await sleep(0.05) }
    log("cursor-follow: \(got.map { "\($0.0):\($0.1)" } ?? "nothing")  (want main.tex:31)")
    got = nil
    _ = try? await nv.execLua("vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<leader>av', true, false, true), 'm', false)", [])
    for _ in 0..<40 where got == nil { await sleep(0.05) }
    log("<leader>av forced: \(got.map { "\($0.0):\($0.1)" } ?? "nothing")")
    let fwd = p.pdf.syncTex?.forward(file: "main.tex", line: 31)
    log("forward main.tex:31 → \(fwd.map { "page \($0.page) y \(Int($0.y))" } ?? "none")")
    // PDF → Neovim: what a double-click at that spot reports, sent through the same handler.
    if let f = fwd, let inv = p.pdf.inverse(page: f.page, x: f.x + 5, y: f.y + f.h / 2) {
      log("inverse at that spot → \(inv.path):\(inv.line)")
      _ = try? await nv.execLua("vim.api.nvim_win_set_cursor(0, {1, 0})", [])
      p.pdf.onInverseSearch?(inv.path, inv.line)
      await sleep(0.3)
      let cur = (try? await nv.execLua("return {vim.fn.expand('%:t'), vim.api.nvim_win_get_cursor(0)[1]}", []))?.array
      log("after the double-click Neovim is at \(cur?[0].string ?? "?"):\(cur?[1].int ?? -1)")
    }
    // Toggles (margin shown first, so all three panes take part).
    p.setPane(p.sidebar, hidden: false)
    await sleep(0.2)
    let w0 = (p.sidebar.frame.width, p.editorBox.frame.width, p.pdf.view.frame.width)
    p.togglePDF(nil); await sleep(0.2)
    log("⌘\\ → pdf hidden \(p.pdf.view.isHidden), editor \(Int(w0.1)) → \(Int(p.editorBox.frame.width)) pt")
    p.togglePDF(nil); await sleep(0.2)
    log("⌘\\ again → pdf hidden \(p.pdf.view.isHidden), widths \(Int(p.sidebar.frame.width))/\(Int(p.editorBox.frame.width))/\(Int(p.pdf.view.frame.width)) (before \(Int(w0.0))/\(Int(w0.1))/\(Int(w0.2)))")
    p.toggleMargin(nil); await sleep(0.2)
    log("⌘⇧\\ → margin hidden \(p.sidebar.isHidden)")
    p.toggleMargin(nil); await sleep(0.2)
    log("⌘⇧\\ again → margin hidden \(p.sidebar.isHidden), widths \(Int(p.sidebar.frame.width))/\(Int(p.editorBox.frame.width))/\(Int(p.pdf.view.frame.width))")
    p.savePanes()
    try? (lines.joined(separator: "\n") + "\n").write(to: out, atomically: true, encoding: .utf8)
    try? await p.nvim.command("qall!")  // the run is over: close the window (the app quits with it)
  }
}

/// TAUDOT_SCROLLTRACE=<file>: trackpad flicks and drags through the whole buffer and back, per frame: Neovim's
/// topline, the view's offset, and how far the visible lines moved since the last frame (against the gesture = a
/// bounce). Then <C-d>/<C-u> and the mouse wheel.
@MainActor final class ScrollTrace {
  let p: ProjectWindow
  var markerFrames = 0, markerNeovim = 0
  let out: URL
  var rows: [String] = []
  var report: [String] = []
  var lastYs: [Int: CGFloat] = [:]
  var dir = 0            // the current gesture's direction: +1 down (content up), -1 up
  var phase = ""
  var against = 0, frames = 0, maxAgainst: CGFloat = 0
  init(_ p: ProjectWindow, out: URL) { self.p = p; self.out = out }
  func sleep(_ s: Double) async { try? await Task.sleep(for: .milliseconds(Int(s * 1000))) }

  var lastPos: Double?
  var lastBlank = 0
  var stale = 0, settledChecks = 0
  /// Frames where the cursor was drawn away from its cell as the content draws it (gliding on its own while the text
  /// scrolls), the largest distance, and how often Neovim moved it to another line.
  var cursorOff = 0, cursorMax = 0.0, cursorHops = 0, lastCursorAbs: Int?

  /// Each rendered frame: the median movement of rows drawn in both this frame and the last.
  func sample() {
    let v: EditorView = p.editor
    // How far the content moved on screen this frame, from the view's position (which is what render() draws
    // from). Following rows by version can't work: Neovim leaves rows whose text didn't change, so a blank line in the
    // same screen row keeps its version though it is another line of the text.
    guard let pos = v.scrolls[v.currentGrid]?.position else { return }
    defer { lastPos = pos }
    guard let last = lastPos else { return }
    let m = -CGFloat(pos - last) * v.lineHeight
    frames += 1
    let wrong = dir > 0 ? m : dir < 0 ? -m : 0
    if wrong > 0.5 { against += 1; maxAgainst = max(maxAgainst, wrong) }
    defer { lastBlank = v.debugBlankRows }
    // Neovim's smoothscroll marker must never be drawn (it used to be copied into other rows on fast flicks).
    if v.debugDrawn.contains(where: { $0.1.hasPrefix("<<<") && !$0.1.hasPrefix("<<<<") }) { markerFrames += 1 }
    if v.gridRowsRaw(grid: v.currentGrid).contains(where: { $0.hasPrefix("<<<") && !$0.hasPrefix("<<<<") }) { markerNeovim += 1 }
    var cur = ""
    if let c = v.debugCursor {
      let d = max(abs(c.offY), abs(c.offX))
      if d > 0.5 { cursorOff += 1; cursorMax = max(cursorMax, d) }
      if let l = lastCursorAbs, l != c.abs { cursorHops += 1 }
      lastCursorAbs = c.abs
      cur = String(format: " cursor %d off %.1f,%.1f%@", c.abs, c.offX, c.offY, d > 0.5 ? " CURSOR-OFF" : "")
    }
    let s = v.scrolls[v.currentGrid]
    rows.append(String(format: "%@ %.3f top %d pos %.2f off %.2f finger %.2f dy %.1f blank %d%@", phase, CACurrentMediaTime(),
                       v.visibleLines.lowerBound, s?.position ?? 0, s?.offset ?? 0, s?.finger ?? 0, m, v.debugBlankRows - lastBlank, wrong > 0.5 ? " AGAINST" : "") + cur)
  }

  /// After a gesture: once settled, the drawn rows must be Neovim's.
  func checkSettled() async {
    let v: EditorView = p.editor
    for _ in 0..<100 where !v.scrollSettled(grid: v.currentGrid) { await sleep(0.02) }
    await sleep(0.05)
    settledChecks += 1
    let d = v.drawnRows(grid: v.currentGrid), g = v.gridRows(grid: v.currentGrid)
    if d != g || !v.scrollSettled(grid: v.currentGrid) {
      stale += 1
      if stale <= 3 { rows.append("STALE: drawn \(d.count) rows vs grid \(g.count); first difference at \(zip(d, g).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? -1)") }
    }
  }

  func section(_ name: String) {
    report.append("\(name): \(frames) frames, \(against) moved against the gesture (max \(String(format: "%.1f", maxAgainst)) pt), " +
                  "blank rows drawn \(p.editor.debugBlankRows), " + "settled checks \(settledChecks), drawn ≠ Neovim \(stale), " +
                  "top line \(p.editor.visibleLines.lowerBound) of \(p.editor.ui.windows[p.editor.currentGrid]?.lineCount ?? 0), " +
                  "snap-backs \(p.editor.debugSnapBacks)" +
                  ", cursor off its cell \(cursorOff) frames (max \(String(format: "%.1f", cursorMax)) pt), cursor moved to another line \(cursorHops) times" +
                  ", <<< drawn \(markerFrames) frames (Neovim had it in \(markerNeovim))")
    markerFrames = 0; markerNeovim = 0
    frames = 0; against = 0; maxAgainst = 0; cursorOff = 0; cursorMax = 0; cursorHops = 0; stale = 0; settledChecks = 0; p.editor.debugSnapBacks = 0; p.editor.debugBlankRows = 0; lastBlank = 0
  }

  func run() async {
    let v: EditorView = p.editor
    while !v.attached { await sleep(0.1) }
    await sleep(2)
    v.traceRows = true
    v.onFrameRendered = { [weak self] in self?.sample() }
    let b = Bench(p, out: out)
    let n = v.ui.windows[v.currentGrid]?.lineCount ?? 0
    func atEnd() -> Bool { (v.ui.windows[v.currentGrid]?.botline ?? 0) >= n }
    func atTop() -> Bool { v.visibleLines.lowerBound == 0 }

    p.editor.stats.reset()
    phase = "flick-down"; dir = 1
    for _ in 0..<200 where !atEnd() { await b.gesture(dy: -40, n: 6, momentum: true); await checkSettled() }
    for _ in 0..<4 { await b.gesture(dy: -40, n: 6, momentum: true); await checkSettled() }  // keep pushing at the end
    section("flicks down to the end (40 pt/event, momentum)")
    phase = "flick-up"; dir = -1
    for _ in 0..<200 where !atTop() { await b.gesture(dy: 40, n: 6, momentum: true); await checkSettled() }
    for _ in 0..<4 { await b.gesture(dy: 40, n: 6, momentum: true); await checkSettled() }
    section("flicks up to the top")
    phase = "drag-down"; dir = 1
    for _ in 0..<12 { await b.gesture(dy: -7, n: 40, momentum: false); await checkSettled() }
    section("slow drags down (7 pt/event, no momentum)")
    phase = "drag-up"; dir = -1
    for _ in 0..<12 { await b.gesture(dy: 7, n: 40, momentum: false); await checkSettled() }
    section("slow drags up")
    phase = "ctrl-d"; dir = 1
    for _ in 0..<15 { v.nvim.input("<C-d>"); await sleep(0.25) }
    section("<C-d> x15")
    phase = "ctrl-u"; dir = -1
    for _ in 0..<15 { v.nvim.input("<C-u>"); await sleep(0.25) }
    section("<C-u> x15")
    phase = "wheel-down"; dir = 1
    for _ in 0..<20 { b.wheel(-1); await sleep(0.08) }
    await sleep(0.4)
    section("mouse wheel down x20")
    phase = "wheel-up"; dir = -1
    for _ in 0..<20 { b.wheel(1); await sleep(0.08) }
    await sleep(0.4)
    section("mouse wheel up x20")
    report += ["", "frames over the whole run (\(p.window.occlusionState.contains(.visible) ? "window visible" : "window occluded"), present with CA transaction: \(p.editor.presentsWithTransaction)):", p.editor.stats.summary()]
    try? ((report + ["", "per frame:"] + rows).joined(separator: "\n") + "\n").write(to: out, atomically: true, encoding: .utf8)
    try? await p.nvim.command("qall!")
  }
}

/// TAUDOT_PANECHECK=FILE (Tests/shell_panes.sh): the pane keys, pressed through the View menu's key equivalents
/// (the key → menu item → action path), checked against the window's layout. Lines start with "ok" or "FAIL".
@MainActor final class PaneCheck {
  let p: ProjectWindow
  let out: URL
  var lines: [String] = []
  init(_ p: ProjectWindow, out: URL) { self.p = p; self.out = out }
  func sleep(_ s: Double) async { try? await Task.sleep(for: .milliseconds(Int(s * 1000))) }
  func check(_ ok: Bool, _ what: String) { lines.append("\(ok ? "ok  " : "FAIL") \(what)") }

  func press(_ key: String, _ mods: NSEvent.ModifierFlags = .command) async {
    if !pressMenu(p, key, mods) { check(false, "no menu item for \(mods) \(key)") }
    await sleep(0.35)  // past the ~200 ms animation
    lineAfter("\(mods.contains(.option) ? "⌥" : "")\(mods.contains(.shift) ? "⇧" : "")⌘\(key)")
  }

  /// After every key: the line is on the focused pane (exactly its top), or hidden with one pane; the keys are there.
  var lineSteps = 0, lineWrong: [String] = []
  func lineAfter(_ what: String) {
    lineSteps += 1
    let c = p.window.contentView!
    let many = p.focusOrder.count > 1
    let want = p.lineTarget(p.focusedPane, in: c), got = p.focusLine.frame
    var ok = many ? !p.focusLine.isHidden && abs(got.minX - want.minX) <= 0.5 && abs(got.width - want.width) <= 0.5 && abs(got.minY - want.minY) <= 0.5
                  : p.focusLine.isHidden
    if p.focusedPane == 1 && p.window.firstResponder !== p.editor { ok = false }
    if !ok && lineWrong.count < 6 { lineWrong.append("\(what): pane \(p.focusedPane) line \(p.focusLine.isHidden ? "hidden" : "\(got.integral)") want \(many ? "\(want.integral)" : "hidden")") }
  }

  /// Every frame of a split animation: the line moves without jumps, stays in the window's split, is never on a
  /// pane that isn't the focused one once the slide is over, and ends exactly on the focused pane.
  func capture(_ name: String, _ key: String, _ mods: NSEvent.ModifierFlags = .command) async {
    var frames: [NSRect] = []
    p.onLineFrame = { [weak p] in if let p, !p.focusLine.isHidden { frames.append(p.focusLine.frame) } }
    _ = pressMenu(p, key, mods)
    await sleep(0.4)
    p.onLineFrame = nil
    let c = p.window.contentView!, split = p.split.convert(p.split.bounds, to: c)
    let end = p.lineTarget(p.focusedPane, in: c)
    guard !frames.isEmpty else { check(false, "\(name): no line frames"); return }
    let span = max(1, frames.map(\.minX).max()! - frames.map(\.minX).min()!, frames.map(\.width).max()! - frames.map(\.width).min()!)
    var worst: CGFloat = 0
    for (a, b) in zip(frames, frames.dropFirst()) { worst = max(worst, abs(b.minX - a.minX), abs(b.width - a.width)) }
    let inside = frames.allSatisfy { $0.minX >= split.minX - 0.5 && $0.maxX <= split.maxX + 0.5 }
    let last = frames.last ?? .zero
    check(frames.count >= 8 && inside && worst <= span * 0.5 + 1 && abs(last.minX - end.minX) <= 0.5 && abs(last.width - end.width) <= 0.5,
          "\(name): \(frames.count) frames, largest step \(Int(worst)) of \(Int(span)) pt, ends on pane \(p.focusedPane)")
  }

  var visible: String { (0..<3).map { p.visible($0) ? "SNP"[String.Index(utf16Offset: $0, in: "SNP")] : "-" }.map(String.init).joined() }
  var focused: Int { p.focusedPane }

  /// ⌥⌘↓ / ⌥⌘↑ (View ▸ Next / Previous Comment) from the sidebar: Neovim takes the keys, its cursor goes to the
  /// comment (two of them, on lines 1 and 3, made here), wrapping.
  func jumps() async {
    let mk = """
    local g = require('taudot.gui')
    local n = 0
    for _, row in ipairs({ 0, 2 }) do
      local l = vim.api.nvim_buf_get_lines(0, row, row + 1, false)[1] or ''
      if #l >= 4 then
        g.act('comment', nil, { buf = vim.api.nvim_get_current_buf(), text = 'jump ' .. row, line = row, col = 1, end_line = row, end_col = 4 })
        n = n + 1
      end
    end
    return n
    """
    let made = (try? await p.nvim.execLua(mk, []))?.int ?? 0
    var have = 0
    for _ in 0..<50 {
      have = (try? await p.nvim.execLua("local b = require('taudot.buffer').by_buf[vim.api.nvim_get_current_buf()]; return b and #require('taudot.gui').jump_items(b) or 0", []))?.int ?? 0
      if have >= made { break }
      await sleep(0.1)
    }
    guard made == 2, have >= 2 else { check(false, "⌥⌘↓: two comments to jump between (made \(made), have \(have))"); return }
    _ = try? await p.nvim.execLua("vim.api.nvim_win_set_cursor(0, {2, 0})", [])
    p.focus(pane: 0)
    func cursor() async -> [Int] {
      ((try? await p.nvim.execLua("return vim.api.nvim_win_get_cursor(0)", []))?.array ?? []).compactMap(\.int)
    }
    let down = String(UnicodeScalar(NSDownArrowFunctionKey)!), up = String(UnicodeScalar(NSUpArrowFunctionKey)!)
    await press(down, [.command, .option])
    var c = await cursor()
    check(focused == 1 && p.window.firstResponder === p.editor && c == [3, 1], "⌥⌘↓ from the sidebar: Neovim focused, at the next comment (\(focused), \(c))")
    await press(down, [.command, .option])
    c = await cursor()
    check(c == [1, 1], "⌥⌘↓ past the last wraps to the first (\(c))")
    p.focus(pane: 0)
    await press(up, [.command, .option])
    c = await cursor()
    check(focused == 1 && c == [3, 1], "⌥⌘↑ from the sidebar: back round to the last (\(focused), \(c))")
    // Review ▸ Resolve Comment (⌥⌘R) from Neovim: the comment at the cursor resolves and the cursor moves on.
    let menu = NSApp.mainMenu?.items.first { $0.submenu?.title == "Review" }?.submenu
    check(menu?.items.map(\.title).contains("Accept Suggestion / Reply to Comment") == true && menu?.items.count ?? 0 >= 10,
          "a Review menu with its items (\(menu?.items.map(\.title).filter { !$0.isEmpty } ?? []))")
    await press("r", [.command, .option])
    var resolved = 0
    for _ in 0..<30 {
      resolved = (try? await p.nvim.execLua("local n = 0; for _, t in pairs(require('taudot').project().threads or {}) do if t.resolved then n = n + 1 end end; return n", []))?.int ?? 0
      if resolved > 0 { break }
      await sleep(0.1)
    }
    c = await cursor()
    check(resolved == 1 && c == [1, 1], "⌥⌘R resolves the comment at the cursor and moves to the next (\(resolved) resolved, cursor \(c))")
  }

  /// A trackpad gesture over the margin (Comments ▸ This File) scrolls Neovim, as over the text.
  func marginScroll() async {
    if !p.visible(0) { p.setPane(p.sidebar, hidden: false) }
    p.sidebar.tab = .comments
    p.sidebar.scope = .file
    _ = try? await p.nvim.execLua("vim.cmd('normal! gg')", [])
    await sleep(0.4)
    func top() async -> Int { (try? await p.nvim.execLua("return vim.fn.line('w0')", []))?.int ?? 0 }
    let w0 = await top()
    let m = p.margin
    let at = m.window!.convertPoint(toScreen: m.convert(NSPoint(x: 30, y: m.bounds.midY), to: nil))
    var onText: NSPoint?
    func send(_ dy: Int32, _ phase: Int64, _ to: NSView) {
      let at = onText ?? at
      guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0) else { return }
      cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
      cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
      cg.location = CGPoint(x: at.x, y: NSScreen.screens.first!.frame.maxY - at.y)
      if let e = NSEvent(cgEvent: cg) { to.scrollWheel(with: e) }
    }
    func gesture(_ to: NSView) async {
      send(-8, 1, to)
      for _ in 0..<10 { send(-24, 2, to); await sleep(0.016) }
      send(0, 4, to)
      await sleep(0.6)
    }
    // (the same gesture straight on the text first: what the margin must match)
    let ed: EditorView = p.editor
    let mid = ed.window!.convertPoint(toScreen: ed.convert(NSPoint(x: ed.bounds.midX, y: ed.bounds.midY), to: nil))
    onText = mid
    await gesture(ed)
    let wText = await top()
    onText = nil
    _ = try? await p.nvim.execLua("vim.cmd('normal! gg')", [])
    await sleep(0.4)
    await gesture(m)
    let w1 = await top()
    guard wText > w0 else { lines.append("skip margin scroll: the file fits the window (topline stays \(w0))"); return }
    check(w1 == wText, "a trackpad scroll over the margin scrolls Neovim as one on the text (topline \(w0) → \(w1), on the text \(wText))")
    check(m.overscroll == 0, "… and the cards aren't lifted away from their lines (\(m.overscroll))")
  }

  /// Scroll events through AppKit's own path (NSApp.sendEvent, the window hit-testing the pointer), posted over the
  /// review panel: which view gets them, and does Neovim scroll.
  func scrollPath() async {
    if !p.visible(0) { p.setPane(p.sidebar, hidden: false) }
    p.sidebar.tab = .comments
    p.sidebar.scope = .file
    _ = try? await p.nvim.execLua("vim.cmd('normal! gg')", [])
    await sleep(0.4)
    ScrollEventTrace.install(force: true)
    ScrollEventTrace.lines = []
    func top() async -> Int { (try? await p.nvim.execLua("return vim.fn.line('w0')", []))?.int ?? 0 }
    let w0 = await top()
    let m = p.margin
    let ed: NSView = p.editor
    for (name, view, pt) in [("text (control)", ed, NSPoint(x: ed.bounds.midX, y: ed.bounds.midY)), ("panel middle", m, NSPoint(x: m.bounds.midX, y: m.bounds.midY)),
                             ("panel near the text", m, NSPoint(x: m.bounds.maxX - 12, y: m.bounds.midY + 40))] {
      let at = view.window!.convertPoint(toScreen: view.convert(pt, to: nil))
      func post(_ dy: Int32, _ phase: Int64) {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0) else { return }
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        cg.location = CGPoint(x: at.x, y: NSScreen.screens.first!.frame.maxY - at.y)
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(p.window.windowNumber))
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(p.window.windowNumber))
        if let e = NSEvent(cgEvent: cg) { NSApp.sendEvent(e) }
      }
      // What AppKit hit-tests for a scroll at that point (the frame view's hitTest, as NSWindow does).
      let frame = p.window.contentView!.superview!
      var hv = frame.hitTest(frame.convert(view.convert(pt, to: nil), from: nil))
      var chain: [String] = []
      while let x = hv { chain.append(String(describing: type(of: x))); hv = x.superview }
      lines.append("info hit at \(name): \(chain.prefix(9).joined(separator: " < "))")
      check(view === ed ? chain.first == "EditorView" : chain.contains("ReviewMarginView"), "AppKit sends a scroll at the \(name) to \(view === ed ? "the editor" : "the margin")")
      // (the real screen and input: only when asked for, TAUDOT_ONSCREEN=1 as well; see docs/agents/README.md)
      let env = ProcessInfo.processInfo.environment
      let real = env["TAUDOT_SCROLLREAL"] != nil && env["TAUDOT_ONSCREEN"] == "1"
      if real {
        // The real path: the window in front, the pointer over the point, scroll events from the HID level (the
        // window server routes them, as a trackpad's).
        NSApp.activate(ignoringOtherApps: true)
        p.window.makeKeyAndOrderFront(nil)
        await sleep(0.5)
        CGWarpMouseCursorPosition(CGPoint(x: at.x, y: NSScreen.screens.first!.frame.maxY - at.y))
        await sleep(0.2)
      }
      func hid(_ dy: Int32, _ phase: Int64) {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0) else { return }
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        cg.location = CGPoint(x: at.x, y: NSScreen.screens.first!.frame.maxY - at.y)
        cg.post(tap: .cghidEventTap)
      }
      // (without TAUDOT_SCROLLREAL the events have no window, so AppKit can't route them: only the hit test is checked)
      guard real else { continue }
      let send: (Int32, Int64) -> Void = hid
      let before = await top()
      send(-8, 1)
      for _ in 0..<10 { send(-24, 2); await sleep(0.016) }
      send(0, 4)
      await sleep(0.6)
      let after = await top()
      for l in ScrollEventTrace.lines.prefix(3) { lines.append("info scroll at \(name): \(l)") }
      lines.append("info \(ScrollEventTrace.lines.count) scroll events seen")
      ScrollEventTrace.lines = []
      check(after > before, "a scroll through AppKit's path over the \(name) scrolls Neovim (topline \(before) → \(after))")
      _ = try? await p.nvim.execLua("vim.cmd('normal! gg')", [])
      await sleep(0.4)
    }
    _ = w0
  }

  func run() async {
    let tick0 = (try? await p.nvim.execLua("return vim.b.changedtick", []))?.int
    if !p.visible(0) { p.setPane(p.sidebar, hidden: false) }
    if !p.visible(2) { p.setPane(p.pdf.view, hidden: false) }
    await sleep(0.3)
    p.focus(pane: 1)
    let w0 = p.widths()
    check(visible == "SNP" && focused == 1, "start: all three panes, Neovim focused (\(visible), \(focused))")
    // Each grip is centred on its divider: right after the panes appear, and after the window resizes.
    func gripsCentred() -> [Int] {
      guard let sup = p.split.superview else { return [] }
      return sup.subviews.compactMap { $0 as? DividerGrips.Grip }.filter { !$0.isHidden && $0.split === p.split }.map { g in
        let line = p.split.subviews[g.index].frame.maxX + p.split.dividerThickness / 2
        return Int((sup.convert(g.frame, to: p.split).midX - line).rounded())
      }
    }
    let c0 = gripsCentred()
    let f0 = p.window.frame
    p.window.setFrame(f0.insetBy(dx: 60, dy: 0), display: true)
    await sleep(0.3)
    let c1 = gripsCentred()
    p.window.setFrame(f0, display: true)
    await sleep(0.3)
    check(c0.count == 2 && (c0 + c1).allSatisfy { $0 == 0 }, "the grips sit centred on their dividers (offsets \(c0), after a resize \(c1))")
    // Cycling, wrapping.
    var seq: [Int] = []
    for _ in 0..<3 { await press("]"); seq.append(focused) }
    check(seq == [2, 0, 1], "⌘] cycles N → P → S → N: \(seq)")
    seq = []
    for _ in 0..<3 { await press("["); seq.append(focused) }
    check(seq == [0, 2, 1], "⌘[ cycles back N → S → P → N: \(seq)")
    check(p.editor.focused && p.window.firstResponder === p.editor, "Neovim focused: the editor takes the keys (solid cursor)")
    let left = String(UnicodeScalar(NSLeftArrowFunctionKey)!), right = String(UnicodeScalar(NSRightArrowFunctionKey)!)
    seq = []
    for _ in 0..<3 { await press(left, [.command, .option]); seq.append(focused) }
    check(seq == [0, 0, 0], "⌘⌥← stops at the sidebar: \(seq)")
    check(!p.editor.focused && p.window.firstResponder !== p.editor, "sidebar focused: Neovim isn't (hollow cursor)")
    seq = []
    for _ in 0..<3 { await press(right, [.command, .option]); seq.append(focused) }
    check(seq == [1, 2, 2], "⌘⌥→ stops at the PDF: \(seq)")
    // A hidden pane is skipped; ⌘3 brings it back.
    await press("\\")
    check(visible == "SN-" && focused == 1, "⌘\\ hides the focused PDF; Neovim takes the focus (\(visible), \(focused))")
    seq = []
    for _ in 0..<3 { await press("]"); seq.append(focused) }
    check(seq == [0, 1, 0], "⌘] with the PDF hidden: \(seq)")
    await press("3")
    check(visible == "SNP" && focused == 2, "⌘3 shows and focuses the PDF (\(visible), \(focused))")
    await press("s", [.command, .control])
    check(visible == "-NP", "⌃⌘S hides the sidebar (\(visible))")
    await press("1")
    check(visible == "SNP" && focused == 0, "⌘1 shows and focuses it (\(visible), \(focused))")
    await press("\\", [.command, .shift])
    check(visible == "-NP" && focused == 1, "⇧⌘\\ (alias) hides it; Neovim takes the focus (\(visible), \(focused))")
    await press("e", [.command, .shift])
    check(visible == "SNP" && focused == 0 && p.sidebar.tab == .files && !p.sidebar.commentsVisible,
          "⇧⌘E shows the sidebar's Files tab (\(visible), \(focused), \(p.sidebar.tab))")
    check((p.window.firstResponder as? NSView)?.isDescendant(of: p.sidebar.files) == true,
          "the file tree takes the keys (\(String(describing: p.window.firstResponder)))")
    await press("s", [.command, .control])
    await press("m", [.command, .shift])
    check(visible == "SNP" && focused == 0 && p.sidebar.tab == .comments && p.sidebar.commentsVisible,
          "⇧⌘M shows the hidden sidebar on Comments (\(visible), \(focused), \(p.sidebar.tab))")
    p.sidebar.files.onError?("“x.tex” is already taken.")
    check(p.status.right.stringValue.contains("already taken"), "files.onError shows in the status bar (\(p.status.right.stringValue))")
    // TeX issues, in the strip (no status-bar pill): it waits for runs to settle, then shows and pulses once; it sits
    // atop the PDF, or atop the editor column (Neovim moved down) while the PDF is hidden; ⌥⌘E expands and
    // collapses it; a clean run hides it at once.
    if !p.visible(2) { p.setPane(p.pdf.view, hidden: false) }
    await sleep(0.3)
    let sv = p.stripView
    let pv = p.pdf.view
    p.issues.settle = 0.3
    p.pdf.onStatus?("TeX: main.tex:4: Undefined control sequence")
    p.pdf.onStatus?("TeX: ! Undefined control sequence. l.4 A \\foobar")
    p.pdf.onStatus?("TeX: main.tex:2: Too many }'s")
    p.pdf.onStatus?("1 page, typeset in 12 ms")
    check(sv?.isHidden == true, "a new error waits for the runs to settle (strip hidden)")
    p.pdf.onStatus?("TeX: main.tex:4: Undefined control sequence")
    p.pdf.onStatus?("TeX: ! Undefined control sequence. l.4 A \\foobar")
    p.pdf.onStatus?("TeX: main.tex:2: Too many }'s")
    p.pdf.onStatus?("1 page, typeset in 11 ms")
    await sleep(0.15)
    check(sv?.isHidden == true, "… and another run restarts the wait")
    await sleep(0.5)
    let h0 = sv?.frame.height ?? 0
    check(sv?.isHidden == false && sv?.superview === pv && h0 >= 28 && h0 <= 36 && abs((sv?.frame.maxY ?? 0) - pv.bounds.maxY) < 1
            && abs((sv?.frame.width ?? 0) - pv.bounds.width) < 1,
          "then the strip shows, docked at the top of the PDF pane, one line (\(Int(h0)) pt)")
    check(p.strip.pulse == 1, "… its dot pulses once (\(p.strip.pulse))")
    check(!p.status.subviews.contains { String(describing: type(of: $0)).contains("Pill") }, "no pill in the status bar")
    check(p.issues.shown.first?.context == "A \\foobar" && p.issues.shown.count == 2,
          "the two forms of one error are one issue, with TeX's context (\(p.issues.shown.count))")
    await press("e", [.command, .option])
    await sleep(0.4)
    let h1 = sv?.frame.height ?? 0
    check(p.strip.expanded && h1 > h0 + 50 && h1 <= pv.bounds.height * 0.4 + 40, "⌥⌘E expands it into the list (\(Int(h1)) pt of \(Int(pv.bounds.height)))")
    await press("e", [.command, .option])
    await sleep(0.4)
    check(!p.strip.expanded && abs((sv?.frame.height ?? 0) - h0) < 1, "… and collapses it")
    // the PDF hidden: atop the editor column, Neovim below it; shown again: back over the PDF
    await press("\\")
    await sleep(0.6)
    let colTop = p.column.frame.maxY, sMin = sv?.frame.minY ?? 0
    check(sv?.superview === p.editorBox && sv?.isHidden == false && abs(colTop - sMin) < 1 && abs((sv?.frame.maxY ?? 0) - p.editorBox.bounds.maxY) < 1,
          "PDF hidden: the strip is atop the editor column, Neovim below it (column top \(Int(colTop)), strip bottom \(Int(sMin)))")
    await press("\\")
    await sleep(0.6)
    check(sv?.superview === pv && abs(p.column.frame.maxY - p.editorBox.bounds.maxY) < 1, "PDF shown: back over the PDF, the column at the top again")
    p.pdf.onStatus?("1 page, typeset in 9 ms")
    check(p.issues.shown.isEmpty && sv?.isHidden == true, "a clean run hides the strip at once")
    p.issues.settle = 1.5
    await press("2")
    let w1 = p.widths()
    check(zip(w0, w1).allSatisfy { abs($0 - $1) <= 1 }, "toggles keep the widths: \(w0.map(Int.init)) → \(w1.map(Int.init))")
    let c2 = gripsCentred()
    check(c2.count == 2 && c2.allSatisfy { $0 == 0 }, "after the pane toggles the grips are still centred (\(c2))")
    // The editor|PDF divider has a grip: a 12 pt band over the line that owns the mouse (cursor, hover line, drag).
    if let sup = p.split.superview {
      let x = p.editorBox.frame.maxX + p.split.dividerThickness / 2, y = p.split.bounds.midY
      let on = [x - 5, x, x + 5].map { sup.hitTest(p.split.convert(NSPoint(x: $0, y: y), to: sup)) is DividerGrips.Grip }
      let off = sup.hitTest(p.split.convert(NSPoint(x: x - 20, y: y), to: sup)) is DividerGrips.Grip
      check(on.allSatisfy { $0 } && !off, "the editor|PDF divider's grip covers ±5 pt (\(on), 20 pt off: \(off))")
      // drag it 60 pt left through the grip, then back
      let w0 = p.editorBox.frame.width
      if let g = sup.subviews.compactMap({ $0 as? DividerGrips.Grip }).first(where: { $0.index == 1 && !$0.isHidden }) {
        let win = p.window
        func ev(_ t: NSEvent.EventType, _ dx: CGFloat) -> NSEvent {
          let pt = p.split.convert(NSPoint(x: x + dx, y: y), to: nil)
          return NSEvent.mouseEvent(with: t, location: pt, modifierFlags: [], timestamp: 0, windowNumber: win.windowNumber,
                                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        g.mouseDown(with: ev(.leftMouseDown, 0)); g.mouseDragged(with: ev(.leftMouseDragged, -60)); g.mouseUp(with: ev(.leftMouseUp, -60))
        let w1 = p.editorBox.frame.width
        g.mouseDown(with: ev(.leftMouseDown, -60)); g.mouseDragged(with: ev(.leftMouseDragged, 0)); g.mouseUp(with: ev(.leftMouseUp, 0))
        check(abs(w0 - w1 - 60) <= 1 && abs(p.editorBox.frame.width - w0) <= 1,
              "dragging the grip moves the divider (\(Int(w0)) → \(Int(w1)) → \(Int(p.editorBox.frame.width)))")
      } else { check(false, "no grip on the editor|PDF divider") }
    }
    // Zoom and restore.
    await press("e")
    check(visible == "-N-" && p.editorBox.frame.width >= p.split.bounds.width - 2 * p.split.dividerThickness - 0.5 && focused == 1,
          "⌘E zooms Neovim (\(visible), width \(Int(p.editorBox.frame.width)) of \(Int(p.split.bounds.width)))")
    check(p.window.firstResponder === p.editor, "zoomed Neovim keeps the keys")
    await press("]")
    check(focused == 1, "⌘] while zoomed stays on the only pane")
    await press("e")
    let w2 = p.widths()
    check(visible == "SNP" && zip(w1, w2).allSatisfy { abs($0 - $1) <= 1 }, "⌘E again restores \(visible) \(w2.map(Int.init))")
    await press("3"); await press("e")
    check(visible == "--P" && p.pdf.view.frame.width >= p.split.bounds.width - 2 * p.split.dividerThickness - 0.5, "⌘E zooms the PDF (\(visible))")
    await press("s", [.command, .control])
    let w3 = p.widths()
    check(visible == "-NP" && abs(w3[2] - w1[2]) <= 1 && p.zoom == nil,
          "⌃⌘S while zoomed: the layout comes back, then the sidebar toggles (\(visible) \(w3.map(Int.init)))")
    await press("s", [.command, .control])
    await press("2"); await press("e")
    await press("1")
    let w4 = p.widths()
    check(visible == "SNP" && focused == 0 && zip(w1, w4).allSatisfy { abs($0 - $1) <= 1 },
          "⌘1 while Neovim is zoomed: layout back, sidebar focused (\(visible) \(w4.map(Int.init)))")
    // Focus line over the focused pane (hidden while the window isn't key, as in a background run).
    let content = p.window.contentView!
    let r = p.sidebar.convert(p.sidebar.bounds, to: content)
    check(abs(p.focusLine.frame.minX - r.minX) <= 1 && abs(p.focusLine.frame.width - r.width) <= 1,
          "focus line over the sidebar: \(p.focusLine.frame.integral) vs \(r.integral)")
    // ⌥⌘2 / ⌥⌘3: one pane alone, again restores.
    await press("2", [.command, .option])
    check(visible == "-N-" && focused == 1, "⌥⌘2: Neovim only (\(visible))")
    await press("2", [.command, .option])
    check(visible == "SNP" && focused == 1, "⌥⌘2 again restores (\(visible))")
    await press("3", [.command, .option])
    check(visible == "--P" && focused == 2, "⌥⌘3: PDF only (\(visible))")
    await press("2", [.command, .option])
    check(visible == "-N-" && focused == 1, "⌥⌘2 from PDF only: Neovim only (\(visible))")
    await press("2", [.command, .option])
    await jumps()
    await marginScroll()
    await scrollPath()
    // Split animations, frame by frame.
    await press("1")
    await capture("⌃⌘S hides the focused sidebar: the line slides to Neovim with the split", "s", [.command, .control])
    check(focused == 1 && visible == "-NP", "… Neovim has the keys (\(focused), \(visible))")
    await capture("⌃⌘S shows it without taking the focus: the line rides on Neovim's shrinking frame", "s", [.command, .control])
    check(focused == 1 && visible == "SNP", "… focus stays on Neovim (\(focused))")
    await press("s", [.command, .control])
    await capture("⌘1 shows and focuses it: the line slides onto it as it opens", "1")
    await capture("⌘\\ hides the PDF while the sidebar is focused: the line stays on it", "\\")
    await press("\\")
    await press("e")
    check(p.focusLine.isHidden, "zoomed: one pane, no line")
    await press("e")
    // Projects row → project window: a card grows from the row's rect to the window's frame, then the window fades in.
    let row = NSRect(x: p.window.frame.minX + 40, y: p.window.frame.midY, width: 300, height: 28)
    var cards: [NSRect] = []
    var finished = false
    p.window.alphaValue = 0
    p.grow(from: row) { finished = true }
    let pw = p
    let sampler = Timer(timeInterval: 1.0 / 120, repeats: true) { _ in MainActor.assumeIsolated { if let c = pw.growCard, c.isVisible { cards.append(c.frame) } } }
    RunLoop.main.add(sampler, forMode: .common)
    for _ in 0..<60 where !finished { await sleep(0.02) }
    sampler.invalidate()
    let growing = zip(cards, cards.dropFirst()).allSatisfy { $1.width >= $0.width - 0.5 && $1.height >= $0.height - 0.5 }
    check(finished && cards.count >= 10 && cards[0].width < (row.width + p.window.frame.width) / 2 && growing && cards.last.map { abs($0.width - p.window.frame.width) < 1 && abs($0.height - p.window.frame.height) < 1 } == true
          && p.window.alphaValue == 1 && p.growCard == nil,
          "the window grows out of the row: \(cards.count) frames, \(Int(cards.first?.width ?? 0)) → \(Int(cards.last?.width ?? 0)) pt wide, then fades in (alpha \(p.window.alphaValue))")
    // ⌥⌘\\: the editor column, like ⌘\\ for the PDF; never the last pane.
    await press("2")
    let wE = p.widths()
    await press("\\", [.command, .option])
    check(visible == "S-P" && focused == 2, "⌥⌘\\ hides the editor; the PDF takes the focus (\(visible), \(focused))")
    await press("\\", [.command, .option])
    let wE2 = p.widths()
    check(visible == "SNP" && focused == 2 && zip(wE, wE2).allSatisfy { abs($0 - $1) <= 1 },
          "⌥⌘\\ again shows it at its width, focus stays (\(wE.map(Int.init)) → \(wE2.map(Int.init)))")
    await press("\\", [.command, .option]); await press("s", [.command, .control])
    check(visible == "--P", "only the PDF left (\(visible))")
    await press("\\")
    check(visible == "--P", "⌘\\ on the last pane does nothing (\(visible))")
    await press("2")
    check(visible == "-NP" && focused == 1 && p.window.firstResponder === p.editor, "⌘2 brings the editor back and focuses it (\(visible))")
    await press("s", [.command, .control])
    let gridCols = p.editor.cols
    check(gridCols > 40, "Neovim kept a real grid through the hide (\(gridCols) columns)")
    check(lineWrong.isEmpty, "the line is on the focused pane after every one of \(lineSteps) keys \(lineWrong)")
    let tick1 = (try? await p.nvim.execLua("return vim.b.changedtick", []))?.int
    check(tick0 != nil && tick0 == tick1, "no ⌘ key reached Neovim's text (changedtick \(tick0 ?? -1) → \(tick1 ?? -1))")
    try? (lines.joined(separator: "\n") + "\n").write(to: out, atomically: true, encoding: .utf8)
    _ = await p.shutdown()
    p.window.close()
  }
}

/// Press a key: the menu item whose key equivalent matches, its action sent to this window (a background run's
/// window isn't key, so the responder chain wouldn't reach it). False if no item has that key.
@MainActor func pressMenu(_ p: ProjectWindow, _ key: String, _ mods: NSEvent.ModifierFlags = .command) -> Bool {
  func find(_ m: NSMenu) -> NSMenuItem? {
    for i in m.items {
      if let s = i.submenu, let f = find(s) { return f }
      if i.keyEquivalent == key && i.keyEquivalentModifierMask == mods && i.action != nil { return i }
    }
    return nil
  }
  guard let item = NSApp.mainMenu.flatMap(find), let a = item.action else { return false }
  p.perform(a, with: item)
  return true
}

/// TAUDOT_CLAUDECHECK=FILE (Tests/shell_claude.sh, with TAUDOT_CLAUDE = a fake claude that echoes its input): the
/// Claude pane's keys. TAUDOT_CLAUDECHECK_MISSING=1: the command isn't there, the pane says how to install it.
@MainActor final class ClaudeCheck {
  let p: ProjectWindow
  let out: URL
  var lines: [String] = []
  init(_ p: ProjectWindow, out: URL) { self.p = p; self.out = out }
  func sleep(_ s: Double) async { try? await Task.sleep(for: .milliseconds(Int(s * 1000))) }
  func check(_ ok: Bool, _ what: String) { lines.append("\(ok ? "ok  " : "FAIL") \(what)") }
  func press(_ key: String, _ mods: NSEvent.ModifierFlags = .command) async {
    if !pressMenu(p, key, mods) { check(false, "no menu item for \(mods) \(key)") }
    await sleep(0.35)
  }
  func text() async -> String { await p.claude?.text() ?? "" }
  func waitText(_ s: String) async -> Bool {
    for _ in 0..<100 { if await text().contains(s) { return true }; await sleep(0.05) }
    return false
  }
  func count(_ s: String, in t: String) -> Int { t.components(separatedBy: s).count - 1 }
  var fr: NSResponder? { p.window.firstResponder }

  func run() async {
    defer { finish() }
    if ProcessInfo.processInfo.environment["TAUDOT_CLAUDECHECK_MISSING"] != nil {
      await press("j")
      check(await waitText("isn't on PATH"), "no claude: the pane says how to install it (\(await text().prefix(120)))")
      return
    }
    await press("j")
    check(p.claudeShown && p.focusedPane == 3 && fr === p.claude?.view, "⌘J opens the pane and focuses it")
    check(await waitText("fake claude: ready"), "claude runs in the project folder's terminal")
    let job = await p.claude?.job()
    check(job != nil, "a terminal job (\(String(describing: job)))")
    // Floating (the default): a glass panel over the editor column, bottom centre, ~70% wide, ~40% high.
    let f = p.claudeFloat, box = p.editorBox.bounds
    check(!p.dockedNow && !f.isHidden && p.claude?.view.isDescendant(of: f) == true,
          "⌘J floats the pane over the editor (docked \(p.dockedNow))")
    check(abs(f.frame.width / box.width - 0.7) < 0.02 && abs(f.frame.height / box.height - 0.4) < 0.02 && abs(f.frame.midX - box.midX) < 2,
          "bottom centre, 70% × 40% of the column: \(f.frame.integral) in \(box.integral)")
    let fw = f.convert(f.bounds, to: nil), bw = p.editorBox.convert(p.editorBox.bounds, to: nil)
    check(bw.contains(fw), "inside the editor column (never over the sidebar or the PDF): \(fw.integral) in \(bw.integral)")
    check(p.editor.ui.windows.count > 0 && p.column.arrangedSubviews.count == 1, "the editor keeps the whole column under it")
    // Drag by the strip, resize from the right edge.
    func mouse(_ type: NSEvent.EventType, _ pt: NSPoint, clicks: Int = 1) -> NSEvent? {
      NSEvent.mouseEvent(with: type, location: f.convert(pt, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: p.window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)
    }
    let f0 = f.frame
    let strip = NSPoint(x: f.bounds.midX, y: 8)
    if let d = mouse(.leftMouseDown, strip), let m = mouse(.leftMouseDragged, NSPoint(x: strip.x - 60, y: strip.y - 40)), let u = mouse(.leftMouseUp, NSPoint(x: strip.x - 60, y: strip.y - 40)) {
      f.mouseDown(with: d); f.mouseDragged(with: m); f.mouseUp(with: u)
    }
    check(abs(f.frame.minX - (f0.minX - 60)) < 1 && abs(abs(f.frame.minY - f0.minY) - 40) < 1 && f.frame.size == f0.size,
          "dragging the strip moves it: \(f0.integral) → \(f.frame.integral)")
    let f1 = f.frame
    let edge = NSPoint(x: f.bounds.width - 2, y: f.bounds.midY)
    if let d = mouse(.leftMouseDown, edge), let m = mouse(.leftMouseDragged, NSPoint(x: edge.x + 50, y: edge.y)), let u = mouse(.leftMouseUp, NSPoint(x: edge.x + 50, y: edge.y)) {
      f.mouseDown(with: d); f.mouseDragged(with: m); f.mouseUp(with: u)
    }
    check(abs(f.frame.width - (f1.width + 50)) < 1 && f.frame.minX == f1.minX, "the right edge resizes it: width \(Int(f1.width)) → \(Int(f.frame.width))")
    check(abs(f.placement.w - Double(f.frame.width / box.width)) < 0.01, "the new place is remembered (w \(String(format: "%.2f", f.placement.w)))")
    // The editor under it stays live.
    let top0 = p.editor.visibleLines.lowerBound
    p.nvim.input("<C-e><C-e><C-e>")
    await sleep(0.4)
    check(p.editor.visibleLines.lowerBound > top0, "the editor beneath scrolls (<C-e>×3 with smoothscroll: top line \(top0) → \(p.editor.visibleLines.lowerBound))")
    p.focus(pane: 1)
    check(f.dimmed && f.alphaValue == 1, "Neovim focused: the panel dims (a tint; still opaque)")
    p.focus(pane: 3)
    await press("j")
    check(!p.claudeShown && p.focusedPane == 1 && fr === p.editor, "⌘J again hides it, Neovim focused")
    await press("j")
    let job2 = await p.claude?.job()
    check(p.claudeShown && job2 != nil && job2?.job == job?.job && job2?.pid == job?.pid,
          "⌘J shows the same session (job \(String(describing: job2)))")
    // The cycle and the columns: sidebar, Neovim, Claude, PDF.
    if !p.visible(0) { p.setPane(p.sidebar, hidden: false) }
    if !p.visible(2) { p.setPane(p.pdf.view, hidden: false) }
    p.focus(pane: 1)
    var seq: [Int] = []
    for _ in 0..<4 { await press("]"); seq.append(p.focusedPane) }
    check(seq == [3, 2, 0, 1], "⌘] cycles N → Claude → P → S → N: \(seq)")
    p.focus(pane: 3)
    await press(String(UnicodeScalar(NSRightArrowFunctionKey)!), [.command, .option])
    let r = p.focusedPane
    p.focus(pane: 3)
    await press(String(UnicodeScalar(NSLeftArrowFunctionKey)!), [.command, .option])
    check(r == 2 && p.focusedPane == 0, "⌘⌥→ / ⌘⌥← from Claude: PDF / sidebar (\(r), \(p.focusedPane))")
    // Zoom the Claude pane, and back.
    p.focus(pane: 3)
    await press("e")
    check(p.editorHost.isHidden && !p.visible(0) && !p.visible(2) && p.claudeShown && p.focusedPane == 3,
          "⌘E zooms the Claude pane (editor hidden \(p.editorHost.isHidden))")
    await press("e")
    check(!p.editorHost.isHidden && p.visible(0) && p.visible(2) && p.claudeShown, "⌘E again restores the column and the panes")
    p.focus(pane: 1)
    await press("e")
    check(!p.claudeShown && !p.editorHost.isHidden && !p.visible(0), "⌘E on Neovim hides the Claude pane too")
    await press("e")
    check(p.claudeShown, "… and brings it back")
    // ⌘L: the Visual selection's lines, at the prompt, without Return.
    p.focus(pane: 1)
    p.nvim.input("<Esc>3GVjj")
    await sleep(0.3)
    await press("l")
    let ref = "@main.tex#L3-5"
    check(await waitText(ref), "⌘L in Visual mode types \(ref)")
    await sleep(0.3)
    var t = await text()
    check(count(ref, in: t) == 1, "… once: no Return (an echo would repeat it): \(count(ref, in: t))")
    check(p.focusedPane == 3 && fr === p.claude?.view, "… and focuses the pane")
    let mode = (try? await p.nvim.execLua("return vim.fn.mode()", []))?.string
    check(mode == "n", "Neovim left Visual mode (\(mode ?? "?"))")
    // Esc-Esc back to Neovim.
    for _ in 0..<2 {
      if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: p.window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                  isARepeat: false, keyCode: 53) { p.claude?.view.keyDown(with: e) }
      await sleep(0.05)
    }
    await sleep(0.1)
    check(p.focusedPane == 1 && fr === p.editor, "Esc Esc goes back to Neovim (\(p.focusedPane))")
    // Normal mode: the cursor's line.
    p.nvim.input("<Esc>7G")
    await sleep(0.2)
    await press("l")
    check(await waitText("@main.tex#L7 "), "⌘L in Normal mode types @main.tex#L7")
    t = await text()
    check(count("@main.tex#L7 ", in: t) == 1, "… once")
    await press("2")
    check(p.focusedPane == 1 && fr === p.editor, "⌘2 back to Neovim")
    // "Ask Claude to fix all errors": one prompt, every error with its lines, not sent.
    p.issues.settle = 0.05
    p.pdf.onStatus?("TeX: main.tex:12: Undefined control sequence")
    p.pdf.onStatus?("TeX: main.tex:20: Too many }'s")
    p.pdf.onStatus?("1 page, typeset in 3 ms")
    await sleep(0.3)
    p.askClaudeToFixAll(nil)
    let all = "Fix these LaTeX errors: @main.tex#L6-16 line 12: Undefined control sequence; @main.tex#L14-24 line 20: Too many }'s. Keep each change minimal; fix only these errors."
    func flatAll(_ s: String) -> String { s.filter { !$0.isWhitespace } }
    var typedAll = false
    for _ in 0..<100 { if flatAll(await text()).contains(flatAll(all)) { typedAll = true; break }; await sleep(0.05) }
    check(typedAll, "Ask Claude to fix all errors types: \(all)")
    await press("2")
    // clear the prompt line (Ctrl-U) for the next check
    p.focus(pane: 3)
    await p.claude?.type("\u{15}")
    await sleep(0.2)
    p.pdf.onStatus?("1 page, typeset in 3 ms")
    // "Ask Claude to fix": the prompt with the lines around the error, at the prompt, not sent.
    let err = TeXIssue(.error, line: 12, message: "Undefined control sequence", context: "A \\foobar")
    p.askClaudeToFix(err)
    let fix = "Fix this LaTeX error. @main.tex#L6-16 Error at line 12: Undefined control sequence. Keep the change minimal."
    // the terminal wraps it: compared without whitespace
    func flat(_ s: String) -> String { s.filter { !$0.isWhitespace } }
    var typed = false
    for _ in 0..<100 { if flat(await text()).contains(flat(fix)) { typed = true; break }; await sleep(0.05) }
    check(typed, "Ask Claude to fix types: \(fix)")
    await sleep(0.3)
    t = await text()
    check(count(flat(fix), in: flat(t)) == 1 && p.focusedPane == 3, "… once (no Return), the pane focused")
    await press("2")
    // Double-click the strip: docked as a split under the editor; View ▸ Claude ▸ Floating: back.
    p.focus(pane: 3)
    if let d = mouse(.leftMouseDown, NSPoint(x: f.bounds.midX, y: 8), clicks: 2) { f.mouseDown(with: d) }
    await sleep(0.5)  // the frame morphs into the dock (~220 ms)
    let dh = p.claude?.view.frame.height ?? 0
    check(p.dockedNow && f.isHidden && p.claude?.view.superview === p.column && p.claudeShown && dh >= 80 && p.focusedPane == 3,
          "double-click on the strip docks it (height \(Int(dh)), still focused)")
    let job3 = await p.claude?.job()
    check(job3?.pid == job?.pid, "… same session")
    p.focus(pane: 1); await press("e")
    check(!p.claudeShown, "docked: ⌘E on Neovim hides it"); await press("e")
    p.setClaudeFloating(nil)
    await sleep(0.5)
    check(!p.dockedNow && !f.isHidden && p.claude?.view.isDescendant(of: f) == true && p.column.arrangedSubviews.count == 1,
          "View ▸ Claude ▸ Floating floats it again")
  }

  func finish() {
    try? (lines.joined(separator: "\n") + "\n").write(to: out, atomically: true, encoding: .utf8)
    Task { _ = await p.shutdown(); p.window.close() }
  }
}

/// TAUDOT_NATIVECHECK=FILE (Tests/shell_native.sh, with TAUDOT_EDITOR_MODE=native): a project window in native
/// editor mode, wired as the Neovim one is.
@MainActor final class NativeCheck {
  let p: ProjectWindow
  let out: URL
  var lines: [String] = []
  init(_ p: ProjectWindow, out: URL) { self.p = p; self.out = out }
  func sleep(_ s: Double) async { try? await Task.sleep(for: .milliseconds(Int(s * 1000))) }
  func check(_ ok: Bool, _ what: String) {
    lines.append("\(ok ? "ok  " : "FAIL") \(what)")
    FileHandle.standardError.write(Data("check: \(lines.last!)\n".utf8))  // as it goes: a crash still shows how far it got
  }
  func press(_ key: String, _ mods: NSEvent.ModifierFlags = .command) async { _ = pressMenu(p, key, mods); await sleep(0.35) }

  func run() async {
    guard let ed = p.native else { check(false, "not in native mode"); finish(); return }
    check(p.nvim == nil && p.editor == nil && p.mode == "native", "native mode: no Neovim, no Neovim view")
    check(p.editorView === ed.view && ed.view.superview === p.editorHost, "the native editor sits in the editor column")
    check(p.margin.geometry === ed.view, "the margin's geometry is the native editor")
    let text = ed.view.textView.string
    check(text.contains("\\documentclass"), "the main file is open (\(text.count) characters)")
    check(p.window.firstResponder === ed.view.textView, "the text view takes the keys")
    let want = ProcessInfo.processInfo.environment["TAUDOT_NATIVECHECK_THEME"] ?? "dusk"
    check(ed.view.style.theme.id == want, "Settings' theme applies (\(ed.view.style.theme.id), want \(want))")
    // Pane keys work the same.
    await press("3"); await press("2")
    check(p.focusedPane == 1 && p.window.firstResponder === ed.view.textView, "⌘3 then ⌘2: back in the text view")
    await press("\\", [.command, .option])
    check(p.editorBox.isHidden && p.focusedPane != 1, "⌥⌘\\ hides the native editor too")
    await press("\\", [.command, .option])
    check(!p.editorBox.isHidden, "… and shows it")
    // ⌘L's reference from the native selection.
    let ns = text as NSString
    var starts = [0]
    for i in 0..<min(ns.length, 4000) where ns.character(at: i) == 10 { starts.append(i + 1) }
    if starts.count > 5 {
      ed.view.textView.setSelectedRange(NSRange(location: starts[2] + 1, length: starts[4] + 2 - starts[2] - 1))
      check(p.nativeRef(ed) == "@main.tex#L3-5", "⌘L's reference from a selection: \(p.nativeRef(ed) ?? "nil")")
    }
    // Settings ▸ Appearance, both ways: the text stays exactly where it was, and the chrome (window, status bar) follows.
    // (NSApp.appearance and the notification only: the user's setting isn't written.)
    ed.view.jump(line: 120, col: 0)
    await sleep(0.8)
    let clip = ed.view.scroll.contentView
    for look in [NSAppearance.Name.darkAqua, .aqua, .darkAqua] {
      let y0 = clip.bounds.origin.y
      let first0 = ed.view.textView.characterIndexForInsertion(at: NSPoint(x: 40, y: clip.bounds.minY + 4))
      // the notification first (the app re-applies the user's own setting on it), then the look under test
      NotificationCenter.default.post(name: TaudotSettings.changed, object: TaudotSettings.shared, userInfo: ["key": "taudot.appearance"])
      NSApp.appearance = NSAppearance(named: look)
      await sleep(0.8)
      let y1 = clip.bounds.origin.y
      let first1 = ed.view.textView.characterIndexForInsertion(at: NSPoint(x: 40, y: clip.bounds.minY + 4))
      check(abs(y1 - y0) < 0.5 && first0 == first1, "\(look == .aqua ? "light" : "dark"): the text stays put (top \(Int(y0)) → \(Int(y1)), first char \(first0) → \(first1))")
      let dark = p.window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      func isDark(_ v: NSView?) -> Bool? { v.map { $0.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua } }
      let chrome = [isDark(p.status), isDark(p.stripView), isDark(p.claudeFloat)]
      check(dark == (look == .darkAqua) && chrome.allSatisfy { $0 == nil || $0 == dark },
            "… the window, status bar, issues strip and Claude panel follow (\(dark ? "dark" : "light"))")
    }
    NSApp.appearance = nil
    // a real re-style (a bigger font) keeps the top line too
    let yA = clip.bounds.origin.y
    let firstA = ed.view.textView.characterIndexForInsertion(at: NSPoint(x: 40, y: clip.bounds.minY + 4))
    var bigger = ed.view.style
    bigger.fontSize += 2
    p.keepingTop(of: ed.view) { ed.view.apply(style: bigger) }
    await sleep(0.8)
    let firstB = ed.view.textView.characterIndexForInsertion(at: NSPoint(x: 40, y: clip.bounds.minY + 4))
    check(abs(firstB - firstA) <= 2, "a bigger font keeps the line at the top (first char \(firstA) → \(firstB), top \(Int(yA)) → \(Int(clip.bounds.origin.y)))")
    if ProcessInfo.processInfo.environment["TAUDOT_NO_PDF"] == nil, ProcessInfo.processInfo.environment["TAUDOT_NATIVECHECK_NOSYNC"] == nil { await sync(ed) }
    // Opening each style file from the Files sidebar's path (review.open, as a click does), then back to main.tex.
    let styles = ((try? FileManager.default.contentsOfDirectory(atPath: p.folder.path)) ?? []).filter { $0.hasSuffix(".sty") || $0.hasSuffix(".cls") || $0.hasSuffix(".bst") }.sorted()
    for f in styles {
      p.review?.open(p.folder.appendingPathComponent(f))
      for _ in 0..<40 where ed.current != f { await sleep(0.05) }
      await sleep(0.5)
      check(ed.current == f && !ed.view.textView.string.isEmpty, "the Files sidebar opens \(f) (current \(ed.current ?? "nil"), \(ed.view.textView.string.count) characters)")
    }
    if !styles.isEmpty {
      p.review?.open(p.folder.appendingPathComponent("main.tex"))
      for _ in 0..<40 where ed.current != "main.tex" { await sleep(0.05) }
      check(ed.current == "main.tex", "… and back to main.tex")
    }
    await nativeIssues(ed)
    let t0 = CACurrentMediaTime()
    let ok = await p.shutdown()
    check(ok && CACurrentMediaTime() - t0 < 1, "closing doesn't ask or wait")
    finish()
  }

  /// SyncTeX both ways, as in Neovim mode: a double-click on the PDF puts the caret on that source line, and a
  /// double-click in the editor shows that line in the PDF (a deliberate jump).
  func sync(_ ed: NativeEditor) async {
    for _ in 0..<900 where p.pdf.syncTex == nil { await sleep(0.1) }
    guard let st = p.pdf.syncTex else { check(false, "SyncTeX never arrived"); return }
    let text = ed.view.textView.string.components(separatedBy: "\n")
    // a body line with words on it (well after \begin{document})
    let begin = text.firstIndex { $0.contains("\\begin{document}") } ?? 0
    func prose(_ k: Int) -> Bool {
      let l = text[k]
      return k > begin && l.split(separator: " ").count > 6 && !l.hasPrefix("\\") && !l.hasPrefix("%")
    }
    guard let i = text.indices.first(where: prose), let f = st.forward(file: "main.tex", line: i + 1)
    else { check(false, "no body line found in the PDF"); return }
    let line = i + 1
    ed.view.jump(line: 1, col: 0)
    await sleep(0.3)
    // a real double-click, through the window, on that spot of the page
    let pane = p.pdf.view as! PDFPaneView
    pane.scrollTo(page: f.page, y: CGFloat(f.y))
    await sleep(0.3)
    let wpt = pane.convert(pane.toPane(pane.pagePoint(f.page, CGPoint(x: f.x + 5, y: f.y + f.h / 2))), to: nil)
    for n in [1, 2] {
      for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        if let e = NSEvent.mouseEvent(with: t, location: wpt, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: p.window.windowNumber, context: nil, eventNumber: 0, clickCount: n, pressure: 1) {
          p.window.sendEvent(e)
        }
      }
    }
    await sleep(0.8)
    let at = ed.view.lineCol(ed.view.caret).0 + 1
    let inv = p.pdf.lastInverse
    check(inv != nil && at == inv?.line,
          "PDF double-click → the editor's caret on that line (clicked line \(line), inverse \(inv.map { "\($0.path):\($0.line)" } ?? "none"), caret \(at))")
    check(p.window.firstResponder === ed.view.textView, "… and the editor has the keys")
    let vis = ed.view.scroll.contentView.bounds
    let caretY = ed.view.textView.firstRect(forCharacterRange: NSRange(location: ed.view.caret, length: 0), actualRange: nil)
    let local = ed.view.textView.convert(p.window.convertFromScreen(caretY), from: nil)
    check(vis.intersects(local), "… with that line in view (caret y \(Int(local.midY)), view \(Int(vis.minY))–\(Int(vis.maxY)))")
    // editor → PDF: a double-click on a word sends a deliberate cursor event for its line
    let b = ed.bridge
    var got: [Value]?
    b.notify("taudot_app_cursor") { a in got = a }
    let tv = ed.view.textView
    let ns = tv.string as NSString
    var loc = 0
    for _ in 0..<(line - 1) { loc = NSMaxRange(ns.lineRange(for: NSRange(location: loc, length: 0))) }
    ed.view.jump(line: 1, col: 0)
    await sleep(0.4)
    got = nil
    tv.scrollRangeToVisible(NSRange(location: loc, length: 0))
    guard let lm = tv.layoutManager, let tc = tv.textContainer else { return }
    let g = lm.glyphIndexForCharacter(at: loc + 2)
    var r = lm.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: tc)
    r.origin.x += tv.textContainerOrigin.x; r.origin.y += tv.textContainerOrigin.y
    let pt = tv.convert(NSPoint(x: r.midX, y: r.midY), to: nil)
    func ev(_ t: NSEvent.EventType, _ n: Int) -> NSEvent? {
      NSEvent.mouseEvent(with: t, location: pt, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: p.window.windowNumber, context: nil, eventNumber: 0, clickCount: n, pressure: 1)
    }
    for n in [1, 2] {
      guard let d = ev(.leftMouseDown, n), let u = ev(.leftMouseUp, n) else { continue }
      NSApp.postEvent(u, atStart: false)  // ends the text view's tracking loop
      tv.mouseDown(with: d)
      await sleep(0.05)
    }
    for _ in 0..<20 where got == nil || got?[2].bool != true { await sleep(0.05) }
    check(got?[0].string == "main.tex" && got?[1].int == line && got?[2].bool == true,
          "editor double-click → a deliberate forward search for line \(line) (got \(got.map { "\($0)" } ?? "nothing"))")
  }

  func finish() {
    try? (lines.joined(separator: "\n") + "\n").write(to: out, atomically: true, encoding: .utf8)
    p.window.close()
  }
}
