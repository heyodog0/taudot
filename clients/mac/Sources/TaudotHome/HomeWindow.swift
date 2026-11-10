// The home window: what taudot shows when it opens without a folder, and from File ▸ Projects… (⇧⌘O).
// Liquid Glass with a faint Taudot tint; the accent only in small touches (Flair.swift). Signed out: SignInView. Signed in: the projects (ProjectsView) with a toolbar for the filter, search and account.
// Opening a project that isn't on this Mac yet clones it first (into ~/Overleaf/<name>, or the folder chosen in the
// account menu), then hands the folder to `onOpen`.
import AppKit
import TaudotShared

/// ⌘R refreshes, ⌘F goes to the search field, wherever focus is.
final class HomeNSWindow: NSWindow {
  var onRefresh: (() -> Void)?
  var onFind: (() -> Void)?
  var onNew: (() -> Void)?
  override func performKeyEquivalent(with e: NSEvent) -> Bool {
    let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if mods == .command, let c = e.charactersIgnoringModifiers {
      if c == "r" { onRefresh?(); return true }
      if c == "f" { onFind?(); return true }
      if c == "n" { onNew?(); return true }
    }
    return super.performKeyEquivalent(with: e)
  }
}

@MainActor public final class HomeWindow: NSObject, NSWindowDelegate, NSToolbarDelegate, NSSearchFieldDelegate, ProjectsViewDelegate {
  public let window: NSWindow
  public let engine: HomeEngine
  /// The Overleaf server: `$TAUDOT_SERVER`, the `taudot.server` default, else overleaf.com.
  public let server: String
  /// Open this project folder in a project window.
  public var onOpen: ((URL) -> Void)?
  /// Open this folder, growing the window out of the project's row: `from` is the row's selection pill in screen
  /// coordinates, measured just before the home window hides (nil when the row isn't on screen). When set, it is
  /// called instead of `onOpen`.
  public var onOpenFrom: ((URL, NSRect?) -> Void)?
  /// Whether a project window has this folder open (then its local copy can't be removed).
  public var isOpen: ((URL) -> Bool)?
  /// Close the home window once a project opens, as Xcode's welcome window does.
  public var closesOnOpen = true
  /// "checking", "signedOut", "projects" (after each list load), "error": for tests and screenshots.
  public var onState: ((String) -> Void)?

  public static let projectsFolderKey = "taudot.projectsFolder"

  private let signIn = SignInView(frame: .zero)
  private let list = ProjectsView(frame: .zero)
  private let statusLabel = NSTextField(labelWithString: "")
  private let statusSpinner = NSProgressIndicator()
  private let checking = NSProgressIndicator()
  private let body = NSView()
  private let statusBar = NSView()
  private let filter = NSSegmentedControl()
  private var searchItem: NSSearchToolbarItem?
  private let accountMenu = NSMenu()
  private var account: [String: Any] = [:]
  private var lastLoad = Date.distantPast
  private var loadGeneration = 0
  /// Bumped by each account question (status, sign-in, sign-out): only the newest one's answer is applied (A22).
  private var accountGeneration = 0
  private var web: WebSignIn?

