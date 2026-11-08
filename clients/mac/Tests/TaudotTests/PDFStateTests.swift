// statefix (docs/state-machines.md, sm-pdf's items): the PDF pane's and History's async state, driven by fakes with
// controlled timing. All off screen.
import AppKit
import Foundation
import Testing
@testable import TaudotPDF
@testable import TaudotHistory
@testable import TaudotCursor

/// A typesetter whose reports and SyncTeX the test hands out: `synctex()` waits until `releaseSynctex()`.
@MainActor final class FakeTypesetter: Typesetter {
  var onPages: ((PagesEvent) -> Void)?
  var onError: ((String) -> Void)?
  var onLine: ((String) -> Void)?
  var onNote: ((String) -> Void)?
  var onRestart: (() -> Void)?
  var pageStyle = "white"
  var restartCount = 0
  var sent = 0
  var hasGlyphs = false
  var engineName = "fake"
  var started = false, stopped = false
  var synctexText: String?
  var synctexAsked = 0
  var gateSynctex = false
  private var waiting: [CheckedContinuation<Void, Never>] = []
  init(synctex: String?) { synctexText = synctex }
  func start() { started = true }
  func stop() { stopped = true }
  func killForTest() {}
  func open(_ path: String, _ text: String) { sent += 1 }
  func change(_ path: String, _ pos: Int, _ del: Int, _ ins: String) { sent += 1 }
  func rescan() {}
  func goal(_ page: Int) {}
  func synctex() async -> String? {
    synctexAsked += 1
    let text = synctexText  // as of the call: the run that had settled then
    if gateSynctex { await withCheckedContinuation { waiting.append($0) } }
    return text
  }
  func releaseSynctex() {
    gateSynctex = false
    let w = waiting
    waiting = []
    for c in w { c.resume() }
  }
  /// The page's glyphs (`hasGlyphs` must be set); `gateGlyphs` holds each read until `releaseGlyphs()`.
  var pageGlyphs: PageGlyphs?
  var gateGlyphs = false, glyphsAsked = 0
  private var glyphWaiting: [CheckedContinuation<Void, Never>] = []
  func glyphs(page: Int) async -> PageGlyphs? {
    glyphsAsked += 1
    if gateGlyphs { await withCheckedContinuation { glyphWaiting.append($0) } }
    return pageGlyphs
  }
  func releaseGlyphs() {
    gateGlyphs = false
    let w = glyphWaiting
    glyphWaiting = []
    for c in w { c.resume() }
  }
  /// Renders a white tile when set; `gateRender` holds each render until `releaseRenders()`.
  var renders = false, gateRender = false, rendersAsked = 0
  private var renderWaiting: [CheckedContinuation<Void, Never>] = []
  func render(page: Int, scale: Double, x: Int, y: Int, w: Int, h: Int) async -> TileImage? {
    guard renders else { return nil }
    rendersAsked += 1
    if gateRender { await withCheckedContinuation { renderWaiting.append($0) } }
    return makeImage(rgb: Data(repeating: 255, count: w * h * 3), w: w, h: h)
  }
  func releaseRenders() {
    gateRender = false
    let w = renderWaiting
    renderWaiting = []
    for c in w { c.resume() }
  }
  /// A finished run of `n` letter pages (`done: false`: a report on the way).
  func done(_ n: Int = 1, done: Bool = true, changed: [Int]? = nil) {
    onPages?(PagesEvent(["ev": "pages", "n": n, "done": done, "sizes": Array(repeating: [612.0, 792.0], count: n),
                         "changed": changed ?? Array(0..<n)])!)
  }
}

@MainActor func settle(_ seconds: Double = 20, _ cond: () -> Bool) async {
  let end = Date() + seconds
  while !cond() && Date() < end { try? await Task.sleep(nanoseconds: 5_000_000) }
}

