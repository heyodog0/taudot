// The Taudot palette and glass, shared by Settings (TaudotApp/SettingsView.swift) and the Projects window
// (TaudotHome): the logo's ink, teal and lime over a teal ground, cream-bright in light mode. One place, so a palette
// change lands in both windows. Coral is never a control: it means "you" (the avatar).
import AppKit
import SwiftUI

extension Color {
  /// An sRGB colour from 0xRRGGBB.
  public init(taudot v: UInt32, _ a: Double = 1) {
    self.init(.sRGB, red: Double(v >> 16 & 0xff) / 255, green: Double(v >> 8 & 0xff) / 255, blue: Double(v & 0xff) / 255, opacity: a)
  }
}

public struct TaudotPalette: Sendable {
  public var dark: Bool
  public var ground: [Color], glow: Color, glow2: Color
  public var panel: Color, panelSolid: Color, rim: Color
  public var card: Color, cardSolid: Color, separator: Color
  public var selected: Color, search: Color, capsule: Color, capsuleSolid: Color
  public var text: Color, secondary: Color
  public var accent: Color, onAccent: Color, switchOff: Color, knobOff: Color
  public var previewStroke: Color

  public static func make(dark: Bool) -> TaudotPalette {
    dark
      ? TaudotPalette(dark: true, ground: [Color(taudot: 0x05171a), Color(taudot: 0x0a2a30)], glow: Color(taudot: 0x2fbf9f, 0.22), glow2: Color(taudot: 0xe2ff8a, 0.07),
                      panel: Color(taudot: 0x0f3d44, 0.78), panelSolid: Color(taudot: 0x0b2a30), rim: Color(taudot: 0x2a5a60, 0.8),
                      card: Color(taudot: 0x15464d, 0.62), cardSolid: Color(taudot: 0x0d2b31), separator: Color.white.opacity(0.08),
                      selected: Color(taudot: 0x2fbf9f, 0.38), search: Color.white.opacity(0.07), capsule: Color(taudot: 0x2fbf9f, 0.22), capsuleSolid: Color(taudot: 0x14434a),
                      text: Color(taudot: 0xe8f3ef), secondary: Color(taudot: 0x8fb0ab),
                      accent: Color(taudot: 0xc8f36a), onAccent: Color(taudot: 0x0b2a30), switchOff: Color.white.opacity(0.14), knobOff: Color(taudot: 0xd3e2de),
                      previewStroke: Color.white.opacity(0.10))
      : TaudotPalette(dark: false, ground: [Color(taudot: 0xf3f8f6), Color(taudot: 0xdcebe6)], glow: Color(taudot: 0x2fbf9f, 0.18), glow2: Color(taudot: 0xe2ff8a, 0.20),
                      panel: Color(taudot: 0xd6ebe4, 0.62), panelSolid: Color(taudot: 0xe6efec), rim: Color(taudot: 0xbcd4cd, 0.9),
                      card: Color(taudot: 0xf6fcf9, 0.68), cardSolid: Color.white, separator: Color(taudot: 0x0b2a30, 0.08),
                      selected: Color(taudot: 0x2fbf9f, 0.32), search: Color(taudot: 0x0b2a30, 0.06), capsule: Color(taudot: 0x2fbf9f, 0.18), capsuleSolid: Color(taudot: 0xe0ece8),
                      text: Color(taudot: 0x0b2a30), secondary: Color(taudot: 0x56706d),
                      accent: Color(taudot: 0x0f8f7a), onAccent: .white, switchOff: Color(taudot: 0x0b2a30, 0.12), knobOff: .white,
                      previewStroke: Color(taudot: 0x0b2a30, 0.10))
  }
}

/// The same colours for AppKit views (tables, layers), following the view's appearance.
public enum TaudotColor {
  private static func dyn(_ light: UInt32, _ dark: UInt32, _ la: CGFloat = 1, _ da: CGFloat = 1) -> NSColor {
    NSColor(name: nil) { a in
      let d = a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      let v = d ? dark : light
      return NSColor(srgbRed: CGFloat(v >> 16 & 0xff) / 255, green: CGFloat(v >> 8 & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: d ? da : la)
    }
  }
  public static let text = dyn(0x0b2a30, 0xe8f3ef)
  public static let secondary = dyn(0x56706d, 0x8fb0ab)
  public static let accent = dyn(0x0f8f7a, 0xc8f36a)
  public static let selected = dyn(0x2fbf9f, 0x2fbf9f, 0.32, 0.38)
  public static let separator = dyn(0x0b2a30, 0xffffff, 0.08, 0.08)
  /// The window glass's tint: Taudot's ground, softened.
  public static let glassTint = dyn(0xeef7f3, 0x0e2328)
  public static let button = dyn(0x0f8f7a, 0x1f9e88)
  /// The selected row's glass: teal in both modes (lime goes olive over dark glass).
  public static let selection = dyn(0x2fbf9f, 0x2fbf9f, 0.24, 0.30)
  /// "You" (avatars, your own marks), never a control.
  public static let coral = NSColor(srgbRed: 1, green: 0x5e / 255.0, blue: 0x4d / 255.0, alpha: 1)
}

/// Reduce Transparency (the system's, or TAUDOT_REDUCE_TRANSPARENCY=1 for screenshots of the fallback).
public func taudotSolid(_ reduce: Bool) -> Bool {
  reduce || ProcessInfo.processInfo.environment["TAUDOT_REDUCE_TRANSPARENCY"] == "1"
}

/// Liquid Glass in `shape`, tinted (macOS 26); else, or with Reduce Transparency, a solid fill with a hairline rim.
public struct TaudotGlass<S: InsettableShape>: ViewModifier {
  let shape: S
  let tint: Color
  let fill: Color
  let rim: Color
  var interactive = false
  @Environment(\.accessibilityReduceTransparency) var reduce

  public func body(content: Content) -> some View {
    if !taudotSolid(reduce), #available(macOS 26.0, *) {
      content.glassEffect(interactive ? Glass.regular.tint(tint).interactive() : Glass.regular.tint(tint), in: shape)
    } else {
      content.background(shape.fill(fill)).overlay(shape.strokeBorder(rim, lineWidth: 1))
    }
  }
}

extension View {
  public func taudotGlass<S: InsettableShape>(_ shape: S, tint: Color, fill: Color, rim: Color, interactive: Bool = false) -> some View {
    modifier(TaudotGlass(shape: shape, tint: tint, fill: fill, rim: rim, interactive: interactive))
  }
}

/// The ground the glass sits on: a gradient with a soft teal glow at the top left and a breath of lime below.
public struct TaudotGround: View {
  let p: TaudotPalette
  public init(_ p: TaudotPalette) { self.p = p }
  public var body: some View {
    ZStack {
      LinearGradient(colors: p.ground, startPoint: .topLeading, endPoint: .bottomTrailing)
      RadialGradient(colors: [p.glow, .clear], center: UnitPoint(x: 0.1, y: 0.05), startRadius: 0, endRadius: 520)
      RadialGradient(colors: [p.glow2, .clear], center: UnitPoint(x: 0.95, y: 1), startRadius: 0, endRadius: 480)
    }
  }
}
