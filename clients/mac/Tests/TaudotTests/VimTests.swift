import AppKit
import Foundation
import Testing
@testable import TaudotEditor

/// A VimBuffer in memory, undo by snapshots.
@MainActor final class MemBuffer: VimBuffer {
  var str: NSMutableString
  var selection = NSRange(location: 0, length: 0)
  var undos: [(String, Int)] = [], redos: [(String, Int)] = []
  var depth = 0
  var clipboard: String?
  var shown = ""
  init(_ s: String) { str = NSMutableString(string: s) }
  var text: NSString { str }
  func replace(_ r: NSRange, with string: String) {
    if depth == 0 { undos.append((str as String, selection.location)); redos = [] }
    str.replaceCharacters(in: r, with: string)
  }
  func beginChange() {
    if depth == 0 { undos.append((str as String, selection.location)); redos = [] }
    depth += 1
  }
  func endChange() {
    depth = max(0, depth - 1)
    if depth == 0, let last = undos.last, last.0 == str as String { undos.removeLast() }
  }
  func undo() {
    guard let u = undos.popLast() else { return }
    redos.append((str as String, selection.location))
    str.setString(u.0)
    selection = NSRange(location: min(u.1, str.length), length: 0)
  }
  func redo() {
    guard let r = redos.popLast() else { return }
    undos.append((str as String, selection.location))
    str.setString(r.0)
    selection = NSRange(location: min(r.1, str.length), length: 0)
  }
  func displayLine(from loc: Int, by count: Int) -> Int {
    // No wrapping here: a display line is a line.
    let lines = (str as String).components(separatedBy: "\n")
    var line = 0, start = 0
    for (i, l) in lines.enumerated() {
      let len = (l as NSString).length
      if loc <= start + len { line = i; break }
      start += len + 1
    }
    let col = loc - start
    let target = max(0, min(lines.count - 1, line + count))
    let tstart = lines[..<target].reduce(0) { $0 + ($1 as NSString).length + 1 }
    return tstart + min(col, (lines[target] as NSString).length)
  }
  var screenLines: ClosedRange<Int> { 0...9 }
  var scrolled = 0
  func scroll(lines: Int) { scrolled += lines }
  func status(_ text: String) { shown = text }
}

@MainActor func vim(_ start: String, _ keys: String) -> (String, MemBuffer, VimEngine) {
  let c = (start as NSString).range(of: "|").location
  let b = MemBuffer(start.replacingOccurrences(of: "|", with: ""))
  b.selection = NSRange(location: c, length: 0)
  let v = VimEngine(buffer: b)
  v.feed(keys)
  let out = NSMutableString(string: b.str)
  out.insert("|", at: b.selection.location)
  return (out as String, b, v)
}

