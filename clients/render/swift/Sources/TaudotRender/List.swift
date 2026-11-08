// The display list as Swift values, read from the binary format in clients/render/dlist.md.
import Foundation

public typealias Rect = (x0: Float, y0: Float, x1: Float, y1: Float)

public struct Matrix: Equatable {
  public var a, b, c, d, e, f: Float
  public init(_ a: Float, _ b: Float, _ c: Float, _ d: Float, _ e: Float, _ f: Float) {
    self.a = a; self.b = b; self.c = c; self.d = d; self.e = e; self.f = f
  }
}

public struct RGBA: Equatable {
  public var r, g, b, a: Float
}

public enum PathCmd: Equatable {
  case move(Float, Float)
  case line(Float, Float)
  case quad(Float, Float, Float, Float)
  case curve(Float, Float, Float, Float, Float, Float)
  case close
}

public struct Stroke: Equatable {
  public var width: Float
  public var cap: UInt8
  public var join: UInt8
  public var miter: Float
  public var dashPhase: Float
  public var dashes: [Float]
}

public struct Glyph: Equatable {
  public var gid: UInt32
  public var x, y, adv: Float
  public var text: String
}

public enum TextMode: UInt8 { case fill = 0, stroke = 1, fillStroke = 2, clip = 3, invisible = 4 }

public enum Font {
  case sfnt(name: String, path: String, index: UInt32)
  case outlines(name: String, glyphs: [UInt32: [PathCmd]])
  case missing(name: String)

  public var name: String {
    switch self {
    case .sfnt(let n, _, _), .outlines(let n, _), .missing(let n): return n
    }
  }
}

public enum ImageData {
  case png(Data), jpeg(Data), rgba(Data)
}

public struct Image {
  public var w, h: Int
  public var data: ImageData
  /// a hash of every byte (format, size, data), computed when the list is read: identifies the image across lists
  public var key: UInt64 = 0
}

/// A fast 64-bit hash of all of `d` (8 bytes at a time, multiply–xorshift mixing). Swift's own Data hash looks at a
/// prefix only, so images that start alike (RGBA renders of one figure) would collide.
func contentHash(_ d: Data, seed: UInt64) -> UInt64 {
  var h: UInt64 = seed ^ (UInt64(d.count) &* 0x9E3779B97F4A7C15)
  d.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
    let n = p.count / 8
    for i in 0..<n {
      var k = p.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self)
      k &*= 0xff51afd7ed558ccd; k ^= k >> 33
      h = (h ^ k) &* 0xc4ceb9fe1a85ec53; h ^= h >> 29
    }
    for i in (n * 8)..<p.count { h = (h ^ UInt64(p[i])) &* 0x100000001b3 }
  }
  h ^= h >> 32
  return h
}

public enum Op {
  case text(bbox: Rect, mode: TextMode, color: RGBA, stroke: Stroke?, font: UInt32, m: (Float, Float, Float, Float), glyphs: [Glyph])
  case fill(bbox: Rect, evenOdd: Bool, color: RGBA, m: Matrix, path: [PathCmd])
  case stroke(bbox: Rect, color: RGBA, m: Matrix, stroke: Stroke, path: [PathCmd])
  case rule(bbox: Rect, color: RGBA)
  case image(bbox: Rect, alpha: Float, m: Matrix, image: UInt32)
  case imageMask(bbox: Rect, color: RGBA, m: Matrix, image: UInt32)
  /// a page of a PDF file (an included figure), drawn whole: `m` maps its PDF space to the page, clipped to `box`
  case figure(bbox: Rect, m: Matrix, box: Rect, page: Int, path: String)
  case shade(bbox: Rect, radial: Bool, extend: (Bool, Bool), coords: [Float], m: Matrix, shadeBox: Rect, alpha: Float, samples: [UInt8])
  case clipPath(bbox: Rect, evenOdd: Bool, m: Matrix, path: [PathCmd])
  case clipStroke(bbox: Rect, m: Matrix, stroke: Stroke, path: [PathCmd])
  case clipImageMask(bbox: Rect, m: Matrix, image: UInt32)
  case popClip
  case beginGroup(bbox: Rect, isolated: Bool, knockout: Bool, blend: UInt8, alpha: Float)
  case endGroup
  case beginMask(bbox: Rect, luminosity: Bool, backdrop: (Float, Float, Float))
  case endMask
  case beginTile(bbox: Rect, area: Rect, view: Rect, xstep: Float, ystep: Float, m: Matrix)
  case endTile
  case beginTag(String)
  case endTag
  case unsupported(bbox: Rect, what: String)
  case unknown(kind: UInt8)
}

