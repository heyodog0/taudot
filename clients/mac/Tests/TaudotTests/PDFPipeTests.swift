// pdfpipe step 2: the PDF pane typesets the editor's own text (NativeDoc.onText → TaudotPDFPane.editorChanged), not
// the engine's echo. The typesetter's text must equal the editor's buffer after every step: local edits, remote ones
// transformed past ours in flight and pending, acks, out-of-order changes, rebases, a typesetter restart.
import Foundation
import Testing
@testable import TaudotEditor
@testable import TaudotPDF
import TaudotCursor
import QuartzCore
import AppKit

/// A typesetter that only keeps the texts it was given.
@MainActor final class TextTypesetter: Typesetter {
  var onPages: ((PagesEvent) -> Void)?
  var onError: ((String) -> Void)?
  var onLine: ((String) -> Void)?
  var onNote: ((String) -> Void)?
  var onRestart: (() -> Void)?
  var pageStyle = ""
  var restartCount = 0
  var sent = 0
  var hasGlyphs: Bool { false }
  var engineName: String { "text" }
  var texts: [String: [UInt8]] = [:]
  var opens = 0
  var bad = 0
  func start() {}
  func stop() {}
  func killForTest() {}
  func open(_ path: String, _ text: String) { sent += 1; opens += 1; texts[path] = Array(text.utf8) }
  func change(_ path: String, _ pos: Int, _ del: Int, _ ins: String) {
    sent += 1
    guard var b = texts[path], pos >= 0, del >= 0, pos + del <= b.count else { bad += 1; return }
    b.replaceSubrange(pos..<(pos + del), with: Array(ins.utf8))
    texts[path] = b
  }
  func rescan() {}
  func goal(_ page: Int) {}
  func synctex() async -> String? { nil }
  func glyphs(page: Int) async -> PageGlyphs? { nil }
  func render(page: Int, scale: Double, x: Int, y: Int, w: Int, h: Int) async -> TileImage? { nil }
}

/// The doc fed to a pane as NativeEditor feeds it.
@MainActor private func fed(_ d: NativeDoc) -> (TaudotPDFPane, TextTypesetter) {
  let p = TaudotPDFPane()
  let t = TextTypesetter()
  p.install(t, choice: .texpresso)
  p.editorHolds(d.path, text: d.string)
  d.onText = { edits in for e in edits { p.editorChanged(d.path, e.pos, e.del, e.ins) } }
  return (p, t)
}

/// A random edit of `text` (bytes), cut only between whole UTF-8 characters; sometimes multi-byte.
private func randomEdit(_ text: [UInt8], _ rng: inout SystemRandomNumberGenerator) -> Edit {
  let starts = (0...text.count).filter { $0 == text.count || text[$0] & 0xC0 != 0x80 }
  let a = starts.randomElement(using: &rng)!
  let b = starts.filter { $0 >= a && $0 <= a + 6 }.randomElement(using: &rng)!
  let ins = ["", "x", "é", "🙂", "ab\n", "\\emph{y}"].randomElement(using: &rng)!
  return Edit(pos: a, del: b - a, ins: ins)
}

@Test @MainActor func typesetterFollowsTheEditorThroughInterleavings() {
  var rng = SystemRandomNumberGenerator()
  for round in 0..<40 {
    let d = NativeDoc(docID: "d", path: "main.tex", text: "\\section{Intro}\nhello wörld\n", seq: 0, conn: nil)
    let (_, t) = fed(d)
    for step in 0..<120 {
      switch Int.random(in: 0..<10, using: &rng) {
      case 0..<4:  // the user types
        d.local(randomEdit(d.text, &rng))
      case 4..<7:  // a collaborator's edit, made on the engine's text at its seq (without ours in flight or pending)
        let e = randomEdit(d.base, &rng)
        d.changed(["seq": d.seq + 1, "edits": [["pos": e.pos, "del": e.del, "ins": e.ins]]])
      case 7:  // our pending edit goes out
        _ = d.takeSend()
      default:  // the engine confirms the one in flight
        if d.inflight != nil { d.ack(d.seq + 1) }
      }
      #expect(t.texts["main.tex"] == d.text, "round \(round) step \(step): typesetter \(String(decoding: t.texts["main.tex"] ?? [], as: UTF8.self).debugDescription) editor \(d.string.debugDescription)")
      if t.texts["main.tex"] != d.text { return }
    }
    #expect(t.bad == 0)
  }
}

