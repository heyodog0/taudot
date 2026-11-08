// A cache of glyph coverage masks for outline fonts: each glyph is filled once per device size and subpixel phase,
// then composited. Filling the outline on every use costs ~4 µs a glyph; glyphs repeat.
//
// Two ways to composite:
//  - direct: the target is an RGBA8 bitmap we can address, with no clip, transparency layer or blend active: the mask
//    is blended straight into its memory (colour × coverage over the destination), as a rasteriser's glyph cache does.
//  - otherwise: a colour image of the glyph, made once per colour, drawn with CGContextDrawImage (respects clips).
//
// Phase: the glyph's device origin is rounded to the steps in `steps` (the oracle's own positions, so caching costs no
// fidelity). TAUDOT_GLYPH_Q=n forces n×n steps, for experiments.
import CoreGraphics
import Foundation

final class GlyphCache {
  static let shared = GlyphCache()
  /// TAUDOT_GLYPH_CACHE=0 turns the cache off (every glyph filled from its outline)
  static let on = ProcessInfo.processInfo.environment["TAUDOT_GLYPH_CACHE"] != "0"
  static let direct = ProcessInfo.processInfo.environment["TAUDOT_GLYPH_DIRECT"] != "0"

  struct Key: Hashable {
    var outline: Int     // identity of the outline (hash of its commands)
    var a, b, c, d: Int32  // device linear matrix, in 1/1024
    var fx, fy: Int8     // phase, with the step count in the high bits
  }
  final class Entry {
    let mask: [UInt8]    // coverage, w × h, top row first
    let w, h, dx, dy: Int  // the mask's lower-left corner relative to the origin pixel (device, y up)
    var images: [UInt32: CGImage] = [:]
    init(mask: [UInt8], w: Int, h: Int, dx: Int, dy: Int) { self.mask = mask; self.w = w; self.h = h; self.dx = dx; self.dy = dy }
  }

  private var map: [Key: Entry] = [:]
  static let gray = CGColorSpaceCreateDeviceGray()
  let limit = 20000

  /// Subpixel steps per pixel (x, y) for a glyph drawn with device matrix `m`. Matches how the oracle (MuPDF)
  /// positions cached glyphs, as its documentation describes: the smaller the glyph, the finer the steps; upright
  /// text gets whole-pixel y. Learnt from its description and measured, not copied.
  static let forcedQ = Int(ProcessInfo.processInfo.environment["TAUDOT_GLYPH_Q"] ?? "") ?? 0
  static func steps(_ m: CGAffineTransform) -> (Int, Int)? {
    if forcedQ > 0 { return (forcedQ, forcedQ) }
    let size = (abs(m.a * m.d - m.b * m.c)).squareRoot()
    if size > 256 { return nil }
    // only upright glyphs: rotated or skewed ones land closer to the oracle filled from the outline, unsnapped
    // (measured on 1706.03762 p12–14's vertical labels)
    if forcedQ == 0, !(abs(m.b) < 1e-6 * max(1, size) && abs(m.c) < 1e-6 * max(1, size)) { return nil }
    var h = size >= 48 ? 1 : size >= 24 ? 2 : 4
    var v = size >= 8 ? 1 : size >= 4 ? 2 : 4
    let z: CGFloat = 1e-6 * max(1, size)  // our matrices come out of float math: near zero is zero
    if abs(m.a) < z && abs(m.d) < z { h = min(h, v) }
    if abs(m.b) < z && abs(m.c) < z { v = min(v, h) }
    return (h, v)
  }

