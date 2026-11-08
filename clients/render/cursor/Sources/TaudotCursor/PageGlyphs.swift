import CoreGraphics
import Foundation

/// A page's glyphs, as the `glyphs` verb of txp-render writes them (format: clients/render/glyphs.c). Points from the
/// page's top-left, y down.
public struct PageGlyphs: Decodable, Sendable {
  public struct Glyph: Decodable, Sendable {
    public var t: String
    public var b: [Double]  // advance box x0, y0, x1, y1
    public var i: [Double]  // ink box
    public var o: [Double]  // origin on the baseline
    public var s: Double  // size, points
    public var f: Int  // font index
    public var l: Int  // typeset line
    public var w: Int  // word
    public var c: Int  // clip depth

    public init(t: String, b: [Double], i: [Double]? = nil, o: [Double]? = nil, s: Double = 10, f: Int = 0,
                l: Int, w: Int, c: Int = 0) {
      self.t = t; self.b = b; self.i = i ?? b; self.o = o ?? [b[0], b[3] - 0.25 * s]; self.s = s; self.f = f
      self.l = l; self.w = w; self.c = c
    }

    public var box: CGRect { CGRect(x: b[0], y: b[1], width: b[2] - b[0], height: b[3] - b[1]) }
    public var ink: CGRect { CGRect(x: i[0], y: i[1], width: i[2] - i[0], height: i[3] - i[1]) }
    public var baseline: Double { o[1] }
  }

  public struct Line: Decodable, Sendable {
    public var b: [Double]
    public var base: Double
    public var g: [Int]  // first glyph, count
  }

  public var page: Int
  public var w: Double, h: Double
  public var fonts: [String]
  public var glyphs: [Glyph]
  public var lines: [Line]

  public init(page: Int, w: Double = 612, h: Double = 792, glyphs: [Glyph]) {
    self.page = page; self.w = w; self.h = h; fonts = ["test"]; self.glyphs = glyphs
    var lines: [Line] = []
    var i = 0
    while i < glyphs.count {
      var j = i, r = glyphs[i].b
      while j < glyphs.count && glyphs[j].l == glyphs[i].l {
        let b = glyphs[j].b
        r = [min(r[0], b[0]), min(r[1], b[1]), max(r[2], b[2]), max(r[3], b[3])]
        j += 1
      }
      lines.append(Line(b: r, base: glyphs[i].baseline, g: [i, j - i]))
      i = j
    }
    self.lines = lines
  }

  init(page: Int, w: Double, h: Double, fonts: [String], glyphs: [Glyph], lines: [Line]) {
    self.page = page; self.w = w; self.h = h; self.fonts = fonts; self.glyphs = glyphs; self.lines = lines
  }

  public static func load(_ url: URL) throws -> PageGlyphs { try read(Data(contentsOf: url)) }

  /// Reads a `glyphs` file (~1 ms for 3,000 glyphs).
  public static func read(_ data: Data) throws -> PageGlyphs { try GlyphReader.read(data) }
}
