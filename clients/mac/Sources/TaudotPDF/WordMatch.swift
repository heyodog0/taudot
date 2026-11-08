// Word-level SyncTeX: SyncTeX only knows lines, so the word is found by matching the source line's words against the
// words on the typeset lines (read from the page by PageText). Pure functions, tested in TaudotPDFTests.
import CoreGraphics
import Foundation

public enum WordMatch {
  /// A word of a source line: its normalised text and UTF-8 byte columns [start, end) in the line (Neovim's columns).
  public struct SourceWord: Equatable, Sendable {
    public var text: String
    public var start: Int, end: Int
    public init(_ text: String, _ start: Int, _ end: Int) { self.text = text; self.start = start; self.end = end }
  }

  /// A word read off the page, in reading order. `rects` are in page points from the top-left (two for a word
  /// hyphenated across lines). `hyphenBreak`: it is the last word of its typeset line and ends with a hyphen.
  public struct PageWord: Equatable, Sendable {
    public var text: String
    public var rects: [CGRect]
    public var hyphenBreak = false
    public init(_ text: String, _ rects: [CGRect], hyphenBreak: Bool = false) {
      self.text = text; self.rects = rects; self.hyphenBreak = hyphenBreak
    }
  }

  /// Commands whose next braced argument doesn't show up as that text on the page.
  static let hiddenArg: Set<String> = [
    "cite", "citep", "citet", "citeauthor", "citeyear", "citealp", "citealt", "nocite", "ref", "eqref", "cref", "Cref",
    "autoref", "pageref", "nameref", "label", "begin", "end", "usepackage", "documentclass", "input", "include",
    "includegraphics", "bibliography", "bibliographystyle", "newcommand", "renewcommand", "def", "url", "href",
    "vspace", "hspace", "setlength", "addtolength", "color", "textcolor", "pagestyle", "thispagestyle",
  ]

  /// Lowercase, no accents, ligatures split (ﬁ → fi), letters and digits only.
  public static func normalize(_ s: String) -> String {
    let f = s.precomposedStringWithCompatibilityMapping
      .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    return String(String.UnicodeScalarView(f.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
  }

  /// The words of a LaTeX source line, skipping comments, control sequences, the arguments of `hiddenArg` commands
  /// and inline math.
  public static func sourceWords(_ line: String) -> [SourceWord] {
    let b = Array(line.utf8)
    var out: [SourceWord] = []
    var i = 0
    func isLetter(_ c: UInt8) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) }
    func skipGroup() {  // a balanced {...} (after spaces, a star and [...] options)
      while i < b.count && (b[i] == 32 || b[i] == 42) { i += 1 }
      while i < b.count && b[i] == 91 {  // [
        var depth = 0
        while i < b.count {
          if b[i] == 91 { depth += 1 } else if b[i] == 93 { depth -= 1; if depth == 0 { i += 1; break } }
          i += 1
        }
      }
      guard i < b.count && b[i] == 123 else { return }
      var depth = 0
      while i < b.count {
        if b[i] == 92 { i += 2; continue }
        if b[i] == 123 { depth += 1 } else if b[i] == 125 { depth -= 1; if depth == 0 { i += 1; return } }
        i += 1
      }
    }
    while i < b.count {
      let c = b[i]
      if c == 37 { break }  // %
      if c == 92 {  // \
        i += 1
        guard i < b.count else { break }
        if isLetter(b[i]) {
          let s = i
          while i < b.count && isLetter(b[i]) { i += 1 }
          let name = String(decoding: b[s..<i], as: UTF8.self)
          if hiddenArg.contains(name) { skipGroup() }
        } else {
          i += 1
        }
        continue
      }
      if c == 36 {  // $...$ (and $$...$$)
        i += 1
        while i < b.count && b[i] == 36 { i += 1 }
        while i < b.count && b[i] != 36 { if b[i] == 92 { i += 1 }; i += 1 }
        while i < b.count && b[i] == 36 { i += 1 }
        continue
      }
      // a run of letters and digits (apostrophes inside count: "don't")
      let s = i
      var j = i
      while j < b.count {
        let start = j
        let (scalar, n) = decode(b, j)
        guard let scalar else { break }
        // \- (a discretionary hyphen) inside a word: "exam\-ple"
        if scalar == "\\", j > s, j + 2 < b.count, b[j + 1] == 45, isAlnum(b, j + 2) { j += 2; continue }
        let wordy = CharacterSet.alphanumerics.contains(scalar)
          || ((scalar == "'" || scalar == "\u{2019}") && j > s && j + n < b.count && isAlnum(b, j + n))
        if !wordy { j = start; break }
        j += n
      }
      if j > s {
        let t = normalize(String(decoding: b[s..<j], as: UTF8.self))
        if !t.isEmpty { out.append(SourceWord(t, s, j)) }
        i = j
      } else {
        i += max(1, decode(b, i).1)
      }
    }
    return out
  }

