// TAUDOT_FLOATCHECK=FILE (Tests/uifix_float.sh): the floating card of the comment under the cursor, in the editor
// mode the window runs (native or Neovim), with the comments pane hidden. Background only: the caret is moved through
// the editor's own API, no keys are posted, nothing comes to the front.
import AppKit
import TaudotNeovim
import TaudotReview
import TaudotShared

@MainActor final class FloatCheck {
  let p: ProjectWindow
  let out: URL
  var lines: [String] = []
  init(_ p: ProjectWindow, out: URL) { self.p = p; self.out = out }
  func sleep(_ s: Double) async { try? await Task.sleep(for: .milliseconds(Int(s * 1000))) }
  func check(_ ok: Bool, _ what: String) { lines.append("\(ok ? "ok  " : "FAIL") \(what)") }

  /// The caret to a 0-based line and column.
  func caret(_ l: Int, _ c: Int) async {
    if let ed = p.native { ed.view.jump(line: l + 1, col: c) } else {
      _ = try? await p.nvim?.execLua("vim.api.nvim_win_set_cursor(0, {\(l + 1), \(c)})", [])
    }
    await sleep(0.7)
  }
  var where_: String {
    let m = p.margin
    return "cursor \(m.cursor.line):\(m.cursor.col) buf \(m.cursor.buf)/\(m.state.buf) here \(m.cursor.here.count), floating \(m.floatingIDs.count) \(m.floatingFrame.map { NSStringFromRect($0) } ?? "-")"
  }

  func run() async {
    await sleep(2)
    let rows = [3, 8]
    // TAUDOT_FLOATCHECK_EXISTING=1: the comments are already there (a second run on the same project)
    for (k, l) in rows.enumerated() where ProcessInfo.processInfo.environment["TAUDOT_FLOATCHECK_EXISTING"] == nil {
      let args: Value = .map([(.string("text"), .string("float \(k)")), (.string("line"), .int(Int64(l))), (.string("col"), .int(0)),
                              (.string("end_line"), .int(Int64(l))), (.string("end_col"), .int(6))])
      _ = try? await (p.native?.bridge as NeovimBridge? ?? p.nvim)?.execLua("return require('taudot.gui').act(...)", [.string("comment"), .null, args])
    }
    for _ in 0..<50 where p.margin.state.items.filter({ $0.kind == .comment }).count < 2 { await sleep(0.1) }
    check(p.margin.state.items.filter { $0.kind == .comment }.count >= 2, "two comments (\(p.margin.state.items.count) items)")
    lines.append("info mode \(p.mode), pane hidden \(p.margin.paneHidden)")
    await caret(rows[0], 2)
    check(p.margin.floatingIDs.count == 1 && p.margin.floatingFrame != nil, "a card floats in the first comment: \(where_)")
    await caret(5, 0)
    await sleep(0.4)
    check(p.margin.floatingIDs.isEmpty, "none between them: \(where_)")
    await caret(rows[1], 3)
    check(p.margin.floatingIDs.count == 1 && p.margin.floatingFrame != nil, "a card floats in the second: \(where_)")
    // The end-of-line notes (Neovim's inline notes; the native editor's lineNotes), then View ▸ Comments in the Text.
    let n0 = await notes()
    check(n0.count == 2, "an end-of-line note on each commented line: \(n0)")
    shoot("TAUDOT_FLOATCHECK_SHOT")
    p.toggleCommentsInText(nil)
    await sleep(0.6)
    check(p.margin.floatingIDs.isEmpty, "hidden: the card goes: \(where_)")
    check(await notes().isEmpty, "hidden: no end-of-line notes (\(await notes()))")
    if let ed = p.native { check(ed.view.tintRanges.isEmpty, "hidden: no comment tints (\(ed.view.tintRanges.count))") } else {
      let c = await nvimMarked()
      check(c == 0, "hidden: no comment colour or sign in Neovim (\(c) marked)")
    }
    check(p.sidebar.inlineHidden, "hidden: the sidebar's eye shows it")
    await caret(rows[0], 1)
    check(p.margin.floatingIDs.isEmpty, "hidden: none at another comment: \(where_)")
    check(p.margin.state.items.filter { $0.kind == .comment }.count >= 2, "hidden: the sidebar's list keeps them")
    shoot("TAUDOT_FLOATCHECK_SHOT_HIDDEN")
    p.toggleCommentsInText(nil)
    await sleep(0.6)
    check(p.margin.floatingIDs.count == 1, "shown again: the card at the cursor is back: \(where_)")
    check(await notes().count == 2, "shown again: the notes are back")
    if p.native == nil { let c = await nvimMarked(); check(c >= 2, "shown again: Neovim colours them (\(c) marked)") }
    // The comments margin on screen: its cards take over, the notes go (gui.lua margin_shown).
    p.sidebar.tab = .comments
    p.toggleMargin(nil)
    await sleep(0.8)
    shoot("TAUDOT_FLOATCHECK_SHOT_MARGIN")
    let shownNotes = await notes()
    check(!p.margin.paneHidden && shownNotes.isEmpty, "the margin shown: no end-of-line notes (\(shownNotes))")
    p.toggleMargin(nil)
    await sleep(0.8)
    let backNotes = await notes()
    check(backNotes.count == 2, "the margin hidden again: the notes are back (\(backNotes))")
    finish()
  }

  /// The end-of-line notes now, as text.
  func notes() async -> [String] {
    if let ed = p.native { return ed.lineNotes.map(\.string) }
    let v = try? await p.nvim?.execLua("""
      local ns, out = vim.api.nvim_create_namespace('taudot.inline'), {}
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })) do
        local t = ''
        for _, c in ipairs(m[4].virt_text or {}) do t = t .. c[1] end
        out[#out + 1] = t
      end
      return out
      """, [])
    if case let .array(a)? = v { return a.compactMap(\.string) }
    return []
  }

  /// Neovim's comment extmarks that colour their text or carry a sign.
  func nvimMarked() async -> Int {
    let v = try? await p.nvim?.execLua("""
      local ns, n = vim.api.nvim_create_namespace('taudot.comment'), 0
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })) do
        if m[4].hl_group or m[4].sign_text then n = n + 1 end
      end
      return n
      """, [])
    return v?.int ?? -1
  }

  func shoot(_ env: String) {
    if let f = ProcessInfo.processInfo.environment[env], let v = p.window.contentView,
       let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
      v.cacheDisplay(in: v.bounds, to: rep)
      try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: f))
    }
  }

  func finish() {
    try? (lines.joined(separator: "\n") + "\n").write(to: out, atomically: true, encoding: .utf8)
    p.window.close()
    NSApp.terminate(nil)
  }
}
