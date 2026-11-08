// msgpack encode and streaming decode, for Neovim's RPC (no dependencies).
import Foundation
import TaudotShared

public enum MsgPack {
  public static func encode(_ v: Value) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(64)
    encode(v, into: &out)
    return out
  }

  public static func encode(_ v: Value, into o: inout [UInt8]) {
    switch v {
    case .null: o.append(0xc0)
    case .bool(let b): o.append(b ? 0xc3 : 0xc2)
    case .int(let i): encodeInt(i, &o)
    case .float(let d): o.append(0xcb); be(d.bitPattern, &o)
    case .string(let s):
      let u = Array(s.utf8)
      let n = u.count
      if n < 32 { o.append(0xa0 | UInt8(n)) }
      else if n < 0x100 { o.append(0xd9); o.append(UInt8(n)) }
      else if n < 0x10000 { o.append(0xda); be(UInt16(n), &o) }
      else { o.append(0xdb); be(UInt32(n), &o) }
      o.append(contentsOf: u)
    case .binary(let b):
      let n = b.count
      if n < 0x100 { o.append(0xc4); o.append(UInt8(n)) }
      else if n < 0x10000 { o.append(0xc5); be(UInt16(n), &o) }
      else { o.append(0xc6); be(UInt32(n), &o) }
      o.append(contentsOf: b)
    case .array(let a):
      let n = a.count
      if n < 16 { o.append(0x90 | UInt8(n)) }
      else if n < 0x10000 { o.append(0xdc); be(UInt16(n), &o) }
      else { o.append(0xdd); be(UInt32(n), &o) }
      for x in a { encode(x, into: &o) }
    case .map(let m):
      let n = m.count
      if n < 16 { o.append(0x80 | UInt8(n)) }
      else if n < 0x10000 { o.append(0xde); be(UInt16(n), &o) }
      else { o.append(0xdf); be(UInt32(n), &o) }
      for (k, x) in m { encode(k, into: &o); encode(x, into: &o) }
    }
  }

  static func encodeInt(_ i: Int64, _ o: inout [UInt8]) {
    if i >= 0 {
      if i < 128 { o.append(UInt8(i)) }
      else if i < 0x100 { o.append(0xcc); o.append(UInt8(i)) }
      else if i < 0x10000 { o.append(0xcd); be(UInt16(i), &o) }
      else if i < 0x1_0000_0000 { o.append(0xce); be(UInt32(i), &o) }
      else { o.append(0xcf); be(UInt64(i), &o) }
    } else {
      if i >= -32 { o.append(UInt8(bitPattern: Int8(i))) }
      else if i >= -128 { o.append(0xd0); o.append(UInt8(bitPattern: Int8(i))) }
      else if i >= -32768 { o.append(0xd1); be(UInt16(bitPattern: Int16(i)), &o) }
      else if i >= -2_147_483_648 { o.append(0xd2); be(UInt32(bitPattern: Int32(i)), &o) }
      else { o.append(0xd3); be(UInt64(bitPattern: i), &o) }
    }
  }

  @inline(__always) static func be<T: FixedWidthInteger>(_ x: T, _ o: inout [UInt8]) {
    var b = x.bigEndian
    withUnsafeBytes(of: &b) { o.append(contentsOf: $0) }
  }
}

/// Streaming decoder: feed bytes as they arrive, take whole values out.
public struct MsgPackDecoder {
  var buf: [UInt8] = []
  var pos = 0

  public init() {}

  public mutating func feed(_ bytes: some Sequence<UInt8>) {
    if pos > 0 && pos == buf.count { buf.removeAll(keepingCapacity: true); pos = 0 }
    else if pos > 1 << 20 { buf.removeFirst(pos); pos = 0 }
    buf.append(contentsOf: bytes)
  }

  public enum DecodeError: Error { case badByte(UInt8), badUTF8 }

  struct Short: Error {}

  /// The next complete value, or nil if more bytes are needed.
  public mutating func next() throws -> Value? {
    var p = pos
    do {
      let v = try value(&p)
      pos = p
      return v
    } catch is Short {
      return nil
    }
  }

  /// All complete values buffered.
  public mutating func drain() throws -> [Value] {
    var out: [Value] = []
    while let v = try next() { out.append(v) }
    return out
  }

  @inline(__always) func need(_ p: Int, _ n: Int) throws { if p + n > buf.count { throw Short() } }

  @inline(__always) func read<T: FixedWidthInteger>(_ p: inout Int, _: T.Type) throws -> T {
    let n = MemoryLayout<T>.size
    try need(p, n)
    var x: T = 0
    for i in 0..<n { x = x << 8 | T(buf[p + i]) }
    p += n
    return x
  }

