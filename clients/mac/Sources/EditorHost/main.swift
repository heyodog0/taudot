// EditorHost: the native editor in a window wired the way the app wires Neovim: the review sidebar (comments margin)
// on the left through ReviewController, the PDF pane on the right, SyncTeX both ways. For trying it and for checks.
//
//   swift run EditorHost FOLDER [--socket PATH] [--main main.tex] [--theme ID] [--shot FILE.png]
//                        [--check OUT.json --bob "node .../ce_bob.ts" --bob-cwd DIR --project ID]
//
// --check runs a scenario against the local Overleaf CE with Bob (Overleaf's own editor, tests/ce_bob.ts) on the
// other side, writes the results as JSON and quits (exit 1 if any failed). See clients/mac/Tests/editor_ce.sh.
import AppKit
import TaudotEditor
import TaudotPDF
import TaudotReview
import TaudotShared

// TEXSYNC_* variables (names before the rename) still work (Compat.swift).
Compat.envFallback()

var args = Array(CommandLine.arguments.dropFirst())
@MainActor func opt(_ name: String) -> String? {
  guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
  let v = args[i + 1]
  args.removeSubrange(i...i + 1)
  return v
}
let socketOpt = opt("--socket") ?? ProcessInfo.processInfo.environment["TAUDOT_SOCKET"]
  ?? Compat.engineSocket()
let mainOpt = opt("--main")
let themeOpt = opt("--theme")
let shotOpt = opt("--shot")
let checkOpt = opt("--check")
let bobOpt = opt("--bob")
let bobCwd = opt("--bob-cwd")
let projectOpt = opt("--project")
/// For the engine-restart step: a file holding the engine's pid, and a shell command that starts it again (and writes
/// its pid there).
let enginePidFile = opt("--engine-pidfile")
/// Checks run in the background (docs/developing.md, "Tests stay off the screen"): no Dock icon, no
/// activation, the window off every screen. TAUDOT_ONSCREEN=1 (opt-in) puts it on screen; so does a run without
/// --check (EditorHost as a manual tool).
let onScreen = ProcessInfo.processInfo.environment["TAUDOT_ONSCREEN"] != nil || CommandLine.arguments.firstIndex(of: "--check") == nil

