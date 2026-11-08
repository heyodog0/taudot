// The editor font: `guifont` parsed, four faces, cell metrics in device pixels.
import AppKit
import CoreText

public struct FontStyle: OptionSet, Hashable, Sendable {
  public let rawValue: UInt8
  public init(rawValue: UInt8) { self.rawValue = rawValue }
  public static let bold = FontStyle(rawValue: 1)
  public static let italic = FontStyle(rawValue: 2)
}

public final class FontSet {
  public let faces: [CTFont]  // index by FontStyle.rawValue (0...3)
  public let size: CGFloat     // points
  public let scale: CGFloat    // device pixels per point
  /// Cell size in device pixels (whole pixels).
  public let cellWidth: CGFloat
  public let cellHeight: CGFloat
  public let ascent: CGFloat   // pixels, from the cell top to the baseline (includes half the linespace)
  public let underlinePos: CGFloat  // pixels below the baseline
  public let underlineThickness: CGFloat
  public let linespace: Int
  public let name: String

  public static let defaultSize: CGFloat = 13

  /// `guifont` like "JetBrains Mono,Menlo:h14:b" (Neovim's syntax; `_` stands for a space). nil: the system monospace.
  public convenience init(guifont: String?, linespace: Int = 0, scale: CGFloat) {
    var size = FontSet.defaultSize
    var base: CTFont?
    var bold = false, italic = false
    if let gf = guifont, !gf.isEmpty {
      let parts = gf.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
      for opt in parts.dropFirst() {
        if opt.hasPrefix("h"), let s = Double(opt.dropFirst()) { size = CGFloat(s) }
        if opt == "b" { bold = true }
        if opt == "i" { italic = true }
      }
      for raw in parts[0].split(separator: ",") {
        let name = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "_", with: " ")
        if name.isEmpty || name == "*" { continue }
        if let f = FontSet.find(name, size: size) { base = f; break }
      }
    }
    var f = base ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular) as CTFont
    if bold { f = CTFontCreateCopyWithSymbolicTraits(f, 0, nil, .traitBold, .traitBold) ?? f }
    if italic { f = CTFontCreateCopyWithSymbolicTraits(f, 0, nil, .traitItalic, .traitItalic) ?? f }
    self.init(base: f, linespace: linespace, scale: scale)
  }

  static func find(_ name: String, size: CGFloat) -> CTFont? {
    let f = CTFontCreateWithName(name as CFString, size, nil)
    let got = CTFontCopyFamilyName(f) as String
    let ps = CTFontCopyPostScriptName(f) as String
    let want = name.lowercased()
    if got.lowercased() == want || ps.lowercased() == want || (CTFontCopyFullName(f) as String).lowercased() == want { return f }
    return nil
  }

  public init(base: CTFont, linespace: Int, scale: CGFloat) {
    self.scale = scale
    self.size = CTFontGetSize(base)
    self.linespace = linespace
    self.name = CTFontCopyFamilyName(base) as String
    func variant(_ t: CTFontSymbolicTraits) -> CTFont {
      if t.isEmpty { return base }
      return CTFontCreateCopyWithSymbolicTraits(base, 0, nil, t, t) ?? base
    }
    // Icons (Nerd Font private-use glyphs) come from an installed Nerd Font when the main font lacks them.
    let cascade = FontSet.symbolFallbacks(size: CTFontGetSize(base))
    func withCascade(_ f: CTFont) -> CTFont {
      guard !cascade.isEmpty else { return f }
      let d = CTFontDescriptorCreateCopyWithAttributes(CTFontCopyFontDescriptor(f),
        [kCTFontCascadeListAttribute: cascade] as CFDictionary)
      return CTFontCreateWithFontDescriptor(d, CTFontGetSize(f), nil)
    }
    faces = [variant([]), variant(.traitBold), variant(.traitItalic), variant([.traitBold, .traitItalic])].map(withCascade)
    // Advance of "M" in the regular face.
    var ch: UniChar = 0x4D
    var glyph: CGGlyph = 0
    CTFontGetGlyphsForCharacters(base, &ch, &glyph, 1)
    var adv = CGSize.zero
    CTFontGetAdvancesForGlyphs(base, .horizontal, &glyph, &adv, 1)
    let asc = CTFontGetAscent(base), desc = CTFontGetDescent(base), lead = CTFontGetLeading(base)
    cellWidth = (adv.width * scale).rounded()
    let lineH = ((asc + desc + lead) * scale).rounded(.up)
    cellHeight = lineH + CGFloat(linespace) * scale
    ascent = (asc * scale + (lead * scale) / 2).rounded() + (CGFloat(linespace) * scale / 2).rounded(.down)
    underlinePos = max(1, (-CTFontGetUnderlinePosition(base) * scale).rounded())
    underlineThickness = max(1, (CTFontGetUnderlineThickness(base) * scale).rounded())
  }

  public func face(_ s: FontStyle) -> CTFont { faces[Int(s.rawValue & 3)] }

  nonisolated(unsafe) static var symbolCache: [CTFontDescriptor]?

  /// Descriptors of installed fonts with Nerd Font symbols: "Symbols Nerd Font Mono" first, then any "Nerd Font Mono".
  static func symbolFallbacks(size: CGFloat) -> [CTFontDescriptor] {
    if let c = symbolCache { return c }
    let families = (CTFontManagerCopyAvailableFontFamilyNames() as! [String])
    var picks = families.filter { $0.hasPrefix("Symbols Nerd Font") }
    if let m = families.first(where: { $0.hasSuffix("Nerd Font Mono") }) { picks.append(m) }
    else if let m = families.first(where: { $0.contains("Nerd Font") }) { picks.append(m) }
    let r = picks.map { CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: $0] as CFDictionary) }
    symbolCache = r
    return r
  }
}
