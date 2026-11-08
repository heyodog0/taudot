// Signed out: one calm column. "Use My Browser's Session" (the engine tries Chrome, Arc, Brave, Edge, Vivaldi and
// Safari in turn and says which it used), "Paste a Session Cookie" as the fallback, and signing in inside the app.
import AppKit
import SwiftUI
import TaudotShared

@MainActor final class SignInView: NSView {
  /// `account.login` params → the engine's answer, or an error message.
  var login: (@MainActor ([String: Any]) async -> String?)?
  var signInHere: (() -> Void)?

  private let title = NSTextField(labelWithString: "Sign in to Overleaf")
  private let subtitle = NSTextField(wrappingLabelWithString: "")
  private let browserButton = NSButton(title: "Use My Browser’s Session", target: nil, action: nil)
  private let spinner = NSProgressIndicator()
  private let message = NSTextField(wrappingLabelWithString: "")
  private let pasteToggle = NSButton(title: "Paste a session cookie instead", target: nil, action: nil)
  private let cookieField = NSSecureTextField()
  private let cookieButton = NSButton(title: "Sign In", target: nil, action: nil)
  private let pasteHelp = NSTextField(wrappingLabelWithString: "")
  private let pasteBox = NSStackView()
  private let hereButton = NSButton(title: "Sign in on overleaf.com here…", target: nil, action: nil)
  private let hereHelp = NSTextField(wrappingLabelWithString: "Google and other single sign-on may refuse to sign in inside an app. If that happens, sign in in your browser and use its session.")

  var server: String = "https://www.overleaf.com" {
    didSet { updateTexts() }
  }

