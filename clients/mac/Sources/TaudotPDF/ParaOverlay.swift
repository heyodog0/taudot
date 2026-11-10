// The paragraph preview (docs/live-protocol.md, `para`): the driver typesets only the paragraph being edited, from a
// process parked at its start, and hands over its new lines as a display list placed over the old lines of the page on
// screen. The pane paints them there within a frame, until a PDF with the edit (the exact pass) replaces the page.
//
// This file reads the list (TDL, clients/render/dlist.md: the PAGE, FONT outlines, TEXT and RULE records the driver
// writes) and draws it the way LiveDraw draws tiles, so an exact preview has the exact page's pixels. Logic stays in
// the driver (C); here it is only drawn.
import CoreGraphics
import CoreText
import Foundation

public struct ParaOverlay: @unchecked Sendable {
  /// The driver's go number, and the edits (`applied`) it shows: a PDF with at least these replaces it.
  public let go: Int
  public let applied: Int
  /// The driver's time from reading the edit to sending this (µs).
  public let driverUs: Int
  public let page: Int
  /// "exact": same lines and heights, nothing that moves other things (the page around it is unchanged);
  /// "provisional": shown, but the exact pass may move what follows (`why` says what differs).
  public let state: String
  public let why: String?
  /// Page points, y down: the old lines and the new ones; painted paper before the new lines go on.
  public let erase: [CGRect]
  /// Glyphs, one path per run (page points, y down), and rules.
  let runs: [(path: CGPath, color: CGColor)]
  /// Runs in sfnt fonts (XeTeX's OpenType files), drawn as text by Core Graphics (as the exact page's PDF text is),
  /// not as filled outlines: the same rasterizer, the same weight.
  let texts: [GlyphRun]
  let rules: [(rect: CGRect, color: CGColor)]
  /// Each run's ink box (page points): paper goes under it too (microtype protrudes punctuation past the box).
  let inks: [CGRect]
  /// The same lines as a one-page PDF with the fonts' programs (`overlay`), its top-left at `origin` on the page:
  /// drawn by Core Graphics as the exact page is, so an exact preview has its pixels. The display list is the fallback.
  let pdf: CGPDFPage?
  let origin: CGPoint

  public var exact: Bool { state == "exact" }
  /// Everything it paints, page points.
  public var bounds: CGRect {
    let all = erase + rules.map(\.rect) + inks
    return all.dropFirst().reduce(all.first ?? .null) { $0.union($1) }
  }

  /// From a `para` event with a display list; nil for `none` or a list that can't be read.
  public init?(event m: [String: Any]) {
    guard let state = m["state"] as? String, state != "none", let path = m["path"] as? String,
      let data = FileManager.default.contents(atPath: path), let page = m["page"] as? Int
    else { return nil }
    self.go = m["go"] as? Int ?? 0
    self.applied = m["applied"] as? Int ?? 0
    self.driverUs = m["us"] as? Int ?? -1
    self.page = page
    self.state = state
    self.why = m["why"] as? String
    self.erase = (m["erase"] as? [[Double]] ?? []).compactMap { r in
      r.count == 4 ? CGRect(x: r[0], y: r[1], width: r[2] - r[0], height: r[3] - r[1]) : nil
    }
    // with the PDF, the list's outlines aren't needed: only the runs' ink boxes (reading the paths costs ~1 ms)
    let withPDF = m["overlay"] is String && m["origin"] != nil
    guard let list = ParaOverlay.read(data, outlines: !withPDF) else { return nil }
    self.runs = list.runs
    self.texts = list.texts
    self.rules = list.rules
    self.inks = list.inks
    let o = m["origin"] as? [Double] ?? []
    origin = o.count == 2 ? CGPoint(x: o[0], y: o[1]) : .zero
    if o.count == 2, let p = m["overlay"] as? String, let d = FileManager.default.contents(atPath: p),
      let prov = CGDataProvider(data: d as CFData), let doc = CGPDFDocument(prov), let pg = doc.page(at: 1) {
      pdf = pg
    } else {
      pdf = nil
    }
  }

