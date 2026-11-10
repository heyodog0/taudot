// The Metal editor's layout: one Core Text line per paragraph (a source line), wrapped into visual lines of one
// height by our own breaking (after whitespace, else anywhere), cached per paragraph. An edit re-lays out only the
// paragraphs it touches; the rest only shift. Positions are UTF-16 offsets into the text view's storage, geometry in
// points of the document (origin top left, the text container's inset and padding included).
import AppKit
import CoreText

@MainActor final class TextLayout {
  /// One paragraph's layout (its text without the newline).
  final class Para {
    var len = 0
    /// Laid out (glyphs and caret offsets); else only `estimate` lines.
    var laid = false
    /// Caret x before each UTF-16 offset 0...len, points from the paragraph's left.
    var xs: [Float] = []
    /// Glyphs in visual order: id, x (points), UTF-16 offset, font (index into `fonts`).
    var glyphs: [CGGlyph] = []
    var gx: [Float] = []
    var gi: [Int32] = []
    var gf: [UInt16] = []
    /// Offset where each visual line starts (the first is 0).
    var breaks: [Int32] = [0]
    /// The width `breaks` were made for.
    var width: Float = -1
    var lines: Int { breaks.count }
  }

  private(set) var starts: [Int] = [0]
  private(set) var paras: [Para] = [Para()]
  /// Visual lines before each paragraph (count + 1 entries), valid up to and including `cum[cumValid]`.
  private var cum: [Int] = [0, 1]
  private var cumValid = 0
  /// Fonts the glyphs use (the base font first; Core Text's fallbacks after).
  private(set) var fonts: [CTFont] = []
  /// Bumped when the fonts start over (setFont): glyph runs shaped outside the layout (line notes) are stale.
  private(set) var fontGeneration = 0
  private var fontKeys: [String: UInt16] = [:]

  var font: NSFont
  /// Points per visual line.
  var lineHeight: CGFloat
  /// From a line's top to its baseline. The line spacing is above the glyphs, as TextKit 2 puts it.
  var baseline: CGFloat
  /// The line spacing (points above each line's glyphs; caret and selection start below it).
  var spacing: CGFloat
  /// The text's left edge and the top of the first line, in the document.
  var origin: CGPoint
  /// The wrap width (points).
  var width: CGFloat { didSet { if width != oldValue { invalidateCum(0) } } }
  /// The advance of "M" (estimates before a paragraph is laid out).
  private(set) var charWidth: CGFloat
  private var attrs: [NSAttributedString.Key: Any]

  /// The text (the text view's storage, read only).
  var text: NSString

  init(text: NSString, font: NSFont, lineSpacing: CGFloat, origin: CGPoint, width: CGFloat) {
    self.text = text
    self.font = font
    self.origin = origin
    self.width = width
    spacing = lineSpacing
    lineHeight = ceil(font.ascender - font.descender + font.leading) + lineSpacing
    baseline = lineSpacing + ceil(font.ascender)
    charWidth = ("M" as NSString).size(withAttributes: [.font: font]).width
    attrs = [.font: font, .paragraphStyle: NSParagraphStyle.default, .ligature: 0]
    fonts = [font as CTFont]
    fontKeys[TextLayout.key(font as CTFont)] = 0
    reset()
  }

  static func key(_ f: CTFont) -> String { "\(CTFontCopyPostScriptName(f))@\(CTFontGetSize(f))" }

  /// Forget everything and index the paragraphs of `text` again (a new doc, a new font).
  func reset() {
    var st = [0]
    let n = text.length
    var i = 0
    while i < n {
      let r = text.range(of: "\n", options: .literal, range: NSRange(location: i, length: n - i))
      if r.location == NSNotFound { break }
      st.append(r.location + 1)
      i = r.location + 1
    }
    starts = st
    paras = st.indices.map { k in
      let p = Para()
      p.len = paraEnd(k, n) - st[k]
      return p
    }
    invalidateCum(0)
  }

