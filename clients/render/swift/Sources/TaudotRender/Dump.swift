// A JSON dump of a list for debugging (`taudot-raster LIST --dump`): one font, image or op per line.
import Foundation

public enum Dump {
  static func s(_ x: String) -> String {
    var o = "\""
    for u in x.unicodeScalars {
      switch u {
      case "\"": o += "\\\""
      case "\\": o += "\\\\"
      case "\n": o += "\\n"
      default: if u.value < 0x20 { o += String(format: "\\u%04x", u.value) } else { o.unicodeScalars.append(u) }
      }
    }
    return o + "\""
  }
  static func n(_ f: Float) -> String { f == f.rounded() && abs(f) < 1e7 ? String(Int(f)) : String(format: "%.3f", f) }
  static func r(_ b: Rect) -> String { "[\(n(b.x0)),\(n(b.y0)),\(n(b.x1)),\(n(b.y1))]" }
  static func m(_ m: Matrix) -> String { "[\(n(m.a)),\(n(m.b)),\(n(m.c)),\(n(m.d)),\(n(m.e)),\(n(m.f))]" }
  static func c(_ c: RGBA) -> String { "[\(n(c.r)),\(n(c.g)),\(n(c.b)),\(n(c.a))]" }
  static func p(_ path: [PathCmd]) -> String {
    "\"" + path.map { c -> String in
      switch c {
      case .move(let x, let y): return "M \(n(x)) \(n(y))"
      case .line(let x, let y): return "L \(n(x)) \(n(y))"
      case .quad(let a, let b, let x, let y): return "Q \(n(a)) \(n(b)) \(n(x)) \(n(y))"
      case .curve(let a, let b, let c, let d, let x, let y): return "C \(n(a)) \(n(b)) \(n(c)) \(n(d)) \(n(x)) \(n(y))"
      case .close: return "Z"
      }
    }.joined(separator: " ") + "\""
  }
  static func st(_ s: Stroke) -> String {
    "{\"w\":\(n(s.width)),\"cap\":\(s.cap),\"join\":\(s.join),\"miter\":\(n(s.miter)),\"dash\":[\(s.dashes.map(n).joined(separator: ","))]}"
  }

