// Box drawing (U+2500–257F), block elements (U+2580–259F) and sextants (U+1FB00–1FB3B) drawn to the exact cell
// rect, pixel-aligned, instead of from the font, whose glyphs don't fill a cell taller than the font's line (gaps
// between rows in the Claude logo, borders, Telescope). As kitty, Ghostty and Neovide do. Drawn into the glyph atlas
// slot (GlyphAtlas.rasterize), so it is cached per cell size like any glyph.
//
// Box drawing's arms and weights are read from the characters' Unicode names ("BOX DRAWINGS DOWN SINGLE AND RIGHT
// DOUBLE"), which spell the shape out.
import CoreGraphics
import Foundation

enum BoxDrawing {
  static func handles(_ s: String) -> Bool {
    guard let u = single(s) else { return false }
    return (0x2500...0x259F).contains(u) || (0x1FB00...0x1FB3B).contains(u)
  }

  static func single(_ s: String) -> UInt32? {
    let us = s.unicodeScalars
    guard us.count == 1, let u = us.first else { return nil }
    return u.value
  }

  /// Draw `s` in white into `ctx` (bottom-left origin, pixels), filling the cell `cell`.
  static func draw(_ s: String, in ctx: CGContext, cell: CGRect, scale: CGFloat) {
    guard let u = single(s) else { return }
    let d = Drawer(ctx: ctx, cell: cell, scale: scale)
    switch u {
    case 0x2580...0x259F: d.block(u)
    case 0x1FB00...0x1FB3B: d.sextant(u)
    default: d.box(u)
    }
  }

  /// Arms (left, right, up, down): 0 none, 1 light, 2 heavy, 3 double. From the Unicode name; cached.
  nonisolated(unsafe) static var armsCache: [UInt32: [Int]] = [:]
  static func arms(_ u: UInt32) -> [Int]? {
    if let a = armsCache[u] { return a }
    guard let name = Unicode.Scalar(u)?.properties.name, name.hasPrefix("BOX DRAWINGS ") else { return nil }
    let words = name.dropFirst("BOX DRAWINGS ".count).split(separator: " ").map(String.init)
    var a = [0, 0, 0, 0]
    let weight = ["LIGHT": 1, "SINGLE": 1, "HEAVY": 2, "DOUBLE": 3]
    let dirs: [String: [Int]] = ["LEFT": [0], "RIGHT": [1], "UP": [2], "DOWN": [3], "HORIZONTAL": [0, 1], "VERTICAL": [2, 3]]
    // "LIGHT DOWN AND RIGHT" (weight first, kept for later directions) or "DOWN LIGHT AND RIGHT HEAVY" (weight after).
    let prefix = weight[words.first ?? ""] != nil
    var current = 0
    var pending: [Int] = []
    for w in words {
      if let k = weight[w] {
        if !pending.isEmpty { for i in pending { a[i] = k }; pending = [] } else { current = k }
      } else if let ds = dirs[w] {
        if prefix && current != 0 { for i in ds { a[i] = current } } else { pending += ds }
      }
    }
    armsCache[u] = a
    return a
  }
}

private struct Drawer {
  let ctx: CGContext
  let cell: CGRect
  let scale: CGFloat
  var w: CGFloat { cell.width }
  var h: CGFloat { cell.height }
  /// Line thickness: light ~1 pt (whole pixels), heavy twice that.
  var light: CGFloat { max(1, (scale * 1).rounded()) }
  var heavy: CGFloat { light * 2 }

  /// Fill a rect given from the cell's top-left, y down.
  func fill(_ x: CGFloat, _ y: CGFloat, _ rw: CGFloat, _ rh: CGFloat, alpha: CGFloat = 1) {
    guard rw > 0, rh > 0 else { return }
    ctx.setFillColor(CGColor(gray: 1, alpha: alpha))
    ctx.fill(CGRect(x: cell.minX + x, y: cell.maxY - y - rh, width: rw, height: rh))
  }

  // MARK: blocks

