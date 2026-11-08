// Draws a PageList into any CGContext. The page's frame is PDF points, y down (dlist.md); `draw` flips for CG.
import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// Feature groups, switched on one at a time as each is built (backend.md, Phase A step 4). An op of a group that is
/// off draws as a magenta box, like UNSUPPORTED, so it shows in the harness's diff.
public struct Groups: OptionSet, Hashable {
  public let rawValue: Int
  public init(rawValue: Int) { self.rawValue = rawValue }
  public static let paths = Groups(rawValue: 1)       // FILL, STROKE, path clips
  public static let rules = Groups(rawValue: 2)       // RULE
  public static let fonts = Groups(rawValue: 4)       // TEXT
  public static let images = Groups(rawValue: 8)      // DRAW_IMAGE, IMAGE_MASK, image clips
  public static let transparency = Groups(rawValue: 16) // groups, soft masks, tiles, blend modes
  public static let all: Groups = [.paths, .rules, .fonts, .images, .transparency]
  /// what this build draws
  public static let built: Groups = .all

  public static let names: [(String, Groups)] = [
    ("paths", .paths), ("rules", .rules), ("fonts", .fonts), ("images", .images), ("transparency", .transparency),
  ]
  public init?(names list: String) {
    var g: Groups = []
    for n in list.split(separator: ",") {
      if n == "all" { g.formUnion(.all); continue }
      if n == "built" { g.formUnion(.built); continue }
      guard let k = Groups.names.first(where: { $0.0 == n }) else { return nil }
      g.insert(k.1)
    }
    self = g
  }
}

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func cgColor(_ c: RGBA, alpha: Float = 1) -> CGColor {
  CGColor(colorSpace: srgb, components: [CGFloat(c.r), CGFloat(c.g), CGFloat(c.b), CGFloat(c.a * alpha)])!
}

func cgRect(_ r: Rect) -> CGRect {
  CGRect(x: CGFloat(r.x0), y: CGFloat(r.y0), width: CGFloat(r.x1 - r.x0), height: CGFloat(r.y1 - r.y0))
}

func cgAffine(_ m: Matrix) -> CGAffineTransform {
  CGAffineTransform(a: CGFloat(m.a), b: CGFloat(m.b), c: CGFloat(m.c), d: CGFloat(m.d), tx: CGFloat(m.e), ty: CGFloat(m.f))
}

func cgPath(_ cmds: [PathCmd], _ t: CGAffineTransform = .identity) -> CGPath {
  let p = CGMutablePath()
  var open = false
  for c in cmds {
    switch c {
    case .move(let x, let y): p.move(to: CGPoint(x: CGFloat(x), y: CGFloat(y)), transform: t); open = true
    case .line(let x, let y):
      if !open { p.move(to: CGPoint(x: CGFloat(x), y: CGFloat(y)), transform: t); open = true }
      else { p.addLine(to: CGPoint(x: CGFloat(x), y: CGFloat(y)), transform: t) }
    case .quad(let x1, let y1, let x, let y):
      p.addQuadCurve(to: CGPoint(x: CGFloat(x), y: CGFloat(y)), control: CGPoint(x: CGFloat(x1), y: CGFloat(y1)), transform: t)
    case .curve(let x1, let y1, let x2, let y2, let x, let y):
      p.addCurve(to: CGPoint(x: CGFloat(x), y: CGFloat(y)), control1: CGPoint(x: CGFloat(x1), y: CGFloat(y1)),
                 control2: CGPoint(x: CGFloat(x2), y: CGFloat(y2)), transform: t)
    case .close: if open { p.closeSubpath() }
    }
  }
  return p
}

