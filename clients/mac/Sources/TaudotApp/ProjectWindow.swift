// One project's window: review margin | Neovim | PDF, a status bar, SyncTeX both ways.
import AppKit
import SwiftUI
import TaudotNeovim
import TaudotEditor
import TaudotHistory
import TaudotPDF
import TaudotReview
import TaudotShared

@MainActor final class ProjectWindow: NSObject, NSWindowDelegate, NSSplitViewDelegate {
  let folder: URL
  let window: NSWindow
  /// "neovim" or "native" (Settings ▸ Editor), fixed when the window opens. Neovim mode has `nvim` and `editor`;
  /// native mode has `native` (TaudotEditor) and neither of those.
  let mode: String
  let nvim: Neovim!
  let editor: EditorView!
  let native: NativeEditor?
  /// What the review controller, the PDF and the app's notifications talk to: Neovim, or the native editor's bridge.
  var bridge: NeovimBridge { native.map { $0.bridge } ?? nvim }
  /// The editor's view in the column, and the view that takes the keys.
  var editorView: NSView { native?.view ?? editor }
  var editorResponder: NSView { native?.view.textView ?? editor }
  /// Where the window's start is (A6): one state, so a window closed mid-start stops there, and a failed start says so.
  enum StartPhase: Equatable { case booting, started, failed, closed }
  var startPhase: StartPhase = .booting
  /// The editor is up (Neovim attached, or the native editor started).
  var editorStarted: Bool { startPhase == .started }
  struct WindowClosed: Error {}
  /// After every await of the start: stop there if the window closed meanwhile.
  func stillOpen() throws { if closing || startPhase == .closed { throw WindowClosed() } }
  let split = NSSplitView()
  /// The left pane: Files | Comments. The comments margin lives in it (`sidebar.margin`).
  let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 280, height: 600))
  var margin: ReviewMarginView { sidebar.margin }
  let pdf = TaudotPDFPane()
  let status = StatusBar()
  let editorBox = NSView()
  var review: ReviewController?
  /// History (History.swift): the sidebar's third tab and the diff over the editor.
  var history: HistoryController?
  var historyPDF: HistoryPDFController?
  var historyReturnTab: SidebarView.Tab = .files
  var mainFile: String?
  /// The last run's TeX errors and warnings (Issues.swift), their popover, and whether Neovim has the diagnostics module.
  let issues = IssuesModel()
  /// Edits made outside this window (OutsideEditsUI.swift, editfix item 9).
  let outside = OutsideEdits()
  let changesView = ChangesView(frame: .zero)
  let editPill = EditPill()
  var followEdits = UserDefaults.standard.bool(forKey: "taudot.followEdits") {
    didSet { UserDefaults.standard.set(followEdits, forKey: "taudot.followEdits"); changesView.following = followEdits }
  }
  var lastTyped: CFTimeInterval = 0
  var pendingFollow: OutsideEdits.Change?
  var followTimer: Timer?
  var typingMonitor: Any?
  /// The doc the editor shows (its caret reports), and when the Claude pane's claude last wrote output.
  var editorPath: String?
  var claudeOutputAt: CFTimeInterval = 0
  /// The strip over the PDF pane and what it shows.
  let strip = IssuesStripState()
  var stripView: NSView?
  var stripObservers: [NSKeyValueObservation] = []
  /// The editor column's top: the editor box's, or the strip's bottom while the strip is there.
  lazy var columnTop: NSLayoutConstraint = column.topAnchor.constraint(equalTo: editorBox.topAnchor)
  var texDiagnosticsLoaded = false
  let engineSocket: URL
  var onClose: (() -> Void)?

  var defaultsKey: String { "taudot.panes." + folder.path }
  /// The sidebar (Files | Comments; the key predates it and kept its name): hidden unless the user showed it (⌘⇧\, remembered for every project). The margin then shows the
  /// comment at the cursor as a floating card. TAUDOT_COMMENTS=shown|hidden overrides it for a run without saving;
  /// margin measurements (TAUDOT_MARGIN_TRACE) show it.
  static let commentsKey = "taudot.commentsShown"
  static let commentsOverride: Bool? = {
    let env = ProcessInfo.processInfo.environment
    if let c = env["TAUDOT_COMMENTS"] { return c == "shown" }
    return env["TAUDOT_MARGIN_TRACE"] != nil ? true : nil
  }()
  var closing = false
  /// Save questions open now, and the most at once (A13 checks: never two).
  var asksOpen = 0, asksMost = 0
  /// The running quit flow (oneQuitFlow).
  var quitFlow: Task<Bool, Never>?
  /// The Projects row this window was opened from (screen rect), for the grow animation.
  var growFrom: NSRect?
  /// The card of the grow animation while it runs (checks sample it).
  var growCard: NSWindow?
  /// The mark and a line while the folder has no main .tex (showEmptyState).
  var emptyState: NSView?
  // Panes (Panes.swift): the focused one (0 sidebar, 1 Neovim, 2 PDF), a zoom to undo, the divider animation.
  var focusedPane = 1
  var zoom: (pane: Int, hidden: [Bool], widths: [CGFloat], claude: Bool)?
  var animatingPanes = false
  var paneAnimation: Timer?
  /// The running animation's panes to hide and its end (Panes.swift animate; settlePanes runs it now).
  var paneMotion: (hide: Set<Int>, finish: @MainActor () -> Void)?
  let focusLine = NSView()
  var linePane: Int?
  var lineSlide: (from: NSRect, t0: CFTimeInterval)?
  var lineTimer: Timer?
  /// Called after each placement of the focus line (PaneCheck samples it).
  var onLineFrame: (() -> Void)?
  /// The line normally shows only in the key window; the background checks (never key) see it too.
  var lineIgnoresKey: Bool { ProcessInfo.processInfo.environment["TAUDOT_PANECHECK"] != nil }
  /// Side panes on their way out (not focusable).
  var panesHiding = Set<Int>()
  var clickMonitor: Any?
  var settingsObserver: Any?
  var firstFlush = false
  var nvimBoot: Task<Void, Error>?
  /// The editor column: Neovim above, the Claude pane (⌘J, ClaudePane.swift) below.
  let column = NSSplitView()
  /// Neovim's view in the column. The margin puts its comment pill next to the editor (in its superview): this keeps
  /// it out of the split view, which would take it for a pane.
  let editorHost = NSView()
  /// The Claude pane's floating panel (ClaudeFloat.swift), over the editor column.
  let claudeFloat = ClaudeFloat(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
  lazy var dockedNow = claudeDocked
  /// The floating panel is fading out (counts as hidden).
  var claudeFading = false
  /// Bumped by every show/hide/mode change of the Claude pane: a fade's completion from before is stale (A1).
  var claudeGen = 0
  var claude: ClaudePane?
  var lastClaudeEsc: TimeInterval = 0
  /// The find bar (Find.swift) and its PDF follow timer.
  var find: FindController?
  var findPDFTimer: Timer?

  init(folder: URL) throws {
    self.folder = folder
    timeline("window init")
    let env = ProjectWindow.environment()
    timeline("environment")
    // The bundle carries txp-render (bundle.sh); TaudotPDF finds it through $TAUDOT_TXP. No txp-headless fallback:
    // without txp-render the pane says so (TxpPaths.missing).
    if ProcessInfo.processInfo.environment["TAUDOT_TXP"] == nil,
      let r = Bundle.main.resourceURL?.appendingPathComponent("txp-render"),
      FileManager.default.isExecutableFile(atPath: r.path)
    { setenv("TAUDOT_TXP", r.path, 1) }
    mainFile = ProjectWindow.mainTex(in: folder)
    let sock = ProcessInfo.processInfo.environment["TAUDOT_SOCKET"] ?? env["TAUDOT_SOCKET"]
      ?? Compat.engineSocket()
    engineSocket = URL(fileURLWithPath: sock)
    mode = ProcessInfo.processInfo.environment["TAUDOT_EDITOR_MODE"] ?? TaudotSettings.shared.editorMode
    if mode == "native" {
      nvim = nil
      native = NativeEditor(folder: folder, socket: engineSocket)
    } else {
      // No main file yet: the window shows the taudot mark (showEmptyState), not Neovim's intro screen as well.
      nvim = try Neovim(args: ["--cmd", swapLua] + (mainFile.map { [$0] } ?? ["--cmd", "set shortmess+=I"]), cwd: folder, env: env)
      timeline("nvim spawned")
      native = nil
    }
    let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let frame = NSRect(x: screen.minX + 40, y: screen.minY + 40, width: min(1700, screen.width - 80), height: min(1000, screen.height - 80))
    window = (measureRun ? MeasureWindow.self : NSWindow.self).init(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                      backing: .buffered, defer: false)
    window.title = folder.lastPathComponent
    window.subtitle = folder.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    window.titlebarAppearsTransparent = true
    window.tabbingMode = .disallowed
    window.isReleasedWhenClosed = false
    window.setFrameAutosaveName("taudot.window." + folder.path)
    editor = nvim.map { EditorView(nvim: $0, frame: NSRect(x: 0, y: 0, width: frame.width * 0.45, height: frame.height)) }
    super.init()
    window.delegate = self
    timeline("window made")
    layout(frame)
    wire()
    installFind()
    timeline("laid out")
  }

  // MARK: layout

  func layout(_ frame: NSRect) {
    let content = NSView()
    window.contentView = content
    for v in [split, status] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(v) }
    NSLayoutConstraint.activate([
      split.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor),
      split.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      split.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      split.bottomAnchor.constraint(equalTo: status.topAnchor),
      status.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      status.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      status.bottomAnchor.constraint(equalTo: content.bottomAnchor),
      status.heightAnchor.constraint(equalToConstant: StatusBar.height),
    ])
    editorBox.wantsLayer = true
    editorBox.addSubview(column)
    claudeFloat.isHidden = true
    editorBox.addSubview(claudeFloat, positioned: .above, relativeTo: column)
    claudeFloat.onDock = { [weak self] in self?.morphClaude(docked: true) }
    claudeFloat.onFrameChange = { [weak self] in self?.updateFocusLine(animated: false) }
    column.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      column.leadingAnchor.constraint(equalTo: editorBox.leadingAnchor), column.trailingAnchor.constraint(equalTo: editorBox.trailingAnchor),
      columnTop, column.bottomAnchor.constraint(equalTo: editorBox.bottomAnchor),
    ])
    column.isVertical = false
    column.dividerStyle = .thin
    column.delegate = self
    let ev = editorView
    editorHost.addSubview(ev)
    ev.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      ev.leadingAnchor.constraint(equalTo: editorHost.leadingAnchor), ev.trailingAnchor.constraint(equalTo: editorHost.trailingAnchor),
      ev.topAnchor.constraint(equalTo: editorHost.topAnchor), ev.bottomAnchor.constraint(equalTo: editorHost.bottomAnchor),
    ])
    column.addArrangedSubview(editorHost)
    column.setHoldingPriority(.defaultLow, forSubviewAt: 0)
    split.isVertical = true
    split.dividerStyle = .thin
    split.delegate = self
    // margin | editor | PDF (docs/mac-app.md). The editor takes the slack when the window resizes.
    sidebar.frame = NSRect(x: 0, y: 0, width: 280, height: frame.height)
    editorBox.frame = NSRect(x: 0, y: 0, width: (frame.width * 0.42).rounded(), height: frame.height)
    pdf.view.frame = NSRect(x: 0, y: 0, width: frame.width - 280 - frame.width * 0.42, height: frame.height)
    split.addArrangedSubview(sidebar)
    split.addArrangedSubview(editorBox)
    split.addArrangedSubview(pdf.view)
    split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
    split.setHoldingPriority(.defaultLow - 1, forSubviewAt: 1)
    split.setHoldingPriority(.defaultLow, forSubviewAt: 2)
    // Divider positions are remembered per project folder by the split view itself; hidden panes by us.
    split.autosaveName = "taudot.split." + folder.path
    let d = UserDefaults.standard.dictionary(forKey: defaultsKey) ?? [:]
    sidebar.isHidden = !(ProjectWindow.commentsOverride ?? UserDefaults.standard.bool(forKey: ProjectWindow.commentsKey))
    pdf.view.isHidden = d["pdfHidden"] as? Bool ?? false
    // The editor column hidden (⌥⌘\\), never with everything else hidden too.
    editorBox.isHidden = (d["editorHidden"] as? Bool ?? false) && !(sidebar.isHidden && pdf.view.isHidden)
    editor?.onFlush = { [weak self] in
      if let self, !self.firstFlush { self.firstFlush = true; timeline("first nvim flush") }
      self?.syncColors()
    }
    native?.onError = { [weak self] e in self?.status.note(e) }
    // The PDF typesets the native editor's own text: its edits skip the engine round trip (pdfpipe, step 2).
    native?.docFeed = .init(
      held: { [weak self] path, text in self?.pdf.editorHolds(path, text: text); self?.outside.held(path, text) },
      changed: { [weak self] path, pos, del, ins in self?.pdf.editorChanged(path, pos, del, ins); self?.outside.changed(path, pos, del, ins) },
      released: { [weak self] path in self?.pdf.editorReleased(path); self?.outside.released(path) })
    wireIssues()
    wireNativeIssues()
    wireOutside()
  }

  /// Right of every screen, for background runs.
  static var offscreenOrigin: NSPoint {
    NSPoint(x: (NSScreen.screens.map(\.frame.maxX).max() ?? 0) + 200, y: NSScreen.screens.first?.frame.minY ?? 0)
  }

  func savePanes() {
    settlePanes()  // never a frame of an animation (A2)
    if zoom != nil { return }  // a zoom is temporary
    guard !backgroundRun else { return }
    UserDefaults.standard.set(["pdfHidden": pdf.view.isHidden, "editorHidden": editorBox.isHidden], forKey: defaultsKey)
    if ProjectWindow.commentsOverride == nil { UserDefaults.standard.set(!sidebar.isHidden, forKey: ProjectWindow.commentsKey) }
  }

  func splitView(_ splitView: NSSplitView, constrainMinCoordinate p: CGFloat, ofSubviewAt i: Int) -> CGFloat {
    if splitView === column { return max(p, 120) }  // the editor keeps a few lines
    if animatingPanes { return p }
    return i == 0 ? max(p, 180) : p
  }

  func splitView(_ splitView: NSSplitView, constrainMaxCoordinate p: CGFloat, ofSubviewAt i: Int) -> CGFloat {
    if splitView === column { return min(p, splitView.bounds.height - 80) }
    if animatingPanes { return p }
    return i == 0 ? min(p, 480) : p
  }

  /// Grips over the thin dividers (DividerGrip.swift): a wide target, the resize cursor, a line on hover.
  lazy var splitGrips = DividerGrips(split)
  lazy var columnGrips = DividerGrips(column)

  func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
    splitView === column ? false : subview !== editorBox
  }

  /// Widths of the side panes when they were last visible, to give them back when shown again.
  var paneWidths: [ObjectIdentifier: CGFloat] = [:]

  /// No divider next to a hidden pane: NSSplitView otherwise leaves its divider layer where the pane was, a dark
  /// 1 pt line over the editor.
  func splitView(_ splitView: NSSplitView, shouldHideDividerAt i: Int) -> Bool {
    if splitView === column { return !claudeShown || editorHost.isHidden }
    return i == 0 ? sidebar.isHidden : pdf.view.isHidden
  }

  func splitViewDidResizeSubviews(_ notification: Notification) {
    // A dragged Claude pane keeps its height (not while the window or a zoom resizes the column).
    if (notification.object as? NSSplitView) === column, notification.userInfo?["NSSplitViewDividerIndex"] != nil,
       let c = claude, !c.view.isHidden, !c.view.frame.isEmpty { claudeHeight = c.view.frame.height }
    if (notification.object as? NSSplitView) === split { hideStaleDividers(); layoutClaudeFloat() }
    hideStaleDividers()
    updateFocusLine(animated: false)
  }

  /// Show or hide a side pane; the split animates (~200 ms) and the editor takes the difference. Hiding the focused
  /// pane gives the focus to Neovim (or what's left) first, so the line slides there with the split.
  /// Show or hide a pane (the sidebar, the editor column with a docked Claude pane, or the PDF); the split
  /// animates (~200 ms). Never all of them: hiding the last visible pane does nothing. Hiding the focused pane gives
  /// the focus to a neighbour first (Neovim, else the PDF, else the sidebar), so the line slides there with the split.
  func setPane(_ v: NSView, hidden: Bool, animated: Bool = true) {
    if zoom != nil { unzoom(animated: false) }  // a toggle applies to the layout the zoom hid
    guard let idx = panes.firstIndex(of: v), v.isHidden != hidden || (hidden == false && panesHiding.contains(idx)) else { return }
    func shownAfter(_ i: Int) -> Bool { i == idx ? !hidden : !(panes[i].isHidden || panesHiding.contains(i)) }
    if hidden && !(0..<3).contains(where: { $0 != idx && shownAfter($0) }) { NSSound.beep(); return }
    // Panes keep their widths through any toggle (not the one taking the slack now: its width is the leftover).
    let slackNow = [1, 2, 0].first { !panes[$0].isHidden && !panesHiding.contains($0) }
    for (i, p) in panes.enumerated() where i != slackNow && !p.isHidden && !panesHiding.contains(i) && p.frame.width > 0 {
      paneWidths[ObjectIdentifier(p)] = p.frame.width
    }
    let total = split.bounds.width, d = split.dividerThickness
    var target = (0..<3).map { i -> CGFloat in
      guard shownAfter(i) else { return 0 }
      return paneWidths[ObjectIdentifier(panes[i])] ?? (i == 0 ? 280 : i == 1 ? (total * 0.42).rounded() : (total * 0.4).rounded())
    }
    // One pane takes what's left: the editor, else the PDF, else the sidebar.
    if let slack = [1, 2, 0].first(where: shownAfter) {
      target[slack] = 0
      target[slack] = max(0, total - target.reduce(0, +) - 2 * d)
    }
    if hidden {
      if focusedPane == idx || (idx == 1 && focusedPane == 3) {
        let order = idx == 0 ? [1, 3, 2] : idx == 1 ? [2, 0] : [1, 3, 0]
        if let i = order.first(where: focusable) { focus(pane: i) }
      }
      panesHiding.insert(idx)
      if !animated { panesHiding.remove(idx) }
    } else {
      panesHiding.remove(idx)
      // In at no width, then opened up.
      var w0 = widths(); w0[idx] = 0
      v.isHidden = false
      split.adjustSubviews()
      setWidths(w0)
    }
    if animated {
      animate(to: target, hide: hidden ? [idx] : [])
    } else {
      v.isHidden = hidden
      split.adjustSubviews()
      setWidths(target)
      parkHidden()
      savePanes()
      if !focusable(focusedPane), let i = [1, 3, 0, 2].first(where: focusable) { focus(pane: i) }
      updateFocusLine(animated: false)
    }
  }

  /// ⌥⌘\\: the editor column (Neovim and a docked Claude pane), as ⌘\\ does the PDF.
  @objc func toggleEditor(_ sender: Any?) {
    if zoom != nil { unzoom(animated: false) }
    setPane(editorBox, hidden: !editorBox.isHidden)
  }

  @objc func togglePDFComments(_ sender: Any?) { pdf.toggleComments() }

  // ⌘+ / ⌘− / ⌘0: the editor's font, either editor mode; saved as Settings ▸ Editor ▸ Font size, so every window
  // follows (applySettings).
  @objc func fontBigger(_ sender: Any?) { TaudotSettings.shared.stepFontSize(by: 1, current: editorFontSize) }
  @objc func fontSmaller(_ sender: Any?) { TaudotSettings.shared.stepFontSize(by: -1, current: editorFontSize) }
  @objc func fontActualSize(_ sender: Any?) { TaudotSettings.shared.resetFontSize() }
  /// The size the editor shows now, points.
  var editorFontSize: Double { Double(native?.view.style.fontSize ?? editor?.fontPointSize ?? 13) }

  @objc func togglePDF(_ sender: Any?) {
    if zoom != nil { unzoom(animated: false) }  // toggle the layout the zoom hid, not the zoom
    setPane(pdf.view, hidden: !pdf.view.isHidden)
  }

  @objc func toggleMargin(_ sender: Any?) {
    if zoom != nil { unzoom(animated: false) }
    setPane(sidebar, hidden: !sidebar.isHidden)
  }

  @objc func forwardSearch(_ sender: Any?) {
    if let native { native.forwardSearch(); return }
    Task { _ = try? await nvim.execLua("require('taudot.app').cursor(true)", []) }
  }

  // MARK: wiring

  func wire() {
    // The line follows its pane's frame whatever moves it (the split's last adjustment, autolayout, full screen).
    for v in [sidebar, editorBox, editorHost, editorView, pdf.view, claudeFloat] as [NSView] {
      v.postsFrameChangedNotifications = true
      NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: v, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.updateFocusLine(animated: false) }
      }
    }
    settingsObserver = NotificationCenter.default.addObserver(forName: TaudotSettings.changed, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { if self?.editorStarted == true { self?.applySettings() } }
    }
    // Hidden (occluded, minimised, another Space): the app's status poll in Neovim stops until it shows again.
    NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.native == nil, self.editorStarted else { return }
        let hidden = !self.window.occlusionState.contains(.visible)
        self.nvim.send("nvim_exec_lua", [.string("local m = package.loaded['taudot.app'] if m and m.pause then m.pause(...) end"), .array([.bool(hidden)])])
      }
    }
    clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] e in
      MainActor.assumeIsolated { self?.clicked(e) }
      return e
    }
    margin.geometry = native?.view ?? editor
    margin.editorOffset = 0  // the margin and the editor share their top
    sidebar.folder = folder
    // Margin measurements and checks (TAUDOT_COMMENTS=shown, TAUDOT_MARGIN_TRACE) want the comments on screen.
    if ProjectWindow.commentsOverride == true { sidebar.tab = .comments }
    sidebar.files.onError = { [weak self] e in self?.status.note(e) }
    sidebar.onToggleInline = { [weak self] in self?.toggleCommentsInText(nil) }
    let r = ReviewController(nvim: bridge, sidebar: sidebar)
    r.onResult = { [weak self] a, err in if let err { self?.status.note("\(a.kind): \(err)") } }
    review = r
    wireHistory()
    // The margin gives the keys back through the window (A12: not to the editor under History's diff).
    margin.onFocusEditor = { [weak self] in self?.giveEditorKeys() }
    // The review bar floats over the bottom of the editor while reviewing.
    editorBox.addSubview(r.bar)
    // Review comments → sticky notes on the PDF (the followed file's open comments); a note's click → that comment.
    r.onStateApplied = { [weak self] st in
      guard let self, let path = st.file ?? st.path else { return }
      self.pdf.setComments(st.items.filter { $0.kind == .comment }.map { it in
        PDFComment(
          id: it.id, path: path, line: it.range.line + 1, column: it.range.col, endLine: it.range.endLine + 1,
          endColumn: it.range.endCol, quote: it.quote, author: it.author.name, color: it.color,
          firstMessage: it.messages.first?.text ?? "", replies: max(0, it.messages.count - 1), resolved: it.resolved,
          messages: it.messages.map { m in
            // each author in the colour the margin gives them: the thread's own, else one picked from their id
            var other = it
            other.color = m.user.id == it.author.id ? it.color : nil
            other.author = m.user
            return PDFCommentMessage(
              author: m.user.name, color: MarkColor.hex(other.authorColor), text: m.text, time: m.ts, mine: m.mine)
          })
      })
    }
    pdf.onCommentClick = { [weak self] id in
      guard let self else { return }
      self.review?.send(.goto(id))
      self.sidebar.margin.select(id)
      self.focusEditorToJump()
    }
    // The pinned card on the PDF: reply and resolve, as the margin's cards do.
    pdf.onCommentReply = { [weak self] id, text in self?.review?.send(.reply(id, text: text)) }
    pdf.onCommentResolve = { [weak self] id in self?.review?.send(.resolve(id)) }
    // A comment written on the PDF (text selected there, mapped to its source range). gui.act's comment works on
    // Neovim's current buffer, so Neovim opens that file at the range first.
    pdf.onCommentCreate = { [weak self] d, text in
      guard let self else { return }
      let abs = d.path.hasPrefix("/") ? d.path : self.folder.appendingPathComponent(d.path).path
      Task {
        _ = try? await self.bridge.execLua(
          "require('taudot.preview').jump(...)", [.string(abs), .int(Int64(d.line)), .int(Int64(d.column))])
        self.review?.send(.comment(ReviewRange(line: d.line - 1, col: d.column, endLine: d.endLine - 1, endCol: d.endColumn), text: text))
      }
    }
    // Neovim exited (:qa, or the quit below): close the window.
    nvim?.onExit = { [weak self] in
      guard let self, !self.closing else { return }
      self.closing = true
      self.window.close()
    }
    // Neovim → PDF: the cursor resting on a new line (cursor-follow), or <leader>av / ⌘⌥J (forced).
    bridge.notify("taudot_app_cursor") { [weak self] args in
      guard let self, args.count >= 2, let path = args[0].string, let line = args[1].int else { return }
      if path.isEmpty { self.pdf.clearMark(); self.pdf.hideCaret(); return }  // the cursor left the .tex files
      if self.pdf.view.isHidden && args.count > 2 && args[2].bool == true { self.setPane(self.pdf.view, hidden: false) }
      let deliberate = args.count > 4 ? args[4].bool == true : (args.count > 2 && args[2].bool == true)
      // (a double-click's mark fades by itself: args[5])
      self.pdf.cursorMoved(path: path, line: line, column: args.count > 3 ? args[3].int : nil, deliberate: deliberate,
                           fades: args.count > 5 && args[5].bool == true)
    }
    // Editor → PDF: the cursor dot, on every move and key (`taudot_app_caret path line byte-col line-text sent-at`;
    // placed at the exact letter from txp-render's glyphs).
    bridge.notify("taudot_app_caret") { [weak self] args in
      guard let self, args.count >= 4, let path = args[0].string, let line = args[1].int, let col = args[2].int,
        let text = args[3].string
      else { return }
      self.pdf.showCaret(path: path, line: line, column: col, text: text, sentAt: args.count > 4 ? args[4].double : nil)
      self.editorPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
    }
    // Neovim → PDF: the buffer's own text (pdfpipe, step 2), as the native editor's docFeed.
    bridge.notify("taudot_app_text") { [weak self] args in
      guard let self, let p = args.first?.string else { return }
      let path = p.hasPrefix("/") ? String(p.dropFirst()) : p
      if args.count > 2, let text = args[2].string {
        self.pdf.editorHolds(path, text: text)
        self.outside.held(path, text)
      } else if args.count > 1, let edits = args[1].array {
        for e in edits {
          guard let pos = e["pos"]?.int, let del = e["del"]?.int else { continue }
          self.pdf.editorChanged(path, pos, del, e["ins"]?.string ?? "")
          self.outside.changed(path, pos, del, e["ins"]?.string ?? "")
        }
      }
    }
    bridge.notify("taudot_app_text_released") { [weak self] args in
      guard let p = args.first?.string else { return }
      self?.pdf.editorReleased(p.hasPrefix("/") ? String(p.dropFirst()) : p)
      self?.outside.released(p.hasPrefix("/") ? String(p.dropFirst()) : p)
    }
    wireOutsideNotify()
    bridge.notify("taudot_app_status") { [weak self] args in
      if args.first?["connection"]?.string == "online" { timeline("engine online") }
      guard let p = args.first else { return }
      self?.status.connection(p)
    }
    // PDF → Neovim: double-click opens that file at that line.
    pdf.onInverseSearchWord = { [weak self] path, line, column in
      guard let self else { return }
      let abs = path.hasPrefix("/") ? path : self.folder.appendingPathComponent(path).path
      let col: Value = column.map { .int(Int64($0)) } ?? .null
      Task { _ = try? await self.bridge.execLua("require('taudot.preview').jump(...)", [.string(abs), .int(Int64(line)), col]) }
      self.focusEditorToJump()
    }
    pdf.onStatus = { [weak self] s in
      timeline("pdf: " + s)
      if ProcessInfo.processInfo.environment["TAUDOT_DEBUG"] != nil { FileHandle.standardError.write("pdf status: \(s)\n".data(using: .utf8)!) }
      guard let self else { return }
      self.issues.showBadboxes = self.pdf.engine.map { $0 != .texpresso } ?? false
      if s.hasPrefix("TeX: ") { self.issues.summary(String(s.dropFirst(5))); return }
      if s.contains("typeset") { self.issues.runDone() }
      if (s.hasPrefix("texpresso: ") || s.hasPrefix("pdfTeX: ")) && s.hasSuffix("restarting") { self.issues.restarted() }
      self.status.pdf(s)
    }
    // TeX's log, rebuilt from the typesetter's stderr: exact errors across rollbacks, and the warnings.
    pdf.onDriverLine = { [weak self] l in self?.issues.driverLine(l) }
    // BibTeX's warnings and errors (the .blg), as Overleaf lists them.
    pdf.onBibIssues = { [weak self] xs in self?.issues.bibIssues(xs) }
  }

  /// Started from init, as soon as the views exist, all at once: the PDF (its typeset and its engine feed) and Neovim's
  /// config, UI and project connection, while the window is still being shown.
  /// What a window waits for before it first talks to the engine (A17): the launch's `taudot service ensure`, which
  /// may restart the engine. Every window, however it was opened (Projects, Finder, the command line). Checks swap it.
  static var engineReady: Task<String?, Never> = BundledTools.ensured
  /// The window has talked to the engine (the PDF pane opened, or Neovim told to open the project).
  var engineTouched = false

  func boot() {
    present()
    let ready = ProjectWindow.engineReady
    let pdfBoot = Task { @MainActor [weak self] in
      _ = await ready.value
      guard let self, !self.closing else { return }
      if ProcessInfo.processInfo.environment["TAUDOT_NO_PDF"] == nil {
        if let mainFile { self.engineTouched = true; pdf.open(folder: folder, main: mainFile, engineSocket: engineSocket); timeline("pdf opened") }
        else { status.pdf("waiting for the main .tex") }
      }
    }
    guard let nvim, let editor else { return }
    let openProject = ProcessInfo.processInfo.environment["TAUDOT_NO_OPEN"] == nil
    let dir = ProjectWindow.pluginDir(), path = folder.path
    nvimBoot = Task { @MainActor in
      _ = await pdfBoot.value
      engineTouched = true
      // Before attaching (Neovim waits for the UI before reading the config): once the config has run, add the
      // plugin if the user's config didn't, and open the project.
      _ = try await nvim.execLua(startupLua, [.string(dir), .string(path), .bool(openProject)])
      timeline("startupLua")
      try await editor.attach()
      timeline("attached")
    }
  }

  /// The window on screen (or behind, for measured runs), first thing.
  func present() {
    if ProcessInfo.processInfo.environment["TAUDOT_ONTOP"] != nil {
      // Measuring visible idle: in front of everything and unoccluded, but never key and deaf to the mouse, so the
      // user's keys and pointer can't reach it.
      window.level = .floating
      window.ignoresMouseEvents = true
      if let sc = NSScreen.main?.visibleFrame { window.setFrame(NSRect(x: sc.minX, y: sc.minY, width: 900, height: 560), display: false) }
      window.orderFrontRegardless()
    } else if backgroundRun {
      // Behind everything and off every screen (right of all of them); layout and rendering still run there.
      // (TAUDOT_CLAUDESHOT / TAUDOT_ONSCREEN, opt-in: on screen, still behind, for a window capture.)
      if !onScreenRun { window.setFrameOrigin(ProjectWindow.offscreenOrigin) }
      window.orderBack(nil)
      // measured runs: key (inside this never-activated app), so keys posted to the PID reach the editor
      if measureRun { window.makeKey() }
    } else {
      // Opened from the Projects window: grow out of the project's row; otherwise a gentle fade in.
      if !reduceMotion { window.alphaValue = 0 }
      window.makeKeyAndOrderFront(nil)
      if let r = growFrom, !reduceMotion { grow(from: r) }
      else if !reduceMotion { NSAnimationContext.runAnimationGroup({ c in c.duration = 0.2; window.animator().alphaValue = 1 }, completionHandler: nil) }
    }
    giveEditorKeys()
    timeline("presented")
  }

  func start() async {
    timeline("start")
    // After the split view has applied its saved positions: a margin narrower than its cards can use (or a broken
    // saved layout) goes back to the default width.
    DispatchQueue.main.async { [self] in
      if !sidebar.isHidden && sidebar.frame.width < 220 { split.setPosition(280, ofDividerAt: 0) }
    }
    if ProcessInfo.processInfo.environment["TAUDOT_DEBUG"] != nil { FileHandle.standardError.write("Taudot: window \(window.windowNumber)\n".data(using: .utf8)!) }
    if ProcessInfo.processInfo.environment["TAUDOT_NO_PDF"] != nil { setPane(pdf.view, hidden: true, animated: false) }
    let openProject = ProcessInfo.processInfo.environment["TAUDOT_NO_OPEN"] == nil
    if let native {
      _ = await ProjectWindow.engineReady.value  // (A17)
      engineTouched = true
      await startNative(native, openProject: openProject)
      return
    }
    do {
      try await nvimBoot?.value
      try stillOpen()
      if ProcessInfo.processInfo.environment["TAUDOT_ONTOP"] == "focus" { nvim.send("nvim_ui_set_focus", [.bool(true)]) }
      // After VimEnter: the app's own Lua (cursor-follow, status) and the review margin.
      for _ in 0..<500 {
        if (try? await nvim.execLua("return vim.v.vim_did_enter == 1 and vim.fn.exists(':Taudot') == 2", [])) == .bool(true) { break }
        try await Task.sleep(for: .milliseconds(20))
        try stillOpen()
      }
      timeline("vim entered")
      let chan = try await nvim.channelID()
      _ = try await nvim.execLua(appLua, [.int(Int64(chan)), .string(folder.path)])
      try stillOpen()
      timeline("appLua")
      try await review?.attach(channel: chan)
      await attachFind(channel: chan)
      timeline("review attached")
      try stillOpen()
      startPhase = .started
      applySettings()
      if !window.occlusionState.contains(.visible) { nvim.send("nvim_exec_lua", [.string("package.loaded['taudot.app'].pause(true)"), .array([])]) }
      if mainFile == nil && openProject {
        // A fresh project folder fills once the engine has the project: wait for its main file, then show it.
        showEmptyState("Waiting for the project…")
        for _ in 0..<300 {
          try stillOpen()
          if let m = ProjectWindow.mainTex(in: folder) {
            mainFile = m
            pdf.open(folder: folder, main: m, engineSocket: engineSocket)
            try? await nvim.command("edit " + m)
            break
          }
          try await Task.sleep(for: .milliseconds(100))
        }
        try stillOpen()
        if mainFile == nil { showEmptyState("No .tex file in this folder yet") } else { hideEmptyState() }
      }
      if let lua = ProcessInfo.processInfo.environment["TAUDOT_EXEC"] {
        Task { try? await Task.sleep(for: .seconds(1)); _ = try? await nvim.execLua(lua, []) }
      }
      if let t = ProcessInfo.processInfo.environment["TAUDOT_SCROLLTRACE"] { Task { await ScrollTrace(self, out: URL(fileURLWithPath: t)).run() } }
      if let w = ProcessInfo.processInfo.environment["TAUDOT_WIRECHECK"] { Task { await WireCheck(self, out: URL(fileURLWithPath: w)).run() } }
      if ProcessInfo.processInfo.environment["TAUDOT_CLAUDESHOT"] != nil {
        // The screenshot's setup: a selection asked about (⌘L), then nothing more.
        Task { try? await Task.sleep(for: .seconds(1.5)); nvim.input("<Esc>40GVjj"); try? await Task.sleep(for: .seconds(0.3)); askClaude(nil) }
      }
      if let f = ProcessInfo.processInfo.environment["TAUDOT_ISSUESSHOT"] { Task { await issuesShot(URL(fileURLWithPath: f)) } }
      if let c = ProcessInfo.processInfo.environment["TAUDOT_CLAUDECHECK"] { Task { await ClaudeCheck(self, out: URL(fileURLWithPath: c)).run() } }
      if let c = ProcessInfo.processInfo.environment["TAUDOT_STATECHECK"], StateCheck.claim() { Task { await StateCheck(self, out: URL(fileURLWithPath: c)).run() } }
      if let c = ProcessInfo.processInfo.environment["TAUDOT_PANECHECK"] { Task { await PaneCheck(self, out: URL(fileURLWithPath: c)).run() } }
      if let c = ProcessInfo.processInfo.environment["TAUDOT_CYCLECHECK"] { Task { await CycleCheck(self, out: URL(fileURLWithPath: c)).run() } }
      if let c = ProcessInfo.processInfo.environment["TAUDOT_FLOATCHECK"] { Task { await FloatCheck(self, out: URL(fileURLWithPath: c)).run() } }
    if let c = ProcessInfo.processInfo.environment["TAUDOT_ZOOMCHECK"] { Task { await ZoomCheck(self, out: URL(fileURLWithPath: c)).run() } }
    if let c = ProcessInfo.processInfo.environment["TAUDOT_OUTSIDECHECK"] { Task { await OutsideCheck(self, out: URL(fileURLWithPath: c)).run() } }
      if let b = ProcessInfo.processInfo.environment["TAUDOT_BENCH"] { Task { await Bench(self, out: URL(fileURLWithPath: b)).run() } }
    } catch is WindowClosed {
    } catch {
      if startPhase == .booting { startPhase = .failed }
      status.note("Taudot: \(error)")
    }
  }

  /// A card in the window's colour grows from the row's rect to the window's frame (~280 ms, ease-out), then the
  /// window fades in under it and the card fades away. The window itself never resizes on the way, so Neovim and the
  /// PDF lay out once.
  func grow(from r: NSRect, done: (@MainActor () -> Void)? = nil) {
    let card = NSWindow(contentRect: r, styleMask: .borderless, backing: .buffered, defer: false)
    card.isOpaque = false
    card.backgroundColor = .clear
    card.hasShadow = true
    card.ignoresMouseEvents = true
    card.isReleasedWhenClosed = false
    card.animationBehavior = .none
    let v = NSView()
    v.wantsLayer = true
    v.layer?.cornerRadius = min(12, r.height / 2)
    v.layer?.backgroundColor = (window.backgroundColor ?? .windowBackgroundColor).cgColor
    v.layer?.borderWidth = 1
    v.layer?.borderColor = NSColor.separatorColor.cgColor
    card.contentView = v
    card.order(.above, relativeTo: window.windowNumber)
    growCard = card
    let end = window.frame
    NSAnimationContext.runAnimationGroup({ c in
      c.duration = 0.28
      c.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
      card.animator().setFrame(end, display: true)
      v.animator().layer?.cornerRadius = 10
    }, completionHandler: { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { card.close(); return }
        NSAnimationContext.runAnimationGroup({ c in
          c.duration = 0.14
          self.window.animator().alphaValue = 1
          card.animator().alphaValue = 0
        }, completionHandler: {
          MainActor.assumeIsolated {
            card.orderOut(nil)
            self.growCard = nil
            done?()
          }
        })
      }
    })
  }

  /// The project window's empty state, over the editor: the taudot mark in mono (the app's identity; coral is kept
  /// for "you") and one line under it.
  func showEmptyState(_ text: String) {
    let root = VStack(spacing: 14) {
      TaudotMark().foregroundStyle(.secondary).frame(height: 54)
      Text(text).font(.system(size: 13)).foregroundStyle(.secondary)
    }
    if let h = emptyState as? NSHostingView<AnyView> {
      h.rootView = AnyView(root)
    } else {
      let h = NSHostingView(rootView: AnyView(root))
      h.translatesAutoresizingMaskIntoConstraints = false
      editorBox.addSubview(h, positioned: .below, relativeTo: claudeFloat)
      NSLayoutConstraint.activate([h.centerXAnchor.constraint(equalTo: editorBox.centerXAnchor),
                                   h.centerYAnchor.constraint(equalTo: editorBox.centerYAnchor)])
      emptyState = h
    }
    emptyState?.alphaValue = 1
  }

  func hideEmptyState() {
    guard let v = emptyState else { return }
    emptyState = nil
    NSAnimationContext.runAnimationGroup({ c in c.duration = reduceMotion ? 0 : 0.2; v.animator().alphaValue = 0 },
                                         completionHandler: { MainActor.assumeIsolated { v.removeFromSuperview() } })
  }

  /// Settings (⌘,) applied to this window, at start and on every change: Neovim's theme, font, line height and the
  /// plugin's comment options; the soft-wrap width; resolved comments; the accent on the focus line.
  func applySettings() {
    let s = TaudotSettings.shared
    if let native {
      // The native editor: the same theme tokens; "Your Neovim colours" means Dusk or Paper by the appearance.
      let dark = window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      let theme = Theme.named(s.editorTheme) ?? Theme.named(dark ? "dusk" : "paper")!
      let style = EditorStyle(theme: theme, fontFamily: s.fontFamily, fontSize: s.fontSize > 0 ? CGFloat(s.fontSize) : 13,
                              lineSpacing: s.lineSpace >= 0 ? CGFloat(s.lineSpace) : 3, maxColumns: s.maxTextWidth)
      // Only a real change re-styles the text (every setting comes through here: Appearance must not move it), and
      // then the character at the top of the view stays where it was.
      if native.view.style != style { keepingTop(of: native.view) { native.view.apply(style: style) } }
      native.view.vimEnabled = s.vimKeys
      syncColors()
    } else {
      Task { _ = try? await nvim.execLua(s.neovimLua(), []) }
      // Columns for the text plus the gutter (numbers and signs).
      editor.maxColumns = s.maxTextWidth > 0 ? s.maxTextWidth + 8 : 0
    }
    margin.showResolved = s.showResolved
    applyCommentsInText()
    pdf.pageStyle = PDFPaneView.PageStyle(rawValue: s.pdfPage) ?? .white
    focusLine.layer?.backgroundColor = accentColor.withAlphaComponent(0.85).cgColor
  }

  /// Runs `change` and puts the text back so the character at the top of the view is where it was (now and once the
  /// re-layout has settled).
  func keepingTop(of v: NativeEditorView, _ change: () -> Void) {
    let clip = v.scroll.contentView, tv = v.textView
    let topPoint = NSPoint(x: tv.textContainerInset.width + 4, y: clip.bounds.minY + 2)
    let idx = tv.characterIndexForInsertion(at: topPoint)
    // TextKit 2 (touching `layoutManager` would switch the view to TextKit 1): the paragraph's laid-out frame
    func lineY(_ i: Int) -> CGFloat? {
      guard let tlm = tv.textLayoutManager, let tcm = tlm.textContentManager,
            let loc = tcm.location(tcm.documentRange.location, offsetBy: i) else { return nil }
      tlm.ensureLayout(for: NSTextRange(location: loc))
      guard let f = tlm.textLayoutFragment(for: loc) else { return nil }
      return f.layoutFragmentFrame.minY + tv.textContainerOrigin.y
    }
    let offset = lineY(idx).map { clip.bounds.minY - $0 } ?? 0
    change()
    func restore() {
      guard let y = lineY(idx) else { return }
      clip.scroll(to: NSPoint(x: clip.bounds.minX, y: max(0, y + offset)))
      v.scroll.reflectScrolledClipView(clip)
    }
    restore()
    DispatchQueue.main.async { MainActor.assumeIsolated { restore() } }
  }

  var accentColor: NSColor {
    let a = TaudotSettings.shared.accent
    return a == "system" ? .controlAccentColor : MarkColor.color(hex: a) ?? .controlAccentColor
  }

  /// Native mode's start: the editor connects to the engine and opens the main file (or waits for one), then the
  /// review controller attaches through its bridge.
  func startNative(_ ed: NativeEditor, openProject: Bool) async {
    // A folder not cloned yet fills in ed.start (project.open clones it); then its main file goes to the PDF.
    let fresh = mainFile == nil && openProject
    if fresh { showEmptyState("Waiting for the project…") }
    do {
      try await ed.start(main: mainFile)
      try stillOpen()
      if fresh {
        if let m = ed.current ?? ProjectWindow.mainTex(in: folder) {
          mainFile = m
          pdf.open(folder: folder, main: m, engineSocket: engineSocket)
          hideEmptyState()
        } else {
          showEmptyState("No .tex file in this project yet")
        }
      }
      try await review?.attach(channel: nil)
      try stillOpen()
      startPhase = .started
      applySettings()
      giveEditorKeys()
    } catch is WindowClosed {
      return
    } catch {
      if startPhase == .booting { startPhase = .failed }
      status.note("editor: \(error)")
      if fresh { showEmptyState("Couldn't open the project: \(error)") }
    }
    if let c = ProcessInfo.processInfo.environment["TAUDOT_STATECHECK"], StateCheck.claim() { Task { await StateCheck(self, out: URL(fileURLWithPath: c)).run() } }
    if let c = ProcessInfo.processInfo.environment["TAUDOT_NATIVECHECK"] { Task { await NativeCheck(self, out: URL(fileURLWithPath: c)).run() } }
    if let c = ProcessInfo.processInfo.environment["TAUDOT_CYCLECHECK"] { Task { await CycleCheck(self, out: URL(fileURLWithPath: c)).run() } }
    if let c = ProcessInfo.processInfo.environment["TAUDOT_FLOATCHECK"] { Task { await FloatCheck(self, out: URL(fileURLWithPath: c)).run() } }
    if let c = ProcessInfo.processInfo.environment["TAUDOT_ZOOMCHECK"] { Task { await ZoomCheck(self, out: URL(fileURLWithPath: c)).run() } }
    if let c = ProcessInfo.processInfo.environment["TAUDOT_OUTSIDECHECK"] { Task { await OutsideCheck(self, out: URL(fileURLWithPath: c)).run() } }
  }

  /// The editor column takes the editor's background; the window's chrome (title bar, status bar, the issues strip,
  /// the Claude panel) follows Settings ▸ Appearance, live (the app's appearance; nothing pinned on the window).
  func syncColors() {
    let bg = native?.view.style.theme.bg ?? editor.ui.defaultBg, fg = native?.view.style.theme.fg ?? editor.ui.defaultFg
    if native == nil && TaudotSettings.shared.editorTheme == Theme.neovimID { SettingsModel.neovimColors = (bg, fg) }
    func color(_ c: UInt32) -> NSColor {
      NSColor(srgbRed: CGFloat((c >> 16) & 0xff) / 255, green: CGFloat((c >> 8) & 0xff) / 255, blue: CGFloat(c & 0xff) / 255, alpha: 1)
    }
    let c = color(bg)
    window.appearance = nil
    if window.backgroundColor != .windowBackgroundColor { window.backgroundColor = .windowBackgroundColor }
    if editorBox.layer?.backgroundColor != c.cgColor { editorBox.layer?.backgroundColor = c.cgColor }
    _ = fg
  }

  // MARK: window

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if closing { return true }
    Task { if await shutdown() { window.close() } }
    return false
  }

  /// End this window's Neovim: offer to save modified non-taudot buffers (taudot's sync live), then quit it,
  /// killing it after a second if it hangs. False if the user cancelled.
  /// ⌘Q's first phase (A4): this window's save question answered (saves done), nothing stopped. False if the user
  /// cancelled; then no window is touched.
  func readyToQuit() async -> Bool {
    guard native == nil, !closing, nvim.isRunning else { return true }
    return await oneQuitFlow { [self] in
      await nvim.resolveUnsaved { [weak self] bufs, retry in await self?.askUnsaved(bufs, retry: retry) ?? .discard }
    }
  }

  /// `asked`: readyToQuit already settled the save question (⌘Q's second phase): nothing more is asked.
  func shutdown(asked: Bool = false) async -> Bool {
    await oneQuitFlow { [self] in await shutdownNow(asked: asked) }
  }

  /// One quit flow at a time (A13): a second ⌘W, or ⌘Q, while one runs (its save question up) joins it and takes its
  /// answer, instead of asking again.
  func oneQuitFlow(_ body: @escaping @MainActor () async -> Bool) async -> Bool {
    if let t = quitFlow { return await t.value }
    let t = Task { @MainActor in await body() }
    quitFlow = t
    let ok = await t.value
    if quitFlow == t { quitFlow = nil }
    return ok
  }

  private func shutdownNow(asked: Bool) async -> Bool {
    if native != nil {
      // Native: edits are synced as typed; nothing to save or quit. Stop its reconnecting.
      savePanes()
      closing = true
      native?.stop()
      if let c = claude { claude = nil; await c.stop() }
      return true
    }
    if closing || !nvim.isRunning { closing = true; return true }
    savePanes()
    let ok = await nvim.quit { [weak self] bufs, retry in asked ? .discard : await self?.askUnsaved(bufs, retry: retry) ?? .discard }
    if ok {
      closing = true
      if let c = claude { claude = nil; await c.stop() }
    }
    return ok
  }

  func askUnsaved(_ bufs: [(buf: Int, name: String)], retry: Bool) async -> UnsavedChoice {
    asksOpen += 1
    asksMost = max(asksMost, asksOpen)
    defer { asksOpen -= 1 }
    if let a = ProcessInfo.processInfo.environment["TAUDOT_QUIT_ANSWER"] {
      // (checks: the answer comes after TAUDOT_QUIT_ANSWER_DELAY seconds, as a person's would)
      if let d = ProcessInfo.processInfo.environment["TAUDOT_QUIT_ANSWER_DELAY"].flatMap(Double.init) { try? await Task.sleep(for: .seconds(d)) }
      return a == "save" && !retry ? .save : a == "cancel" ? .cancel : .discard
    }
    let names = bufs.map { $0.name.isEmpty ? "[No Name]" : $0.name.replacingOccurrences(of: folder.path + "/", with: "") }
    let alert = NSAlert()
    alert.messageText = retry ? "Some files couldn't be saved." : "Save changes to files Taudot doesn't sync?"
    alert.informativeText = names.joined(separator: "\n") + (retry ? "\n\nQuit without them?" : "\n\nProject files are synced already.")
    if retry {
      alert.addButton(withTitle: "Quit Anyway"); alert.addButton(withTitle: "Cancel")
    } else {
      alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Don't Save"); alert.addButton(withTitle: "Cancel")
    }
    if !backgroundRun { window.makeKeyAndOrderFront(nil) }
    let r = await withCheckedContinuation { c in alert.beginSheetModal(for: window) { c.resume(returning: $0) } }
    if retry { return r == .alertFirstButtonReturn ? .discard : .cancel }
    return r == .alertFirstButtonReturn ? .save : r == .alertSecondButtonReturn ? .discard : .cancel
  }

  func windowWillClose(_ notification: Notification) {
    startPhase = .closed
    savePanes()
    paneAnimation?.invalidate()
    if let m = clickMonitor { NSEvent.removeMonitor(m) }
    pdf.close()
    nvim?.terminate()
    onClose?()
  }

  func windowDidBecomeKey(_ notification: Notification) { editor?.focused = window.firstResponder === editor; updateFocusLine(animated: false) }
  func windowDidResignKey(_ notification: Notification) { editor?.focused = false; updateFocusLine(animated: false) }
  func windowDidUpdate(_ notification: Notification) { trackFocus() }

  // MARK: helpers

  /// clients/nvim: in the bundle's Resources, else next to this source file (swift run from a checkout).
  static func pluginDir() -> String {
    if let r = Bundle.main.resourceURL?.appendingPathComponent("nvim"), FileManager.default.fileExists(atPath: r.appendingPathComponent("plugin").path) {
      return r.path
    }
    return URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../nvim").standardized.path
  }

  /// The main .tex (the PDF pane's rule: main.tex, else a top-level .tex with \documentclass).
  static func mainTex(in folder: URL) -> String? { TaudotPDFPane.findMain(in: folder) }

  /// A Finder-launched app has a bare environment: take PATH (and a few more, unless already set) from the login
  /// shell, once: read on a background thread from launch on (`LoginEnvironment.prefetch`), so the shell starts while
  /// AppKit does instead of in front of the first window.
  static func environment() -> [String: String] { LoginEnvironment.shared.get() }

  nonisolated static func readEnvironment() -> [String: String] {
    let env = ProcessInfo.processInfo.environment
    if env["TERM"] != nil { return [:] }
    let shell = env["SHELL"] ?? "/bin/zsh"
    let p = Process()
    p.executableURL = URL(fileURLWithPath: shell)
    p.arguments = ["-l", "-c", "env"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return [:] }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    var r: [String: String] = [:]
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
      guard let eq = line.firstIndex(of: "=") else { continue }
      let k = String(line[..<eq])
      if k == "PATH" || (["LANG", "LC_ALL", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "TAUDOT_SOCKET"].contains(k) && env[k] == nil) {
        r[k] = String(line[line.index(after: eq)...])
      }
    }
    return r
  }
}

