// UTF-8 byte offsets (the engine's) ↔ UTF-16 offsets (NSString's), over a doc's bytes.

public enum Utf {
  /// UTF-16 units of the character starting with this byte (0 for continuation bytes).
  @inline(__always) static func units(_ b: UInt8) -> Int {
    if b < 0x80 { return 1 }
    if b < 0xC0 { return 0 }
    if b < 0xF0 { return 1 }
    return 2
  }

  /// The UTF-16 offset of byte offset `pos`.
  public static func utf16(_ bytes: [UInt8], _ pos: Int) -> Int {
    var n = 0
    let end = min(pos, bytes.count)
    bytes.withUnsafeBufferPointer { p in
      for i in 0..<end { n &+= units(p[i]) }
    }
    return n
  }

  /// The byte offset of UTF-16 offset `off` (a split surrogate pair counts as the whole character).
  public static func utf8(_ bytes: [UInt8], _ off: Int) -> Int {
    var n = 0, i = 0
    bytes.withUnsafeBufferPointer { p in
      while i < p.count && n < off {
        n += units(p[i])
        i += 1
        while i < p.count && p[i] >= 0x80 && p[i] < 0xC0 { i += 1 }
      }
    }
    return i
  }

  /// Byte offsets where each line starts.
  public static func lineStarts(_ bytes: [UInt8]) -> [Int] {
    var out = [0]
    bytes.withUnsafeBufferPointer { p in
      for i in 0..<p.count where p[i] == 10 { out.append(i + 1) }
    }
    return out
  }

  /// (line, byte column) of a byte offset, given `lineStarts`.
  public static func lineCol(_ starts: [Int], _ pos: Int) -> (Int, Int) {
    var lo = 0, hi = starts.count - 1
    while lo < hi {
      let mid = (lo + hi + 1) / 2
      if starts[mid] <= pos { lo = mid } else { hi = mid - 1 }
    }
    return (lo, pos - starts[lo])
  }
}
