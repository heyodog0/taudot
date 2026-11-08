import AppKit
import Foundation
import Testing
@testable import TaudotEditor
@testable import TaudotShared
import TaudotPDF

// MARK: OT (the same fuzz as clients/nvim/tests/ot_spec.lua)

private struct Rng {
  var s: UInt64
  mutating func next() -> Double {
    s = (s &* 1103515245 &+ 12345) % 2147483648
    return Double(s) / 2147483648
  }
}

private func randomEdits(_ text: String, _ r: inout Rng) -> [Edit] {
  let alphabet = ["a", "b", "\n", "é", "😀", "xy"]
  var t = Array(text)
  var out: [Edit] = []
  for _ in 0..<(1 + Int(r.next() * 3)) {
    let i = Int(r.next() * Double(t.count + 1))
    let d = Int(r.next() * Double(min(3, t.count - i + 1)))
    var ins = ""
    for _ in 0..<Int(r.next() * 3) { ins += alphabet[Int(r.next() * Double(alphabet.count))] }
    let pos = String(t[..<i]).utf8.count
    let del = String(t[i..<min(t.count, i + d)]).utf8.count
    out.append(Edit(pos: pos, del: del, ins: ins))
    t.replaceSubrange(i..<min(t.count, i + d), with: Array(ins))
  }
  return out
}

@Test func otTransformConverges() throws {
  var r = Rng(s: 7)
  let t = "ab é😀\ncd\nef"
  let base = Array(t.utf8)
  for _ in 0..<3000 {
    let ea = randomEdits(t, &r), eb = randomEdits(t, &r)
    let a = try Op.from(ea, len: base.count), b = try Op.from(eb, len: base.count)
    #expect(base.applying(a.edits) == base.applying(ea))
    let (a2, b2) = try Op.transform(a, b)
    let left = base.applying(ea).applying(b2.edits), right = base.applying(eb).applying(a2.edits)
    #expect(left == right)
  }
  let a = try Op.from(Edit(pos: 1, del: 0, ins: "A"), len: 2), b = try Op.from(Edit(pos: 1, del: 0, ins: "B"), len: 2)
  let (_, b2) = try Op.transform(a, b)
  #expect(Array("xAy".utf8).applying(b2.edits) == Array("xABy".utf8))
}

// MARK: OT against ot2 (crates/ot2/fixtures/byte_ops.json; TAUDOT_OT_FIXTURE=<path> for a larger set)

private func comps(_ v: Any?) -> [Op.Comp] {
  (v as! [Any]).map { c in
    if let s = c as? String { return .insert(Array(s.utf8)) }
    let n = (c as! NSNumber).intValue
    return n < 0 ? .delete(-n) : .retain(n)
  }
}

private func edits(_ v: Any?) -> [Edit] {
  (v as! [[String: Any]]).map { Edit(pos: ($0["pos"] as! NSNumber).intValue, del: ($0["del"] as! NSNumber).intValue, ins: $0["ins"] as! String) }
}

@Test func otMatchesOt2Fixtures() throws {
  let path = ProcessInfo.processInfo.environment["TAUDOT_OT_FIXTURE"]
    ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../crates/ot2/fixtures/byte_ops.json").path
  let cases = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [[String: Any]]
  var fails = 0
  func check<T: Equatable>(_ i: Int, _ what: String, _ got: T, _ want: T) {
    if got != want {
      fails += 1
      if fails <= 5 { Issue.record("case \(i) \(what): got \(got), want \(want)") }
    }
  }
  for (i, c) in cases.enumerated() {
    let base = Array((c["base"] as! String).utf8)
    let a = Op(comps: comps(c["a"])), b = Op(comps: comps(c["b"]))
    check(i, "from comps", a.comps, comps(c["a"]))
    check(i, "base/target", [a.base, a.target], [base.count, (c["after_a"] as! String).utf8.count])
    check(i, "compose", try Op.compose(a, Op(comps: comps(c["c"]))).comps, comps(c["compose_ac"]))
    let (a2, b2) = try Op.transform(a, b)
    let t = c["transform_ab"] as! [Any]
    check(i, "transform", [a2.comps, b2.comps], [comps(t[0]), comps(t[1])])
    check(i, "normalize", Op(comps: comps(c["raw"])).comps, comps(c["from_comps"]))
    let fe = try? Op.from(edits(c["edits"]), len: base.count)
    check(i, "from edits", fe?.comps, c["from_edits"] is NSNull ? nil : comps(c["from_edits"]))
    check(i, "edits", a.edits, edits(c["to_edits_a"]))
    check(i, "applying", base.applying(a.edits), Array((c["after_a"] as! String).utf8))
    for m in c["map_a"] as! [[Any]] {
      let p = (m[0] as! NSNumber).intValue, left = (m[1] as! String) == "left"
      check(i, "map \(p) \(m[1])", a.map(p, stickLeft: left), (m[2] as! NSNumber).intValue)
    }
    if let w = c["wrong_len"], !(w is NSNull) {
      let x = Op(comps: comps(w))
      check(i, "compose refuses", (try? Op.compose(a, x)) != nil, a.target == x.base)
      check(i, "transform refuses", (try? Op.transform(a, x)) != nil, false)
    }
  }
  #expect(fails == 0, "\(fails) differences in \(cases.count) cases")
}