/// (name, start, keys, want): `|` is the cursor.
let golden: [(String, String, String, String)] = [
  // motions
  ("l h", "a|bc", "lh", "a|bc"),
  ("l stops at the last char", "ab|c\nd", "ll", "ab|c\nd"),
  ("j keeps the column", "abc|def\nx\nabcdefg", "jj", "abcdef\nx\nabc|defg"),
  ("w b e", "|foo bar.baz qux", "ww", "foo bar|.baz qux"),
  ("W", "|foo bar.baz qux", "WW", "foo bar.baz |qux"),
  ("e", "|foo bar", "e", "fo|o bar"),
  ("b", "foo ba|r", "b", "foo |bar"),
  ("w stops at an empty line", "|ab\n\ncd", "w", "ab\n|\ncd"),
  ("0 ^ $", "  ab|c", "^", "  |abc"),
  ("$", "|abc\nde", "$", "ab|c\nde"),
  ("gg G", "a\nb\n|c", "gg", "|a\nb\nc"),
  ("count G", "|a\nb\nc", "2G", "a\n|b\nc"),
  ("f t ; ,", "|a,b,c,d", "f,;", "a,b|,c,d"),
  ("t", "|a,b,c", "t,", "|a,b,c"),
  ("T ,", "a,b,c,|d", "F,,", "a,b,c|,d"),
  ("% on braces", "|\\frac{a}{b}", "f{%", "\\frac{a|}{b}"),
  ("% on begin", "\\be|gin{proof}\nx\n\\end{proof}", "%", "\\begin{proof}\nx\n|\\end{proof}"),
  ("% on end", "\\begin{proof}\nx\n\\e|nd{proof}", "%", "|\\begin{proof}\nx\n\\end{proof}"),
  ("} {", "|a\nb\n\nc", "}", "a\nb\n|\nc"),
  ("search", "|one two one", "/one<CR>", "one two |one"),
  ("n N", "|x a x a x", "/x<CR>nN", "x a |x a x"),
  ("*", "|foo bar foo", "*", "foo bar |foo"),
  // operators
  ("dw", "|foo bar", "dw", "|bar"),
  ("d2w", "|a b c d", "d2w", "|c d"),
  ("2dw", "|a b c d", "2dw", "|c d"),
  ("dw at line end", "foo |bar\nbaz", "dw", "foo| \nbaz"),
  ("cw like ce", "|foo bar", "cwxy<Esc>", "x|y bar"),
  ("dd", "a\n|b\nc", "dd", "a\n|c"),
  ("dd last line", "a\n|b", "dd", "|a"),
  ("3dd", "|a\nb\nc\nd", "3dd", "|d"),
  ("cc keeps indent", "  |abc\nx", "ccz<Esc>", "  |z\nx"),
  ("yy p", "|a\nb", "yyp", "a\n|a\nb"),
  ("yw P", "|ab cd", "ywP", "ab| ab cd"),
  ("x", "a|bc", "x", "a|c"),
  ("3x", "|abcd", "3x", "|d"),
  ("X", "ab|c", "X", "a|c"),
  ("D", "ab|cdef", "D", "a|b"),
  ("C", "ab|cdef", "Cx<Esc>", "ab|x"),
  ("s", "|abc", "sz<Esc>", "|zbc"),
  ("S", "  a|b\nc", "Sz<Esc>", "  |z\nc"),
  ("J", "|a\n  b", "J", "a| b"),
  ("r", "|abc", "rx", "|xbc"),
  ("3r", "|abcd", "3rx", "xx|xd"),
  ("~", "|abc", "~~", "AB|c"),
  ("gU iw", "|abc def", "gUiw", "|ABC def"),
  ("guu", "|ABC", "guu", "|abc"),
  (">> <<", "|a\nb", ">>j>>k<<", "|a\n  b"),
  ("de", "|foo bar", "de", "| bar"),
  ("d$", "a|bc\nd", "d$", "|a\nd"),
  ("dgg", "a\nb\n|c", "dgg", "|"),
  ("dG", "a\n|b\nc", "dG", "|a"),
  ("dt", "|a,b,c", "dt,", "|,b,c"),
  ("df", "|a,b,c", "df,", "|b,c"),
  ("d/", "|one two three", "d/thr<CR>", "|three"),
  // text objects
  ("diw", "foo b|ar baz", "diw", "foo | baz"),
  ("daw", "foo b|ar baz", "daw", "foo |baz"),
  ("ci(", "f(a, |b) c", "ci(x<Esc>", "f(|x) c"),
  ("da{", "\\textbf{|bold} x", "da{", "\\textbf| x"),
  ("ci{ nested", "\\frac{a+\\sqrt{|b}}{c}", "ci{x<Esc>", "\\frac{a+\\sqrt{|x}}{c}"),
  ("di[", "\\item[|abc] d", "di[", "\\item[|] d"),
  ("ci\"", "say \"h|i\" ok", "ci\"yo<Esc>", "say \"y|o\" ok"),
  ("di$", "let $x|+1$ be", "di$", "let $|$ be"),
  ("da$", "let $x|+1$ be", "da$", "let | be"),
  ("dip", "a\n|b\n\nc", "dip", "|\nc"),
  ("dap", "a\n|b\n\nc", "dap", "|c"),
  ("die", "\\begin{proof}\n  x|y\n  z\n\\end{proof}", "die", "\\begin{proof}\n|\\end{proof}"),
  ("dae", "a \\begin{em}|x\\end{em} b", "dae", "a | b"),
  ("cie nested", "\\begin{a}\n\\begin{b}\n|x\n\\end{b}\n\\end{a}", "cie", "\\begin{a}\n\\begin{b}\n|\n\\end{b}\n\\end{a}"),
  ("dis", "One. Tw|o three. Four.", "dis", "One. | Four."),
  // visual
  ("v d", "|abcd", "vld", "|cd"),
  ("V d", "a\n|b\nc", "Vjd", "|a"),
  ("v iw y P", "|ab cd", "viwyP", "a|bab cd"),
  ("v ~", "|ab", "vl~", "|AB"),
  ("V >", "|a\nb", "Vj>", "  |a\n  b"),
  ("v o", "a|bcd", "vlohd", "|d"),
  ("v r", "|abc", "vlrx", "|xxc"),
  ("V J", "|a\nb\nc", "VjjJ", "a b| c"),
  // insert and friends
  ("i", "a|b", "ix<Esc>", "a|xb"),
  ("a", "a|b", "ax<Esc>", "ab|x"),
  ("I", "  a|b", "Ix<Esc>", "  |xab"),
  ("A", "a|b\nc", "Ax<Esc>", "ab|x\nc"),
  ("o keeps indent", "  |a\nb", "ox<Esc>", "  a\n  |x\nb"),
  ("O", "a\n|b", "Ox<Esc>", "a\n|x\nb"),
  ("R", "|abcd", "Rxy<Esc>", "x|ycd"),
  // undo, redo, repeat
  ("u", "|abc", "xxu", "|bc"),
  ("u C-r", "|abc", "xxuu<C-r>", "|bc"),
  ("u after insert", "|a", "ixyz<Esc>u", "|a"),
  (". after dw", "|a b c d", "dw.", "|c d"),
  (". after ciw", "|foo bar baz", "ciwx<Esc>w.w.", "x x |x"),
  ("3.", "|a b c d e", "dw3.", "|e"),
  (". after x", "|abcd", "x..", "|d"),
  (". after A", "|a\nb", "A;<Esc>j.", "a;\nb|;"),
  // registers and marks
  ("\"a register", "|one\ntwo", "\"ayyj\"ap", "one\ntwo\n|one"),
  ("yank keeps \"0", "|ab\ncd", "yyjddk\"0p", "ab\n|ab"),
  ("marks", "|a\nb\nc", "majj'a", "|a\nb\nc"),
  ("backtick mark", "a|bc\nd", "mbj`b", "a|bc\nd"),
  ("''", "|a\nb\nc", "G''", "|a\nb\nc"),
  ("d'a", "|a\nb\nc", "majd'a", "|c"),
  // :
  (":n", "|a\nb\nc", ":3<CR>", "a\nb\n|c"),
  (":s", "|foo foo\nfoo", ":s/foo/bar/<CR>", "|bar foo\nfoo"),
  (":%s g", "|foo foo\nfoo", ":%s/foo/x/g<CR>", "x x\n|x"),
  (":s groups", "|\\cite{a}", ":s/\\\\cite\\{(\\w)\\}/\\\\ref{\\1}/<CR>", "|\\ref{a}"),
  (":'<,'>s", "|a\na\na", "Vj:s/a/b/<CR>", "b\n|b\na"),
  (":w", "|a", ":w<CR>", "|a"),
  // scrolling
  ("C-d", "|0\n1\n2\n3\n4\n5\n6\n7\n8\n9", "<C-d>", "0\n1\n2\n3\n|4\n5\n6\n7\n8\n9"),
  ("H M L", "a\nb\n|c\nd", "L", "a\nb\nc\n|d"),
  ("gj", "|ab\ncd", "lgj", "ab\nc|d"),
]

