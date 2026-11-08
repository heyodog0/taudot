// The home window's few touches of colour, in the Taudot palette: teal on New Project, the accent (teal in light
// mode, lime in dark) on the on-this-Mac marks and in the selection's glass, a hint of teal in the window's glass; coral, the brand's "you", on the account avatar.
// Off with the `taudot.homeFlair` default set to NO (or TAUDOT_HOME_FLAIR=0).
import AppKit
import TaudotShared

enum Flair {
  static var on: Bool {
    if let e = ProcessInfo.processInfo.environment["TAUDOT_HOME_FLAIR"] { return e != "0" }
    return UserDefaults.standard.object(forKey: "taudot.homeFlair") as? Bool ?? true
  }

  static var accent: NSColor { on ? TaudotColor.accent : .controlAccentColor }
  /// New Project's fill: Taudot teal (lighter in dark mode).
  static var button: NSColor { on ? TaudotColor.button : .controlAccentColor }

  /// A round coral avatar with your initials (the account toolbar item).
  static func avatar(_ initials: String, size: CGFloat = 22) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
      TaudotColor.coral.setFill()
      NSBezierPath(ovalIn: r.insetBy(dx: 0.5, dy: 0.5)).fill()
      let font = NSFont.systemFont(ofSize: size * 0.42, weight: .bold)
      let s = NSAttributedString(string: initials, attributes: [.font: font, .foregroundColor: NSColor.white])
      let b = s.size()
      s.draw(at: NSPoint(x: r.midX - b.width / 2, y: r.midY - b.height / 2))
      return true
    }
  }
}