  public static func op(_ op: Op) -> String {
    switch op {
    case .text(let b, let mode, let col, _, let f, let mm, let g):
      let text = g.map(\.text).joined()
      return "{\"op\":\"text\",\"bbox\":\(r(b)),\"mode\":\(mode.rawValue),\"color\":\(c(col)),\"font\":\(f),\"m\":[\(n(mm.0)),\(n(mm.1)),\(n(mm.2)),\(n(mm.3))],\"n\":\(g.count),\"text\":\(s(text)),\"glyphs\":[\(g.map { "[\($0.gid),\(n($0.x)),\(n($0.y)),\(n($0.adv))]" }.joined(separator: ","))]}"
    case .fill(let b, let eo, let col, let mm, let path):
      return "{\"op\":\"fill\",\"bbox\":\(r(b)),\"eo\":\(eo),\"color\":\(c(col)),\"m\":\(m(mm)),\"path\":\(p(path))}"
    case .stroke(let b, let col, let mm, let sk, let path):
      return "{\"op\":\"stroke\",\"bbox\":\(r(b)),\"color\":\(c(col)),\"m\":\(m(mm)),\"stroke\":\(st(sk)),\"path\":\(p(path))}"
    case .figure(let b, let mm, let fb, let pg, let path):
      return "{\"op\":\"figure\",\"bbox\":\(r(b)),\"m\":\(m(mm)),\"box\":\(r(fb)),\"page\":\(pg),\"path\":\(s(path))}"
    case .rule(let b, let col): return "{\"op\":\"rule\",\"bbox\":\(r(b)),\"color\":\(c(col))}"
    case .image(let b, let a, let mm, let i): return "{\"op\":\"image\",\"bbox\":\(r(b)),\"alpha\":\(n(a)),\"m\":\(m(mm)),\"image\":\(i)}"
    case .imageMask(let b, let col, let mm, let i): return "{\"op\":\"image_mask\",\"bbox\":\(r(b)),\"color\":\(c(col)),\"m\":\(m(mm)),\"image\":\(i)}"
    case .clipPath(let b, let eo, let mm, let path): return "{\"op\":\"clip_path\",\"bbox\":\(r(b)),\"eo\":\(eo),\"m\":\(m(mm)),\"path\":\(p(path))}"
    case .clipStroke(let b, let mm, let sk, let path): return "{\"op\":\"clip_stroke\",\"bbox\":\(r(b)),\"m\":\(m(mm)),\"stroke\":\(st(sk)),\"path\":\(p(path))}"
    case .clipImageMask(let b, let mm, let i): return "{\"op\":\"clip_image_mask\",\"bbox\":\(r(b)),\"m\":\(m(mm)),\"image\":\(i)}"
    case .shade(let b, let radial, let e, let co, let mm, _, let a, let smp):
      return "{\"op\":\"shade\",\"bbox\":\(r(b)),\"type\":\"\(radial ? "radial" : "axial")\",\"extend\":[\(e.0),\(e.1)],\"coords\":[\(co.map(n).joined(separator: ","))],\"m\":\(m(mm)),\"alpha\":\(n(a)),\"first\":\(Array(smp.prefix(4))),\"last\":\(Array(smp.suffix(4)))}"
    case .popClip: return "{\"op\":\"pop_clip\"}"
    case .beginGroup(let b, let iso, let ko, let bl, let a):
      return "{\"op\":\"begin_group\",\"bbox\":\(r(b)),\"isolated\":\(iso),\"knockout\":\(ko),\"blend\":\(bl),\"alpha\":\(n(a))}"
    case .endGroup: return "{\"op\":\"end_group\"}"
    case .beginMask(let b, let l, _): return "{\"op\":\"begin_mask\",\"bbox\":\(r(b)),\"luminosity\":\(l)}"
    case .endMask: return "{\"op\":\"end_mask\"}"
    case .beginTile(let b, _, _, let xs, let ys, let mm):
      return "{\"op\":\"begin_tile\",\"bbox\":\(r(b)),\"xstep\":\(n(xs)),\"ystep\":\(n(ys)),\"m\":\(m(mm))}"
    case .endTile: return "{\"op\":\"end_tile\"}"
    case .beginTag(let w): return "{\"op\":\"begin_tag\",\"what\":\(s(w))}"
    case .endTag: return "{\"op\":\"end_tag\"}"
    case .unsupported(let b, let w): return "{\"op\":\"unsupported\",\"bbox\":\(r(b)),\"what\":\(s(w))}"
    case .unknown(let k): return "{\"op\":\"unknown\",\"kind\":\(k)}"
    }
  }

  public static func json(_ l: PageList) -> String {
    var lines = ["{\"page\":\(l.page),\"w\":\(n(l.width)),\"h\":\(n(l.height)),"]
    lines.append("\"fonts\":{")
    lines.append(l.fonts.keys.sorted().map { id -> String in
      switch l.fonts[id]! {
      case .sfnt(let name, let path, let i): return "\"\(id)\":{\"type\":\"sfnt\",\"name\":\(s(name)),\"path\":\(s(path)),\"index\":\(i)}"
      case .outlines(let name, let g): return "\"\(id)\":{\"type\":\"outlines\",\"name\":\(s(name)),\"glyphs\":\(g.count)}"
      case .missing(let name): return "\"\(id)\":{\"type\":\"missing\",\"name\":\(s(name))}"
      }
    }.joined(separator: ",\n"))
    lines.append("},\"images\":{")
    lines.append(l.images.keys.sorted().map { id -> String in
      let im = l.images[id]!
      let (f, k): (String, Int) = {
        switch im.data { case .png(let d): return ("png", d.count); case .jpeg(let d): return ("jpeg", d.count); case .rgba(let d): return ("rgba", d.count) }
      }()
      return "\"\(id)\":{\"w\":\(im.w),\"h\":\(im.h),\"format\":\"\(f)\",\"bytes\":\(k)}"
    }.joined(separator: ",\n"))
    lines.append("},\"ops\":[")
    lines.append(l.ops.map(op).joined(separator: ",\n"))
    lines.append("]}")
    return lines.joined(separator: "\n")
  }
}