/// A swap file left by a Neovim that died (a crash, a kill) would stop the window at Neovim's "Found a swap file"
/// question before the app is attached. The app answers it: a dead owner's unmodified swap is deleted; anything else
/// (its owner still running, or unsaved changes in it) opens the file anyway and says so. Taudot's buffers are synced
/// as they are typed, so the file on disk is already current.
let swapLua = "lua vim.api.nvim_create_autocmd('SwapExists', { callback = function() "
  + "local i = vim.fn.swapinfo(vim.v.swapname); local pid = tonumber(i.pid) or 0; "
  + "local alive = pid > 0 and vim.uv.kill(pid, 0) == 0; "
  + "if not alive and (tonumber(i.dirty) or 0) == 0 then vim.v.swapchoice = 'd'; return end; "
  + "vim.v.swapchoice = 'e'; local f = vim.fn.fnamemodify(vim.v.swapname, ':t'); "
  + "vim.schedule(function() vim.notify(alive and ('Taudot: another Neovim (pid ' .. pid .. ') has this file open too') "
  + "or ('Taudot: an older swap file has unsaved changes (' .. f .. '); :recover to see them'), vim.log.levels.WARN) end) end })"

let startupLua = """
local dir, folder, open = ...
-- Configs can tell they run in the app (like vim.g.neovide).
vim.g.taudot_app = 1
vim.api.nvim_create_autocmd('VimEnter', { once = true, callback = function()
  -- The app scrolls smoothly and animates the cursor itself. Plugins that do it inside Neovim fight it: mini.animate
  -- puts every scroll back and replays it a row at a time (seen: the view lagged and bounced), and smear-cursor
  -- draws its trail in the grid. Turn them off here; a config can check vim.g.taudot_app to do it earlier.
  vim.g.minianimate_disable = true
  pcall(function() require('smear_cursor').enabled = false end)
  if vim.fn.exists(':Taudot') ~= 2 then
    vim.opt.runtimepath:append(dir)
    vim.cmd('runtime! plugin/taudot.lua')
  end
  -- Mac-style copy and paste unless the user has their own.
  if vim.fn.maparg('<D-v>', 'n') == '' then
    vim.keymap.set({ 'n', 'v' }, '<D-v>', '"+p')
    vim.keymap.set({ 'i', 'c' }, '<D-v>', '<C-r>+')
    vim.keymap.set('v', '<D-c>', '"+y')
    vim.keymap.set('n', '<D-s>', '<cmd>write<cr>')
  end
  if open then vim.cmd('Taudot open ' .. vim.fn.fnameescape(folder)) end
end })
"""

