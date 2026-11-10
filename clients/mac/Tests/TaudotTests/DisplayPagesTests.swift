import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import TaudotPDF

// tau-live's display pages (docs/live-protocol.md, "Display pages on tau-live"): a `pdf` event with `"display": true`
// shows its new page and leaves SyncTeX, the log's issues and the final PDF as they were; the finished event then
// replaces it. A scripted driver sends the events, with PDFs made here.

/// A PDF of one page per string, each drawing its string.
private func makePDF(_ pages: [String], at url: URL) throws {
  var box = CGRect(x: 0, y: 0, width: 300, height: 200)
  let ctx = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
  for text in pages {
    ctx.beginPDFPage(nil)
    let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
    let s = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
    ctx.textPosition = CGPoint(x: 40, y: 100)
    CTLineDraw(CTLineCreateWithAttributedString(s), ctx)
    ctx.endPDFPage()
  }
  ctx.closePDF()
}

/// The driver: `hello`, a finished compile (A: SyncTeX, a log with an error); on the first `change` a display page
/// (D: its page 0 new, its page 1 an old one); on `finish` the finished compile (B).
private let script = """
  import json, os, sys
  d = os.environ["DISPLAY_TEST_DIR"]
  def out(m): print(json.dumps(m), flush=True)
  out({"ev": "hello", "engine": "pdfTeX"})
  out({"ev": "pdf", "seq": 0, "run": 1, "applied": 0, "pages": 2, "final": True, "from_page": 0,
       "path": d + "/A.pdf", "synctex": d + "/A.synctex", "log": d + "/A.log"})
  out({"ev": "done", "seq": 0, "runs": 1, "pages": 2, "code": 1, "path": d + "/A.pdf", "log": d + "/A.log"})
  sent = 0
  for line in sys.stdin:
      cmd = json.loads(line)
      if cmd[0] == "change":
          sent += 1
          out({"ev": "pdf", "seq": 1, "run": 2, "applied": sent, "pages": 1, "final": False, "from_page": 0,
               "display": True, "path": d + "/D.pdf", "edit_us": 9000})
      elif cmd[0] == "finish":
          out({"ev": "pdf", "seq": 1, "run": 2, "applied": sent, "pages": 2, "final": True, "from_page": 0,
               "path": d + "/B.pdf", "synctex": d + "/B.synctex", "log": d + "/B.log"})
          out({"ev": "done", "seq": 1, "runs": 1, "pages": 2, "code": 0, "path": d + "/B.pdf", "log": d + "/B.log"})
  """

@MainActor private func waitFor(_ seconds: Double = 20, _ cond: () -> Bool) async throws {
  let end = Date().addingTimeInterval(seconds)
  while !cond() && Date() < end { try await Task.sleep(for: .milliseconds(10)) }
  #expect(cond())
}

@MainActor @Test func displayPageKeepsSyncTexAndIssues() async throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("display-\(UUID().uuidString.prefix(6))")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: dir) }
  try makePDF(["one", "two"], at: dir.appendingPathComponent("A.pdf"))
  try makePDF(["ONE", "stale"], at: dir.appendingPathComponent("D.pdf"))
  try makePDF(["ONE", "two"], at: dir.appendingPathComponent("B.pdf"))
  try "SyncTeX Version:1\nInput:1:./main.tex\nA\n".write(to: dir.appendingPathComponent("A.synctex"), atomically: true, encoding: .utf8)
  try "SyncTeX Version:1\nInput:1:./main.tex\nB\n".write(to: dir.appendingPathComponent("B.synctex"), atomically: true, encoding: .utf8)
  try "! Undefined control sequence.\nl.3 \\foo\n".write(to: dir.appendingPathComponent("A.log"), atomically: true, encoding: .isoLatin1)
  try "Output written on main.pdf (2 pages).\n".write(to: dir.appendingPathComponent("B.log"), atomically: true, encoding: .isoLatin1)
  try "\\documentclass{article}\n".write(to: dir.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
  let driver = dir.appendingPathComponent("display-driver.py")
  try script.write(to: driver, atomically: true, encoding: .utf8)

  var env = ProcessInfo.processInfo.environment
  env["TAUDOT_LIVE_DRIVER"] = driver.path
  env["DISPLAY_TEST_DIR"] = dir.path
  let t = LiveTex(main: dir.appendingPathComponent("main.tex"), year: "2026", env: env)
  var events: [PagesEvent] = [], errors: [String] = [], lines: [String] = []
  t.onPages = { events.append($0) }
  t.onError = { errors.append($0) }
  t.onLine = { lines.append($0) }
  t.start()
  defer { t.stop() }

  try await waitFor { events.contains { $0.done } }
  #expect(t.pageText(0)?.contains("one") == true)
  #expect(errors.count == 1 && errors[0].contains("Undefined control sequence"))
  let syncA = await t.synctex()
  #expect(syncA?.hasSuffix("A\n") == true)
  let finalA = t.finalPDF
  let linesA = lines.count

  // the display page: page 0 new, page 1 (old in its file) as shown; nothing else moves
  events = []
  t.change("main.tex", 0, 0, "x")
  try await waitFor { !events.isEmpty }
  let d = try #require(events.first)
  #expect(d.display && !d.done)
  #expect(d.changed == [0])
  #expect(d.sizes.count == 2)
  #expect(t.pageText(0)?.contains("ONE") == true)
  #expect(t.pageText(1)?.contains("two") == true)
  #expect(await t.synctex() == syncA)
  #expect(t.finalPDF == finalA)
  #expect(errors.count == 1 && lines.count == linesA)

  // the finished output replaces it, with its SyncTeX and log
  events = []
  t.finish()
  try await waitFor { events.contains { $0.done } }
  #expect(events.allSatisfy { !$0.display })
  #expect(t.pageText(0)?.contains("ONE") == true && t.pageText(1)?.contains("two") == true)
  #expect(await t.synctex()?.hasSuffix("B\n") == true)
  #expect(t.finalPDF != finalA)
  #expect(lines.count > linesA && lines.contains { $0.contains("Output written") })
  #expect(errors.count == 1)
}

/// A display event's PagesEvent carries the flag; others don't.
@Test func pagesEventDisplayFlag() throws {
  let d = try #require(PagesEvent(["ev": "pages", "n": 1, "display": true]))
  #expect(d.display)
  let f = try #require(PagesEvent(["ev": "pages", "n": 1]))
  #expect(!f.display)
}
