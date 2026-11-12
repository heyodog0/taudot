// The native editor mode: a project's docs edited in NativeEditorView, talking to the engine directly.
//
// The shell keeps its wiring: `bridge` is a NeovimBridge that answers the calls the app makes into Neovim's Lua
// (`taudot.gui` for the review margin, `taudot.preview.jump` and `taudot.app.cursor` for PDF sync) and sends the
// same notifications (`taudot_review`, `taudot_review_cursor`, `taudot_review_done`, `taudot_app_cursor`,
// `taudot_app_status`), so ReviewController, the margin, its floating cards and the PDF pane work unchanged.
import AppKit
import TaudotPDF
import TaudotShared

public struct EditorError: Error, CustomStringConvertible {
  public var description: String
  init(_ d: String) { description = d }
}

@MainActor public final class NativeEditor {
  public let folder: URL
  public let socket: URL
  public let view: NativeEditorView
  public let bridge = NativeBridge()
  public private(set) var conn: JSONRPCConnection?
  public private(set) var projectID: String?
  public private(set) var me: [String: Any] = [:]
  public private(set) var docIDs: [String: String] = [:]
  public private(set) var docs: [String: NativeDoc] = [:]
  public private(set) var current: String?
  public private(set) var connection = "connecting" { didSet { statusChanged() } }
  var threads: [String: [String: Any]] = [:]
  var threadsSupported = true
  var track = false { didSet { statusChanged() } }
  var users: [[String: Any]] = [] { didSet { statusChanged() } }
  var showResolved = false
  /// The comments margin is on screen (gui.lua's margin_shown): the end-of-line notes are off while it shows.
  var marginShown = true { didSet { if marginShown != oldValue { reviewChanged() } } }
  /// View ▸ Hide Comments in Text: no comment tints, no end-of-line notes (the margin's list still works).
  public var inlineHidden = false {
    didSet { if inlineHidden != oldValue { view.commentsHidden = inlineHidden; reviewChanged() } }
  }
  /// The end-of-line comment notes now (LineNotes.swift), and each change of them.
  public internal(set) var lineNotes: [LineNote] = []
  public var onLineNotes: (([LineNote]) -> Void)?
  /// The panel's Comments / Suggestions filter (the jumps follow it).
  var kinds: (comments: Bool, suggestions: Bool) = (true, true)
  /// The item the last jump landed on (to step past it when another starts at the same place).
  var lastJumped: String?
  private var buffers: [String: Int] = [:]
  private var statusTimer: Timer?
  /// A caret move for the PDF's dot, sent after the frame (caretMoved).
  private var pendingCaret: [Value]?
  private var lastStatus: Value?
  private var presenceTimer: Timer?
  /// Errors worth showing (the shell's status bar).
  public var onError: ((String) -> Void)?
  /// The engine docs this editor holds, and every change to their text (NativeDoc.onText), for the PDF pane to
  /// typeset the editor's own text (pdfpipe): `held` once a doc is opened, `released` for each at stop.
  public var docFeed: DocFeed? {
    didSet { for d in docs.values where !d.docID.isEmpty { feed(d) } }
  }
  public struct DocFeed {
    public var held: @MainActor (_ path: String, _ text: String) -> Void
    public var changed: @MainActor (_ path: String, _ pos: Int, _ del: Int, _ ins: String) -> Void
    public var released: @MainActor (_ path: String) -> Void
    public init(held: @escaping @MainActor (String, String) -> Void,
                changed: @escaping @MainActor (String, Int, Int, String) -> Void,
                released: @escaping @MainActor (String) -> Void) {
      self.held = held
      self.changed = changed
      self.released = released
    }
  }

  private func feed(_ d: NativeDoc) {
    let path = d.path
    // outside edits (a coauthor's, or one made on disk) to the app, as Neovim's taudot.app sends them (item 9)
    d.onOutside = { [weak self] edits, p in
      let es = Value.array(edits.map { Value.obj([("pos", .int(Int64($0.pos))), ("del", .int(Int64($0.del))), ("ins", .string($0.ins))]) })
      self?.bridge.emit("taudot_app_outside", [.string(path), es, Value.from(p["author"]), Value.from(p["origin"]), Value.from(p["source"])])
    }
    guard let f = docFeed else { d.onText = nil; return }
    f.held(d.path, d.string)
    d.onText = { edits in for e in edits { f.changed(path, e.pos, e.del, e.ins) } }
  }