/// The app's side of the plugin, as `package.loaded['taudot.app']`: cursor-follow and forward search to the PDF
/// (`taudot_app_cursor path line forced`), and the engine connection for the status bar (`taudot_app_status`).
let appLua = """
local chan, folder = ...
local api, uv = vim.api, vim.uv
local M = {}
package.loaded['taudot.app'] = M
local root = (uv.fs_realpath(folder) or folder) .. '/'
local function rel(p)
  p = uv.fs_realpath(p) or p
  if p:sub(1, #root) == root then return p:sub(#root + 1) end
  if p:sub(1, #folder + 1) == folder .. '/' then return p:sub(#folder + 2) end
  return p
end
-- Editor → PDF: every change to a doc's text in Neovim (taudot.buffer's text_changed), so the PDF typesets the
-- buffer's own text without the engine round trip (pdfpipe): `taudot_app_text path edits` (byte offsets, applied in
-- order) or `taudot_app_text path nil text` (whole), `taudot_app_text_released path`.
function M.text(b, edits, text)
  if edits then vim.rpcnotify(chan, 'taudot_app_text', b.path, edits)
  else vim.rpcnotify(chan, 'taudot_app_text', b.path, vim.NIL, text or b.text) end
end
function M.text_released(b) vim.rpcnotify(chan, 'taudot_app_text_released', b.path) end
-- An outside edit applied to a doc (a coauthor's, or one made on disk): `taudot_app_outside path edits author origin
-- source`, edits in the buffer's byte offsets, applied one after another (after its taudot_app_text).
function M.outside(b, edits, author, origin, source)
  vim.rpcnotify(chan, 'taudot_app_outside', b.path, edits, author or vim.NIL, origin or vim.NIL, source or vim.NIL)
end
-- The app's Undo of an outside edit: replace `del` bytes at byte `pos` of the doc at `path` with `ins`, as if typed (the
-- plugin sends it). True when the doc is open here.
function M.replace(path, pos, del, ins)
  local B = require('taudot.buffer')
  for _, b in pairs(B.by_buf or {}) do
    if b.path == path and api.nvim_buf_is_valid(b.buf) then
      local sr, sc = B.pos_to_rc(b.buf, pos)
      local er, ec = B.pos_to_rc(b.buf, pos + del)
      if not (sr and er) then return false end
      api.nvim_buf_set_text(b.buf, sr, sc, er, ec, vim.split(ins, '\\n', { plain = true }))
      return true
    end
  end
  return false
end
do  -- buffers attached before this ran
  local okb, buffer = pcall(require, 'taudot.buffer')
  if okb and buffer.by_buf then
    for _, b in pairs(buffer.by_buf) do if b.text and not b.detached then M.text(b, nil) end end
  end
end
local last
-- ]r / [r and the app's ⌥⌘↓ / ⌥⌘↑ go through taudot.gui's jump: the next cursor event is deliberate (the PDF shows
-- its highlight there; ordinary moves only move the coral dot)
local okg, gui = pcall(require, 'taudot.gui')
if okg and type(gui.jump) == 'function' and not gui._app_jump then
  local jump = gui.jump
  gui.jump = function(...) M.deliberate = true; return jump(...) end
  gui._app_jump = true
end
-- The word the cursor is in (its first byte, 0-based), so the PDF's mark follows word to word along a line.
local function word_start(text, col)
  local i = col + 1
  if not text:sub(i, i):match('[%w\\128-\\255]') then return col end
  while i > 1 and text:sub(i - 1, i - 1):match('[%w\\128-\\255]') do i = i - 1 end
  return i - 1
end
function M.cursor(force, insert, click)
  local name = api.nvim_buf_get_name(0)
  if not name:match('%.tex$') then
    -- not a .tex buffer: the PDF's mark goes (once)
    if last ~= '' then last = ''; vim.rpcnotify(chan, 'taudot_app_cursor', '', 0, false, 0) end
    return
  end
  local line, col = unpack(api.nvim_win_get_cursor(0))
  local key = name .. ':' .. line
  -- in normal mode, each word; while typing, each line (a word key would ask the PDF for every pause)
  if not insert then key = key .. ':' .. word_start(api.nvim_get_current_line(), col) end
  local deliberate = force == true or M.deliberate == true
  if key == last and not deliberate then return end
  M.deliberate = false
  last = key
  vim.rpcnotify(chan, 'taudot_app_cursor', rel(name), line, force == true, col, deliberate, click == true)
end
local timer = uv.new_timer()
local g = api.nvim_create_augroup('taudot_app', { clear = true })
-- The cursor dot on the PDF: every move and every edit, at once, with the line as it is now (the PDF places the dot
-- on the page already drawn; no typeset needed) and when it was sent (uv.hrtime: the app's clock).
api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI', 'TextChanged', 'TextChangedI', 'BufEnter' }, { group = g, callback = function()
  local name = api.nvim_buf_get_name(0)
  if not name:match('%.tex$') then return end
  local line, col = unpack(api.nvim_win_get_cursor(0))
  vim.rpcnotify(chan, 'taudot_app_caret', rel(name), line, col, api.nvim_get_current_line(), uv.hrtime() / 1e9)
end })
api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI', 'BufEnter' }, { group = g, callback = function(ev)
  local insert = ev.event == 'CursorMovedI'
  timer:stop()
  timer:start(150, 0, vim.schedule_wrap(function() M.cursor(false, insert) end))
end })
-- A double-click selects the word, as usual, and shows it in the PDF (a deliberate jump: the highlight goes there,
-- and fades by itself, as a click in the PDF's does).
if vim.fn.maparg('<2-LeftMouse>', 'n') == '' then
  vim.keymap.set('n', '<2-LeftMouse>', "<2-LeftMouse><Cmd>lua require('taudot.app').cursor(true, false, true)<CR>",
    { desc = 'Taudot: select the word and show it in the PDF' })
end
if vim.fn.maparg('<leader>av', 'n') == '' then
  vim.keymap.set('n', '<leader>av', function() M.cursor(true) end, { desc = 'Taudot: show this line in the PDF' })
end
-- The status bar's engine state (connection, unconfirmed edits, who else is here). The plugin has no events for these,
-- so it is polled, but only as fast as it can change: every 400 ms while something is in flight (unconfirmed edits, not
-- connecting), every 3 s at rest, right away after an edit, and not at all while the window is hidden (M.pause).
local sent, busy, paused = '', true, false
local st = uv.new_timer()
local function status()
  local ok, t = pcall(require, 'taudot')
  local p = ok and t.project() or nil
  local s = { connection = 'none', unconfirmed = 0, users = {} }
  if p then
    s.connection = p.connection or 'offline'
    for _, b in pairs(t.buffers() or {}) do
      s.unconfirmed = s.unconfirmed + (b.unconfirmed and b:unconfirmed() or 0)
      if b.error then s.error = b.path .. ': ' .. b.error end
    end
    for _, u in ipairs(p.users or {}) do
      if u.user_id ~= p.me then s.users[#s.users + 1] = u.name or u.initials or '?' end
    end
    s.track = p.track_changes == true
  end
  busy = s.unconfirmed > 0 or s.connection == 'connecting'
  local j = vim.json.encode(s)
  if j ~= sent then sent = j; vim.rpcnotify(chan, 'taudot_app_status', s) end
end
local function schedule(ms)
  st:stop()
  if paused then return end
  st:start(ms, 0, vim.schedule_wrap(function() status(); schedule(busy and 400 or 3000) end))
end
api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, { group = g, callback = function()
  if not paused and (not busy or st:get_due_in() > 400) then schedule(400) end
end })
function M.pause(p)
  paused = p
  if p then st:stop() else schedule(0) end
end
schedule(0)
return true
"""