  private static func decode(_ b: [UInt8], _ i: Int) -> (Unicode.Scalar?, Int) {
    var it = b[i...].makeIterator()
    var d = UTF8()
    if case .scalarValue(let s) = d.decode(&it) { return (s, UTF8.width(s)) }
    return (nil, 1)
  }

  private static func isAlnum(_ b: [UInt8], _ i: Int) -> Bool {
    guard let s = decode(b, i).0 else { return false }
    return CharacterSet.alphanumerics.contains(s)
  }

  /// The word the cursor is on (or touching), else the nearest one within `reach` bytes.
  public static func wordIndex(_ words: [SourceWord], column: Int, reach: Int = 12) -> Int? {
    if let i = words.firstIndex(where: { column >= $0.start && column <= $0.end }) { return i }
    var best: Int?, bestD = reach + 1
    for (i, w) in words.enumerated() {
      let d = column < w.start ? w.start - column : column - w.end
      if d < bestD { best = i; bestD = d }
    }
    return best
  }

  /// Same word, allowing for a misread letter or two in longer words.
  public static func same(_ a: String, _ b: String) -> Bool {
    if a == b { return true }
    let n = min(a.count, b.count)
    if n < 4 { return false }
    return distance(a, b, limit: n >= 8 ? 2 : 1) <= (n >= 8 ? 2 : 1)
  }

  static func distance(_ a: String, _ b: String, limit: Int) -> Int {
    let x = Array(a), y = Array(b)
    if abs(x.count - y.count) > limit { return limit + 1 }
    var prev = Array(0...y.count), cur = [Int](repeating: 0, count: y.count + 1)
    for i in 1...max(1, x.count) where !x.isEmpty {
      cur[0] = i
      for j in 1...max(1, y.count) where !y.isEmpty {
        cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
      }
      swap(&prev, &cur)
    }
    return x.isEmpty ? y.count : prev[y.count]
  }

  /// Joins a word broken by a hyphen at the end of a typeset line with the next one when the source has the joined
  /// word ("exam-" "ple" → "example").
  public static func joinHyphens(_ page: [PageWord], source: [SourceWord]) -> [PageWord] {
    let known = Set(source.map(\.text))
    var out: [PageWord] = []
    var i = 0
    while i < page.count {
      let w = page[i]
      if w.hyphenBreak, i + 1 < page.count, known.contains(w.text + page[i + 1].text) {
        out.append(PageWord(w.text + page[i + 1].text, w.rects + page[i + 1].rects))
        i += 2
      } else {
        out.append(w)
        i += 1
      }
    }
    return out
  }

  /// How well a and b line up around a[i] / b[j]: the word itself plus up to three neighbours each side.
  static func score(_ a: [String], _ i: Int, _ b: [String], _ j: Int) -> Double {
    guard same(a[i], b[j]) else { return 0 }
    var s = a[i] == b[j] ? 1.0 : 0.8
    for d in 1...3 {
      if i - d >= 0, j - d >= 0, same(a[i - d], b[j - d]) { s += 1.0 / Double(d) }
      if i + d < a.count, j + d < b.count, same(a[i + d], b[j + d]) { s += 1.0 / Double(d) }
    }
    return s
  }

