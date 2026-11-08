// TAUDOT_FINDCHECK=FILE (Tests/find_app.sh): the find bar in a real project window, either editor mode, off screen.
// ⌘F, typing (counts against the text itself), Enter / ⇧⌘G, Esc (cursor left on the match), `/` (Enter gives the
// editor the keys, n moves the bar's count, Esc closes), ⌥⌘F replace one and all, undo. TAUDOT_FINDCHECK_SHOTS=DIR:
// window captures. TAUDOT_FINDCHECK_WORD: the word to search (default "model"). Timing per keystroke in the bar.
import AppKit
import TaudotEditor
import TaudotNeovim
import TaudotShared

@MainActor final class FindCheck {
  let p: ProjectWindow
  let out: URL
  var lines: [String] = []
  let env = ProcessInfo.processInfo.environment
  init(_ p: ProjectWindow, out: URL) { self.p = p; self.out = out }
  func sleep(_ s: Double) async { try? await Task.sleep(for: .milliseconds(Int(s * 1000))) }
  func check(_ ok: Bool, _ what: String) {
    lines.append("\(ok ? "ok  " : "FAIL") \(what)")
    FileHandle.standardError.write(Data("findcheck: \(lines.last!)\n".utf8))
  }
  func note(_ s: String) { lines.append("    " + s); FileHandle.standardError.write(Data("findcheck: \(s)\n".utf8)) }
  var f: FindController { p.find! }
  var native: NativeEditor? { p.native }

  func shot(_ name: String) async {
    guard let dir = env["TAUDOT_FINDCHECK_SHOTS"] else { return }
    await sleep(0.4)
    let pr = Process()
    pr.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    pr.arguments = ["-x", "-o", "-l\(p.window.windowNumber)", dir + "/" + name + ".png"]
    try? pr.run()
    pr.waitUntilExit()
    note("shot \(name).png")
  }

  /// The field editor, while the bar's field has the keys.
  var fieldEditor: NSTextView? {
    guard let t = p.window.firstResponder as? NSTextView, t.isFieldEditor else { return nil }
    return t
  }

  func type(_ s: String) async {
    for ch in s {
      guard let fe = fieldEditor else { check(false, "typing: the bar has no keys"); return }
      fe.insertText(String(ch), replacementRange: fe.selectedRange())
    }
    await f.settle()
    await sleep(0.15)
  }

  func command(_ sel: Selector) async {
    fieldEditor?.doCommand(by: sel)
    await f.settle()
    await sleep(0.2)
  }

  func clearField() async {
    fieldEditor?.selectAll(nil)
    fieldEditor?.insertText("", replacementRange: fieldEditor?.selectedRange() ?? NSRange())
    await f.settle()
  }

  /// The buffer's text and the cursor (UTF-16 offset) in either mode.
  func text() async -> String {
    if let n = native { return n.view.textView.string }
    return (try? await p.nvim.execLua("return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\\n')", []))?.string ?? ""
  }
  func cursor() async -> Int {
    if let n = native { return n.view.textView.selectedRange().location }
    let r = (try? await p.nvim.execLua("local r, c = unpack(vim.api.nvim_win_get_cursor(0)); return vim.fn.line2byte(r) - 1 + c", []))?.int ?? -1
    let t = await text()
    return Utf.utf16(Array(t.utf8), max(0, r))
  }