@Test @MainActor func engineEchoOfAHeldDocIsIgnored() {
  let d = NativeDoc(docID: "d", path: "main.tex", text: "abc\n", seq: 0, conn: nil)
  let (p, t) = fed(d)
  d.local(Edit(pos: 3, del: 0, ins: "d"))
  // the feed's sink as the engine's stream would call it (its echo of our edit): dropped for a held doc
  p.feedChangeForTest("main.tex", 3, 0, "d")
  #expect(t.texts["main.tex"] == Array("abcd\n".utf8))
  // a doc no editor holds still follows the engine
  p.feedOpenForTest("other.tex", "x\n")
  p.feedChangeForTest("other.tex", 1, 0, "y")
  #expect(t.texts["other.tex"] == Array("xy\n".utf8))
}

@Test @MainActor func typesetterRestartGetsTheEditorsText() {
  let d = NativeDoc(docID: "d", path: "main.tex", text: "abc\n", seq: 0, conn: nil)
  let (p, _) = fed(d)
  d.local(Edit(pos: 0, del: 0, ins: "unsent "))
  let t2 = TextTypesetter()
  p.install(t2, choice: .texpresso)  // a restart or a switch of typesetter: the docs whole again
  #expect(t2.texts["main.tex"] == d.text)
  p.feedOpenForTest("main.tex", "abc\n")  // the feed's reopen after a restart: the engine's text, without ours
  #expect(t2.texts["main.tex"] == d.text)
  d.local(Edit(pos: 0, del: 1, ins: ""))
  #expect(t2.texts["main.tex"] == d.text)
}

@Test @MainActor func releasedDocFollowsTheEngineAgain() {
  let d = NativeDoc(docID: "d", path: "main.tex", text: "abc\n", seq: 0, conn: nil)
  let (p, t) = fed(d)
  p.editorReleased("main.tex")
  d.onText = nil
  p.feedOpenForTest("main.tex", "engine\n")
  #expect(t.texts["main.tex"] == Array("engine\n".utf8))
  p.feedChangeForTest("main.tex", 0, 0, ">")
  #expect(t.texts["main.tex"] == Array(">engine\n".utf8))
}

/// A rebase (reconnect to a new engine whose text has a collaborator's edit and lost nothing of ours): the typesetter
/// still has the editor's merged text.
@Test @MainActor func rebaseKeepsTypesetterOnTheEditorsText() async throws {
  let sock = "/tmp/tdpp-\(getpid()).sock"
  let eng = FakeEditorEngine(path: sock) { m, _, _ in
    switch m {
    case "doc.open": return .ok(["doc_id": "d2", "text": "THEIRS abc\n", "seq": 5])
    case "doc.ranges": return .ok(["ranges": [], "seq": 5])
    default: return .ok([:])
    }
  }
  eng.start()
  defer { eng.stop() }
  let c = try JSONRPCConnection(socket: sock)
  let d = NativeDoc(docID: "d", path: "main.tex", text: "abc\n", seq: 0, conn: c)
  d.projectID = "p"
  let (_, t) = fed(d)
  d.local(Edit(pos: 3, del: 0, ins: " mine"))
  await d.rebase()
  #expect(d.string == "THEIRS abc mine\n")
  #expect(t.texts["main.tex"] == d.text)
  c.close()
}

// ---- step 3: the PDF's main-thread work ----------------------------------------------------------------------------