@Test func otMapPosition() throws {
  let op = try Op.from(Edit(pos: 2, del: 0, ins: "xyz"), len: 5)
  #expect(op.map(2) == 5)
  #expect(op.map(2, stickLeft: true) == 2)
  #expect(op.map(4) == 7)
  let del = try Op.from(Edit(pos: 1, del: 3, ins: ""), len: 5)
  #expect(del.map(2) == 1)
  #expect(del.map(5) == 2)
}

@Test func utfOffsets() {
  let b = Array("aé😀\nb".utf8)
  #expect(Utf.utf16(b, 3) == 2)  // a é
  #expect(Utf.utf16(b, 7) == 4)  // + 😀 (two units)
  #expect(Utf.utf8(b, 4) == 7)
  #expect(Utf.utf8(b, 2) == 3)
  #expect(Utf.lineStarts(b) == [0, 8])
  #expect(Utf.lineCol([0, 8], 9) == (1, 1))
}

// MARK: NativeDoc without an engine

@MainActor @Test func docTransformsRemotePastUnsentEdits() {
  let d = NativeDoc(docID: "d", path: "main.tex", text: "hello world", seq: 3, conn: nil)
  var applied: [[Edit]] = []
  d.onRemote = { e, _ in applied.append(e) }
  d.local(Edit(pos: 5, del: 0, ins: ","))  // hello, world (pending: no connection)
  d.changed(["seq": 4, "edits": [["pos": 0, "del": 0, "ins": ">> "]]])
  #expect(d.string == ">> hello, world")
  #expect(d.seq == 4)
  d.changed(["seq": 5, "edits": [["pos": 14, "del": 0, "ins": "!"]]])  // after "world" in the engine's text
  #expect(d.string == ">> hello, world!")
  #expect(applied.count == 2)
}

@MainActor @Test func docMovesRanges() {
  let d = NativeDoc(docID: "d", path: "main.tex", text: "abc commented def", seq: 1, conn: nil)
  d.setRanges([["id": "c1", "kind": "comment", "start": 4, "end": 13, "text": "commented", "thread_id": "c1"]], seq: 1)
  d.local(Edit(pos: 4, del: 0, ins: "X"))  // at the start: goes before
  #expect(d.ranges[0].start == 5 && d.ranges[0].end == 14)
  d.local(Edit(pos: 14, del: 0, ins: "Y"))  // at the end: goes after
  #expect(d.ranges[0].end == 14)
  d.changed(["seq": 2, "edits": [["pos": 0, "del": 4, "ins": ""]]])
  #expect(d.string == "XcommentedY def" && d.ranges[0].start == 1 && d.ranges[0].end == 10)
}

// MARK: syntax and comforts

@Test func latexTokens() {
  let s = "\\section{A} % c\n$x+1$ \\begin{equation}y\\end{equation}" as NSString
  let toks = LatexSyntax.tokens(s, in: NSRange(location: 0, length: s.length)).map { (s.substring(with: $0.0), $0.1) }
  #expect(toks.contains { $0 == ("\\section", .command) })
  #expect(toks.contains { $0 == ("% c", .comment) })
  #expect(toks.contains { $0 == ("x+1", .math) })
  #expect(toks.contains { $0 == ("equation", .env) })
  #expect(toks.contains { $0 == ("y", .math) })
  #expect(LatexSyntax.inDisplayMath(s, at: s.length - 15))
  #expect(!LatexSyntax.inDisplayMath(s, at: 5))
}

@Test func comfortsBeginAndComments() {
  let s = "  \\begin{figure}[t]\n\\begin{itemize}\\item a\n\\end{itemize}" as NSString
  #expect(Comforts.beginEnding(s, at: 16) == "figure")
  #expect(Comforts.matchingEnd(s, from: 16, env: "figure") == nil)
  let e = Comforts.matchingEnd(s, from: 35, env: "itemize")
  #expect(e.map { s.substring(with: $0) } == "itemize")
  #expect(Comforts.beginLine(s, lineAt: 3)?.env == "figure")
  #expect(Comforts.beginLine(s, lineAt: 3)?.indent == "  ")
  #expect(Comforts.toggleComment(["  a", "", "    b"]) == ["  % a", "", "  %   b"])
  #expect(Comforts.toggleComment(["  % a", "", "  %   b"]) == ["  a", "", "    b"])
  #expect(Comforts.fuzzy("sec", "\\section")! < Comforts.fuzzy("sec", "\\subsection")!)
  #expect(Comforts.fuzzy("zz", "\\section") == nil)
}

// MARK: the view, in a window off screen

