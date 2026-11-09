import AppKit
import CoreImage
import Foundation
import Testing
@testable import TaudotPDF

// Universal (tau-live, stock engines) through LiveTex: XeLaTeX and LuaLaTeX projects typeset live, BibTeX reruns,
// edits reach the pages. Skipped when universal's build isn't there (UniversalPaths.missing).

private func project(_ text: String, files: [String: String] = [:]) throws -> URL {
  let fm = FileManager.default
  let dir = fm.temporaryDirectory.appendingPathComponent("uni-test-\(UUID().uuidString.prefix(6))")
  try fm.createDirectory(at: dir, withIntermediateDirectories: true)
  try text.write(to: dir.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
  for (k, v) in files { try v.write(to: dir.appendingPathComponent(k), atomically: true, encoding: .utf8) }
  return dir
}

@MainActor private func waitFor(_ seconds: Double = 60, _ cond: () -> Bool) async throws {
  let end = Date().addingTimeInterval(seconds)
  while !cond() && Date() < end { try await Task.sleep(for: .milliseconds(20)) }
}

private let paper: String = {
  let para = (1...12).map { "Paragraph \($0). " + String(repeating: "Some words to fill the line. ", count: 12) }
  return "\\documentclass{article}\n\\usepackage{fontspec}\n\\begin{document}\n\\section{Intro}\\label{intro}\n"
    + para.joined(separator: "\n\n") + "\n\nSee Section~\\ref{intro} and \\cite{knuth}.\n"
    + "\\bibliographystyle{plain}\n\\bibliography{refs}\n\\end{document}\n"
}()
private let bib = "@book{knuth, author={Donald Knuth}, title={The {\\TeX}book}, year={1984}, publisher={Addison-Wesley}}\n"

@Test func universalEngineChoice() {
  let env: [String: String] = [:]
  let on = (unicode: true, pdflatex: false)
  #expect(EngineChoice.choose(compiler: "xelatex", image: nil, mainText: nil, setting: nil, universal: on, env: env) == .universal(.xelatex))
  #expect(EngineChoice.choose(compiler: "lualatex", image: nil, mainText: nil, setting: nil, universal: on, env: env) == .universal(.lualatex))
  #expect(EngineChoice.choose(compiler: "pdflatex", image: "texlive-full:2025.1", mainText: nil, setting: nil, universal: on, env: env) == .live(year: "2025"))
  #expect(EngineChoice.choose(compiler: "pdflatex", image: nil, mainText: nil, setting: nil, universal: (true, true), env: env) == .universal(.pdflatex))
  // the project's own engine wins over Overleaf's
  #expect(EngineChoice.choose(compiler: "pdflatex", image: nil, mainText: nil, engine: .lualatex, setting: nil, universal: on, env: env) == .universal(.lualatex))
  #expect(EngineChoice.choose(compiler: "xelatex", image: nil, mainText: nil, engine: .pdflatex, setting: nil, universal: on, env: env) == .live(year: "2026"))
  // the source decides without the engine
  #expect(EngineChoice.choose(compiler: nil, image: nil, mainText: "% !TEX program = lualatex\n", setting: nil, universal: on, env: env) == .universal(.lualatex))
  #expect(EngineChoice.choose(compiler: nil, image: nil, mainText: "\\usepackage{fontspec}\n", setting: nil, universal: on, env: env) == .universal(.xelatex))
  #expect(EngineChoice.choose(compiler: "xelatex", image: nil, mainText: nil, setting: "texpresso", universal: on, env: env) == .texpresso)
  #expect(EngineChoice.choose(compiler: nil, image: nil, mainText: nil, setting: nil, universal: on, env: ["TAUDOT_ENGINE": "universal-lualatex"]) == .universal(.lualatex))
}

/// A project on universal: first compile with BibTeX (citation resolved), an edit on page 2 changes page 2 only,
/// SyncTeX, glyphs.
@MainActor func universalEndToEnd(_ e: TexEngine) async throws {
  guard UniversalPaths.missing(e) == nil else { print("skip: \(UniversalPaths.missing(e)!)"); return }
  let dir = try project(paper, files: ["refs.bib": bib])
  defer { try? FileManager.default.removeItem(at: dir) }
  let t = LiveTex(main: dir.appendingPathComponent("main.tex"), year: "2026", state: dir.appendingPathComponent(".state"), universal: e)
  var events: [PagesEvent] = []
  var notes: [String] = []
  t.onPages = { events.append($0) }
  t.onNote = { notes.append($0) }
  t.start()
  defer { t.stop() }
  try await waitFor(120) { events.contains { $0.done } }
  let first = try #require(events.last, "no pages; notes: \(notes.suffix(5))")
  #expect(first.n == 2, "notes: \(notes.suffix(5))")
  #expect(t.pageText(1)?.contains("Knuth") == true)  // BibTeX ran and the rerun picked it up
  #expect(t.pageText(1)?.contains("[1]") == true)
  let img = try #require(await t.render(page: 0, scale: 2, x: 100, y: 100, w: 400, h: 300))
  #expect(img.width == 400)
  let g = try #require(await t.glyphs(page: 0))
  #expect(g.glyphs.map(\.t).joined().contains("Paragraph1."))

  events = []
  t.open("main.tex", paper)
  let at = (paper as NSString).range(of: "See Section").location
  t.change("main.tex", at, 0, "Added words. ")
  try await waitFor { events.contains { $0.done && $0.applied >= 2 } }
  let changed = Set(events.filter { $0.applied >= 2 }.flatMap(\.changed))
  #expect(changed == [1])
  #expect(t.pageText(1)?.contains("Added words.") == true)
  #expect(t.pageText(0)?.contains("Paragraph 1.") == true)
  let st = SyncTex(try #require(await t.synctex()))
  #expect(st.forward(file: "main.tex", line: 5)?.page == 0)
  if e == .xelatex {  // tau-live converted only page 2: page 1 is still drawn from the first compile's PDF
    #expect(t.pages.count == 2 && t.pages[0].pdf !== t.pages[1].pdf && t.pages[1].pdf.first == 1)
    print("xdv → pdf in tau-live: \(t.xdvMs.value) ms")
  }
}

@MainActor @Test func universalLuaLaTeX() async throws { try await universalEndToEnd(.lualatex) }
@MainActor @Test func universalXeLaTeX() async throws { try await universalEndToEnd(.xelatex) }

/// The pane picks universal for a fontspec document (no engine: the source decides) and shows its pages.
@MainActor @Test func paneChoosesUniversal() async throws {
  guard UniversalPaths.missing(.xelatex) == nil, UniversalSettings.unicode() else { return }
  let dir = try project(paper, files: ["refs.bib": bib])
  defer { try? FileManager.default.removeItem(at: dir) }
  let cache = dir.appendingPathExtension("cache")
  defer { try? FileManager.default.removeItem(at: cache) }
  let pane = TaudotPDFPane(cacheRoot: cache)
  pane.open(folder: dir, main: "main.tex", engineSocket: nil)
  defer { pane.close() }
  #expect(pane.engine == .universal(.xelatex))
  #expect(CurrentProject.running == "XeLaTeX on universal")
  try await waitFor { pane.syncTex != nil }
  #expect(pane.pane.pageCount == 2)
  #expect(pane.inverse(page: 0, x: 200, y: 200)?.path.hasSuffix("main.tex") == true)
  // the project's own engine (Settings ▸ PDF): restarts on LuaLaTeX
  UniversalSettings.setEngine(.lualatex, for: dir)
  defer { UniversalSettings.setEngine(nil, for: dir) }
  NotificationCenter.default.post(name: UniversalSettings.changed, object: nil)
  #expect(pane.engine == .universal(.lualatex))
}

/// Universal's paragraph preview (tau-live's `para`, as the patched pass's): typing in a paragraph gets exact
/// previews on the right page (page 2: tau-live runs no pass before the first page has shipped); drawn as the pane draws them, against the exact page over the erase rects.
/// Returns (previews checked, differing pixels per preview).
@MainActor func universalPara(_ e: TexEngine) async throws -> (Int, [Int]) {
  guard UniversalPaths.missing(e) == nil else { return (0, []) }
  let para = (1...14).map { "Paragraph \($0). " + String(repeating: "Some words to fill the line. ", count: 12) }
  let text = "\\documentclass{article}\n\\begin{document}\n" + para.joined(separator: "\n\n") + "\n\\end{document}\n"
  let dir = try project(text)
  defer { try? FileManager.default.removeItem(at: dir) }
  let t = LiveTex(main: dir.appendingPathComponent("main.tex"), year: "2026", universal: e)
  var events: [PagesEvent] = []
  var previews: [ParaOverlay] = []
  t.onPages = { events.append($0) }
  t.onPara = { previews.append($0) }
  t.start()
  defer { t.stop() }
  try await waitFor { events.contains { $0.done } }
  t.open("main.tex", text)
  var at = text.utf8.count - (text.components(separatedBy: "Paragraph 13. ").last ?? "").utf8.count + 4
  var diffs: [Int] = []
  for i in 0..<5 {
    t.change("main.tex", at, 0, "x")
    at += 1
    let applied = 2 + i
    try await waitFor(20) { events.contains { $0.done && $0.applied >= applied } }
    try await waitFor(1) { previews.contains { $0.applied == applied } }  // (decoded on its own queue: may land after `done`)
    guard let o = previews.last(where: { $0.applied == applied }) else { continue }  // the first edit leaves the snapshot
    #expect(o.exact, "\(e) preview \(o.go): \(o.state) \(o.why ?? "")")
    #expect(t.pageText(o.page)?.contains("Paragraph 13.") == true)  // on the page that holds the paragraph
    let b = o.bounds.insetBy(dx: -2, dy: -2)
    let x0 = Int(b.minX * 2), y0 = Int(b.minY * 2), w = Int(b.width * 2), h = Int(b.height * 2)
    let mine = try #require(ParaOverlay.render(o, scale: 2, x0: x0, y0: y0, w: w, h: h, style: "white"))
    let exact = try #require(await t.render(page: o.page, scale: 2, x: x0, y: y0, w: w, h: h))
    var diff = 0
    for y in 4..<(h - 4) {
      for x in 4..<(w - 4) where o.erase.contains(where: { $0.contains(CGPoint(x: Double(x0 + x) / 2, y: Double(y0 + y) / 2)) }) {
        let p = pixel(mine, x, y), q = pixel(exact, x, y)
        if max(abs(p.0 - q.0), abs(p.1 - q.1), abs(p.2 - q.2)) > 0 { diff += 1 }
      }
    }
    if let dd = ProcessInfo.processInfo.environment["UNI_DUMP"] {
      dumpTile(mine, "\(dd)/\(e)-\(o.go)-mine.png"); dumpTile(exact, "\(dd)/\(e)-\(o.go)-exact.png")
    }
    diffs.append(diff)
  }
  print("universalPara \(e): \(diffs.count) checked of \(previews.count) previews, differing px \(diffs)")
  return (diffs.count, diffs)
}

@MainActor @Test func universalParaPdfTeX() async throws {
  let (n, d) = try await universalPara(.pdflatex)
  if UniversalPaths.missing(.pdflatex) == nil { #expect(n >= 3); #expect(d.allSatisfy { $0 == 0 }) }
}
@MainActor @Test func universalParaLuaTeX() async throws {
  let (n, d) = try await universalPara(.lualatex)
  if UniversalPaths.missing(.lualatex) == nil { #expect(n >= 3); #expect(d.allSatisfy { $0 == 0 }) }
}
/// XeTeX's preview is the TDL's outlines (no overlay PDF), the page xdvipdfmx's PDF: same glyphs, same places;
/// antialiasing of outlines filled by us vs the embedded font drawn by Core Graphics may differ at edges.
@MainActor @Test func universalParaXeTeX() async throws {
  let (n, d) = try await universalPara(.xelatex)
  if UniversalPaths.missing(.xelatex) == nil { #expect(n >= 3); #expect(d.allSatisfy { $0 < 2000 }) }  // measured ~1k, all in the edited line and the next
}

/// The pane shows universal's preview: an edit puts the overlay layer on its page, the exact page retires it.
@MainActor @Test func paneShowsUniversalPara() async throws {
  guard UniversalPaths.missing(.lualatex) == nil else { return }
  let para = (1...14).map { "Paragraph \($0). " + String(repeating: "Some words to fill the line. ", count: 12) }
  let text = "% !TEX program = lualatex\n\\documentclass{article}\n\\begin{document}\n" + para.joined(separator: "\n\n") + "\n\\end{document}\n"
  let dir = try project(text)
  defer { try? FileManager.default.removeItem(at: dir) }
  let cache = dir.appendingPathExtension("cache")
  defer { try? FileManager.default.removeItem(at: cache) }
  let pane = TaudotPDFPane(cacheRoot: cache)
  pane.open(folder: dir, main: "main.tex", engineSocket: nil)
  defer { pane.close() }
  #expect(pane.engine == .universal(.lualatex))
  try await waitFor { pane.syncTex != nil }
  let t = try #require(pane.txp)
  t.open("main.tex", text)
  var at = text.utf8.count - (text.components(separatedBy: "Paragraph 13. ").last ?? "").utf8.count + 4
  var shown: [ParaOverlay] = []
  pane.pane.para.onShown = { shown.append($0) }
  for _ in 0..<4 {
    t.change("main.tex", at, 0, "x")
    at += 1
    try await Task.sleep(for: .milliseconds(400))
  }
  #expect(!shown.isEmpty, "no preview reached the pane")
  #expect(shown.allSatisfy { $0.exact })
  try await waitFor(5) { pane.pane.paraShown == nil }
  #expect(pane.pane.paraShown == nil, "the exact page didn't retire the preview")
}

/// Debugging aid (UNI_DUMP=dir): a tile as PNG.
func dumpTile(_ t: TileImage, _ path: String) {
  let ci = CIImage(ioSurface: t.surface)
  let ctx = CIContext()
  guard let cg = ctx.createCGImage(ci, from: ci.extent) else { return }
  let rep = NSBitmapImageRep(cgImage: cg)
  try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}
