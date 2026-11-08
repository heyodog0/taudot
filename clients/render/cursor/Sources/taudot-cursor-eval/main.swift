// taudot-cursor-eval DOCDIR OUTDIR [N] [SEED]
//
// Scores TaudotCursor on a typeset paper: OUTDIR holds main.synctex and glyphs-P.json from
// clients/render/cursor/tools/txp.py. Picks N random (line, column) positions of each kind in DOCDIR/main.tex's body
// and reports how often the dot lands on the right glyph, the fallbacks, and the glyph → source round trip.
import Foundation
import TaudotCursor

let args = CommandLine.arguments
guard args.count >= 3 else {
  print("usage: taudot-cursor-eval DOCDIR OUTDIR [N] [SEED]")
  exit(2)
}
let doc = URL(fileURLWithPath: args[1]), outDir = URL(fileURLWithPath: args[2])
let count = args.count > 3 ? Int(args[3])! : 200
var seed: UInt64 = args.count > 4 ? UInt64(args[4])! : 42
func rand(_ n: Int) -> Int {  // splitmix64: the same positions every run
  seed &+= 0x9E3779B97F4A7C15
  var z = seed
  z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
  z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
  return Int((z ^ (z >> 31)) % UInt64(n))
}

let tSync = Date()
let synctex = SyncTeX(text: try String(contentsOf: outDir.appendingPathComponent("main.synctex"), encoding: .utf8))
print(String(format: "synctex: %d pages, read in %.0f ms", synctex.pages.count, Date().timeIntervalSince(tSync) * 1000))
let map = CursorMap(synctex: synctex) { p in
  try? PageGlyphs.load(outDir.appendingPathComponent("glyphs-\(p).json"))
}
let tLoad = Date()
for p in 0..<synctex.pages.count { _ = map.page(p) }
print(String(format: "glyph files decoded: %.1f ms a page", Date().timeIntervalSince(tLoad) * 1000 / Double(max(synctex.pages.count, 1))))
var files: [String: [String]] = [:]
func lines(_ f: String) -> [String]? {
  if let l = files[f] { return l }
  let u = f.hasPrefix("/") ? URL(fileURLWithPath: f) : doc.appendingPathComponent(f)
  guard let s = try? String(contentsOf: u, encoding: .utf8) else { return nil }
  let l = s.components(separatedBy: "\n")
  files[f] = l
  return l
}
func text(_ f: String, _ l: Int) -> String? {
  guard let ls = lines(f), l >= 1, l <= ls.count else { return nil }
  return ls[l - 1]
}

// body lines of main.tex: between \begin{document} and \end{document}, outside floats and display maths
let main = lines("main.tex")!
let skipEnvs = ["figure", "table", "equation", "align", "algorithm", "tabular", "gather", "multline", "eqnarray",
                "verbatim", "lstlisting", "minted", "tikzpicture", "displaymath"]
var body: [Int] = []  // 1-based
var inDoc = false, depth = 0
for (i, l) in main.enumerated() {
  if l.contains("\\begin{document}") { inDoc = true; continue }
  if l.contains("\\end{document}") { break }
  guard inDoc else { continue }
  for e in skipEnvs {
    for star in ["", "*"] {
      depth += l.components(separatedBy: "\\begin{\(e)\(star)}").count - 1
      depth -= l.components(separatedBy: "\\end{\(e)\(star)}").count - 1
    }
  }
  if depth == 0 && !synctex.records(file: "main.tex", line: i + 1).isEmpty && !l.contains("\\end{") && !l.contains("\\[") && !l.contains("\\]") && !l.contains("$$") { body.append(i + 1) }
}

struct Pos { var line: Int; var col: Int; var token: SourceLine.Token; var source: SourceLine }
func positions(_ want: (SourceLine, Int, SourceLine.Token?) -> Bool, _ n: Int) -> [Pos] {
  var out: [Pos] = []
  var tries = 0
  while out.count < n && tries < n * 2000 {
    tries += 1
    let l = body[rand(body.count)]
    let s = SourceLine(main[l - 1])
    let bytes = s.text.utf8.count
    guard bytes > 0 else { continue }
    let c = rand(bytes)
    let tok = s.tokens.first { c >= $0.col && c < $0.end }
    // the start of a character only
    if let tok, tok.col != c && s.classes[c] != .command && s.classes[c] != .comment { continue }
    guard want(s, c, tok) else { continue }
    out.append(Pos(line: l, col: c, token: tok ?? SourceLine.Token(letter: 0, col: c, end: c, kind: .space), source: s))
  }
  return out
}

// ---- body text: the dot on the right glyph -------------------------------------------------------------------------
let textPos = positions({ s, c, tok in
  guard let tok, tok.kind == .text, s.classes[c] == .text else { return false }
  // a letter or digit, so "the right glyph" means something
  return Unicode.Scalar(tok.letter).map { $0.properties.isAlphabetic || $0.properties.numericType != nil } ?? false
}, count)

func glyphLetter(_ c: Caret) -> UInt32? {
  guard let g = map.page(c.page)?.glyphs[c.glyph] else { return nil }
  var ls: [UInt32] = []
  for u in g.t.unicodeScalars {
    for d in String(Character(u)).decomposedStringWithCanonicalMapping.unicodeScalars where !(0x300...0x36F).contains(d.value) {
      ls += d.properties.lowercaseMapping.unicodeScalars.map(\.value)
    }
  }
  if g.t == "ﬁ" || g.t == "ﬂ" { return nil }
  return c.letterInGlyph < ls.count ? ls[c.letterInGlyph] : nil
}
func sourceWord(_ p: Pos) -> String {
  let toks = p.source.tokens
  guard var i = toks.firstIndex(where: { $0.col == p.token.col }) else { return "" }
  var j = i
  while i > 0 && toks[i - 1].kind == .text && toks[i - 1].letter != 0x20 { i -= 1 }
  while j + 1 < toks.count && toks[j + 1].kind == .text && toks[j + 1].letter != 0x20 { j += 1 }
  return String(String.UnicodeScalarView(toks[i...j].compactMap { Unicode.Scalar($0.letter) }))
}

