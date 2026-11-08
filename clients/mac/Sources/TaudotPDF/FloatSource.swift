// Figures and cross-references in the source (pure, testable without a PDF).
//
// A click on a figure's graphic gets a SyncTeX line that is rarely the figure's own: the image box often carries
// `\end{figure}` or the paragraph after the float. So the float is found in the source instead: the figure (or table)
// environment around the line SyncTeX gave, or the one just before it, and its `\includegraphics` line.
//
// A click on a cross-reference ("Figure 3") finds the `\ref`-like command it was typeset from, and the `\label` it
// points at.
import Foundation

public enum FloatSource {
  public struct Graphic: Equatable, Sendable {
    public var line: Int  // 1-based
    public var column: Int  // UTF-8 byte offset of `\includegraphics`
    public var file: String
  }

  /// A float environment: `figure`, `figure*`, `table`, `table*`, `wrapfigure`, `algorithm`, …, lines 1-based.
  public struct Env: Equatable, Sendable {
    public var kind: String
    public var begin: Int
    public var end: Int
    public var graphics: [Graphic] = []
    public var labels: [(line: Int, key: String)] = []
    public static func == (a: Env, b: Env) -> Bool {
      a.kind == b.kind && a.begin == b.begin && a.end == b.end && a.graphics == b.graphics
        && a.labels.map(\.key) == b.labels.map(\.key)
    }
  }

  static let floats: Set<String> = ["figure", "figure*", "table", "table*", "wrapfigure", "wraptable", "algorithm", "subfigure"]

  /// A line without its `%` comment (an escaped `\%` stays).
  static func code(_ line: String) -> Substring {
    var prev: Character = " "
    for (i, c) in zip(line.indices, line) {
      if c == "%" && prev != "\\" { return line[..<i] }
      prev = c
    }
    return line[...]
  }

  /// `\name{arg}` occurrences in a line (comments skipped): the name, the argument, the byte column of the backslash.
  static func commands(_ line: String, _ names: Set<String>) -> [(name: String, arg: String, start: Int, end: Int)] {
    let s = Array(code(line).utf8)
    var out: [(String, String, Int, Int)] = []
    var i = 0
    while i < s.count {
      guard s[i] == UInt8(ascii: "\\") else { i += 1; continue }
      var j = i + 1
      while j < s.count, (s[j] >= 65 && s[j] <= 90) || (s[j] >= 97 && s[j] <= 122) { j += 1 }
      if j < s.count, s[j] == UInt8(ascii: "*") { j += 1 }
      let name = String(decoding: s[(i + 1)..<j], as: UTF8.self)
      guard names.contains(name) else { i = max(j, i + 1); continue }
      // optional [..] arguments, then {..}
      var k = j
      while k < s.count, s[k] == UInt8(ascii: " ") { k += 1 }
      while k < s.count, s[k] == UInt8(ascii: "[") {
        while k < s.count, s[k] != UInt8(ascii: "]") { k += 1 }
        k += 1
      }
      guard k < s.count, s[k] == UInt8(ascii: "{") else { i = j; continue }
      var depth = 0, e = k
      while e < s.count {
        if s[e] == UInt8(ascii: "{") { depth += 1 }
        if s[e] == UInt8(ascii: "}") { depth -= 1; if depth == 0 { break } }
        e += 1
      }
      let arg = String(decoding: s[(k + 1)..<min(e, s.count)], as: UTF8.self)
      out.append((name, arg, i, min(e + 1, s.count)))
      i = e + 1
    }
    return out
  }

  /// Every float environment in a file's lines, innermost last when nested.
  public static func environments(_ lines: [String]) -> [Env] {
    var open: [Env] = []
    var out: [Env] = []
    for (n, line) in lines.enumerated() {
      for c in commands(line, ["begin", "end", "includegraphics", "label"]) {
        switch c.name {
        case "begin" where floats.contains(c.arg):
          open.append(Env(kind: c.arg, begin: n + 1, end: n + 1))
        case "end" where floats.contains(c.arg):
          if let i = open.lastIndex(where: { $0.kind == c.arg }) {
            var e = open.remove(at: i)
            e.end = n + 1
            out.append(e)
            // a subfigure's graphics and labels belong to its figure too
            if let p = open.indices.last {
              open[p].graphics += e.graphics
              open[p].labels += e.labels
            }
          }
        case "includegraphics":
          if !open.isEmpty { open[open.count - 1].graphics.append(Graphic(line: n + 1, column: c.start, file: c.arg)) }
        case "label":
          if !open.isEmpty { open[open.count - 1].labels.append((n + 1, c.arg)) }
        default: break
        }
      }
    }
    return out.sorted { ($0.begin, -$0.end) < ($1.begin, -$1.end) }
  }

  /// The float a SyncTeX hit on a figure belongs to: the innermost one holding the line (a subfigure's figure, not the
  /// subfigure, unless it is the only one), else the nearest one ending at most `after` lines before it (SyncTeX gave
  /// the paragraph after the float).
  public static func around(_ lines: [String], line: Int, after: Int = 4) -> Env? {
    let envs = environments(lines).filter { $0.kind != "subfigure" }
    if let e = envs.filter({ $0.begin <= line && line <= $0.end }).min(by: { $0.end - $0.begin < $1.end - $1.begin }) { return e }
    // between the float's end and the line: nothing but blank or comment lines, or a few lines of text at most
    return envs.filter { $0.end < line && line - $0.end <= after }.max { $0.end < $1.end }
  }

