// Wires the margin to Neovim: taudot_review* notifications in, gui.act out.
import AppKit
import TaudotShared

@MainActor public final class ReviewController {
  public let margin: ReviewMarginView
  public let nvim: NeovimBridge
  private var req = 0
  private var pending: [Int: ReviewAction] = [:]
  /// Every action's outcome, for tests and logs.
  public var onResult: ((ReviewAction, String?) -> Void)?
  /// A state the margin now shows (after the empty-list hold): what the app's auto-hide should follow, rather than
  /// raw taudot_review notifications.
  public var onStateApplied: ((ReviewState) -> Void)?
  /// How long an empty list for the buffer that just had cards waits before it is believed (gui.lua holds too).
  public var emptyHold: TimeInterval = 0.5
  /// How long an action may wait for its taudot_review_done before it fails (A18).
  public var actionTimeout: TimeInterval = 20
  var pendingCount: Int { pending.count }
  private var held: ReviewState?
  private var attached = false

  /// Inline end-of-line notes off while the margin shows, back as the user had them when it hides.
  func marginShown(_ shown: Bool) {
    guard attached else { return }
    ReviewMarginView.traceLine("margin \(shown ? "shown" : "hidden") → inline notes \(shown ? "off" : "restored")")
    Task { @MainActor in
      _ = try? await nvim.execLua("return require('taudot.gui').act(...)", [.string("margin_shown"), .null, .map([(.string("shown"), .bool(shown))])])
    }
  }
  private var holdTimer: Timer?
  private var keyMonitor: Any?

  public init(nvim: NeovimBridge, margin: ReviewMarginView) {
    self.nvim = nvim
    self.margin = margin
    margin.onAction = { [weak self] a in self?.send(a) }
    margin.onStartComment = { [weak self] in self?.startComment() }
    margin.onVisibilityChange = { [weak self] shown in self?.marginShown(shown) }
    margin.onShowResolvedChange = { [weak self] on in self?.showResolved(on); self?.updateBar() }
    margin.onCurrentChange = { [weak self] in self?.updateBar() }
    margin.onLayoutChange = { [weak self] l in self?.sendLayout(l) }
    bar.onVerb = { [weak self] v in _ = self?.verb(v) }
    bar.onAllInFile = { [weak self] accept in self?.sidebar?.allInFile(accept: accept) }
    bar.onPreview = { [weak self] m in self?.preview(m) }
    bar.onClose = { [weak self] in self?.stopReview() }
  }

  func sendLayout(_ l: ReviewMarginView.Layout) {
    guard attached else { return }
    Task { @MainActor in
      _ = try? await nvim.execLua("return require('taudot.gui').act(...)", [.string("layout"), .null, .map([(.string("stacked"), .bool(l == .stacked))])])
    }
  }

  func sendKinds(_ k: ReviewKinds) {
    guard attached else { return }
    Task { @MainActor in
      _ = try? await nvim.execLua("return require('taudot.gui').act(...)", [.string("kinds"), .null,
        .map([(.string("comments"), .bool(k.contains(.comments))), (.string("suggestions"), .bool(k.contains(.suggestions)))])])
    }
  }

  // ---- review mode: the bar, the previews ------------------------------------------------------------------------

  /// The review bar (the app puts it over the editor).
  public let bar = ReviewBar()
  /// Showing the bar: from ⌥⌘↓ / ⌥⌘↑ or Review ▸ Review Suggestions…, until its ✕.
  public private(set) var reviewing = false
  public private(set) var previewMode = "off"

  /// Show the bar; with nothing under the cursor, go to the first item (`jumpIfNothingHere`). Returns whether it
  /// jumped (⌥⌘↓ then mustn't jump again: that skipped the first comment).
  @discardableResult public func startReview(jumpIfNothingHere: Bool = true) -> Bool {
    var jumped = false
    if !reviewing {
      reviewing = true
      bar.isHidden = false
      if jumpIfNothingHere && margin.currentItem == nil { jump(1); jumped = true }
    }
    updateBar()
    return jumped
  }
  public func stopReview() {
    reviewing = false
    bar.isHidden = true
    if previewMode != "off" { preview("off") }
  }
  func updateBar() {
    guard reviewing else { return }
    let cur = margin.currentItem
    bar.show(text: ReviewPosition.text(cur, in: margin.state.items, kinds: margin.kinds, showResolved: margin.showResolved),
             comment: cur?.kind == .comment || (cur == nil && margin.kinds == .comments))
  }
  /// "accepted", "rejected", "off".
  public func preview(_ mode: String) {
    Task { @MainActor in
      let r = try? await nvim.execLua("return require('taudot.gui').act(...)", [.string("preview"), .null, .map([(.string("mode"), .string(mode))])])
      if r?["ok"].bool != true { sidebar?.files.onError?(r?["error"].string ?? "can't preview") }
    }
  }
  func previewChanged(_ mode: String) {
    previewMode = mode
    margin.previewMode = mode == "off" ? nil : mode
    bar.setPreview(mode)
  }