  func run() async {
    for _ in 0..<200 where !p.editorStarted { await sleep(0.05) }
    await sleep(1.0)
    let word = env["TAUDOT_FINDCHECK_WORD"] ?? "model"
    let mode = native == nil ? "neovim" : "native"
    note("mode \(mode), word \(word)")
    let body = await text()
    guard case .success(let all) = FindQuery(word).matches(in: body as NSString), all.count >= 3 else {
      check(false, "the doc has \(word) at least 3 times"); finish(); return
    }
    // ⌘F from the top of the file
    if let n = native { n.view.textView.setSelectedRange(NSRange(location: 0, length: 0)) } else { p.nvim.input("gg0"); await sleep(0.2) }
    _ = pressMenu(p, "f")
    await sleep(0.3)
    check(f.isOpen && !f.bar.isHidden && fieldEditor != nil, "⌘F opens the bar with the keys in its field")
    let top = p.editorHost.isFlipped ? f.bar.frame.minY : p.editorHost.bounds.height - f.bar.frame.maxY
    let corner = f.bar.frame.maxX > p.editorHost.bounds.width - 40 && top < 30
    check(corner, "the bar sits at the editor column's top right (\(f.bar.frame))")
    await clearField()
    await type(word)
    check(f.count.total == all.count && f.count.current == 1, "typing '\(word)': \(f.bar.countLabel.stringValue) (want 1 of \(all.count))")
    let c0 = await cursor()
    check(c0 == all[0].location, "the cursor is on the first match (\(c0), want \(all[0].location))")
    await shot("find-\(mode)")
    await command(#selector(NSResponder.insertNewline(_:)))
    check(f.count.current == 2, "Enter: the next (\(f.bar.countLabel.stringValue))")
    _ = pressMenu(p, "g")
    await f.settle(); await sleep(0.2)
    check(f.count.current == 3, "⌘G: the next (\(f.bar.countLabel.stringValue))")
    _ = pressMenu(p, "G")
    await f.settle(); await sleep(0.2)
    check(f.count.current == 2, "⇧⌘G: the previous (\(f.bar.countLabel.stringValue))")
    // options: whole word / case
    f.bar.toggle("case")
    await f.settle(); await sleep(0.1)
    let exact = (try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: word)))?.numberOfMatches(in: body, range: NSRange(location: 0, length: (body as NSString).length)) ?? -1
    check(f.count.total == exact, "match case: \(f.count.total) (want \(exact))")
    f.bar.toggle("case")
    await f.settle()
    await type("(")
    check(f.count.total == 0 && f.bar.countLabel.stringValue == "No matches", "no match says so: \(f.bar.countLabel.stringValue)")
    f.bar.toggle("regex")
    await f.settle(); await sleep(0.1)
    check(f.count.error != nil, "a broken regex says why: \(f.bar.countLabel.stringValue)")
    await shot("find-\(mode)-regex-error")
    f.bar.toggle("regex")
    fieldEditor?.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
    await f.settle(); await sleep(0.1)
    // Esc: closed, cursor on the match
    let before = f.count.current
    await command(#selector(NSResponder.cancelOperation(_:)))
    await sleep(0.3)
    let c1 = await cursor()
    check(!f.isOpen && (f.bar.isHidden || f.bar.alphaValue < 0.01), "Esc closes the bar")
    check(all.firstIndex { $0.location == c1 } == before - 1, "… leaving the cursor on match \(before) (\(c1))")
    check(p.window.firstResponder === p.editorResponder, "… and the editor has the keys")

    // `/`: Vim's key opens the bar; Enter gives the editor the keys, the bar stays and n moves its count; Esc closes
    if let n = native {
      n.view.vimEnabled = true
      n.view.vimEngine?.feed("gg")
      n.view.vimEngine?.feed("/")
    } else {
      p.nvim.input("gg/")
    }
    await sleep(0.4)
    check(f.isOpen && f.vimOpened && fieldEditor != nil && f.bar.field.stringValue.isEmpty, "/ opens the bar, empty, with the keys")
    await type(word)
    await shot("find-\(mode)-slash")
    await command(#selector(NSResponder.insertNewline(_:)))
    check(f.isOpen && p.window.firstResponder === p.editorResponder, "Enter after /: the editor has the keys, the bar stays up")
    let k0 = f.count.current
    if let n = native { n.view.vimEngine?.feed("n") } else { p.nvim.input("n") }
    for _ in 0..<40 where f.count.current == k0 { await sleep(0.05) }
    check(f.count.current == k0 + 1, "n moves the bar's count (\(k0) → \(f.count.current))")
    if let n = native {
      let esc = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: p.window.windowNumber,
                                 context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
      n.view.textView.keyDown(with: esc)
    } else {
      p.nvim.input("<Esc>")
    }
    for _ in 0..<20 where f.isOpen { await sleep(0.05) }
    if f.isOpen && native == nil {
      note("Esc in normal mode is the user's own mapping here: the bar stays (closing it with ✕)")
      f.close()
    } else {
      check(!f.isOpen, "Esc in the editor closes the bar")
    }
    if native == nil {
      let reg = (try? await p.nvim.execLua("return vim.fn.getreg('/')", []))?.string ?? ""
      check(reg == (f.target as? NeovimFindTarget)?.pattern(FindQuery(word)), "Neovim's search register is the bar's pattern (\(reg))")
    }

    // ⌥⌘F: replace one, then all, then undo
    if let n = native { n.view.textView.setSelectedRange(NSRange(location: 0, length: 0)) } else { p.nvim.input("gg0"); await sleep(0.2) }
    await sleep(0.4)  // the close's animation
    _ = pressMenu(p, "f", [.command, .option])
    await sleep(0.3)
    check(f.isOpen && f.bar.replaceShown, "⌥⌘F opens the bar with its replace row")
    p.window.makeFirstResponder(f.bar.field)
    await clearField()
    await type(word)
    p.window.makeFirstResponder(f.bar.replaceField)
    fieldEditor?.insertText("REPLACED", replacementRange: fieldEditor?.selectedRange() ?? NSRange())
    await shot("find-\(mode)-replace")
    // All first, then one, each undone at once: with no input events (an off-screen run) the app's undo groups only
    // end at an undo, so each replace is checked alone.
    f.replace(all: true)
    await f.settle(); await sleep(0.4)
    var t = await text()
    let many = t.components(separatedBy: "REPLACED").count - 1
    check(many == all.count && f.count.total == 0, "Replace All: every match (\(many) of \(all.count))")
    await shot("find-\(mode)-replaced")
    func undo() async {
      if let n = native { n.view.textView.undoManager?.undo() } else { _ = try? await p.nvim.execLua("vim.cmd('silent undo')", []) }
      await sleep(0.4)
    }
    await undo()
    t = await text()
    check(t == body, "one undo takes back Replace All")
    f.refresh()
    await f.settle()
    if let n = native { n.view.textView.setSelectedRange(NSRange(location: 0, length: 0)) } else { _ = try? await p.nvim.execLua("vim.api.nvim_win_set_cursor(0, {1, 0})", []) }
    p.window.makeFirstResponder(f.bar.replaceField)
    await command(#selector(NSResponder.insertNewline(_:)))  // not on a match: goes to the first
    await command(#selector(NSResponder.insertNewline(_:)))  // replaces it, on to the next
    t = await text()
    let one = t.components(separatedBy: "REPLACED").count - 1
    check(one == 1 && f.count.total == all.count - 1 && t.range(of: "REPLACED")?.lowerBound == t.index(t.startIndex, offsetBy: (t as NSString).substring(to: all[0].location).count),
          "Enter in Replace: the first match replaced (\(one)), \(f.count.total) left")
    await undo()
    t = await text()
    check(t == body, "… undone: the text is back")
    if f.isOpen { f.close() }
    await sleep(0.3)

    await timing(word)
    finish()
  }

  /// Keystrokes in the bar, one at a time: until the count is back (the search ran and the matches are marked) and,
  /// in Neovim mode, Neovim's redraw of the highlights has been flushed.
  func timing(_ word: String) async {
    if let n = native { n.view.textView.setSelectedRange(NSRange(location: 0, length: 0)) } else { p.nvim.input("gg0"); await sleep(0.2) }
    _ = pressMenu(p, "f")
    await sleep(0.3)
    var ms: [Double] = []
    var flushMs: [Double] = []
    for round in 0..<4 {
      await clearField()
      await sleep(0.1)
      for ch in word {
        guard let fe = fieldEditor else { break }
        let n0 = f.searches
        var flushed: CFTimeInterval = 0
        if let ed = p.editor { ed.onFlush = { if flushed == 0 { flushed = CACurrentMediaTime() } } }
        let t0 = CACurrentMediaTime()
        fe.insertText(String(ch), replacementRange: fe.selectedRange())
        while f.searches == n0 { try? await Task.sleep(for: .microseconds(200)) }
        let t1 = CACurrentMediaTime()
        if p.editor != nil {
          for _ in 0..<200 where flushed == 0 { try? await Task.sleep(for: .microseconds(250)) }
          if flushed > 0 && round > 0 { flushMs.append((max(flushed, t1) - t0) * 1000) }
        }
        if round > 0 { ms.append((t1 - t0) * 1000) }
        await sleep(0.05)
      }
    }
    p.editor?.onFlush = nil
    func stat(_ xs: [Double]) -> String {
      let s = xs.sorted()
      guard !s.isEmpty else { return "-" }
      return String(format: "p50 %.1f ms, max %.1f ms (n=%d)", s[s.count / 2], s.last!, s.count)
    }
    note("keystroke → count back: \(stat(ms))")
    if !flushMs.isEmpty { note("keystroke → Neovim's highlight redraw flushed: \(stat(flushMs))") }
    let worst = (flushMs.isEmpty ? ms : flushMs).sorted()
    let p50 = worst.isEmpty ? 99 : worst[worst.count / 2]
    check(p50 < 16.7, "typing in the bar: the highlight update within a frame (p50 \(String(format: "%.1f", p50)) ms)")
    f.close()
  }

  func finish() {
    try? (lines.joined(separator: "\n") + "\n").write(to: out, atomically: true, encoding: .utf8)
    Task { _ = await p.shutdown(); p.window.close() }
  }
}