  func setFont(_ f: NSFont, lineSpacing: CGFloat) {
    fontGeneration += 1
    font = f
    spacing = lineSpacing
    lineHeight = ceil(f.ascender - f.descender + f.leading) + lineSpacing
    baseline = lineSpacing + ceil(f.ascender)
    charWidth = ("M" as NSString).size(withAttributes: [.font: f]).width
    attrs[.font] = f
    fonts = [f as CTFont]
    fontKeys = [TextLayout.key(f as CTFont): 0]
    for p in paras { p.laid = false; p.width = -1; p.breaks = [0] }
    invalidateCum(0)
  }

  /// The index of a font in `fonts` (added when new).
  func fontIndex(_ f: CTFont) -> UInt16 {
    let key = TextLayout.key(f)
    if let i = fontKeys[key] { return i }
    let i = UInt16(fonts.count)
    fonts.append(f)
    fontKeys[key] = i
    return i
  }

  /// Text that isn't the document's (line notes): its glyphs as one line, x from its start.
  struct Shaped { var glyphs: [CGGlyph] = []; var gx: [Float] = []; var gi: [Int32] = []; var gf: [UInt16] = []; var width: Float = 0 }

  func shape(_ s: NSAttributedString) -> Shaped {
    var out = Shaped()
    let line = CTLineCreateWithAttributedString(s)
    for run in CTLineGetGlyphRuns(line) as! [CTRun] {
      let count = CTRunGetGlyphCount(run)
      guard count > 0 else { continue }
      let f = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
      let fi = fontIndex(f)
      var gl = [CGGlyph](repeating: 0, count: count), pos = [CGPoint](repeating: .zero, count: count), idx = [CFIndex](repeating: 0, count: count)
      CTRunGetGlyphs(run, CFRange(location: 0, length: count), &gl)
      CTRunGetPositions(run, CFRange(location: 0, length: count), &pos)
      CTRunGetStringIndices(run, CFRange(location: 0, length: count), &idx)
      for j in 0..<count { out.glyphs.append(gl[j]); out.gx.append(Float(pos[j].x)); out.gi.append(Int32(idx[j])); out.gf.append(fi) }
    }
    out.width = Float(CTLineGetTypographicBounds(line, nil, nil, nil))
    return out
  }

  /// The x (from the text's left edge) where paragraph k's last visual line ends.
  func lineEndX(_ k: Int) -> CGFloat {
    let p = ensure(k)
    guard p.laid, p.len > 0, !p.xs.isEmpty else { return 0 }
    return CGFloat(p.xs[p.len] - p.xs[Int(p.breaks[p.breaks.count - 1])])
  }

  private func paraEnd(_ k: Int, _ n: Int) -> Int { k + 1 < starts.count ? starts[k + 1] - 1 : n }

  // MARK: edits

  /// The storage changed: `range` is the new text's range, `delta` the change in length.
  func edited(_ range: NSRange, delta: Int) {
    let loc = range.location
    let oldEnd = NSMaxRange(range) - delta
    let a = paraIndex(loc)
    var b = a
    while b + 1 < starts.count && starts[b + 1] <= oldEnd { b += 1 }
    var fresh: [Int] = []
    var i = loc
    let end = NSMaxRange(range)
    while i < end {
      let r = text.range(of: "\n", options: .literal, range: NSRange(location: i, length: end - i))
      if r.location == NSNotFound { break }
      fresh.append(r.location + 1)
      i = r.location + 1
    }
    let tail = starts[(b + 1)...].map { $0 + delta }
    starts.replaceSubrange((a + 1)..., with: fresh + tail)
    let made = (0...fresh.count).map { _ in Para() }
    paras.replaceSubrange(a...b, with: made)
    let n = text.length
    for k in a...(a + fresh.count) { paras[k].len = paraEnd(k, n) - starts[k] }
    invalidateCum(a)
  }

  private func invalidateCum(_ from: Int) {
    cumValid = min(cumValid, from)
  }

  // MARK: laying out

