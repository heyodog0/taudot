// Axial and radial shadings rasterised per device pixel: t at each pixel centre, the colour from the list's 256
// samples, painted 1:1 under the current clip. Whole pixels inside the shading's extent are painted fully, as the
// oracle does; CGShading antialiases the extent's end and lands about a pixel off.
import CoreGraphics
import Foundation

extension Drawer {
  /// where in a pixel t is sampled (0.5: its centre)
  static let shadeOffset = Double(ProcessInfo.processInfo.environment["TAUDOT_SHADE_OFFSET"] ?? "") ?? 0.5
  /// t at shading-space point (x, y), or nil where the shading paints nothing.
  static func shadeT(_ radial: Bool, _ ext: (Bool, Bool), _ c: [Float], _ x: Double, _ y: Double) -> Double? {
    let x0 = Double(c[0]), y0 = Double(c[1]), r0 = Double(c[2]), x1 = Double(c[3]), y1 = Double(c[4]), r1 = Double(c[5])
    func ok(_ t: Double) -> Double? {
      if t < 0 { return ext.0 ? 0 : nil }
      if t > 1 { return ext.1 ? 1 : nil }
      return t
    }
    if !radial {
      let dx = x1 - x0, dy = y1 - y0, l = dx * dx + dy * dy
      if l == 0 { return nil }
      return ok(((x - x0) * dx + (y - y0) * dy) / l)
    }
    // |p − c(t)| = r(t), r(t) ≥ 0, the largest t (PDF's rule for radial shadings)
    let cdx = x1 - x0, cdy = y1 - y0, dr = r1 - r0, pdx = x - x0, pdy = y - y0
    let a = cdx * cdx + cdy * cdy - dr * dr
    let b = pdx * cdx + pdy * cdy + r0 * dr
    let cc = pdx * pdx + pdy * pdy - r0 * r0
    var ts: [Double] = []
    if abs(a) < 1e-12 {
      if b != 0 { ts = [cc / (2 * b)] }
    } else {
      let disc = b * b - a * cc
      if disc < 0 { return nil }
      let s = disc.squareRoot()
      ts = [(b + s) / a, (b - s) / a].sorted(by: >)
    }
    for t in ts where r0 + t * dr >= 0 {
      if let v = ok(t) { return v }
    }
    return nil
  }

  /// false: nothing to paint here (the caller falls back to CGShading).
  static func drawShade(_ cx: CGContext, _ radial: Bool, _ ext: (Bool, Bool), _ c: [Float], _ m: Matrix, _ sb: Rect,
                        _ alpha: Float, _ samples: [UInt8], bbox: Rect) -> Bool {
    let full = cgAffine(m).concatenating(cx.ctm)  // shading space → device (y up)
    let inv = full.inverted()
    var area = cx.boundingBoxOfClipPath.applying(cx.ctm)
    let b = cgRect(bbox).applying(cx.ctm)
    if b.width < 1e5 { area = area.intersection(b) }
    if sb.x1 > sb.x0, sb.y1 > sb.y0 { area = area.intersection(cgRect(sb).applying(full)) }
    if area.isNull || area.isEmpty { return true }
    let X0 = Int(area.minX.rounded(.down)), Y0 = Int(area.minY.rounded(.down))
    let X1 = Int(area.maxX.rounded(.up)), Y1 = Int(area.maxY.rounded(.up))
    let w = X1 - X0, h = Y1 - Y0
    guard w > 0, h > 0, w * h <= 16 << 20 else { return false }
    let n = samples.count / 4
    var px = [UInt8](repeating: 0, count: w * h * 4)
    for j in 0..<h {
      let dy = Double(Y1 - 1 - j) + Drawer.shadeOffset  // memory row j is the top row
      for i in 0..<w {
        let dx = Double(X0 + i) + Drawer.shadeOffset
        let sx = Double(inv.a) * dx + Double(inv.c) * dy + Double(inv.tx)
        let sy = Double(inv.b) * dx + Double(inv.d) * dy + Double(inv.ty)
        guard let t = shadeT(radial, ext, c, sx, sy) else { continue }
        let k = min(n - 1, max(0, Int((t * Double(n - 1)).rounded()))) * 4
        let a = Int(samples[k + 3])
        let o = (j * w + i) * 4
        // premultiplied
        px[o] = UInt8((Int(samples[k]) * a + 127) / 255)
        px[o + 1] = UInt8((Int(samples[k + 1]) * a + 127) / 255)
        px[o + 2] = UInt8((Int(samples[k + 2]) * a + 127) / 255)
        px[o + 3] = UInt8(a)
      }
    }
    guard let img = Sampler.make(px, w, h) else { return false }
    let dev = cx.ctm
    cx.saveGState()
    cx.concatenate(dev.inverted())
    cx.interpolationQuality = .none
    cx.setAlpha(CGFloat(alpha))
    cx.draw(img, in: CGRect(x: X0, y: Y0, width: w, height: h))
    cx.restoreGState()
    return true
  }
}
