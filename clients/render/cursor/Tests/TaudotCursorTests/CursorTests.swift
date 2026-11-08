import XCTest
@testable import TaudotCursor

/// A fake typeset page: words laid out left to right, 5 pt a letter, lines 12 pt apart, one glyph per letter unless
/// a glyph is written as "[fi]" (a ligature) or "[´]" (a spacing accent drawn before its letter).
struct FakePage {
  var glyphs: [PageGlyphs.Glyph] = []
  var word = 0

  mutating func line(_ l: Int, _ words: [String], x0: Double = 100) {
    var x = x0
    let base = 100 + Double(l) * 12
    for w in words {
      var i = w.startIndex
      while i < w.endIndex {
        var t = String(w[i])
        if w[i] == "[" , let e = w[i...].firstIndex(of: "]") {
          t = String(w[w.index(after: i)..<e])
          i = e
        }
        i = w.index(after: i)
        let width = 5.0 * Double(max(t.count, 1))
        glyphs.append(PageGlyphs.Glyph(t: t, b: [x, base - 7.5, x + width, base + 2.5], o: [x, base], s: 10, l: l,
                                       w: word))
        x += width
      }
      word += 1
      x += 3
    }
  }

  /// SyncTeX text with one glue record per (line of source, typeset line, x)
  static func synctex(_ recs: [(src: Int, row: Int, x: Double)]) -> SyncTeX {
    let k = 65536 * 72.27 / 72
    var s = "SyncTeX Version:1\nInput:1:main.tex\nOutput:pdf\nMagnification:1000\nUnit:1\nX Offset:0\nY Offset:0\nContent:\n{1\n"
    for r in recs { s += "g1,\(r.src):\(Int(r.x * k)),\(Int((100 + Double(r.row) * 12) * k))\n" }
    s += "}1\nPostamble:\n"
    return SyncTeX(text: s)
  }
}

final class SourceLineTests: XCTestCase {
  func letters(_ s: String) -> String {
    String(String.UnicodeScalarView(SourceLine(s).tokens.compactMap { Unicode.Scalar($0.letter) }))
  }