@MainActor private func tempFolder(_ name: String) throws -> URL {
  let d = FileManager.default.temporaryDirectory.appendingPathComponent("statefix-\(name)-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
  try "\\documentclass{article}\n\\begin{document}\nx\n\nHello world here.\n\\end{document}\n".write(
    to: d.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
  return d
}

/// A version's pane the way openVersion sets it up, on a fake typesetter.
@MainActor private func openFakeVersion(_ p: TaudotPDFPane, _ folder: URL, _ t: FakeTypesetter) {
  p.close()
  p.folder = folder
  p.openedMainName = "main.tex"
  p.versionFolder = folder
  p.install(t, choice: .texpresso)
}

// P3: version A's SyncTeX (asked for after its run settled) arrives after the pane moved to version B. It must not
// become B's SyncTeX, place A's changes on B or replay A's pending jump there.
@Test @MainActor func closedVersionsLateSyncTexIsDropped() async throws {
  let a = try tempFolder("a"), b = try tempFolder("b")
  defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
  let p = TaudotPDFPane()
  let ta = FakeTypesetter(synctex: sample)
  ta.gateSynctex = true
  openFakeVersion(p, a, ta)
  p.jump(path: "main.tex", line: 5, column: nil)  // before SyncTeX: kept for later
  ta.done()
  await settle { ta.synctexAsked > 0 }
  // History picks version B while A's SyncTeX is on its way
  let tb = FakeTypesetter(synctex: nil)
  openFakeVersion(p, b, tb)
  ta.releaseSynctex()
  try? await Task.sleep(nanoseconds: 300_000_000)
  #expect(p.syncTex == nil)
  #expect(p.lastSynctexText == nil)
  #expect(p.pendingJump == nil)
  #expect(!p.changesPlaced)
}

// P2: a comment's hover card is a view of the pane (an NSPopover's window took the mouse from the pages: a flicker),
// shows the comment's new text after an update, and goes when the window stops being key.
@Test @MainActor func commentHoverCardFollowsUpdatesAndWindow() throws {
  let saved = UserDefaults.standard.object(forKey: NotesOverlay.shownKey)
  defer { UserDefaults.standard.set(saved, forKey: NotesOverlay.shownKey) }
  UserDefaults.standard.removeObject(forKey: NotesOverlay.shownKey)
  let view = PDFPaneView(frame: NSRect(x: 0, y: 0, width: 700, height: 400))
  let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 700, height: 400), styleMask: [.borderless], backing: .buffered, defer: true)
  window.isReleasedWhenClosed = false
  window.contentView = view
  defer { window.close() }
  view.setSizes([CGSize(width: 612, height: 792)])
  let line = CGRect(x: 72, y: 200, width: 400, height: 9)
  let note = PlacedNote(id: "a", page: 0, line: line, side: .right, slot: 0)
  view.notes.set([note], comments: [PDFComment(id: "a", path: "main.tex", line: 1, author: "Ana", firstMessage: "first")])
  view.hoverPages(at: try #require(view.notePoint("a")))
  #expect(view.noteCardShown == "a")
  #expect(view.notes.hoverCardInPane)
  let f = try #require(view.subviews.first { $0 is HoverCardView }?.frame)
  #expect(f.width >= 200 && f.height > 30 && f.height < 300 && view.bounds.contains(f), "card \(f)")
  #expect(window.contentView?.hitTest(NSPoint(x: f.midX, y: f.midY)).map { $0 is HoverCardView } != true)  // never takes the mouse
  // a reply arrives while the card is up
  view.notes.set([note], comments: [PDFComment(id: "a", path: "main.tex", line: 1, author: "Ana", firstMessage: "edited", replies: 1)])
  #expect(view.noteCardShown == "a")
  #expect(view.notes.hoverCardComment?.firstMessage == "edited" && view.notes.hoverCardComment?.replies == 1)
  // another app comes forward: the pages never see the mouse leave
  NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
  #expect(view.noteCardShown == nil)
}

// Coordinator request (from sm-app): the History pane forwards focus to its table a turn later; if focus moved on in
// that turn (⇧⌘H, then an issue jump to the editor), the table must not take it back.
@Test @MainActor func historyPaneDoesNotTakeFocusBack() async {
  let w = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
  w.isReleasedWhenClosed = false
  defer { w.close() }
  let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
  let pane = HistoryController(source: FakeHistorySource()).pane
  pane.frame = NSRect(x: 0, y: 0, width: 280, height: 600)
  let editor = NSTextView(frame: NSRect(x: 300, y: 0, width: 600, height: 600))
  root.addSubview(pane)
  root.addSubview(editor)
  w.contentView = root
  #expect(w.makeFirstResponder(pane))
  #expect(w.makeFirstResponder(editor))  // in the same turn
  try? await Task.sleep(nanoseconds: 50_000_000)
  #expect(w.firstResponder === editor)
  // alone, the pane still hands focus to its table
  #expect(w.makeFirstResponder(pane))
  try? await Task.sleep(nanoseconds: 50_000_000)
  #expect(w.firstResponder !== pane && w.firstResponder !== editor)
}

// P4: the project asks for a live pdfTeX year that isn't installed: TeXpresso runs instead, once, not again on every
// engine reconnect (project.open names the same typesetter each time).
@Test @MainActor func missingYearFallsBackOnce() throws {
  let a = try tempFolder("p4")
  defer { try? FileManager.default.removeItem(at: a) }
  let p = TaudotPDFPane()
  var made: [EngineChoice] = []
  p.makeTypesetter = { c in made.append(c); return FakeTypesetter(synctex: nil) }
  p.folder = a
  p.openedMainName = "main.tex"
  p.engineChosen(.live(year: "1999"))
  #expect(made == [.texpresso] && p.engine == .texpresso)
  p.engineChosen(.live(year: "1999"))  // a reconnect
  p.engineChosen(.live(year: "1999"))
  #expect(made == [.texpresso])
  p.engineChosen(.texpresso)  // Settings: TeXpresso for everything
  #expect(made == [.texpresso] && p.requested == .texpresso)  // it runs already
}

// P7: run 1's SyncTeX is slow to come; run 2 settles and its SyncTeX comes first. Run 1's must not replace it.
@Test @MainActor func olderSyncTexNeverReplacesNewer() async throws {
  let a = try tempFolder("p7")
  defer { try? FileManager.default.removeItem(at: a) }
  let p = TaudotPDFPane()
  let t = FakeTypesetter(synctex: sample)
  t.gateSynctex = true
  p.folder = a
  p.openedMainName = "main.tex"
  p.install(t, choice: .texpresso)
  t.done()
  await settle { t.synctexAsked == 1 }
  let newer = sample + "\n"
  t.synctexText = newer
  t.gateSynctex = false
  t.done()
  await settle { p.lastSynctexText == newer }
  #expect(p.lastSynctexText == newer)
  t.releaseSynctex()  // run 1's arrives late
  try? await Task.sleep(nanoseconds: 100_000_000)
  #expect(p.lastSynctexText == newer)
}

// P8: a page changes while the page cache is being saved (its render was asked for before the change). It must stay
// dirty, to be saved again, not be marked clean with the old image on disk.
@Test @MainActor func pageChangedDuringCacheSaveStaysDirty() async throws {
  let a = try tempFolder("p8")
  let root = a.appendingPathExtension("cache")
  defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: root) }
  let p = TaudotPDFPane(cacheRoot: root)
  let t = FakeTypesetter(synctex: nil)
  t.renders = true
  p.folder = a
  p.openedMainName = "main.tex"
  p.install(t, choice: .texpresso)
  t.done(1)
  #expect(p.cacheDirty == [0])
  t.gateRender = true
  let save = Task { await p.saveCache() }
  await settle { t.rendersAsked == 1 }
  t.done(1, done: false, changed: [0])  // typing: page 0 again
  t.releaseRenders()
  await save.value
  #expect(p.cacheDirty.contains(0))
}