  func value(_ p: inout Int) throws -> Value {
    try need(p, 1)
    let b = buf[p]; p += 1
    switch b {
    case 0x00...0x7f: return .int(Int64(b))
    case 0xe0...0xff: return .int(Int64(Int8(bitPattern: b)))
    case 0x80...0x8f: return try map(&p, Int(b & 0x0f))
    case 0x90...0x9f: return try array(&p, Int(b & 0x0f))
    case 0xa0...0xbf: return try str(&p, Int(b & 0x1f))
    case 0xc0: return .null
    case 0xc2: return .bool(false)
    case 0xc3: return .bool(true)
    case 0xc4: return try bin(&p, Int(try read(&p, UInt8.self)))
    case 0xc5: return try bin(&p, Int(try read(&p, UInt16.self)))
    case 0xc6: return try bin(&p, Int(try read(&p, UInt32.self)))
    case 0xc7: let n = Int(try read(&p, UInt8.self)); return try ext(&p, n)
    case 0xc8: let n = Int(try read(&p, UInt16.self)); return try ext(&p, n)
    case 0xc9: let n = Int(try read(&p, UInt32.self)); return try ext(&p, n)
    case 0xca: return .float(Double(Float(bitPattern: try read(&p, UInt32.self))))
    case 0xcb: return .float(Double(bitPattern: try read(&p, UInt64.self)))
    case 0xcc: return .int(Int64(try read(&p, UInt8.self)))
    case 0xcd: return .int(Int64(try read(&p, UInt16.self)))
    case 0xce: return .int(Int64(try read(&p, UInt32.self)))
    case 0xcf: return .int(Int64(bitPattern: try read(&p, UInt64.self)))
    case 0xd0: return .int(Int64(Int8(bitPattern: try read(&p, UInt8.self))))
    case 0xd1: return .int(Int64(Int16(bitPattern: try read(&p, UInt16.self))))
    case 0xd2: return .int(Int64(Int32(bitPattern: try read(&p, UInt32.self))))
    case 0xd3: return .int(Int64(bitPattern: try read(&p, UInt64.self)))
    case 0xd4: return try ext(&p, 1)
    case 0xd5: return try ext(&p, 2)
    case 0xd6: return try ext(&p, 4)
    case 0xd7: return try ext(&p, 8)
    case 0xd8: return try ext(&p, 16)
    case 0xd9: return try str(&p, Int(try read(&p, UInt8.self)))
    case 0xda: return try str(&p, Int(try read(&p, UInt16.self)))
    case 0xdb: return try str(&p, Int(try read(&p, UInt32.self)))
    case 0xdc: return try array(&p, Int(try read(&p, UInt16.self)))
    case 0xdd: return try array(&p, Int(try read(&p, UInt32.self)))
    case 0xde: return try map(&p, Int(try read(&p, UInt16.self)))
    case 0xdf: return try map(&p, Int(try read(&p, UInt32.self)))
    default: throw DecodeError.badByte(b)
    }
  }

  func str(_ p: inout Int, _ n: Int) throws -> Value {
    try need(p, n)
    let s = buf.withUnsafeBufferPointer { String(decoding: UnsafeBufferPointer(rebasing: $0[p..<p + n]), as: UTF8.self) }
    p += n
    return .string(s)
  }

  func bin(_ p: inout Int, _ n: Int) throws -> Value {
    try need(p, n)
    let b = Array(buf[p..<p + n]); p += n
    return .binary(b)
  }

  /// Neovim's EXT types (Buffer 0, Window 1, Tabpage 2) carry a msgpack int handle; decode them as that int.
  func ext(_ p: inout Int, _ n: Int) throws -> Value {
    try need(p, 1 + n)
    p += 1
    var q = p
    let inner = try? value(&q)
    p += n
    if case .int = inner { return inner! }
    return .binary(Array(buf[p - n..<p]))
  }

  func array(_ p: inout Int, _ n: Int) throws -> Value {
    var a: [Value] = []
    a.reserveCapacity(Swift.min(n, 4096))
    for _ in 0..<n { a.append(try value(&p)) }
    return .array(a)
  }

  func map(_ p: inout Int, _ n: Int) throws -> Value {
    var m: [(Value, Value)] = []
    m.reserveCapacity(Swift.min(n, 4096))
    for _ in 0..<n { let k = try value(&p); let v = try value(&p); m.append((k, v)) }
    return .map(m)
  }
}

// Convenience accessors.
public extension Value {
  var int: Int? { if case .int(let i) = self { return Int(i) }; if case .float(let d) = self { return Int(d) }; return nil }
  var double: Double? { if case .float(let d) = self { return d }; if case .int(let i) = self { return Double(i) }; return nil }
  var string: String? { if case .string(let s) = self { return s }; if case .binary(let b) = self { return String(decoding: b, as: UTF8.self) }; return nil }
  var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
  var array: [Value]? { if case .array(let a) = self { return a }; return nil }
  var mapPairs: [(Value, Value)]? { if case .map(let m) = self { return m }; return nil }
  subscript(key: String) -> Value? {
    guard case .map(let m) = self else { return nil }
    for (k, v) in m where k.string == key { return v }
    return nil
  }
  subscript(i: Int) -> Value? { guard case .array(let a) = self, i < a.count else { return nil }; return a[i] }
}