  override init(frame: NSRect) {
    super.init(frame: frame)
    // Taudot's mark, the dot in coral (the brand's "you"), the tau in the text colour.
    let ink = TaudotColor.text
    let icon = NSHostingView(rootView: TaudotMark(dot: TaudotMark.coral).foregroundStyle(Color(nsColor: ink)).frame(height: 56))
    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.heightAnchor.constraint(equalToConstant: 56).isActive = true
    title.font = .systemFont(ofSize: 22, weight: .bold)
    title.alignment = .center
    for l in [subtitle, message, pasteHelp, hereHelp] {
      l.alignment = .center
      l.textColor = .secondaryLabelColor
      l.font = .systemFont(ofSize: NSFont.smallSystemFontSize + 1)
    }
    subtitle.font = .systemFont(ofSize: NSFont.systemFontSize)
    pasteHelp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    hereHelp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    pasteHelp.textColor = .tertiaryLabelColor
    hereHelp.textColor = .tertiaryLabelColor
    message.isSelectable = true
    message.isHidden = true

    browserButton.bezelStyle = .push
    browserButton.controlSize = .large
    browserButton.keyEquivalent = "\r"
    browserButton.bezelColor = TaudotColor.accent
    browserButton.target = self
    browserButton.action = #selector(useBrowser)
    spinner.style = .spinning
    spinner.controlSize = .small
    spinner.isDisplayedWhenStopped = false

    for b in [pasteToggle, hereButton] {
      b.isBordered = false
      b.contentTintColor = TaudotColor.accent
      b.font = .systemFont(ofSize: NSFont.systemFontSize)
      b.target = self
    }
    pasteToggle.action = #selector(togglePaste)
    hereButton.action = #selector(here)

    cookieField.placeholderString = "overleaf_session2 value"
    cookieField.target = self
    cookieField.action = #selector(useCookie)
    cookieButton.target = self
    cookieButton.action = #selector(useCookie)
    let row = NSStackView(views: [cookieField, cookieButton])
    row.spacing = 8
    pasteBox.orientation = .vertical
    pasteBox.spacing = 6
    pasteBox.addArrangedSubview(row)
    pasteBox.addArrangedSubview(pasteHelp)
    pasteBox.isHidden = true

    let buttonRow = NSStackView(views: [browserButton, spinner])
    buttonRow.spacing = 8
    let column = NSStackView(views: [icon, title, subtitle, buttonRow, message, pasteToggle, pasteBox, hereButton, hereHelp])
    column.orientation = .vertical
    column.alignment = .centerX
    column.spacing = 10
    column.setCustomSpacing(14, after: icon)
    column.setCustomSpacing(18, after: subtitle)
    column.setCustomSpacing(22, after: message)
    column.setCustomSpacing(16, after: pasteBox)
    column.setCustomSpacing(4, after: hereButton)
    column.translatesAutoresizingMaskIntoConstraints = false
    addSubview(column)
    NSLayoutConstraint.activate([
      column.centerXAnchor.constraint(equalTo: centerXAnchor),
      column.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -10),
      column.widthAnchor.constraint(equalToConstant: 380),
      subtitle.widthAnchor.constraint(equalTo: column.widthAnchor),
      message.widthAnchor.constraint(equalTo: column.widthAnchor),
      pasteBox.widthAnchor.constraint(equalTo: column.widthAnchor),
      pasteHelp.widthAnchor.constraint(equalTo: column.widthAnchor),
      hereHelp.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -20),
      cookieField.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
    ])
    updateTexts()
  }

  required init?(coder: NSCoder) { fatalError() }

  private var host: String { URL(string: server)?.host ?? server }
  private var cookieName: String { host.hasSuffix("overleaf.com") ? "overleaf_session2" : "overleaf.sid" }

  private func updateTexts() {
    subtitle.stringValue = "Taudot uses your \(host) session, so your edits reach collaborators under your own name. If you’re signed in in your browser, that’s all it needs."
    cookieField.placeholderString = "\(cookieName) value"
    pasteHelp.stringValue = "In your browser on \(host): Developer Tools ▸ Application (Safari: Storage) ▸ Cookies ▸ \(cookieName), copy its value."
    hereButton.title = "Sign in on \(host) here…"
  }

  /// Say something under the button: a plain line, or an error.
  func show(_ text: String, error: Bool = false) {
    message.stringValue = text
    message.isHidden = text.isEmpty
    message.textColor = error ? .systemRed : .secondaryLabelColor
  }

  func reset() {
    show("")
    cookieField.stringValue = ""
    busy(false)
  }

  private func busy(_ on: Bool) {
    for c in [browserButton, cookieButton, cookieField, pasteToggle, hereButton] as [NSControl] { c.isEnabled = !on }
    if on { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
  }

  @objc private func useBrowser() {
    show("Looking in Chrome, Arc, Brave, Edge, Vivaldi and Safari… macOS may ask to let Taudot read your browser’s cookies.")
    run(["from": "browser"])
  }

  @objc private func useCookie() {
    let c = cookieField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !c.isEmpty else { window?.makeFirstResponder(cookieField); return }
    show("Checking the cookie…")
    run(["from": "cookie", "cookie": c])
  }

  @objc private func togglePaste() {
    pasteBox.isHidden.toggle()
    pasteToggle.title = pasteBox.isHidden ? "Paste a session cookie instead" : "Hide"
    if !pasteBox.isHidden { window?.makeFirstResponder(cookieField) }
  }

  @objc private func here() { signInHere?() }

  private func run(_ params: [String: Any]) {
    busy(true)
    Task {
      let err = await login?(params)
      busy(false)
      if let err { show(SignInView.explain(err), error: true) }
    }
  }

  /// The engine's error, shortened for this view: its first line, and for the browser search one line per browser
  /// that had something other than "not installed".
  static func explain(_ err: String) -> String {
    let lines = err.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    guard let first = lines.first else { return err }
    if first.hasPrefix("no logged-in Overleaf session found") {
      let found = lines.dropFirst().filter { $0.contains(":") && !$0.contains("not installed") && !$0.hasPrefix("Log in to") }
      var out = "No signed-in Overleaf session was found in your browsers. Sign in to Overleaf in your browser, then try again."
      if !found.isEmpty { out += "\n\n" + found.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: "\n") }
      return out
    }
    return first.prefix(1).uppercased() + first.dropFirst()
  }
}
