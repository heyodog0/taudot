// TAUDOT_OUTSIDECHECK=FILE (Tests/outside_check.sh, editfix item 9): edits written to the project's file on disk while
// the window is open (the mock engine sends them as `source: "disk"`, as the real engine does), in the editor mode the
// window runs. Highlights in the editor and on the PDF that fade, the Changes list and its Undo, the off-screen pill,
// Follow Edits (and that it waits while the user types), "Claude" while the Claude pane is busy. Off screen.
import AppKit
import TaudotEditor
import TaudotNeovim
import TaudotShared

@MainActor final class OutsideCheck {
  let p: ProjectWindow
  let out: URL
  var lines: [String] = []
  init(_ p: ProjectWindow, out: URL) { self.p = p; self.out = out }
  func sleep(_ s: Double) async { try? await Task.sleep(for: .milliseconds(Int(s * 1000))) }
  func check(_ ok: Bool, _ what: String) { lines.append("\(ok ? "ok  " : "FAIL") \(what)") }
  func wait(_ s: Double, _ cond: () async -> Bool) async -> Bool {
    for _ in 0..<Int(s * 20) { if await cond() { return true }; await sleep(0.05) }
    return await cond()
  }
  var file: URL { p.folder.appendingPathComponent("main.tex") }

  /// The file on disk, edited as another program would: `old` replaced by `new` (first occurrence).
  func diskEdit(_ old: String, _ new: String) {
    guard var t = try? String(contentsOf: file, encoding: .utf8), let r = t.range(of: old) else { lines.append("FAIL no \(old) in the file"); return }
    t.replaceSubrange(r, with: new)
    try? t.write(to: file, atomically: false, encoding: .utf8)
  }

  /// Editor highlights of outside edits now: (inserted, deletion marks).
  func editorMarks() async -> (Int, Int) {
    if let ed = p.native {
      return ed.view.flashCounts
    }
    let r = try? await p.nvim?.execLua("""
      local ns = vim.api.nvim_get_namespaces()['taudot.author']
      local ins, del = 0, 0
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })) do
        local hl = m[4].hl_group or ''
        if hl:match('^TaudotFade0_') then ins = ins + 1 elseif hl:match('^TaudotDeleted0_') then del = del + 1 end
      end
      return { ins, del }
      """, [])
    let a = r?.array ?? []
    return (a.first?.int ?? -1, a.count > 1 ? a[1].int ?? -1 : -1)
  }

  /// The editor's cursor line (1-based).
  func cursorLine() async -> Int {
    if let ed = p.native { return ed.view.lineCol(ed.view.caret).0 + 1 }
    return (try? await p.nvim?.execLua("return vim.api.nvim_win_get_cursor(0)[1]", []))?.int ?? -1
  }
  func setCursor(_ line: Int) async {
    if let ed = p.native { ed.view.jump(line: line, col: 0) } else {
      _ = try? await p.nvim?.execLua("vim.api.nvim_win_set_cursor(0, {\(line), 0}); vim.cmd('normal! zt')", [])
    }
    await sleep(0.3)
  }
  /// The source line (1-based) that starts with "Line n ".
  func lineOf(_ n: Int) -> Int {
    (text().components(separatedBy: "\n").firstIndex { $0.hasPrefix("Line \(n) ") } ?? -2) + 1
  }
  /// The editor's text as the window holds it.
  func text() -> String { p.outside.text("main.tex").map { String(decoding: $0, as: UTF8.self) } ?? "" }

