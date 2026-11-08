import CoreGraphics
import Foundation

/// Where the source cursor is on the page, and the reverse.
public struct Caret: Sendable, Equatable {
  public var page: Int
  /// the caret's x: the left edge of the letter the cursor is before (or the right edge of the one it's after)
  public var x: Double
  public var top: Double, bottom: Double, baseline: Double
  /// the letter the cursor is on: its share of the glyph's advance box (a ligature's box split evenly)
  public var letter: CGRect
  public var glyph: Int, letterInGlyph: Int
  /// true when the caret sits after the letter (the cursor is on a space or past the line's last letter)
  public var after: Bool
  /// false: the source letter under the cursor was found on the page. true: the cursor is in a command, a comment,
  /// maths that didn't match, and this is the nearest typeset letter.
  public var approximate: Bool
}

public struct SourcePosition: Sendable, Equatable {
  public var file: String
  public var line: Int  // 1-based
  public var column: Int  // UTF-8 bytes
  public var approximate: Bool
}

public enum ColumnUnit: Sendable { case utf8, utf16 }

/// Source positions ↔ glyphs, through SyncTeX (which typeset lines a source line touched) and an alignment of the
/// source line's letters with those lines' glyphs.
///
/// Not thread-safe: use it from one queue or actor. What it caches, and when that goes:
/// - each page's glyphs, read through `pages` on first use or handed in with `setPage`: dropped by `update` when a
///   "pages" event lists the page as changed;
/// - each source line's alignment, keyed by (file, line, text): an edit changes the text, so the line is aligned
///   again on the next call (≤ 2 ms on the 32-page paper); `update` drops them all, since a new SyncTeX can move
///   any line.
public final class CursorMap {
  public private(set) var synctex: SyncTeX
  private let loadPage: (Int) -> PageGlyphs?
  private var pageCache: [Int: PageGlyphs] = [:]

  public init(synctex: SyncTeX, pages: @escaping (Int) -> PageGlyphs?) {
    self.synctex = synctex
    loadPage = pages
  }

  public func page(_ p: Int) -> PageGlyphs? {
    if let g = pageCache[p] { return g }
    let g = loadPage(p)
    pageCache[p] = g
    return g
  }

  /// Drop what was read from pages and lines.
  public func invalidate() { pageCache.removeAll(); lineCache.removeAll() }

  /// After a "pages" event from txp-render: the new SyncTeX (`["synctex", id, path]`), and the event's `changed`
  /// pages, whose glyphs are read again on next use. Pages at or past `count` are dropped too.
  public func update(synctex: SyncTeX, changed: [Int], count: Int? = nil) {
    self.synctex = synctex
    for p in changed { pageCache[p] = nil }
    if let count { for p in pageCache.keys where p >= count { pageCache[p] = nil } }
    lineCache.removeAll()
  }

  /// Hand in a page's glyphs read elsewhere (decoding one takes ~12 ms: do it off the main thread).
  public func setPage(_ p: Int, _ glyphs: PageGlyphs) {
    pageCache[p] = glyphs
    lineCache.removeAll()
  }

  // ---- the page's letters --------------------------------------------------------------------------------------------

  struct PageLetter {
    var u: UInt32
    var page: Int, glyph: Int, k: Int, of: Int  // letter k of `of` in the glyph (k -1: the space after the glyph)
    var far = false  // on a row next to the source line's own rows
  }

  /// The letters of typeset lines in order, a space between words and lines.
  func letters(_ rows: [(page: Int, line: Int, far: Bool)]) -> [PageLetter] {
    var out: [PageLetter] = []
    var lastGlyph = (page: -1, glyph: -1)
    for (p, l, far) in rows {
      guard let pg = page(p), l < pg.lines.count else { continue }
      let first = pg.lines[l].g[0], count = pg.lines[l].g[1]
      var word = -1
      for gi in first..<(first + count) {
        let g = pg.glyphs[gi]
        if g.w != word && !out.isEmpty && out.last!.u != Letters.space {
          out.append(PageLetter(u: Letters.space, page: lastGlyph.page, glyph: lastGlyph.glyph, k: -1, of: 0, far: far))
        }
        word = g.w
        let ls = Letters.fold(g.t)
        for (k, u) in ls.enumerated() {
          out.append(PageLetter(u: u, page: p, glyph: gi, k: k, of: ls.count, far: far))
        }
        lastGlyph = (p, gi)
      }
    }
    return out
  }

  func letterBox(_ l: PageLetter) -> CGRect? {
    guard l.glyph >= 0, let g = page(l.page)?.glyphs[l.glyph] else { return nil }
    let b = g.box
    guard l.k >= 0, l.of > 1 else { return b }
    let w = b.width / Double(l.of)
    return CGRect(x: b.minX + w * Double(l.k), y: b.minY, width: w, height: b.height)
  }

