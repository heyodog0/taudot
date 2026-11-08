// Where the forward-search mark goes: the word box, a faint band over the typeset line it sits on, and a tick in the
// left margin at the line's start. Pure geometry in page points (y down), so it can be tested without a window.
import AppKit

public enum LineMark {
  /// The typeset lines a word is on: for each of its rects (two for a word hyphenated across lines), the row whose
  /// vertical span holds the rect's middle, the shortest if several do (an enclosing box can be taller). One line per
  /// rect at most; none when no row holds it.
  public static func lines(word: [CGRect], rows: [CGRect]) -> [CGRect] {
    var out: [CGRect] = []
    for w in word {
      let hits = rows.filter { $0.minY - 0.5 <= w.midY && w.midY <= $0.maxY + 0.5 && $0.height <= maxLine }
      guard let r = hits.min(by: { $0.height < $1.height }) else { continue }
      if !out.contains(r) { out.append(r) }
    }
    return out
  }

  /// A typeset line taller than this isn't one line (a SyncTeX row of a figure or display), so it gets no band.
  public static let maxLine: CGFloat = 30

  /// The band over a line: its own height and width, padded a little so ascenders and descenders sit inside it.
  public static func band(_ line: CGRect) -> CGRect { line.insetBy(dx: -3, dy: -1.5) }

  /// The margin tick left of a line's start, kept a few screen points wide and at least ~14 screen points tall at any
  /// zoom (`magnification` = screen points per page point), so the line can be found when zoomed out.
  public static func tick(_ line: CGRect, magnification: CGFloat) -> CGRect {
    let m = max(magnification, 0.05)
    let w = max(2, 3 / m), gap = max(3, 5 / m)
    let h = max(line.height + 3, 14 / m)
    return CGRect(x: max(0, line.minX - 3 - gap - w), y: line.midY - h / 2, width: w, height: h)
  }
}

/// The forward-search mark's colour: the system accent by default, or one the user picked (right-click on the PDF ▸
/// Highlight Colour), kept in UserDefaults as "accent" or "#rrggbb".
@MainActor public enum MarkColor {
  public static let key = "taudot.pdfMarkColor"
  public static let presets: [(name: String, key: String)] = [
    ("System Accent", "accent"), ("Yellow", "#f5c400"), ("Orange", "#ff8a00"), ("Green", "#2fb344"),
    ("Blue", "#1f7aff"), ("Purple", "#9b51e0"), ("Pink", "#ff4fa0"),
  ]

  public static var stored: String {
    get { UserDefaults.standard.string(forKey: key) ?? "accent" }
    set { UserDefaults.standard.set(newValue, forKey: key) }
  }

  public static var current: NSColor { stored == "accent" ? .controlAccentColor : color(hex: stored) ?? .controlAccentColor }

  public static func color(hex: String) -> NSColor? {
    let h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
    return NSColor(srgbRed: CGFloat(v >> 16 & 0xff) / 255, green: CGFloat(v >> 8 & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
  }

  public static func hex(_ c: NSColor) -> String {
    let s = c.usingColorSpace(.sRGB) ?? .black
    return String(format: "#%02x%02x%02x", Int((s.redComponent * 255).rounded()), Int((s.greenComponent * 255).rounded()),
      Int((s.blueComponent * 255).rounded()))
  }

  /// How strongly each part is laid on: the line band faint, the word box stronger; more on a dark page.
  public struct Tint: Equatable, Sendable {
    public let band, bandEdge, word, wordEdge, tick: CGFloat
    public init(dark: Bool) {
      if dark { (band, bandEdge, word, wordEdge, tick) = (0.30, 0.55, 0.45, 0.95, 1) }
      else { (band, bandEdge, word, wordEdge, tick) = (0.13, 0.28, 0.26, 0.85, 0.9) }
    }
  }

  static func swatch(_ c: NSColor) -> NSImage {
    NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
      c.setFill()
      NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3).fill()
      return true
    }
  }
}

/// What a new forward-search mark does to the one on screen: one animation per jump, never a flash.
public enum MarkPlan: Equatable, Sendable {
  /// Nothing shown (or it had dimmed): it fades in where it belongs.
  case appear
  /// Another place: the band and the box glide there (~120 ms, ease-out).
  case glide
  /// The same place (a cursor-follow echo of an inverse search, a repeated ⌘⌥J, the same line asked twice): nothing
  /// moves.
  case stay

  public struct Mark: Equatable, Sendable {
    public var page: Int
    public var words: [CGRect]
    public var lines: [CGRect]
    /// Idle for a while: only an underline left.
    public var dimmed = false
    public init(page: Int, words: [CGRect], lines: [CGRect], dimmed: Bool = false) {
      self.page = page; self.words = words; self.lines = lines; self.dimmed = dimmed
    }
  }

  static func same(_ a: [CGRect], _ b: [CGRect]) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { abs($0.minX - $1.minX) < 1 && abs($0.minY - $1.minY) < 1 && abs($0.maxX - $1.maxX) < 1 && abs($0.maxY - $1.maxY) < 1 }
  }

  public static func decide(current: Mark?, page: Int, words: [CGRect], lines: [CGRect]) -> MarkPlan {
    guard let c = current, !c.dimmed else { return .appear }
    if c.page == page {
      if !words.isEmpty && same(words, c.words) && (lines.isEmpty || same(lines, c.lines)) { return .stay }
      if words.isEmpty && !lines.isEmpty && same(lines, c.lines) && c.words.isEmpty { return .stay }
    }
    return .glide
  }
}