  /// Lay out paragraph k (glyphs, caret offsets) if it isn't, and break it for the current width.
  @discardableResult func ensure(_ k: Int) -> Para {
    let p = paras[k]
    guard !p.laid || p.width != Float(width) else { return p }
    let before = p.laid ? p.lines : estimate(k)
    if !p.laid { typeset(k, p) }
    if p.width != Float(width) { breakLines(k, p) }
    // cum[k] still holds (it counts the paragraphs before k); cum[k + 1] on counted this one's old lines. (Keeping
    // cum[k + 1] drew the next paragraph over this one's last lines until something else cleared the cache: the
    // user's "lines overlapped, then fixed themselves".)
    if p.lines != before { invalidateCum(k) }
    return p
  }

  var allLaid: Bool { paras.allSatisfy(\.laid) }

  private func typeset(_ k: Int, _ p: Para) {
    p.laid = true
    p.glyphs = []; p.gx = []; p.gi = []; p.gf = []
    let n = p.len
    p.xs = [Float](repeating: 0, count: n + 1)
    guard n > 0 else { p.width = -1; return }
    let s = text.substring(with: NSRange(location: starts[k], length: n))
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
    let runs = CTLineGetGlyphRuns(line) as! [CTRun]
    for run in runs {
      let count = CTRunGetGlyphCount(run)
      guard count > 0 else { continue }
      let ra = CTRunGetAttributes(run) as NSDictionary
      let f = ra[kCTFontAttributeName] as! CTFont
      let fi = fontIndex(f)
      var gl = [CGGlyph](repeating: 0, count: count)
      var pos = [CGPoint](repeating: .zero, count: count)
      var idx = [CFIndex](repeating: 0, count: count)
      CTRunGetGlyphs(run, CFRange(location: 0, length: count), &gl)
      CTRunGetPositions(run, CFRange(location: 0, length: count), &pos)
      CTRunGetStringIndices(run, CFRange(location: 0, length: count), &idx)
      for j in 0..<count {
        let si = idx[j]
        p.glyphs.append(gl[j]); p.gx.append(Float(pos[j].x)); p.gi.append(Int32(si)); p.gf.append(fi)
      }
    }
    // caret offsets from the glyphs: an offset with a glyph starts at it; one inside a cluster (no glyph of its own)
    // takes the cluster's start; the end is the line's width. (Asking Core Text per offset is quadratic.)
    var have = [Bool](repeating: false, count: n + 1)
    for g in 0..<p.gi.count {
      let i = Int(p.gi[g])
      if i <= n && (!have[i] || p.gx[g] < p.xs[i]) { p.xs[i] = p.gx[g]; have[i] = true }
    }
    p.xs[n] = Float(CTLineGetTypographicBounds(line, nil, nil, nil))
    have[n] = true
    var lastX: Float = 0
    for i in 0...n { if have[i] { lastX = p.xs[i] } else { p.xs[i] = lastX } }
    p.width = -1
  }

  /// Greedy wrapping: as much as fits, back to just after the last space or tab; trailing spaces may hang past the
  /// edge (as NSTextView's word wrapping does).
  private func breakLines(_ k: Int, _ p: Para) {
    p.width = Float(width)
    p.breaks = [0]
    let n = p.len
    guard p.laid, n > 0, width > charWidth else { return }
    let w = Float(width)
    var s = 0
    var buf = [unichar](repeating: 0, count: n)
    text.getCharacters(&buf, range: NSRange(location: starts[k], length: n))
    while true {
      let x0 = p.xs[s]
      // the furthest end e with xs[e] - x0 <= w
      var lo = s + 1, hi = n
      if p.xs[n] - x0 <= w { break }
      while lo < hi {
        let m = (lo + hi + 1) / 2
        if p.xs[m] - x0 <= w { lo = m } else { hi = m - 1 }
      }
      var e = lo
      // spaces hang: past the edge, skip over them
      while e < n && (buf[e] == 32 || buf[e] == 9) { e += 1 }
      if e >= n { break }
      // back to just after a space
      var b = e
      while b > s && !(buf[b - 1] == 32 || buf[b - 1] == 9) { b -= 1 }
      if b > s { e = b }
      // never split a surrogate pair
      if e > s + 1 && e < n && buf[e] >= 0xDC00 && buf[e] <= 0xDFFF { e -= 1 }
      if e <= s { e = s + 1 }
      p.breaks.append(Int32(e))
      s = e
    }
  }