@MainActor @Test func vimGolden() {
  var failed: [String] = []
  for (name, start, keys, want) in golden {
    let (got, _, _) = vim(start, keys)
    if got != want { failed.append("\(name): \(keys.debugDescription) on \(start.debugDescription) → \(got.debugDescription), want \(want.debugDescription)") }
  }
  for f in failed { print("VIMFAIL " + f) }
  #expect(failed.isEmpty, "\(failed.count) of \(golden.count) failed")
}

@MainActor @Test func vimModesAndClipboard() {
  let (_, b, v) = vim("|ab", "i")
  #expect(v.mode == .insert && b.shown == "-- INSERT --")
  v.feed("<Esc>")
  #expect(v.mode == .normal && b.shown == "")
  v.feed("\"+yy")
  #expect(b.clipboard == "ab\n")
  b.clipboard = "zz"
  v.feed("\"+P")
  #expect(b.str as String == "zzab")
  v.feed("v")
  #expect(v.mode == .visual && b.shown == "-- VISUAL --")
}

@MainActor @Test func vimOneUndoPerCommand() {
  let (got, b, _) = vim("|a b c", "d2w")
  #expect(got == "|c")
  #expect(b.undos.count == 1)
}

@MainActor func keyEvent(_ k: String, window: NSWindow) -> NSEvent {
  let codes: [String: UInt16] = ["<Esc>": 53, "<CR>": 36, "<BS>": 51]
  let chars = ["<Esc>": "\u{1b}", "<CR>": "\r", "<BS>": "\u{7f}"][k] ?? k
  return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                          context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false,
                          keyCode: codes[k] ?? 0)!
}