  func testReading() {
    XCTAssertEqual(letters(#"A caf\'e, \emph{bold} move"#), "a cafe, bold move")
    XCTAssertEqual(letters(#"as shown \citep{x2020} and in Fig.~\ref{fig:a}."#), "as shown and in fig. .")
    XCTAssertEqual(letters("one -- two --- ``three'' it's"), "one – two — “three” it’s")
    XCTAssertEqual(letters("text % a comment"), "text ")
    XCTAssertEqual(letters(#"let $\alpha_i = x^2$ be"#), "let αi=x2 be")
    XCTAssertEqual(letters(#"\lstinputlisting[caption=x]{f.txt}"#), "f.txt")
    XCTAssertEqual(letters(#"\item[(a)] first"#), "(a) first")
    XCTAssertEqual(letters(#"na\"{\i}ve \c{c}a"#), "naive ca")
  }

  func testClasses() {
    let s = SourceLine(#"See \cite{k} $x$ % c"#)
    XCTAssertEqual(s.classes[0], .text)
    XCTAssertEqual(s.classes[5], .command)  // inside \cite
    XCTAssertEqual(s.classes[14], .math)  // x
    XCTAssertEqual(s.classes[18], .comment)
  }

  func testUTF16Column() {
    let s = SourceLine("é x")  // é is 2 bytes, 1 UTF-16 unit
    XCTAssertEqual(s.utf8Column(utf16: 2), 3)
  }
}

final class AlignTests: XCTestCase {
  func u(_ s: String) -> [UInt32] { s.unicodeScalars.map(\.value) }

  func testFreeEndsAndGap() {
    // the source's words sit in the middle of the page's, split by a long run of other text
    let r = Align.run(u("hello world"), u("xx hello  a long float caption here  world yy"))
    XCTAssertTrue(r.same.allSatisfy { $0 }, "\(r)")
    XCTAssertEqual(r.match.first, 3)
  }
}

final class CursorMapTests: XCTestCase {
  func map(_ page: FakePage, _ sync: SyncTeX) -> CursorMap {
    let pg = PageGlyphs(page: 0, glyphs: page.glyphs)
    return CursorMap(synctex: sync) { $0 == 0 ? pg : nil }
  }

  func testLetterInWordAndLigature() {
    var p = FakePage()
    p.line(0, ["The", "[fi]ne", "print."])
    let m = map(p, FakePage.synctex([(1, 0, 120)]))
    let text = "The fine print."
    // the cursor on "i" of "fine": letter 1 of the "fi" glyph, its right half
    let c = m.caret(file: "main.tex", line: 1, text: text, column: 5)!
    XCTAssertEqual(c.glyph, 3)
    XCTAssertEqual(c.letterInGlyph, 1)
    XCTAssertEqual(c.x, p.glyphs[3].b[0] + 5, accuracy: 0.01)
    XCTAssertFalse(c.approximate)
    // on the space after "The": after the "e"
    let s = m.caret(file: "main.tex", line: 1, text: text, column: 3)!
    XCTAssertTrue(s.after)
    XCTAssertEqual(s.x, p.glyphs[2].b[2], accuracy: 0.01)
    // past the end of the line: after the final "."
    let e = m.caret(file: "main.tex", line: 1, text: text, column: text.utf8.count)!
    XCTAssertEqual(e.glyph, p.glyphs.count - 1)
    XCTAssertTrue(e.after)
  }

  func testHyphenatedWordAcrossLines() {
    var p = FakePage()
    p.line(0, ["by", "trans-"])
    p.line(1, ["planting", "it"])
    let m = map(p, FakePage.synctex([(1, 0, 110), (1, 1, 150)]))
    let text = "by transplanting it"
    // "p" of "planting" is on the second line
    let c = m.caret(file: "main.tex", line: 1, text: text, column: 8)!
    XCTAssertEqual(p.glyphs[c.glyph].t, "p")
    XCTAssertEqual(p.glyphs[c.glyph].l, 1)
    // "s" is on the first
    let s = m.caret(file: "main.tex", line: 1, text: text, column: 7)!
    XCTAssertEqual(p.glyphs[s.glyph].t, "s")
    XCTAssertEqual(p.glyphs[s.glyph].l, 0)
  }

  func testAccentAndMacro() {
    var p = FakePage()
    p.line(0, ["a", "[´]cafe", "bold", "x"])  // OT1: the accent drawn as its own glyph
    let m = map(p, FakePage.synctex([(1, 0, 110)]))
    let text = #"a caf\'e \textbf{bold} x"#
    // the cursor on \'e: the "e"
    let c = m.caret(file: "main.tex", line: 1, text: text, column: 5)!
    XCTAssertEqual(p.glyphs[c.glyph].t, "e")
    XCTAssertFalse(c.approximate)
    // in "\textbf": approximate, on a neighbouring letter
    let t = m.caret(file: "main.tex", line: 1, text: text, column: 12)!
    XCTAssertTrue(t.approximate)
    // "o" of bold, inside the macro's argument: exact
    let o = m.caret(file: "main.tex", line: 1, text: text, column: 18)!
    XCTAssertEqual(p.glyphs[o.glyph].t, "o")
    XCTAssertFalse(o.approximate)
  }

  func testCommentMathAndSilentLines() {
    var p = FakePage()
    p.line(0, ["see", "α", "=", "1", "here"])
    let m = map(p, FakePage.synctex([(1, 0, 110)]))
    let text = #"see $\alpha = 1$ here % note"#
    // in \alpha: the α glyph, exact
    let a = m.caret(file: "main.tex", line: 1, text: text, column: 6)!
    XCTAssertEqual(p.glyphs[a.glyph].t, "α")
    // the comment: after the last typeset letter before it, approximate
    let c = m.caret(file: "main.tex", line: 1, text: text, column: 25)!
    XCTAssertTrue(c.approximate)
    XCTAssertEqual(p.glyphs[c.glyph].t, "e")
    XCTAssertTrue(c.after)
    // a line with no record typesets nothing: no dot
    XCTAssertNil(m.caret(file: "main.tex", line: 2, text: "% only a comment", column: 3))
  }

  func testRoundTrip() {
    var p = FakePage()
    p.line(0, ["first", "line", "of", "text"])
    p.line(1, ["second", "line", "here"])
    let m = map(p, FakePage.synctex([(1, 0, 110), (2, 1, 110)]))
    let lines = ["first line of text", "second line here"]
    for (l, t) in lines.enumerated() {
      for col in 0..<t.utf8.count where t.utf8[t.utf8.index(t.utf8.startIndex, offsetBy: col)] != 32 {
        let c = m.caret(file: "main.tex", line: l + 1, text: t, column: col)!
        let s = m.source(page: 0, glyph: c.glyph, letter: c.letterInGlyph) { _, n in n >= 1 && n <= lines.count ? lines[n - 1] : nil }
        XCTAssertEqual(s, SourcePosition(file: "main.tex", line: l + 1, column: col, approximate: false), "\(l + 1):\(col)")
      }
    }
    // by point: the middle of "second"'s "c"
    let g = p.glyphs.firstIndex { $0.l == 1 && $0.t == "c" }!
    let s = m.source(page: 0, x: p.glyphs[g].b[0] + 2, y: 112) { _, n in n >= 1 && n <= lines.count ? lines[n - 1] : nil }
    XCTAssertEqual(s?.line, 2)
    XCTAssertEqual(s?.column, 2)
  }
}

final class UpdateTests: XCTestCase {
  func testChangedPageIsReadAgain() {
    var a = FakePage()
    a.line(0, ["old", "words"])
    var b = FakePage()
    b.line(0, ["new", "words", "here"])
    var current = PageGlyphs(page: 0, glyphs: a.glyphs)
    var reads = 0
    let m = CursorMap(synctex: FakePage.synctex([(1, 0, 110)])) { _ in reads += 1; return current }
    XCTAssertEqual(m.caret(file: "main.tex", line: 1, text: "old words", column: 4)?.glyph, 3)
    current = PageGlyphs(page: 0, glyphs: b.glyphs)
    // unchanged page: still the old glyphs; the edited text is aligned again against them
    _ = m.caret(file: "main.tex", line: 1, text: "new words here", column: 10)
    XCTAssertEqual(reads, 1)
    m.update(synctex: FakePage.synctex([(1, 0, 110)]), changed: [0])
    let c = m.caret(file: "main.tex", line: 1, text: "new words here", column: 10)!
    XCTAssertEqual(reads, 2)
    XCTAssertEqual(b.glyphs[c.glyph].t, "h")
  }
}

final class GlyphReaderTests: XCTestCase {
  func testSameAsJSONDecoder() throws {
    let json = #"""
      {"page":2,"w":612.000,"h":792.000,"fonts":["Nimbus \"Roman\"","X"],
      "glyphs":[
      {"t":"fi","b":[1.00,2.50,3.00,-4.25],"i":[1,2,3,4],"o":[1.00,2.00],"s":9.96,"f":0,"l":0,"w":0,"c":0},
      {"t":"’","b":[5,6,7,8],"i":[5,6,7,8],"o":[5,7.5],"s":1e1,"f":1,"l":1,"w":1,"c":2}],
      "lines":[
      {"b":[1,2,3,4],"base":2.00,"g":[0,1]},
      {"b":[5,6,7,8],"base":7.5,"g":[1,1]}],
      "words":[{"t":"fi","b":[1,2,3,4],"l":0,"g":[0,1]}]}
      """#
    let fast = try PageGlyphs.read(Data(json.utf8))
    let slow = try JSONDecoder().decode(PageGlyphs.self, from: Data(json.utf8))
    XCTAssertEqual(fast.fonts, slow.fonts)
    XCTAssertEqual(fast.glyphs.map(\.t), ["fi", "’"])
    XCTAssertEqual(fast.glyphs.map(\.b), slow.glyphs.map(\.b))
    XCTAssertEqual(fast.glyphs.map(\.s), slow.glyphs.map(\.s))
    XCTAssertEqual(fast.glyphs.map(\.c), [0, 2])
    XCTAssertEqual(fast.lines.map(\.g), slow.lines.map(\.g))
    XCTAssertEqual(fast.lines.map(\.base), slow.lines.map(\.base))
    XCTAssertThrowsError(try PageGlyphs.read(Data("{\"glyphs\":[{\"b\":[1,2]}]}".utf8)))
  }
}

final class WordsTests: XCTestCase {
  func testRunsHyphensAndRegion() {
    var p = FakePage()
    p.line(0, ["WordsPlay-generated", "game’s", "(see", "[fi]le).", "trans-"])
    p.line(1, ["planting", "x"])
    let pg = PageGlyphs(page: 0, glyphs: p.glyphs)
    let w = pg.words()
    XCTAssertEqual(w.map(\.raw), ["WordsPlay", "generated", "game’s", "see", "file", "trans-", "planting", "x"])
    // boxes: the union of the glyphs' advance boxes
    let first = p.glyphs[0].box.union(p.glyphs[8].box)
    XCTAssertEqual(w[0].rect, first)
    XCTAssertEqual(w[0].glyphs, 0..<9)
    // the ligature is one glyph inside "file"
    XCTAssertEqual(w[4].glyphs.count, 3)
    // a region holding only the second line
    XCTAssertEqual(pg.words(in: CGRect(x: 0, y: 105, width: 600, height: 12)).map(\.raw), ["planting", "x"])
  }
}