var wordRight = 0, right = 0, wrongLetter = 0, approx = 0, none = 0, roundTrip = 0, rtTried = 0
var times: [Double] = []
var failures: [String] = []
for p in textPos {
  let t0 = Date()
  let c = map.caret(file: "main.tex", line: p.line, text: p.source.text, column: p.col)
  times.append(Date().timeIntervalSince(t0) * 1000)
  guard let c else { none += 1; failures.append("none  \(p.line):\(p.col) \(sourceWord(p))"); continue }
  if c.approximate { approx += 1; failures.append("approx \(p.line):\(p.col) \(sourceWord(p))"); continue }
  if glyphLetter(c) == p.token.letter && !c.after {
    right += 1
    // stronger: the glyph's typeset word holds the source word (hyphenated words: one of its halves)
    let pg = map.page(c.page)!
    let w = pg.glyphs[c.glyph].w
    let word = pg.glyphs.filter { $0.w == w }.map(\.t).joined().lowercased().filter { $0.isLetter || $0.isNumber }
    let src = sourceWord(p).lowercased().filter { $0.isLetter || $0.isNumber }
    let half = word.hasSuffix("-") ? String(word.dropLast()) : word
    if src.contains(word) || word.contains(src) || (!half.isEmpty && src.contains(half)) { wordRight += 1 }
    else { failures.append("word  \(p.line):\(p.col) \(src) vs glyph word \(word)") }
  } else {
    wrongLetter += 1
    let g = map.page(c.page)!.glyphs[c.glyph]
    failures.append("wrong \(p.line):\(p.col) '\(Unicode.Scalar(p.token.letter)!)' in \(sourceWord(p)) → glyph '\(g.t)' p\(c.page + 1)")
  }
  // glyph → source
  rtTried += 1
  let s = map.source(page: c.page, glyph: c.glyph, letter: c.letterInGlyph, text: text)
  if let s, s.line == p.line, s.column == p.token.col, !s.approximate { roundTrip += 1 }
  else { failures.append("trip  \(p.line):\(p.col) \(sourceWord(p)) → \(s.map { "\($0.line):\($0.column)\($0.approximate ? " approx" : "")" } ?? "nil")") }
}
times.sort()
print(String(format: "body text: %d/%d on the right glyph (%.1f%%), %d wrong letter, %d approximate, %d no dot",
             right, textPos.count, 100.0 * Double(right) / Double(max(textPos.count, 1)), wrongLetter, approx, none))
print("  of those, the glyph's word holds the source word: \(wordRight)")
print(String(format: "round trip glyph → source: %d/%d (%.1f%%)", roundTrip, rtTried,
             100.0 * Double(roundTrip) / Double(max(rtTried, 1))))
print(String(format: "caret time: median %.2f ms, p90 %.2f ms, max %.2f ms (first call on a line aligns it)",
             times[times.count / 2], times[times.count * 9 / 10], times.last!))

// ---- fallbacks -----------------------------------------------------------------------------------------------------
for (name, cls) in [("maths", SourceLine.ByteClass.math), ("command", .command), ("comment", .comment)] {
  let ps = positions({ s, c, _ in
    s.classes[c] == cls && (cls != .comment || s.tokens.contains { $0.kind == .text && $0.letter != 0x20 && $0.end <= c })
  }, count / 4)
  var dots = 0, approxDots = 0, exact = 0
  for p in ps {
    guard let c = map.caret(file: "main.tex", line: p.line, text: p.source.text, column: p.col) else { continue }
    dots += 1
    if c.approximate { approxDots += 1 } else { exact += 1 }
  }
  print("\(name): \(ps.count) positions, \(dots) with a dot (\(exact) exact, \(approxDots) approximate), \(ps.count - dots) none")
}
// lines that typeset nothing: comment-only and blank lines
var silent = 0, silentDots = 0
for l in body where main[l - 1].trimmingCharacters(in: .whitespaces).hasPrefix("%") || main[l - 1].trimmingCharacters(in: .whitespaces).isEmpty {
  silent += 1
  if map.caret(file: "main.tex", line: l, text: main[l - 1], column: 0) != nil { silentDots += 1 }
}
print("blank or comment-only lines: \(silent), with a dot: \(silentDots)")
if ProcessInfo.processInfo.environment["VERBOSE"] != nil { failures.forEach { print("  " + $0) } }
else { failures.prefix(25).forEach { print("  " + $0) } }

// DEBUG=LINE:COL prints what the caret saw
if let d = ProcessInfo.processInfo.environment["DEBUG"] {
  let parts = d.split(separator: ":").compactMap { Int($0) }
  let (l, c) = (parts[0], parts[1])
  print("records:", synctex.records(file: "main.tex", line: l).map { "p\($0.page + 1) \($0.record.kind) y\(Int($0.record.y)) x\(Int($0.record.x))" }.prefix(12))
  print(map.debug(file: "main.tex", line: l, text: main[l - 1], column: c))
}
if let d = ProcessInfo.processInfo.environment["DEBUG_Y"] {
  let v = d.split(separator: ":").compactMap { Double($0) }
  print(synctex.lines(page: Int(v[0]), y0: v[1], y1: v[2]).map(\.line))
  let pg = map.page(Int(v[0]))!
  let g = pg.glyphs[Int(v[3])]
  print("glyph", g.t, g.b, "line", pg.lines[g.l].b)
}
