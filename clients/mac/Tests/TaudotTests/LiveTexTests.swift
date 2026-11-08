import AppKit
import Foundation
import Testing
@testable import TaudotPDF
import TaudotNeovim
import TaudotCursor

// The live pdfTeX's app side (LiveTex.swift) against the fake driver (Tests/live/fake-live.py: stock pdfLaTeX from
// scratch), or the real one when built. Skipped when the 2026 stock engine or its TeX Live tree isn't built (LiveTexPaths.missing).

private func liveReady() -> Bool {
  LiveTexPaths.missing("2026") == nil  // the real driver when it is built, else the fake (TAUDOT_LIVE_DRIVER=fake forces it)
}

private func tempProject(_ text: String, files: [String: String] = [:]) throws -> URL {
  let fm = FileManager.default
  let dir = fm.temporaryDirectory.appendingPathComponent("live-test-\(UUID().uuidString.prefix(6))")
  try fm.createDirectory(at: dir, withIntermediateDirectories: true)
  try text.write(to: dir.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
  for (k, v) in files { try v.write(to: dir.appendingPathComponent(k), atomically: true, encoding: .utf8) }
  return dir
}

@MainActor private func waitFor(_ seconds: Double = 30, _ cond: () -> Bool) async throws {
  let end = Date().addingTimeInterval(seconds)
  while !cond() && Date() < end { try await Task.sleep(for: .milliseconds(20)) }
}

private let twoPages: String = {
  let para = (1...14).map { "Paragraph \($0). " + String(repeating: "Some words to fill the line. ", count: 12) }
  return "\\documentclass{article}\n\\usepackage{hyperref}\n\\begin{document}\n\\section{Intro}\\label{intro}\n"
    + para.joined(separator: "\n\n") + "\n\nSee Section~\\ref{intro}.\n\\end{document}\n"
}()

/// Pages, a render, an edit on page 2 that changes page 2 only, SyncTeX, glyphs, the log as TeXpresso's log lines.
@MainActor @Test func liveTexEndToEnd() async throws {
  guard liveReady() else { return }
  let dir = try tempProject(twoPages)
  defer { try? FileManager.default.removeItem(at: dir) }
  let t = LiveTex(main: dir.appendingPathComponent("main.tex"), year: "2026")
  var events: [PagesEvent] = []
  var lines: [String] = []
  t.onPages = { events.append($0) }
  t.onLine = { lines.append($0) }
  t.start()
  defer { t.stop() }
  try await waitFor { events.contains { $0.done } }
  let first = try #require(events.last)
  #expect(first.n == 2)
  #expect(abs(first.sizes[0].width - 612) < 1 && abs(first.sizes[0].height - 792) < 1)
  #expect(t.ready)

  // a tile: white paper with ink on it
  let img = try #require(await t.render(page: 0, scale: 2, x: 100, y: 100, w: 400, h: 300))
  #expect(img.width == 400 && img.height == 300)
  #expect(inkFraction(img) > 0.01)

  // the log reaches the issues list's buffer
  #expect(lines.contains("[\"truncate-lines\", \"log\", 0]"))
  #expect(lines.contains { $0.hasPrefix("[\"append-lines\", \"log\", ") && $0.contains("pdfTeX") })

  // glyphs: the words of page 1, in lines
  let g = try #require(await t.glyphs(page: 0))
  let words = g.glyphs.map(\.t).joined()
  #expect(words.contains("Paragraph1."))
  #expect(g.lines.count > 20)

  // an edit at the end: page 2 changes, page 1 doesn't
  events = []
  t.open("main.tex", twoPages)
  let at = twoPages.utf8.count - "\n\\end{document}\n".utf8.count
  t.change("main.tex", at, 0, " Added.")
  try await waitFor { events.contains { $0.done && $0.applied >= 2 } }
  let changed = Set(events.filter { $0.applied >= 2 }.flatMap(\.changed))
  #expect(changed == [1])
  #expect(t.pageText(1)?.contains("Added.") == true)

  let st = SyncTex(try #require(await t.synctex()))
  #expect(st.forward(file: "main.tex", line: 5)?.page == 0)
}

/// The pane on the live pdfTeX: a folder without the engine gets pdfTeX for a pdfLaTeX document, TeXpresso for a
/// fontspec one; the pages arrive; inverse search works on them.
@MainActor @Test func paneChoosesLiveTex() async throws {
  guard liveReady() else { return }
  let dir = try tempProject(twoPages)
  defer { try? FileManager.default.removeItem(at: dir) }
  let cache = dir.appendingPathExtension("cache")  // its own page cache, not a shared TAUDOT_PAGE_CACHE
  defer { try? FileManager.default.removeItem(at: cache) }
  let pane = TaudotPDFPane(cacheRoot: cache)
  pane.open(folder: dir, main: "main.tex", engineSocket: nil)
  defer { pane.close() }
  #expect(pane.engine == .live(year: "2026"))
  try await waitFor { pane.syncTex != nil }
  #expect(pane.pane.pageCount == 2)
  let hit = pane.inverse(page: 0, x: 200, y: 200)
  #expect(hit?.path.hasSuffix("main.tex") == true)
}

@Test func engineChoice() {
  let env: [String: String] = [:]
  #expect(EngineChoice.choose(compiler: "pdflatex", image: "texlive-full:2025.1", mainText: nil, setting: nil, env: env) == .live(year: "2025"))
  #expect(EngineChoice.choose(compiler: "pdflatex", image: "", mainText: nil, setting: nil, env: env) == .live(year: "2026"))
  #expect(EngineChoice.choose(compiler: "pdflatex", image: "texlive-full:2022.1", mainText: nil, setting: nil, env: env) == .live(year: "2024"))
  #expect(EngineChoice.choose(compiler: "xelatex", image: "texlive-full:2025.1", mainText: nil, setting: nil, env: env) == .texpresso)
  #expect(EngineChoice.choose(compiler: "lualatex", image: nil, mainText: nil, setting: nil, env: env) == .texpresso)
  #expect(EngineChoice.choose(compiler: "pdflatex", image: nil, mainText: nil, setting: "texpresso", env: env) == .texpresso)
  // no engine: the source decides
  let xe = "% !TEX program = xelatex\n\\documentclass{article}\n"
  #expect(EngineChoice.choose(compiler: nil, image: nil, mainText: xe, setting: nil, env: env) == .texpresso)
  let fs = "\\documentclass{article}\n\\usepackage{fontspec}\n\\begin{document}\n"
  #expect(EngineChoice.choose(compiler: nil, image: nil, mainText: fs, setting: nil, env: env) == .texpresso)
  let commented = "\\documentclass{article}\n% \\usepackage{fontspec}\n\\begin{document}\n\\usepackage{fontspec}"
  #expect(EngineChoice.choose(compiler: nil, image: nil, mainText: commented, setting: nil, env: env) == .live(year: "2026"))
  #expect(EngineChoice.choose(compiler: "xelatex", image: nil, mainText: nil, setting: nil, env: ["TAUDOT_ENGINE": "live"]) == .live(year: "2026"))
}

@Test func gzipInflates() throws {
  let text = String(repeating: "SyncTeX Version:1\nInput:1:./main.tex\n", count: 200)
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gz-\(UUID().uuidString.prefix(6))")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: dir) }
  let f = dir.appendingPathComponent("a.synctex")
  try text.write(to: f, atomically: true, encoding: .utf8)
  let p = Process()
  p.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
  p.arguments = ["-k", f.path]
  try p.run()
  p.waitUntilExit()
  #expect(LivePDF.readSynctex(f.path + ".gz") == text)
  #expect(LivePDF.readSynctex(f.path) == text)
}

/// Page styles leave figures alone: a page with a grey rule (ink) and an image; dark recolours the rule, not the image.
@Test func restyleKeepsFigures() throws {
  // a one-page PDF made with Core Graphics: a black bar, and a red image
  let data = NSMutableData()
  var box = CGRect(x: 0, y: 0, width: 200, height: 200)
  let ctx = try #require(CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil))
  ctx.beginPDFPage(nil)
  ctx.setFillColor(CGColor(gray: 0, alpha: 1))
  ctx.fill(CGRect(x: 10, y: 150, width: 100, height: 20))
  let px = [UInt8](repeating: 0, count: 16 * 16 * 4).enumerated().map { $0.offset % 4 == 0 ? UInt8(255) : $0.offset % 4 == 3 ? 255 : 0 }
  let img = CGImage(width: 16, height: 16, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 64,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                    provider: CGDataProvider(data: Data(px) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
  ctx.draw(img, in: CGRect(x: 50, y: 20, width: 80, height: 80))
  ctx.endPDFPage()
  ctx.closePDF()
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rs-\(UUID().uuidString.prefix(6))")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: dir) }
  let path = dir.appendingPathComponent("a.pdf").path
  try (data as Data).write(to: URL(fileURLWithPath: path))
  let pdf = try #require(LivePDF(path: path, synctex: nil, log: nil, seq: 1, run: 1))
  #expect(pdf.figureRects(0).count == 1)
  let t = try #require(LiveDraw.render(pdf, page: 0, scale: 1, x: 0, y: 0, w: 200, h: 200, style: "dark"))
  // y down: the bar at rows 30..50, the image at rows 100..180
  #expect(pixel(t, 50, 40) == (0xd6, 0xd8, 0xda))  // black ink → light ink
  #expect(pixel(t, 5, 5) == (0x1d, 0x1f, 0x21))  // paper → dark
  let red = pixel(t, 90, 140)
  #expect(red.0 > 200 && red.1 < 40 && red.2 < 40)  // the figure as it is
}

/// The fraction of a tile's pixels that aren't white.
func inkFraction(_ t: TileImage) -> Double {
  let s = t.surface
  s.lock(options: .readOnly, seed: nil)
  defer { s.unlock(options: .readOnly, seed: nil) }
  let b = s.baseAddress.assumingMemoryBound(to: UInt8.self)
  var ink = 0
  for y in 0..<t.height { for x in 0..<t.width where b[y * s.bytesPerRow + x * 4 + 1] < 200 { ink += 1 } }
  return Double(ink) / Double(t.width * t.height)
}

/// (r, g, b) at a pixel, rows from the top.
func pixel(_ t: TileImage, _ x: Int, _ y: Int) -> (Int, Int, Int) {
  let s = t.surface
  s.lock(options: .readOnly, seed: nil)
  defer { s.unlock(options: .readOnly, seed: nil) }
  let p = s.baseAddress.assumingMemoryBound(to: UInt8.self) + y * s.bytesPerRow + x * 4
  return (Int(p[2]), Int(p[1]), Int(p[0]))
}

/// Debugging aid: LIVE_DUMP=file.pdf:PAGE prints that page's words as the pane reads them (glyphs → words).
@Test func liveDumpWords() throws {
  guard let spec = ProcessInfo.processInfo.environment["LIVE_DUMP"] else { return }
  let parts = spec.split(separator: ":")
  let pdf = try #require(LivePDF(path: String(parts[0]), synctex: nil, log: nil, seq: 0, run: 0))
  let g = try #require(LiveDraw.glyphs(pdf, page: Int(parts[1]) ?? 0))
  let grep = ProcessInfo.processInfo.environment["LIVE_DUMP_GREP"]
  for w in g.words() where grep == nil || w.raw.contains(grep!) { print("WORD \(w.raw) \(w.rect)") }
}

/// XeLaTeX projects stay on TeXpresso: a fontspec document in a folder without the engine.
@MainActor @Test func paneKeepsXeLaTeXOnTeXpresso() throws {
  let dir = try tempProject("\\documentclass{article}\n\\usepackage{fontspec}\n\\begin{document}\nHi.\n\\end{document}\n")
  defer { try? FileManager.default.removeItem(at: dir) }
  let cache = dir.appendingPathExtension("cache")  // its own page cache, not a shared TAUDOT_PAGE_CACHE
  defer { try? FileManager.default.removeItem(at: cache) }
  let pane = TaudotPDFPane(cacheRoot: cache)
  pane.open(folder: dir, main: "main.tex", engineSocket: nil)
  defer { pane.close() }
  #expect(pane.engine == .texpresso)
  #expect(pane.txp is Txp)
}

/// "Ours equals Overleaf's", the first half: the pane's PDF is byte for byte a stock pdfLaTeX run of the same text
/// (latexmk's reruns included), dates pinned. Against the fake it checks the harness; with $TAUDOT_LIVE_DRIVER set to
/// the real driver it checks the live engine.
@MainActor @Test func livePDFEqualsStock() async throws {
  guard LiveTexPaths.missing("2026") == nil else { return }
  // dates pinned through LiveTex's own environment: a setenv would reach every test running beside this one
  var pinned = ProcessInfo.processInfo.environment
  pinned["SOURCE_DATE_EPOCH"] = "1700000000"
  pinned["FORCE_SOURCE_DATE"] = "1"
  let dir = try tempProject(twoPages)
  defer { try? FileManager.default.removeItem(at: dir) }
  let t = LiveTex(main: dir.appendingPathComponent("main.tex"), year: "2026", env: pinned)
  var done = 0
  t.onPages = { if $0.done { done += 1 } }
  t.start()
  defer { t.stop() }
  // "done" once the first compile has settled (latexmk's rerun for hyperref's .out and the \ref included)
  try await waitFor { done >= 1 }
  let ours = try #require(t.finalPDF)

  // stock: pdfLaTeX twice in a copy, as latexmk does here
  let ref = dir.appendingPathComponent("stock")
  try FileManager.default.createDirectory(at: ref, withIntermediateDirectories: true)
  try twoPages.write(to: ref.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
  // off the main actor: a blocking wait here would stall every main-actor test running beside this one
  var env = LiveTexPaths.environment("2026", base: pinned)
  env["TEXFORMATS"] = ".:\(LiveTexPaths.build("2026"))/fmt-stock"
  let exe = "\(LiveTexPaths.build("2026"))/stock/texk/web2c/pdflatex"
  try await Task.detached {
    for _ in 0..<2 {
      let p = Process()
      p.executableURL = URL(fileURLWithPath: exe)
      p.arguments = ["-fmt=pdflatex", "-interaction=batchmode", "-synctex=1", "main.tex"]
      p.currentDirectoryURL = ref
      p.environment = env
      p.standardOutput = FileHandle.nullDevice
      try p.run()
      p.waitUntilExit()
    }
  }.value
  let stock = try Data(contentsOf: ref.appendingPathComponent("main.pdf"))
  #expect(ours.count == stock.count)
  #expect(ours == stock)
}

/// Costs on a real PDF: LIVE_COST=file.pdf prints the load (bytes, CGPDFDocument, page digests), a page's glyphs, a
/// full page drawn at 2× and the same in dark.
@Test func liveCosts() throws {
  guard let path = ProcessInfo.processInfo.environment["LIVE_COST"] else { return }
  func ms(_ f: () -> Void) -> Double { let t = CFAbsoluteTimeGetCurrent(); f(); return (CFAbsoluteTimeGetCurrent() - t) * 1000 }
  var pdf: LivePDF?
  let load = (0..<5).map { _ in ms { pdf = LivePDF(path: path, synctex: nil, log: nil, seq: 0, run: 0) } }.min()!
  let p = try #require(pdf)
  let glyph = (0..<5).map { k in ms { _ = LiveDraw.glyphs(LivePDF(path: path, synctex: nil, log: nil, seq: 0, run: 0)!, page: k % p.pageCount) } }.sorted()[2]
  let s = p.sizes[0]
  var white: [Double] = [], dark: [Double] = []
  for k in 0..<min(8, p.pageCount) {
    white.append(ms { _ = LiveDraw.render(p, page: k, scale: 2, x: 0, y: 0, w: Int(s.width * 2), h: Int(s.height * 2), style: "white") })
    dark.append(ms { _ = LiveDraw.render(p, page: k, scale: 2, x: 0, y: 0, w: Int(s.width * 2), h: Int(s.height * 2), style: "dark") })
  }
  print(String(format: "COST pages %d load %.1f ms glyphs/page %.1f ms (median) render 2x white p50 %.1f max %.1f dark p50 %.1f max %.1f",
               p.pageCount, load, glyph, white.sorted()[white.count / 2], white.max()!, dark.sorted()[dark.count / 2], dark.max()!))
}

/// The issues list's input on pdfTeX: the pane's driver lines rebuild pdfTeX's log (an undefined reference, an
/// overfull box), and BibTeX's warnings come as the .blg.
@MainActor @Test func liveLogAndBibTeXIssues() async throws {
  guard LiveTexPaths.missing("2026") == nil else { return }
  let text = """
    \\documentclass{article}
    \\begin{document}
    See \\ref{nowhere} and \\cite{knuth84}.
    \\hbox to 2cm{An overfull box that is far too wide for two centimetres}
    \\bibliographystyle{plain}
    \\bibliography{refs}
    \\end{document}

    """
  let bib = "@book{knuth84, author = {Donald Knuth}, title = {The {\\TeX}book}, publisher = {}, year = 1984}\n"
  let dir = try tempProject(text, files: ["refs.bib": bib])
  defer { try? FileManager.default.removeItem(at: dir) }
  let cache = dir.appendingPathExtension("cache")  // its own page cache, not a shared TAUDOT_PAGE_CACHE
  defer { try? FileManager.default.removeItem(at: cache) }
  let pane = TaudotPDFPane(cacheRoot: cache)
  var log = TeXLogBuffer()
  var bib0: [BibTeXIssue] = []
  pane.onDriverLine = { log.apply(line: $0) }
  pane.onBibIssues = { bib0 = $0 }
  pane.open(folder: dir, main: "main.tex", engineSocket: nil)
  defer { pane.close() }
  try await waitFor { pane.lastPages?.done == true && !bib0.isEmpty }
  let all = log.lines.joined(separator: "\n")
  #expect(all.contains("Reference `nowhere' on page 1 undefined"))
  #expect(all.contains("Overfull \\hbox"))
  #expect(!all.contains("Citation `knuth84' on page 1 undefined"))  // BibTeX ran and the rerun found it
  #expect(bib0.contains { $0.message.contains("empty publisher") })
}

/// Offline at the first open: the driver's `error` reaches the status line, and the pane stays up.
@MainActor @Test func liveOfflineIsShown() async throws {
  guard LiveTexPaths.missing("2026") == nil else { return }
  var env = ProcessInfo.processInfo.environment
  env["TAUDOT_LIVE_DRIVER"] = "fake"
  env["FAKE_LIVE_FAIL"] = "offline"
  let dir = try tempProject(twoPages)
  defer { try? FileManager.default.removeItem(at: dir) }
  let t = LiveTex(main: dir.appendingPathComponent("main.tex"), year: "2026", env: env)
  var notes: [String] = []
  t.onNote = { notes.append($0) }
  t.start()
  defer { t.stop() }
  try await waitFor(10) { notes.contains { $0.hasPrefix("offline: ") } }
  #expect(notes.contains { $0.hasPrefix("offline: ") && $0.contains("article.cls") })
}