// P8: a pane reused for another folder shows that folder's cached pages (its pages had been rendered for the last one,
// and a rendered page refuses a cached image).
@Test @MainActor func reusedPaneShowsTheCache() async throws {
  let a = try tempFolder("p8a"), b = try tempFolder("p8b")
  let root = a.appendingPathExtension("cache")
  defer { for d in [a, b, root] { try? FileManager.default.removeItem(at: d) } }
  let ctx = CGContext(data: nil, width: 61, height: 79, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
  PageCache.write(b, page: 0, image: ctx.makeImage()!, root: root)
  PageCache.write(b, index: .init(main: "main.tex", sizes: [[612, 792]], scales: [0.1], topPage: 0, topY: 0, saved: Date()), root: root)
  let p = TaudotPDFPane(cacheRoot: root)
  p.makeTypesetter = { _ in FakeTypesetter(synctex: nil) }
  p.open(folder: a, main: "main.tex", engineSocket: nil)
  (p.txp as? FakeTypesetter)?.done(1)
  p.pane.pages[0].underVer = p.pane.pages[0].ver  // drawn (as the pane does once its render is in)
  p.open(folder: b, main: "main.tex", engineSocket: nil)
  await settle { p.cachePagesShown > 0 }
  #expect(p.cachePagesShown == 1)
  #expect((p.pane.pages[0].under.contents as! CGImage?)?.width == 61)
  p.close()
}

/// An off-screen window holding a pane view of one letter page.
@MainActor private func paneInWindow() -> (PDFPaneView, NSWindow) {
  let v = PDFPaneView(frame: NSRect(x: 0, y: 0, width: 700, height: 900))
  let w = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 700, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
  w.isReleasedWhenClosed = false
  w.contentView = v
  return (v, w)
}

// P9: pages on screen and no typesetter (a closed version pane, before the first start): no render retries at 10 Hz.
@Test @MainActor func noTypesetterNoRenderRetries() async {
  let p = TaudotPDFPane()
  let w = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 700, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
  w.isReleasedWhenClosed = false
  defer { w.close() }
  p.pane.frame = NSRect(x: 0, y: 0, width: 700, height: 900)
  w.contentView = p.pane
  p.pane.setSizes([CGSize(width: 612, height: 792)])
  p.pane.refresh()
  try? await Task.sleep(nanoseconds: 700_000_000)
  #expect(p.pane.renderCount < 4, "\(p.pane.renderCount) renders")
}

// P9: renders that never answer (a hung typesetter) hold the render slots only for a while: the pane then asks again.
@Test @MainActor func hungRendersFreeTheirSlots() async {
  let (v, w) = paneInWindow()
  defer { w.close() }
  let saved = PDFPaneView.renderTimeout
  PDFPaneView.renderTimeout = 0.2
  defer { PDFPaneView.renderTimeout = saved }
  var calls = 0
  v.renderer = { _, _, _, _, _, _ in
    calls += 1
    try? await Task.sleep(nanoseconds: 3_000_000_000)
    return nil
  }
  v.setSizes([CGSize(width: 612, height: 792)])
  v.refresh()
  try? await Task.sleep(nanoseconds: 50_000_000)
  let first = calls
  #expect(first >= 1 && first <= v.maxInflight)
  try? await Task.sleep(nanoseconds: 600_000_000)
  #expect(calls > first, "slots still held: \(calls) calls")
}

// P9: a changed page whose tiles had been freed (scrolled far away and back) still reports when its new content shows;
// a zoom alone (same content) doesn't.
@Test @MainActor func changedPageReportsWhenShown() async {
  let (v, w) = paneInWindow()
  defer { w.close() }
  v.renderer = { _, _, _, _, w, h in makeImage(rgb: Data(repeating: 255, count: w * h * 3), w: w, h: h) }
  var shown: [Int] = []
  v.onPageShown = { shown.append($0) }
  v.setSizes([CGSize(width: 612, height: 792)])
  v.refresh()
  await settle { v.pages[0].shown != nil }
  #expect(shown.isEmpty)  // the first drawing isn't an edit
  // its tiles freed (as when far from the view), then an edit to it
  for l in v.pages[0].tiles.values { l.removeFromSuperlayer() }
  v.pages[0].tiles = [:]
  v.pages[0].shown = nil
  v.markChanged(0)
  await settle { !shown.isEmpty }
  #expect(shown == [0])
}

/// A fake engine on a Unix socket: answers project.open (one doc), doc.open and doc.subscribe, counts the calls, and
/// sends notifications when told to. One client at a time, on a thread of its own.
final class FakeEngine: @unchecked Sendable {
  let path: String
  private let l = NSLock()
  private var fd: Int32 = -1, client: Int32 = -1
  private var _calls: [String] = []
  var calls: [String] { l.lock(); defer { l.unlock() }; return _calls }
  /// Seconds each doc.open answer waits (a busy engine).
  var openDelay: Double = 0
  var text = "\\documentclass{article}\\begin{document}x\\end{document}\n"
  var seq = 3

  init() throws {
    path = FileManager.default.temporaryDirectory.appendingPathComponent("fe-\(UUID().uuidString.prefix(6)).sock").path
    fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { p in
      for (i, b) in path.utf8.enumerated() { p[i] = b }
    }
    let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    guard r == 0, listen(fd, 4) == 0 else { throw NSError(domain: "FakeEngine", code: Int(errno)) }
    Thread.detachNewThread { [self] in self.serve() }
  }

  private func serve() {
    while true {
      let c = accept(fd, nil, nil)
      if c < 0 { return }
      l.lock(); client = c; l.unlock()
      var buf = Data()
      var chunk = [UInt8](repeating: 0, count: 65536)
      while true {
        let n = read(c, &chunk, chunk.count)
        if n <= 0 { break }
        buf.append(contentsOf: chunk[0..<n])
        while let nl = buf.firstIndex(of: 0x0A) {
          let line = buf[buf.startIndex..<nl]
          buf.removeSubrange(buf.startIndex...nl)
          guard let m = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let id = m["id"] as? Int,
            let method = m["method"] as? String else { continue }
          l.lock(); _calls.append(method); let delay = openDelay; l.unlock()
          var result: [String: Any] = [:]
          switch method {
          case "project.open": result = ["project_id": "p", "docs": [["doc_id": "d", "path": "main.tex"]]]
          case "doc.open":
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            result = ["text": text, "seq": seq]
          default: break
          }
          send(["jsonrpc": "2.0", "id": id, "result": result])
        }
      }
      close(c)
    }
  }

  func send(_ m: [String: Any]) {
    guard var d = try? JSONSerialization.data(withJSONObject: m) else { return }
    d.append(0x0A)
    l.lock(); let c = client; l.unlock()
    _ = d.withUnsafeBytes { write(c, $0.baseAddress!, $0.count) }
  }

  /// The engine restarting: the client's connection drops; the socket still takes new ones.
  func dropClient() {
    l.lock(); let c = client; l.unlock()
    if c >= 0 { shutdown(c, SHUT_RDWR) }
  }

  func stop() {
    shutdown(fd, SHUT_RDWR)
    close(fd)
    l.lock(); let c = client; l.unlock()
    if c >= 0 { shutdown(c, SHUT_RDWR) }
    unlink(path)
  }
}

// P10: reopens asked for while one runs (a TeXpresso restart, engine.lagged, a change that didn't fit) make one more
// pass, not one each.
@Test @MainActor func reopensWhileOneRunsCoalesce() async throws {
  let e = try FakeEngine()
  defer { e.stop() }
  var opens: [String] = []
  let f = EngineFeed(socket: e.path, folder: URL(fileURLWithPath: "/tmp/p10"), sink: .init(open: { p, _ in opens.append(p) }, change: { _, _, _, _ in }))
  f.start()
  defer { f.stop() }
  await settle { opens.count == 1 }
  e.openDelay = 0.15
  let first = Task { try? await f.reopen() }
  await settle { e.calls.filter { $0 == "doc.open" }.count == 2 }  // running
  async let b: Void? = try? f.reopen()
  async let c: Void? = try? f.reopen()
  async let d: Void? = try? f.reopen()
  _ = await (b, c, d)
  await first.value
  try? await Task.sleep(nanoseconds: 200_000_000)
  #expect(e.calls.filter { $0 == "doc.open" }.count == 3, "\(e.calls)")  // the first, the running one, one more
}

// P10: a change already on its way when the feed stops (the pane closed or moved to another folder) is not handed on.
@Test @MainActor func noChangesAfterStop() async throws {
  let e = try FakeEngine()
  defer { e.stop() }
  var changes = 0
  let f = EngineFeed(socket: e.path, folder: URL(fileURLWithPath: "/tmp/p10"), sink: .init(open: { _, _ in }, change: { _, _, _, _ in changes += 1 }))
  f.start()
  await settle { e.calls.contains("doc.subscribe") }
  e.send(["jsonrpc": "2.0", "method": "doc.changed", "params": ["doc_id": "d", "seq": 4, "edits": [["pos": 0, "del": 0, "ins": "a"]]]])
  usleep(100_000)  // the main actor blocked: the change is read and queued for it
  f.stop()
  try? await Task.sleep(nanoseconds: 100_000_000)
  #expect(changes == 0)
}

// P11: Esc while the selected words are still being read: the late read must not bring the selection and pill back.
@Test @MainActor func escBeforeTheWordReadKeepsTheSelectionGone() async throws {
  let a = try tempFolder("p11")
  defer { try? FileManager.default.removeItem(at: a) }
  let p = TaudotPDFPane()
  let t = FakeTypesetter(synctex: nil)
  t.hasGlyphs = true
  func word(_ s: String, _ x: Double, _ w: Int) -> [PageGlyphs.Glyph] {
    s.enumerated().map { i, ch in PageGlyphs.Glyph(t: String(ch), b: [x + Double(i) * 6, 92, x + Double(i + 1) * 6, 102], l: 0, w: w) }
  }
  t.pageGlyphs = PageGlyphs(page: 0, glyphs: word("Hello", 80, 0) + word("world", 116, 1) + word("here.", 152, 2))
  t.gateGlyphs = true
  p.folder = a
  p.openedMainName = "main.tex"
  p.install(t, choice: .texpresso)
  p.pane.setSizes([CGSize(width: 612, height: 792)])
  p.synctex = SyncTex(sample)
  p.select(page: 0, from: CGPoint(x: 82, y: 97), to: CGPoint(x: 140, y: 97), done: true)
  #expect(!p.pane.selection.isEmpty)  // the provisional highlight
  await settle { t.glyphsAsked > 0 }
  p.pane.selection.clear()  // Esc
  t.releaseGlyphs()
  try? await Task.sleep(nanoseconds: 100_000_000)
  #expect(p.pane.selection.isEmpty && p.pane.selection.pill == nil)
}

/// A pane on the fake with SyncTeX and a cursor map (no glyphs read yet), for the cursor dot.
@MainActor private func paneWithCursorMap(_ folder: URL, _ t: FakeTypesetter) -> TaudotPDFPane {
  let p = TaudotPDFPane()
  t.hasGlyphs = true
  p.folder = folder
  p.openedMainName = "main.tex"
  p.install(t, choice: .texpresso)
  t.done(1)
  p.synctex = SyncTex(sample)
  p.cursorMap = CursorMap(synctex: TaudotCursor.SyncTeX(text: sample)) { _ in nil }
  return p
}

// P12: the cursor's page was read before (no letter found there for it), then the page changed: on the same line the
// dot's lookup must read the page again, not skip it for good.
@Test @MainActor func caretLooksUpAgainAfterThePageChanged() async throws {
  let a = try tempFolder("p12")
  defer { try? FileManager.default.removeItem(at: a) }
  let t = FakeTypesetter(synctex: nil)
  let p = paneWithCursorMap(a, t)
  p.glyphCache[0] = PageGlyphs(page: 0, glyphs: [])
  p.showCaret(path: "main.tex", line: 5, column: 2, text: "Hello world here.")
  #expect(t.glyphsAsked == 0)  // read already
  t.done(1, done: false, changed: [0])  // typing changed the page
  t.pageGlyphs = PageGlyphs(page: 0, glyphs: [])
  p.showCaret(path: "main.tex", line: 5, column: 3, text: "Hello world here.")
  await settle { t.glyphsAsked > 0 }
  #expect(t.glyphsAsked == 1)
}

// P12: a page whose glyphs can't be read (nil) is not asked for again and again while the cursor rests.
@Test @MainActor func caretDoesNotLoopOnUnreadablePage() async throws {
  let a = try tempFolder("p12b")
  defer { try? FileManager.default.removeItem(at: a) }
  let t = FakeTypesetter(synctex: nil)
  let p = paneWithCursorMap(a, t)
  p.showCaret(path: "main.tex", line: 5, column: 2, text: "Hello world here.")
  try? await Task.sleep(nanoseconds: 300_000_000)
  #expect(t.glyphsAsked <= 2, "\(t.glyphsAsked) reads")
}

// P13: a forward search's word read is overtaken by a mark clear (the cursor left the document): the search counts as
// done, not stuck at "looking" for good.
@Test @MainActor func forwardSearchDoneAfterAClear() async throws {
  let a = try tempFolder("p13")
  defer { try? FileManager.default.removeItem(at: a) }
  let t = FakeTypesetter(synctex: nil)
  let p = paneWithCursorMap(a, t)
  p.cursorMap = nil
  t.gateGlyphs = true
  p.jump(path: "main.tex", line: 5, column: 2)
  await settle { t.glyphsAsked > 0 }
  #expect(!p.forwardSearchDone)
  p.clearMark()
  t.releaseGlyphs()
  try? await Task.sleep(nanoseconds: 50_000_000)
  #expect(p.forwardSearchDone)
}

// P13: a cursor-follow jump asked for before SyncTeX is in is replayed as what it was, not as a deliberate one.
@Test @MainActor func pendingFollowJumpStaysAFollow() async throws {
  let a = try tempFolder("p13b")
  defer { try? FileManager.default.removeItem(at: a) }
  let p = TaudotPDFPane()
  let t = FakeTypesetter(synctex: sample)
  p.folder = a
  p.openedMainName = "main.tex"
  p.install(t, choice: .texpresso)
  p.jump(path: "main.tex", line: 5, column: nil, deliberate: false)  // what cursorMoved does in follow mode
  t.done(1)
  await settle { p.syncTex != nil && p.pendingJump == nil }
  #expect(p.syncTex != nil && p.pendingJump == nil)
  #expect(p.markFor == nil)  // a follow doesn't pin the highlight to its line
}

// P13: the dim timer of a mark shown in follow mode doesn't dim it after the mode is turned off.
@Test @MainActor func dimTimerGoesWithFollowMode() async {
  let m = ForwardMark()
  m.idleAfter = 0.1
  m.dimWhenIdle = true
  m.show(page: 0, words: [CGRect(x: 10, y: 10, width: 20, height: 10)], lines: [CGRect(x: 0, y: 10, width: 300, height: 10)],
         color: CGColor(gray: 0, alpha: 1), tint: MarkColor.Tint(dark: false))
  m.dimWhenIdle = false
  try? await Task.sleep(nanoseconds: 250_000_000)
  #expect(!m.dimmed)
}

// P14: the marks are placed again (a new range: cleared, then the same change back) while a change's card waits to
// show. The card shows on the next hover, and no stale card shows meanwhile.
@Test @MainActor func changeCardAfterTheMarksWerePlacedAgain() async throws {
  let (v, w) = paneInWindow()
  defer { w.close() }
  v.setSizes([CGSize(width: 612, height: 792)])
  let ov = v.changes
  let c = PDFChange(id: "main.tex#0", kind: .insert, path: "main.tex", line: 5, column: 0, endLine: 5, endColumn: 5, text: "Hello",
                    author: "Bob", color: .systemBlue, time: nil)
  let placed = PlacedChange(id: c.id, page: 0, rects: [CGRect(x: 80, y: 92, width: 30, height: 10)])
  ov.set([placed], changes: [c])
  let at = v.pagePoint(0, CGPoint(x: 90, y: 97))
  #expect(ov.hover(at) && ov.popoverShown == nil)  // waits
  ov.set([], changes: [])  // re-placed: gone for a moment
  try? await Task.sleep(for: ChangesOverlay.showDelay + .milliseconds(100))
  #expect(ov.popoverShown == nil)
  ov.set([placed], changes: [c])
  _ = ov.hover(at)
  try? await Task.sleep(for: ChangesOverlay.showDelay)
  for _ in 0..<40 where ov.popoverShown == nil { try? await Task.sleep(for: .milliseconds(50)) }  // slack under load
  #expect(ov.popoverShown == c.id)
}

// P15: the comments toggle in one window: every window's notes follow (hidden and dead together), none is left drawn
// but dead to clicks.
@Test @MainActor func commentsToggleReachesEveryWindow() throws {
  let d = try #require(UserDefaults(suiteName: "statefix-p15-\(UUID().uuidString)"))
  let (v1, w1) = paneInWindow(), (v2, w2) = paneInWindow()
  defer { w1.close(); w2.close() }
  let line = CGRect(x: 72, y: 200, width: 400, height: 9)
  var ticks: [Bool] = []
  for v in [v1, v2] {
    v.notes.defaults = d
    v.setSizes([CGSize(width: 612, height: 792)])
    v.notes.set([PlacedNote(id: "a", page: 0, line: line, side: .right, slot: 0)], comments: [PDFComment(id: "a", path: "main.tex", line: 1, author: "Ana")])
  }
  v2.notes.onShownChanged = { ticks.append($0) }
  v1.notes.shown = false
  #expect(!v2.notes.shown && v2.notes.markersHidden == [true])
  #expect(ticks == [false])  // its View menu tick follows too
  v1.notes.shown = true
  let pa = try #require(v2.notePoint("a"))
  #expect(v2.notes.markersHidden == [false] && v2.clickPages(at: pa))
}

// A21: a version that failed to load (the engine was away) is fetched again when the same range is shown again.
@Test @MainActor func historyPDFRetriesAFailedRange() async throws {
  let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("a21-\(UUID().uuidString.prefix(6))")
  let project = tmp.appendingPathComponent("project")
  try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: tmp) }
  let f = FakeHistorySource()
  let r = HistoryRange(fromV: 12, toV: 15)
  let files = [HistoryFile(path: "main.tex", op: .edited)]
  let p = HistoryPDFController(source: f, project: project, mainFile: "main.tex", cacheRoot: tmp.appendingPathComponent("cache"))
  var errors = 0
  p.onError = { _ in errors += 1 }
  p.show(r, files: files, head: nil)
  await settle { errors == 1 }
  let asked = f.calls.count
  p.show(r, files: files, head: nil)  // the same range again (History shown again)
  await settle { f.calls.count > asked }
  #expect(f.calls.count > asked, "\(f.calls)")
  p.close()
}