/// TAUDOT_TIMELINE=1: launch milestones on stderr, in ms since the process started (finding what waits in series).
@MainActor func timeline(_ what: String) {
  Latency.shared.launch(what)
  guard ProcessInfo.processInfo.environment["TAUDOT_TIMELINE"] != nil else { return }
  var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
  var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
  sysctl(&mib, 4, &info, &size, nil, 0)
  let st = info.kp_proc.p_un.__p_starttime
  var now = timeval(); gettimeofday(&now, nil)
  let ms = Double(now.tv_sec - st.tv_sec) * 1000 + Double(now.tv_usec - st.tv_usec) / 1000
  FileHandle.standardError.write(String(format: "timeline %7.1f %@\n", ms, what).data(using: .utf8)!)
}

final class LoginEnvironment: @unchecked Sendable {
  static let shared = LoginEnvironment()
  private let lock = NSCondition()
  private var value: [String: String]?
  private var started = false

  func prefetch() {
    lock.lock(); defer { lock.unlock() }
    guard !started else { return }
    started = true
    Thread.detachNewThread { [self] in
      let v = ProjectWindow.readEnvironment()
      lock.lock(); value = v; lock.broadcast(); lock.unlock()
    }
  }

  func get() -> [String: String] {
    prefetch()
    lock.lock(); defer { lock.unlock() }
    while value == nil { lock.wait() }
    return value!
  }
}

/// Measured runs (TAUDOT_MEASURE): a window AppKit doesn't pull back onto a screen when it orders in.
final class MeasureWindow: NSWindow {
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { measureRun && !onScreenRun ? frameRect : super.constrainFrameRect(frameRect, to: screen) }
}
