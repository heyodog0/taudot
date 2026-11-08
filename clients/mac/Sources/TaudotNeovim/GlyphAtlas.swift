// Cells' text rasterized once by Core Text into a Metal texture.
import AppKit
import CoreText
import Metal
import TaudotShared

public struct GlyphKey: Hashable {
  public var text: String
  public var style: FontStyle
  public var cells: UInt8
}

public struct GlyphEntry {
  /// Atlas rect in pixels.
  public var x: UInt16, y: UInt16, w: UInt16, h: UInt16
  /// Where the slot's origin sits relative to the cell's top-left, in pixels (negative: padding).
  public var dx: Int16, dy: Int16
  public var color: Bool
  public var empty: Bool
}

public final class GlyphAtlas: GlyphTexture {
  public let device: MTLDevice
  public private(set) var texture: MTLTexture
  public let size: Int
  public private(set) var font: FontSet
  var entries: [GlyphKey: GlyphEntry] = [:]
  var shelfX = 0, shelfY = 0, shelfH = 0
  public private(set) var generation = 0
  let padX: Int, padY: Int
  public var ligatures = false

  public init(device: MTLDevice, font: FontSet, size: Int = 2048) {
    self.device = device
    self.font = font
    self.size = size
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: size, height: size, mipmapped: false)
    d.usage = .shaderRead
    d.storageMode = .shared
    texture = device.makeTexture(descriptor: d)!
    padX = Int((font.cellWidth / 2).rounded(.up))
    padY = Int((font.cellHeight / 3).rounded(.up))
  }

  public func reset() {
    entries.removeAll(keepingCapacity: true)
    shelfX = 0; shelfY = 0; shelfH = 0
    generation += 1
  }

  public func entry(_ text: String, _ style: FontStyle, cells: Int) -> GlyphEntry {
    let key = GlyphKey(text: text, style: style, cells: UInt8(clamping: cells))
    if let e = entries[key] { return e }
    let e = rasterize(key)
    entries[key] = e
    return e
  }

  func rasterize(_ key: GlyphKey) -> GlyphEntry {
    let blank = GlyphEntry(x: 0, y: 0, w: 0, h: 0, dx: 0, dy: 0, color: false, empty: true)
    if key.text.isEmpty || key.text.allSatisfy({ $0 == " " }) { return blank }
    let cw = Int(font.cellWidth), ch = Int(font.cellHeight)
    let w = Int(key.cells) * cw + 2 * padX, h = ch + 2 * padY
    guard let (x, y) = place(w, h) else {
      // Full: start over (callers re-request every frame, so the cache refills).
      reset()
      return rasterize(key)
    }
    let ctFont = font.face(key.style)
    let attrs: [NSAttributedString.Key: Any] = [
      .font: ctFont, .foregroundColor: NSColor.white.cgColor, .ligature: ligatures ? 1 : 0,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: key.text, attributes: attrs))
    let runs = CTLineGetGlyphRuns(line) as! [CTRun]
    let procedural = BoxDrawing.handles(key.text)
    let color = !procedural && runs.contains { r in
      let a = CTRunGetAttributes(r) as NSDictionary
      let f = a[kCTFontAttributeName] as! CTFont
      return CTFontGetSymbolicTraits(f).contains(.traitColorGlyphs)
    }
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let cs = CGColorSpaceCreateDeviceRGB()
    px.withUnsafeMutableBytes { buf in
      let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      ctx.setAllowsFontSmoothing(true)
      ctx.setShouldSmoothFonts(!color)
      ctx.setAllowsAntialiasing(true)
      ctx.setShouldAntialias(true)
      if !color {
        // Opaque black under white text, so macOS's font smoothing (stem darkening) applies; red becomes coverage.
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
      }
      if procedural {
        // Box drawing, blocks, sextants: drawn to the cell's exact rect (BoxDrawing.swift), not from the font.
        BoxDrawing.draw(key.text, in: ctx, cell: CGRect(x: padX, y: padY, width: Int(key.cells) * cw, height: ch), scale: font.scale)
        return
      }
      ctx.scaleBy(x: font.scale, y: font.scale)
      let baseline = CGFloat(padY + ch) - font.ascent  // from the bottom, in pixels
      var tx = CGFloat(padX)
      // Scale a glyph wider than its cells down so it never spills into the next cell.
      let lineW = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) * font.scale
      let avail = CGFloat(Int(key.cells) * cw)
      if color && lineW > avail * 1.05 {
        let s = avail / lineW
        ctx.scaleBy(x: s, y: s)
        tx /= s
        ctx.textPosition = CGPoint(x: tx / font.scale, y: (baseline / s) / font.scale)
      } else {
        if lineW < avail { tx += ((avail - lineW) / 2).rounded(.down) * (Int(key.cells) > 1 && color ? 1 : 0) }
        ctx.textPosition = CGPoint(x: tx / font.scale, y: baseline / font.scale)
      }
      CTLineDraw(line, ctx)
    }
    if !color {
      for i in stride(from: 0, to: px.count, by: 4) {
        let c = px[i]
        px[i] = 255; px[i + 1] = 255; px[i + 2] = 255; px[i + 3] = c
      }
    }
    texture.replace(region: MTLRegionMake2D(x, y, w, h), mipmapLevel: 0, withBytes: px, bytesPerRow: w * 4)
    return GlyphEntry(x: UInt16(x), y: UInt16(y), w: UInt16(w), h: UInt16(h), dx: Int16(-padX), dy: Int16(-padY),
                      color: color, empty: false)
  }

  func place(_ w: Int, _ h: Int) -> (Int, Int)? {
    if shelfX + w > size { shelfY += shelfH; shelfX = 0; shelfH = 0 }
    if shelfY + h > size { return nil }
    let p = (shelfX, shelfY)
    shelfX += w
    shelfH = max(shelfH, h)
    return p
  }
}

extension Renderer {
  public func glyph(_ e: GlyphEntry, x: Float, y: Float, color: SIMD4<Float>) {
    if e.empty { return }
    glyph(rect: SIMD4(x + Float(e.dx), y + Float(e.dy), Float(e.w), Float(e.h)),
          uv: SIMD4(Float(e.x), Float(e.y), Float(e.w), Float(e.h)), color: color, colorGlyph: e.color)
  }
}
