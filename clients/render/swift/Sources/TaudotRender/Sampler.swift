// Images resampled to the exact device pixels they cover, so CG copies them 1:1.
//
// The oracle (MuPDF) places an axis-aligned image on whole device pixels, growing it outward to the pixels its edges
// touch, and resamples it to that size. This is our own resampler for the same placement (written from first
// principles): area averaging when shrinking (each output pixel averages the source area it covers), bilinear at
// pixel centres when enlarging, separable, on premultiplied RGBA.
import CoreGraphics
import Foundation

enum Sampler {
  /// For each output pixel along one axis: (first source index, weights) summing to 1.
  static func weights(src: Int, dst: Int) -> [(Int, [Float])] {
    let r = Double(src) / Double(dst)
    var out: [(Int, [Float])] = []
    out.reserveCapacity(dst)
    for i in 0..<dst {
      if dst <= src {
        let a = Double(i) * r, b = Double(i + 1) * r
        let first = Int(a.rounded(.down)), last = min(src - 1, Int((b - 1e-9).rounded(.down)))
        var w: [Float] = []
        for k in first...max(first, last) {
          let lo = max(a, Double(k)), hi = min(b, Double(k + 1))
          w.append(Float(max(0, hi - lo) / r))
        }
        out.append((first, w))
      } else {
        let c = (Double(i) + 0.5) * r - 0.5
        let k = Int(c.rounded(.down)), t = Float(c - Double(k))
        if k < 0 { out.append((0, [1])) }
        else if k >= src - 1 { out.append((src - 1, [1])) }
        else { out.append((k, [1 - t, t])) }
      }
    }
    return out
  }

  /// `img` resampled to w × h pixels, premultiplied RGBA8 sRGB.
  static func resample(_ img: CGImage, w: Int, h: Int) -> CGImage? {
    let sw = img.width, sh = img.height
    guard sw > 0, sh > 0, w > 0, h > 0 else { return nil }
    // decode to premultiplied RGBA8, top row first
    var src = [UInt8](repeating: 0, count: sw * sh * 4)
    let ok = src.withUnsafeMutableBytes { p -> Bool in
      guard let cx = CGContext(data: p.baseAddress, width: sw, height: sh, bitsPerComponent: 8, bytesPerRow: sw * 4,
                               space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
      cx.interpolationQuality = .none
      cx.draw(img, in: CGRect(x: 0, y: 0, width: sw, height: sh))
      return true
    }
    guard ok else { return nil }
    if sw == w && sh == h { return make(src, w, h) }
    // horizontal pass: sh rows × w
    let wx = weights(src: sw, dst: w), wy = weights(src: sh, dst: h)
    var mid = [Float](repeating: 0, count: w * sh * 4)
    for y in 0..<sh {
      let row = y * sw * 4, orow = y * w * 4
      for x in 0..<w {
        let (k0, ws) = wx[x]
        var acc: (Float, Float, Float, Float) = (0, 0, 0, 0)
        for (j, wt) in ws.enumerated() {
          let s = row + (k0 + j) * 4
          acc.0 += wt * Float(src[s]); acc.1 += wt * Float(src[s + 1])
          acc.2 += wt * Float(src[s + 2]); acc.3 += wt * Float(src[s + 3])
        }
        let o = orow + x * 4
        mid[o] = acc.0; mid[o + 1] = acc.1; mid[o + 2] = acc.2; mid[o + 3] = acc.3
      }
    }
    // vertical pass
    var out = [UInt8](repeating: 0, count: w * h * 4)
    for y in 0..<h {
      let (k0, ws) = wy[y]
      for x in 0..<(w * 4) {
        var acc: Float = 0
        for (j, wt) in ws.enumerated() { acc += wt * mid[(k0 + j) * w * 4 + x] }
        out[y * w * 4 + x] = UInt8(max(0, min(255, acc.rounded())))
      }
    }
    return make(out, w, h)
  }

  static func make(_ px: [UInt8], _ w: Int, _ h: Int) -> CGImage? {
    guard let p = CGDataProvider(data: Data(px) as CFData) else { return nil }
    return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: srgb,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: p,
                   decode: nil, shouldInterpolate: false, intent: .defaultIntent)
  }
}

extension Resources {
  /// The image `id` resampled to w × h, from a process-wide cache keyed by the image's content: an app redrawing a
  /// page (scroll, zoom back, an edit elsewhere) neither decodes nor resamples it again.
  func resampled(_ id: UInt32, w: Int, h: Int) -> CGImage? {
    guard let im = list.images[id] else { return nil }
    let key = SampleKey(content: Sampler.contentKey(im), w: w, h: h)
    if let r = Sampler.cache[key] { return r }
    guard let img = image(id) else { return nil }
    let r = Sampler.resample(img, w: w, h: h)
    Sampler.store(key, r, bytes: w * h * 4)
    return r
  }
}

struct SampleKey: Hashable { let content: UInt64; let w, h: Int }

extension Sampler {
  static var cache: [SampleKey: CGImage?] = [:]
  static var cacheBytes = 0
  static let cacheLimit = 256 << 20

  static func store(_ k: SampleKey, _ r: CGImage?, bytes: Int) {
    if cacheBytes + bytes > cacheLimit { cache.removeAll(); cacheBytes = 0 }
    cache[k] = r
    cacheBytes += bytes
  }

  static func contentKey(_ im: Image) -> UInt64 { im.key }
}

