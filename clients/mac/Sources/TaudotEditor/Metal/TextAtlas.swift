// Glyphs rasterized once by Core Text into a Metal texture, by (font, glyph, quarter-pixel x offset): text in a
// proportional font keeps its exact positions. Coverage is drawn white on opaque black with font smoothing on, as
// Neovim mode's atlas does, so the glyphs get macOS's stem darkening like AppKit's text.
import AppKit
import CoreText
import Metal
import TaudotShared

final class TextAtlas: GlyphTexture {
  struct Key: Hashable { var font: UInt16; var glyph: CGGlyph; var sub: UInt8 }
  struct Entry {
    var x: UInt16, y: UInt16, w: UInt16, h: UInt16
    /// From the pen (whole pixel, on the baseline) to the bitmap's top left, in pixels.
    var dx: Int16, dy: Int16
    var color: Bool
    var empty: Bool
  }
  static let subpixel = 4

  let device: MTLDevice
  private(set) var texture: MTLTexture
  let size: Int
  var scale: CGFloat { didSet { if scale != oldValue { reset() } } }
  private var entries: [Key: Entry] = [:]
  private var shelfX = 0, shelfY = 0, shelfH = 0
  /// Bumped on every reset (callers drop what they cached).
  private(set) var generation = 0

  init(device: MTLDevice, scale: CGFloat, size: Int = 2048) {
    self.device = device
    self.scale = scale
    self.size = size
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: size, height: size, mipmapped: false)
    d.usage = .shaderRead
    d.storageMode = .shared
    texture = device.makeTexture(descriptor: d)!
  }

  func reset() {
    entries.removeAll(keepingCapacity: true)
    shelfX = 0; shelfY = 0; shelfH = 0
    generation += 1
  }

  /// `full` is set when the atlas had to start over during this call (what was drawn this frame must be redrawn).
  func entry(_ font: CTFont, fontIndex: UInt16, glyph: CGGlyph, sub: Int, full: inout Bool) -> Entry {
    let key = Key(font: fontIndex, glyph: glyph, sub: UInt8(sub))
    if let e = entries[key] { return e }
    let e = rasterize(font, glyph: glyph, sub: sub, full: &full)
    entries[key] = e
    return e
  }

  private func rasterize(_ font: CTFont, glyph: CGGlyph, sub: Int, full: inout Bool) -> Entry {
    let blank = Entry(x: 0, y: 0, w: 0, h: 0, dx: 0, dy: 0, color: false, empty: true)
    var g = glyph
    var r = CGRect.zero
    CTFontGetBoundingRectsForGlyphs(font, .horizontal, &g, &r, 1)
    if r.isEmpty || r.width <= 0 || r.height <= 0 { return blank }
    let pad = 2
    let left = Int((r.minX * scale).rounded(.down)) - pad
    let bottom = Int((r.minY * scale).rounded(.down)) - pad
    let w = Int((r.maxX * scale).rounded(.up)) + pad + 1 - left
    let h = Int((r.maxY * scale).rounded(.up)) + pad - bottom
    guard w > 0, h > 0, w < size / 4, h < size / 4 else { return blank }
    guard let (x, y) = place(w, h) else {
      reset()
      full = true
      return rasterize(font, glyph: glyph, sub: sub, full: &full)
    }
    let color = CTFontGetSymbolicTraits(font).contains(.traitColorGlyphs)
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    px.withUnsafeMutableBytes { buf in
      let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      ctx.setAllowsFontSmoothing(true)
      ctx.setShouldSmoothFonts(!color)
      ctx.setAllowsAntialiasing(true)
      ctx.setShouldAntialias(true)
      ctx.setAllowsFontSubpixelPositioning(true)
      ctx.setShouldSubpixelPositionFonts(true)
      ctx.setAllowsFontSubpixelQuantization(false)
      ctx.setShouldSubpixelQuantizeFonts(false)
      if !color {
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
      }
      ctx.setFillColor(CGColor(gray: 1, alpha: 1))
      ctx.scaleBy(x: scale, y: scale)
      // the pen at (-left + sub/4, -bottom) pixels in this bitmap
      var pos = CGPoint(x: (CGFloat(-left) + CGFloat(sub) / CGFloat(TextAtlas.subpixel)) / scale, y: CGFloat(-bottom) / scale)
      CTFontDrawGlyphs(font, &g, &pos, 1, ctx)
    }
    if !color {
      for i in stride(from: 0, to: px.count, by: 4) {
        let c = px[i]
        px[i] = 255; px[i + 1] = 255; px[i + 2] = 255; px[i + 3] = c
      }
    }
    texture.replace(region: MTLRegionMake2D(x, y, w, h), mipmapLevel: 0, withBytes: px, bytesPerRow: w * 4)
    // bitmap top = h + bottom pixels above the baseline
    return Entry(x: UInt16(x), y: UInt16(y), w: UInt16(w), h: UInt16(h), dx: Int16(left), dy: Int16(-(h + bottom)),
                 color: color, empty: false)
  }

  private func place(_ w: Int, _ h: Int) -> (Int, Int)? {
    if shelfX + w > size { shelfY += shelfH; shelfX = 0; shelfH = 0 }
    if shelfY + h > size { return nil }
    let p = (shelfX, shelfY)
    shelfX += w
    shelfH = max(shelfH, h)
    return p
  }
}