  /// Lines a paragraph not laid out yet is guessed to take.
  private func estimate(_ k: Int) -> Int {
    let p = paras[k]
    if p.laid && p.width == Float(width) { return p.lines }
    if p.laid { breakLines(k, p); return p.lines }
    guard width > charWidth else { return 1 }
    return max(1, Int((CGFloat(p.len) * charWidth / width).rounded(.up)))
  }

  /// Visual lines before paragraph k.
  func linesBefore(_ k: Int) -> Int {
    if cum.count != paras.count + 1 { cum = [Int](repeating: 0, count: paras.count + 1); cumValid = 0 }
    if k > cumValid {
      var c = cum[cumValid]
      for i in cumValid..<k { c += estimate(i); cum[i + 1] = c }
      cumValid = k
    }
    return cum[k]
  }

  /// For checks: the first paragraph whose cached count of lines before it disagrees with the paragraphs' own counts
  /// (laid out ones as broken, the rest as estimated), or nil.
  func staleCum() -> Int? {
    guard cum.count == paras.count + 1 else { return nil }
    var c = cum[0]
    for i in 0..<cumValid {
      let p = paras[i]
      c += p.laid && p.width == Float(width) ? p.lines : (p.laid ? -1_000_000 : estimate(i))
      if cum[i + 1] != c { return i }
    }
    return nil
  }

  var totalLines: Int { linesBefore(paras.count) }
  var height: CGFloat { CGFloat(totalLines) * lineHeight }

  /// The paragraph a visual line belongs to, and the line within it.
  func para(ofVisualLine v: Int) -> (Int, Int) {
    let total = totalLines
    let v = max(0, min(v, total - 1))
    var lo = 0, hi = paras.count - 1
    while lo < hi {
      let m = (lo + hi + 1) / 2
      if linesBefore(m) <= v { lo = m } else { hi = m - 1 }
    }
    return (lo, v - linesBefore(lo))
  }

  /// The paragraph holding a UTF-16 offset.
  func paraIndex(_ loc: Int) -> Int {
    var lo = 0, hi = starts.count - 1
    while lo < hi {
      let m = (lo + hi + 1) / 2
      if starts[m] <= loc { lo = m } else { hi = m - 1 }
    }
    return lo
  }

  // MARK: geometry

  /// (paragraph, visual line in it, x) of an offset; at a wrap point the caret goes to the start of the next line.
  func place(_ loc: Int) -> (k: Int, line: Int, x: CGFloat) {
    let loc = max(0, min(loc, text.length))
    let k = paraIndex(loc)
    let p = ensure(k)
    let off = min(loc - starts[k], p.len)
    var l = 0
    while l + 1 < p.breaks.count && Int(p.breaks[l + 1]) <= off { l += 1 }
    let x = p.laid && !p.xs.isEmpty ? CGFloat(p.xs[off] - p.xs[Int(p.breaks[l])]) : 0
    return (k, l, x)
  }

  /// The caret's rect at an offset (one line tall, zero wide), in the document.
  func caretRect(_ loc: Int) -> CGRect {
    let (k, l, x) = place(loc)
    let y = origin.y + CGFloat(linesBefore(k) + l) * lineHeight
    return CGRect(x: origin.x + x, y: y + spacing, width: 0, height: lineHeight - spacing)
  }

  func y(ofPara k: Int) -> CGFloat { origin.y + CGFloat(linesBefore(k)) * lineHeight }

  /// The offset nearest a point in the document.
  func offset(at pt: CGPoint) -> Int {
    let v = Int(floor((pt.y - origin.y) / lineHeight))
    if v < 0 { return 0 }
    if v >= totalLines { return text.length }
    let (k, l) = para(ofVisualLine: v)
    return offset(para: k, line: l, x: pt.x - origin.x)
  }