/// A typesetter serving one finished PDF (its SyncTeX and glyphs), as LiveTex does.
@MainActor final class OnePDFTypesetter: Typesetter {
  var onPages: ((PagesEvent) -> Void)?
  var onError: ((String) -> Void)?
  var onLine: ((String) -> Void)?
  var onNote: ((String) -> Void)?
  var onRestart: (() -> Void)?
  var pageStyle = ""
  var restartCount = 0
  var sent = 0
  var hasGlyphs: Bool { true }
  var engineName: String { "pdf" }
  let pdf: LivePDF
  init(_ pdf: LivePDF) { self.pdf = pdf }
  func start() {}
  func stop() {}
  func killForTest() {}
  func open(_ path: String, _ text: String) {}
  func change(_ path: String, _ pos: Int, _ del: Int, _ ins: String) {}
  func rescan() {}
  func goal(_ page: Int) {}
  func synctex() async -> String? { pdf.synctex }
  func glyphs(page: Int) async -> PageGlyphs? {
    let pdf = self.pdf
    return await Task.detached { LiveDraw.glyphs(pdf, page: page).map(UncheckedBox.init) }.value?.v
  }
  func render(page: Int, scale: Double, x: Int, y: Int, w: Int, h: Int) async -> TileImage? {
    let pdf = self.pdf
    return await Task.detached { LiveDraw.render(pdf, page: page, scale: scale, x: x, y: y, w: w, h: h, style: "white").map(UncheckedBox.init) }.value?.v
  }
  func report() {
    let sizes = pdf.sizes.map { [Double($0.width), Double($0.height)] }
    onPages?(PagesEvent(["ev": "pages", "gen": 1, "n": sizes.count, "typeset": sizes.count, "done": true, "sizes": sizes,
                         "changed": Array(0..<sizes.count), "edit_us": 0, "applied": 0])!)
  }
}

/// The cursor dot's cost a key on a real paper: $PDFPIPE_PDF (a finished PDF with its .synctex beside it) and
/// $PDFPIPE_DIR (its project, main.tex), e.g. the PaperA copy typeset by the live driver. Off unless both are set.
@Test(.enabled(if: ProcessInfo.processInfo.environment["PDFPIPE_PDF"] != nil))
@MainActor func caretCostOnARealPaper() async throws {
  let env = ProcessInfo.processInfo.environment
  let pdfPath = env["PDFPIPE_PDF"]!, dir = URL(fileURLWithPath: env["PDFPIPE_DIR"]!)
  let stx = pdfPath.replacingOccurrences(of: ".pdf", with: ".synctex")
  let pdf = try #require(LivePDF(path: pdfPath, synctex: stx, log: nil, seq: 1, run: 1))
  let source = try String(contentsOf: dir.appendingPathComponent("main.tex"), encoding: .utf8)
  let lines = source.components(separatedBy: "\n")
  let p = TaudotPDFPane()
  p.folder = dir
  p.openedMainName = "main.tex"
  let t = OnePDFTypesetter(pdf)
  p.install(t, choice: .live(year: "2026"))
  p.editorHolds("main.tex", text: source)
  t.report()
  let line = Int(env["PDFPIPE_LINE"] ?? "177")!
  p.showCaret(path: "main.tex", line: line, column: 10, text: lines[line - 1])
  let deadline = Date().addingTimeInterval(10)
  while p.cursorMap == nil || p.glyphCache.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
  try await Task.sleep(for: .milliseconds(300))
  #expect(p.cursorMap != nil)
  var ms: [Double] = []
  let typing = env["PDFPIPE_TYPE"] != nil
  let lineStart = lines[0..<(line - 1)].reduce(0) { $0 + $1.utf8.count + 1 }
  var text = lines[line - 1]
  for k in 0..<200 {  // a cursor walking along the line, as typing moves it (and, typing, the line growing)
    var col = 5 + k % max(1, lines[line - 1].utf8.count - 10)
    if typing {
      col = 40 + k
      p.editorChanged("main.tex", lineStart + col - 1, 0, "x")
      var u = Array(text.utf8); u.insert(UInt8(ascii: "x"), at: col - 1); text = String(decoding: u, as: UTF8.self)
    }
    let t0 = CACurrentMediaTime()
    p.showCaret(path: "main.tex", line: line, column: col, text: text)
    ms.append((CACurrentMediaTime() - t0) * 1000)
  }
  ms.sort()
  print(String(format: "caret: p50 %.3f p95 %.3f max %.3f ms (%@)", ms[100], ms[190], ms[199], p.caretOutcomeCounts.description))
  #expect(ms[190] < 2.0, "p95 \(ms[190]) ms")
}