@MainActor @Test func vimInTheTextView() {
  let v = NativeEditorView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
  let w = NSWindow(contentRect: NSRect(x: -3000, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
  w.contentView = v
  let d = NativeDoc(docID: "d", path: "main.tex", text: "\\section{Intro}\nSome text here.\n", seq: 0, conn: nil)
  v.show(d, buffer: 1)
  v.vimEnabled = true
  w.makeFirstResponder(v.textView)
  var status: [String] = []
  v.onVimStatus = { status.append($0) }
  #expect(v.textView.blockCaret)
  func type(_ keys: String) { for k in VimKey.parse(keys) { v.textView.keyDown(with: keyEvent(k.name, window: w)) } }
  type("jwciwmore<Esc>")
  #expect(v.textView.string == "\\section{Intro}\nSome more here.\n")
  #expect(d.string == v.textView.string)
  #expect(v.vimEngine?.mode == .normal && v.textView.blockCaret)
  #expect(status.contains("-- INSERT --") && status.last == "")
  type("ggf{ci{Methods<Esc>")
  #expect(v.textView.string.hasPrefix("\\section{Methods}"))
  type("Go\\begin{itemize}<Esc>")
  // Typing in insert mode goes through the text view: the comforts close the environment.
  #expect(v.textView.string.contains("\\begin{itemize}\n\\end{itemize}"))
  #expect(d.string == v.textView.string)
  v.vimEnabled = false
  #expect(!v.textView.blockCaret)
}

// MARK: review keys and the caret's shape (docs/agents/editor-vim-cursor.md)

@MainActor @Test func vimCursorShapes() {
  let b = MemBuffer("one two\n")
  let v = VimEngine(buffer: b)
  var seen: [VimEngine.CursorShape] = []
  v.onCursorShape = { seen.append($0) }
  #expect(v.cursorShape == .block)
  let steps: [(String, VimEngine.CursorShape)] = [
    ("d", .halfBlock), ("<Esc>", .block), ("r", .underline), ("x", .block), ("i", .bar), ("<Esc>", .block),
    ("R", .underline), ("<Esc>", .block), ("v", .block), ("<Esc>", .block), ("c", .halfBlock), ("w", .bar), ("<Esc>", .block),
  ]
  for (k, want) in steps {
    for key in VimKey.parse(k) { v.handle(key) }
    #expect(v.cursorShape == want, "after \(k): \(v.cursorShape)")
  }
  #expect(seen == [.halfBlock, .block, .underline, .block, .bar, .block, .underline, .block, .halfBlock, .bar, .block])
}

/// The caret drawn as Neovim draws it: an opaque block in the cursor colour with the character in the background
/// colour on it (normal), a bar (insert), an underline (r). Pixels from the view.
@MainActor @Test func vimCaretDrawing() throws {
  let v = NativeEditorView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
  let w = NSWindow(contentRect: NSRect(x: -3000, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
  w.contentView = v
  v.show(NativeDoc(docID: "d", path: "main.tex", text: "Wide text\n", seq: 0, conn: nil), buffer: 1)
  v.vimEnabled = true
  w.makeFirstResponder(v.textView)
  w.layoutIfNeeded()
  let tv = v.textView
  tv.caretAlwaysShown = true  // (the test window isn't key)
  // (the editor view's pixels and points: the same in TextKit and Metal mode)
  func pixels() -> NSBitmapImageRep {
    let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
    v.cacheDisplay(in: v.bounds, to: rep)
    return rep
  }
  func caretRect() -> NSRect {
    var actual = NSRange()
    let screen = tv.firstRect(forCharacterRange: NSRange(location: tv.selectedRange().location, length: 0), actualRange: &actual)
    return v.convert(w.convertFromScreen(screen), from: nil)
  }
  tv.cursorColor = NSColor(srgbRed: 1, green: 0.2, blue: 0.2, alpha: 1)  // (the theme's is close to its text colour)
  tv.updateCaret()
  let cursor: NSColor = tv.cursorColor, bg: NSColor = tv.backgroundColor
  // the test's caret is red, the theme's background near black (colours come back shifted by colour management)
  func near(_ p: NSColor?, _ c: NSColor) -> Bool {
    guard let p = p?.usingColorSpace(.sRGB) else { return false }
    if c == bg { return p.redComponent < 0.15 && p.greenComponent < 0.15 && p.blueComponent < 0.15 }
    return p.redComponent > 0.6 && p.greenComponent < 0.45 && p.blueComponent < 0.45
  }
  /// The box (in points) of the pixels in colour c, and how many background pixels it holds.
  func box(_ rep: NSBitmapImageRep, _ c: NSColor, bg: NSColor) -> (NSRect, Int) {
    let s = CGFloat(rep.pixelsWide) / rep.size.width
    var x0 = Int.max, y0 = Int.max, x1 = -1, y1 = -1
    for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide where near(rep.colorAt(x: x, y: y), c) {
      x0 = min(x0, x); y0 = min(y0, y); x1 = max(x1, x); y1 = max(y1, y)
    } }
    guard x1 >= 0 else { return (.zero, 0) }
    var inside = 0
    for y in y0...y1 { for x in x0...x1 where near(rep.colorAt(x: x, y: y), bg) { inside += 1 } }
    return (NSRect(x: CGFloat(x0) / s, y: CGFloat(y0) / s, width: CGFloat(x1 - x0 + 1) / s, height: CGFloat(y1 - y0 + 1) / s), inside)
  }
  // normal: a block one character wide and a line tall, the letter in the background colour on it
  #expect(tv.caretShape == .block)
  var rep = pixels()
  if let out = ProcessInfo.processInfo.environment["TAUDOT_CARET_PNG"] { try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out)) }
  var (b, inside) = box(rep, cursor, bg: bg)
  #expect(b.width > 5 && b.width < 12 && b.height > 10, "block: \(b)")
  #expect(inside > 5, "the letter on the block: \(inside) background pixels")
  // r: an underline
  v.vimEngine?.handle(VimKey("r"))
  #expect(tv.caretShape == .underline)
  rep = pixels()
  if let out = ProcessInfo.processInfo.environment["TAUDOT_CARET_PNG"] { try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out.replacingOccurrences(of: ".png", with: "-underline.png"))) }
  (b, inside) = box(rep, cursor, bg: bg)
  #expect(b.width > 5 && b.height <= 3.5, "underline: \(b)")
  // operator pending: half a block
  v.vimEngine?.handle(VimKey("<Esc>"))
  v.vimEngine?.handle(VimKey("d"))
  rep = pixels()
  if let out = ProcessInfo.processInfo.environment["TAUDOT_CARET_PNG"] { try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out.replacingOccurrences(of: ".png", with: "-half.png"))) }
  let half = box(rep, cursor, bg: bg).0
  #expect(half.height > 4 && half.height < 10, "half block: \(half)")
  v.vimEngine?.handle(VimKey("<Esc>"))
  // insert: the system's bar (ours hidden, the system's in the cursor colour)
  v.vimEngine?.handle(VimKey("i"))
  #expect(tv.caretShape == nil && !tv.vimCaretShown && (tv.isMetal || tv.insertionPointColor == tv.cursorColor))
  // normal again: ours, the system's clear; it follows the caret
  v.vimEngine?.handle(VimKey("<Esc>"))
  #expect(tv.vimCaretShown && (tv.isMetal || tv.insertionPointColor == .clear))
  let x0 = tv.vimCaretFrame.minX
  v.vimEngine?.feed("w")
  #expect(tv.vimCaretFrame.minX > x0 + 20, "the block follows w: \(x0) → \(tv.vimCaretFrame.minX)")
  v.vimEnabled = false
}

