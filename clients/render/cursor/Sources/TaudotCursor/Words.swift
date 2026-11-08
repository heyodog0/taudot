import CoreGraphics

extension PageGlyphs {
  /// A word on the page: the text of a run of letters and digits, and its box (points from the page's top-left).
  public struct Word: Sendable, Equatable {
    public var raw: String
    public var rect: CGRect
    /// the glyphs it's made of: first index into `glyphs`, and how many
    public var glyphs: Range<Int>
  }

  /// The page's words, in reading order, the drop-in for reading them off a render with OCR. A typeset word (glyphs
  /// with no gap between them) is split into its runs of letters and digits, an apostrophe inside a run staying in
  /// it ("WordsPlay-generated" → "WordsPlay", "generated"; "game’s" stays whole). A word that ends its typeset line
  /// with a hyphen keeps the hyphen on its last run ("trans-": a word broken across lines).
  ///
  /// `region`: only words whose box's centre is inside it. `clipped`: include text drawn inside clipped content
  /// (included figures, mostly).
  public func words(in region: CGRect? = nil, clipped: Bool = true) -> [Word] {
    var out: [Word] = []
    var i = 0
    while i < glyphs.count {
      var j = i
      while j < glyphs.count && glyphs[j].w == glyphs[i].w { j += 1 }
      defer { i = j }
      if !clipped && glyphs[i].c > 0 { continue }
      let lastOfLine = j == glyphs.count || glyphs[j].l != glyphs[i].l
      let hyphen = lastOfLine && ["-", "\u{2010}"].contains(glyphs[j - 1].t)
      // runs over characters, each tied to its glyph (a ligature glyph gives several characters)
      var runText = "", runStart = -1, runEnd = -1
      var runs: [(String, Int, Int)] = []
      func close() {
        if runStart >= 0 {
          // a trailing apostrophe isn't part of the word
          while let l = runText.last, l == "'" || l == "\u{2019}" { runText.removeLast() }
          if !runText.isEmpty { runs.append((runText, runStart, runEnd)) }
        }
        runText = ""; runStart = -1
      }
      for g in i..<j {
        for ch in glyphs[g].t {
          let wordy = ch.isLetter || ch.isNumber || ((ch == "'" || ch == "\u{2019}") && runStart >= 0)
          if wordy {
            if runStart < 0 { runStart = g }
            runText.append(ch)
            runEnd = g + 1
          } else { close() }
        }
      }
      close()
      for (k, r) in runs.enumerated() {
        var rect = CGRect.null
        for g in r.1..<r.2 { rect = rect.union(glyphs[g].box) }
        if let region, !region.contains(CGPoint(x: rect.midX, y: rect.midY)) { continue }
        out.append(Word(raw: hyphen && k == runs.count - 1 ? r.0 + "-" : r.0, rect: rect, glyphs: r.1..<r.2))
      }
    }
    return out
  }
}