  /// The offset in visual line `l` of paragraph `k` nearest `x` (from the text's left edge).
  func offset(para k: Int, line l: Int, x: CGFloat) -> Int {
    let p = ensure(k)
    guard p.laid, p.len > 0 else { return starts[k] }
    let a = Int(p.breaks[min(l, p.breaks.count - 1)])
    let b = l + 1 < p.breaks.count ? Int(p.breaks[l + 1]) : p.len
    let x0 = p.xs[a]
    var best = a, bestD = Float.infinity
    // the last line ends after its last character; a wrapped line ends before the next line's first
    let last = l + 1 < p.breaks.count ? max(a, b - 1) : b
    var i = a
    while i <= last {
      let d = abs(p.xs[i] - x0 - Float(x))
      if d < bestD { bestD = d; best = i }
      i += 1
    }
    var o = best
    // inside a surrogate pair: to its start
    if o > 0 && o < p.len {
      let c = text.character(at: starts[k] + o)
      if c >= 0xDC00 && c <= 0xDFFF { o -= 1 }
    }
    return starts[k] + o
  }

  /// The offset `count` visual lines below (above, when negative) `loc`, at x `goal` (nil: `loc`'s own x).
  func offset(from loc: Int, lines count: Int, goal: CGFloat?) -> (Int, CGFloat) {
    let (k, l, x) = place(loc)
    let gx = goal ?? x
    let v = linesBefore(k) + l + count
    if v < 0 { return (0, gx) }
    if v >= totalLines { return (text.length, gx) }
    let (k2, l2) = para(ofVisualLine: v)
    return (offset(para: k2, line: l2, x: gx), gx)
  }

  /// The visual line's offsets (start, end) holding `loc` (the end before a wrap's next line, or at the newline).
  func visualLine(at loc: Int) -> (Int, Int) {
    let (k, l, _) = place(loc)
    let p = paras[k]
    let a = Int(p.breaks[l]), b = l + 1 < p.breaks.count ? Int(p.breaks[l + 1]) : p.len
    return (starts[k] + a, starts[k] + b)
  }

  /// Rects covering a range, one per visual line, in the document. `extendNewline`: a selected newline adds a space.
  func rects(_ r: NSRange, extendNewline: Bool = false) -> [CGRect] {
    let n = text.length
    let a = max(0, min(r.location, n)), b = max(a, min(NSMaxRange(r), n))
    guard b > a else { return [] }
    var out: [CGRect] = []
    var k = paraIndex(a)
    while k < paras.count && starts[k] <= b {
      let p = ensure(k)
      let ps = starts[k]
      let from = max(a, ps) - ps, to = min(b, ps + p.len) - ps
      let hasNL = k + 1 < paras.count && b > ps + p.len
      let yk = y(ofPara: k)
      for l in 0..<p.breaks.count {
        let la = Int(p.breaks[l]), lb = l + 1 < p.breaks.count ? Int(p.breaks[l + 1]) : p.len
        let s = max(from, la), e = min(to, lb)
        let last = l + 1 == p.breaks.count
        if s > e || (s == e && !(last && hasNL && s == lb)) { continue }
        if s == e && !last { continue }
        let x0 = p.laid && !p.xs.isEmpty ? p.xs[la] : 0
        let sx = p.laid && !p.xs.isEmpty ? CGFloat(p.xs[s] - x0) : 0
        var ex = p.laid && !p.xs.isEmpty ? CGFloat(p.xs[e] - x0) : 0
        if last && hasNL && extendNewline { ex += charWidth * 0.5 }
        if ex <= sx && !(last && hasNL) { continue }
        out.append(CGRect(x: origin.x + sx, y: yk + CGFloat(l) * lineHeight + spacing, width: max(ex - sx, 0), height: lineHeight - spacing))
      }
      k += 1
    }
    return out
  }

  /// Lay out paragraphs from `from` until `budget` seconds pass; returns the next paragraph to do (paras.count: done).
  func layOut(from: Int, budget: Double) -> Int {
    let t0 = CACurrentMediaTime()
    var k = from
    while k < paras.count {
      if !paras[k].laid { ensure(k) }
      k += 1
      if k % 16 == 0 && CACurrentMediaTime() - t0 > budget { break }
    }
    return k
  }
}