  func entry(path: CGPath, outline: Int, m: CGAffineTransform) -> (Entry, CGFloat, CGFloat)? {
    guard let (hq, vq) = GlyphCache.steps(m) else { return nil }
    // round to the nearest step: whole pixels plus a phase in 1/hq, 1/vq
    let sx = (m.tx * CGFloat(hq)).rounded(), sy = (m.ty * CGFloat(vq)).rounded()
    let ox = (sx / CGFloat(hq)).rounded(.down), oy = (sy / CGFloat(vq)).rounded(.down)
    let fx = sx - ox * CGFloat(hq), fy = sy - oy * CGFloat(vq)
    let key = Key(outline: outline, a: Int32((m.a * 1024).rounded()), b: Int32((m.b * 1024).rounded()),
                  c: Int32((m.c * 1024).rounded()), d: Int32((m.d * 1024).rounded()),
                  fx: Int8(fx) | Int8(hq) << 3, fy: Int8(fy) | Int8(vq) << 3)
    if let hit = map[key] { return (hit, ox, oy) }
    let lin = CGAffineTransform(a: m.a, b: m.b, c: m.c, d: m.d, tx: fx / CGFloat(hq), ty: fy / CGFloat(vq))
    let r = path.boundingBoxOfPath.applying(lin)
    let e: Entry
    if r.isNull || r.isEmpty || r.width > 4096 || r.height > 4096 {
      e = Entry(mask: [], w: 0, h: 0, dx: 0, dy: 0)
    } else {
      let x0 = Int(r.minX.rounded(.down)) - 1, y0 = Int(r.minY.rounded(.down)) - 1
      let w = Int(r.maxX.rounded(.up)) + 1 - x0, h = Int(r.maxY.rounded(.up)) + 1 - y0
      var mask = [UInt8](repeating: 0, count: w * h)
      if w <= Scratch.size && h <= Scratch.size {
        // one reusable grey context: clear the corner, fill, copy the rows out (a new context per glyph costs more
        // than the fill)
        let sc = Scratch.shared
        let top = Scratch.size - h  // the corner's first memory row (memory rows run top down)
        for j in 0..<h { memset(sc.base + (top + j) * Scratch.size, 0, w) }
        sc.cx.saveGState()
        sc.cx.translateBy(x: CGFloat(-x0), y: CGFloat(-y0))
        sc.cx.concatenate(lin)
        sc.cx.addPath(path)
        sc.cx.fillPath(using: .winding)
        sc.cx.restoreGState()
        mask.withUnsafeMutableBytes { p in
          for j in 0..<h { memcpy(p.baseAddress! + j * w, sc.base + (top + j) * Scratch.size, w) }
        }
      } else {
        mask.withUnsafeMutableBytes { p in
          let bm = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: GlyphCache.gray,
                             bitmapInfo: CGImageAlphaInfo.none.rawValue)!
          bm.setFillColor(gray: 1, alpha: 1)
          bm.translateBy(x: CGFloat(-x0), y: CGFloat(-y0))
          bm.concatenate(lin)
          bm.addPath(path)
          bm.fillPath(using: .winding)
        }
      }
      e = Entry(mask: mask, w: w, h: h, dx: x0, dy: y0)
    }
    if map.count >= limit { map.removeAll(keepingCapacity: true) }
    map[key] = e
    return (e, ox, oy)
  }

  /// Draws `path` (glyph space) under `m` (glyph space → device, y up) filled with `color`. `target`: the bitmap to
  /// blend into directly, when that's allowed. false: not cacheable (huge glyph), the caller fills the outline.
  @discardableResult
  func draw(_ cx: CGContext, target: Bitmap?, path: CGPath, outline: Int, m: CGAffineTransform, color: RGBA) -> Bool {
    guard let (e, ox, oy) = entry(path: path, outline: outline, m: m) else { return false }
    if e.w == 0 { return true }
    let x0 = Int(ox) + e.dx, y0 = Int(oy) + e.dy
    if let t = target {
      t.blend(e.mask, w: e.w, h: e.h, x: x0, y: y0, color: color)
      return true
    }
    func q8(_ v: Float) -> UInt32 { UInt32(max(0, min(255, (v * 255).rounded()))) }
    let ck = q8(color.r) << 24 | q8(color.g) << 16 | q8(color.b) << 8 | q8(color.a)
    var img = e.images[ck]
    if img == nil {
      var px = [UInt8](repeating: 0, count: e.w * e.h * 4)
      let c = [color.r, color.g, color.b].map { $0 * color.a }
      for i in 0..<(e.w * e.h) {
        let a = Float(e.mask[i]) * color.a
        px[i * 4] = UInt8((c[0] * Float(e.mask[i])).rounded())
        px[i * 4 + 1] = UInt8((c[1] * Float(e.mask[i])).rounded())
        px[i * 4 + 2] = UInt8((c[2] * Float(e.mask[i])).rounded())
        px[i * 4 + 3] = UInt8(a.rounded())
      }
      img = Sampler.make(px, e.w, e.h)
      e.images[ck] = img
    }
    if let img {
      cx.draw(img, in: CGRect(x: CGFloat(x0), y: CGFloat(y0), width: CGFloat(e.w), height: CGFloat(e.h)))
    }
    return true
  }
}

/// An RGBA8 bitmap context's memory, for blending glyph masks straight in (device coordinates, y up).
final class Bitmap {
  let base: UnsafeMutablePointer<UInt8>
  let width, height, rowBytes: Int

  init?(_ cx: CGContext) {
    guard let d = cx.data, cx.bitsPerPixel == 32, cx.bitsPerComponent == 8,
          cx.alphaInfo == .noneSkipLast || cx.alphaInfo == .premultipliedLast,
          cx.bitmapInfo.intersection(.byteOrderMask) == [] || cx.bitmapInfo.contains(.byteOrder32Big)
    else { return nil }
    base = d.assumingMemoryBound(to: UInt8.self)
    width = cx.width; height = cx.height; rowBytes = cx.bytesPerRow
  }

  /// colour × coverage over the destination: d = c·a + d·(1 − a), a = coverage × alpha (premultiplied colour)
  func blend(_ mask: [UInt8], w: Int, h: Int, x: Int, y: Int, color: RGBA) {
    let r = Int((color.r * 255).rounded()), g = Int((color.g * 255).rounded()), b = Int((color.b * 255).rounded())
    let al = Int((color.a * 255).rounded())
    mask.withUnsafeBufferPointer { m in
      for j in 0..<h {
        let dy = y + (h - 1 - j)  // mask row j (top first) → device row from the bottom
        if dy < 0 || dy >= height { continue }
        let row = base + (height - 1 - dy) * rowBytes
        let i0 = max(0, -x), i1 = min(w, width - x)
        if i0 >= i1 { continue }
        for i in i0..<i1 {
          var a = Int(m[j * w + i])
          if a == 0 { continue }
          if al != 255 { a = (a * al + 127) / 255 }
          let p = row + (x + i) * 4
          let na = 255 - a
          p[0] = UInt8((r * a + Int(p[0]) * na + 127) / 255)
          p[1] = UInt8((g * a + Int(p[1]) * na + 127) / 255)
          p[2] = UInt8((b * a + Int(p[2]) * na + 127) / 255)
          p[3] = UInt8((255 * a + Int(p[3]) * na + 127) / 255)
        }
      }
    }
  }
}

/// A 512 × 512 grey bitmap context reused to render glyph masks (white on black, coverage = grey).
final class Scratch {
  static let size = 512
  static let shared = Scratch()
  let base: UnsafeMutablePointer<UInt8>
  let cx: CGContext
  init() {
    base = .allocate(capacity: Scratch.size * Scratch.size)
    cx = CGContext(data: base, width: Scratch.size, height: Scratch.size, bitsPerComponent: 8, bytesPerRow: Scratch.size,
                   space: GlyphCache.gray, bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    cx.setFillColor(gray: 1, alpha: 1)
  }
}