public struct PageList {
  public var page: Int = 0
  public var width: Float = 0, height: Float = 0
  public var fonts: [UInt32: Font] = [:]
  public var images: [UInt32: Image] = [:]
  public var ops: [Op] = []
}

public enum ListError: Error, CustomStringConvertible {
  case badMagic, badVersion(UInt32), truncated(at: Int)
  public var description: String {
    switch self {
    case .badMagic: return "not a Taudot display list"
    case .badVersion(let v): return "unsupported list version \(v)"
    case .truncated(let at): return "list truncated at byte \(at)"
    }
  }
}

struct Reader {
  let bytes: [UInt8]
  var at: Int
  let end: Int

  init(_ bytes: [UInt8], from: Int = 0, to: Int? = nil) {
    self.bytes = bytes; at = from; end = to ?? bytes.count
  }

  mutating func need(_ n: Int) throws { if at + n > end { throw ListError.truncated(at: at) } }
  mutating func u8() throws -> UInt8 { try need(1); defer { at += 1 }; return bytes[at] }
  mutating func u16() throws -> UInt16 {
    try need(2); defer { at += 2 }
    return UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8
  }
  mutating func u32() throws -> UInt32 {
    try need(4); defer { at += 4 }
    return UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
  }
  mutating func f32() throws -> Float { Float(bitPattern: try u32()) }
  mutating func str() throws -> String {
    let n = Int(try u16())
    try need(n); defer { at += n }
    return String(decoding: bytes[at..<at + n], as: UTF8.self)
  }
  mutating func data(_ n: Int) throws -> Data {
    try need(n); defer { at += n }
    return Data(bytes[at..<at + n])
  }
  mutating func rect() throws -> Rect { (try f32(), try f32(), try f32(), try f32()) }
  mutating func matrix() throws -> Matrix { Matrix(try f32(), try f32(), try f32(), try f32(), try f32(), try f32()) }
  mutating func rgba() throws -> RGBA { RGBA(r: try f32(), g: try f32(), b: try f32(), a: try f32()) }
  mutating func stroke() throws -> Stroke {
    let w = try f32(), cap = try u8(), join = try u8(), miter = try f32(), phase = try f32()
    let n = Int(try u16())
    var d: [Float] = []
    d.reserveCapacity(n)
    for _ in 0..<n { d.append(try f32()) }
    return Stroke(width: w, cap: cap, join: join, miter: miter, dashPhase: phase, dashes: d)
  }
  mutating func path() throws -> [PathCmd] {
    let ncmd = Int(try u32()), ncoord = Int(try u32())
    try need(ncmd + 4 * ncoord)
    let cmds = at
    at += ncmd
    var out: [PathCmd] = []
    out.reserveCapacity(ncmd)
    for i in 0..<ncmd {
      switch bytes[cmds + i] {
      case UInt8(ascii: "M"): out.append(.move(try f32(), try f32()))
      case UInt8(ascii: "L"): out.append(.line(try f32(), try f32()))
      case UInt8(ascii: "Q"): out.append(.quad(try f32(), try f32(), try f32(), try f32()))
      case UInt8(ascii: "C"): out.append(.curve(try f32(), try f32(), try f32(), try f32(), try f32(), try f32()))
      default: out.append(.close)
      }
    }
    return out
  }
}

extension PageList {
  public init(contentsOf url: URL) throws {
    try self.init(bytes: [UInt8](try Data(contentsOf: url)))
  }

