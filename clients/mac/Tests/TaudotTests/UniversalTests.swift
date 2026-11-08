import AppKit
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
  #expect(first.n == 2)
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
  if e == .xelatex { print("xdv → pdf: \(t.xdvMs.value) ms") }
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
