// The find bar: its model (matches, smart case, whole word, regex errors, replacements, Vim patterns), the native
// editor's target (live search, n/N, replace one and all as one undo), the controller (typing coalesces, Enter after
// `/`), and Neovim's side (find.lua through a real headless Neovim).
import AppKit
import Foundation
import Testing
@testable import TaudotEditor
@testable import TaudotNeovim
import TaudotShared

private func ranges(_ q: FindQuery, _ s: String) -> [String] {
  guard case .success(let rs) = q.matches(in: s as NSString) else { return ["error"] }
  return rs.map { (s as NSString).substring(with: $0) }
}

@Test func findSmartCase() {
  let s = "Alpha alpha ALPHA"
  #expect(ranges(FindQuery("alpha"), s).count == 3)
  #expect(ranges(FindQuery("Alpha"), s) == ["Alpha"])
  #expect(ranges(FindQuery("alpha", matchCase: true), s) == ["alpha"])
  // a regex's escapes aren't capitals: \S stays smart
  #expect(!FindQuery(#"\Salpha"#, regex: true).caseSensitive)
  #expect(FindQuery(#"\SAlpha"#, regex: true).caseSensitive)
}

@Test func findLiteralWordAndRegex() {
  let s = #"a.b axb \cite{x} cite cites é_cite"#
  #expect(ranges(FindQuery("a.b"), s) == ["a.b"])  // literal: the dot is a dot
  #expect(ranges(FindQuery("a.b", regex: true), s) == ["a.b", "axb"])
  #expect(ranges(FindQuery(#"\cite{"#), s) == [#"\cite{"#])
  #expect(ranges(FindQuery("cite", wholeWord: true), s) == ["cite", "cite"])  // not "cites", not "é_cite"
  #expect(ranges(FindQuery("cite|axb", wholeWord: true, regex: true), s) == ["axb", "cite", "cite"])
  // empty matches are skipped
  #expect(ranges(FindQuery("x*", regex: true), s) == ["x", "x"])
}