/// A path of only moves and lines split into polylines of at most `n` segments, consecutive pieces sharing their end
/// point. nil when it has curves or closed subpaths (those stroke as one).
func polylineChunks(_ cmds: [PathCmd], _ n: Int) -> [CGPath]? {
  var out: [CGPath] = []
  var cur = CGMutablePath(), segs = 0, last = CGPoint.zero, prev = CGPoint.zero, open = false
  for c in cmds {
    switch c {
    case .move(let x, let y):
      if segs > 0 { out.append(cur) }
      cur = CGMutablePath(); segs = 0
      last = CGPoint(x: CGFloat(x), y: CGFloat(y)); prev = last; cur.move(to: last); open = true
    case .line(let x, let y):
      guard open else { return nil }
      let p = CGPoint(x: CGFloat(x), y: CGFloat(y))
      if segs == n { out.append(cur); cur = CGMutablePath(); cur.move(to: prev); cur.addLine(to: last); segs = 1 }
      prev = last; last = p; cur.addLine(to: p); segs += 1
    default: return nil
    }
  }
  if segs > 0 { out.append(cur) }
  return out
}

/// First and last segments of a single-subpath polyline: (start, next, end, previous).
func polylineEnds(_ cmds: [PathCmd]) -> (CGPoint, CGPoint, CGPoint, CGPoint)? {
  var pts: [CGPoint] = []
  for c in cmds {
    switch c {
    case .move(let x, let y): if !pts.isEmpty { return nil }; pts.append(CGPoint(x: CGFloat(x), y: CGFloat(y)))
    case .line(let x, let y): pts.append(CGPoint(x: CGFloat(x), y: CGFloat(y)))
    default: return nil
    }
  }
  guard pts.count >= 2 else { return nil }
  // a tiny piece of each end segment, so only the cap shows (it is drawn inward from the end)
  func toward(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: a.x + (b.x - a.x) * 0.01, y: a.y + (b.y - a.y) * 0.01) }
  return (pts[0], toward(pts[0], pts[1]), pts[pts.count - 1], toward(pts[pts.count - 1], pts[pts.count - 2]))
}

/// A CGShading over 256 RGBA8 samples (t from 0 to 1, linear between samples).
final class ShadeTable { let v: [Float]; init(_ s: [UInt8]) { v = s.map { Float($0) / 255 } } }

func makeShading(_ radial: Bool, _ ext: (Bool, Bool), _ c: [Float], _ samples: [UInt8]) -> CGShading? {
  guard samples.count >= 8, samples.count % 4 == 0, c.count == 6 else { return nil }
  let table = ShadeTable(samples)
  var cb = CGFunctionCallbacks(version: 0, evaluate: { info, input, output in
    let t = Unmanaged<ShadeTable>.fromOpaque(info!).takeUnretainedValue()
    let n = t.v.count / 4
    let x = max(0, min(1, Float(input[0]))) * Float(n - 1)
    let i = min(n - 2, Int(x)), f = x - Float(i)
    for k in 0..<4 { output[k] = CGFloat(t.v[i * 4 + k] * (1 - f) + t.v[(i + 1) * 4 + k] * f) }
  }, releaseInfo: { info in Unmanaged<ShadeTable>.fromOpaque(info!).release() })
  let info = Unmanaged.passRetained(table).toOpaque()
  let domain: [CGFloat] = [0, 1], range: [CGFloat] = [0, 1, 0, 1, 0, 1, 0, 1]
  guard let fn = CGFunction(info: info, domainDimension: 1, domain: domain, rangeDimension: 4, range: range, callbacks: &cb)
  else { Unmanaged<ShadeTable>.fromOpaque(info).release(); return nil }
  let p0 = CGPoint(x: CGFloat(c[0]), y: CGFloat(c[1])), p1 = CGPoint(x: CGFloat(c[3]), y: CGFloat(c[4]))
  if radial {
    return CGShading(radialSpace: srgb, start: p0, startRadius: CGFloat(c[2]), end: p1, endRadius: CGFloat(c[5]),
                     function: fn, extendStart: ext.0, extendEnd: ext.1)
  }
  return CGShading(axialSpace: srgb, start: p0, end: p1, function: fn, extendStart: ext.0, extendEnd: ext.1)
}