  public init(bytes: [UInt8]) throws {
    var r = Reader(bytes)
    guard bytes.count >= 8, bytes[0..<4].elementsEqual([0x54, 0x44, 0x4c, 0]) else { throw ListError.badMagic }
    r.at = 4
    let v = try r.u32()
    guard v == 1 || v == 2 else { throw ListError.badVersion(v) }
    while r.at < bytes.count {
      let kind = try r.u8()
      let len = Int(try r.u32())
      try r.need(len)
      var p = Reader(bytes, from: r.at, to: r.at + len)
      r.at += len
      switch kind {
      case 0x00: return
      case 0x01:
        page = Int(try p.u32()); width = try p.f32(); height = try p.f32()
      case 0x02:
        let id = try p.u32(), type = try p.u8(), name = try p.str()
        switch type {
        case 1: fonts[id] = .sfnt(name: name, path: try p.str(), index: try p.u32())
        case 2:
          var g: [UInt32: [PathCmd]] = [:]
          for _ in 0..<Int(try p.u32()) { let gid = try p.u32(); g[gid] = try p.path() }
          fonts[id] = .outlines(name: name, glyphs: g)
        default: fonts[id] = .missing(name: name)
        }
      case 0x03:
        let id = try p.u32(), w = Int(try p.u32()), h = Int(try p.u32()), fmt = try p.u8()
        let d = try p.data(Int(try p.u32()))
        var im = Image(w: w, h: h, data: fmt == 1 ? .png(d) : fmt == 2 ? .jpeg(d) : .rgba(d))
        im.key = contentHash(d, seed: UInt64(fmt) << 48 ^ UInt64(w) << 24 ^ UInt64(h))
        images[id] = im
      default:
        ops.append(try Self.op(kind, &p))
      }
    }
  }

  static func op(_ kind: UInt8, _ p: inout Reader) throws -> Op {
    guard (0x10...0x3f).contains(kind) else { return .unknown(kind: kind) }
    let bbox = try p.rect()
    switch kind {
    case 0x10:
      let mode = TextMode(rawValue: try p.u8()) ?? .fill
      let color = try p.rgba()
      let stroke = mode == .stroke ? try p.stroke() : nil
      let font = try p.u32()
      let m = (try p.f32(), try p.f32(), try p.f32(), try p.f32())
      let n = Int(try p.u32())
      var g: [Glyph] = []
      g.reserveCapacity(n)
      for _ in 0..<n { g.append(Glyph(gid: try p.u32(), x: try p.f32(), y: try p.f32(), adv: try p.f32(), text: try p.str())) }
      return .text(bbox: bbox, mode: mode, color: color, stroke: stroke, font: font, m: m, glyphs: g)
    case 0x11:
      return .fill(bbox: bbox, evenOdd: try p.u8() != 0, color: try p.rgba(), m: try p.matrix(), path: try p.path())
    case 0x12:
      return .stroke(bbox: bbox, color: try p.rgba(), m: try p.matrix(), stroke: try p.stroke(), path: try p.path())
    case 0x13: return .rule(bbox: bbox, color: try p.rgba())
    case 0x14: return .image(bbox: bbox, alpha: try p.f32(), m: try p.matrix(), image: try p.u32())
    case 0x15: return .imageMask(bbox: bbox, color: try p.rgba(), m: try p.matrix(), image: try p.u32())
    case 0x16:
      let t = try p.u8(), e0 = try p.u8() != 0, e1 = try p.u8() != 0
      var c: [Float] = []
      for _ in 0..<6 { c.append(try p.f32()) }
      let m = try p.matrix(), sb = try p.rect(), a = try p.f32()
      let n = Int(try p.u16())
      let d = try p.data(n * 4)
      return .shade(bbox: bbox, radial: t == 3, extend: (e0, e1), coords: c, m: m, shadeBox: sb, alpha: a, samples: [UInt8](d))
    case 0x17:
      let m = try p.matrix(), fb = try p.rect(), pg = Int(try p.u32())
      return .figure(bbox: bbox, m: m, box: fb, page: pg, path: try p.str())
    case 0x20: return .clipPath(bbox: bbox, evenOdd: try p.u8() != 0, m: try p.matrix(), path: try p.path())
    case 0x21: return .clipStroke(bbox: bbox, m: try p.matrix(), stroke: try p.stroke(), path: try p.path())
    case 0x22: return .clipImageMask(bbox: bbox, m: try p.matrix(), image: try p.u32())
    case 0x2f: return .popClip
    case 0x30:
      return .beginGroup(bbox: bbox, isolated: try p.u8() != 0, knockout: try p.u8() != 0, blend: try p.u8(), alpha: try p.f32())
    case 0x31: return .endGroup
    case 0x32: return .beginMask(bbox: bbox, luminosity: try p.u8() != 0, backdrop: (try p.f32(), try p.f32(), try p.f32()))
    case 0x33: return .endMask
    case 0x34:
      return .beginTile(bbox: bbox, area: try p.rect(), view: try p.rect(), xstep: try p.f32(), ystep: try p.f32(), m: try p.matrix())
    case 0x35: return .endTile
    case 0x36: return .beginTag(try p.str())
    case 0x37: return .endTag
    case 0x3f: return .unsupported(bbox: bbox, what: try p.str())
    default: return .unknown(kind: kind)
    }
  }
}