  /// Draw into a bitmap whose pixel (0, 0) is page pixel (x0, y0) at `scale` pixels a point (rows from the top, as
  /// LiveDraw's tiles): paper over `erase`, then the lines. `ctx` is y up, `h` pixels tall.
  public func draw(in ctx: CGContext, scale: Double, x0: Int, y0: Int, h: Int) {
    ctx.saveGState()
    defer { ctx.restoreGState() }
    // page (y down) → pixels (y up)
    ctx.concatenate(CGAffineTransform(a: scale, b: 0, c: 0, d: -scale, tx: Double(-x0), ty: Double(h + y0)))
    // paper over the old lines, out to whole pixels and not antialiased: an edge pixel half covered would keep half of
    // the old glyph under the new one
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.setShouldAntialias(false)
    // and under the new glyphs' ink (microtype protrudes punctuation past the line's box)
    for r in erase + inks where !r.isNull {
      let x0 = (r.minX * scale).rounded(.down) / scale, x1 = (r.maxX * scale).rounded(.up) / scale
      let y0 = (r.minY * scale).rounded(.down) / scale, y1 = (r.maxY * scale).rounded(.up) / scale
      ctx.fill(CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
    }
    ctx.setShouldAntialias(true)
    for r in rules {
      ctx.setFillColor(r.color)
      ctx.fill(r.rect)
    }
    if let pdf {
      let H = pdf.getBoxRect(.mediaBox).height
      ctx.concatenate(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: origin.x, ty: origin.y + H))
      ctx.interpolationQuality = .high
      ctx.setShouldSubpixelPositionFonts(true)
      ctx.drawPDFPage(pdf)
      return
    }
    ctx.setShouldAntialias(true)
    for r in runs {
      ctx.addPath(r.path)
      ctx.setFillColor(r.color)
      ctx.fillPath(using: .winding)
    }
    ctx.setShouldSubpixelPositionFonts(true)
    ctx.textMatrix = .identity
    for t in texts {
      ctx.setFillColor(t.color)
      for (g, p) in zip(t.glyphs, t.positions) {
        ctx.saveGState()
        ctx.concatenate(t.m.concatenating(CGAffineTransform(translationX: p.x, y: p.y)))
        var gl = g, at = CGPoint.zero
        CTFontDrawGlyphs(t.font, &gl, &at, 1, ctx)
        ctx.restoreGState()
      }
    }
  }

  // ---- TDL (the subset the driver writes)