@MainActor @Test func viewSendsTypedEditsAsBytes() throws {
  let v = NativeEditorView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
  let w = NSWindow(contentRect: NSRect(x: -3000, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
  w.contentView = v
  let d = NativeDoc(docID: "d", path: "main.tex", text: "é😀 x\n\\begin{figure}\n\\end{figure}\n", seq: 0, conn: nil)
  v.show(d, buffer: 1)
  v.textView.setSelectedRange(NSRange(location: 4, length: 0))  // after "é😀 "
  v.textView.insertText("ab", replacementRange: v.textView.selectedRange())
  #expect(d.string == "é😀 abx\n\\begin{figure}\n\\end{figure}\n")
  #expect(d.pending?.edits == [Edit(pos: 7, del: 0, ins: "ab")])
  // A remote edit lands where it should and keeps the caret on its character.
  d.changed(["seq": 1, "edits": [["pos": 0, "del": 2, "ins": "E"]]])
  #expect(v.textView.string == d.string)
  #expect(v.textView.selectedRange().location == 6)
  // Renaming the begin renames the end.
  let s = v.textView.string as NSString
  let name = s.range(of: "figure")
  v.textView.setSelectedRange(NSRange(location: NSMaxRange(name), length: 0))
  v.textView.insertText("*", replacementRange: v.textView.selectedRange())
  #expect(v.textView.string.contains("\\end{figure*}"))
  #expect(d.string == v.textView.string)
  // Geometry: lines have tops, in order.
  w.layoutIfNeeded()
  v.textView.textLayoutManager?.ensureLayout(for: v.textView.textLayoutManager!.documentRange)
  let y0 = v.y(ofLine: 0), y1 = v.y(ofLine: 1)
  #expect(y0 != nil && y1 != nil && y1! > y0!)
  #expect(v.visibleLines.lowerBound == 0)
}

@MainActor @Test func viewComforts() {
  let v = NativeEditorView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
  let w = NSWindow(contentRect: NSRect(x: -3000, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
  w.contentView = v
  let d = NativeDoc(docID: "d", path: "main.tex", text: "  ", seq: 0, conn: nil)
  v.show(d, buffer: 1)
  let tv = v.textView
  tv.setSelectedRange(NSRange(location: 2, length: 0))
  for ch in "\\begin{table}" { tv.insertText(String(ch), replacementRange: tv.selectedRange()) }
  #expect(tv.string == "  \\begin{table}\n  \\end{table}")
  #expect(tv.selectedRange().location == 15)
  tv.doCommand(by: #selector(NSResponder.insertNewline(_:)))
  #expect(tv.string == "  \\begin{table}\n    \n  \\end{table}")
  #expect(tv.selectedRange().location == 20)
  tv.setSelectedRange(NSRange(location: 0, length: tv.string.utf16.count))
  tv.toggleComment()
  #expect(tv.string == "  % \\begin{table}\n    \n  % \\end{table}")
  #expect(d.string == tv.string)
}

@MainActor @Test func lineIndexFollowsEdits() {
  let v = NativeEditorView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
  v.show(NativeDoc(docID: "d", path: "main.tex", text: "ab\nc\n\nd é\n", seq: 0, conn: nil), buffer: 1)
  var r = Rng(s: 7)
  let pieces = ["x", "\n", "é\n", "\n\n", "", "yz"]
  for _ in 0..<300 {
    _ = v.starts16  // built, then kept up to date through the edits
    let n = (v.textView.string as NSString).length
    let a = Int(r.next() * Double(n + 1)), len = min(n - a, Int(r.next() * 4))
    let ins = pieces[Int(r.next() * Double(pieces.count))]
    let range = NSRange(location: a, length: len)
    if v.textView.shouldChangeText(in: range, replacementString: ins) {
      v.textView.textStorage?.replaceCharacters(in: range, with: ins)
      v.textView.didChangeText()
    }
    let s = v.textView.string as NSString
    var want = [0]
    for i in 0..<s.length where s.character(at: i) == 10 { want.append(i + 1) }
    #expect(v.starts16 == want)
    if v.starts16 != want { break }
  }
}

/// Edits that open or close display math recolour what follows; the rest recolour their line only.
@MainActor @Test func highlightAfterEditsMatchesFull() {
  func colours(_ v: NativeEditorView) -> [NSColor?] {
    let st = v.textView.textStorage!
    return (0..<st.length).map { st.attribute(.foregroundColor, at: $0, effectiveRange: nil) as? NSColor }
  }
  // (text, edit range, replacement)
  let cases: [(String, NSRange, String)] = [
    ("a \\[ x \\]\nb {c}\n", NSRange(location: 9, length: 1), ""),  // backspace the `]` of `\]`
    ("a \\\nb {c}\n", NSRange(location: 3, length: 0), "["),  // type the `[` of `\[`
    ("\\begin{align} x\n{y}\n\\end{align}\n{z}\n", NSRange(location: 1, length: 1), ""),  // break `\begin`
    ("\\begin{align} x\n{y}\n\\end{align}\n{z}\n", NSRange(location: 22, length: 1), ""),  // break `\end`
    ("x\n{y}\n", NSRange(location: 0, length: 0), "\\begin{align}"),
    ("a \\[ x \\]\nb {c}\n", NSRange(location: 4, length: 1), "q"),  // an ordinary key inside math
  ]
  for (text, range, ins) in cases {
    let v = NativeEditorView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    v.show(NativeDoc(docID: "d", path: "main.tex", text: text, seq: 0, conn: nil), buffer: 1)
    if v.textView.shouldChangeText(in: range, replacementString: ins) {
      v.textView.textStorage?.replaceCharacters(in: range, with: ins)
      v.textView.didChangeText()
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))  // the highlight runs on the next turn
    let got = colours(v)
    v.highlight(NSRange(location: 0, length: v.textView.textStorage!.length))
    let want = colours(v)
    let bad = (0..<want.count).filter { got[$0] != want[$0] }
    #expect(bad.isEmpty, "CASE \(text.debugDescription) \(range) \(ins.debugDescription): differs at \(bad) of \((v.textView.string).debugDescription)")
  }
}

@Test func displayMathScan() {
  func at(_ s: String, _ marker: String = "|") -> Bool {
    let loc = (s as NSString).range(of: marker).location
    return LatexSyntax.inDisplayMath(s as NSString, at: loc)
  }
  #expect(at("\\[ x | \\]"))
  #expect(!at("\\[ x \\] |"))
  #expect(at("\\begin{align} a | \\end{align}"))
  #expect(!at("\\begin{align} a \\end{align} \\begin{figure} |"))
  #expect(at("\\begin{align} a \\begin{figure} |"))
  #expect(!at("a \\\\[2pt] b |"))
  #expect(at("\\begin{equation*}|"))
}

@MainActor @Test func caretReportsEveryMoveAndKey() {
  let v = NativeEditorView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
  let d = NativeDoc(docID: "d", path: "main.tex", text: "ab\né c\n", seq: 0, conn: nil)
  v.show(d, buffer: 1)
  var got: [(Int, Int, String)] = []
  v.onCaret = { got.append(($0, $1, $2)) }
  let tv = v.textView
  tv.setSelectedRange(NSRange(location: 4, length: 0))  // line 2, after "é"
  tv.insertText("x", replacementRange: tv.selectedRange())  // one key: one report, with the new text
  tv.setSelectedRange(NSRange(location: 1, length: 0))  // line 1, col 1
  tv.setSelectedRange(NSRange(location: 1, length: 0))  // no move: no report
  #expect(got.count == 3)
  #expect(got[0] == (2, 2, "é c"))
  #expect(got[1] == (2, 3, "éx c"))
  #expect(got[2] == (1, 1, "ab"))
}

@MainActor @Test func emojiTypedAsReplacementCharacters() {
  let v = NativeEditorView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
  let d = NativeDoc(docID: "d", path: "main.tex", text: "ab", seq: 0, conn: nil)
  v.show(d, buffer: 1)
  v.textView.setSelectedRange(NSRange(location: 1, length: 0))
  v.textView.insertText("x😀y", replacementRange: v.textView.selectedRange())
  #expect(v.textView.string == "ax\u{FFFD}\u{FFFD}yb")
  #expect(d.string == v.textView.string)
  #expect(v.textView.selectedRange().location == 5)
}

/// `TAUDOT_THEME_SHOTS=<dir> swift test --filter themeShots`: the editor in a few themes, as PNGs.
@MainActor @Test func themeShots() throws {
  guard let dir = ProcessInfo.processInfo.environment["TAUDOT_THEME_SHOTS"] else { return }
  let sample = """
  \\section{Results}\\label{sec:results} % first pass
  We train for $T = 10^6$ steps \\cite{knuth1984}, see Figure~\\ref{fig:a}.
  \\begin{equation}
    \\mathcal{L}(\\theta) = \\sum_i \\log p_\\theta(x_i)
  \\end{equation}
  \\begin{itemize}
    \\item \\textbf{Fast}: under 5 ms.
  \\end{itemize}
  """
  var ids = ["catppuccin-latte", "gruvbox-dark", "kanagawa-wave", "nord"]
  ids += RexThemes.all().prefix(2).map(\.id)
  for id in ids {
    guard let t = Theme.named(id) else { continue }
    let v = NativeEditorView(frame: NSRect(x: 0, y: 0, width: 620, height: 210))
    let w = NSWindow(contentRect: NSRect(x: -3000, y: 0, width: 620, height: 210), styleMask: [.borderless], backing: .buffered, defer: false)
    w.contentView = v
    v.show(NativeDoc(docID: "d", path: "main.tex", text: sample, seq: 0, conn: nil), buffer: 1)
    v.apply(style: EditorStyle(theme: t, fontSize: 13))
    v.setTints([(NSRange(location: 64, length: 18), .systemBlue, 0.22, true)])
    w.layoutIfNeeded()
    v.textView.textLayoutManager?.ensureLayout(for: v.textView.textLayoutManager!.documentRange)
    let rep = try #require(v.bitmapImageRepForCachingDisplay(in: v.bounds))
    v.cacheDisplay(in: v.bounds, to: rep)
    try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(id).png"))
  }
}

/// `TAUDOT_EDITOR_BENCH=<a .tex file> swift test --filter typingBench`: 160 keys typed into the native editor as the
/// app wires it (margin cursor payload, PDF caret notification), each followed by layout and display. Per-key ms.
@MainActor @Test func typingBench() throws {
  guard let file = ProcessInfo.processInfo.environment["TAUDOT_EDITOR_BENCH"] else { return }
  let text = try String(contentsOfFile: file, encoding: .utf8)
  let ed = NativeEditor(folder: URL(fileURLWithPath: "/tmp"), socket: URL(fileURLWithPath: "/tmp/none.sock"), frame: NSRect(x: 0, y: 0, width: 720, height: 900))
  let w = NSWindow(contentRect: NSRect(x: -3000, y: 0, width: 720, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
  w.contentView = ed.view
  var carets = 0
  ed.bridge.notify("taudot_app_caret") { _ in carets += 1 }
  ed.bridge.notify("taudot_review_cursor") { _ in }
  ed.adopt(NativeDoc(docID: "d", path: "main.tex", text: text, seq: 0, conn: nil))
  let tv = ed.view.textView
  let at = (tv.string as NSString).range(of: "\\section{Introduction}")
  ed.view.jump(line: ed.view.lineCol(at.location == NSNotFound ? 0 : at.location).0 + 4, col: 0)
  w.displayIfNeeded()
  RunLoop.main.run(until: Date().addingTimeInterval(0.3))
  let typed = "The quick brown fox jumps over the lazy dog while the agent learns $x^2$ from pixels and sparse rewards in every game we tried, which is a nice result indeed. "
  var ms: [Double] = []
  let reps = Int(ProcessInfo.processInfo.environment["TAUDOT_EDITOR_BENCH_REPS"] ?? "1") ?? 1
  // TAUDOT_EDITOR_BENCH_SAMPLE=<file>: a `sample` profile of the typing
  if let out = ProcessInfo.processInfo.environment["TAUDOT_EDITOR_BENCH_SAMPLE"] {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
    p.arguments = ["\(getpid())", "6", "-file", out]
    try p.run()
    Thread.sleep(forTimeInterval: 0.5)
  }
  for ch in String(repeating: typed, count: reps) {
    let t0 = CACurrentMediaTime()
    tv.insertText(String(ch), replacementRange: tv.selectedRange())
    RunLoop.main.run(until: Date())  // the highlight (RunLoop.perform)
    w.displayIfNeeded()
    ms.append((CACurrentMediaTime() - t0) * 1000)
  }
  let back = 40
  for _ in 0..<back {
    let t0 = CACurrentMediaTime()
    tv.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
    RunLoop.main.run(until: Date())
    w.displayIfNeeded()
    ms.append((CACurrentMediaTime() - t0) * 1000)
  }
  let s = ms.sorted()
  func q(_ p: Double) -> Double { s[min(s.count - 1, Int(p * Double(s.count)))] }
  print(String(format: "typingBench: %d keys, mean %.2f ms, p50 %.2f, p95 %.2f, max %.2f; %d caret notifications",
               ms.count, ms.reduce(0, +) / Double(ms.count), q(0.5), q(0.95), s.last!, carets))
  #expect(ed.doc?.string == tv.string)
}

// MARK: engine restarts (docs/agents/editor-reconnect.md)

@Test func opDiffIsExactAndFine() throws {
  var r = Rng(s: 5)
  let alphabet = ["a", "b", "\n", "é", "xy", "😀"]
  for _ in 0..<2000 {
    func rnd() -> [UInt8] { Array((0..<Int(r.next() * 12)).map { _ in alphabet[Int(r.next() * Double(alphabet.count))] }.joined().utf8) }
    let a = rnd(), b = rnd()
    let op = Op.diff(a, b)
    #expect(op.base == a.count && op.apply(a) == b)
    // whole characters only: every insert is valid UTF-8
    for c in op.comps { if case let .insert(t) = c { #expect(String(decoding: t, as: UTF8.self).utf8.elementsEqual(t)) } }
  }
  let base = Array("one\ntwo\nthree\nfour\nfive\n".utf8)
  let (theirs, _) = try Op.transform(Op.diff(base, Array("ONE\ntwo\nthree\nfour\nFIVE\n".utf8)), Op.diff(base, Array("one\ntwo\nthree!\nfour\nfive\n".utf8)))
  #expect(String(decoding: theirs.apply(Array("one\ntwo\nthree!\nfour\nfive\n".utf8)), as: UTF8.self) == "ONE\ntwo\nthree!\nfour\nFIVE\n")
  let (t2, _) = try Op.transform(Op.diff(Array("abc\n".utf8), Array("aXbc\n".utf8)), Op.diff(Array("abc\n".utf8), Array("abYc\n".utf8)))
  #expect(String(decoding: t2.apply(Array("abYc\n".utf8)), as: UTF8.self) == "aXbYc\n")
}

/// `TAUDOT_RECONNECT_MOCK=<clients/mock-engine/main.ts> swift test --filter nativeEngineRestart`: the mock engine
/// killed with an edit in flight and one pending, a collaborator's line added while it's down, more typed, a new
/// engine on the same socket. Nothing lost or doubled; the view == the engine.
@MainActor @Test func nativeEngineRestart() async throws {
  guard let mockMain = ProcessInfo.processInfo.environment["TAUDOT_RECONNECT_MOCK"] else { return }
  let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("txr-\(getpid())")
  try? FileManager.default.removeItem(at: dir)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: dir) }
  let file = dir.appendingPathComponent("main.tex")
  try "\\documentclass{article}\n\\begin{document}\nHello.\n\\end{document}\n".write(to: file, atomically: true, encoding: .utf8)
  let sock = "/tmp/txr-\(getpid()).sock"
  func startMock() throws -> Process {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["deno", "run", "-A", mockMain, "--folder", dir.path, "--socket", sock, "--latency", "400"]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try p.run()
    return p
  }
  func until(_ s: Double, _ f: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(s)
    while Date() < end { if f() { return true }; try? await Task.sleep(for: .milliseconds(20)) }
    return f()
  }
  var mock = try startMock()
  defer { mock.terminate() }
  #expect(await until(10) { FileManager.default.fileExists(atPath: sock) })
  let ed = NativeEditor(folder: dir, socket: URL(fileURLWithPath: sock))
  let w = NSWindow(contentRect: NSRect(x: -3000, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
  w.contentView = ed.view
  try await ed.start(main: "main.tex")
  let tv = ed.view.textView
  func addLine(_ s: String) {
    let at = (tv.string as NSString).range(of: "\\end{document}").location
    tv.setSelectedRange(NSRange(location: at, length: 0))
    tv.insertText(s + "\n", replacementRange: tv.selectedRange())
  }
  let d = try #require(ed.doc)
  addLine("AAA confirmed before the restart")
  #expect(await until(5) { d.seq > 0 && d.unconfirmed == 0 })
  #expect(await until(3) { ((try? String(contentsOf: file, encoding: .utf8)) ?? "").contains("AAA") })  // the mock keeps it
  addLine("BBB in flight when the engine dies")
  #expect(await until(2) { d.inflight != nil })
  kill(mock.processIdentifier, SIGKILL)
  mock.waitUntilExit()
  unlink(sock)
  addLine("CCC typed while the engine is down")
  try? await Task.sleep(for: .milliseconds(300))
  let disk = try String(contentsOf: file, encoding: .utf8)
  try ("% REMOTE line from a collaborator\n" + disk).write(to: file, atomically: true, encoding: .utf8)
  mock = try startMock()
  #expect(await until(10) { FileManager.default.fileExists(atPath: sock) })
  addLine("DDD typed while reconnecting")
  #expect(await until(30) { d.rebases >= 1 && d.unconfirmed == 0 && !d.rebasing })
  let probe = try JSONRPCConnection(socket: sock)
  _ = try await probe.call("project.open", ["folder": dir.path])
  let server = try await probe.call("doc.open", ["project_id": "mock", "path": "main.tex"])["text"] as? String ?? ""
  for w in ["AAA", "BBB", "CCC", "DDD", "REMOTE"] {
    #expect(server.components(separatedBy: w).count == 2, "\(w) once on the engine: \(server)")
  }
  #expect(server == tv.string)
  #expect(d.error == nil)
  ed.stop()
}


// MARK: LaTeX errors inline (docs/agents/errors.md)

@MainActor @Test func texIssuesInline() throws {
  let text = "\\begin{document}\nfoo } bar\n  \\undefinedcs x\nOverfull here\n\\end{document}\n"
  let ed = NativeEditor(folder: URL(fileURLWithPath: "/tmp"), socket: URL(fileURLWithPath: "/tmp/none.sock"), frame: NSRect(x: 0, y: 0, width: 600, height: 400))
  let w = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
  w.contentView = ed.view
  let d = NativeDoc(docID: "d", path: "main.tex", text: text, seq: 0, conn: nil)
  ed.adopt(d)
  w.layoutIfNeeded()
  let v = ed.view, tv = v.textView
  func marked(_ i: Int) -> String { (tv.string as NSString).substring(with: v.issueMarks[i]) }
  ed.setIssues([
    EditorIssue(severity: .error, path: "main.tex", line: 2, column: 5, message: "Extra }, or forgotten \\endgroup", plain: "There's a } with no matching {"),
    EditorIssue(severity: .error, path: "main.tex", line: 3, column: 14, message: "Undefined control sequence"),
    EditorIssue(severity: .warning, path: "main.tex", line: 4, message: "Overfull \\hbox (12.3pt too wide)"),
    EditorIssue(severity: .error, path: "other.tex", line: 1, message: "elsewhere"),
  ])
  #expect(v.issueMarks.count == 3)  // other files' issues aren't marked here
  #expect(marked(0) == "}")
  #expect(marked(1) == "\\undefinedcs")
  #expect(marked(2) == "Overfull here")  // no column: the line's text
  // the card: with the caret on a marked line, the plain message; elsewhere, none
  tv.setSelectedRange(NSRange(location: 0, length: 0))
  #expect(v.issueCardText == "")
  tv.setSelectedRange(NSRange(location: (tv.string as NSString).range(of: "bar").location, length: 0))
  #expect(v.issueCardText == "There's a } with no matching {")
  // typing on the line closes the card; moving there opens it
  tv.insertText("x", replacementRange: tv.selectedRange())
  #expect(v.issueCardText == "")
  tv.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
  tv.setSelectedRange(NSRange(location: (tv.string as NSString).range(of: "foo").location, length: 0))
  #expect(v.issueCardText == "There's a } with no matching {")
  // marks move with edits: a line typed above
  tv.setSelectedRange(NSRange(location: 0, length: 0))
  tv.insertText("% new line\n", replacementRange: tv.selectedRange())
  #expect(marked(0) == "}" && marked(1) == "\\undefinedcs")
  // Ask Claude: the prompt names the line where the error is now
  var asked: (EditorIssue, String)?
  ed.onAskClaude = { asked = ($0, $1) }
  tv.setSelectedRange(NSRange(location: (tv.string as NSString).range(of: "undefinedcs").location, length: 0))
  #expect(v.issueCardText == "Undefined control sequence")
  v.pressAskClaude()
  #expect(asked?.1 == "Fix this LaTeX error. @main.tex#L1-8 Error at line 4: Undefined control sequence. Keep the change minimal.")
  #expect(EditorIssue(severity: .warning, path: "a.tex", line: 9, message: "Overfull").claudePrompt() == "Fix this LaTeX warning. @a.tex#L3-13 Warning at line 9: Overfull. Keep the change minimal.")
  // pixels: a red wave under "}" and a red dot in the margin on its line
  v.issuesOverlay.frame = v.canvas.bounds
  let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
  v.cacheDisplay(in: v.bounds, to: rep)
  if let out = ProcessInfo.processInfo.environment["TAUDOT_ISSUES_PNG"] { try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out)) }
  let sc = CGFloat(rep.pixelsWide) / rep.size.width
  func reds(_ r: NSRect) -> Int {
    var n = 0
    for y in Int(r.minY * sc)..<Int(r.maxY * sc) { for x in Int(r.minX * sc)..<Int(r.maxX * sc) {
      if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.redComponent > 0.6, c.greenComponent < 0.45, c.blueComponent < 0.45 { n += 1 }
    } }
    return n
  }
  let brace = v.convert(try #require(v.issueRects(v.issueMarks[0]).first), from: v.canvas)
  #expect(reds(NSRect(x: brace.minX - 1, y: brace.maxY - 6, width: brace.width + 2, height: 9)) > 3, "a wave under }")
  #expect(reds(NSRect(x: 0, y: brace.minY, width: v.convert(tv.textContainerOrigin, from: v.canvas).x, height: brace.height)) > 3, "a dot in the margin")
  // a clean run clears them
  ed.setIssues([])
  #expect(v.issueMarks.isEmpty && v.issueCardText == "")
}

/// `TAUDOT_ISSUES_SHOT=<png> swift test --filter issuesShot`: an error and a warning marked, the card open (off-screen).
@MainActor @Test func issuesShot() throws {
  guard let out = ProcessInfo.processInfo.environment["TAUDOT_ISSUES_SHOT"] else { return }
  let text = """
  \\section{Introduction}
  Tide pools have long served as natural laboratories for the study of
  simple behaviour, like tiny algorithms.} From limpets that return
  to the same rock \\citep{smith2015} to crabs that trade shells in
  orderly queues \\citep{jones2019}.

  So what, then, makes a great \\textbff{tide pool} for a field survey?
  \\textit{Access} matters most, as low tide is short and the walk back
  to shore sets the pace of every visit.

  """
  let ed = NativeEditor(folder: URL(fileURLWithPath: "/tmp"), socket: URL(fileURLWithPath: "/tmp/none.sock"), frame: NSRect(x: 0, y: 0, width: 760, height: 330))
  let w = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: 760, height: 330), styleMask: [.titled], backing: .buffered, defer: false)
  w.contentView = ed.view
  ed.adopt(NativeDoc(docID: "d", path: "main.tex", text: text, seq: 0, conn: nil))
  w.layoutIfNeeded()
  ed.setIssues([
    EditorIssue(severity: .error, path: "main.tex", line: 3, column: 40, message: "Extra }, or forgotten \\endgroup", plain: "There's a } with no matching {"),
    EditorIssue(severity: .warning, path: "main.tex", line: 7, column: 37, message: "Undefined control sequence", plain: "\\textbff isn't defined (a typo for \\textbf?)"),
  ])
  let tv = ed.view.textView
  tv.setSelectedRange(NSRange(location: (tv.string as NSString).range(of: "algorithms").location, length: 0))
  ed.view.layoutSubtreeIfNeeded()
  let v = ed.view
  let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
  v.cacheDisplay(in: v.bounds, to: rep)
  try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
}

/// `TAUDOT_SCROLL_BENCH=<a .tex file> swift test -c release --filter scrollBench`: trackpad-like scrolling through the
/// native editor, off-screen: 60 events of 14 pt at 120 Hz, then a momentum tail (×0.95 a frame), down and back up.
/// TAUDOT_SCROLL_FROM=<line>: start there instead (as after a search or a PDF click) and scroll up, into text TextKit
/// hasn't laid out. Per event: the main thread's time (the event, layout, display), the clip's move, and where a line
/// near the top went. Jumps: the clip moving other than the event's delta, or the text moving other than the clip
/// (TextKit 2 correcting its guessed heights); height changes of the document. With the margin's per-scroll work.
/// TAUDOT_SCROLL_VIM=1: Vim keys on. (Continuous pixel deltas without gesture phases: phased synthetic events send
/// NSScrollView into its gesture tracking loop, which waits for real ones.)
@MainActor @Test func scrollBench() throws {
  guard let file = ProcessInfo.processInfo.environment["TAUDOT_SCROLL_BENCH"] else { return }
  let env = ProcessInfo.processInfo.environment
  let text = try String(contentsOfFile: file, encoding: .utf8)
  let ed = NativeEditor(folder: URL(fileURLWithPath: "/tmp"), socket: URL(fileURLWithPath: "/tmp/none.sock"), frame: NSRect(x: 0, y: 0, width: 720, height: 900))
  let w = NSWindow(contentRect: NSRect(x: -5000, y: 0, width: 720, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
  w.contentView = ed.view
  ed.adopt(NativeDoc(docID: "d", path: "main.tex", text: text, seq: 0, conn: nil))
  if env["TAUDOT_SCROLL_VIM"] != nil { ed.view.vimEnabled = true }
  w.makeFirstResponder(ed.view.textView)
  ed.view.onChange { _ = ed.view.visibleLines.map { ed.view.y(ofLine: $0) } }  // the margin's work
  w.layoutIfNeeded()
  w.displayIfNeeded()
  RunLoop.main.run(until: Date().addingTimeInterval(0.3))
  let clip = ed.view.scroll.contentView
  func event(_ dy: Double) -> NSEvent? {
    guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(dy.rounded()), wheel2: 0, wheel3: 0) else { return nil }
    e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    e.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: dy)
    e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: dy)
    return NSEvent(cgEvent: e)
  }
  var ms: [Double] = [], jumps: [String] = [], jumpLog: [String] = []
  var heightChanges = 0, textJumps = 0
  func send(_ dy: Double) {
    guard let e = event(dy) else { return }
    let y0 = clip.bounds.minY, h0 = ed.view.textView.frame.height
    let anchor = ed.view.visibleLines.lowerBound + 8
    let a0 = ed.view.y(ofLine: anchor)
    let t0 = CACurrentMediaTime()
    ed.view.scroll.scrollWheel(with: e)
    RunLoop.main.run(until: Date())
    w.layoutIfNeeded()
    w.displayIfNeeded()
    ms.append((CACurrentMediaTime() - t0) * 1000)
    let moved = clip.bounds.minY - y0
    if ed.view.textView.frame.height != h0 { heightChanges += 1 }
    let atEnd = clip.bounds.minY <= 0.5 || clip.bounds.maxY >= ed.view.textView.frame.height - 0.5
    if dy != 0, !atEnd, abs(moved - (-dy)) > 3 { jumps.append(String(format: "%.0f→%.0f", -dy, moved)) }
    if let a0, let a1 = ed.view.y(ofLine: anchor), abs((a0 - a1) - moved) > 1.5 {
      textJumps += 1
      if textJumps <= 4 { jumpLog.append(String(format: "line %d moved %.1f, clip %.1f", anchor, a0 - a1, moved)) }
    }
  }
  let from = env["TAUDOT_SCROLL_FROM"].flatMap(Int.init)
  if let from {
    ed.view.jump(line: from, col: 0)
    w.layoutIfNeeded(); w.displayIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
  }
  let deadline = Date().addingTimeInterval(60)
  for dir in from != nil ? [-1.0, -1.0, 1.0] : [1.0, -1.0] {
    for _ in 0..<60 where Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.008)); send(-14 * dir) }
    var m = -30.0 * dir
    while abs(m) > 0.5, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.008)); m *= 0.95; send(m) }
  }
  let s = ms.sorted()
  func q(_ p: Double) -> Double { s[min(s.count - 1, Int(p * Double(s.count)))] }
  print(String(format: "scrollBench: %d events, frame ms p50 %.2f p95 %.2f max %.2f, over 8.3 ms: %d; clip jumps %d %@; text jumps %d (%@); height changes %d",
               ms.count, q(0.5), q(0.95), s.last!, ms.filter { $0 > 8.3 }.count, jumps.count, jumps.prefix(6).joined(separator: " "), textJumps, jumpLog.joined(separator: "; "), heightChanges))
}

