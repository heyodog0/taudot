// Item 8: the PDF pane jittered while the user typed inside a long \item (universal pdfLaTeX: display pages, the
// paragraph preview, then finished pages). A typing burst in such an item, off screen, with every frame of the page
// in view composited from the pane's own layers (underlay, tiles, preview), so what the user sees can be compared
// frame to frame.
import AppKit
import CoreText
import CoreImage
import Foundation
import Testing
@testable import TaudotPDF

/// A list whose second item is one long paragraph, as the user's was: bold lead-in, percentages, `vs.\ `.
let jitterDoc: String = {
  var s = "\\documentclass{article}\n\\usepackage[margin=1in]{geometry}\n\\begin{document}\n\\section{Results}\n"
  s += (1...14).map { "Opening paragraph \($0). " + String(repeating: "The measurements were repeated on each sample. ", count: 7) }.joined(separator: "\n\n")
  s += "\n\n\\begin{itemize}\n"
  s += "  \\item \\textbf{First finding.} A short item about the baseline at 12\\% of the total.\n"
  s += "  \\item \\textbf{Main result.} Over the full run the treated group improved by 52\\% vs.\\ 31\\% for the controls, "
  s += String(repeating: "and the gap held across sites, seasons and operators (48\\% vs.\\ 29\\% at the smallest site), ", count: 4)
  s += "TYPEHERE which we take as the central result of this study.\n"
  s += "  \\item \\textbf{Third finding.} Costs fell by 7\\% overall.\n"
  s += "\\end{itemize}\n\n"
  s += (3...30).map { "Closing paragraph \($0). " + String(repeating: "Further work will extend the analysis to more sites. ", count: 8) }.joined(separator: "\n\n")
  s += "\n\\end{document}\n"
  return s
}()

/// What one frame of the page in view showed: its pixels (page points, grey) and what was on it.
struct JitterFrame {
  var t: Double
  var pixels: [UInt8]
  var what: String
}

@MainActor final class JitterRecorder {
  let pane: PDFPaneView
  let page: Int
  let w: Int, h: Int
  /// Pixels a point: the tiles' own scale, so each layer lands on whole pixels as on screen.
  let scale: Double
  var frames: [JitterFrame] = []
  var events: [String] = []
  private var last: String = ""
  private var timer: Timer?
  private let ci = CIContext()
  let t0 = CACurrentMediaTime()

  init(_ pane: PDFPaneView, page: Int) {
    self.pane = pane
    self.page = page
    scale = pane.pages[page].shown?.scale ?? pane.pixelScale
    w = Int((pane.pages[page].size.width * scale).rounded(.up))
    h = Int((pane.pages[page].size.height * scale).rounded(.up))
  }