  func run() async {
    for _ in 0..<300 where p.pdf.syncTex == nil { await sleep(0.1) }
    check(p.pdf.syncTex != nil, "the PDF typeset (mode \(p.mode))")
    await setCursor(1)
    _ = await wait(5) { !self.text().isEmpty }

    // 1. a disk edit near the top, in view: tinted in the editor (disk colour), listed, marked on the PDF, fading
    let n0 = p.outside.changes.count
    diskEdit("Line 5 words", "Line 5 freshly added words")
    let landed = await wait(5) { self.p.outside.changes.count > n0 }
    check(landed, "the disk edit reached the window (\(p.outside.changes.count) changes)")
    let c1 = p.outside.list.first
    check(c1?.who == "on disk" && c1?.disk == true, "labelled as made on disk: \(c1?.who ?? "-")")
    let m1 = await editorMarks()
    check(m1.0 >= 1, "the inserted text is tinted in the editor (\(m1))")
    check(p.changesView.rowsForTest.first?.undo == true, "listed in Changes with Undo: \(p.changesView.rowsForTest.first.map { "\($0.who) \($0.summary)" } ?? "-")")
    let pdfMarked = await wait(15) { !self.p.pdf.pane.editMarkRects.isEmpty }
    check(pdfMarked, "the changed lines are tinted on the PDF (\(p.pdf.pane.editMarkRects.count) rects)")
    // a deletion: its place marked
    diskEdit(" several more", "")
    _ = await wait(5) { self.p.outside.changes.count > n0 + 1 }
    let m2 = await editorMarks()
    check(m2.1 >= 1, "a deletion's place is marked (\(m2))")
    let faded = await wait(8) { let m = await self.editorMarks(); return m.0 == 0 && m.1 == 0 && self.p.pdf.pane.editMarkRects.isEmpty }
    check(faded, "all of it fades (editor \(await editorMarks()), PDF \(p.pdf.pane.editMarkRects.count))")

    // 2. Follow off: an edit far below the view shows the pill, and nothing moves
    p.followEdits = false
    await setCursor(1)
    diskEdit("Line 90 words", "Line 90 changed words")
    _ = await wait(5) { self.p.outside.changes.count > n0 + 2 }
    await sleep(0.3)
    check(!p.editPill.isHidden && p.editPill.title.contains("main.tex:\(lineOf(90))"), "an edit out of view shows the pill: \(p.editPill.isHidden ? "hidden" : p.editPill.title)")
    check(await cursorLine() == 1, "Follow off: the cursor stayed (\(await cursorLine()))")

    // 3. Follow on: the editor goes to each edit
    p.followEdits = true
    p.editPill.hide()
    diskEdit("Line 70 words", "Line 70 followed words")
    let went = await wait(5) { await self.cursorLine() == self.lineOf(70) }
    check(went, "Follow on: the editor went to the edit (cursor line \(await cursorLine()))")
    let pdfWent = await wait(15) { self.p.pdf.pane.editMarkRects.contains { self.p.pdf.pane.pagesInView.contains($0.page) } }
    check(pdfWent, "and the PDF scrolled to its marked lines (pages in view \(p.pdf.pane.pagesInView), marks on \(p.pdf.pane.editMarkRects.map(\.page)))")

    // 4. Follow waits while the user types: keys posted to the window, an edit lands, nothing moves until 2 s after
    await setCursor(10)
    let typing = Task { @MainActor in
      for _ in 0..<12 {
        if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: self.p.window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                                    isARepeat: false, keyCode: 63) {  // (fn: a key with no text, so nothing is typed)
          NSApp.postEvent(e, atStart: false)
        }
        try? await Task.sleep(for: .milliseconds(150))
      }
    }
    await sleep(0.3)
    diskEdit("Line 50 words", "Line 50 waited words")
    await sleep(1.0)
    let stayed = await cursorLine()
    check(stayed == 10, "while typing the editor stays (cursor line \(stayed))")
    await typing.value
    let followed = await wait(4) { await self.cursorLine() == self.lineOf(50) }
    check(followed, "after 2 s without a key it goes there (cursor line \(await cursorLine()))")
    p.followEdits = false

    // 5. Undo from the list: the text goes back while it is still as the edit left it
    if let c = p.outside.list.first(where: { String(decoding: $0.new, as: UTF8.self).contains("waited") }) {
      p.changesView.onUndo?(c)
      let undone = await wait(5) { !self.text().contains("Line 50 waited words") && self.text().contains("Line 50 words") }
      check(undone, "Undo put the text back")
      let onDisk = await wait(5) { (try? String(contentsOf: self.file, encoding: .utf8))?.contains("Line 50 words") == true }
      check(onDisk, "and it reached the file")
    } else { check(false, "the Line 50 change is listed: \(p.outside.list.map { OutsideEdits.summary($0) })") }

    // 6. Claude: a disk edit while the Claude pane's claude is writing
    p.claudeOutputAt = CACurrentMediaTime()
    let n6 = p.outside.changes.count
    diskEdit("Line 20 words", "Line 20 claude words")
    _ = await wait(5) { self.p.outside.changes.count > n6 }
    check(p.outside.list.first?.who == "Claude", "labelled Claude while the pane was busy: \(p.outside.list.first?.who ?? "-")")
    check(p.sidebar.changesLabel == "Changes \(p.outside.changes.count)" && p.changesView.rowsForTest.count == p.outside.changes.count,
          "the Changes tab: \(p.sidebar.changesLabel), \(p.changesView.rowsForTest.count) rows")
    if let f = ProcessInfo.processInfo.environment["TAUDOT_OUTSIDECHECK_SHOT"] {
      p.setPane(p.sidebar, hidden: false)
      p.sidebar.tab = .changes
      diskEdit("Line 8 words", "Line 8 shown words")
      await sleep(0.6)
      if let v = p.window.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: f))
      }
    }

    try? (lines.joined(separator: "\n") + "\n").write(to: out, atomically: true, encoding: .utf8)
    p.window.close()
    NSApp.terminate(nil)
  }
}
