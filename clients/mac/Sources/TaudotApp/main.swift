// taudot for Mac: a folder's Neovim (the user's config), the review margin and the PDF, side by side.
// Usage: taudot-app [FOLDER]   (no folder: the Projects window)
import AppKit
import TaudotHome
import TaudotNeovim
import TaudotShared

// TEXSYNC_* variables (names before the rename) still work (Compat.swift).
Compat.envFallback()
Compat.migrateDefaults()

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
  var projects: [ProjectWindow] = []

  /// Sign-in and the Overleaf projects list: shown when launched without a folder, and from File ▸ Projects….
  lazy var home: HomeWindow = {
    let sock = ProcessInfo.processInfo.environment["TAUDOT_SOCKET"]
      ?? Compat.engineSocket()
    let h = HomeWindow(socket: URL(fileURLWithPath: sock))
    h.onOpen = { [weak self] folder in self?.open(folder) }
    // From a row: the project window grows out of it (nil rect: a fade).
    h.onOpenFrom = { [weak self] folder, rect in self?.open(folder, from: rect) }
    h.isOpen = { [weak self] folder in
      self?.projects.contains { $0.folder.standardizedFileURL.path == folder.standardizedFileURL.path } ?? false
    }
    // Closing it with no project open quits, as closing the last project window does.
    NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: h.window, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { if self?.projects.isEmpty == true { NSApp.terminate(nil) } }
    }
    return h
  }()

  @objc func showHome() { home.show() }
  @objc func showSettings() { SettingsWindow.shared.show() }
  @objc func showAbout() { AboutWindow.shared.show() }
  @objc func showAcknowledgements() { AcknowledgementsWindow.shared.show() }
  @objc func checkForUpdates(_ sender: Any?) { Updater.shared.checkForUpdates(sender) }

  func prewarmSettings(after s: Double) {
    DispatchQueue.main.asyncAfter(deadline: .now() + s) { [self] in
      // (keys the app got count too: posted ones aren't session events, and a 140 ms build under typing is a hitch)
      if CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!) < 1
        || Latency.now - Latency.shared.lastKeyAt < 2 { prewarmSettings(after: 2) }
      else { SettingsWindow.prewarm() }
    }
  }

  /// Settings ▸ Editor ▸ Reopen Windows in This Mode: each project window in the other mode opens again in the chosen
  /// one (the new window first, so the app never runs out of windows and quits), then the old one closes. The old
  /// window's save question comes before anything opens (A14): Cancel leaves it as it is, with no second window.
  @objc func reopenInEditorMode() {
    let want = TaudotSettings.shared.editorMode
    Task {
      for p in projects where p.mode != want {
        guard await p.readyToQuit() else { continue }
        open(p.folder)
        if await p.shutdown(asked: true) { p.window.close() }
      }
    }
  }

  /// Settings ▸ Appearance ▸ Theme for the whole app (System follows macOS).
  func applyAppearance() {
    switch TaudotSettings.shared.appearance {
    case "light": NSApp.appearance = NSAppearance(named: .aqua)
    case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
    default: NSApp.appearance = nil
    }
  }

  func applicationDidFinishLaunching(_ n: Notification) {
    timeline("did finish launching")
    // A self-contained app (docs/release.md): its engine's launch agent points at this bundle; updates by Sparkle.
    _ = BundledTools.ensured
    Updater.shared.start()
    // the last crash, if there was one we haven't shown (after the windows are up)
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { MainActor.assumeIsolated { CrashReport.showIfAny() } }
    buildMenu()
    applyAppearance()
    timeline("menu built")
    NotificationCenter.default.addObserver(forName: TaudotSettings.changed, object: nil, queue: .main) { [weak self] n in
      let key = n.userInfo?["key"] as? String
      MainActor.assumeIsolated { if key == "taudot.appearance" { self?.applyAppearance() } }
    }
    if let sec = ProcessInfo.processInfo.environment["TAUDOT_SETTINGSSHOT"] {
      // Screenshots: the Settings window on a section, behind other windows.
      SettingsWindow.shared.show(section: SettingsSection(rawValue: sec) ?? .appearance)
    }
    if ProcessInfo.processInfo.environment["TAUDOT_ABOUTSHOT"] != nil { showAbout() }
    let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
    if let path = args.first {
      open(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
    } else if ProcessInfo.processInfo.environment["TAUDOT_SETTINGSSHOT"] == nil && ProcessInfo.processInfo.environment["TAUDOT_ABOUTSHOT"] == nil {
      home.show()
    }
    if !backgroundRun { NSApp.activate() }
    // Settings, ahead of ⌘,: once launch has settled (the first PDF page lands at ~2 s) and the user isn't typing or
    // pointing (it holds the main thread ~0.2 s).
    if ProcessInfo.processInfo.environment["TAUDOT_NO_PREWARM"] == nil { prewarmSettings(after: 5) }
    // Measuring ⌘, (TAUDOT_TIMELINE): open Settings this many seconds after launch.
    if let t = ProcessInfo.processInfo.environment["TAUDOT_SETTINGS_AT"].flatMap(Double.init) {
      DispatchQueue.main.asyncAfter(deadline: .now() + t) { [self] in timeline("settings menu"); showSettings() }
    }
    // Tests/shell_quit.sh: TAUDOT_QUIT_TEST=quit:SECONDS (⌘Q) or close:SECONDS (⌘W / the close button).
    if let q = ProcessInfo.processInfo.environment["TAUDOT_QUIT_TEST"]?.split(separator: ":"), q.count == 2, let t = Double(q[1]) {
      DispatchQueue.main.asyncAfter(deadline: .now() + t) { [self] in
        if q[0] == "close" { projects.first?.window.performClose(nil) } else { NSApp.terminate(nil) }
      }
    }
  }

  func open(_ folder: URL, from rect: NSRect? = nil) {
    do {
      let p = try ProjectWindow(folder: folder.standardizedFileURL)
      p.growFrom = rect
      p.boot()
      projects.append(p)
      p.onClose = { [weak self, weak p] in
        guard let self else { return }
        projects.removeAll { $0 === p }
        if projects.isEmpty && !quitting && !home.window.isVisible { NSApp.terminate(nil) }
      }
      Task { await p.start() }
    } catch {
      NSAlert(error: error).runModal()
    }
  }

  @objc func openPanel() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.prompt = "Open Project"
    if panel.runModal() == .OK, let url = panel.url { open(url) }
  }

  var quitting = false

  /// ⌘Q: each window ends its Neovim (asking only about modified non-taudot files), never waiting on a hung one,
  /// then the app terminates. (Not `.terminateLater`: its modal run-loop mode doesn't serve the main queue, so the
  /// replies from Neovim would never arrive.)
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if projects.isEmpty || projects.allSatisfy(\.closing) { return .terminateNow }
    if quitting { return .terminateCancel }
    quitting = true
    Task {
      // Two phases (A4): every window's question first, none stopped until all agree; a Cancel leaves them all as
      // they were.
      for p in projects where !(await p.readyToQuit()) { quitting = false; return }
      for p in projects { _ = await p.shutdown(asked: true) }
      NSApp.terminate(nil)
    }
    return .terminateCancel
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    for u in urls { open(u.hasDirectoryPath ? u : u.deletingLastPathComponent()) }
  }

  func buildMenu() {
    let main = NSMenu()
    let appItem = NSMenuItem()
    main.addItem(appItem)
    let app = NSMenu()
    app.addItem(withTitle: "About Taudot", action: #selector(showAbout), keyEquivalent: "")
    app.addItem(withTitle: "Acknowledgements", action: #selector(showAcknowledgements), keyEquivalent: "")
    if Updater.shared.available { app.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates(_:)), keyEquivalent: "") }
    app.addItem(.separator())
    app.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
    app.addItem(.separator())
    app.addItem(withTitle: "Hide Taudot", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    app.addItem(withTitle: "Quit Taudot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = app
    let fileItem = NSMenuItem()
    main.addItem(fileItem)
    let file = NSMenu(title: "File")
    file.addItem(withTitle: "Projects…", action: #selector(showHome), keyEquivalent: "O")
    file.addItem(withTitle: "Open Folder…", action: #selector(openPanel), keyEquivalent: "o")
    file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    fileItem.submenu = file
    // Edit: the standard items, sent to the first responder. The native editor (an NSTextView) gets ⌘Z ⌘C ⌘V ⌘X ⌘A
    // only through these. Neovim's view implements none of them, so there they're disabled and the keys reach Neovim
    // as <D-…> (EditorView+Input). Then Find (the find bar, Find.swift).
    let editItem = NSMenuItem()
    main.addItem(editItem)
    let edit = NSMenu(title: "Edit")
    edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
    edit.addItem(.separator())
    edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    edit.addItem(.separator())
    let findItem = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
    let findMenu = NSMenu(title: "Find")
    findMenu.addItem(withTitle: "Find…", action: #selector(ProjectWindow.findShow(_:)), keyEquivalent: "f")
    findMenu.addItem(withTitle: "Find and Replace…", action: #selector(ProjectWindow.findReplace(_:)), keyEquivalent: "f").keyEquivalentModifierMask = [.command, .option]
    findMenu.addItem(withTitle: "Find Next", action: #selector(ProjectWindow.findNext(_:)), keyEquivalent: "g")
    findMenu.addItem(withTitle: "Find Previous", action: #selector(ProjectWindow.findPrevious(_:)), keyEquivalent: "G")
    findItem.submenu = findMenu
    edit.addItem(findItem)
    editItem.submenu = edit
    let viewItem = NSMenuItem()
    main.addItem(viewItem)
    let view = NSMenu(title: "View")
    func item(_ title: String, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = .command) {
      view.addItem(withTitle: title, action: action, keyEquivalent: key).keyEquivalentModifierMask = mods
    }
    item("Show/Hide Sidebar", #selector(ProjectWindow.toggleMargin(_:)), "s", [.command, .control])
    item("Show/Hide PDF", #selector(ProjectWindow.togglePDF(_:)), "\\")
    item("Show/Hide Editor", #selector(ProjectWindow.toggleEditor(_:)), "\\", [.command, .option])
    item("Show Comments on PDF", #selector(ProjectWindow.togglePDFComments(_:)), "k", [.command, .shift])
    item("Show Comments in the Text", #selector(ProjectWindow.toggleCommentsInText(_:)), "k", [.command, .option])
    let alias = NSMenuItem(title: "Show/Hide Comments", action: #selector(ProjectWindow.toggleMargin(_:)), keyEquivalent: "\\")
    alias.keyEquivalentModifierMask = [.command, .shift]
    alias.isAlternate = false
    alias.isHidden = true            // ⇧⌘\: the old key for the margin, kept working
    alias.allowsKeyEquivalentWhenHidden = true
    view.addItem(alias)
    item("Show Files", #selector(ProjectWindow.showSidebarFiles(_:)), "e", [.command, .shift])
    item("Show Comments", #selector(ProjectWindow.showSidebarComments(_:)), "m", [.command, .shift])
    item("Show History", #selector(ProjectWindow.showSidebarHistory(_:)), "h", [.command, .shift])
    item("Show Issues", #selector(ProjectWindow.toggleIssues(_:)), "e", [.command, .option])
    view.addItem(.separator())
    // The editor's font, both editor modes (TaudotSettings.fontSize, as Settings ▸ Editor sets it).
    item("Bigger", #selector(ProjectWindow.fontBigger(_:)), "+")
    let biggerAlias = NSMenuItem(title: "Bigger", action: #selector(ProjectWindow.fontBigger(_:)), keyEquivalent: "=")
    biggerAlias.isHidden = true      // ⌘= (no shift): the same as ⌘+
    biggerAlias.allowsKeyEquivalentWhenHidden = true
    view.addItem(biggerAlias)
    item("Smaller", #selector(ProjectWindow.fontSmaller(_:)), "-")
    item("Actual Size", #selector(ProjectWindow.fontActualSize(_:)), "0")
    view.addItem(.separator())
    let focusHeader = NSMenuItem(title: "Focus", action: nil, keyEquivalent: "")
    focusHeader.isEnabled = false
    view.addItem(focusHeader)
    item("Sidebar", #selector(ProjectWindow.focusSidebar(_:)), "1")
    item("Neovim", #selector(ProjectWindow.focusEditor(_:)), "2")
    item("PDF", #selector(ProjectWindow.focusPDF(_:)), "3")
    item("Next Pane", #selector(ProjectWindow.focusNextPane(_:)), "]")
    item("Previous Pane", #selector(ProjectWindow.focusPreviousPane(_:)), "[")
    item("Pane to the Left", #selector(ProjectWindow.focusPaneLeft(_:)), String(UnicodeScalar(NSLeftArrowFunctionKey)!), [.command, .option])
    item("Pane to the Right", #selector(ProjectWindow.focusPaneRight(_:)), String(UnicodeScalar(NSRightArrowFunctionKey)!), [.command, .option])
    item("Zoom Pane", #selector(ProjectWindow.toggleZoom(_:)), "e")
    item("Neovim Only", #selector(ProjectWindow.neovimOnly(_:)), "2", [.command, .option])
    item("PDF Only", #selector(ProjectWindow.pdfOnly(_:)), "3", [.command, .option])
    view.addItem(.separator())
    let claudeItem = NSMenuItem(title: "Claude", action: nil, keyEquivalent: "")
    let claudeMenu = NSMenu(title: "Claude")
    claudeMenu.addItem(withTitle: "Show/Hide Claude", action: #selector(ProjectWindow.toggleClaude(_:)), keyEquivalent: "j")
    claudeMenu.addItem(withTitle: "Ask Claude About This", action: #selector(ProjectWindow.askClaude(_:)), keyEquivalent: "l")
    claudeMenu.addItem(withTitle: "Ask Claude to Fix All Errors", action: #selector(ProjectWindow.askClaudeToFixAll(_:)), keyEquivalent: "")
    claudeMenu.addItem(withTitle: "Ask Claude to Fix the First Issue", action: #selector(ProjectWindow.askClaudeToFixFirst(_:)), keyEquivalent: "")
    claudeMenu.addItem(.separator())
    claudeMenu.addItem(withTitle: "Floating", action: #selector(ProjectWindow.setClaudeFloating(_:)), keyEquivalent: "")
    claudeMenu.addItem(withTitle: "Docked", action: #selector(ProjectWindow.setClaudeDocked(_:)), keyEquivalent: "")
    claudeItem.submenu = claudeMenu
    view.addItem(claudeItem)
    view.addItem(.separator())
    view.addItem(withTitle: "Show Line in PDF", action: #selector(ProjectWindow.forwardSearch(_:)), keyEquivalent: "j").keyEquivalentModifierMask = [.command, .option]
    viewItem.submenu = view
    // Review: every review action with its key (docs/agents/margin-keys.md). The verbs act on the selected card,
    // else the one at the cursor, from any pane, then move to the next item; next / previous follow the filter.
    let reviewItem = NSMenuItem()
    main.addItem(reviewItem)
    let review = NSMenu(title: "Review")
    func ritem(_ title: String, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = [.command, .option]) {
      review.addItem(withTitle: title, action: action, keyEquivalent: key).keyEquivalentModifierMask = mods
    }
    ritem("Review Suggestions…", #selector(ProjectWindow.reviewStart(_:)), "", [])
    ritem("Next Item", #selector(ProjectWindow.nextComment(_:)), String(UnicodeScalar(NSDownArrowFunctionKey)!))
    ritem("Previous Item", #selector(ProjectWindow.previousComment(_:)), String(UnicodeScalar(NSUpArrowFunctionKey)!))
    review.addItem(.separator())
    ritem("Accept Suggestion / Reply to Comment", #selector(ProjectWindow.reviewAcceptOrReply(_:)), "\r")
    ritem("Reject Suggestion", #selector(ProjectWindow.reviewReject(_:)), String(UnicodeScalar(NSBackspaceCharacter)!))
    ritem("Resolve Comment", #selector(ProjectWindow.reviewResolve(_:)), "r")
    ritem("New Comment on Selection", #selector(ProjectWindow.reviewNewComment(_:)), "m")
    review.addItem(.separator())
    ritem("Accept All Suggestions in This File…", #selector(ProjectWindow.reviewAcceptAll(_:)), "", [])
    ritem("Reject All Suggestions in This File…", #selector(ProjectWindow.reviewRejectAll(_:)), "", [])
    review.addItem(.separator())
    let show = NSMenuItem(title: "Show", action: nil, keyEquivalent: "")
    let showMenu = NSMenu(title: "Show")
    for (t, tag) in [("Comments and Suggestions", 3), ("Comments Only", 1), ("Suggestions Only", 2)] {
      let i = NSMenuItem(title: t, action: #selector(ProjectWindow.reviewShow(_:)), keyEquivalent: "")
      i.tag = tag
      showMenu.addItem(i)
    }
    showMenu.addItem(.separator())
    for (t, tag) in [("Suggestions (Markup)", 10), ("Preview All Accepted", 11), ("Preview All Rejected", 12)] {
      let i = NSMenuItem(title: t, action: #selector(ProjectWindow.reviewPreview(_:)), keyEquivalent: "")
      i.tag = tag
      showMenu.addItem(i)
    }
    show.submenu = showMenu
    review.addItem(show)
    reviewItem.submenu = review
    let winItem = NSMenuItem()
    main.addItem(winItem)
    let win = NSMenu(title: "Window")
    win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    win.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
    win.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f").keyEquivalentModifierMask = [.command, .control]
    winItem.submenu = win
    NSApp.windowsMenu = win
    NSApp.mainMenu = main
  }
}

/// A measured run (bench, checks): never come to the front of the user's screen (docs/agents/README.md, "Tests must not
/// disturb the user's screen"). TAUDOT_OFFSCREEN=1 makes any run one.
let backgroundRun = ["TAUDOT_OFFSCREEN", "TAUDOT_MEASURE", "TAUDOT_BENCH", "TAUDOT_WIRECHECK", "TAUDOT_SCROLLTRACE", "TAUDOT_QUIT_TEST", "TAUDOT_PANECHECK", "TAUDOT_CLAUDECHECK", "TAUDOT_CLAUDESHOT", "TAUDOT_ONSCREEN", "TAUDOT_SETTINGSSHOT", "TAUDOT_NATIVECHECK", "TAUDOT_ONTOP", "TAUDOT_ISSUESSHOT", "TAUDOT_ABOUTSHOT", "TAUDOT_HISTORYCHECK", "TAUDOT_STATECHECK", "TAUDOT_FINDCHECK", "TAUDOT_FLOATCHECK"].contains { ProcessInfo.processInfo.environment[$0] != nil }
// A child that dies (txp-headless without tectonic, a crashed Neovim) must never take the app with it: writes to its closed
// pipe fail with EPIPE instead of killing us.
signal(SIGPIPE, SIG_IGN)
MainActor.assumeIsolated { Latency.shared.install(); timeline("main"); CrashReport.crashOnExceptions() }
LoginEnvironment.shared.prefetch()
let app = NSApplication.shared
// Background runs: no Dock icon and never activated. TAUDOT_ONSCREEN / ONTOP / CLAUDESHOT (opt-in, real screen):
// accessory, so the checks that need the app active can activate it.
let measureRun = ProcessInfo.processInfo.environment["TAUDOT_MEASURE"] != nil
let onScreenRun = ["TAUDOT_ONSCREEN", "TAUDOT_ONTOP", "TAUDOT_CLAUDESHOT"].contains { ProcessInfo.processInfo.environment[$0] != nil }
// TAUDOT_MEASURE (with TAUDOT_OFFSCREEN; Tests/perf): .accessory, whose windows do order in (off every screen), so
// frames are drawn, committed and presented as for the user, and can be captured; still no Dock icon, never activated.
app.setActivationPolicy(!backgroundRun ? .regular : onScreenRun || measureRun ? .accessory : .prohibited)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