  func start() {
    timer = Timer.scheduledTimer(withTimeInterval: 0.004, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.sample() } }
    RunLoop.main.add(timer!, forMode: .common)
  }
  func stop() { timer?.invalidate() }

  func note(_ s: String) { events.append(String(format: "%7.1f %@", (CACurrentMediaTime() - t0) * 1000, s)) }

  private func image(_ c: Any?) -> CGImage? {
    guard let c else { return nil }
    if CFGetTypeID(c as CFTypeRef) == CGImage.typeID { return (c as! CGImage) }
    guard let s = c as? IOSurface else { return nil }
    // (not cached: a freed surface's address comes back for another)
    let im = CIImage(ioSurface: s)
    return ci.createCGImage(im, from: im.extent)
  }

  /// The layers on the page now (contents identity and frame), the view's origin and the page's: a change is a frame.
  private func signature() -> String {
    let p = pane.pages[page]
    let b = pane.scroll.contentView.bounds
    var s = String(format: "view %.2f,%.2f page %.2f,%.2f |", b.minX, b.minY, p.origin.x, p.origin.y)
    for l in p.layer.sublayers ?? [] where !l.isHidden {
      let id = l.contents.map { String(UInt(bitPattern: ObjectIdentifier($0 as AnyObject).hashValue), radix: 36) } ?? "-"
      let dims = (l.contents as? IOSurface).map { "\($0.width)x\($0.height)" } ?? (l.contents != nil ? "img" : "")
      s += " \(id):\(dims)@" + String(format: "%.1f,%.1f,%.1f,%.1f", l.frame.minX, l.frame.minY, l.frame.width, l.frame.height)
    }
    return s
  }

  func sample() {
    let s = signature()
    guard s != last else { return }
    last = s
    let p = pane.pages[page]
    // composite at 1 px a point, y down like the page layer (the pane is flipped)
    var px = [UInt8](repeating: 255, count: w * h)
    px.withUnsafeMutableBytes { buf in
      guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
      ctx.interpolationQuality = .none
      ctx.translateBy(x: 0, y: CGFloat(h))
      ctx.scaleBy(x: scale, y: -scale)
      for l in p.layer.sublayers ?? [] where !l.isHidden {
        guard let img = image(l.contents) else { continue }
        // the image's rows run from its top (tile and preview surfaces are top-down)
        ctx.saveGState()
        ctx.translateBy(x: l.frame.minX, y: l.frame.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(origin: .zero, size: l.frame.size))
        ctx.restoreGState()
      }
    }
    let para = pane.paraShown.map { "para a\($0.applied) \($0.state)" } ?? "no para"
    frames.append(JitterFrame(t: (CACurrentMediaTime() - t0) * 1000, pixels: px,
                              what: "v\(p.ver) shown \(p.shown.map { "\($0.ver)" } ?? "-") \(para) | \(s)"))
  }

  /// Rows (page points) where two frames differ by more than a faint tone.
  func diffRows(_ a: [UInt8], _ b: [UInt8]) -> (rows: [Int], count: Int) {
    var rows: [Int] = [], n = 0
    for y in 0..<h {
      var hit = false
      for x in 0..<w where abs(Int(a[y * w + x]) - Int(b[y * w + x])) > 48 { n += 1; hit = true }
      if hit, rows.last != Int(Double(y) / scale) { rows.append(Int(Double(y) / scale)) }
    }
    return (rows, n)
  }

  func dump(_ dir: String) {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for (i, f) in frames.enumerated() {
      var px = f.pixels
      px.withUnsafeMutableBytes { buf in
        guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let img = ctx.makeImage() else { return }
        try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?
          .write(to: URL(fileURLWithPath: "\(dir)/f\(String(format: "%03d", i)).png"))
      }
    }
  }
}

func rowRanges(_ rows: [Int]) -> String {
  var out: [String] = [], start = -1, prev = -2
  for r in rows + [Int.max] {
    if r != prev + 1 { if start >= 0 { out.append(start == prev ? "\(start)" : "\(start)-\(prev)") }; start = r }
    prev = r
  }
  return out.joined(separator: ",")
}

/// Types `keys` into the item, one key every `gap` s, on the given engine, and records every frame of the item's page.
@MainActor func jitterRun(_ choice: EngineChoice?, keys: String = "and also more words ", gap: Double = 0.09) async throws -> JitterRecorder? {
  let fm = FileManager.default
  let dir = fm.temporaryDirectory.appendingPathComponent("jitter-\(UUID().uuidString.prefix(6))")
  try fm.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? fm.removeItem(at: dir) }
  try jitterDoc.write(to: dir.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
  let cache = dir.appendingPathExtension("cache")
  defer { try? fm.removeItem(at: cache) }
  let win = NSWindow(contentRect: NSRect(x: -12000, y: -12000, width: 640, height: 820), styleMask: [.titled], backing: .buffered, defer: false)
  win.isReleasedWhenClosed = false
  let pdf = TaudotPDFPane(cacheRoot: cache)
  pdf.pane.frame = win.contentView!.bounds
  win.contentView!.addSubview(pdf.pane)
  win.orderFront(nil)
  defer { win.close() }
  pdf.open(folder: dir, main: "main.tex", engineSocket: nil)
  defer { pdf.close() }
  if let choice { pdf.startTypesetter(choice) }
  try await waitForJ(90) { pdf.syncTex != nil && pdf.pane.settled }
  guard let t = pdf.txp, pdf.syncTex != nil else { print("jitter: engine \(String(describing: pdf.engine)) sync \(pdf.syncTex != nil) settled \(pdf.pane.settled) pages \(pdf.pane.pageCount)"); return nil }
  // the item in view, a third of the way down, as when typing in it
  let line = jitterDoc.components(separatedBy: "TYPEHERE")[0].components(separatedBy: "\n").count
  guard let row = pdf.syncTex?.rows(file: "main.tex", line: line)?.rows.first else { print("jitter: no row for line \(line)"); return nil }
  pdf.pane.scrollTo(page: row.page, y: row.rect.minY)
  t.goal(row.page)
  try await waitForJ(10) { pdf.pane.settled }
  let rec = JitterRecorder(pdf.pane, page: row.page)
  rec.note("item on page \(row.page) y \(Int(row.rect.minY)); view \(pdf.pane.clipView.bounds)")
  // chain onto the pane's handlers: the events, as they come
  if let lt = t as? LiveTex {
    let op = lt.onPages, oq = lt.onPara
    lt.onPages = { e in rec.note("pages gen \(e.gen) applied \(e.applied) n \(e.n) done \(e.done) display \(e.display) changed \(e.changed)"); op?(e) }
    lt.onPara = { o in rec.note("para a\(o.applied) \(o.state) \(o.why ?? "") page \(o.page) bounds \(Int(o.bounds.minY))-\(Int(o.bounds.maxY))"); oq?(o) }
  }
  t.open("main.tex", jitterDoc)
  try await Task.sleep(for: .milliseconds(1500))
  rec.start()
  var at = jitterDoc.utf8.count - (jitterDoc.components(separatedBy: "TYPEHERE").last ?? "").utf8.count - "TYPEHERE".utf8.count
  // (under load the exact page can beat a preview's render, which is then dropped: type on until previews have shown)
  let shows0 = pdf.pane.paraShows, want = choice == nil ? 6 : 0  // (the patched path sends no previews)
  for (i, ch) in Array(keys + String(repeating: keys, count: 3)).enumerated() where i < keys.count || pdf.pane.paraShows - shows0 < want {
    rec.note("key '\(ch)'")
    t.change("main.tex", at, 0, String(ch))
    at += String(ch).utf8.count
    try await Task.sleep(for: .milliseconds(Int(gap * 1000)))
  }
  try await Task.sleep(for: .milliseconds(2500))
  rec.stop()
  return rec
}