/// The block blinks at rest, solid while moving or typing and for `blinkRest` after (short periods for the test).
@MainActor @Test func vimBlockBlinks() async {
  let v = NativeEditorView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
  let w = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
  w.contentView = v
  v.show(NativeDoc(docID: "d", path: "main.tex", text: "one two three\n", seq: 0, conn: nil), buffer: 1)
  let tv = v.textView
  tv.caretAlwaysShown = true
  tv.blinkOn = 0.12; tv.blinkOff = 0.12; tv.blinkRest = 0.3
  v.vimEnabled = true
  w.makeFirstResponder(tv)
  func lit(over s: Double) async -> [Bool] {
    var out: [Bool] = []
    let end = Date().addingTimeInterval(s)
    while Date() < end { out.append(tv.caretLit); try? await Task.sleep(for: .milliseconds(15)) }
    return out
  }
  // just shown: solid for the rest time
  #expect(await lit(over: 0.25).allSatisfy { $0 })
  // then blinking: both phases seen
  // (up to 3 s: with the whole suite on the main actor, a 15 ms sleep can take far longer)
  var blinking: [Bool] = []
  let until = Date().addingTimeInterval(3)
  while Date() < until && !(blinking.contains(false) && blinking.contains(true)) { blinking += await lit(over: 0.3) }
  #expect(blinking.contains(false) && blinking.contains(true), "blinks at rest (\(blinking.count) samples)")
  // a move: solid again at once and for the rest time
  v.vimEngine?.feed("w")
  #expect(await lit(over: 0.25).allSatisfy { $0 }, "solid after a move")
  // an edit, likewise
  try? await Task.sleep(for: .milliseconds(400))
  v.vimEngine?.feed("x")
  #expect(await lit(over: 0.25).allSatisfy { $0 }, "solid after an edit")
  // insert mode: the system bar (ours hidden, no timer left lit)
  v.vimEngine?.feed("i")
  #expect(!tv.caretLit && !tv.vimCaretShown)
  v.vimEnabled = false
}