/// A window macOS doesn't pull back onto a screen.
final class OffscreenWindow: NSWindow {
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
let engineCmd = opt("--engine-cmd")
guard let folderArg = args.first else {
  FileHandle.standardError.write("usage: EditorHost FOLDER [--socket PATH] [--check OUT.json ...]\n".data(using: .utf8)!)
  exit(2)
}
let folder = URL(fileURLWithPath: (folderArg as NSString).expandingTildeInPath).standardized

func log(_ s: String) { FileHandle.standardError.write("editorhost: \(s)\n".data(using: .utf8)!) }

@MainActor final class Host: NSObject, NSApplicationDelegate {
  var window: NSWindow!
  let split = NSSplitView()
  let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 280, height: 800))
  let pdf = TaudotPDFPane()
  var editor: NativeEditor!
  var review: ReviewController!
  /// PDF jumps asked for (path, line), for the check.
  var jumps: [(String, Int)] = []
  /// Cursor-dot notifications (path, line, byte column, line text), for the check.
  var carets: [(String, Int, Int, String)] = []

  func applicationDidFinishLaunching(_ n: Notification) {
    // off every screen unless on-screen is asked for: right of the rightmost one
    let right = NSScreen.screens.map(\.frame.maxX).max() ?? 0
    let rect = onScreen ? NSRect(x: 60, y: 60, width: 1500, height: 900) : NSRect(x: right + 4000, y: 0, width: 1500, height: 900)
    window = (onScreen ? NSWindow.self : OffscreenWindow.self).init(contentRect: rect, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
    window.title = "EditorHost — \(folder.lastPathComponent)"
    editor = NativeEditor(folder: folder, socket: URL(fileURLWithPath: socketOpt), frame: NSRect(x: 0, y: 0, width: 720, height: 900))
    if let id = themeOpt, let t = Theme.named(id) { var s = editor.view.style; s.theme = t; editor.view.apply(style: s) }
    split.isVertical = true
    split.dividerStyle = .thin
    split.frame = window.contentView!.bounds
    split.autoresizingMask = [.width, .height]
    for v in [sidebar, editor.view, pdf.view] as [NSView] { split.addArrangedSubview(v) }
    window.contentView!.addSubview(split)
    sidebar.tab = .comments
    sidebar.folder = folder
    sidebar.margin.geometry = editor.view
    sidebar.margin.editorOffset = 0
    editor.onError = { log($0) }
    wire()
    // Off screen: never ordered in (macOS pulls an ordered-in window back onto a screen); it lays out and draws into
    // bitmaps all the same.
    if !onScreen {}
    else if checkOpt != nil { window.orderBack(nil) }
    else { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    window.layoutIfNeeded()
    split.adjustSubviews()
    split.setPosition(280, ofDividerAt: 0)
    split.setPosition(rect.width - 560, ofDividerAt: 1)
    window.makeFirstResponder(editor.view.textView)
    Task { await start() }
  }

  /// As ProjectWindow.wire(), with the bridge in Neovim's place.
  func wire() {
    let b = editor.bridge
    review = ReviewController(nvim: b, sidebar: sidebar)
    review.onResult = { a, err in if let err { log("\(a.kind): \(err)") } }
    review.onStateApplied = { [weak self] st in
      guard let self, let path = st.file ?? st.path else { return }
      self.pdf.setComments(st.items.filter { $0.kind == .comment }.map { it in
        PDFComment(
          id: it.id, path: path, line: it.range.line + 1, column: it.range.col, endLine: it.range.endLine + 1,
          endColumn: it.range.endCol, quote: it.quote, author: it.author.name, color: it.color,
          firstMessage: it.messages.first?.text ?? "", replies: max(0, it.messages.count - 1), resolved: it.resolved)
      })
    }
    b.notify("taudot_app_cursor") { [weak self] a in
      guard let self, a.count >= 2, case let .string(path) = a[0], case let .int(line) = a[1] else { return }
      var col: Int?
      if a.count > 3, case let .int(c) = a[3] { col = Int(c) }
      self.jumps.append((path, Int(line)))
      self.pdf.jump(path: path, line: Int(line), column: col)
    }
    b.notify("taudot_app_caret") { [weak self] a in
      guard let self, a.count >= 4, case let .string(path) = a[0], case let .int(line) = a[1], case let .int(col) = a[2],
        case let .string(text) = a[3] else { return }
      var sent: Double?
      if a.count > 4, case let .float(t) = a[4] { sent = t }
      self.carets.append((path, Int(line), Int(col), text))
      self.pdf.showCaret(path: path, line: Int(line), column: Int(col), text: text, sentAt: sent)
    }
    b.notify("taudot_app_status") { a in log("status \(a)") }
    pdf.onStatus = { s in log("pdf: \(s)") }
    pdf.onInverseSearchWord = { [weak self] path, line, column in
      guard let self else { return }
      let abs = path.hasPrefix("/") ? path : folder.appendingPathComponent(path).path
      let col: Value = column.map { .int(Int64($0)) } ?? .null
      Task { _ = try? await b.execLua("require('taudot.preview').jump(...)", [.string(abs), .int(Int64(line)), col]) }
      self.window.makeFirstResponder(self.editor.view.textView)
    }
  }

  func start() async {
    do {
      try await editor.start(main: mainOpt)
      try await review.attach(channel: nil)
      let main = mainOpt ?? TaudotPDFPane.findMain(in: folder) ?? "main.tex"
      pdf.open(folder: folder, main: main, engineSocket: URL(fileURLWithPath: socketOpt))
    } catch {
      log("start failed: \(error)")
      if checkOpt != nil { exit(1) }
      return
    }
    if let out = checkOpt { await Check(self, out: out).run() }
    if let shot = shotOpt, checkOpt == nil {
      try? await Task.sleep(for: .seconds(3))
      Host.shot(window, to: shot)
    }
  }

  /// A PNG of the window: on screen, `screencapture` (its real pixels); off screen, the views drawn into a bitmap.
  static func shot(_ w: NSWindow, to path: String) {
    guard onScreen else {
      guard let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
      v.cacheDisplay(in: v.bounds, to: rep)
      try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
      return
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-o", "-l\(w.windowNumber)", path]
    try? p.run()
    p.waitUntilExit()
  }
}

/// Bob: tests/ce_bob.ts, one JSON command per line each way.
@MainActor final class Bob {
  let p = Process()
  let input = Pipe(), output = Pipe()
  var lines: [String] = []
  private let buf = LineBox()

  init(_ cmd: String, cwd: String?) throws {
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = cmd.split(separator: " ").map(String.init)
    if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    p.standardInput = input
    p.standardOutput = output
    let box = buf
    output.fileHandleForReading.readabilityHandler = { h in
      let d = h.availableData
      if !d.isEmpty { box.add(d) }
    }
    try p.run()
  }

  private var sent = 0
  private var stuck: String?

  /// Bob answers one command at a time, in order: reply n is for command n (counted, so a late reply is never taken
  /// for the next command's). After one timeout Bob is still busy with that command, so later asks fail at once
  /// instead of each waiting out its own timeout behind it.
  func ask(_ cmd: [String: Any], timeout: Double = 60) async -> [String: Any] {
    if let stuck { return ["ok": false, "error": "bob stuck on \(stuck)"] }
    let n = sent
    sent += 1
    var d = try! JSONSerialization.data(withJSONObject: cmd)
    d.append(0x0A)
    input.fileHandleForWriting.write(d)
    let deadline = Date().addingTimeInterval(timeout)
    while buf.count <= n && Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
    guard let l = buf.line(n) else {
      stuck = cmd["cmd"] as? String ?? "?"
      FileHandle.standardError.write(Data("editorhost: bob: no reply to \(stuck!) in \(Int(timeout))s\n".utf8))
      return ["ok": false, "error": "no reply"]
    }
    return (try? JSONSerialization.jsonObject(with: Data(l.utf8)) as? [String: Any]) ?? ["ok": false, "error": "bad reply \(l)"]
  }

  func close() { input.fileHandleForWriting.write(Data("{\"cmd\":\"close\"}\n".utf8)) }
}

final class LineBox: @unchecked Sendable {
  private let lock = NSLock()
  private var partial = Data()
  private var lines: [String] = []
  var count: Int { lock.withLock { lines.count } }
  func line(_ i: Int) -> String? { lock.withLock { i < lines.count ? lines[i] : nil } }
  func add(_ d: Data) {
    lock.withLock {
      partial.append(d)
      while let nl = partial.firstIndex(of: 0x0A) {
        lines.append(String(decoding: partial[partial.startIndex..<nl], as: UTF8.self))
        partial.removeSubrange(partial.startIndex...nl)
      }
    }
  }
}

@MainActor final class Check {
  let h: Host
  let out: String
  var results: [[String: Any]] = []
  init(_ h: Host, out: String) {
    self.h = h
    self.out = out
  }

  var ed: NativeEditor { h.editor }
  var tv: NSTextView { h.editor.view.textView }
  var text: String { tv.string }

  func record(_ name: String, _ ok: Bool, _ detail: Any = "") {
    log("\(ok ? "ok  " : "FAIL") \(name) \(detail)")
    results.append(["name": name, "ok": ok, "detail": "\(detail)"])
  }

  func until(_ seconds: Double, _ cond: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !cond() {
      if Date() > deadline { return false }
      try? await Task.sleep(for: .milliseconds(50))
    }
    return true
  }

  func type(_ s: String) async {
    for ch in s {
      tv.insertText(String(ch), replacementRange: tv.selectedRange())
      try? await Task.sleep(for: .milliseconds(15))
    }
  }

  /// Our edits acked by the engine, and the engine's acked by Overleaf.
  func settled() async -> Bool {
    guard await until(15, { (self.ed.doc?.unconfirmed ?? 1) == 0 }) else { return false }
    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline {
      if let c = ed.conn, let pid = ed.projectID, let st = try? await c.call("project.status", ["project_id": pid]),
         let docs = st["docs"] as? [[String: Any]], docs.allSatisfy({ ($0["unconfirmed"] as? Int ?? 0) == 0 }) { return true }
      try? await Task.sleep(for: .milliseconds(100))
    }
    return false
  }

  func diff(_ a: String, _ b: String) -> String {
    let x = Array(a), y = Array(b)
    var i = 0
    while i < min(x.count, y.count) && x[i] == y[i] { i += 1 }
    return "lengths \(x.count)/\(y.count), first difference at \(i): \(String(x[i..<min(x.count, i + 30)]).debugDescription) vs \(String(y[i..<min(y.count, i + 30)]).debugDescription)"
  }

  func run() async {
    defer { finish() }
    record("opens main.tex", ed.doc?.path == "main.tex", ed.doc?.path ?? "nil")
    guard let bobCmd = bobOpt, let project = projectOpt else { record("bob", false, "no --bob/--project"); return }
    let bob: Bob
    do { bob = try Bob(bobCmd, cwd: bobCwd) } catch { record("bob starts", false, error); return }
    defer { bob.close() }
    let o = await bob.ask(["cmd": "open", "project": project, "file": "main.tex"], timeout: 90)
    record("bob opens main.tex in Overleaf", o["ok"] as? Bool == true, o["error"] ?? "")

    // 1. Typing reaches Overleaf.
    let s = text as NSString
    let mt = s.range(of: "\\maketitle")
    tv.setSelectedRange(NSRange(location: NSMaxRange(mt), length: 0))
    let typed = "\nNative edit é😀, typed."
    await type(typed)
    let sent = await settled()
    var sv = await bob.ask(["cmd": "server"])
    let server = sv["text"] as? String ?? ""
    record("typed edit confirmed", sent, ed.doc?.unconfirmed ?? -1)
    let sent16 = NativeEditorView.bmp(typed)
    record("emoji typed as two U+FFFD, as Overleaf's editor does", text.contains(sent16), sent16.debugDescription)
    record("typed edit in Overleaf (Bob's browser)", (sv["browser"] as? String ?? "").contains(sent16), (sv["browser"] as? String ?? "").prefix(200).debugDescription)
    _ = server
    let caretBefore = tv.selectedRange().location

    // 2. Bob types in Overleaf: it shows here, the caret stays on its character.
    _ = await bob.ask(["cmd": "type", "pos": 0, "text": "Bob was here. "])
    let got = await until(10) { self.text.hasPrefix("Bob was here. ") }
    record("Bob's typing shows", got, text.prefix(40))
    let caret = tv.selectedRange().location
    record("caret kept its place", caret == caretBefore + ("Bob was here. " as NSString).length, "\(caretBefore) → \(caret)")

    // 3. Bob's comment: a tint in the text, a card in the margin.
    sv = await bob.ask(["cmd": "server"])
    let st = (sv["text"] as? String ?? "") as NSString
    // the seed's title (docker/seed/main.tex), whatever it says
    let tr = st.range(of: "(?<=\\\\title\\{)[^}]+", options: .regularExpression)
    let title = tr.location == NSNotFound ? "" : st.substring(with: tr)
    let q = title.isEmpty ? NSRange(location: 0, length: 1) : tr
    record("seed has a title to comment on", !title.isEmpty, title)
    _ = await bob.ask(["cmd": "comment", "pos": q.location, "len": q.length, "thread": "6a6b6c6d6e6f707172737475"])
    let card = await until(10) { self.h.sidebar.margin.state.items.contains { $0.kind == .comment && $0.quote == title } }
    record("comment card in the margin", card, h.sidebar.margin.state.items.map(\.quote))
    record("comment tinted in the text", !h.editor.view.tintRanges.isEmpty, h.editor.view.tintRanges)
    if let it = h.sidebar.margin.state.items.first {
      let line = (text as NSString).substring(with: (text as NSString).lineRange(for: NSRange(location: h.editor.view.location(line: it.range.line, col: 0), length: 0)))
      record("card on the comment's line", !title.isEmpty && line.contains(title), line.trimmingCharacters(in: .newlines))
    }

    // 4. Bob's cursor.
    _ = await bob.ask(["cmd": "cursor", "pos": 3])
    let cur = await until(10) { !self.h.editor.view.others.isEmpty }
    record("Bob's cursor shows", cur, h.editor.view.others.map(\.name))

    // 5. Completion from the engine.
    let end = (text as NSString).range(of: "\\end{document}").location
    tv.setSelectedRange(NSRange(location: end, length: 0))
    tv.insertText("\n", replacementRange: tv.selectedRange())
    tv.setSelectedRange(NSRange(location: end, length: 0))
    await type("\\cite{")
    let pop = await until(5) { (self.h.editor.view.popupLabels.count) > 0 }
    record("\\cite{ completes from refs.bib", pop, h.editor.view.popupLabels.prefix(5))
    tv.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
    for _ in 0..<6 { tv.doCommand(by: #selector(NSResponder.deleteBackward(_:))) }
    await type("\\sec")
    _ = await until(5) { !self.h.editor.view.popupLabels.isEmpty }
    tv.doCommand(by: #selector(NSResponder.insertTab(_:)))
    let after = (text as NSString).substring(with: (text as NSString).lineRange(for: NSRange(location: tv.selectedRange().location, length: 0)))
    record("Tab accepts \\section{} with the caret inside", after.hasPrefix("\\section{}") && (text as NSString).substring(with: NSRange(location: tv.selectedRange().location, length: 1)) == "}", after.trimmingCharacters(in: .newlines))
    await type("Native")
    tv.moveToEndOfLine(nil)
    tv.doCommand(by: #selector(NSResponder.insertNewline(_:)))

    // 6. \begin closes itself.
    await type("\\begin{itemize}")
    record("\\begin{itemize} closes", text.contains("\\begin{itemize}\n\\end{itemize}"))
    tv.doCommand(by: #selector(NSResponder.insertNewline(_:)))
    await type("\\item one")

    // 7. PDF sync both ways.
    let ln = h.editor.view.lineCol(tv.selectedRange().location).0 + 1
    h.jumps = []
    h.editor.forwardSearch()
    record("⌘⌥J asks the PDF for this line", h.jumps.last.map { $0.0 == "main.tex" && $0.1 == ln } ?? false, h.jumps.map { "\($0.0):\($0.1)" })
    // The cursor dot: each key and move reports the caret and its line; the dot lands on a typeset line.
    h.carets = []
    await type("!")
    let byKey = h.carets.last.map { $0.0 == "main.tex" && $0.1 == ln && $0.3.hasSuffix("\\item one!") } ?? false
    tv.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
    let typedAt = (text as NSString).range(of: "typed.")
    tv.setSelectedRange(NSRange(location: typedAt.location + 2, length: 0))
    let tl = h.editor.view.lineCol(typedAt.location)
    try? await Task.sleep(for: .milliseconds(30))  // (sent after the frame: NativeEditor.caretMoved)
    let byMove = h.carets.last.map { $0.1 == tl.0 + 1 && $0.2 == tl.1 + 2 && $0.3.hasSuffix("typed.") } ?? false
    record("each key and move sends taudot_app_caret", byKey && byMove, h.carets.suffix(3).map { "\($0.0):\($0.1):\($0.2) \($0.3)" })
    let dot = await until(20) { self.h.pdf.pane.caret != nil }
    record("the PDF draws the cursor dot", dot, h.pdf.pane.caret.map { "\($0)" } ?? "none")
    h.pdf.onInverseSearchWord?("sections/intro.tex", 2, nil)
    let inv = await until(10) { self.h.editor.current == "sections/intro.tex" }
    record("PDF double-click opens the file at the line", inv && h.editor.view.lineCol(tv.selectedRange().location).0 == 1,
           "\(h.editor.current ?? "-") line \(h.editor.view.lineCol(tv.selectedRange().location).0 + 1)")
    try? await Task.sleep(for: .seconds(1))
    try? await ed.open(path: "main.tex")

    // 8. Everything converged.
    _ = await settled()
    try? await Task.sleep(for: .seconds(1))
    sv = await bob.ask(["cmd": "server"])
    let native = ed.doc?.string ?? ""
    // joinDoc lines are UTF-8 packed one byte per character (docs/protocol.md): unpack.
    let raw = sv["text"] as? String ?? ""
    let server8 = raw.unicodeScalars.allSatisfy { $0.value < 256 } ? String(decoding: raw.unicodeScalars.map { UInt8($0.value) }, as: UTF8.self) : raw
    record("native text == Overleaf's", server8 == native, diff(native, server8))
    record("Overleaf's editor == native", (sv["browser"] as? String) == native, diff(native, sv["browser"] as? String ?? ""))

    // 9. Vim keys: edits made with Vim commands reach Overleaf.
    h.editor.view.vimEnabled = true
    h.window.makeFirstResponder(tv)
    func keys(_ s: String) {
      for k in VimKey.parse(s) {
        let codes: [String: UInt16] = ["<Esc>": 53, "<CR>": 36]
        let ch = ["<Esc>": "\u{1b}", "<CR>": "\r"][k.name] ?? k.name
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: h.window.windowNumber,
                                 context: nil, characters: ch, charactersIgnoringModifiers: ch, isARepeat: false, keyCode: codes[k.name] ?? 0)!
        tv.keyDown(with: e)
      }
    }
    keys("<Esc>gg/Alice<CR>ciwCarol<Esc>")
    keys("/\\\\maketitle<CR>oVim was here.<Esc>yyp")
    _ = await settled()
    try? await Task.sleep(for: .seconds(1))
    sv = await bob.ask(["cmd": "server"])
    let br = sv["browser"] as? String ?? ""
    record("Vim edits reach Overleaf", br.contains("Carol and Bob") && br.components(separatedBy: "Vim was here.").count == 3, br.prefix(260).debugDescription)
    record("Vim: native == Overleaf", br == ed.doc?.string, diff(ed.doc?.string ?? "", br))

    // 9b. Vim's review keys go through the engine: ]r to Bob's tracked insertion, ga accepts it; gx rejects another;
    // gC resolves the comment.
    sv = await bob.ask(["cmd": "server"])
    let stext = sv["text"] as? String ?? ""
    let mk = (stext as NSString).range(of: "\\maketitle")
    _ = await bob.ask(["cmd": "track_insert", "pos": NSMaxRange(mk), "text": " TRACKEDA", "tc": "aaaaaaaaaaaaaaaaa1"])
    let auth = (stext as NSString).range(of: "\\author")
    _ = await bob.ask(["cmd": "track_insert", "pos": auth.location, "text": "TRACKEDX ", "tc": "aaaaaaaaaaaaaaaaa2"])
    let both = await until(15) { (self.ed.doc?.ranges.filter { $0.kind == "tracked_insert" }.count ?? 0) >= 2 }
    record("vim review: Bob's tracked insertions arrive", both, ed.doc?.ranges.map { "\($0.kind) \($0.text)" } ?? [])
    // the comment or tracked change under the caret
    func here(_ comment: Bool) -> DocRange? {
      guard let d = ed.doc else { return nil }
      let pos = Utf.utf8(d.text, h.editor.view.caret)
      return d.ranges.first { ($0.kind == "comment") == comment && $0.start <= pos && pos <= max($0.end, $0.start) }
    }
    var reviewErrors: [String] = []
    h.editor.bridge.notify("taudot_review_done") { a in
      if case let .map(m)? = a.first, let e = m.first(where: { if case .string("error") = $0.0 { return true }; return false })?.1,
         case let .string(msg) = e { reviewErrors.append(msg) }
    }
    func cycle(to word: String, comment: Bool = false) async -> Bool {
      keys("<Esc>gg0")
      for _ in 0..<8 {
        keys("]r")
        try? await Task.sleep(for: .milliseconds(50))
        if let it = here(comment), comment || it.text.contains(word) { return true }
      }
      return false
    }
    let onA = await cycle(to: "TRACKEDA")
    keys("ga")
    var accepted = false
    for _ in 0..<20 {
      try? await Task.sleep(for: .milliseconds(500))
      sv = await bob.ask(["cmd": "server"])
      let changes = ((sv["ranges"] as? [String: Any])?["changes"] as? [[String: Any]]) ?? []
      if (sv["text"] as? String ?? "").contains(" TRACKEDA") && !changes.contains(where: { ($0["op"] as? [String: Any])?["i"] as? String == " TRACKEDA" }) {
        accepted = true
        break
      }
    }
    // (Overleaf CE has no route to accept tracked changes: there, the engine's error must show)
    let ceRefused = reviewErrors.contains { $0.contains("can't accept") }
    record("vim review: ]r then ga accepts (CE: says it can't)", onA && (accepted || ceRefused), "\(onA) \(accepted) \(reviewErrors)")
    let onX = await cycle(to: "TRACKEDX")
    keys("gx")
    var rejected = false
    for _ in 0..<20 {
      try? await Task.sleep(for: .milliseconds(500))
      sv = await bob.ask(["cmd": "server"])
      if !(sv["text"] as? String ?? "TRACKEDX").contains("TRACKEDX") { rejected = true; break }
    }
    record("vim review: gx rejects on Overleaf", onX && rejected, onX)
    let onC = await cycle(to: "", comment: true)
    keys("gC")
    let resolved = await until(15) { self.h.sidebar.margin.state.items.contains { $0.kind == .comment && $0.resolved } }
    record("vim review: gC resolves the comment", onC && resolved, h.sidebar.margin.state.items.map { "\($0.kind) \($0.resolved)" })
    _ = await settled()
    sv = await bob.ask(["cmd": "server"])
    record("vim review: native == Overleaf", (sv["browser"] as? String) == ed.doc?.string, diff(ed.doc?.string ?? "", sv["browser"] as? String ?? ""))

    // 10. Geometry for the margin.
    let vis = h.editor.view.visibleLines
    let ys = vis.prefix(6).compactMap { h.editor.view.y(ofLine: $0) }
    record("line tops increase", ys.count >= 2 && zip(ys, ys.dropFirst()).allSatisfy { $0 < $1 }, ys)
    if let shot = shotOpt {
      // Back to the comment so the card shows.
      if let it = h.sidebar.margin.state.items.first { h.review.send(.goto(it.id)) }
      if onScreen { h.window.orderFront(nil) }
      try? await Task.sleep(for: .seconds(4))
      Host.shot(h.window, to: shot)
      if onScreen { h.window.orderBack(nil) }
    }

    // 11. The engine restarts mid-typing.
    await engineRestart(bob)
  }

  /// 11. The engine killed (-9) while typing: an edit in flight, one typed while it's down, Bob's edit meanwhile, one
  /// typed while reconnecting. Overleaf ends with each once, equal to the view.
  func engineRestart(_ bob: Bob) async {
    guard let pf = enginePidFile, let cmd = engineCmd, let pid = Int32((try? String(contentsOfFile: pf, encoding: .utf8))?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") else { return }
    h.editor.view.vimEnabled = false
    guard let d = ed.doc else { record("restart: doc", false, ""); return }
    func addLine(_ s: String) {
      let at = (tv.string as NSString).range(of: "\\end{document}").location
      tv.setSelectedRange(NSRange(location: at, length: 0))
      tv.insertText(s + "\n", replacementRange: tv.selectedRange())
    }
    addLine("AAA on Overleaf before the restart")
    _ = await settled()
    var sv: [String: Any] = [:]
    for _ in 0..<20 {
      sv = await bob.ask(["cmd": "server"])
      if (sv["browser"] as? String ?? "").contains("AAA") { break }
      try? await Task.sleep(for: .milliseconds(500))
    }
    addLine("BBB just typed")
    try? await Task.sleep(for: .milliseconds(80))
    kill(pid, SIGKILL)
    record("restart: connection lost", await until(5) { self.ed.connection == "offline" }, ed.connection)
    addLine("CCC typed while the engine is down")
    _ = await bob.ask(["cmd": "type", "pos": 0, "text": "% REMOTE from Bob\n"])
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", cmd]
    try? p.run()
    addLine("DDD typed while reconnecting")
    let back = await until(60) { d.rebases >= 1 && d.unconfirmed == 0 && !d.rebasing && self.ed.connection == "online" }
    record("restart: reconnected and rebased", back, "rebases \(d.rebases), unconfirmed \(d.unconfirmed), \(ed.connection), error \(d.error ?? "-")")
    var br = ""
    for _ in 0..<40 {
      sv = await bob.ask(["cmd": "server"])
      br = sv["browser"] as? String ?? ""
      if br.contains("DDD") && br == d.string { break }
      try? await Task.sleep(for: .milliseconds(500))
    }
    let counts = ["AAA", "BBB", "CCC", "DDD", "REMOTE"].map { "\($0) \(br.components(separatedBy: $0).count - 1)" }
    record("restart: every edit once on Overleaf", counts.allSatisfy { $0.hasSuffix(" 1") }, counts)
    record("restart: native == Overleaf", br == d.string && br == tv.string, diff(d.string, br))
    record("restart: no error left", d.error == nil, d.error ?? "")
  }

  func finish() {
    let ok = results.allSatisfy { $0["ok"] as? Bool == true }
    if let d = try? JSONSerialization.data(withJSONObject: ["ok": ok, "results": results], options: [.prettyPrinted]) {
      try? d.write(to: URL(fileURLWithPath: out))
    }
    log(ok ? "all passed" : "FAILED")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(ok ? 0 : 1) }
  }
}

let app = NSApplication.shared
app.setActivationPolicy(onScreen ? .regular : .prohibited)
let host = MainActor.assumeIsolated { Host() }
app.delegate = host
app.run()
