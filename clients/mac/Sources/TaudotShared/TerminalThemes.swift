// Terminal colour schemes (Rex's themes, the shipped ones, imported Ghostty and iTerm2 files) as editor Themes.
//
// A terminal scheme has a background, foreground, cursor, selection and 16 ANSI colours. They map onto the tokens as
// follows: commands blue, environments magenta, math yellow, comments
// bright black, brackets cyan, errors red; line numbers, the cursor line and panels are mixed from bg and fg.
import AppKit
import Foundation

/// A terminal colour scheme. Colours are 0xRRGGBB.
public struct TerminalPalette: Equatable, Sendable {
  public var background: UInt32
  public var foreground: UInt32
  public var cursor: UInt32?
  public var selection: UInt32?
  /// 16 colours: black red green yellow blue magenta cyan white, then their bright forms.
  public var ansi: [UInt32]
  public init(background: UInt32, foreground: UInt32, cursor: UInt32? = nil, selection: UInt32? = nil, ansi: [UInt32]) {
    self.background = background
    self.foreground = foreground
    self.cursor = cursor
    self.selection = selection
    self.ansi = ansi
  }

  /// Relative luminance of the background below one half: a dark scheme.
  public var isDark: Bool { luminance(background) < 0.5 }
}

func luminance(_ c: UInt32) -> Double {
  let r = Double((c >> 16) & 0xff) / 255, g = Double((c >> 8) & 0xff) / 255, b = Double(c & 0xff) / 255
  return 0.2126 * r + 0.7152 * g + 0.0722 * b
}

/// `a` mixed toward `b` by `t` (0…1), per channel.
public func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
  func ch(_ s: UInt32) -> Double { Double(s & 0xff) }
  var out: UInt32 = 0
  for shift in [16, 8, 0] as [UInt32] {
    let x = ch(a >> shift), y = ch(b >> shift)
    out |= UInt32((x + (y - x) * t).rounded()) << shift
  }
  return out
}

extension Theme {
  /// The editor theme for a terminal scheme.
  public static func from(_ p: TerminalPalette, id: String, name: String, dark: Bool? = nil) -> Theme {
    let a = p.ansi.count >= 16 ? p.ansi : p.ansi + Array(repeating: p.foreground, count: 16 - p.ansi.count)
    let bg = p.background, fg = p.foreground
    let dark = dark ?? p.isDark
    // Prefer the normal colour; the bright one when the normal one is too close to the background to read.
    func pick(_ n: Int) -> UInt32 { abs(luminance(a[n]) - luminance(bg)) < 0.12 ? a[n + 8] : a[n] }
    let comment = abs(luminance(a[8]) - luminance(bg)) < 0.12 ? mix(bg, fg, 0.5) : a[8]
    return Theme(
      id: id, name: name, dark: dark, bg: bg, fg: fg, comment: comment,
      command: pick(4), math: pick(3), env: pick(5), bracket: pick(6),
      selection: p.selection ?? mix(bg, fg, 0.22), cursor: p.cursor ?? fg, cursorLine: mix(bg, fg, 0.05),
      lineNr: mix(bg, fg, 0.3), lineNrCurrent: mix(bg, fg, 0.75), search: pick(3), panel: mix(bg, fg, 0.07),
      info: pick(4), warn: pick(3), ok: pick(2), hint: pick(6), error: pick(1))
  }
}

// MARK: files

public enum ThemeFiles {
  static func hex(_ s: Substring) -> UInt32? {
    var t = s.trimmingCharacters(in: .whitespaces)
    if t.hasPrefix("#") { t.removeFirst() }
    guard t.count == 6 else { return nil }
    return UInt32(t, radix: 16)
  }

  /// A Ghostty theme: `background = 1e1e2e`, `palette = 4=#89b4fa`, …
  public static func ghostty(_ text: String) -> TerminalPalette? {
    var bg: UInt32?, fg: UInt32?, cursor: UInt32?, sel: UInt32?
    var ansi = [UInt32?](repeating: nil, count: 16)
    for raw in text.split(whereSeparator: \.isNewline) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
      let key = line[..<eq].trimmingCharacters(in: .whitespaces), val = line[line.index(after: eq)...]
      switch key {
      case "background": bg = hex(val)
      case "foreground": fg = hex(val)
      case "cursor-color": cursor = hex(val)
      case "selection-background": sel = hex(val)
      case "palette":
        let parts = val.split(separator: "=", maxSplits: 1)
        if parts.count == 2, let n = Int(parts[0].trimmingCharacters(in: .whitespaces)), (0..<16).contains(n) { ansi[n] = hex(parts[1]) }
      default: break
      }
    }
    guard let bg, let fg, ansi.allSatisfy({ $0 != nil }) else { return nil }
    return TerminalPalette(background: bg, foreground: fg, cursor: cursor, selection: sel, ansi: ansi.map { $0! })
  }

  /// An iTerm2 `.itermcolors` plist (components 0…1, in sRGB or calibrated RGB).
  public static func iterm(_ data: Data) -> TerminalPalette? {
    guard let d = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
    func color(_ k: String) -> UInt32? {
      guard let c = d[k] as? [String: Any], let r = c["Red Component"] as? Double, let g = c["Green Component"] as? Double,
            let b = c["Blue Component"] as? Double else { return nil }
      func ch(_ v: Double) -> UInt32 { UInt32((max(0, min(1, v)) * 255).rounded()) }
      return ch(r) << 16 | ch(g) << 8 | ch(b)
    }
    let ansi = (0..<16).map { color("Ansi \($0) Color") }
    guard let bg = color("Background Color"), let fg = color("Foreground Color"), ansi.allSatisfy({ $0 != nil }) else { return nil }
    return TerminalPalette(background: bg, foreground: fg, cursor: color("Cursor Color"), selection: color("Selection Color"), ansi: ansi.map { $0! })
  }

  /// Either format, by content.
  public static func parse(_ data: Data) -> TerminalPalette? {
    if let p = iterm(data) { return p }
    return String(data: data, encoding: .utf8).flatMap(ghostty)
  }
}
