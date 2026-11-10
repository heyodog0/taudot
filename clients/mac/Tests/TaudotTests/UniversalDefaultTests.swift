import Foundation
import Testing
@testable import TaudotPDF

// pdfLaTeX on universal by default (2026-11-09), the patched pdfTeX when the switch is off; sessions forked from
// uspeed's parked engine (docs/universal.md, "Parked engine").

private func defaults() -> UserDefaults {
  let name = "universal-default-\(UUID().uuidString.prefix(6))"
  let d = UserDefaults(suiteName: name)!
  d.removePersistentDomain(forName: name)
  return d
}

@Test func pdflatexOnUniversalByDefault() {
  let d = defaults()
  #expect(UniversalSettings.pdflatex(d))
  let sw = (UniversalSettings.unicode(d), UniversalSettings.pdflatex(d))
  #expect(EngineChoice.choose(compiler: "pdflatex", image: "texlive-full:2025.1", mainText: nil, setting: nil, universal: sw, env: [:])
    == .universal(.pdflatex))
  #expect(EngineChoice.choose(compiler: nil, image: nil, mainText: "\\documentclass{article}\n", setting: nil, universal: sw, env: [:])
    == .universal(.pdflatex))
  // the switch off: the patched pdfTeX, for the project's year
  d.set(false, forKey: UniversalSettings.pdflatexKey)
  #expect(!UniversalSettings.pdflatex(d))
  let off = (UniversalSettings.unicode(d), UniversalSettings.pdflatex(d))
  #expect(EngineChoice.choose(compiler: "pdflatex", image: "texlive-full:2025.1", mainText: nil, setting: nil, universal: off, env: [:])
    == .live(year: "2025"))
  // "everything on TeXpresso" still wins
  #expect(EngineChoice.choose(compiler: "pdflatex", image: nil, mainText: nil, setting: "texpresso", universal: sw, env: [:]) == .texpresso)
}

/// Without a universal build a pdfLaTeX project falls back to the patched pdfTeX (and to TeXpresso without that).
@MainActor @Test func pdflatexFallsBackWithoutUniversal() {
  let none: (TexEngine) -> String? = { _ in "no tau-live" }
  let (c, notes) = TaudotPDFPane.runnable(.universal(.pdflatex), universalMissing: none, liveMissing: { _ in nil })
  #expect(c == .live(year: EngineChoice.years[0]))
  #expect(notes.count == 1 && notes[0].contains("pdfTeX"))
  #expect(TaudotPDFPane.runnable(.universal(.pdflatex), universalMissing: none, liveMissing: { _ in "no year" }).0 == .texpresso)
  #expect(TaudotPDFPane.runnable(.universal(.lualatex), universalMissing: none, liveMissing: { _ in nil }).0 == .texpresso)
  #expect(TaudotPDFPane.runnable(.universal(.pdflatex), universalMissing: { _ in nil }, liveMissing: { _ in nil }).0 == .universal(.pdflatex))
}

/// A session started with --parked forks its engine from the parked one, and typesets the same pages.
@MainActor @Test func sessionForksFromParkedEngine() async throws {
  guard UniversalPaths.missing(.pdflatex) == nil else { return }
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("parked-\(UUID().uuidString.prefix(6))")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: dir) }
  try "\\documentclass{article}\n\\begin{document}\nParked engines, \\today.\n\\end{document}\n"
    .write(to: dir.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
  let parks = ParkedEngines.shared
  parks.enabled = true
  defer { parks.stopAll(); parks.enabled = false }
  #expect(parks.ensure(.pdflatex) != nil)
  let end = Date().addingTimeInterval(30)
  while (parks.parkedEvents[.pdflatex] ?? 0) == 0 && Date() < end { try await Task.sleep(for: .milliseconds(20)) }
  #expect((parks.parkedEvents[.pdflatex] ?? 0) > 0, "no parked engine")

  func session(log: URL) async throws -> String? {
    var env = ProcessInfo.processInfo.environment
    env["TAU_LIVE_LOG"] = log.path
    let t = LiveTex(main: dir.appendingPathComponent("main.tex"), year: "2026", env: env, universal: .pdflatex)
    var done = false
    t.onPages = { if $0.done { done = true } }
    t.start()
    defer { t.stop() }
    let end = Date().addingTimeInterval(60)
    while !done && Date() < end { try await Task.sleep(for: .milliseconds(20)) }
    #expect(done)
    return t.pageText(0)
  }
  let log = dir.appendingPathComponent("parked.log")
  let parkedText = try await session(log: log)
  let l = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
  #expect(l.contains("from the parked engine"), "the session spawned its own engine")
  // the same pages as a session that starts its own engine
  parks.enabled = false
  let own = dir.appendingPathComponent("own.log")
  let ownText = try await session(log: own)
  #expect(((try? String(contentsOf: own, encoding: .utf8)) ?? "").contains("engine") )
  #expect(!(((try? String(contentsOf: own, encoding: .utf8)) ?? "").contains("from the parked engine")))
  #expect(parkedText != nil && parkedText == ownText)
}