  public init(socket: URL, server: String? = nil) {
    let env = ProcessInfo.processInfo.environment
    self.server = (server ?? env["TAUDOT_SERVER"] ?? UserDefaults.standard.string(forKey: "taudot.server") ?? "https://www.overleaf.com")
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    engine = HomeEngine(socket: socket)
    let w = HomeNSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 520),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    window = w
    super.init()
    w.onRefresh = { [weak self] in self?.refresh() }
    w.onFind = { [weak self] in self?.focusSearch() }
    w.onNew = { [weak self] in self?.newProject() }
    // Show up on the Space the user is on, not where it was last.
    window.collectionBehavior.insert(.moveToActiveSpace)
    // Glass: the window itself is clear and Liquid Glass fills it (build()).
    window.isOpaque = false
    window.backgroundColor = .clear
    window.title = "Projects"
    window.titlebarSeparatorStyle = .none
    window.titlebarAppearsTransparent = true
    window.minSize = NSSize(width: 620, height: 380)
    window.isReleasedWhenClosed = false
    window.tabbingMode = .disallowed
    window.delegate = self
    window.setFrameAutosaveName("taudot.home")
    if !window.setFrameUsingName("taudot.home") { window.center() }
    build()
    signIn.server = self.server
    signIn.login = { [weak self] params in await self?.login(params) }
    signIn.signInHere = { [weak self] in self?.webSignIn() }
    list.delegate = self
    engine.onCloneProgress = { [weak self] p in self?.cloneProgress(p) }
  }

  private var serverHost: String { URL(string: server)?.host ?? server }

  public var projectsFolder: URL {
    get {
      let p = UserDefaults.standard.string(forKey: HomeWindow.projectsFolderKey) ?? "~/Overleaf"
      return URL(fileURLWithPath: (p as NSString).expandingTildeInPath, isDirectory: true)
    }
    set { UserDefaults.standard.set(ProjectList.abbreviate(newValue.path), forKey: HomeWindow.projectsFolderKey) }
  }

  // MARK: layout

  private func build() {
    let content = NSView()
    window.contentView = HomeWindow.glass(holding: content)
    for v in [body, statusBar] { v.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(v) }
    statusBar.wantsLayer = true
    let line = NSBox()
    line.boxType = .separator
    statusLabel.textColor = .secondaryLabelColor
    statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    statusLabel.lineBreakMode = .byTruncatingMiddle
    statusSpinner.style = .spinning
    statusSpinner.controlSize = .small
    statusSpinner.isDisplayedWhenStopped = false
    for v in [line, statusLabel, statusSpinner] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; statusBar.addSubview(v) }
    checking.style = .spinning
    checking.isDisplayedWhenStopped = false
    NSLayoutConstraint.activate([
      body.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor),
      body.leadingAnchor.constraint(equalTo: content.leadingAnchor), body.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      body.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
      statusBar.leadingAnchor.constraint(equalTo: content.leadingAnchor), statusBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      statusBar.bottomAnchor.constraint(equalTo: content.bottomAnchor), statusBar.heightAnchor.constraint(equalToConstant: 26),
      line.topAnchor.constraint(equalTo: statusBar.topAnchor), line.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor),
      line.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor),
      statusSpinner.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 12),
      statusSpinner.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
      statusLabel.leadingAnchor.constraint(equalTo: statusSpinner.trailingAnchor, constant: 6),
      statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: statusBar.trailingAnchor, constant: -12),
      statusLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
    ])
    filter.segmentCount = ProjectFilter.allCases.count
    for (i, f) in ProjectFilter.allCases.enumerated() { filter.setLabel(f.title, forSegment: i) }
    filter.selectedSegment = 0
    filter.target = self
    filter.action = #selector(filterChanged)
    filter.segmentStyle = .automatic
  }

  private func setBody(_ v: NSView) {
    body.subviews.forEach { $0.removeFromSuperview() }
    v.translatesAutoresizingMaskIntoConstraints = false
    body.addSubview(v)
    NSLayoutConstraint.activate([
      v.topAnchor.constraint(equalTo: body.topAnchor), v.bottomAnchor.constraint(equalTo: body.bottomAnchor),
      v.leadingAnchor.constraint(equalTo: body.leadingAnchor), v.trailingAnchor.constraint(equalTo: body.trailingAnchor),
    ])
  }

  private func setToolbar(_ on: Bool) {
    if on, window.toolbar == nil {
      let t = NSToolbar(identifier: "taudot.home")
      t.delegate = self
      t.displayMode = .iconOnly
      t.allowsUserCustomization = false
      window.toolbar = t
      window.toolbarStyle = .unified
    } else if !on {
      window.toolbar = nil
    }
  }

  private func status(_ text: String, busy: Bool = false) {
    statusLabel.stringValue = text
    if busy { statusSpinner.startAnimation(nil) } else { statusSpinner.stopAnimation(nil) }
  }

  // MARK: states

  public func show() {
    window.makeKeyAndOrderFront(nil)
    if account.isEmpty { check() } else { refresh() }
  }

  /// Tests and screenshots: the window off every screen and behind everything, never key, so nothing appears on
  /// the user's screen and no focus moves (docs/agents/README.md, Tests must not disturb the user's screen).
  public func showOffscreen() {
    window.collectionBehavior.remove(.moveToActiveSpace)
    let all = NSScreen.screens.reduce(NSRect.zero) { $0.union($1.frame) }
    window.setFrameOrigin(NSPoint(x: all.maxX + 2000, y: all.minY))
    window.orderBack(nil)
    if account.isEmpty { check() } else { refresh() }
  }

  /// Ask the engine who is signed in, then show the sign-in view or the list.
  public func check() {
    setToolbar(false)
    let spin = NSView()
    checking.translatesAutoresizingMaskIntoConstraints = false
    spin.addSubview(checking)
    NSLayoutConstraint.activate([checking.centerXAnchor.constraint(equalTo: spin.centerXAnchor), checking.centerYAnchor.constraint(equalTo: spin.centerYAnchor)])
    setBody(spin)
    checking.startAnimation(nil)
    status("Connecting to the sync engine…", busy: false)
    accountGeneration += 1
    let gen = accountGeneration
    onState?("checking")
    Task {
      do {
        let st = try await engine.call("account.status", ["url": server])
        guard gen == accountGeneration else { return }
        checking.stopAnimation(nil)
        if st["logged_in"] as? Bool == true { signedIn(st) } else {
          signedOut(st["expired"] as? Bool == true ? "Your \(serverHost) session has expired or was signed out. Sign in again." : nil)
        }
      } catch {
        guard gen == accountGeneration else { return }
        checking.stopAnimation(nil)
        signedOut("\(error)", error: true)
      }
    }
  }

  private func signedOut(_ note: String? = nil, error: Bool = false) {
    account = [:]
    list.projects = []
    setToolbar(false)
    window.title = "Taudot"
    window.subtitle = ""
    signIn.reset()
    if let note { signIn.show(note, error: error) }
    setBody(signIn)
    status("Not signed in to \(serverHost)")
    onState?("signedOut")
  }

  private func signedIn(_ st: [String: Any]) {
    account = st
    list.me = st["user_id"] as? String
    setToolbar(true)
    window.title = "Projects"
    window.subtitle = serverHost
    rebuildAccountMenu()
    setBody(list)
    refresh()
  }

  private func login(_ params: [String: Any]) async -> String? {
    accountGeneration += 1
    let gen = accountGeneration
    var p = params
    p["url"] = server
    do {
      let st = try await engine.call("account.login", p)
      guard gen == accountGeneration else { return nil }  // (a newer question decides)
      signedIn(st)
      if let s = st["source"] as? String { status("Signed in with \(HomeWindow.sourceName(s))’s session", busy: true) }
      return nil
    } catch {
      return "\(error)"
    }
  }

  static func sourceName(_ s: String) -> String {
    ["chrome": "Chrome", "arc": "Arc", "brave": "Brave", "edge": "Edge", "vivaldi": "Vivaldi", "safari": "Safari",
     "cookie": "a pasted cookie", "webview": "this window", "engine": "the engine", "keychain": "a saved"][s] ?? s
  }

  /// Load the list again. Quiet when there is already one on screen.
  public func refresh() {
    guard !account.isEmpty else { check(); return }
    loadGeneration += 1
    let gen = loadGeneration
    list.loading = true
    if list.projects.isEmpty { status("Loading projects…", busy: true) }
    lastLoad = Date()
    Task {
      do {
        try? FileManager.default.createDirectory(at: projectsFolder, withIntermediateDirectories: true)
        let r = try await engine.call("projects.list", ["url": server, "scan": [projectsFolder.path]])
        guard gen == loadGeneration else { return }
        let ps = (r["projects"] as? [[String: Any]] ?? []).compactMap(HomeProject.init(json:))
        list.loading = false
        list.projects = ps
        if list.cloning.isEmpty { summary() }
        onState?("projects")
      } catch {
        guard gen == loadGeneration else { return }
        list.loading = false
        let msg = "\(error)"
        if msg.contains("expired") || msg.contains("not logged in") || msg.contains("logged out") {
          signedOut("Your \(serverHost) session has expired or was signed out. Sign in again.")
        } else {
          status("Couldn’t load projects: \(msg.split(separator: "\n").first ?? "")")
          onState?("error")
        }
      }
    }
  }

  private func summary() {
    let n = list.projects.filter { !$0.archived && !$0.trashed }.count
    let local = list.projects.filter(\.isLocal).count
    var s = "\(n) project\(n == 1 ? "" : "s")"
    if local > 0 { s += " · \(local) on this Mac" }
    status(s)
  }

  // MARK: toolbar

  private static let filterID = NSToolbarItem.Identifier("filter")
  private static let searchID = NSToolbarItem.Identifier("search")
  private static let accountID = NSToolbarItem.Identifier("account")
  private static let newID = NSToolbarItem.Identifier("new")

  public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [HomeWindow.newID, HomeWindow.filterID, .flexibleSpace, HomeWindow.searchID, HomeWindow.accountID]
  }

  public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }

  public func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
    switch id {
    case HomeWindow.filterID:
      let i = NSToolbarItem(itemIdentifier: id)
      i.view = filter
      i.label = "Filter"
      return i
    case HomeWindow.newID:
      let i = NSToolbarItem(itemIdentifier: id)
      i.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Project")
      i.label = "New Project"
      i.toolTip = "New Project (⌘N)"
      i.target = self
      i.action = #selector(newProjectAction)
      i.isBordered = true
      if Flair.on, #available(macOS 26.0, *) {
        // The one filled control: teal, so the white + reads in both modes.
        i.style = .prominent
        i.backgroundTintColor = Flair.button
      }
      return i
    case HomeWindow.searchID:
      let i = NSSearchToolbarItem(itemIdentifier: id)
      i.searchField.placeholderString = "Search projects"
      i.searchField.delegate = self
      i.searchField.target = self
      i.searchField.action = #selector(searchChanged(_:))
      i.preferredWidthForSearchField = 220
      searchItem = i
      return i
    case HomeWindow.accountID:
      let i = NSMenuToolbarItem(itemIdentifier: id)
      i.image = NSImage(systemSymbolName: "person.crop.circle", accessibilityDescription: "Account")
      i.label = "Account"
      i.menu = accountMenu
      i.showsIndicator = false
      accountItem = i
      updateAvatar()
      i.toolTip = "Account"
      return i
    default: return nil
    }
  }

  @objc private func refreshAction() { refresh() }

  @objc private func filterChanged() {
    list.query.filter = ProjectFilter.allCases[max(0, filter.selectedSegment)]
  }

  @objc private func searchChanged(_ f: NSSearchField) { list.query.search = f.stringValue }

  public func controlTextDidChange(_ n: Notification) {
    if let f = n.object as? NSSearchField { list.query.search = f.stringValue }
  }

  public func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
    // From the search field: ↓ moves into the list, Return opens the first match.
    if sel == #selector(NSResponder.moveDown(_:)) || sel == #selector(NSResponder.insertNewline(_:)) {
      if let i = list.rows.firstIndex(where: { if case .project = $0 { true } else { false } }) {
        if list.table.selectedRow < 0 { list.table.selectRowIndexes([i], byExtendingSelection: false) }
        if sel == #selector(NSResponder.insertNewline(_:)) { list.openSelected() } else { window.makeFirstResponder(list.table) }
      }
      return true
    }
    return false
  }

  private func focusSearch() {
    if let f = searchItem?.searchField { window.makeFirstResponder(f) }
  }

  private weak var accountItem: NSMenuToolbarItem?

  /// The account item: your initials on a small gradient (flair), else the plain person symbol.
  private func updateAvatar() {
    guard let i = accountItem else { return }
    let who = (account["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (account["email"] as? String ?? "")
    let initials = who.split { !$0.isLetter }.prefix(2).compactMap(\.first).map { String($0).uppercased() }.joined()
    if Flair.on && !initials.isEmpty {
      i.image = Flair.avatar(initials)
    } else {
      i.image = NSImage(systemSymbolName: "person.crop.circle", accessibilityDescription: "Account")
    }
  }

  private func rebuildAccountMenu() {
    updateAvatar()
    accountMenu.removeAllItems()
    let name = account["name"] as? String ?? ""
    let email = account["email"] as? String ?? ""
    let head = NSMenuItem(title: name, action: nil, keyEquivalent: "")
    head.attributedTitle = NSAttributedString(string: name.isEmpty ? email : name, attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
    head.isEnabled = false
    accountMenu.addItem(head)
    if !email.isEmpty && !name.isEmpty { let e = accountMenu.addItem(withTitle: email, action: nil, keyEquivalent: ""); e.isEnabled = false }
    if let s = account["source"] as? String {
      let src = s == "keychain" ? "Signed in on \(serverHost)" : "Session from \(HomeWindow.sourceName(s))"
      let e = accountMenu.addItem(withTitle: src, action: nil, keyEquivalent: ""); e.isEnabled = false
    }
    accountMenu.addItem(.separator())
    let folder = accountMenu.addItem(withTitle: "Projects Folder: \(ProjectList.abbreviate(projectsFolder.path))…", action: #selector(chooseFolder), keyEquivalent: "")
    folder.target = self
    accountMenu.addItem(.separator())
    let out = accountMenu.addItem(withTitle: "Log Out", action: #selector(logOut), keyEquivalent: "")
    out.target = self
  }

  @objc private func chooseFolder() {
    let p = NSOpenPanel()
    p.canChooseDirectories = true
    p.canChooseFiles = false
    p.canCreateDirectories = true
    p.prompt = "Use This Folder"
    p.message = "New local copies of projects go in this folder."
    p.directoryURL = projectsFolder
    p.beginSheetModal(for: window) { [weak self] r in
      guard let self, r == .OK, let u = p.url else { return }
      projectsFolder = u
      rebuildAccountMenu()
      refresh()
    }
  }

  @objc private func logOut() {
    accountGeneration += 1
    let gen = accountGeneration
    Task {
      _ = try? await engine.call("account.logout", ["url": server])
      guard gen == accountGeneration else { return }
      signedOut("Signed out. Projects already on this Mac stay where they are.")
    }
  }

  /// "Sign in here": the server's login page in a sheet. `autofill` (email, password) is for tests.
  public func webSignIn(autofill: (String, String)? = nil) {
    guard let url = URL(string: server) else { return }
    let w = WebSignIn(server: url)
    w.autofill = autofill
    web = w
    w.onCancel = { [weak self] in self?.endWeb() }
    w.onCookie = { [weak self] cookie in
      guard let self else { return }
      Task {
        let err = await self.login(["from": "cookie", "cookie": cookie, "source": "webview"])
        self.endWeb()
        if let err { self.signIn.show(SignInView.explain(err), error: true) }
      }
    }
    window.beginSheet(w.panel)
  }

  private func endWeb() {
    if let p = web?.panel { window.endSheet(p) }
    web = nil
  }

  // MARK: new project

  @objc private func newProjectAction() { newProject() }

  /// Ask for a name (and Blank or Example), make the project on Overleaf, then download and open it.
  public func newProject() {
    guard !account.isEmpty, window.attachedSheet == nil else { return }
    let a = NSAlert()
    a.messageText = "New Project"
    a.informativeText = "It’s made on \(serverHost), then downloaded to \(ProjectList.abbreviate(projectsFolder.path)) and opened."
    let name = NSTextField(string: "")
    name.placeholderString = "Project name"
    let kind = NSPopUpButton(frame: .zero, pullsDown: false)
    kind.addItems(withTitles: ["Blank", "Example"])
    let label = NSTextField(labelWithString: "Template:")
    let row = NSStackView(views: [label, kind])
    row.spacing = 6
    let box = NSStackView(views: [name, row])
    box.orientation = .vertical
    box.alignment = .leading
    box.spacing = 8
    box.frame = NSRect(x: 0, y: 0, width: 280, height: 58)
    name.frame.size.width = 280
    name.widthAnchor.constraint(equalToConstant: 280).isActive = true
    a.accessoryView = box
    a.addButton(withTitle: "Create")
    a.addButton(withTitle: "Cancel")
    a.window.initialFirstResponder = name
    a.beginSheetModal(for: window) { [weak self] r in
      guard let self, r == .alertFirstButtonReturn else { return }
      let n = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !n.isEmpty else { return }
      createProject(n, template: kind.indexOfSelectedItem == 1 ? "example" : "blank")
    }
  }

  /// Make the project on Overleaf, then download and open it (what Create in the New Project sheet does).
  public func createProject(_ name: String, template: String) {
    status("Creating “\(name)” on \(serverHost)…", busy: true)
    Task {
      do {
        let r = try await engine.call("project.create", ["url": server, "name": name, "template": template])
        guard let id = r["project_id"] as? String else { throw HomeEngine.Failure(description: "the server gave no project ID") }
        let p = HomeProject(id: id, name: name, lastUpdated: Date(), accessLevel: "owner")
        list.projects.insert(p, at: 0)
        open(p)
        refresh()
      } catch {
        status("Couldn’t create “\(name)”")
        alert("Couldn’t create “\(name)”", "\(error)")
      }
    }
  }

  // MARK: open, clone, remove

  public func open(_ p: HomeProject) {
    if let f = p.localFolder {
      finishOpen(URL(fileURLWithPath: f, isDirectory: true), project: p.id)
      return
    }
    guard !list.cloning.contains(p.id) else { return }
    let fm = FileManager.default
    let root = projectsFolder
    let folder = ProjectList.cloneFolder(root: root, name: p.name) { fm.fileExists(atPath: $0.path) }
    list.cloning.insert(p.id)
    status("Downloading “\(p.name)” to \(ProjectList.abbreviate(folder.path))…", busy: true)
    Task {
      defer { list.cloning.remove(p.id) }
      do {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let r = try await engine.call("project.clone", ["url": server, "project_id": p.id, "folder": folder.path])
        let path = r["folder"] as? String ?? folder.path
        if let i = list.projects.firstIndex(where: { $0.id == p.id }) {
          list.projects[i].localFolder = path
          list.projects[i].lastOpened = Date()
        }
        summary()
        finishOpen(URL(fileURLWithPath: path, isDirectory: true), project: p.id)
      } catch {
        status("Couldn’t download “\(p.name)”")
        alert("Couldn’t download “\(p.name)”", "\(error)")
      }
    }
  }

  private func cloneProgress(_ p: [String: Any]) {
    guard let stage = p["stage"] as? String, stage != "done", let text = p["text"] as? String,
          let name = list.projects.first(where: { $0.id == p["project_id"] as? String })?.name else { return }
    status("“\(name)”: \(text)…", busy: true)
  }

  private func finishOpen(_ url: URL, project id: String) {
    if let f = onOpenFrom {
      f(url, window.isVisible ? list.screenRect(ofProject: id) : nil)
    } else {
      onOpen?(url)
    }
    if closesOnOpen { window.orderOut(nil) }
  }

  public func openOnWeb(_ p: HomeProject) {
    if let u = URL(string: "\(server)/project/\(p.id)") { NSWorkspace.shared.open(u) }
  }

  public func reveal(_ p: HomeProject) {
    guard let f = p.localFolder else { return }
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: f)])
  }

  /// Answers the remove question instead of a sheet (tests).
  var confirm: ((String, @escaping @MainActor (Bool) -> Void) -> Void)?

  public func removeLocal(_ p: HomeProject) {
    guard let f = p.localFolder else { return }
    let url = URL(fileURLWithPath: f, isDirectory: true)
    if isOpen?(url) == true {
      alert("“\(p.name)” is open", "Close its window first, then remove the local copy.")
      return
    }
    let a = NSAlert()
    a.messageText = "Remove the local copy of “\(p.name)”?"
    a.informativeText = "\(ProjectList.abbreviate(f)) goes to the Trash and Taudot stops syncing it. The project stays on Overleaf; you can download it again any time."
    a.addButton(withTitle: "Move to Trash")
    a.addButton(withTitle: "Cancel")
    a.buttons[0].hasDestructiveAction = true
    let ask: (@escaping @MainActor (Bool) -> Void) -> Void = confirm.map { c in { c(a.messageText, $0) } }
      ?? { [window] done in a.beginSheetModal(for: window) { done($0 == .alertFirstButtonReturn) } }
    ask { [weak self] ok in
      guard let self, ok else { return }
      // Opened while the question was up (A23): never trash a folder a window is editing.
      if self.isOpen?(url) == true {
        self.alert("“\(p.name)” is open", "Close its window first, then remove the local copy.")
        return
      }
      Task {
        do {
          // Stop the engine first: deleting a folder it still mirrors would be synced as deletes.
          _ = try await self.engine.call("project.forget", ["url": self.server, "project_id": p.id, "folder": f])
          try await NSWorkspace.shared.recycle([url])
          self.status("Moved \(ProjectList.abbreviate(f)) to the Trash")
        } catch {
          self.alert("Couldn’t remove the local copy", "\(error)")
        }
        self.refresh()
      }
    }
  }

  /// Takes the alerts instead of a sheet (tests: a sheet brings the window on screen).
  var onAlert: ((String, String) -> Void)?

  private func alert(_ title: String, _ text: String) {
    if let onAlert { onAlert(title, text); return }
    let a = NSAlert()
    a.messageText = title
    a.informativeText = text
    a.beginSheetModal(for: window)
  }

  // MARK: window

  /// How much of the tint lies over the glass (0 = clear glass, 1 = opaque). The `taudot.homeGlassOpacity`
  /// default overrides it.
  static var glassOpacity: CGFloat {
    let d = UserDefaults.standard.double(forKey: "taudot.homeGlassOpacity")
    return d > 0 ? min(d, 1) : 0.6
  }

  /// Light mode keeps more of its tint, so it stays bright over dark windows behind.
  static func tint(_ a: NSAppearance) -> NSColor {
    let dark = a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    return TaudotColor.glassTint.withAlphaComponent(dark ? glassOpacity : min(1, glassOpacity + 0.18))
  }

  /// Liquid Glass behind the whole window (macOS 26), tinted with a breath of Taudot's ground: near-white with a hint
  /// of teal in light mode, near-black with a hint of teal in dark. Else the window-background material.
  static func glass(holding content: NSView) -> NSView {
    if #available(macOS 26.0, *), !taudotSolid(NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency) {
      let g = NSGlassEffectView()
      g.cornerRadius = 16
      g.tintColor = NSColor(name: nil) { tint($0) }
      g.contentView = content
      return g
    }
    let v = NSVisualEffectView()
    v.material = .underWindowBackground
    v.blendingMode = .behindWindow
    v.state = .followsWindowActiveState
    content.translatesAutoresizingMaskIntoConstraints = false
    v.addSubview(content)
    NSLayoutConstraint.activate([
      content.topAnchor.constraint(equalTo: v.topAnchor), content.bottomAnchor.constraint(equalTo: v.bottomAnchor),
      content.leadingAnchor.constraint(equalTo: v.leadingAnchor), content.trailingAnchor.constraint(equalTo: v.trailingAnchor),
    ])
    return v
  }

  public func windowDidBecomeKey(_ n: Notification) {
    // Refresh on focus, at most every 15 s.
    if !account.isEmpty, Date().timeIntervalSince(lastLoad) > 15 { refresh() }
  }

  /// The projects as last loaded.
  public var projects: [HomeProject] { list.projects }

  /// Sign in with a session cookie, as the sign-in view's paste field does. Returns an error message.
  public func signIn(cookie: String) async -> String? { await login(["from": "cookie", "cookie": cookie]) }

  /// For screenshots: show the first local-less project as being downloaded, without the engine.
  public func stageCloning() {
    guard let p = list.projects.first(where: { !$0.isLocal && !$0.archived && !$0.trashed }) else { return }
    list.cloning.insert(p.id)
    if let i = list.rows.firstIndex(where: { if case .project(let q, false) = $0 { q.id == p.id } else { false } }) {
      list.table.selectRowIndexes([i], byExtendingSelection: false)
    }
    status("“\(p.name)”: downloading 12 files…", busy: true)
  }
}