  /// The Review menu (any pane): next / previous go through Neovim (across files, following the filter); the rest act
  /// on the selected card, else the one at the cursor, then select the next. False: nothing to act on.
  @discardableResult public func verb(_ v: ReviewVerb) -> Bool {
    switch v {
    case .next, .previous:
      startReview(jumpIfNothingHere: false)
      // Stacked, or one author's: through the panel's list (what it shows, in its order); else Neovim's jump,
      // across files.
      if margin.cardLayout == .stacked || margin.authorFilter != nil { return margin.verb(v) }
      jump(v == .next ? 1 : -1)
      return true
    default: return margin.verb(v)
    }
  }

  func showResolved(_ on: Bool) {
    guard attached else { return }
    Task { @MainActor in
      _ = try? await nvim.execLua("return require('taudot.gui').act(...)", [.string("show_resolved"), .null, .map([(.string("on"), .bool(on))])])
    }
  }

  /// To the next (dir 1) or previous (-1) open comment or tracked change, on into the project's other files at the
  /// ends (gui.jump, as ]r / [r). Neovim moves the cursor; the card follows it (selected, or floating).
  public func jump(_ dir: Int, count: Int = 1) {
    Task { @MainActor in
      _ = try? await nvim.execLua("require('taudot.gui').jump(...)", [.int(Int64(dir < 0 ? -1 : 1)), .int(Int64(max(1, count)))])
    }
  }

  /// The sidebar's controller: its Comments tab is the margin; its Files tab opens files in Neovim and follows the
  /// buffer Neovim shows.
  public weak var sidebar: SidebarView?
  public convenience init(nvim: NeovimBridge, sidebar: SidebarView) {
    self.init(nvim: nvim, margin: sidebar.margin)
    self.sidebar = sidebar
    sidebar.files.onOpen = { [weak self] url in self?.open(url) }
    sidebar.overview.onReveal = { [weak self] it in self?.reveal(it) }
    sidebar.onKindsChange = { [weak self] k in self?.sendKinds(k) }
    sidebar.overview.onAction = { [weak self] a, it in
      guard let self else { return }
      let go = { [weak self] in self?.send(a, path: it.path) }
      if case .delete = a {
        self.margin.ask("Delete this comment?", info: "This deletes the comment and its replies from Overleaf for everyone. This can't be undone.", button: "Delete") { ok in
          if ok { go() }
        }
      } else {
        go()
      }
    }
    sidebar.onScopeChange = { [weak self] s in if s == .all { self?.refreshOverview() } }
    sidebar.onTabChange = { [weak self, weak sidebar] _ in if sidebar?.overviewVisible == true { self?.refreshOverview() } }
  }

  // ---- the overview (Comments ▸ All) ----------------------------------------------------------------------------

  private var overviewReqs: Set<Int> = []
  private var overviewQueued = false
  /// Fetch every comment in the project (gui.lua's act overview) into the sidebar's overview. Coalesced.
  public func refreshOverview() {
    guard attached, !overviewQueued else { return }
    overviewQueued = true
    Task { @MainActor in
      overviewQueued = false
      req += 1
      let r = req
      overviewReqs.insert(r)
      let res = try? await nvim.execLua("return require('taudot.gui').act(...)", [.string("overview"), .null, .map([(.string("req"), .int(Int64(r)))])])
      if res?["ok"].bool != true { overviewReqs.remove(r) }
    }
  }

  /// A row of the overview: Neovim opens its file at it (as ]r lands) and the sidebar goes back to This File, where
  /// the cursor selects its card.
  public func reveal(_ it: OverviewItem) {
    if it.resolved { margin.showResolved = true }
    sidebar?.scope = .file
    send(.reveal(it.id, path: it.path))
  }

  /// Edit a file in Neovim's main window (gui.act open). A failure shows as a notice.
  public func open(_ url: URL) {
    Task { @MainActor in
      do {
        let r = try await nvim.execLua("return require('taudot.gui').act(...)", [.string("open"), .null, .map([(.string("path"), .string(url.path))])])
        if !r["ok"].bool { sidebar?.files.onError?(r["error"].string ?? "can't open \(url.lastPathComponent)") }
        onResult?(.open(url.path), r["ok"].bool ? nil : (r["error"].string ?? "failed"))
      } catch {
        onResult?(.open(url.path), "\(error)")
      }
    }
  }

