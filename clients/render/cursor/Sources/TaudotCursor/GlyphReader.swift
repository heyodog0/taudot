import Foundation

/// A fast reader for the `glyphs` file: a byte scanner for its one shape. JSONDecoder takes ~12 ms on a page of
/// 3,000 glyphs, this ~1 ms; the latency path after each typeset reads the page in view.
struct GlyphReader {
  let p: UnsafeBufferPointer<UInt8>
  var i = 0

  struct Bad: Error {}

  mutating func ws() { while i < p.count, p[i] == 32 || p[i] == 10 || p[i] == 13 || p[i] == 9 { i += 1 } }
  mutating func expect(_ c: UInt8) throws { ws(); guard i < p.count, p[i] == c else { throw Bad() }; i += 1 }
  mutating func peek() -> UInt8 { ws(); return i < p.count ? p[i] : 0 }

  mutating func number() throws -> Double {
    ws()
    var neg = false, v = 0.0, frac = 0.0, scale = 1.0, seen = false
    if i < p.count, p[i] == 45 { neg = true; i += 1 }
    while i < p.count, p[i] >= 48, p[i] <= 57 { v = v * 10 + Double(p[i] - 48); i += 1; seen = true }
    if i < p.count, p[i] == 46 {
      i += 1
      while i < p.count, p[i] >= 48, p[i] <= 57 { scale /= 10; frac += Double(p[i] - 48) * scale; i += 1; seen = true }
    }
    if i < p.count, p[i] == 101 || p[i] == 69 {  // exponent: rare, fall back
      let start = i
      i += 1
      while i < p.count, (p[i] >= 48 && p[i] <= 57) || p[i] == 43 || p[i] == 45 { i += 1 }
      let e = Double(String(decoding: UnsafeBufferPointer(rebasing: p[(start + 1)..<i]), as: UTF8.self)) ?? 0
      v = (v + frac) * pow(10, e)
      frac = 0
    }
    guard seen else { throw Bad() }
    return neg ? -(v + frac) : v + frac
  }

  mutating func string() throws -> String {
    try expect(34)
    let start = i
    var plain = true
    while i < p.count, p[i] != 34 {
      if p[i] == 92 { plain = false; i += 2 } else { i += 1 }
    }
    guard i < p.count else { throw Bad() }
    let raw = UnsafeBufferPointer(rebasing: p[start..<i])
    i += 1
    if plain { return String(decoding: raw, as: UTF8.self) }
    // escapes: let Foundation do it
    var d = Data([34])
    d.append(contentsOf: raw)
    d.append(34)
    guard let s = try JSONSerialization.jsonObject(with: d, options: .fragmentsAllowed) as? String else { throw Bad() }
    return s
  }

  mutating func numbers() throws -> [Double] {
    try expect(91)
    var out: [Double] = []
    out.reserveCapacity(4)
    if peek() == 93 { i += 1; return out }
    while true {
      out.append(try number())
      if peek() == 44 { i += 1; continue }
      try expect(93)
      return out
    }
  }

  /// Calls `body` with each key of an object, positioned at its value.
  mutating func object(_ body: (inout GlyphReader, String) throws -> Void) throws {
    try expect(123)
    if peek() == 125 { i += 1; return }
    while true {
      let k = try string()
      try expect(58)
      try body(&self, k)
      if peek() == 44 { i += 1; continue }
      try expect(125)
      return
    }
  }

  mutating func array(_ body: (inout GlyphReader) throws -> Void) throws {
    try expect(91)
    if peek() == 93 { i += 1; return }
    while true {
      try body(&self)
      if peek() == 44 { i += 1; continue }
      try expect(93)
      return
    }
  }

  /// Skips any value.
  mutating func skip() throws {
    switch peek() {
    case 34: _ = try string()
    case 123: try object { r, _ in try r.skip() }
    case 91: try array { r in try r.skip() }
    case 116, 102, 110: while i < p.count, p[i] >= 97, p[i] <= 122 { i += 1 }  // true false null
    default: _ = try number()
    }
  }

  static func read(_ data: Data) throws -> PageGlyphs {
    try data.withUnsafeBytes { raw -> PageGlyphs in
      var r = GlyphReader(p: raw.bindMemory(to: UInt8.self))
      var page = 0, w = 0.0, h = 0.0
      var fonts: [String] = []
      var glyphs: [PageGlyphs.Glyph] = []
      var lines: [PageGlyphs.Line] = []
      try r.object { r, key in
        switch key {
        case "page": page = Int(try r.number())
        case "w": w = try r.number()
        case "h": h = try r.number()
        case "fonts": try r.array { r in fonts.append(try r.string()) }
        case "glyphs":
          glyphs.reserveCapacity(4096)
          try r.array { r in
            var g = PageGlyphs.Glyph(t: "", b: [0, 0, 0, 0], l: 0, w: 0)
            try r.object { r, k in
              switch k {
              case "t": g.t = try r.string()
              case "b": g.b = try r.numbers()
              case "i": g.i = try r.numbers()
              case "o": g.o = try r.numbers()
              case "s": g.s = try r.number()
              case "f": g.f = Int(try r.number())
              case "l": g.l = Int(try r.number())
              case "w": g.w = Int(try r.number())
              case "c": g.c = Int(try r.number())
              default: try r.skip()
              }
            }
            guard g.b.count == 4, g.i.count == 4, g.o.count == 2 else { throw Bad() }
            glyphs.append(g)
          }
        case "lines":
          try r.array { r in
            var l = PageGlyphs.Line(b: [0, 0, 0, 0], base: 0, g: [0, 0])
            try r.object { r, k in
              switch k {
              case "b": l.b = try r.numbers()
              case "base": l.base = try r.number()
              case "g": l.g = try r.numbers().map { Int($0) }
              default: try r.skip()
              }
            }
            guard l.b.count == 4, l.g.count == 2 else { throw Bad() }
            lines.append(l)
          }
        default: try r.skip()
        }
      }
      return PageGlyphs(page: page, w: w, h: h, fonts: fonts, glyphs: glyphs, lines: lines)
    }
  }
}