/// The device rectangle a path covers when it is one axis-aligned rectangle under `t` (M L L L [L|Z] [M]), else nil.
func deviceRect(_ cmds: [PathCmd], _ t: CGAffineTransform) -> CGRect? {
  var pts: [CGPoint] = []
  for (i, c) in cmds.enumerated() {
    switch c {
    case .move(let x, let y):
      if i == 0 { pts.append(CGPoint(x: CGFloat(x), y: CGFloat(y))) }
      else if i < cmds.count - 1 { return nil }  // a trailing move (PGF writes one) is harmless
    case .line(let x, let y): pts.append(CGPoint(x: CGFloat(x), y: CGFloat(y)))
    case .close: break
    default: return nil
    }
  }
  if pts.count == 5, abs(pts[4].x - pts[0].x) < 1e-4, abs(pts[4].y - pts[0].y) < 1e-4 { pts.removeLast() }
  guard pts.count == 4 else { return nil }
  let d = pts.map { $0.applying(t) }
  let e: CGFloat = 1e-3
  for i in 0..<4 {
    let a = d[i], b = d[(i + 1) % 4]
    if abs(a.x - b.x) > e && abs(a.y - b.y) > e { return nil }
  }
  let xs = d.map(\.x), ys = d.map(\.y)
  return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
}

func apply(_ s: Stroke, to cx: CGContext) {
  cx.setLineWidth(CGFloat(s.width))
  cx.setLineCap(s.cap == 0 ? .butt : s.cap == 2 ? .square : .round)
  cx.setLineJoin(s.join == 1 ? .round : s.join == 2 ? .bevel : .miter)
  cx.setMiterLimit(CGFloat(s.miter))
  if s.dashes.isEmpty || s.dashes.allSatisfy({ $0 == 0 }) { cx.setLineDash(phase: 0, lengths: []) }
  else { cx.setLineDash(phase: CGFloat(s.dashPhase), lengths: s.dashes.map { CGFloat($0) }) }
}

/// Fonts and images made once per list (and per process for font files).
final class Resources {
  static var fontFiles: [String: CGFont] = [:]
  static var ctFontFiles: [String: CTFont] = [:]
  /// glyph outlines by outline identity (outlineID), kept across lists
  static var outlinePaths: [Int: CGPath] = [:]
  var ctFonts: [UInt32: CTFont] = [:]
  var images: [UInt32: CGImage] = [:]
  let list: PageList
  init(_ list: PageList) { self.list = list }

  func ctFont(_ id: UInt32) -> CTFont? {
    if let f = ctFonts[id] { return f }
    guard case .sfnt(_, let path, let index)? = list.fonts[id] else { return nil }
    let key = "\(path)#\(index)"
    if let f = Resources.ctFontFiles[key] { ctFonts[id] = f; return f }
    var cg = Resources.fontFiles[key]
    if cg == nil {
      let url = URL(fileURLWithPath: path) as CFURL
      if index == 0, let p = CGDataProvider(url: url) { cg = CGFont(p) }
      else if let ds = CTFontManagerCreateFontDescriptorsFromURL(url) as? [CTFontDescriptor], Int(index) < ds.count {
        cg = CTFontCopyGraphicsFont(CTFontCreateWithFontDescriptor(ds[Int(index)], 1, nil), nil)
      }
      Resources.fontFiles[key] = cg
    }
    guard let g = cg else { return nil }
    let f = CTFontCreateWithGraphicsFont(g, 1, nil, nil)
    ctFonts[id] = f
    Resources.ctFontFiles[key] = f
    return f
  }

  /// glyph outline in em units, y up
  /// a process-wide identity for an outline glyph: its font name and its commands (fonts have per-page ids)
  var outlineIDs: [UInt64: Int] = [:]
  func outlineID(_ font: UInt32, _ gid: UInt32) -> Int {
    let key = UInt64(font) << 32 | UInt64(gid)
    if let v = outlineIDs[key] { return v }
    var h = Hasher()
    h.combine(list.fonts[font]?.name ?? "")
    if case .sfnt(_, let path, let index)? = list.fonts[font] { h.combine(path); h.combine(index) }
    h.combine(gid)
    if case .outlines(_, let g)? = list.fonts[font], let cmds = g[gid] {
      h.combine(cmds.count)
      for c in cmds {
        switch c {
        case .move(let x, let y), .line(let x, let y): h.combine(x); h.combine(y)
        case .quad(let a, let b, let x, let y): h.combine(a); h.combine(b); h.combine(x); h.combine(y)
        case .curve(let a, let b, let c, let d, let x, let y):
          h.combine(a); h.combine(b); h.combine(c); h.combine(d); h.combine(x); h.combine(y)
        case .close: h.combine(0)
        }
      }
    }
    let v = h.finalize()
    outlineIDs[key] = v
    return v
  }