// P18: the engine's connection drops (a restart). Its last mirror writes may still come in as file events: the docs it
// serves stay "live" (their saves ignored) until a connect fails, not from the moment the connection drops.
@Test @MainActor func liveDocsKeptAcrossAReconnect() async throws {
  let e = try FakeEngine()
  defer { e.stop() }
  let f = EngineFeed(socket: e.path, folder: URL(fileURLWithPath: "/tmp/p18"), sink: .init(open: { _, _ in }, change: { _, _, _, _ in }))
  f.start()
  defer { f.stop() }
  await settle { f.liveDocs == ["main.tex"] }
  e.dropClient()
  try? await Task.sleep(nanoseconds: 200_000_000)
  #expect(f.liveDocs == ["main.tex"])
  await settle(20) { e.calls.filter { $0 == "project.open" }.count == 2 }  // back
  #expect(f.liveDocs == ["main.tex"])
  e.stop()  // gone for good: the next connect fails
  await settle(20) { f.liveDocs.isEmpty }
  #expect(f.liveDocs.isEmpty)
}

// P19 (not reproduced): a typesetter's "fetching"/"offline" note is replaced by the next run's status.
@Test @MainActor func fetchNoteReplacedByTheNextRun() throws {
  let a = try tempFolder("p19")
  defer { try? FileManager.default.removeItem(at: a) }
  let p = TaudotPDFPane()
  var status: [String] = []
  p.onStatus = { status.append($0) }
  let t = FakeTypesetter(synctex: nil)
  p.folder = a
  p.openedMainName = "main.tex"
  p.install(t, choice: .texpresso)
  t.onNote?("TeX Live 2026: fetching cmr10.tfm (1 files, 0.1 MB)")
  t.onNote?("offline: can't fetch cmr10.tfm")
  t.done(1)
  #expect(status.last?.hasPrefix("1 page") == true, "\(status)")
}

// PDFHost's featureWait (P20's list): the page cache's SyncTeX is up at open, before the run's; benches wait for the
// run's own (`syncTexFromRun`).
@Test @MainActor func cachedSyncTexIsNotTheRuns() async throws {
  let a = try tempFolder("host")
  let root = a.appendingPathExtension("cache")
  defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: root) }
  PageCache.write(a, synctex: sample, root: root)
  PageCache.write(a, index: .init(main: "main.tex", sizes: [[612, 792]], scales: [0.1], topPage: 0, topY: 0, saved: Date()), root: root)
  let p = TaudotPDFPane(cacheRoot: root)
  let t = FakeTypesetter(synctex: sample + "\n")
  p.makeTypesetter = { _ in t }
  p.open(folder: a, main: "main.tex", engineSocket: nil)
  await settle { p.syncTex != nil }
  #expect(p.syncTex != nil && !p.syncTexFromRun)  // the cache's
  t.done(1)
  await settle { p.syncTexFromRun }
  #expect(p.syncTexFromRun)
  p.close()
}
