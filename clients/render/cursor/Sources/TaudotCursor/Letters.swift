/// The letters both sides are compared in: lower case, accents dropped, punctuation in one spelling.
enum Letters {
  static let space: UInt32 = 0x20

  /// Spacing accents a font draws as their own glyph (OT1 builds é from ´ and e): they compare as nothing.
  private static let spacingAccents: Set<UInt32> = [0xB4, 0x2C6, 0x2DC, 0xA8, 0x60, 0xAF, 0x2D8, 0x2D9, 0x2C7, 0xB8,
                                                    0x2DA, 0x2DD, 0x5E, 0x7E]

  /// One scalar → the letters it compares as (often one, none for accents, three for an ellipsis).
  static func fold(_ u: UInt32, into out: inout [UInt32]) {
    switch u {
    case 0x2026, 0x22EF: out += [0x2E, 0x2E, 0x2E]; return  // … ⋯
    case 0x2212, 0x2010, 0x2011: out.append(0x2D); return  // − ‐ ‑ → -
    case 0xA0, 0x9, 0xA, 0xD: out.append(space); return
    case 0x2032: out.append(0x2019); return  // a prime compares as ’ (an apostrophe in the source)
    case 0xFB00: out += [0x66, 0x66]; return
    case 0xFB01: out += [0x66, 0x69]; return
    case 0xFB02: out += [0x66, 0x6C]; return
    case 0xFB03: out += [0x66, 0x66, 0x69]; return
    case 0xFB04: out += [0x66, 0x66, 0x6C]; return
    default: break
    }
    if spacingAccents.contains(u) { return }
    if u < 0x80 {
      out.append(u >= 0x41 && u <= 0x5A ? u + 32 : u)
      return
    }
    guard let s = Unicode.Scalar(u) else { return }
    for d in String(Character(s)).decomposedStringWithCanonicalMapping.unicodeScalars {
      if (0x300...0x36F).contains(d.value) { continue }  // combining marks
      for l in d.properties.lowercaseMapping.unicodeScalars { out.append(l.value) }
    }
  }

  static func fold(_ s: String) -> [UInt32] {
    var out: [UInt32] = []
    for u in s.unicodeScalars { fold(u.value, into: &out) }
    return out
  }
}
