// The thin bar under the panes: engine connection on the left, the PDF's state on the right. (TeX errors: the issues
// strip over the PDF, Issues.swift.)
import AppKit
import TaudotShared

@MainActor final class StatusBar: NSView {
  static let height: CGFloat = 22

  let left = NSTextField(labelWithString: "")
  let right = NSTextField(labelWithString: "")
  let dot = NSView()
  var bg = NSColor.windowBackgroundColor, fg = NSColor.secondaryLabelColor
  /// Follows the window's appearance live (Settings ▸ Appearance): the dynamic colours are resolved again.
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    redraw()
  }
  private var noteTimer: Timer?
  private var pdfText = ""

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.masksToBounds = true
    for l in [left, right] {
      l.wantsLayer = true
      l.font = .systemFont(ofSize: 11)
      l.lineBreakMode = .byTruncatingTail
      l.translatesAutoresizingMaskIntoConstraints = false
      addSubview(l)
    }
    right.alignment = .right
    dot.wantsLayer = true
    dot.layer?.cornerRadius = 3.5
    dot.translatesAutoresizingMaskIntoConstraints = false
    addSubview(dot)
    NSLayoutConstraint.activate([
      dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
      dot.centerYAnchor.constraint(equalTo: centerYAnchor),
      dot.widthAnchor.constraint(equalToConstant: 7), dot.heightAnchor.constraint(equalToConstant: 7),
      left.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 6),
      left.centerYAnchor.constraint(equalTo: centerYAnchor),
      right.leadingAnchor.constraint(greaterThanOrEqualTo: left.trailingAnchor, constant: 12),
      right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      right.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
    right.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    connection(.map([(.string("connection"), .string("none"))]))
    redraw()
  }

  required init?(coder: NSCoder) { fatalError() }


  func redraw() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.backgroundColor = bg.blended(withFraction: 0.06, of: .gray)?.cgColor ?? bg.cgColor
    }
    right.textColor = fg
    left.textColor = fg
    setRight(pdfText)
  }

  /// Text changes on the right fade (~180 ms) instead of snapping.
  func setRight(_ t: String) {
    guard right.stringValue != t else { return }
    let f = CATransition()
    f.type = .fade
    f.duration = 0.18
    right.layer?.add(f, forKey: "fade")
    right.stringValue = t
  }

  var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

  /// `taudot_app_status`: {connection, unconfirmed, users, track}.
  func connection(_ s: Value) {
    let conn = s["connection"]?.string ?? "none"
    let unconfirmed = s["unconfirmed"]?.int ?? 0
    let users = (s["users"]?.array ?? []).compactMap(\.string)
    let color: NSColor = conn == "online" ? (unconfirmed == 0 ? .systemGreen : .systemYellow)
      : conn == "connecting" ? .systemYellow : conn == "none" ? .systemGray : .systemRed
    dot.layer?.backgroundColor = color.cgColor
    var parts = [conn == "none" ? "no project" : conn]
    if unconfirmed > 0 { parts.append("\(unconfirmed) edit\(unconfirmed == 1 ? "" : "s") unconfirmed") }
    if s["track"]?.bool == true { parts.append("tracking changes") }
    if !users.isEmpty { parts.append("with " + users.joined(separator: ", ")) }
    // an edit the engine refused or a failed merge: the edits are kept but not synced, until it clears
    if let err = s["error"]?.string, !err.isEmpty {
      dot.layer?.backgroundColor = NSColor.systemRed.cgColor
      parts = ["not synced: " + err]
    }
    left.stringValue = parts.joined(separator: "  ·  ")
  }

  /// The PDF pane's `onStatus` (not its "TeX: " errors: those go to the issues).
  func pdf(_ s: String) {
    pdfText = s
    redraw()
  }

  /// A passing note (action failures), shown for a few seconds.
  func note(_ s: String) {
    setRight(s)
    noteTimer?.invalidate()
    noteTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.redraw() }
    }
  }

}