  public init(folder: URL, socket: URL, frame: NSRect = NSRect(x: 0, y: 0, width: 800, height: 600)) {
    self.folder = folder
    self.socket = socket
    view = NativeEditorView(frame: frame)
    bridge.editor = self
    // Vim keys: the review verbs, as in Neovim (]r [r to cycle, ga gx gC on the item at the caret, then the next).
    func jump(_ d: Int) -> (Int) -> Void { { [weak self] n in Task { @MainActor in _ = await self?.act("jump", id: nil, args: .obj([("dir", .int(Int64(d))), ("count", .int(Int64(n)))])) } } }
    func verb(_ v: String) -> (Int) -> Void { { [weak self] _ in Task { @MainActor in _ = await self?.act("verb", id: nil, args: .obj([("verb", .string(v))])) } } }
    view.vimCommands = ["]r": jump(1), "[r": jump(-1), "ga": verb("accept"), "gx": verb("reject"), "gC": verb("resolve")]
    view.completer = { [weak self] pos, before in await self?.complete(pos: pos, before: before) }
    view.onCursor = { [weak self] line, col in self?.cursorMoved(line: line, col: col, force: false) }
    view.onSelection = { [weak self] in self?.selectionChanged() }
    view.onCaret = { [weak self] line, col, text in self?.caretMoved(line: line, col: col, text: text) }
    view.textView.onDoubleClick = { [weak self] in self?.forwardSearch() }
  }

  // MARK: connection

  /// Connect, open the project of `folder`, then show `main` (a path in the project; nil: the project's main .tex).
  /// The file on disk shows at once, read-only, while the engine catches up: project.open, then the project's
  /// subscription, status, threads and the doc in parallel. An empty folder fills here: project.open clones it.
  public func start(main: String?) async throws {
    if let main { showFromDisk(main) }
    wantedMain = main
    let c: JSONRPCConnection
    let r: [String: Any]
    do {
      c = try connect()
      r = try await c.call("project.open", ["folder": folder.path])
    } catch {
      // The engine isn't there (yet) or refused: keep trying; reconnect() opens the project and the main doc.
      conn?.close()
      connection = "offline"
      pushStatus()
      scheduleReconnect()
      throw error
    }
    projectID = r["project_id"] as? String
    me = r["me"] as? [String: Any] ?? [:]
    for d in r["docs"] as? [[String: Any]] ?? [] {
      if let p = d["path"] as? String, let id = d["doc_id"] as? String { docIDs[p] = id }
    }
    guard let pid = projectID else { throw EditorError("project.open gave no project_id") }
    // the project's files are on disk now: its main .tex, as the PDF pane finds it
    let path = main ?? TaudotPDFPane.findMain(in: folder).flatMap { docIDs[$0] != nil ? $0 : nil }
      ?? docIDs.keys.sorted().first { $0.hasSuffix(".tex") }
    async let known: Void = loadInstance()
    async let subscribed: Void = subscribeActivity(pid)
    async let status: Void = loadStatus(pid)
    async let threadsLoaded: Void = loadThreads()
    async let opened: Void = openMain(path)
    _ = await (known, subscribed, status, threadsLoaded)
    try await opened
    reviewChanged()
    drawOthers()
    startStatus()
  }

  private var instance: String?
  private var retry: TimeInterval = 0.25
  private var stopped = false
  private var reconnectTimer: Timer?
  /// The doc start() was asked to show, for a reconnect after a failed start.
  private var wantedMain: String?
  /// Opens in progress by path, and the path the user last asked for (A8: only that one is shown).
  private var opening: [String: Task<NativeDoc, Error>] = [:]
  private var wanted: String?

  private func connect() throws -> JSONRPCConnection {
    let c = try JSONRPCConnection(socket: socket.path)
    conn = c
    c.onNotification = { [weak self] m, p in self?.note(m, p) }
    c.onClose = { [weak self, weak c] in
      guard let self, self.conn === c else { return }
      self.connection = "offline"
      self.pushStatus()
      self.scheduleReconnect()
    }
    return c
  }