  var glyphPaths: [UInt64: CGPath?] = [:]
  func glyphPath(_ font: UInt32, _ gid: UInt32) -> CGPath? {
    let key = UInt64(font) << 32 | UInt64(gid)
    if let p = glyphPaths[key] { return p }
    let oid = outlineID(font, gid)
    if let p = Resources.outlinePaths[oid] { glyphPaths[key] = p; return p }
    var p: CGPath?
    switch list.fonts[font] {
    case .outlines(_, let g)?: p = g[gid].map { cgPath($0) }
    case .sfnt?: p = ctFont(font).flatMap { CTFontCreatePathForGlyph($0, CGGlyph(gid), nil) }
    default: p = nil
    }
    glyphPaths[key] = p
    if let p { Resources.outlinePaths[oid] = p }
    return p
  }

  func image(_ id: UInt32) -> CGImage? {
    if let i = images[id] { return i }
    guard let im = list.images[id] else { return nil }
    var out: CGImage?
    switch im.data {
    case .png(let d), .jpeg(let d):
      if let src = CGImageSourceCreateWithData(d as CFData, nil) { out = CGImageSourceCreateImageAtIndex(src, 0, nil) }
    case .rgba(let d):
      if im.w > 0, im.h > 0, d.count == im.w * im.h * 4, let p = CGDataProvider(data: d as CFData) {
        out = CGImage(width: im.w, height: im.h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: im.w * 4,
                      space: srgb, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: p,
                      decode: nil, shouldInterpolate: true, intent: .defaultIntent)
      }
    }
    images[id] = out
    return out
  }

  /// the image's alpha as a DeviceGray image, for CG's clip(to:mask:)
  func alphaMask(_ id: UInt32) -> CGImage? {
    guard let im = list.images[id], case .rgba(let d) = im.data, d.count == im.w * im.h * 4 else { return image(id) }
    let s = [UInt8](d)
    var a = [UInt8](repeating: 0, count: im.w * im.h)
    for i in 0..<a.count { a[i] = s[i * 4 + 3] }
    guard let p = CGDataProvider(data: Data(a) as CFData) else { return nil }
    return CGImage(width: im.w, height: im.h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: im.w,
                   space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: p,
                   decode: nil, shouldInterpolate: true, intent: .defaultIntent)
  }
}

public struct DrawStats {
  public var ops = 0, magenta = 0
  public var unsupported: [String: Int] = [:]
}

public enum Drawer {
  public static let magenta = RGBA(r: 1, g: 0, b: 1, a: 1)
  static let cgShades = ProcessInfo.processInfo.environment["TAUDOT_CG_SHADES"] != nil
  static let aaRectClips = ProcessInfo.processInfo.environment["TAUDOT_AA_RECT_CLIPS"] != nil
  static let chunk = Int(ProcessInfo.processInfo.environment["TAUDOT_STROKE_CHUNK"] ?? "") ?? 16