@Test func findRegexErrors() {
  if case .failure(let e) = FindQuery("(ab", regex: true).compiled() { #expect(e.message == "Unclosed (") } else { Issue.record("compiled") }
  if case .failure(let e) = FindQuery("[ab", regex: true).compiled() { #expect(e.message == "Unclosed [") } else { Issue.record("compiled") }
  if case .failure(let e) = FindQuery("ab\\", regex: true).compiled() { #expect(e.message == "Ends with a backslash") } else { Issue.record("compiled") }
  // the same text, literal, is fine
  #expect(ranges(FindQuery("(ab"), "x(ab") == ["(ab"])
  #expect(FindCount(error: "Unclosed (").label == "Unclosed (")
  #expect(FindCount(current: 3, total: 17).label == "3 of 17")
  #expect(FindCount(current: 0, total: 0).label == "No matches")
  #expect(FindCount(current: 0, total: 4).label == "4 matches")
  #expect(FindCount(current: 2, total: 99, incomplete: true).label == "2 of 99+")
}

@Test func findReplacementText() {
  let s = "John Smith, Ada Lovelace" as NSString
  let q = FindQuery(#"(\w+) (\w+)"#, regex: true)
  guard case .success(let rs) = q.matches(in: s) else { Issue.record("no matches"); return }
  #expect(q.replacement(for: rs[0], in: s, with: #"\2, \1"#) == "Smith, John")
  #expect(q.replacement(for: rs[1], in: s, with: "$2 ($1)") == "Lovelace (Ada)")
  // literal: replaced as typed
  let lit = FindQuery("Smith")
  #expect(lit.replacement(for: NSRange(location: 5, length: 5), in: s, with: #"$1 \1 &"#) == #"$1 \1 &"#)
  // Vim's :s gets the literal text escaped, a regex's $1 as \1
  #expect(lit.vimReplacement(#"a\b&c~d/e"#) == #"a\\b\&c\~d\/e"#)
  #expect(lit.vimReplacement("x\ny") == #"x\ry"#)
  #expect(q.vimReplacement("$2, $1/x") == #"\2, \1\/x"#)
}

@Test func findVimPatterns() {
  #expect(FindQuery("alpha").vimPattern == #"\c\Valpha"#)
  #expect(FindQuery("Alpha").vimPattern == #"\C\VAlpha"#)
  #expect(FindQuery("alpha", matchCase: true).vimPattern == #"\C\Valpha"#)
  #expect(FindQuery(#"a\b"#).vimPattern == #"\c\Va\\b"#)
  #expect(FindQuery("cite", wholeWord: true).vimPattern == #"\c\V\<cite\>"#)
  #expect(FindQuery("a|b", regex: true).vimPattern == #"\c\va|b"#)
  #expect(FindQuery("a|b", wholeWord: true, regex: true).vimPattern == #"\c\v<%(a|b)>"#)
  // back from the history
  for q in [FindQuery("alpha"), FindQuery("Alpha"), FindQuery("alpha", matchCase: true), FindQuery(#"a\b"#), FindQuery("cite", wholeWord: true),
            FindQuery("a|b", regex: true), FindQuery("a|b", wholeWord: true, regex: true), FindQuery("x", matchCase: true, wholeWord: true)] {
    #expect(FindQuery.fromVim(q.vimPattern) == q, "\(q.vimPattern)")
  }
  #expect(FindQuery.fromVim("foo") == nil)  // typed at Neovim's own / : not the bar's
  #expect(FindQuery.fromVim(#"\c\Vfo\no"#) == nil)
  // plain words go to Neovim plain when the user's options already give the case
  #expect(FindQuery("model").vimPattern(ignorecase: true, smartcase: true) == "model")
  #expect(FindQuery("Model").vimPattern(ignorecase: true, smartcase: true) == "Model")
  #expect(FindQuery("model", matchCase: true).vimPattern(ignorecase: true, smartcase: true) == #"\Cmodel"#)
  #expect(FindQuery("Model").vimPattern(ignorecase: true, smartcase: false) == #"\CModel"#)
  #expect(FindQuery("model").vimPattern(ignorecase: false, smartcase: false) == #"\cmodel"#)
  #expect(FindQuery("cite", wholeWord: true).vimPattern(ignorecase: true, smartcase: true) == #"\<cite\>"#)
  #expect(FindQuery("a.b").vimPattern(ignorecase: true, smartcase: true) == #"\c\Va.b"#)
  #expect(FindQuery.fromVim("model", ignorecase: true, smartcase: true) == FindQuery("model"))
  #expect(FindQuery.fromVim("model", ignorecase: false, smartcase: false) == FindQuery("model", matchCase: true))
  #expect(FindQuery.fromVim(#"\<cite\>"#, ignorecase: true, smartcase: true) == FindQuery("cite", wholeWord: true))
  #expect(FindQuery.fromVim("Model", ignorecase: true, smartcase: false) == nil)
  #expect(FindQuery.fromVim("a.b", ignorecase: true, smartcase: true) == nil)
}

@Test func findMatchIndex() {
  let m = FindMatches(ranges: [NSRange(location: 2, length: 1), NSRange(location: 5, length: 1), NSRange(location: 9, length: 1)])
  #expect(m.index(from: 0, forward: true) == 0)
  #expect(m.index(from: 2, forward: true) == 1)          // after, not at (Vim's /)
  #expect(m.index(from: 2, forward: true, inclusive: true) == 0)
  #expect(m.index(from: 9, forward: true) == 0)          // wraps
  #expect(m.index(from: 5, forward: false) == 0)
  #expect(m.index(from: 1, forward: false) == 2)         // wraps
  #expect(m.index(at: 5) == 1)
  #expect(m.index(at: 6) == nil)
}

// MARK: the native editor

@MainActor private func nativeEditor(_ text: String) -> (NativeEditorView, NSWindow, NativeDoc) {
  let v = NativeEditorView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
  let w = NSWindow(contentRect: NSRect(x: -3000, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
  w.contentView = v
  let d = NativeDoc(docID: "d", path: "main.tex", text: text, seq: 0, conn: nil)
  v.show(d, buffer: 1)
  return (v, w, d)
}

@MainActor @Test func findNativeSearchStepReplace() async {
  let (v, w, d) = nativeEditor("one two one\nthree one\nOne\n")
  _ = w
  let t = NativeFindTarget(editor: v)
  let tv = v.textView
  tv.setSelectedRange(NSRange(location: 4, length: 0))
  _ = await t.findBegin(backward: false)
  var c = await t.findSearch(FindQuery("one"))
  #expect(c == FindCount(current: 2, total: 4))           // the first after the caret
  #expect(tv.selectedRange() == NSRange(location: 8, length: 3))  // selected (no Vim)
  #expect(v.findMarkRanges.ranges.count == 4 && v.findMarkRanges.current == 1)
  c = await t.findStep(forward: true)
  #expect(c.current == 3)
  c = await t.findStep(forward: false)
  c = await t.findStep(forward: false)
  #expect(c.current == 1)
  c = await t.findStep(forward: false)
  #expect(c.current == 4)                                  // wraps
  c = await t.findSearch(FindQuery("One"))
  #expect(c.total == 1)                                    // smart case
  // replace one: the match at the caret, then on to the next
  _ = await t.findSearch(FindQuery("one"))
  tv.setSelectedRange(NSRange(location: 0, length: 3))
  // no event loop here: one undo group per action by hand, as each key event would make
  let um = tv.undoManager!
  um.groupsByEvent = false
  um.beginUndoGrouping()
  var (c2, n) = await t.findReplace(FindQuery("one"), with: "1", all: false)
  um.endUndoGrouping()
  #expect(n == 1)
  #expect(tv.string == "1 two one\nthree one\nOne\n")
  #expect(c2.total == 3 && tv.selectedRange() == NSRange(location: 6, length: 3))
  // replace all, one undo step
  um.beginUndoGrouping()
  (c2, n) = await t.findReplace(FindQuery("one", regex: true), with: "<$0>", all: false)
  um.endUndoGrouping()
  #expect(n == 1)
  um.beginUndoGrouping()
  (c2, n) = await t.findReplace(FindQuery("(o)ne", regex: true), with: "[$1]", all: true)
  um.endUndoGrouping()
  #expect(n == 3)
  #expect(tv.string == "1 two <[o]>\nthree [o]\n[O]\n")
  #expect(d.string == tv.string)                           // the engine's copy saw every edit
  #expect(c2.total == 0)
  um.undo()
  #expect(tv.string == "1 two <one>\nthree one\nOne\n")
  #expect(d.string == tv.string)
  // closing with no match: back where it started
  await t.findEnd(keep: true)
  #expect(v.findMarkRanges.ranges.isEmpty)
}

@MainActor @Test func findNativeVimMode() async {
  let (v, w, _) = nativeEditor("alpha beta\nbeta gamma\nbeta\n")
  _ = w
  v.vimEnabled = true
  var opened: Character?
  v.onVimSearchKey = { c in opened = c; return true }
  let vim = v.vimEngine!
  vim.feed("/")
  #expect(opened == "/")
  #expect(vim.cmdline == nil)                              // the bar took it, not Vim's own line
  let t = NativeFindTarget(editor: v)
  _ = await t.findBegin(backward: false)
  let c = await t.findSearch(FindQuery("beta"))
  #expect(c == FindCount(current: 1, total: 3))
  #expect(v.textView.selectedRange() == NSRange(location: 6, length: 0))  // Vim: the caret at the match, no selection
  await t.findEnd(keep: true)
  vim.feed("n")
  #expect(v.textView.selectedRange().location == 11)       // n continues the bar's search
  vim.feed("n")
  #expect(v.textView.selectedRange().location == 22)
  vim.feed("N")
  #expect(v.textView.selectedRange().location == 11)
  vim.feed("``")
  #expect(v.textView.selectedRange().location == 0 || v.textView.selectedRange().location == 22)
  // `d/` keeps Vim's own command line
  opened = nil
  vim.feed("d/")
  #expect(opened == nil && vim.cmdline != nil)
  vim.feed("<Esc>")
}

// MARK: the controller

@MainActor final class FakeTarget: FindTarget {
  var searched: [String] = []
  var ended: [Bool] = []
  var delay: Duration = .milliseconds(20)
  let findResponder = NSView()
  var onFindCount: ((FindCount) -> Void)?
  var onFindClose: (() -> Void)?
  func findBegin(backward: Bool) async -> [FindQuery] { [FindQuery("older"), FindQuery("oldest")] }
  func findSearch(_ q: FindQuery) async -> FindCount {
    searched.append(q.text)
    try? await Task.sleep(for: delay)
    return FindCount(current: q.text.isEmpty ? 0 : 1, total: q.text.count)
  }
  func findStep(forward: Bool) async -> FindCount { FindCount(current: forward ? 2 : 1, total: 5) }
  func findReplace(_ q: FindQuery, with template: String, all: Bool) async -> (FindCount, Int) { (FindCount(), all ? 5 : 1) }
  func findPassive(_ on: Bool) async {}
  func findEnd(keep: Bool) async { ended.append(keep) }
}

@MainActor @Test func findControllerCoalescesTyping() async {
  let host = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
  let w = NSWindow(contentRect: NSRect(x: -3000, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
  w.contentView = host
  let t = FakeTarget()
  let f = FindController(target: t)
  f.install(in: host)
  f.open()
  #expect(f.isOpen && !f.bar.isHidden)
  // the bar sits at the top right
  #expect(abs(f.bar.frame.maxX - (host.bounds.width - f.inset.width)) < 0.5)
  for s in ["a", "al", "alp", "alph", "alpha"] {
    f.bar.field.stringValue = s
    f.bar.changed()
  }
  await f.settle()
  // the first went at once; the middle ones were dropped; the last always runs
  #expect(t.searched.first == "a" && t.searched.last == "alpha" && t.searched.count <= 3)
  #expect(f.count.total == 5 && f.bar.countLabel.stringValue == "1 of 5")
  // history: ↑ shows older searches, ↓ back to what was typed
  try? await Task.sleep(for: .milliseconds(30))
  f.browseHistory(-1)
  #expect(f.bar.field.stringValue == "older")
  f.browseHistory(-1)
  #expect(f.bar.field.stringValue == "oldest")
  f.browseHistory(1)
  f.browseHistory(1)
  #expect(f.bar.field.stringValue == "alpha")
  await f.settle()
  f.close()
  try? await Task.sleep(for: .milliseconds(50))
  #expect(t.ended == [true])
  #expect(!f.isOpen)
}

@MainActor @Test func findControllerVimEnter() async {
  let host = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
  let w = NSWindow(contentRect: NSRect(x: -3000, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
  w.contentView = host
  let t = FakeTarget()
  host.addSubview(t.findResponder)
  let f = FindController(target: t)
  f.install(in: host)
  f.open(vim: true)
  f.bar.field.stringValue = "abc"
  f.bar.changed()
  await f.settle()
  f.enter(shift: false)
  // after `/`, Enter gives the editor the keys and the bar stays up (n / N update it)
  #expect(f.isOpen)
  #expect(w.firstResponder === t.findResponder)
  t.onFindCount?(FindCount(current: 3, total: 3))
  #expect(f.bar.countLabel.stringValue == "3 of 3")
  t.onFindClose?()
  #expect(!f.isOpen)
}

// MARK: Neovim (find.lua)

private let nvimPlugin = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../nvim").standardized.path

@MainActor @Test func findNeovimDrivesItsOwnSearch() async throws {
  let nv = try Neovim(args: ["--clean", "--headless", "-n", "--cmd", "set rtp+=" + nvimPlugin])
  defer { nv.terminate() }
  _ = try await nv.execLua("vim.api.nvim_buf_set_lines(0, 0, -1, false, {'alpha beta Alpha', 'foo/bar alpha', 'alphabet'}); vim.api.nvim_win_set_cursor(0, {1, 0})", [])
  let t = NeovimFindTarget(bridge: nv, responder: NSView())
  let chan = try await nv.channelID()
  await t.attach(channel: chan)
  // / opens the bar (a notification), Neovim's own / stays for `:`
  let opened = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
    t.onOpenRequest = { back in c.resume(returning: back) }
    nv.send("nvim_input", [.string("?")])
  }
  #expect(opened == true)
  _ = await t.findBegin(backward: false)
  var c = await t.findSearch(FindQuery("alpha"))
  #expect(c == FindCount(current: 2, total: 4))
  #expect(try await nv.execLua("return vim.api.nvim_win_get_cursor(0)", []) == .array([.int(1), .int(11)]))
  #expect(try await nv.execLua("return vim.fn.getreg('/')", []) == .string(#"\calpha"#))  // --clean: noignorecase, so the case goes in; nothing magic: no \V
  c = await t.findSearch(FindQuery("Alpha"))
  #expect(c.total == 1)
  c = await t.findSearch(FindQuery("(alp", regex: true))
  #expect(c.error == "Unmatched (")
  c = await t.findSearch(FindQuery("alpha", wholeWord: true))
  #expect(c.total == 3)
  c = await t.findStep(forward: true)
  #expect(c.current == 3)
  // replace through :s: a literal with / and &
  c = await t.findSearch(FindQuery("foo/bar"))
  var (r, n) = await t.findReplace(FindQuery("foo/bar"), with: "x/&y", all: false)
  #expect(n == 1 && r.total == 0)
  #expect(try await nv.execLua("return vim.api.nvim_buf_get_lines(0, 1, 2, false)[1]", []) == .string("x/&y alpha"))
  (r, n) = await t.findReplace(FindQuery("(a)lpha", regex: true), with: "[$1]", all: true)
  #expect(n == 4)
  #expect(try await nv.execLua("return vim.api.nvim_buf_get_lines(0, 0, -1, false)", []) == .array([.string("[a] beta [A]"), .string("x/&y [a]"), .string("[a]bet")]))
  // replace-all is one undo step
  _ = try await nv.execLua("vim.cmd('silent undo')", [])
  #expect(try await nv.execLua("return vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]", []) == .string("alpha beta Alpha"))
  // close: the pattern in the / history, n continues it
  _ = await t.findSearch(FindQuery("beta"))
  await t.findEnd(keep: true)
  #expect(try await nv.execLua("return vim.fn.histget('/', -1)", []) == .string(#"\cbeta"#))
  let hist = await t.findBegin(backward: false)
  #expect(hist.first == FindQuery("beta"))
  await t.findEnd(keep: false)
}