  /// The engine went (restarted, crashed): try again, backing off to 8 s, until it's back.
  private func scheduleReconnect() {
    guard !stopped, reconnectTimer == nil else { return }
    retry = min(retry * 2, 8)
    let t = Timer(timeInterval: retry, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.reconnectTimer = nil
        self?.reconnectNow()
      }
    }
    RunLoop.main.add(t, forMode: .common)
    reconnectTimer = t
  }

  private func reconnectNow() {
    Task { await reconnect() }
  }

  /// Connect again and reopen the project; every open doc re-opens and rebases its unsent edits on the engine's
  /// text (NativeDoc.rebase): a new engine's seqs start over, so nothing is sent at an old one.
  func reconnect() async {
    guard !stopped, conn?.closed ?? true else { return }
    connection = "connecting"
    pushStatus()
    var made: JSONRPCConnection?
    do {
      let c = try connect()
      made = c
      let info = try await c.call("engine.info", [:])
      let inst = info["instance"] as? String
      if let old = instance, let inst, old != inst { onError?("the engine restarted; merging your unsent edits") }
      instance = inst ?? instance
      let r = try await c.call("project.open", ["folder": folder.path])
      guard let pid = r["project_id"] as? String else { throw EditorError("project.open gave no project_id") }
      projectID = pid
      for d in r["docs"] as? [[String: Any]] ?? [] {
        if let p = d["path"] as? String, let id = d["doc_id"] as? String { docIDs[p] = id }
      }
      retry = 0.25
      await subscribeActivity(pid)
      await loadStatus(pid)
      for d in docs.values {
        d.reconnected(c, projectID: pid)
        await d.rebase()
      }
      await loadThreads()
      // After a failed start: what start() would have shown.
      if docs.isEmpty, let main = wantedMain ?? TaudotPDFPane.findMain(in: folder) { try? await open(path: main) }
      if statusTimer == nil { startStatus() }
      reviewChanged()
      drawOthers()
      pushStatus()
    } catch {
      // Whatever failed (connect, engine.info, project.open on a live socket), close this attempt and try again:
      // an open connection here would otherwise leave the editor offline for good.
      if let made, conn === made { made.close() }
      connection = "offline"
      pushStatus()
      scheduleReconnect()
    }
  }

  /// Stop reconnecting (the window closes).
  public func stop() {
    stopped = true
    reconnectTimer?.invalidate()
    reconnectTimer = nil
    statusTimer?.invalidate()
    statusTimer = nil
    presenceTimer?.invalidate()
    presenceTimer = nil
    for t in opening.values { t.cancel() }
    conn?.close()
    if let f = docFeed { for d in docs.values { d.onText = nil; f.released(d.path) } }
  }

  private func loadInstance() async {
    if let info = try? await conn?.call("engine.info", [:]) { instance = info["instance"] as? String }
  }

  private func subscribeActivity(_ pid: String) async {
    _ = try? await conn?.call("activity.subscribe", ["project_id": pid])
  }

  private func openMain(_ path: String?) async throws {
    if let path { try await open(path: path) }
  }

  private func loadStatus(_ pid: String) async {
    guard let c = conn, let st = try? await c.call("project.status", ["project_id": pid]) else { return }
    connection = st["connection"] as? String ?? "online"
    users = st["users"] as? [[String: Any]] ?? []
    track = st["track_changes"] as? Bool ?? false
  }

  /// The file as it is on disk, read-only until the engine's doc replaces it (the same text, mostly: the view then
  /// keeps its caret and scroll).
  private func showFromDisk(_ path: String) {
    guard doc == nil, let text = try? String(contentsOf: folder.appendingPathComponent(path), encoding: .utf8) else { return }
    if buffers[path] == nil { buffers[path] = buffers.count + 1 }
    current = path
    view.show(NativeDoc(docID: "", path: path, text: text, seq: 0, conn: nil), buffer: buffers[path]!)
    view.textView.isEditable = false
  }

  func loadThreads() async {
    guard let c = conn, let pid = projectID, let r = try? await c.call("thread.list", ["project_id": pid]) else { return }
    threadsSupported = r["supported"] as? Bool ?? false
    for t in r["threads"] as? [[String: Any]] ?? [] {
      if let id = t["thread_id"] as? String { threads[id] = t }
    }
  }

  /// Open a doc (path relative to the project, or absolute inside the folder) and show it.
  public func open(path p: String) async throws {
    let path = relative(p)
    wanted = path
    if let d = docs[path] { show(d); return }
    // One doc.open per path at a time; whichever open finishes, only the path asked for last is shown.
    let task = opening[path] ?? Task { try await self.load(path) }
    opening[path] = task
    defer { if opening[path] == task { opening[path] = nil } }
    let d = try await task.value
    if wanted == path { show(d) }
  }

  private func load(_ path: String) async throws -> NativeDoc {
    guard let c = conn, let pid = projectID else { throw EditorError("not connected") }
    let r = try await c.call("doc.open", ["project_id": pid, "path": path])
    guard let id = r["doc_id"] as? String, let text = r["text"] as? String, let seq = r["seq"] as? Int else {
      throw EditorError("doc.open \(path): bad result")
    }
    let d = NativeDoc(docID: id, path: path, text: text, seq: seq, conn: c)
    d.editable = r["editable"] as? Bool ?? true
    docs[path] = d
    d.onRanges = { [weak self, weak d] in if let d, self?.current == d.path { self?.reviewChanged() } }
    d.onState = { [weak self] in self?.pushStatus() }
    d.onResync = { [weak self, weak d] in if let d { self?.resync(d) } }
    d.projectID = pid
    d.onError = { [weak self] m in self?.onError?(m); self?.pushStatus() }
    feed(d)
    _ = try await c.call("doc.subscribe", ["doc_id": id, "since_seq": seq])
    if let rr = try? await c.call("doc.ranges", ["doc_id": id]) {
      d.setRanges(rr["ranges"] as? [[String: Any]] ?? [], seq: rr["seq"] as? Int ?? seq)
    }
    return d
  }

  /// For checks and benches: show a doc made without the engine.
  func adopt(_ d: NativeDoc) {
    docs[d.path] = d
    feed(d)
    show(d)
  }

  // MARK: LaTeX errors

  /// The last typeset's errors and warnings, all files: the shown doc marks its own.
  public private(set) var issues: [EditorIssue] = []
  /// "Ask Claude to fix" on an issue: the issue and the prompt to prefill (the shell opens the Claude pane with it).
  public var onAskClaude: ((EditorIssue, String) -> Void)? {
    get { view.onAskClaude }
    set { view.onAskClaude = newValue }
  }

  /// Line `line` (1-based) of `path` as the editor has it now, when that file is the one shown; else nil.
  public func lineText(path: String, line: Int) -> String? {
    guard path == current, line >= 1, line <= view.starts16.count else { return nil }
    let s = view.textView.string as NSString
    let a = view.starts16[line - 1], b = line < view.starts16.count ? view.starts16[line] - 1 : s.length
    return s.substring(with: NSRange(location: a, length: b - a))
  }

  /// A typeset's errors and warnings (the shell decides when: after a run, not mid-line). Replaces the last list; an
  /// empty one clears the marks.
  public func setIssues(_ list: [EditorIssue]) {
    issues = list
    view.placeIssues(list.filter { $0.path == current })
  }

  private func show(_ d: NativeDoc) {
    if buffers[d.path] == nil { buffers[d.path] = buffers.count + 1 }
    current = d.path
    view.show(d, buffer: buffers[d.path]!)
    view.textView.isEditable = d.editable
    view.placeIssues(issues.filter { $0.path == d.path })
    reviewChanged()
    drawOthers()
    view.reportCursor(force: false)
  }

  /// The doc no longer matches the engine: reopen it, keeping what wasn't sent (NativeDoc.rebase).
  private func resync(_ d: NativeDoc) {
    Task { @MainActor in await d.rebase() }
  }

  func relative(_ p: String) -> String {
    let root = folder.resolvingSymlinksInPath().path + "/"
    let abs = URL(fileURLWithPath: p).resolvingSymlinksInPath().path
    if abs.hasPrefix(root) { return String(abs.dropFirst(root.count)) }
    if p.hasPrefix(folder.path + "/") { return String(p.dropFirst(folder.path.count + 1)) }
    return p
  }

  public var doc: NativeDoc? { current.flatMap { docs[$0] } }

  // MARK: notifications

  private func note(_ m: String, _ p: [String: Any]) {
    let docID = p["doc_id"] as? String
    let d = docID.flatMap { id in docs.values.first { $0.docID == id } }
    switch m {
    case "doc.changed": d?.changed(p)
    case "doc.state": d?.engineState(p)
    case "ranges.changed": d?.setRanges(p["ranges"] as? [[String: Any]] ?? [], seq: p["seq"] as? Int ?? 0)
    case "presence.changed":
      users = p["users"] as? [[String: Any]] ?? []
      drawOthers()
      pushStatus()
    case "thread.changed":
      if let id = p["thread_id"] as? String {
        if let t = p["thread"] as? [String: Any] { threads[id] = (threads[id] ?? [:]).merging(t) { $1 } } else { threads[id] = nil }
        reviewChanged()
      }
    case "review.track":
      track = p["on"] as? Bool ?? track
      pushStatus()
    case "project.connection":
      connection = p["connection"] as? String ?? connection
      pushStatus()
    case "engine.lagged":
      for d in docs.values { resync(d) }
    default: break
    }
  }

  // MARK: presence

  private func drawOthers() {
    guard let d = doc else { view.others = []; return }
    let mine = me["user_id"] as? String
    var out: [(String, String, NSColor, Int)] = []
    for u in users {
      guard u["doc_id"] as? String == d.docID, let pos = u["pos"] as? Int, let seq = u["seq"] as? Int,
            u["user_id"] as? String != mine || u["client_id"] == nil,
            let p = d.local(pos: pos, at: seq) else { continue }
      if u["user_id"] as? String == mine { continue }
      let name = u["name"] as? String ?? "?"
      out.append((name, u["initials"] as? String ?? String(name.prefix(1)), NativeEditor.color(u["user_id"] as? String ?? name), p))
    }
    view.others = out
  }

  private func selectionChanged() {
    pushCursor()
    presenceTimer?.invalidate()
    let t = Timer(timeInterval: 0.15, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, let d = self.doc, let c = self.conn, d.unconfirmed == 0 else { return }
        let pos = Utf.utf8(d.text, self.view.caret)
        Task { _ = try? await c.call("presence.cursor", ["doc_id": d.docID, "pos": pos, "seq": d.seq]) }
      }
    }
    RunLoop.main.add(t, forMode: .common)
    presenceTimer = t
  }

  // MARK: completion

  func complete(pos: Int, before: String) async -> CompletionResult? {
    guard let c = conn, let d = doc,
          let r = try? await c.call("complete.items", ["doc_id": d.docID, "pos": pos, "before": before]),
          let from = r["from"] as? Int, let to = r["to"] as? Int else { return nil }
    let items = (r["items"] as? [[String: Any]] ?? []).map {
      CompletionItem(label: $0["label"] as? String ?? "", kind: $0["kind"] as? String ?? "", detail: $0["detail"] as? String ?? "",
                     insert: $0["insert"] as? String ?? "", cursor: $0["cursor"] as? Int)
    }
    // Offsets are in our own text (we sent `before`): convert to UTF-16.
    return CompletionResult(from: Utf.utf16(d.text, from), to: Utf.utf16(d.text, to), context: r["context"] as? String, items: items)
  }

  // MARK: PDF sync

  private func cursorMoved(line: Int, col: Int, force: Bool) {
    guard let p = current, p.hasSuffix(".tex") else { return }
    bridge.emit("taudot_app_cursor", [.string(p), .int(Int64(line)), .bool(force), .int(Int64(col))])
  }

  /// The PDF's cursor dot: every move and key, with the line as it is now and when it was sent (the app's clock).
  private func caretMoved(line: Int, col: Int, text: String) {
    guard let p = current, p.hasSuffix(".tex") else { return }
    let first = pendingCaret == nil
    pendingCaret = [.string(p), .int(Int64(line)), .int(Int64(col)), .string(text), .float(CACurrentMediaTime())]
    guard first else { return }
    // The PDF's cursor dot (SyncTeX rows, the page's words, the source's lines: ~3 ms on a 36-page paper) waits until
    // this turn's frame is committed: a timer fires after the run loop's commit, so the glyph doesn't wait for the dot.
    // Moves in the same turn are coalesced; the last one is sent. (clients/mac/Tests/perf/README.md, the editor's tail)
    let t = Timer(timeInterval: 0, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, let c = self.pendingCaret else { return }
        self.pendingCaret = nil
        self.bridge.emit("taudot_app_caret", c)
      }
    }
    RunLoop.main.add(t, forMode: .common)
  }

  /// ⌘⌥J: the caret's line to the PDF, forced.
  public func forwardSearch() {
    guard let p = current else { return }
    let (l, c) = view.lineCol(view.caret)
    bridge.emit("taudot_app_cursor", [.string(p), .int(Int64(l + 1)), .bool(true), .int(Int64(c))])
  }

  /// Inverse search: open `path` at a 1-based line.
  public func jump(path: String, line: Int, col: Int?) async {
    let rel = relative(path)
    if rel != current { try? await open(path: rel) }
    view.jump(line: line, col: col)
  }

  // MARK: status

  /// The status is pushed when it changes (connection, users, track changes, a doc's state or error), not polled:
  /// a 0.4 s poll was the native editor's whole idle cost (2.5 wakeups/s, clients/mac/Tests/perf/README.md).
  private func startStatus() {
    statusLive = true
    pushStatus()
  }

  private var statusLive = false

  /// Coalesced: several changes in one turn push once, after it.
  private func statusChanged() {
    guard statusLive, statusTimer == nil else { return }
    let t = Timer(timeInterval: 0, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.statusTimer = nil; self?.pushStatus() }
    }
    RunLoop.main.add(t, forMode: .common)
    statusTimer = t
  }

  func pushStatus() {
    let mine = me["user_id"] as? String
    let names = users.filter { $0["user_id"] as? String != mine }.map { Value.string($0["name"] as? String ?? $0["initials"] as? String ?? "?") }
    let unconfirmed = docs.values.reduce(0) { $0 + $1.unconfirmed }
    var pairs: [(Value, Value)] = [
      (.string("connection"), .string(connection)), (.string("unconfirmed"), .int(Int64(unconfirmed))),
      (.string("users"), .array(names)), (.string("track"), .bool(track)),
    ]
    if let e = docs.values.compactMap({ d in d.error.map { "\(d.path): \($0)" } }).first { pairs.append((.string("error"), .string(e))) }
    let s = Value.map(pairs)
    if s != lastStatus {
      lastStatus = s
      bridge.emit("taudot_app_status", [s])
    }
  }

  // MARK: colours

  static let palette: [(NSColor, String)] = [
    (.systemBlue, ""), (.systemOrange, ""), (.systemGreen, ""), (.systemPurple, ""), (.systemPink, ""), (.systemTeal, ""), (.systemIndigo, ""),
  ]

  /// An author's colour, as the margin picks it (ReviewItem.authorColor).
  public static func color(_ key: String) -> NSColor {
    let h = key.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
    return palette[Int(h % UInt32(palette.count))].0
  }

  static func hex(_ c: NSColor) -> String {
    let s = c.usingColorSpace(.sRGB) ?? c
    return String(format: "#%02x%02x%02x", Int(s.redComponent * 255), Int(s.greenComponent * 255), Int(s.blueComponent * 255))
  }
}

extension NativeEditor {
  /// Replace `del` bytes at byte `pos` of the doc at `path` with `ins`, as if typed (undoable, sent as the user's
  /// edit): the app's Undo of an outside edit. Only the doc on screen; false otherwise.
  public func replace(path: String, pos: Int, del: Int, ins: String) -> Bool {
    guard let d = view.doc, d.path == path else { return false }
    return view.replaceBytes(pos: pos, del: del, ins: ins)
  }
}