  /// Where a click on a float's graphic goes: its `\includegraphics` (the one whose file matches `file` when given,
  /// else the one nearest `near`, else the first), else `\begin{…}`. (line, byte column)
  public static func target(_ e: Env, file: String? = nil, near: Int? = nil) -> (line: Int, column: Int) {
    if let file, let g = e.graphics.first(where: { ($0.file as NSString).deletingPathExtension.hasSuffix((file as NSString).deletingPathExtension) }) {
      return (g.line, g.column)
    }
    if let near, let g = e.graphics.min(by: { abs($0.line - near) < abs($1.line - near) }), e.begin <= near, near <= e.end {
      return (g.line, g.column)
    }
    if let g = e.graphics.first { return (g.line, g.column) }
    return (e.begin, 0)
  }

  // ---- cross-references ------------------------------------------------------------------------------------------

  public static let refCommands: Set<String> = ["ref", "autoref", "cref", "Cref", "eqref", "vref", "nameref", "Autoref", "subref"]

  public struct Ref: Equatable, Sendable {
    public var command: String
    public var key: String
    public var start: Int  // byte column of the backslash
    public var end: Int  // after the closing brace
  }

  /// The `\ref`-like commands of a line, in order. `\cref{a,b}` gives the first key.
  public static func refs(_ line: String) -> [Ref] {
    commands(line, refCommands).map { c in
      Ref(command: c.name, key: c.arg.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? c.arg, start: c.start, end: c.end)
    }
  }

  /// Words a reference is typeset with besides its number ("Figure 3", "Fig. 3", "Table 2", "Eq. (4)", "Section 5").
  public static let refWords: Set<String> = [
    "figure", "figures", "fig", "figs", "table", "tables", "tab", "section", "sections", "sec", "appendix", "app",
    "equation", "equations", "eq", "eqs", "algorithm", "alg", "chapter", "chap", "listing", "line", "lemma", "theorem",
    "thm", "definition", "def", "corollary", "proposition", "prop", "part", "subsection", "item", "step",
  ]

  /// Whether a word on the page could be (part of) a typeset reference: its number ("3", "2.1", "A.4", "(5)") or one
  /// of `refWords`.
  public static func refLike(_ word: String) -> Bool {
    let w = word.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "()[].,;:~"))
    if refWords.contains(w) { return true }
    guard let f = w.first else { return false }
    return (f.isNumber || (f.isLetter && w.count <= 4 && w.dropFirst().first.map { $0 == "." || $0.isNumber } == true))
      && w.allSatisfy { $0.isNumber || $0 == "." || $0.isLetter } && w.contains { $0.isNumber }
  }

  /// The reference a click picked: the first `\ref`-like command after the source word matched just left of the click
  /// (`anchorEnd`, a byte column), with only reference words (or nothing) between them.
  public static func ref(after anchorEnd: Int, in line: String) -> Ref? {
    guard let r = refs(line).first(where: { $0.start >= anchorEnd }) else { return nil }
    let between = Array(line.utf8)[min(anchorEnd, line.utf8.count)..<r.start]
    let gap = String(decoding: between, as: UTF8.self)
    let words = WordMatch.sourceWords(gap).map(\.text)
    return words.allSatisfy { refWords.contains($0) } && words.count <= 2 ? r : nil
  }

  /// The reference just before a source word (the click was the line's first words, so the anchor is to its right).
  public static func ref(before anchorStart: Int, in line: String) -> Ref? {
    guard let r = refs(line).last(where: { $0.end <= anchorStart }) else { return nil }
    let gap = String(decoding: Array(line.utf8)[r.end..<min(anchorStart, line.utf8.count)], as: UTF8.self)
    return WordMatch.sourceWords(gap).isEmpty ? r : nil
  }

  /// The reference after a source word, which may sit on a following line of the same paragraph (a sentence a line):
  /// the rest of `line` (1-based) from `column`, then up to `more` lines after it, comments left out.
  public static func ref(after column: Int, line: Int, in lines: [String], more: Int = 3) -> Ref? {
    guard line >= 1, line <= lines.count else { return nil }
    let first = String(code(lines[line - 1]))
    let rest = String(decoding: Array(first.utf8)[min(column, first.utf8.count)...], as: UTF8.self)
    var joined = rest
    for l in line..<min(lines.count, line + more) {
      let c = code(lines[l]).trimmingCharacters(in: .whitespaces)
      if c.isEmpty && !lines[l].contains("%") { break }  // a blank line: the paragraph ended
      joined += " " + c
    }
    return ref(after: 0, in: joined)
  }

  /// The reference before a source word, which may end a line before it: up to `more` lines before `line`, then
  /// `line` up to `column`, comments left out.
  public static func ref(before column: Int, line: Int, in lines: [String], more: Int = 3) -> Ref? {
    guard line >= 1, line <= lines.count else { return nil }
    let last = String(code(lines[line - 1]))
    var joined = String(decoding: Array(last.utf8)[..<min(column, last.utf8.count)], as: UTF8.self)
    var l = line - 2
    while l >= max(0, line - 1 - more) {
      let c = code(lines[l]).trimmingCharacters(in: .whitespaces)
      if c.isEmpty && !lines[l].contains("%") { break }
      joined = c + " " + joined
      l -= 1
    }
    return ref(before: joined.utf8.count, in: joined)
  }

  /// Where `\label{key}` is in a file's lines: (line 1-based, byte column).
  public static func label(_ key: String, in lines: [String]) -> (line: Int, column: Int)? {
    for (n, l) in lines.enumerated() where l.contains(key) {
      if let c = commands(l, ["label"]).first(where: { $0.arg == key }) { return (n + 1, c.start) }
    }
    return nil
  }
}
