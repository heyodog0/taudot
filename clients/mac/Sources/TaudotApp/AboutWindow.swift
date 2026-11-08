// App menu ▸ About Taudot: the mark and the name over Taudot's ground (the palette Settings and the Projects window
// share), and the version. The lockup is TaudotShared's (the logo agent's TaudotLockup: the mark and the "Hand" word).
import AppKit
import SwiftUI
import TaudotShared

/// "0.1 (abc1234)" from the bundle (bundle.sh writes the git description as CFBundleVersion); an unbundled build
/// (swift build) says so.
func taudotVersion(_ info: [String: Any]? = Bundle.main.infoDictionary) -> String {
  guard let short = info?["CFBundleShortVersionString"] as? String else { return "Development build" }
  let build = info?["CFBundleVersion"] as? String
  return build.map { $0 == short ? "Version \(short)" : "Version \(short) (\($0))" } ?? "Version \(short)"
}

/// The mark and the word on one baseline (the logo agent's TaudotLockup, drawn from outlines; the mark's dot coral).
struct AboutLockup: View {
  var body: some View { TaudotLockup().frame(height: 44) }
}

struct AboutView: View {
  let version: String
  @Environment(\.colorScheme) var scheme
  var p: TaudotPalette { .make(dark: scheme == .dark) }

  var body: some View {
    VStack(spacing: 14) {
      Spacer(minLength: 28)
      AboutLockup().foregroundStyle(p.text)
      Text(version)
        .font(.system(size: 12)).monospacedDigit()
        .foregroundStyle(p.secondary)
        .textSelection(.enabled)
      // The attribution LICENSE's additional terms (AGPL §7(b)) require every copy and derived work to keep.
      VStack(spacing: 2) {
        Text("Taudot by Ryan Truong · AGPL-3.0")
        Link("github.com/heyodog0/taudot", destination: URL(string: "https://github.com/heyodog0/taudot")!)
      }
      .font(.system(size: 11))
      .foregroundStyle(p.secondary)
      Button("Acknowledgements") { AcknowledgementsWindow.shared.show() }
        .buttonStyle(.link)
        .font(.system(size: 11))
        .foregroundStyle(p.secondary)
      Spacer(minLength: 22)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(TaudotGround(p))
    .ignoresSafeArea()
  }
}

@MainActor final class AboutWindow {
  static let shared = AboutWindow()
  let window: NSWindow

  init() {
    window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 220), styleMask: [.titled, .closable, .fullSizeContentView],
                      backing: .buffered, defer: false)
    window.title = "About Taudot"
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.isReleasedWhenClosed = false
    window.isMovableByWindowBackground = true
    let host = NSHostingController(rootView: AboutView(version: taudotVersion()))
    host.sizingOptions = []  // the window's size, not the view's: the ground fills it, under the title bar too
    window.contentViewController = host
    window.setContentSize(NSSize(width: 340, height: 220))
    // screenshots: TAUDOT_ABOUT_APPEARANCE=light|dark forces one
    if let a = ProcessInfo.processInfo.environment["TAUDOT_ABOUT_APPEARANCE"] {
      window.appearance = NSAppearance(named: a == "dark" ? .darkAqua : .aqua)
    }
    window.center()
  }

  func show() {
    if backgroundRun {
      if !onScreenRun { window.setFrameOrigin(ProjectWindow.offscreenOrigin) }
      window.orderBack(nil)
    } else {
      window.makeKeyAndOrderFront(nil)
    }
    if let f = ProcessInfo.processInfo.environment["TAUDOT_ABOUTSHOT"] {
      // screenshots: the window number and the version shown, once it has drawn
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [window] in
        try? "\(window.windowNumber)\n\(taudotVersion())\n".write(toFile: f, atomically: true, encoding: .utf8)
      }
    }
  }
}
