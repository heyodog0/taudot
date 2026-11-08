// Rex's themes, read from Rex's own bundle when Rex is installed. Nothing of Rex's is copied into this repo: without
// Rex the group is simply empty.
import AppKit
import Foundation

public enum RexThemes {
  static let bundleIDs = ["com.superlogical.rex", "com.superlogical.rex.beta", "com.superlogical.Rex"]
  static let inside = "Contents/Resources/SuperUI_SuperDesignTokens.bundle/Contents/Resources/themes.json"
  static let fallback = "/Applications/Rex Beta.app"

  /// Where Rex's themes.json is, if Rex is installed.
  public static func file() -> URL? {
    if let p = ProcessInfo.processInfo.environment["TAUDOT_REX_THEMES"] { return URL(fileURLWithPath: p) }
    var apps: [URL] = []
    for id in bundleIDs { if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { apps.append(u) } }
    apps.append(URL(fileURLWithPath: fallback))
    apps.append(URL(fileURLWithPath: "/Applications/Rex.app"))
    return apps.map { $0.appendingPathComponent(inside) }.first { FileManager.default.fileExists(atPath: $0.path) }
  }

  nonisolated(unsafe) private static var cache: [Theme]?
  private static let lock = NSLock()

  /// Rex's themes as editor themes (ids `rex-<id>`), loaded once.
  public static func all() -> [Theme] {
    lock.lock()
    defer { lock.unlock() }
    if let c = cache { return c }
    let out = file().flatMap { try? Data(contentsOf: $0) }.map(parse) ?? []
    cache = out
    return out
  }

  /// `themes.json`: `[{id, name, appearance, source: {background, foreground, cursor, selectionBackground, ansi},
  /// displayP3: {...}}]`.
  public static func parse(_ data: Data) -> [Theme] {
    guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
    return list.compactMap { t in
      guard let id = t["id"] as? String, let name = t["name"] as? String, let src = t["source"] as? [String: Any],
            let p = palette(src, colour: { ($0 as? String).flatMap { ThemeFiles.hex(Substring($0)) } }) else { return nil }
      let dark = (t["appearance"] as? String).map { $0 != "light" }
      var theme = Theme.from(p, id: "rex-" + id, name: name, dark: dark)
      if let d3 = t["displayP3"] as? [String: Any], let p3 = palette(d3, colour: p3Colour) {
        theme.p3 = Theme.from(p3, id: theme.id, name: name, dark: dark).tokens
      }
      return theme
    }
  }

  static func palette(_ m: [String: Any], colour: (Any?) -> UInt32?) -> TerminalPalette? {
    var ansi: [UInt32] = []
    if let a = m["ansi"] as? [Any] { ansi = a.compactMap(colour) }
    else if let a = m["ansi"] as? [String: Any] { ansi = (0..<16).compactMap { colour(a[String($0)]) } }
    guard let bg = colour(m["background"]), let fg = colour(m["foreground"]), ansi.count == 16 else { return nil }
    return TerminalPalette(background: bg, foreground: fg, cursor: colour(m["cursor"]), selection: colour(m["selectionBackground"]), ansi: ansi)
  }

  /// `color(display-p3 r g b)` as 0xRRGGBB of Display P3 components.
  static func p3Colour(_ v: Any?) -> UInt32? {
    guard let s = v as? String, s.hasPrefix("color(display-p3"), let open = s.firstIndex(of: " ") else { return nil }
    let nums = s[open...].dropLast().split(separator: " ").compactMap { Double($0) }
    guard nums.count >= 3 else { return nil }
    func ch(_ x: Double) -> UInt32 { UInt32((max(0, min(1, x)) * 255).rounded()) }
    return ch(nums[0]) << 16 | ch(nums[1]) << 8 | ch(nums[2])
  }
}

extension Theme {
  /// The colour tokens in a fixed order (for `p3`).
  nonisolated(unsafe) public static let tokenPaths: [KeyPath<Theme, UInt32>] = [
    \.bg, \.fg, \.comment, \.command, \.math, \.env, \.bracket, \.selection, \.cursor, \.cursorLine, \.lineNr,
    \.lineNrCurrent, \.search, \.panel, \.info, \.warn, \.ok, \.hint, \.error,
  ]
  public var tokens: [UInt32] { Theme.tokenPaths.map { self[keyPath: $0] } }

  /// A token as a colour: Display P3 when the theme has P3 values, else sRGB.
  public func color(_ k: KeyPath<Theme, UInt32>, alpha: CGFloat = 1) -> NSColor {
    func c(_ v: UInt32) -> (CGFloat, CGFloat, CGFloat) { (CGFloat((v >> 16) & 0xff) / 255, CGFloat((v >> 8) & 0xff) / 255, CGFloat(v & 0xff) / 255) }
    if let p3, let i = Theme.tokenPaths.firstIndex(of: k), i < p3.count {
      let (r, g, b) = c(p3[i])
      return NSColor(displayP3Red: r, green: g, blue: b, alpha: alpha)
    }
    let (r, g, b) = c(self[keyPath: k])
    return NSColor(srgbRed: r, green: g, blue: b, alpha: alpha)
  }
}