extension Resources {
  /// The coverage of mask image `id` (its alpha) resampled to w × h, as a DeviceGray image for clip(to:mask:).
  func resampledMask(_ id: UInt32, w: Int, h: Int) -> CGImage? {
    guard let im = list.images[id] else { return nil }
    let key = SampleKey(content: Sampler.contentKey(im) &+ 1, w: w, h: h)
    if let r = Sampler.cache[key] { return r }
    var out: CGImage?
    if let a = alphaMask(id), let r = Sampler.resample(a, w: w, h: h), let d = r.dataProvider?.data as Data? {
      let px = [UInt8](d)
      var g = [UInt8](repeating: 0, count: w * h)
      for i in 0..<(w * h) { g[i] = px[i * 4] }  // grey → r = g = b
      if let p = CGDataProvider(data: Data(g) as CFData) {
        out = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: p,
                      decode: nil, shouldInterpolate: false, intent: .defaultIntent)
      }
    }
    Sampler.store(key, out, bytes: w * h)
    return out
  }
}

extension Drawer {
  /// Where an axis-aligned unit square under `m` lands in device pixels, grown outward to whole pixels as the oracle
  /// places images: (rect, flipX, flipY), or nil when rotated or skewed.
  static func deviceFit(_ cx: CGContext, _ m: Matrix) -> (CGRect, Bool, Bool)? {
    let full = cgAffine(m).concatenating(cx.ctm)  // unit square → device pixels (y up)
    guard abs(full.b) < 1e-6, abs(full.c) < 1e-6, !cgImages else { return nil }
    let xs = [full.tx, full.tx + full.a], ys = [full.ty, full.ty + full.d]
    let x0 = xs.min()!.rounded(.down), x1 = xs.max()!.rounded(.up)
    let y0 = ys.min()!.rounded(.down), y1 = ys.max()!.rounded(.up)
    guard x1 > x0, y1 > y0, (x1 - x0) * (y1 - y0) < CGFloat(64 << 20) else { return nil }
    return (CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0), full.a < 0, full.d > 0)
  }

  /// Clips to mask image `id` on the unit square under `m` (grid-fitted and resampled like an image). The CTM is
  /// left as it was. false: no mask.
  static func clipToMask(_ cx: CGContext, _ res: Resources, _ id: UInt32, _ m: Matrix) -> Bool {
    let dev = cx.ctm
    if let (r, fx, fy) = deviceFit(cx, m), let mask = res.resampledMask(id, w: Int(r.width), h: Int(r.height)) {
      cx.concatenate(dev.inverted())
      if fx { cx.translateBy(x: r.minX + r.maxX, y: 0); cx.scaleBy(x: -1, y: 1) }
      if fy { cx.translateBy(x: 0, y: r.minY + r.maxY); cx.scaleBy(x: 1, y: -1) }
      cx.clip(to: r, mask: mask)
    } else if let mask = res.alphaMask(id) {
      cx.concatenate(cgAffine(m))
      cx.translateBy(x: 0, y: 1)
      cx.scaleBy(x: 1, y: -1)
      cx.clip(to: CGRect(x: 0, y: 0, width: 1, height: 1), mask: mask)
    } else { return false }
    cx.concatenate(dev.concatenating(cx.ctm.inverted()))  // back to the CTM we had
    return true
  }

  static let cgImages = ProcessInfo.processInfo.environment["TAUDOT_CG_IMAGES"] != nil
  /// Draws `img` on the unit square mapped by `m` (its top row at y = 0). Axis-aligned: grid-fitted outward to whole
  /// device pixels and resampled by `Sampler`. Rotated or skewed: CG's own sampling.
  /// false: the image can't be decoded.
  static func drawImage(_ cx: CGContext, _ res: Resources, _ id: UInt32, _ m: Matrix, alpha: Float) -> Bool {
    let full = cgAffine(m).concatenating(cx.ctm)  // unit square → device pixels (y up)
    cx.saveGState()
    cx.setAlpha(CGFloat(alpha))
    if abs(full.b) < 1e-6, abs(full.c) < 1e-6, !cgImages {
      let xs = [full.tx, full.tx + full.a], ys = [full.ty, full.ty + full.d]
      let x0 = xs.min()!.rounded(.down), x1 = xs.max()!.rounded(.up)
      let y0 = ys.min()!.rounded(.down), y1 = ys.max()!.rounded(.up)
      let w = Int(x1 - x0), h = Int(y1 - y0)
      if w > 0, h > 0, w * h < 64 << 20, let r = res.resampled(id, w: w, h: h) {
        cx.concatenate(cx.ctm.inverted())  // device space
        cx.interpolationQuality = .none
        // the image's top row goes where unit y = 0 lands; its left column where unit x = 0 does
        if full.a < 0 { cx.translateBy(x: x0 + x1, y: 0); cx.scaleBy(x: -1, y: 1) }
        if full.d > 0 { cx.translateBy(x: 0, y: y0 + y1); cx.scaleBy(x: 1, y: -1) }
        cx.draw(r, in: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
        cx.restoreGState()
        return true
      }
    }
    guard let img = res.image(id) else { cx.restoreGState(); return false }
    cx.concatenate(cgAffine(m))
    cx.translateBy(x: 0, y: 1)
    cx.scaleBy(x: 1, y: -1)
    cx.draw(img, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    cx.restoreGState()
    return true
  }
}