@MainActor func waitForJ(_ seconds: Double, _ cond: () -> Bool) async throws {
  let end = Date().addingTimeInterval(seconds)
  while !cond() && Date() < end { try await Task.sleep(for: .milliseconds(20)) }
}

/// The report (JITTER=1): every frame's change from the one before, and frames that went back to an earlier look.
/// `handoffs`: pixels that changed when an exact preview gave way to the page with its edit (nothing should).
@MainActor func jitterReport(_ rec: JitterRecorder, _ name: String) -> (backs: Int, handoffs: [Int]) {
  var lines = rec.events
  var backs = 0, handoffs: [Int] = []
  for i in 1..<max(1, rec.frames.count) {
    let (rows, n) = rec.diffRows(rec.frames[i - 1].pixels, rec.frames[i].pixels)
    var back = ""
    if i >= 2, n > 0, rec.diffRows(rec.frames[i - 2].pixels, rec.frames[i].pixels).count == 0 { back = " BACK"; backs += 1 }
    if rec.frames[i - 1].what.contains(" exact |"), rec.frames[i].what.contains("no para") { handoffs.append(n) }
    lines.append(String(format: "%7.1f frame %d: %d px rows %@%@  [%@]", rec.frames[i].t, i, n, rowRanges(rows), back, rec.frames[i].what))
  }
  if ProcessInfo.processInfo.environment["JITTER"] != nil {
    let out = (ProcessInfo.processInfo.environment["JITTER_OUT"] ?? NSTemporaryDirectory()) + "/jitter-\(name)"
    try? lines.sorted().joined(separator: "\n").write(toFile: out + ".txt", atomically: true, encoding: .utf8)
    if ProcessInfo.processInfo.environment["JITTER_DUMP"] != nil { rec.dump(out) }
    print("jitter report: \(out).txt")
  }
  return (backs, handoffs)
}

@MainActor @Test func typingInAListItemDoesNotJitter() async throws {
  guard UniversalPaths.missing(.pdflatex) == nil else { return }
  guard let rec = try await jitterRun(nil) else { Issue.record("no first compile"); return }
  let r = jitterReport(rec, "universal")
  #expect(r.backs == 0, "the page went back to an earlier look \(r.backs) times (a preview taken down before its page was up)")
  // the previews must have come, or nothing was tested; each one's page then changes (almost) nothing: the lines
  // were drawn where the page puts them (a list item's indent: tau-live put none back, 25 pt, ~27,000 px)
  #expect(r.handoffs.count >= 3, "only \(r.handoffs.count) exact previews were handed over")
  #expect(r.handoffs.allSatisfy { $0 <= 200 }, "pixels changed as exact previews gave way to their pages: \(r.handoffs)")
  // (the few pixels left are one column at a seam between two tiles, in this compositor)
  let places = Set(rec.frames.map { $0.what.components(separatedBy: " | ")[1] })
  #expect(places.count == 1, "the view or the page moved: \(places)")
}

