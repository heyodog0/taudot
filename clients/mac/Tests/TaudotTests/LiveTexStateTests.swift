import Foundation
import Testing
@testable import TaudotPDF

// LiveTex's state across a compile (docs/state-machines.md, P1, P5, P6, P16), on the real live pdfTeX: the driver is
// built from this checkout's clients/pdftex/live.c, the engine is the pdftex agent's. Skipped without the engine.

private func ready() -> Bool { LiveTexPaths.missing("2026") == nil && !LiveTexPaths.isFake("2026") }

/// pdftex-live from this checkout, built once into a temp folder.
private let driver: String? = {
  let src = TxpPaths.repo.appendingPathComponent("clients/pdftex/live.c").path
  let out = FileManager.default.temporaryDirectory.appendingPathComponent("statefix-pdftex-live-\(getpid())").path
  let p = Process()
  p.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
  p.arguments = ["-O2", "-o", out, src]
  guard (try? p.run()) != nil else { return nil }
  p.waitUntilExit()
  return p.terminationStatus == 0 ? out : nil
}()

private func project(_ text: String) throws -> URL {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("statefix-\(UUID().uuidString.prefix(6))")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  try text.write(to: dir.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
  return dir
}

@MainActor private func waitFor(_ seconds: Double = 30, _ cond: () -> Bool) async throws {
  let end = Date().addingTimeInterval(seconds)
  while !cond() && Date() < end { try await Task.sleep(for: .milliseconds(20)) }
}

private let good = "\\documentclass{article}\n\\begin{document}\nHello.\n\\end{document}\n"
private let fatal = "\\documentclass{article}\n\\begin{document}\n\\input{missingfile}\nHello.\n\\end{document}\n"

@MainActor private func live(_ dir: URL) throws -> LiveTex {
  var env = ProcessInfo.processInfo.environment
  env["TAUDOT_LIVE_DRIVER"] = try #require(driver)
  return LiveTex(main: dir.appendingPathComponent("main.tex"), year: "2026", env: env)
}

/// P1: a first run that writes no PDF (a fatal error before page 1) still settles, with its error shown.
@MainActor @Test func liveFatalFirstRunSettles() async throws {
  guard ready() else { return }
  let dir = try project(fatal)
  defer { try? FileManager.default.removeItem(at: dir) }
  let t = try live(dir)
  var events: [PagesEvent] = [], errors: [String] = []
  t.onPages = { events.append($0) }
  t.onError = { errors.append($0) }
  t.start()
  defer { t.stop() }
  try await waitFor { events.contains { $0.done } }
  #expect(events.last?.done == true && events.last?.n == 0)
  #expect(errors.contains { $0.contains("missingfile") })
}

/// P1: after a good PDF, an edit that makes a run write no PDF settles on the pages shown, with the new error, not
/// the old PDF's log.
@MainActor @Test func liveFatalAfterGoodShowsNewLog() async throws {
  guard ready() else { return }
  let dir = try project(good)
  defer { try? FileManager.default.removeItem(at: dir) }
  let t = try live(dir)
  var events: [PagesEvent] = [], errors: [String] = [], lines: [String] = []
  t.onPages = { events.append($0) }
  t.onError = { errors.append($0) }
  t.onLine = { lines.append($0) }
  t.start()
  defer { t.stop() }
  try await waitFor { events.contains { $0.done } }
  #expect(events.last?.n == 1)
  #expect(errors.isEmpty)
  events = []
  lines = []
  t.open("main.tex", fatal)
  try await waitFor { events.contains { $0.done } }
  #expect(events.last?.done == true && events.last?.n == 1)  // the old page stays
  #expect(errors.contains { $0.contains("missingfile") })
  #expect(lines.contains { $0.contains("missingfile") })
}