  /// The typeset lines a source line's SyncTeX records fall on, and the lines just before and after them (a line's
  /// first word follows the previous line's record).
  func rows(file: String, line: Int) -> [(page: Int, line: Int, far: Bool)] {
    var own = Set<Int>(), near = Set<Int>()  // page << 20 | line
    for (p, r) in synctex.records(file: file, line: line) {
      guard let pg = page(p) else { continue }
      for (li, L) in pg.lines.enumerated() {
        let b = L.b
        if r.y >= b[1] - 1 && r.y <= b[3] + 1 && r.x >= b[0] - 3 && r.x <= b[2] + 3 {
          own.insert(p << 20 | li)
          for d in [-1, 1] where li + d >= 0 && li + d < pg.lines.count { near.insert(p << 20 | (li + d)) }
        }
      }
    }
    return own.union(near).sorted().map { ($0 >> 20, $0 & 0xFFFFF, !own.contains($0)) }
  }

  // ---- one source line aligned with its typeset lines ----------------------------------------------------------------

  struct Aligned {
    var source: SourceLine
    var page: [PageLetter]
    var match: [Int]  // source token → page letter, -1
    var same: [Bool]
    var back: [Int: Int]  // page letter → source token (exact matches)
    var cost: Int
  }

  private var lineCache: [String: Aligned] = [:]

  func aligned(file: String, line: Int, text: String) -> Aligned? {
    let key = "\(file)\u{0}\(line)\u{0}\(text)"
    if let a = lineCache[key] { return a }
    let rows = rows(file: file, line: line)
    guard !rows.isEmpty else { return nil }
    let src = SourceLine(text)
    let pl = letters(rows)
    let r = Align.run(src.tokens.map(\.letter), pl.map(\.u), far: pl.map(\.far))
    var back: [Int: Int] = [:]
    for (i, j) in r.match.enumerated() where j >= 0 && r.same[i] { back[j] = i }
    let a = Aligned(source: src, page: pl, match: r.match, same: r.same, back: back, cost: r.cost)
    if lineCache.count > 64 { lineCache.removeAll() }
    lineCache[key] = a
    return a
  }

  // ---- source → caret ------------------------------------------------------------------------------------------------

  /// The caret for the cursor at `column` of line `line` (1-based) of `file`, whose text is `text`. nil when the line
  /// typesets nothing (no SyncTeX record, or no letter of it found on the page).
  public func caret(file: String, line: Int, text: String, column: Int, unit: ColumnUnit = .utf8) -> Caret? {
    guard let a = aligned(file: file, line: line, text: text) else { return nil }
    let src = a.source
    let col = unit == .utf8 ? column : src.utf8Column(utf16: column)
    let toks = src.tokens
    func found(_ t: Int) -> Bool { a.match[t] >= 0 && a.same[t] }
    func caretAt(_ t: Int, after: Bool, approximate: Bool) -> Caret? {
      let l = a.page[a.match[t]]
      guard l.glyph >= 0, let g = page(l.page)?.glyphs[l.glyph], var box = letterBox(l) else { return nil }
      var after = after
      if l.k < 0 { after = true }  // a space: the caret follows the word before it
      if l.k < 0 { box = CGRect(x: box.maxX, y: box.minY, width: 0, height: box.height) }
      return Caret(page: l.page, x: after ? box.maxX : box.minX, top: g.b[1], bottom: g.b[3], baseline: g.baseline,
                   letter: box, glyph: l.glyph, letterInGlyph: max(l.k, 0), after: after, approximate: approximate)
    }
    // the token under the cursor
    if let t = toks.firstIndex(where: { col >= $0.col && col < $0.end }) {
      let k = toks[t].kind
      if found(t) && k != .space { return caretAt(t, after: false, approximate: false) }
      if k == .space {
        // after the word before (or before the next word if the space opens the line)
        if t > 0 && found(t - 1) { return caretAt(t - 1, after: true, approximate: false) }
        if t + 1 < toks.count && found(t + 1) { return caretAt(t + 1, after: false, approximate: false) }
      }
    }
    // nothing found under the cursor: the nearest letter found, in the comment's case the one before it
    let inComment = col < src.classes.count && src.classes[col] == .comment
    var best: (t: Int, d: Int, after: Bool)?
    for (t, tok) in toks.enumerated() where found(t) && tok.kind != .space {
      let d: Int, after: Bool
      if tok.end <= col { d = col - tok.end + 1; after = true }
      else if tok.col > col { d = inComment ? Int.max / 2 : tok.col - col; after = false }
      else { d = 0; after = false }
      if best == nil || d < best!.d { best = (t, d, after) }
    }
    if col >= src.text.utf8.count, let b = best, b.after {
      // past the line's end: after its last letter, as exact as that letter
      return caretAt(b.t, after: true, approximate: false)
    }
    guard let b = best else { return nil }
    return caretAt(b.t, after: b.after, approximate: true)
  }

  // ---- glyph → source ------------------------------------------------------------------------------------------------