@MainActor @Test func typingInAListItemDoesNotJitterPatched() async throws {
  guard LiveTexPaths.missing("2026") == nil else { return }
  guard let rec = try await jitterRun(.live(year: "2026")) else { Issue.record("no first compile"); return }
  let r = jitterReport(rec, "patched")
  #expect(r.backs == 0)
}

/// A one-page PDF drawing `text`.
private func jitterPDF(_ text: String, at url: URL) throws {
  var box = CGRect(x: 0, y: 0, width: 300, height: 200)
  let ctx = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
  ctx.beginPDFPage(nil)
  let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
  let s = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
  ctx.textPosition = CGPoint(x: 40, y: 100)
  CTLineDraw(CTLineCreateWithAttributedString(s), ctx)
  ctx.endPDFPage()
  ctx.closePDF()
}

/// PDFs that land after newer ones are dropped (item 8): tau-live's first-run finisher's PDF after the run's finished
/// one and `done` (seen: the older page went back up, and SyncTeX never installed), and a display page from an
/// earlier compile. A rerun's PDFs and the next compile's are shown.
@MainActor @Test func olderPDFsDontReplaceNewerOnes() async throws {
  let fm = FileManager.default
  let dir = fm.temporaryDirectory.appendingPathComponent("stale-\(UUID().uuidString.prefix(6))")
  try fm.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? fm.removeItem(at: dir) }
  for (n, s) in ["fin": "early", "run": "finished", "next": "next", "old": "older display"] {
    try jitterPDF(s, at: dir.appendingPathComponent("\(n).pdf"))
  }
  try "SyncTeX Version:1\nInput:1:./main.tex\n".write(to: dir.appendingPathComponent("s.synctex"), atomically: true, encoding: .utf8)
  try "Output written on main.pdf (1 page).\n".write(to: dir.appendingPathComponent("l.log"), atomically: true, encoding: .isoLatin1)
  try "\\documentclass{article}\n".write(to: dir.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
  let script = """
    import json, os, sys
    d = os.environ["STALE_DIR"]
    def out(m): print(json.dumps(m), flush=True)
    def pdf(seq, run, name, final, **k): out(dict(ev="pdf", seq=seq, run=run, applied=seq, pages=1, final=final, from_page=0,
        path=d + "/" + name + ".pdf", synctex=d + "/s.synctex", **k))
    out({"ev": "hello", "engine": "pdfTeX"})
    pdf(0, 1, "run", True, log=d + "/l.log")
    out({"ev": "done", "seq": 0, "runs": 1, "pages": 1, "code": 0, "path": d + "/run.pdf", "log": d + "/l.log"})
    pdf(0, 1, "fin", False)
    for line in sys.stdin:
        if json.loads(line)[0] == "change":
            pdf(1, 1, "next", True, log=d + "/l.log")
            pdf(0, 1, "old", False, display=True)
            out({"ev": "done", "seq": 1, "runs": 1, "pages": 1, "code": 0, "path": d + "/next.pdf", "log": d + "/l.log"})
    """
  let driver = dir.appendingPathComponent("stale-driver.py")
  try script.write(to: driver, atomically: true, encoding: .utf8)
  var env = ProcessInfo.processInfo.environment
  env["TAUDOT_LIVE_DRIVER"] = driver.path
  env["STALE_DIR"] = dir.path
  let t = LiveTex(main: dir.appendingPathComponent("main.tex"), year: "2026", env: env)
  var events: [PagesEvent] = []
  t.onPages = { events.append($0) }
  t.start()
  defer { t.stop() }
  try await waitForJ(20) { events.contains { $0.done } }
  try await Task.sleep(for: .milliseconds(500))  // the early PDF has come by now
  #expect(t.pageText(0)?.contains("finished") == true, "the early PDF replaced the finished page: \(t.pageText(0) ?? "-")")
  #expect(events.last?.done == true, "a report after `done` (SyncTeX waits for a quiet `done`)")
  events = []
  t.change("main.tex", 0, 0, "x")
  try await waitForJ(20) { events.contains { $0.done } }
  try await Task.sleep(for: .milliseconds(300))
  #expect(t.pageText(0)?.contains("next") == true, "an older display page went up: \(t.pageText(0) ?? "-")")
}
