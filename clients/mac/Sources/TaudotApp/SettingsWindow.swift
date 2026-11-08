// Settings (⌘,): the window, its sections and its model. The view is SettingsView.swift (Rex's language on Liquid
// Glass, the Taudot palette). Everything is kept in `TaudotSettings` (UserDefaults) and applies live to open windows
// (ProjectWindow.applySettings on TaudotSettings.changed).
import AppKit
import SwiftUI
import TaudotNeovim
import TaudotPDF
import TaudotShared

@MainActor final class SettingsWindow {
  static let shared = SettingsWindow()
  let window: NSWindow
  let model = SettingsModel()

  init() {
    timeline("settings init")
    window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
                      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    window.title = "Settings"
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.isReleasedWhenClosed = false
    // an empty unified toolbar: a taller title bar, so the traffic lights sit inside the sidebar's glass, clear of its
    // rounded corner (as in System Settings), not on its rim
    window.toolbar = NSToolbar(identifier: "taudot.settings")
    window.toolbarStyle = .unified
    window.contentViewController = NSHostingController(rootView: SettingsView(model: model))
    window.setContentSize(NSSize(width: 920, height: 680))
    window.minSize = NSSize(width: 820, height: 600)
    // screenshots: TAUDOT_SETTINGS_APPEARANCE=light|dark forces one
    if let a = ProcessInfo.processInfo.environment["TAUDOT_SETTINGS_APPEARANCE"] {
      window.appearance = NSAppearance(named: a == "dark" ? .darkAqua : .aqua)
    }
    timeline("settings hosted")
    if !backgroundRun { window.setFrameAutosaveName("taudot.settings") }  // a measured run never saves its frame
    if window.frame.origin == .zero { window.center() }
  }

  /// Built, laid out and drawn once off screen while the app is idle after launch, so the first ⌘, only orders it in
  /// (it took ~0.5 s: the SwiftUI form's first layout, the font families, the theme files).
  static func prewarm() {
    timeline("settings prewarm")
    _ = SettingsModel.monoFamilies
    let w = shared.window
    w.contentView?.layoutSubtreeIfNeeded()
    w.displayIfNeeded()
    timeline("settings prewarmed")
  }

  func show(section: SettingsSection? = nil) {
    timeline("settings show")
    if let section { model.section = section }
    model.reload()
    if backgroundRun { if !onScreenRun { window.setFrameOrigin(ProjectWindow.offscreenOrigin) }; window.orderBack(nil) } else { window.makeKeyAndOrderFront(nil) }
    timeline("settings ordered front")
    if let f = ProcessInfo.processInfo.environment["TAUDOT_SETTINGS_WINFILE"] {
      // screenshots: the window number, once it has drawn
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [window] in
        try? "\(window.windowNumber)\n".write(toFile: f, atomically: true, encoding: .utf8)
      }
    }
    DispatchQueue.main.async { timeline("settings next turn") }
    if let g = ProcessInfo.processInfo.environment["TAUDOT_SETTINGS_GO"] {
      // screenshots of the page transition: go to these sections (comma-separated), one every 1.5 s after the first draw
      for (i, name) in g.split(separator: ",").enumerated() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5 * Double(i + 1)) { [model] in
          if name == "scroll" { model.testScroll += 1 } else if let s = SettingsSection(rawValue: String(name)) { model.go(s) }
        }
      }
    }
  }
}

enum SettingsSection: String, CaseIterable, Identifiable {
  case appearance = "Appearance", editor = "Editor", pdf = "PDF", comments = "Comments", account = "Account"
  var id: String { rawValue }
  var icon: String {
    switch self {
    case .appearance: "circle.lefthalf.filled"
    case .editor: "character.cursor.ibeam"
    case .pdf: "doc.richtext"
    case .comments: "text.bubble"
    case .account: "person.crop.circle"
    }
  }
  /// What the search finds a section by.
  var keywords: String {
    switch self {
    case .appearance: "dark light system accent colour color look"
    case .editor: "theme font size line height width wrap solarized overleaf paper dusk tomorrow neovim native vim import"
    case .pdf: "highlight follows cursor sepia dark page comments colour color"
    case .comments: "tint underline bar resolved floating card lines"
    case .account: "sign in projects overleaf"
    }
  }
}

/// `TaudotSettings.shared` as observable state for SwiftUI; writing a property writes the setting (which notifies windows).
@MainActor final class SettingsModel: ObservableObject {
  let s = TaudotSettings.shared
  @Published var section: SettingsSection = .appearance
  @Published var search = ""
  @Published var tick = 0
  /// Screenshots (TAUDOT_SETTINGS_GO's "scroll"): each bump scrolls the page to its end.
  @Published var testScroll = 0
  /// The current editor colours, for the "Your Neovim colours" preview (set by an open project window).
  static var neovimColors: (bg: UInt32, fg: UInt32)?

  func reload() { tick += 1 }

  // back / forward between sections (the title's capsule)
  @Published var back: [SettingsSection] = []
  @Published var forward: [SettingsSection] = []
  func go(_ s: SettingsSection) {
    guard s != section else { return }
    back.append(section); forward = []; section = s
  }
  func goBack() { if let s = back.popLast() { forward.append(section); section = s } }
  func goForward() { if let s = forward.popLast() { back.append(section); section = s } }

  /// "Your Neovim colours" in the previews: Dusk's tokens (the user's own colours are only known in Neovim).
  static var neovimTheme: Theme { Theme.named("dusk")! }

  func importTheme() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.message = "Choose a Ghostty theme or an iTerm2 .itermcolors file"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let t = try ThemeCatalog.importTheme(from: url)
      refreshThemes()
      s.editorTheme = t.id
      tick += 1
    } catch {
      let a = NSAlert()
      a.messageText = "Couldn't import the theme"
      a.informativeText = "\(error)"
      a.runModal()
    }
  }

  func removeTheme(_ t: Theme) {
    ThemeCatalog.remove(t.id)
    if s.editorTheme == t.id { s.editorTheme = "dusk" }
    refreshThemes()
    tick += 1
  }
  /// The theme list, read once (Rex's and imported themes are files) and again after an import or a removal.
  @Published var themeGroups: [ThemeCatalog.Group] = ThemeCatalog.groups
  func refreshThemes() { themeGroups = ThemeCatalog.groups }
  func bind<T>(_ get: @escaping (TaudotSettings) -> T, _ set: @escaping (TaudotSettings, T) -> Void) -> Binding<T> {
    Binding(get: { _ = self.tick; return get(self.s) }, set: { set(self.s, $0); self.tick += 1 })
  }

  static let monoFamilies: [String] = {
    let names = NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []
    let fams = Set(names.compactMap { NSFont(name: $0, size: 12)?.familyName }).filter { !$0.hasPrefix(".") }
    return fams.sorted()
  }()
}