  /// Draws `list` with its top-left at the context's origin at `scale` pixels per point. The context's own CTM must
  /// be y-up (a bitmap context's default); `draw` flips.
  @discardableResult
  /// `visible` (page space, points): ops that draw only outside it are skipped (a tile of the page).
  public static func draw(_ list: PageList, in cx: CGContext, scale: CGFloat, height: CGFloat? = nil,
                          groups: Groups = .built, visible: CGRect? = nil) -> DrawStats {
    let h = height ?? CGFloat(list.height) * scale
    cx.saveGState()
    cx.translateBy(x: 0, y: h)
    cx.scaleBy(x: scale, y: -scale)
    var st = DrawStats()
    let res = Resources(list)
    // what each POP_CLIP undoes: 1 a saved state, 2 a pending rectangle, 0 nothing (a clip whose group was off)
    var clips: [UInt8] = []
    // Axis-aligned rectangle clips, kept out of the graphics state (device space, exact): the oracle cuts images and
    // shadings at whole pixels grown outward, and everything else with antialiased edges, so each op gets the
    // intersection its way.
    var rects: [CGRect] = []
    func rectClip(snapped: Bool) -> CGRect {
      var r = rects[0]
      for q in rects.dropFirst() { r = r.intersection(q) }
      if snapped, !r.isNull {
        r = CGRect(x: r.minX.rounded(.down), y: r.minY.rounded(.down),
                   width: r.maxX.rounded(.up) - r.minX.rounded(.down), height: r.maxY.rounded(.up) - r.minY.rounded(.down))
      }
      return r
    }
    func applyRects(snapped: Bool) {
      let dev = cx.ctm
      let r = rectClip(snapped: snapped)
      cx.concatenate(dev.inverted())
      cx.clip(to: r.isNull ? .zero : r)
      cx.concatenate(dev.concatenating(cx.ctm.inverted()))
    }
    var maskDepth = 0  // inside BEGIN_MASK...END_MASK: ops draw the mask, not the page
    var layers = 0     // transparency layers open
    // glyphs may be blended straight into the bitmap's memory when nothing (clip, layer) stands between
    let bitmap = GlyphCache.direct ? Bitmap(cx) : nil
    var tileDepth = 0

    func box(_ b: Rect, _ what: String) {
      st.magenta += 1
      st.unsupported[what, default: 0] += 1
      guard maskDepth == 0, tileDepth == 0 else { return }
      cx.setFillColor(cgColor(magenta))
      cx.fill(cgRect(b))
    }

    let vis: Rect? = visible.map { (Float($0.minX), Float($0.minY), Float($0.maxX), Float($0.maxY)) }
    for op in list.ops {
      st.ops += 1
      if let v = vis, maskDepth == 0, tileDepth == 0, let b = paintBox(op),
         b.x1 < v.x0 || b.x0 > v.x1 || b.y1 < v.y0 || b.y0 > v.y1 { continue }
      if maskDepth > 0 {
        if case .beginMask = op { maskDepth += 1 }
        if case .endMask = op { maskDepth -= 1 }
        if maskDepth > 0 { continue }
      }
      if tileDepth > 0 {
        if case .beginTile = op { tileDepth += 1 }
        if case .endTile = op { tileDepth -= 1 }
        continue
      }
      // pending rectangle clips around a drawing op; a clip op takes them into the graphics state first
      var wrapped = false
      if !rects.isEmpty {
        switch op {
        case .image, .imageMask, .shade:
          cx.saveGState(); applyRects(snapped: true); wrapped = true
        case .rule, .fill, .stroke, .unsupported, .figure:
          cx.saveGState(); applyRects(snapped: false); wrapped = true
        case .text(_, let mode, _, _, _, _, _) where mode != .clip:
          cx.saveGState(); applyRects(snapped: false); wrapped = true
        default: break
        }
      }
      defer { if wrapped { cx.restoreGState() } }
      switch op {
      case .rule(let b, let c):
        guard groups.contains(.rules) else { box(b, "rule"); continue }
        cx.setFillColor(cgColor(c))
        cx.fill(cgRect(b))

      case .fill(let b, let eo, let c, let m, let path):
        guard groups.contains(.paths) else { box(b, "fill"); continue }
        cx.addPath(cgPath(path, cgAffine(m)))
        cx.setFillColor(cgColor(c))
        cx.fillPath(using: eo ? .evenOdd : .winding)

      case .stroke(let b, let c, let m, let s, let path):
        guard groups.contains(.paths) else { box(b, "stroke"); continue }
        cx.saveGState()
        cx.concatenate(cgAffine(m))
        apply(s, to: cx)
        cx.setStrokeColor(cgColor(c))
        if c.a >= 1, s.dashes.isEmpty, path.count > 1000, let chunks = polylineChunks(path, Drawer.chunk) {
          // CG's stroker slows down badly on long self-crossing polylines (seconds for a 10k-point training curve).
          // Opaque, so pieces stroked one by one cover the same pixels: consecutive pieces share a segment, so every
          // join is inside one piece; butt ends inside a shared segment leave no gap; the path's true ends get their
          // own cap afterwards.
          cx.setLineCap(.butt)
          for ch in chunks { cx.addPath(ch); cx.strokePath() }
          if s.cap != 0, let (a0, a1, z0, z1) = polylineEnds(path) {
            cx.setLineCap(s.cap == 2 ? .square : .round)
            let e = CGMutablePath()
            e.move(to: a1); e.addLine(to: a0)
            e.move(to: z1); e.addLine(to: z0)
            cx.addPath(e)
            cx.strokePath()
          }
        } else {
          cx.addPath(cgPath(path))
          cx.strokePath()
        }
        cx.restoreGState()

      case .clipPath(_, let eo, let m, let path):
        guard groups.contains(.paths) else { clips.append(0); continue }
        if !Drawer.aaRectClips, let r = deviceRect(path, cgAffine(m).concatenating(cx.ctm)) {
          rects.append(r)
          clips.append(2)
          continue
        }
        cx.saveGState()
        if !rects.isEmpty { applyRects(snapped: false) }
        cx.addPath(cgPath(path, cgAffine(m)))
        cx.clip(using: eo ? .evenOdd : .winding)
        clips.append(1)

      case .clipStroke(_, let m, let s, let path):
        guard groups.contains(.paths) else { clips.append(0); continue }
        cx.saveGState()
        if !rects.isEmpty { applyRects(snapped: false) }
        cx.concatenate(cgAffine(m))
        cx.addPath(cgPath(path))
        apply(s, to: cx)
        cx.replacePathWithStrokedPath()
        cx.concatenate(cgAffine(m).inverted())
        cx.clip()
        clips.append(1)

      case .text(let b, let mode, let c, let s, let font, let m, let glyphs):
        if mode == .invisible { continue }
        guard groups.contains(.fonts) else {
          if mode == .clip { clips.append(0) } else { box(b, "text") }
          continue
        }
        let target = layers == 0 && rects.isEmpty && !clips.contains(1) ? bitmap : nil
        drawText(cx, res, b, mode, c, s, font, m, glyphs, &clips, target, box)
        // a text clip saved a state of its own: the pending rectangles go into it too
        if mode == .clip, !rects.isEmpty { applyRects(snapped: false) }

      case .figure(let b, let m, let fb, let pg, let path):
        guard groups.contains(.images), let page = Figures.page(path, pg) else { box(b, "figure"); continue }
        cx.saveGState()
        cx.concatenate(cgAffine(m))
        cx.clip(to: cgRect(fb))
        cx.drawPDFPage(page)
        cx.restoreGState()

      case .image(let b, let alpha, let m, let id):
        guard groups.contains(.images), drawImage(cx, res, id, m, alpha: alpha) else { box(b, "image"); continue }

      case .imageMask(let b, let c, let m, let id):
        guard groups.contains(.images) else { box(b, "image mask"); continue }
        cx.saveGState()
        guard clipToMask(cx, res, id, m) else { cx.restoreGState(); box(b, "image mask"); continue }
        cx.setFillColor(cgColor(c))
        cx.fill(cgRect(b).insetBy(dx: -2, dy: -2))
        cx.restoreGState()

      case .clipImageMask(_, let m, let id):
        guard groups.contains(.images) else { clips.append(0); continue }
        cx.saveGState()
        if !rects.isEmpty { applyRects(snapped: true) }
        guard clipToMask(cx, res, id, m) else { cx.restoreGState(); clips.append(0); continue }
        clips.append(1)

      case .shade(let b, let radial, let ext, let co, let m, let sb, let alpha, let smp):
        guard groups.contains(.paths) else { box(b, "shade"); continue }
        if !Drawer.cgShades, drawShade(cx, radial, ext, co, m, sb, alpha, smp, bbox: b) { continue }
        guard let sh = makeShading(radial, ext, co, smp) else { box(b, "shade"); continue }
        cx.saveGState()
        cx.concatenate(cgAffine(m))
        if sb.x1 > sb.x0, sb.y1 > sb.y0 { cx.clip(to: cgRect(sb)) }
        cx.setAlpha(CGFloat(alpha))
        cx.drawShading(sh)
        cx.restoreGState()

      case .popClip:
        if let k = clips.popLast() { if k == 1 { cx.restoreGState() } else if k == 2 { rects.removeLast() } }

      case .beginGroup(let b, _, _, let blend, let alpha):
        guard groups.contains(.transparency) else {
          if alpha < 1 || blend != 0 { st.unsupported["group", default: 0] += 1 }
          cx.saveGState()
          continue
        }
        cx.saveGState()
        cx.setAlpha(CGFloat(alpha))
        cx.setBlendMode(blendMode(blend))
        cx.beginTransparencyLayer(in: cgRect(b), auxiliaryInfo: nil)
        layers += 1

      case .endGroup:
        if groups.contains(.transparency) { cx.endTransparencyLayer(); layers -= 1 }
        cx.restoreGState()

      case .beginMask(let b, _, _):
        // soft masks: not yet. The masked content is drawn unmasked; the mask's area is reported.
        st.unsupported["soft mask", default: 0] += 1
        _ = b
        maskDepth = 1

      case .endMask:
        clips.append(0)

      case .beginTile(let b, _, _, _, _, _):
        box(b, "tile")
        tileDepth = 1

      case .endTile, .endTag, .beginTag, .unknown:
        continue

      case .unsupported(let b, let what):
        box(b, what)
      }
    }
    while let k = clips.popLast() { if k == 1 { cx.restoreGState() } }
    cx.restoreGState()
    return st
  }