/// Laying the doc out ahead (after a jump into text not laid out yet) never moves what is on screen, and leaves no
/// height to guess: the document's height is final.
@MainActor @Test func layoutAheadKeepsTheViewStill() async throws {
  var lines: [String] = []
  for i in 0..<1500 { lines.append(i % 7 == 0 ? "" : "Line \(i): " + String(repeating: "words that wrap across the column ", count: 1 + i % 5)) }
  let ed = NativeEditor(folder: URL(fileURLWithPath: "/tmp"), socket: URL(fileURLWithPath: "/tmp/none.sock"), frame: NSRect(x: 0, y: 0, width: 600, height: 700))
  let w = NSWindow(contentRect: NSRect(x: -5000, y: 0, width: 600, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
  w.contentView = ed.view
  ed.adopt(NativeDoc(docID: "d", path: "main.tex", text: lines.joined(separator: "\n") + "\n", seq: 0, conn: nil))
  w.layoutIfNeeded()
  ed.view.jump(line: 1200, col: 0)  // at once, before the layout ahead is done
  let y0 = try #require(ed.view.y(ofLine: 1199))
  // (15 s: the whole suite shares the main actor, and the slices are a run-loop turn apart)
  var ys: [CGFloat] = []
  let end = Date().addingTimeInterval(15)
  while !ed.view.laidOutAhead, Date() < end {
    try? await Task.sleep(for: .milliseconds(2))
    if let y = ed.view.y(ofLine: 1199) { ys.append(y) }
  }
  #expect(ed.view.laidOutAhead)
  #expect(ys.allSatisfy { abs($0 - y0) < 1 }, "line 1200 stayed at \(y0): \(Set(ys.map { Int($0) }))")
  let h = ed.view.documentHeight
  if let lay = ed.view.textLayout {
    _ = lay.layOut(from: 0, budget: 10)
    ed.view.resizeDocument()
  } else {
    ed.view.textView.textLayoutManager!.ensureLayout(for: ed.view.textView.textLayoutManager!.documentRange)
  }
  #expect(abs(ed.view.documentHeight - h) < 1, "height final: \(h) → \(ed.view.documentHeight)")
}