/// Scroll and zoom frame costs on a real paper ($PDFPIPE_PDF, as above), in an off-screen window: each step's time
/// from the content moving to the end of its run-loop turn (`scrollFrame` / `zoomFrame`).
@Test(.enabled(if: ProcessInfo.processInfo.environment["PDFPIPE_PDF"] != nil))
@MainActor func scrollAndZoomFramesOnARealPaper() async throws {
  let env = ProcessInfo.processInfo.environment
  let pdfPath = env["PDFPIPE_PDF"]!
  let pdf = try #require(LivePDF(path: pdfPath, synctex: nil, log: nil, seq: 1, run: 1))
  let p = TaudotPDFPane()
  let w = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 800, height: 1000), styleMask: [.borderless], backing: .buffered, defer: false)
  w.isReleasedWhenClosed = false
  defer { w.close() }
  p.view.frame = NSRect(x: 0, y: 0, width: 800, height: 1000)
  w.contentView = p.view
  let t = OnePDFTypesetter(pdf)
  p.install(t, choice: .live(year: "2026"))
  t.report()
  try await Task.sleep(for: .milliseconds(800))
  let clip = p.pane.scroll.contentView
  for k in 0..<240 {  // ~4 pages down at 60 px a step, then back
    var o = clip.bounds.origin
    o.y += k < 120 ? 60 : -60
    clip.scroll(to: o)
    p.pane.scroll.reflectScrolledClipView(clip)
    try await Task.sleep(for: .milliseconds(8))
  }
  for k in 0..<60 {  // pinch in, then out
    p.pane.scroll.setMagnification(p.pane.scroll.magnification * (k < 30 ? 1.02 : 1 / 1.02), centeredAt: NSPoint(x: 400, y: 500))
    try await Task.sleep(for: .milliseconds(8))
  }
  try await Task.sleep(for: .milliseconds(200))
  func q(_ v: [Int64], _ f: Double) -> Double { v.isEmpty ? -1 : Double(v.sorted()[min(v.count - 1, Int(f * Double(v.count)))]) / 1000 }
  let s = p.pane.frames.filter { !$0.zoom }.map(\.us), z = p.pane.frames.filter(\.zoom).map(\.us)
  print(String(format: "scrollFrame n %d p50 %.2f p95 %.2f max %.2f ms; zoomFrame n %d p50 %.2f p95 %.2f max %.2f ms",
               s.count, q(s, 0.5), q(s, 0.95), q(s, 1), z.count, q(z, 0.5), q(z, 0.95), q(z, 1)))
  #expect(s.count > 100 && z.count > 20)
}

/// The pane's share of a PDF event while typing (one page changed of 36), in an off-screen window.
@Test(.enabled(if: ProcessInfo.processInfo.environment["PDFPIPE_PDF"] != nil))
@MainActor func pagesEventCostOnARealPaper() async throws {
  let pdf = try #require(LivePDF(path: ProcessInfo.processInfo.environment["PDFPIPE_PDF"]!, synctex: nil, log: nil, seq: 1, run: 1))
  let p = TaudotPDFPane()
  let w = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 800, height: 1000), styleMask: [.borderless], backing: .buffered, defer: false)
  w.isReleasedWhenClosed = false
  defer { w.close() }
  p.view.frame = NSRect(x: 0, y: 0, width: 800, height: 1000)
  w.contentView = p.view
  let t = OnePDFTypesetter(pdf)
  p.install(t, choice: .live(year: "2026"))
  t.report()
  try await Task.sleep(for: .milliseconds(500))
  let sizes = pdf.sizes.map { [Double($0.width), Double($0.height)] }
  var ms: [Double] = []
  for k in 0..<100 {
    let e = PagesEvent(["ev": "pages", "gen": 2 + k, "n": sizes.count, "typeset": sizes.count, "done": false, "sizes": sizes,
                        "changed": [0], "edit_us": 70000, "applied": k + 1])!
    let t0 = CACurrentMediaTime()
    t.onPages?(e)
    ms.append((CACurrentMediaTime() - t0) * 1000)
    try await Task.sleep(for: .milliseconds(5))
  }
  ms.sort()
  print(String(format: "pagesEvent: p50 %.3f p95 %.3f max %.3f ms", ms[50], ms[95], ms[99]))
}