  /// A new comment: gui.lua captures the selection (live or just left) and its text; the draft card quotes it and
  /// the comment is sent on that range. No selection: a notice, no card.
  public func startComment() {
    Task { @MainActor in
      do {
        let r = try await nvim.execLua("return require('taudot.gui').act(...)", [.string("start_comment"), .null, .map([])])
        openDraft(r)
      } catch {
        margin.notice("\(error)")
      }
    }
  }

  /// start_comment's answer: a draft on that range quoting its text, or the notice.
  func openDraft(_ r: Value) {
    guard r["ok"].bool, let l = r["line"].int, let c = r["col"].int, let el = r["end_line"].int, let ec = r["end_col"].int else {
      margin.notice(Self.noticeText(r["error"].string))
      return
    }
    margin.beginNewComment(on: ReviewRange(line: l, col: c, endLine: el, endCol: ec), quote: r["quote"].string ?? "")
  }

  /// ⌥⌘M in the margin's window starts a comment on the selection. (A local monitor, so it works whatever has the
  /// focus, the editor included, without a menu item; the app may add one calling `margin.newComment()`.)
  func installShortcut() {
    guard keyMonitor == nil else { return }
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
      guard let self, Self.isNewCommentShortcut(e), e.window != nil, e.window === self.margin.window else { return e }
      self.margin.newComment()
      return nil
    }
  }

  static func isNewCommentShortcut(_ e: NSEvent) -> Bool {
    e.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function]) == [.command, .option]
      && e.keyCode == 46  // M, whatever the layout's character for ⌥M is
  }

  isolated deinit {
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
  }

  static func noticeText(_ e: String?) -> String {
    guard let e, !e.isEmpty else { return "Select text to comment" }
    return e.prefix(1).uppercased() + e.dropFirst()
  }

  /// Start listening and ask gui.lua for the state. `channel`: this UI's channel id (nil: the attached UI's).
  public func attach(channel: Int? = nil) async throws {
    ScrollEventTrace.install()
    nvim.notify("taudot_review") { [weak self] args in
      guard let self, let p = args.first else { return }
      self.receive(ReviewState(p))
    }
    nvim.notify("taudot_review_cursor") { [weak self] args in
      guard let self, let p = args.first else { return }
      self.margin.cursor = ReviewCursor(p)
    }
    // The file tree's dots: open comments and collaborators per file.
    nvim.notify("taudot_files") { [weak self] args in
      guard let self, let p = args.first else { return }
      self.sidebar?.files.badges = FileBadges(p)
    }
    // :Taudot comment / <leader>ac in Neovim: gui.lua captured the selection; open the draft.
    nvim.notify("taudot_review_start") { [weak self] args in
      guard let self, let p = args.first else { return }
      self.openDraft(p)
    }
    // A jump landed (]r [r ⌥⌘↓ ⌥⌘↑, the bar): its card opens as a click would.
    nvim.notify("taudot_review_landed") { [weak self] args in
      guard let self, let id = args.first?["id"].string else { return }
      self.margin.land(on: id)
      self.updateBar()
    }
    nvim.notify("taudot_preview") { [weak self] args in
      guard let self, let p = args.first else { return }
      self.previewChanged(p["mode"].string ?? "off")
    }
    nvim.notify("taudot_overview_changed") { [weak self] _ in
      guard let self, self.sidebar?.overviewVisible == true else { return }
      self.refreshOverview()
    }
    nvim.notify("taudot_review_done") { [weak self] args in
      guard let self, let p = args.first, let r = p["req"].int else { return }
      if self.overviewReqs.remove(r) != nil {
        self.sidebar?.overview.items = Overview.items(p["result"])
        return
      }
      guard let a = self.pending.removeValue(forKey: r) else { return }
      self.afterwards.removeValue(forKey: r)?()
      if p["ok"].bool {
        self.margin.actionSucceeded(a)
        self.onResult?(a, nil)
      } else {
        let e = p["error"].string ?? "failed"
        self.margin.actionFailed(a, e)
        self.onResult?(a, e)
      }
    }
    installShortcut()
    let ok = try await nvim.execLua("return require('taudot.gui').attach(...)", [channel.map { .int(Int64($0)) } ?? .null])
    if ok != .bool(true) {
      throw ReviewError.notAttached
    }
    attached = true
    marginShown(margin.isShowing)
    if margin.showResolved { showResolved(true) }
    if let k = sidebar?.kinds, k != .all { sendKinds(k) }
    if margin.cardLayout == .stacked { sendLayout(.stacked) }
  }

  public enum ReviewError: Error { case notAttached }

  /// A taudot_review payload. Cards never go because of a transient empty list: one for the buffer that has
  /// cards waits `emptyHold`, and is dropped if anything else arrives meanwhile.
  public func receive(_ s: ReviewState) {
    let shown = margin.state
    let transient = s.synced && s.items.isEmpty && s.buf == shown.buf && !shown.items.isEmpty
    ReviewMarginView.traceLine("payload buf \(s.buf) synced \(s.synced) items \(s.items.count) reason \(s.reason ?? "-") → \(transient ? "held" : "applied")")
    if transient {
      held = s
      if holdTimer == nil {
        let t = Timer(timeInterval: emptyHold, repeats: false) { [weak self] _ in
          MainActor.assumeIsolated {
            guard let self else { return }
            self.holdTimer = nil
            if let h = self.held {
              self.held = nil
              ReviewMarginView.traceLine("payload buf \(h.buf) items 0 held \(Int(self.emptyHold * 1000)) ms → applied")
              self.apply(h)
            }
          }
        }
        RunLoop.main.add(t, forMode: .common)
        holdTimer = t
      }
      return
    }
    held = nil
    holdTimer?.invalidate()
    holdTimer = nil
    apply(s)
  }

  private func apply(_ s: ReviewState) {
    margin.state = s
    if let f = s.file { sidebar?.files.current = URL(fileURLWithPath: f) }
    onStateApplied?(s)
  }

  /// gui.act's arguments for an action.
  public static func args(_ a: ReviewAction, req: Int?, buf: Int? = nil) -> [(Value, Value)] {
    var m: [(Value, Value)] = []
    if let req { m.append((.string("req"), .int(Int64(req)))) }
    // A new comment goes to the buffer its draft was started in (A3), not whichever is current.
    if let buf { m.append((.string("buf"), .int(Int64(buf)))) }
    switch a {
    case let .reply(_, text):
      m.append((.string("text"), .string(text)))
    case let .editMessage(_, mid, text):
      m.append((.string("message_id"), .string(mid)))
      m.append((.string("text"), .string(text)))
    case let .deleteMessage(_, mid):
      m.append((.string("message_id"), .string(mid)))
    case let .reveal(_, path):
      m.append((.string("path"), .string(path)))
    case let .acceptAll(ids), let .rejectAll(ids):
      m.append((.string("ids"), .array(ids.map { .string($0) })))
    case let .comment(r, text):
      m += [
        (.string("text"), .string(text)), (.string("line"), .int(Int64(r.line))), (.string("col"), .int(Int64(r.col))),
        (.string("end_line"), .int(Int64(r.endLine))), (.string("end_col"), .int(Int64(r.endCol))),
      ]
    default: break
    }
    return m
  }

  /// An action from the overview: its file (maybe not open in Neovim) goes along; the list is fetched again after.
  public func send(_ a: ReviewAction, path: String) {
    req += 1
    let r = req
    track(r, a)
    afterwards[r] = { [weak self] in self?.refreshOverview() }
    let args: [Value] = [.string(a.kind), a.id.map { .string($0) } ?? .null, .map(Self.args(a, req: r) + [(.string("path"), .string(path))])]
    Task { @MainActor in
      let res = try? await nvim.execLua("return require('taudot.gui').act(...)", args)
      if res?["ok"].bool != true {
        pending[r] = nil
        afterwards[r] = nil
        let e = res?["error"].string ?? "failed"
        sidebar?.files.onError?("\(a.kind): \(e)")
        onResult?(a, e)
      }
    }
  }
  private var afterwards: [Int: () -> Void] = [:]

  /// An action waiting for its taudot_review_done (A18): it fails after `actionTimeout` if none comes, so no card
  /// stays "sending" and nothing waits forever.
  private func track(_ r: Int, _ a: ReviewAction) {
    pending[r] = a
    let wait = actionTimeout
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(wait))
      guard let self, let a = self.pending.removeValue(forKey: r) else { return }
      self.afterwards[r] = nil
      let e = "no answer from the editor"
      self.margin.actionFailed(a, e)
      self.onResult?(a, e)
    }
  }

  public func send(_ a: ReviewAction) {
    // select and goto answer at once; the rest go to the engine and come back as taudot_review_done.
    let async = !(a.kind == "select" || a.kind == "goto")
    var r: Int?
    if async {
      req += 1
      r = req
      track(req, a)
    }
    let args: [Value] = [.string(a.kind), a.id.map { .string($0) } ?? .null, .map(Self.args(a, req: r, buf: margin.target(of: a)))]
    Task { @MainActor in
      do {
        let res = try await nvim.execLua("return require('taudot.gui').act(...)", args)
        if !res["ok"].bool {
          if let r { pending[r] = nil }
          let e = res["error"].string ?? "failed"
          margin.actionFailed(a, e)
          onResult?(a, e)
        } else if !async {
          onResult?(a, nil)
        }
      } catch {
        if let r { pending[r] = nil }
        margin.actionFailed(a, "\(error)")
        onResult?(a, "\(error)")
      }
    }
  }
}