  /// Best j in `b` for the word a[i]: the best-scoring match, ties broken by the closer relative position.
  static func best(_ a: [String], _ i: Int, _ b: [String]) -> (index: Int, score: Double)? {
    guard i >= 0, i < a.count else { return nil }
    var pick: (Int, Double, Double)?
    let rel = a.count > 1 ? Double(i) / Double(a.count - 1) : 0.5
    for j in b.indices {
      let s = score(a, i, b, j)
      guard s > 0 else { continue }
      let off = abs((b.count > 1 ? Double(j) / Double(b.count - 1) : 0.5) - rel)
      if pick == nil || s > pick!.1 || (s == pick!.1 && off < pick!.2) { pick = (j, s, off) }
    }
    return pick.map { ($0.0, $0.1) }
  }

  /// Forward: the page word for source word `target`.
  public static func forward(source: [SourceWord], target: Int, page: [PageWord]) -> (word: PageWord, score: Double)? {
    let p = joinHyphens(page, source: source)
    guard let r = best(source.map(\.text), target, p.map(\.text)) else { return nil }
    return (p[r.index], r.score)
  }

  /// Inverse: the source word for page word `clicked` (an index into `page`).
  public static func inverse(page: [PageWord], clicked: Int, source: [SourceWord]) -> (word: SourceWord, score: Double)? {
    guard clicked >= 0, clicked < page.count else { return nil }
    // join hyphenated halves, keeping track of where the clicked word went
    let known = Set(source.map(\.text))
    var p: [PageWord] = []
    var at = -1, i = 0
    while i < page.count {
      let w = page[i]
      if w.hyphenBreak, i + 1 < page.count, known.contains(w.text + page[i + 1].text) {
        if clicked == i || clicked == i + 1 { at = p.count }
        p.append(PageWord(w.text + page[i + 1].text, w.rects + page[i + 1].rects))
        i += 2
      } else {
        if clicked == i { at = p.count }
        p.append(w)
        i += 1
      }
    }
    guard let r = best(p.map(\.text), at, source.map(\.text)) else { return nil }
    return (source[r.index], r.score)
  }

  /// Reading order for words read from typeset lines: by line (`rows`, top to bottom, in page points), then x.
  /// Words outside every row are dropped. Marks `hyphenBreak` on the last word of a row when `raw` ended with "-".
  public static func order(_ words: [(raw: String, rect: CGRect)], rows: [CGRect]) -> [PageWord] {
    var byRow: [[(String, CGRect)]] = Array(repeating: [], count: rows.count)
    for w in words {
      let c = CGPoint(x: w.rect.midX, y: w.rect.midY)
      var bestRow = -1, bestOverlap = 0.0
      for (r, row) in rows.enumerated() where c.x >= row.minX - 2 && c.x <= row.maxX + 2 {
        let o = min(row.maxY, w.rect.maxY) - max(row.minY, w.rect.minY)
        if o > bestOverlap { bestRow = r; bestOverlap = o }
      }
      guard bestRow >= 0 else { continue }
      // the same word read twice (rows are read separately, with a margin that can catch the neighbour's text)
      let dup = byRow[bestRow].firstIndex { o in
        let i = o.1.intersection(w.rect)
        return !i.isNull && i.width * i.height > 0.5 * min(o.1.width * o.1.height, w.rect.width * w.rect.height)
      }
      if let dup {
        if w.rect.height > byRow[bestRow][dup].1.height { byRow[bestRow][dup] = (w.raw, w.rect) }  // the fuller read
      } else {
        byRow[bestRow].append((w.raw, w.rect))
      }
    }
    var out: [PageWord] = []
    for r in rows.indices.sorted(by: { rows[$0].minY < rows[$1].minY || (rows[$0].minY == rows[$1].minY && rows[$0].minX < rows[$1].minX) }) {
      let ws = byRow[r].sorted { $0.1.minX < $1.1.minX }
      for (k, w) in ws.enumerated() {
        let t = normalize(w.0)
        guard !t.isEmpty else { continue }
        let last = k == ws.count - 1
        out.append(PageWord(t, [w.1], hyphenBreak: last && (w.0.hasSuffix("-") || w.0.hasSuffix("\u{2010}"))))
      }
    }
    return out
  }
}