  static func drawText(_ cx: CGContext, _ res: Resources, _ b: Rect, _ mode: TextMode, _ c: RGBA, _ s: Stroke?,
                       _ font: UInt32, _ m: (Float, Float, Float, Float), _ glyphs: [Glyph], _ clips: inout [UInt8], _ target: Bitmap?,
                       _ box: (Rect, String) -> Void) {
    let lin = CGAffineTransform(a: CGFloat(m.0), b: CGFloat(m.1), c: CGFloat(m.2), d: CGFloat(m.3), tx: 0, ty: 0)
    func at(_ g: Glyph) -> CGAffineTransform { lin.concatenating(CGAffineTransform(translationX: CGFloat(g.x), y: CGFloat(g.y))) }
    switch mode {
    case .fill:
      cx.setFillColor(cgColor(c))
      if !GlyphCache.on, case .sfnt? = res.list.fonts[font], let f = res.ctFont(font) {
        // Core Text draws the glyphs (its antialiasing, glyph cache): text matrix = glyph space → page
        cx.saveGState()
        for g in glyphs {
          var gid = CGGlyph(g.gid)
          var p = CGPoint.zero
          cx.textMatrix = at(g)
          CTFontDrawGlyphs(f, &gid, &p, 1, cx)
        }
        cx.restoreGState()
      } else {
        if case .missing? = res.list.fonts[font] { box(b, "type3 text"); return }
        if GlyphCache.on {
          // device space: glyph bitmaps copied 1:1 (GlyphCache)
          let dev = cx.ctm
          cx.saveGState()
          cx.concatenate(dev.inverted())
          cx.interpolationQuality = .none
          for g in glyphs {
            guard let gp = res.glyphPath(font, g.gid) else { continue }
            let m = at(g).concatenating(dev)
            if !GlyphCache.shared.draw(cx, target: target, path: gp, outline: res.outlineID(font, g.gid), m: m, color: c) {
              var mm = m
              if let p = gp.copy(using: &mm) { cx.addPath(p) }
              cx.fillPath(using: .winding)
            }
          }
          cx.restoreGState()
          return
        }
        // one fill per glyph: CG's rasteriser costs by the path's box, so a whole line in one path is slow
        for g in glyphs {
          guard let gp = res.glyphPath(font, g.gid) else { continue }
          cx.saveGState()
          cx.concatenate(at(g))
          cx.addPath(gp)
          cx.restoreGState()
          cx.fillPath(using: .winding)
        }
      }
    case .stroke, .fillStroke:
      let p = CGMutablePath()
      for g in glyphs { if let gp = res.glyphPath(font, g.gid) { p.addPath(gp, transform: at(g)) } }
      if mode == .fillStroke {
        cx.addPath(p); cx.setFillColor(cgColor(c)); cx.fillPath()
      }
      cx.saveGState()
      if let s { apply(s, to: cx) }
      cx.addPath(p)
      cx.setStrokeColor(cgColor(c))
      cx.strokePath()
      cx.restoreGState()
    case .clip:
      let p = CGMutablePath()
      for g in glyphs { if let gp = res.glyphPath(font, g.gid) { p.addPath(gp, transform: at(g)) } }
      cx.saveGState()
      cx.addPath(p)
      cx.clip()
      clips.append(1)
    case .invisible:
      break
    }
  }