  /// The glyph under a point of `page` (points from the top-left), and which of its letters.
  public func glyph(page p: Int, x: Double, y: Double) -> (glyph: Int, letter: Int)? {
    guard let pg = page(p) else { return nil }
    var best: (Int, Double)?
    for (i, g) in pg.glyphs.enumerated() where g.c == 0 {
      let b = g.box
      let dx = x < b.minX ? b.minX - x : x > b.maxX ? x - b.maxX : 0
      let dy = y < b.minY ? b.minY - y : y > b.maxY ? y - b.maxY : 0
      let d = dx + dy * 3
      if best == nil || d < best!.1 { best = (i, d) }
      if d == 0 { break }
    }
    guard let (i, d) = best, d < 20 else { return nil }
    let g = pg.glyphs[i]
    let n = max(Letters.fold(g.t).count, 1)
    let k = min(n - 1, max(0, Int((x - g.b[0]) / max(g.b[2] - g.b[0], 0.01) * Double(n))))
    return (i, k)
  }

  /// The source position of letter `letter` of glyph `glyph` on `page`. `text(file, line)` gives a source line's
  /// text (nil if unknown). Candidates are the source lines SyncTeX puts on the glyph's typeset line and the lines
  /// next to them; the one whose alignment holds the letter wins.
  public func source(page p: Int, glyph gi: Int, letter: Int = 0,
                     text: (String, Int) -> String?) -> SourcePosition? {
    guard let pg = page(p), gi < pg.glyphs.count else { return nil }
    let g = pg.glyphs[gi]
    let L = pg.lines[g.l]
    var cands: [(String, Int)] = []
    var seen = Set<String>()
    // records on this typeset line first, then on the lines above and below (a paragraph's last line may carry
    // only the record of the blank line after it)
    let h = L.b[3] - L.b[1]
    for (y0, y1) in [(L.b[1] - 1, L.b[3] + 1), (L.b[1] - h - 1, L.b[3] + h + 1)] {
      for (f, l) in synctex.lines(page: p, y0: y0, y1: y1) {
        for d in [0, -1, 1] where l + d >= 1 && seen.insert("\(f)\u{0}\(l + d)").inserted { cands.append((f, l + d)) }
      }
    }
    var fallback: SourcePosition?
    var fallbackD = Int.max
    // several lines may hold the letter (the same words in two headings): the one with a record nearest the glyph
    var exact: (pos: SourcePosition, d: Double)?
    for (f, l) in cands {
      guard let t = text(f, l), let a = aligned(file: f, line: l, text: t) else { continue }
      guard let j = a.page.firstIndex(where: { $0.page == p && $0.glyph == gi && $0.k == letter }) else { continue }
      if let s = a.back[j] {
        var d = Double.infinity
        for (rp, r) in synctex.records(file: f, line: l, boxes: true) where rp == p && r.kind != "[" {
          d = min(d, abs(r.y - g.baseline) * 4 + max(0, r.x - g.b[2], g.b[0] - r.x - 400))
        }
        if exact == nil || d < exact!.d {
          exact = (SourcePosition(file: f, line: l, column: a.source.tokens[s].col, approximate: false), d)
        }
        continue
      }
      // the nearest source letter found near this page letter
      for (pj, s) in a.back {
        let d = abs(pj - j)
        if d < fallbackD && d < 40 {
          fallbackD = d
          fallback = SourcePosition(file: f, line: l, column: a.source.tokens[s].col, approximate: true)
        }
      }
    }
    return exact?.pos ?? fallback
  }

  public func source(page p: Int, x: Double, y: Double, text: (String, Int) -> String?) -> SourcePosition? {
    guard let (g, k) = glyph(page: p, x: x, y: y) else { return nil }
    return source(page: p, glyph: g, letter: k, text: text)
  }
}

extension CursorMap {
  /// What the alignment of a line looks like around a column (for the eval tool).
  public func debug(file: String, line: Int, text: String, column: Int) -> String {
    let rows = rows(file: file, line: line)
    var out = "rows: \(rows.map { "p\($0.page + 1)l\($0.line)" }.joined(separator: " "))\n"
    guard let a = aligned(file: file, line: line, text: text) else { return out + "no alignment" }
    out += "cost \(a.cost), \(a.source.tokens.count) source letters, \(a.page.count) page letters\n"
    out += "page: " + String(String.UnicodeScalarView(a.page.compactMap { Unicode.Scalar($0.u) })) + "\n"
    out += "source: " + String(String.UnicodeScalarView(a.source.tokens.compactMap { Unicode.Scalar($0.letter) })) + "\n"
    let toks = a.source.tokens
    guard let t = toks.firstIndex(where: { column >= $0.col && column < $0.end }) ?? toks.firstIndex(where: { $0.col >= column }) else { return out }
    for i in max(0, t - 12)..<min(toks.count, t + 12) {
      let j = a.match[i]
      let s = Unicode.Scalar(toks[i].letter).map { String($0) } ?? "?"
      let g = j >= 0 ? (Unicode.Scalar(a.page[j].u).map { String($0) } ?? "?") + " p\(a.page[j].page + 1)g\(a.page[j].glyph)" : "-"
      out += "\(i == t ? ">" : " ") \(toks[i].col) '\(s)' → \(g)\(j >= 0 && !a.same[i] ? " ≠" : "")\n"
    }
    return out
  }
}