  func block(_ u: UInt32) {
    ctx.setShouldAntialias(false)
    func ry(_ k: CGFloat) -> CGFloat { (h * k / 8).rounded() }
    func rx(_ k: CGFloat) -> CGFloat { (w * k / 8).rounded() }
    let hx = rx(4), hy = ry(4)
    switch u {
    case 0x2580: fill(0, 0, w, hy)                                      // ▀
    case 0x2581...0x2587: let t = ry(CGFloat(u - 0x2580)); fill(0, h - t, w, t)  // ▁..▇
    case 0x2588: fill(0, 0, w, h)                                       // █
    case 0x2589...0x258F: fill(0, 0, rx(CGFloat(0x2590 - u)), h)        // ▉..▏
    case 0x2590: fill(hx, 0, w - hx, h)                                 // ▐
    case 0x2591: fill(0, 0, w, h, alpha: 0.25)                          // ░
    case 0x2592: fill(0, 0, w, h, alpha: 0.5)                           // ▒
    case 0x2593: fill(0, 0, w, h, alpha: 0.75)                          // ▓
    case 0x2594: fill(0, 0, w, ry(1))                                   // ▔
    case 0x2595: let t = rx(1); fill(w - t, 0, t, h)                    // ▕
    default:
      // Quadrants ▖▗▘▙▚▛▜▝▞▟: upper-left, upper-right, lower-left, lower-right.
      let q: [UInt32: (Bool, Bool, Bool, Bool)] = [
        0x2596: (false, false, true, false), 0x2597: (false, false, false, true), 0x2598: (true, false, false, false),
        0x2599: (true, false, true, true), 0x259A: (true, false, false, true), 0x259B: (true, true, true, false),
        0x259C: (true, true, false, true), 0x259D: (false, true, false, false), 0x259E: (false, true, true, false),
        0x259F: (false, true, true, true),
      ]
      guard let (ul, ur, ll, lr) = q[u] else { return }
      if ul { fill(0, 0, hx, hy) }
      if ur { fill(hx, 0, w - hx, hy) }
      if ll { fill(0, hy, hx, h - hy) }
      if lr { fill(hx, hy, w - hx, h - hy) }
    }
  }

  /// Sextants: a 2 × 3 grid, U+1FB00 + mask − 1 for masks 1–62 without 21 (▌) and 42 (▐).
  func sextant(_ u: UInt32) {
    ctx.setShouldAntialias(false)
    var mask = Int(u - 0x1FB00) + 1
    if mask >= 21 { mask += 1 }
    if mask >= 42 { mask += 1 }
    let xs = [0, (w / 2).rounded(), w], ys = [0, (h / 3).rounded(), (2 * h / 3).rounded(), h]
    for bit in 0..<6 where mask & (1 << bit) != 0 {
      let c = bit % 2, r = bit / 2
      fill(xs[c], ys[r], xs[c + 1] - xs[c], ys[r + 1] - ys[r])
    }
  }

  // MARK: box drawing

  func box(_ u: UInt32) {
    // Dashes, arcs and diagonals have their own shapes; everything else is arms from the centre.
    switch u {
    case 0x2504, 0x2505, 0x2508, 0x2509, 0x254C, 0x254D: dashes(horizontal: true, n: dashCount(u), t: u & 1 == 1 ? heavy : light); return
    case 0x2506, 0x2507, 0x250A, 0x250B, 0x254E, 0x254F: dashes(horizontal: false, n: dashCount(u), t: u & 1 == 1 ? heavy : light); return
    case 0x256D...0x2570: arc(u); return
    case 0x2571...0x2573: diagonal(u); return
    default: break
    }
    guard let a = BoxDrawing.arms(u) else { return }
    arms(a)
  }

  func dashCount(_ u: UInt32) -> Int {
    switch u { case 0x2504...0x2507: return 3; case 0x2508...0x250B: return 4; default: return 2 }
  }

  func dashes(horizontal: Bool, n: Int, t: CGFloat) {
    ctx.setShouldAntialias(false)
    let len = horizontal ? w : h
    let gap = max(1, (len / CGFloat(n * 4)).rounded())
    for i in 0..<n {
      let a = (len * CGFloat(i) / CGFloat(n)).rounded(), b = (len * CGFloat(i + 1) / CGFloat(n)).rounded() - gap
      if horizontal { fill(a, ((h - t) / 2).rounded(.down), b - a, t) } else { fill(((w - t) / 2).rounded(.down), a, t, b - a) }
    }
  }

