// TAUDOT_CYCLECHECK=FILE (Tests/review_cycle.sh): cycling through comments with real keys, in the editor mode the
// window runs (native, with or without Vim keys, or Neovim). The window comes to the front for a few seconds and the
// keys are posted at the HID level, so they take the real path: window server → key equivalents → menu → action.
import AppKit
import TaudotNeovim
import TaudotReview
import TaudotShared

@MainActor final class CycleCheck {
  let p: ProjectWindow
  let out: URL
  var lines: [String] = []
  init(_ p: ProjectWindow, out: URL) { self.p = p; self.out = out }
  func sleep(_ s: Double) async { try? await Task.sleep(for: .milliseconds(Int(s * 1000))) }
  func check(_ ok: Bool, _ what: String) { lines.append("\(ok ? "ok  " : "FAIL") \(what)") }

  /// The caret's 0-based line.
  func caretLine() async -> Int {
    if let ed = p.native { return ed.view.lineCol(ed.view.caret).0 }
    return ((try? await p.nvim?.execLua("return vim.api.nvim_win_get_cursor(0)[1] - 1", []))?.int) ?? -1
  }

  func key(_ code: CGKeyCode, _ flags: CGEventFlags = []) async {
    for down in [true, false] {
      guard let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { continue }
      e.flags = flags
      e.post(tap: .cghidEventTap)
      await sleep(0.02)
    }
    await sleep(0.35)
  }
  /// A key sequence at typing speed (a pause longer than Neovim's 'timeoutlen' would split `]r` into `]` and `r`).
  func type(_ s: String) async {
    let codes: [Character: CGKeyCode] = ["]": 30, "[": 33, "r": 15, "g": 5, "a": 0, "x": 7]
    for ch in s {
      guard let c = codes[ch] else { continue }
      for down in [true, false] {
        // (explicitly no modifiers: an event without a source inherits the last ones posted, here ⌥⌘)
        let e = CGEvent(keyboardEventSource: nil, virtualKey: c, keyDown: down)
        e?.flags = []
        e?.post(tap: .cghidEventTap)
        await sleep(0.015)
      }
      await sleep(0.04)
    }
    await sleep(0.5)
  }

  func run() async {
    await sleep(2)
    // Three comments on three lines (through the bridge: the same act the margin's draft uses).
    let rows = [3, 8, 14]
    for (k, l) in rows.enumerated() {
      let args: Value = .map([(.string("text"), .string("cycle \(k)")), (.string("line"), .int(Int64(l))), (.string("col"), .int(0)),
                              (.string("end_line"), .int(Int64(l))), (.string("end_col"), .int(4))])
      _ = try? await (p.native?.bridge as NeovimBridge? ?? p.nvim)?.execLua("return require('taudot.gui').act(...)", [.string("comment"), .null, args])
    }
    for _ in 0..<50 where p.margin.state.items.filter({ $0.kind == .comment }).count < 3 { await sleep(0.1) }
    check(p.margin.state.items.filter { $0.kind == .comment }.count >= 3, "three comments (\(p.margin.state.items.count) items)")
    // The caret at the top, the window in front, the keys from the HID level.
    if let ed = p.native { ed.view.jump(line: 1, col: 0) } else { _ = try? await p.nvim?.execLua("vim.api.nvim_win_set_cursor(0, {1, 0})", []) }
    NSApp.activate(ignoringOtherApps: true)
    p.window.makeKeyAndOrderFront(nil)
    p.focus(pane: 1)
    await sleep(0.6)
    lines.append("info mode \(p.mode), vim keys \(TaudotSettings.shared.vimKeys), first responder \(p.window.firstResponder.map { String(describing: Swift.type(of: $0)) } ?? "nil")")
    var seen: [Int] = []
    var opened: [String] = []
    // After each landing: the card of the comment there is selected and open (its reply field shown).
    func landedOpen() -> String {
      guard p.margin.selectedID != nil else { return "none selected" }
      return p.margin.selectedCardIsOpen ? "open" : "selected, not open"
    }
    for _ in 0..<4 { await key(125, [.maskCommand, .maskAlternate]); seen.append(await caretLine()); await sleep(0.3); opened.append(landedOpen()) }  // ⌥⌘↓
    check(Array(seen.prefix(3)) == rows, "⌥⌘↓ goes comment to comment: lines \(seen) (want \(rows) then round)")
    check(seen.count == 4 && seen[3] == rows[0], "… and round to the first (\(seen.last ?? -1))")
    check(opened.allSatisfy { $0 == "open" }, "each landed card opens with its reply field: \(opened)")
    seen = []
    for _ in 0..<2 { await key(126, [.maskCommand, .maskAlternate]); seen.append(await caretLine()) }  // ⌥⌘↑
    check(seen == [rows[2], rows[1]], "⌥⌘↑ goes back: \(seen)")
    check(!(p.review?.bar.isHidden ?? true), "the review bar shows while cycling")
    // The bar's arrows.
    let before = await caretLine()
    p.review?.bar.buttons["next"]?.performClick(nil)
    await sleep(0.4)
    check(await caretLine() != before, "the bar's ↓ moves on (\(before) → \(await caretLine()))")
    // ]r / [r from the keyboard where there are Vim keys (Neovim, or native with Vim keys).
    if p.mode != "native" || TaudotSettings.shared.vimKeys {
      p.focus(pane: 1)
      if let ed = p.native { ed.view.jump(line: 1, col: 0) } else { _ = try? await p.nvim?.execLua("vim.api.nvim_win_set_cursor(0, {1, 0})", []) }
      await sleep(0.3)
      var r: [Int] = []
      for _ in 0..<2 { await type("]r"); r.append(await caretLine()) }
      await type("[r"); r.append(await caretLine())
      check(r == [rows[0], rows[1], rows[0]], "]r ]r [r: \(r)")
      await sleep(0.3)
      check(landedOpen() == "open", "the card ]r / [r lands on opens (\(landedOpen()))")
    }
    // Stacked: ⌥⌘↓ goes through the list; the editor lands on each, the list stays, the card opens.
    p.sidebar.setLayout(.stacked)
    p.focus(pane: 1)
    if let ed = p.native { ed.view.jump(line: 1, col: 0) } else { _ = try? await p.nvim?.execLua("vim.api.nvim_win_set_cursor(0, {1, 0})", []) }
    p.margin.select(nil)
    await sleep(0.4)
    var st: [Int] = [], op: [String] = []
    let off0 = p.margin.stackOffset
    for _ in 0..<3 { await key(125, [.maskCommand, .maskAlternate]); await sleep(0.3); st.append(await caretLine()); op.append(landedOpen()) }
    check(st == rows, "stacked: ⌥⌘↓ takes the editor to each comment in the list: \(st)")
    check(op.allSatisfy { $0 == "open" } && p.margin.stackOffset == off0, "stacked: each card opens, the list stays (\(op), offset \(p.margin.stackOffset))")
    p.sidebar.setLayout(.beside)
    finish()
  }

  func finish() {
    try? (lines.joined(separator: "\n") + "\n").write(to: out, atomically: true, encoding: .utf8)
    p.window.close()
    NSApp.terminate(nil)
  }
}