  static func blendMode(_ b: UInt8) -> CGBlendMode {
    let modes: [CGBlendMode] = [.normal, .multiply, .screen, .overlay, .darken, .lighten, .colorDodge, .colorBurn,
                                .hardLight, .softLight, .difference, .exclusion, .hue, .saturation, .color, .luminosity]
    return Int(b) < modes.count ? modes[Int(b)] : .normal
  }

  /// A white sRGB bitmap of the page at `scale`, with the harness's context settings (harness/cgraster.swift):
  /// no font smoothing, subpixel positioning on, subpixel quantisation off.
  public static func raster(_ list: PageList, scale: CGFloat, groups: Groups = .built) -> (CGImage, DrawStats) {
    let w = max(1, Int((CGFloat(list.width) * scale).rounded())), h = max(1, Int((CGFloat(list.height) * scale).rounded()))
    let cx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                       bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    // white: every byte 255 (the skipped alpha byte too); a memset is ~4× cheaper than a CG fill of the page
    if let d = cx.data { memset(d, 255, cx.bytesPerRow * h) } else {
      cx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
      cx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    }
    cx.setAllowsFontSmoothing(false)
    cx.setShouldSmoothFonts(false)
    cx.setAllowsFontSubpixelPositioning(true)
    cx.setShouldSubpixelPositionFonts(true)
    cx.setAllowsFontSubpixelQuantization(false)
    cx.setShouldSubpixelQuantizeFonts(false)
    let iq = ProcessInfo.processInfo.environment["TAUDOT_INTERP"]
    cx.interpolationQuality = iq == "none" ? .none : iq == "low" ? .low : iq == "medium" ? .medium : iq == "high" ? .high : iq == "default" ? .default : .medium
    let st = draw(list, in: cx, scale: scale, height: CGFloat(h), groups: groups)
    return (cx.makeImage()!, st)
  }
}