  /// Lines from the centre to the edges: light, heavy, or double (two light lines a light line apart).
  func arms(_ a: [Int]) {
    ctx.setShouldAntialias(false)
    let t = light
    func thick(_ k: Int) -> CGFloat { k == 2 ? heavy : t }
    // A single (light/heavy) line's start across its axis; double lines: the pair's two starts.
    func lineX(_ k: Int) -> CGFloat { ((w - thick(k)) / 2).rounded(.down) }
    func lineY(_ k: Int) -> CGFloat { ((h - thick(k)) / 2).rounded(.down) }
    let dx = (((w - 3 * t) / 2).rounded(.down), ((w - 3 * t) / 2).rounded(.down) + 2 * t)  // left, right vertical lines
    let dy = (((h - 3 * t) / 2).rounded(.down), ((h - 3 * t) / 2).rounded(.down) + 2 * t)  // top, bottom horizontal lines
    let (L, R, U, D) = (a[0], a[1], a[2], a[3])
    let vert = max(U, D), horiz = max(L, R)
    // The span the vertical arms take across x (for horizontal arms to reach), and vice versa.
    func vSpan() -> (CGFloat, CGFloat) {
      if vert == 3 { return (dx.0, dx.1 + t) }
      if vert == 0 { return ((w / 2).rounded(.down), (w / 2).rounded(.down)) }
      let k = max(U == 3 ? 0 : U, D == 3 ? 0 : D)
      return (lineX(k), lineX(k) + thick(k))
    }
    func hSpan() -> (CGFloat, CGFloat) {
      if horiz == 3 { return (dy.0, dy.1 + t) }
      if horiz == 0 { return ((h / 2).rounded(.down), (h / 2).rounded(.down)) }
      let k = max(L == 3 ? 0 : L, R == 3 ? 0 : R)
      return (lineY(k), lineY(k) + thick(k))
    }
    let vs = vSpan(), hs = hSpan()
    // Horizontal arms.
    for (side, k) in [(0, L), (1, R)] where k != 0 {
      if k != 3 {
        let y = lineY(k)
        if side == 0 { fill(0, y, vs.1, thick(k)) } else { fill(vs.0, y, w - vs.0, thick(k)) }
        continue
      }
      // Double: each line stops at the perpendicular arm on its own side, else runs to the far side's.
      for (line, y) in [(2, dy.0), (3, dy.1)] {   // the top line faces up (2), the bottom one down (3)
        let near = a[line], far = a[line == 2 ? 3 : 2]
        var reach: CGFloat
        if near == 3 { reach = side == 0 ? dx.0 + t : dx.1 }
        else if near != 0 { reach = side == 0 ? vs.1 : vs.0 }
        else if far != 0 { reach = side == 0 ? vs.1 : vs.0 }
        else { reach = side == 0 ? dx.1 + t : dx.0 }
        if side == 0 { fill(0, y, reach, t) } else { fill(reach, y, w - reach, t) }
      }
    }
    // Vertical arms.
    for (side, k) in [(2, U), (3, D)] where k != 0 {
      if k != 3 {
        let x = lineX(k)
        if side == 2 { fill(x, 0, thick(k), hs.1) } else { fill(x, hs.0, thick(k), h - hs.0) }
        continue
      }
      for (line, x) in [(0, dx.0), (1, dx.1)] {   // the left line faces left (0), the right one right (1)
        let near = a[line], far = a[line == 0 ? 1 : 0]
        var reach: CGFloat
        if near == 3 { reach = side == 2 ? dy.0 + t : dy.1 }
        else if near != 0 { reach = side == 2 ? hs.1 : hs.0 }
        else if far != 0 { reach = side == 2 ? hs.1 : hs.0 }
        else { reach = side == 2 ? dy.1 + t : dy.0 }
        if side == 2 { fill(x, 0, t, reach) } else { fill(x, reach, t, h - reach) }
      }
    }
  }

  /// ╭ ╮ ╯ ╰: a straight run from each edge into a quarter circle, centred on the light lines.
  func arc(_ u: UInt32) {
    ctx.setShouldAntialias(true)
    let t = light
    let cx = ((w - t) / 2).rounded(.down) + t / 2, cy = ((h - t) / 2).rounded(.down) + t / 2
    let r = min(w, h) / 2
    // In CG coordinates (y up): the cell's centre and edges.
    let X = cell.minX + cx, Y = cell.maxY - cy
    let p = CGMutablePath()
    switch u {
    case 0x256D: p.move(to: CGPoint(x: X, y: cell.minY)); p.addArc(tangent1End: CGPoint(x: X, y: Y), tangent2End: CGPoint(x: cell.maxX, y: Y), radius: r); p.addLine(to: CGPoint(x: cell.maxX, y: Y))  // ╭ down and right
    case 0x256E: p.move(to: CGPoint(x: X, y: cell.minY)); p.addArc(tangent1End: CGPoint(x: X, y: Y), tangent2End: CGPoint(x: cell.minX, y: Y), radius: r); p.addLine(to: CGPoint(x: cell.minX, y: Y))  // ╮ down and left
    case 0x256F: p.move(to: CGPoint(x: X, y: cell.maxY)); p.addArc(tangent1End: CGPoint(x: X, y: Y), tangent2End: CGPoint(x: cell.minX, y: Y), radius: r); p.addLine(to: CGPoint(x: cell.minX, y: Y))  // ╯ up and left
    default: p.move(to: CGPoint(x: X, y: cell.maxY)); p.addArc(tangent1End: CGPoint(x: X, y: Y), tangent2End: CGPoint(x: cell.maxX, y: Y), radius: r); p.addLine(to: CGPoint(x: cell.maxX, y: Y))  // ╰ up and right
    }
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
    ctx.setLineWidth(t)
    ctx.setLineCap(.butt)
    ctx.addPath(p)
    ctx.strokePath()
  }

  /// ╱ ╲ ╳ corner to corner.
  func diagonal(_ u: UInt32) {
    ctx.setShouldAntialias(true)
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
    ctx.setLineWidth(light)
    let tl = CGPoint(x: cell.minX, y: cell.maxY), tr = CGPoint(x: cell.maxX, y: cell.maxY)
    let bl = CGPoint(x: cell.minX, y: cell.minY), br = CGPoint(x: cell.maxX, y: cell.minY)
    if u != 0x2572 { ctx.move(to: tr); ctx.addLine(to: bl) }
    if u != 0x2571 { ctx.move(to: tl); ctx.addLine(to: br) }
    ctx.strokePath()
  }
}