  struct Reader {
    let d: Data
    var i: Int
    mutating func u8() -> UInt8? { guard i < d.count else { return nil }; defer { i += 1 }; return d[d.startIndex + i] }
    mutating func u16() -> Int? { guard i + 2 <= d.count else { return nil }; defer { i += 2 }; return Int(load(UInt16.self)) }
    mutating func u32() -> Int? { guard i + 4 <= d.count else { return nil }; defer { i += 4 }; return Int(load(UInt32.self)) }
    mutating func f32() -> Double? { guard i + 4 <= d.count else { return nil }; defer { i += 4 }; return Double(Float(bitPattern: load(UInt32.self))) }
    func load<T: FixedWidthInteger>(_: T.Type) -> T {
      d.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: i, as: T.self)) }
    }
    mutating func skip(_ n: Int) -> Bool { guard n >= 0, i + n <= d.count else { return false }; i += n; return true }
    mutating func f32s(_ n: Int) -> [Double]? {
      var out: [Double] = []
      out.reserveCapacity(n)
      for _ in 0..<n { guard let v = f32() else { return nil }; out.append(v) }
      return out
    }
  }

  static func read(_ data: Data, outlines: Bool = true)
    -> (runs: [(path: CGPath, color: CGColor)], texts: [GlyphRun], rules: [(rect: CGRect, color: CGColor)], inks: [CGRect])?
  {
    var r = Reader(d: data, i: 0)
    guard data.count >= 8, data.prefix(4) == Data("TDL\0".utf8), r.skip(4), let ver = r.u32(), ver <= 2 else { return nil }
    var glyphs: [Int: [Int: CGPath]] = [:]  // font → gid → outline (em, y up)
    var sfnts: [Int: CTFont?] = [:]  // font → the file's face at 1 pt (its glyph paths are in em units, y up)
    var runs: [(path: CGPath, color: CGColor)] = []
    var texts: [GlyphRun] = []
    var rules: [(rect: CGRect, color: CGColor)] = []
    var inks: [CGRect] = []
    while let kind = r.u8(), let len = r.u32() {
      let end = r.i + len
      guard end <= data.count else { return nil }
      switch kind {
      case 0x00: return (runs, texts, rules, inks)
      case 0x02:  // FONT: id, type, name, then for outlines: n × (gid, path)
        guard let id = r.u32(), let type = r.u8(), let nl = r.u16(), r.skip(nl) else { return nil }
        if type == 2 && outlines {
          guard let n = r.u32() else { return nil }
          var g: [Int: CGPath] = [:]
          for _ in 0..<n {
            guard let gid = r.u32(), let p = path(&r) else { return nil }
            g[gid] = p
          }
          glyphs[id] = g
        } else if type == 1 && outlines {  // sfnt: an OpenType/TrueType file Core Text loads (XeTeX's fonts)
          guard let pl = r.u16(), r.i + pl <= data.count else { return nil }
          let p = String(decoding: data.subdata(in: data.startIndex + r.i ..< data.startIndex + r.i + pl), as: UTF8.self)
          r.i += pl
          guard let index = r.u32() else { return nil }
          sfnts[id] = SfntCache.shared.font(path: p, index: index)
        }
      case 0x10:  // TEXT
        guard let bb = r.f32s(4), let mode = r.u8(), let c = r.f32s(4) else { return nil }
        if mode == 1 || mode == 2 { return nil }  // stroked text: the driver doesn't write it
        inks.append(CGRect(x: bb[0], y: bb[1], width: bb[2] - bb[0], height: bb[3] - bb[1]))
        if !outlines { break }
        guard let font = r.u32(), let m = r.f32s(4), let n = r.u32() else { return nil }
        let out = CGMutablePath()
        let color = CGColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: c[3])
        let mt = CGAffineTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: 0, ty: 0)
        var gs: [CGGlyph] = [], ps: [CGPoint] = []
        for _ in 0..<n {
          guard let gid = r.u32(), let x = r.f32(), let y = r.f32(), r.skip(4), let tl = r.u16(), r.skip(tl) else { return nil }
          if sfnts[font] != nil { gs.append(CGGlyph(gid)); ps.append(CGPoint(x: x, y: y)); continue }
          guard let g = glyphs[font]?[gid] else { continue }
          out.addPath(g, transform: CGAffineTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: x, ty: y))
        }
        if mode == 0, let f = sfnts[font] ?? nil { texts.append(GlyphRun(font: f, glyphs: gs, positions: ps, m: mt, color: color)) }
        else if mode == 0 { runs.append((out, color)) }
      case 0x13:  // RULE: bbox, rgba
        guard let b = r.f32s(4), let c = r.f32s(4) else { return nil }
        rules.append((CGRect(x: b[0], y: b[1], width: b[2] - b[0], height: b[3] - b[1]),
                      CGColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: c[3])))
      default: break
      }
      r.i = end
    }
    return nil  // no END
  }

  static func path(_ r: inout Reader) -> CGPath? {
    guard let nc = r.u32(), let nco = r.u32(), r.i + nc <= r.d.count else { return nil }
    let cmds = r.d.subdata(in: r.d.startIndex + r.i ..< r.d.startIndex + r.i + nc)
    r.i += nc
    guard let co = r.f32s(nco) else { return nil }
    let p = CGMutablePath()
    var k = 0
    for c in cmds {
      switch c {
      case UInt8(ascii: "M"): guard k + 2 <= co.count else { return nil }; p.move(to: CGPoint(x: co[k], y: co[k + 1])); k += 2
      case UInt8(ascii: "L"): guard k + 2 <= co.count else { return nil }; p.addLine(to: CGPoint(x: co[k], y: co[k + 1])); k += 2
      case UInt8(ascii: "Q"):
        guard k + 4 <= co.count else { return nil }
        p.addQuadCurve(to: CGPoint(x: co[k + 2], y: co[k + 3]), control: CGPoint(x: co[k], y: co[k + 1])); k += 4
      case UInt8(ascii: "C"):
        guard k + 6 <= co.count else { return nil }
        p.addCurve(to: CGPoint(x: co[k + 4], y: co[k + 5]), control1: CGPoint(x: co[k], y: co[k + 1]),
                   control2: CGPoint(x: co[k + 2], y: co[k + 3])); k += 6
      case UInt8(ascii: "Z"): p.closeSubpath()
      default: return nil
      }
    }
    return p
  }
}


/// sfnt fonts of display lists (TDL FONT type 1), loaded once per file and face, and their glyph outlines: XeTeX's
/// previews name the same few fonts every key.
final class SfntCache: @unchecked Sendable {
  static let shared = SfntCache()
  private let lock = NSLock()
  private var fonts: [String: CTFont?] = [:]

  func font(path: String, index: Int) -> CTFont? {
    let key = "\(index):\(path)"
    lock.lock()
    if let f = fonts[key] { lock.unlock(); return f }
    lock.unlock()
    var f: CTFont?
    if let ds = CTFontManagerCreateFontDescriptorsFromURL(URL(fileURLWithPath: path) as CFURL) as? [CTFontDescriptor],
      index < ds.count {
      f = CTFontCreateWithFontDescriptor(ds[index], 1, nil)
    }
    lock.lock()
    fonts[key] = f
    lock.unlock()
    return f
  }
}

/// A TEXT run in an sfnt font: glyph ids, their origins (page points, y down) and the em → page matrix.
struct GlyphRun: @unchecked Sendable {
  let font: CTFont
  let glyphs: [CGGlyph]
  let positions: [CGPoint]
  let m: CGAffineTransform
  let color: CGColor
}