/// The ink box of an op that only paints (no clip, group or mask state to keep): what culling may skip.
func paintBox(_ op: Op) -> Rect? {
  switch op {
  case .text(let b, let mode, _, _, _, _, _): return mode == .clip ? nil : b
  case .fill(let b, _, _, _, _), .stroke(let b, _, _, _, _), .rule(let b, _), .image(let b, _, _, _),
       .imageMask(let b, _, _, _), .shade(let b, _, _, _, _, _, _, _), .figure(let b, _, _, _, _):
    return b
  default: return nil
  }
}

/// Included PDF files, opened once per process and again when they change on disk.
enum Figures {
  private static var docs: [String: (mtime: Date, size: Int, doc: CGPDFDocument)] = [:]
  private static let lock = NSLock()

  static func page(_ path: String, _ n: Int) -> CGPDFPage? {
    lock.lock(); defer { lock.unlock() }
    let attrs = try? FileManager.default.attributesOfItem(atPath: path)
    let mtime = attrs?[.modificationDate] as? Date ?? .distantPast, size = attrs?[.size] as? Int ?? -1
    var doc = docs[path].flatMap { $0.mtime == mtime && $0.size == size ? $0.doc : nil }
    if doc == nil {
      doc = CGPDFDocument(URL(fileURLWithPath: path) as CFURL)
      if let d = doc { docs[path] = (mtime, size, d) }
    }
    return doc?.page(at: max(1, n))
  }
}
