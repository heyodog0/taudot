import Foundation
import Testing
@testable import TaudotPDF

// The typesetter drivers' lifecycle in the app (docs/state-machines.md P5): LiveTex and Txp keep one driver alive.
// The drivers here are small shell scripts, so these run anywhere and fast.

private func script(_ body: String) throws -> URL {
  let u = FileManager.default.temporaryDirectory.appendingPathComponent("drv-\(UUID().uuidString.prefix(6)).sh")
  try ("#!/bin/sh\n" + body).write(to: u, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path)
  return u
}

private func project() throws -> URL {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("drv-proj-\(UUID().uuidString.prefix(6))")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  try "\\documentclass{article}\\begin{document}Hi.\\end{document}\n".write(
    to: dir.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
  return dir
}

@MainActor private func waitFor(_ seconds: Double, _ cond: () -> Bool) async throws {
  let end = Date().addingTimeInterval(seconds)
  while !cond() && Date() < end { try await Task.sleep(for: .milliseconds(20)) }
}

@MainActor private func live(_ dir: URL, driver: String) -> LiveTex {
  var env = ProcessInfo.processInfo.environment
  env["TAUDOT_LIVE_DRIVER"] = driver
  return LiveTex(main: dir.appendingPathComponent("main.tex"), year: "2026", env: env)
}

private let hello = #"echo '{"ev":"hello","protocol":1,"engine":"fake","image":""}'"#

/// P5: a driver that can't be launched (not there yet) is tried again, not given up on.
@MainActor @Test func liveDriverLaunchRetried() async throws {
  let dir = try project()
  defer { try? FileManager.default.removeItem(at: dir) }
  let path = FileManager.default.temporaryDirectory.appendingPathComponent("drv-late-\(UUID().uuidString.prefix(6)).sh")
  let t = live(dir, driver: path.path)
  t.start()
  defer { t.stop() }
  try await Task.sleep(for: .milliseconds(300))
  let s = try script("\(hello)\nwhile read l; do :; done\n")
  try FileManager.default.moveItem(at: s, to: path)
  try await waitFor(10) { t.ready }
  #expect(t.ready)
}

/// P5: the events a driver wrote just before it exited are handled (here: its error), every time.
@MainActor @Test func liveLastEventsBeforeExitKept() async throws {
  let dir = try project()
  defer { try? FileManager.default.removeItem(at: dir) }
  let s = try script(#"\#(hello); echo '{"ev":"error","what":"engine","message":"last words"}'; exit 1"# + "\n")
  var seen = 0
  for _ in 0..<15 {
    let t = live(dir, driver: s.path)
    var notes: [String] = []
    t.onNote = { notes.append($0) }
    t.start()
    try await waitFor(3) { notes.contains { $0.contains("restarting") } }
    try await Task.sleep(for: .milliseconds(100))
    t.stop()
    if notes.contains(where: { $0.contains("last words") }) { seen += 1 }
  }
  #expect(seen == 15)
}

/// P5: the restart delay comes back down once a driver settled a compile: one that settles, then crashes, is
/// restarted at the shortest delay each time (without the reset: 0.5, 1, 2 s...).
@MainActor @Test func liveBackoffDecays() async throws {
  let dir = try project()
  defer { try? FileManager.default.removeItem(at: dir) }
  let s = try script(#"\#(hello); echo '{"ev":"done","seq":1,"runs":1,"pages":0,"code":3}'; sleep 0.1; exit 1"# + "\n")
  let t = live(dir, driver: s.path)
  t.start()
  defer { t.stop() }
  try await waitFor(30) { t.restartDelays.count >= 3 }
  #expect(t.restartDelays.prefix(3) == [0.5, 0.5, 0.5])
}

/// P5: Txp, a driver that can't be launched is tried again.
@MainActor @Test func txpLaunchRetried() async throws {
  let dir = try project()
  defer { try? FileManager.default.removeItem(at: dir) }
  let path = FileManager.default.temporaryDirectory.appendingPathComponent("txp-late-\(UUID().uuidString.prefix(6)).sh")
  let t = Txp(main: dir.appendingPathComponent("main.tex"), executable: path.path)
  var pages: [PagesEvent] = []
  t.onPages = { pages.append($0) }
  t.start()
  defer { t.stop() }
  try await Task.sleep(for: .milliseconds(300))
  let s = try script(#"echo '{"ev":"pages","gen":1,"n":1,"done":true,"sizes":[[612,792]],"changed":[0],"applied":0}'"#
    + "\nwhile read l; do :; done\n")
  try FileManager.default.moveItem(at: s, to: path)
  try await waitFor(10) { !pages.isEmpty }
  #expect(!pages.isEmpty)
}

/// P5: Txp's watchdog also covers a driver that hangs after its first pages: edits sent, no report and no output.
@MainActor @Test func txpWatchdogAfterFirstPages() async throws {
  let dir = try project()
  defer { try? FileManager.default.removeItem(at: dir) }
  let s = try script(#"echo '{"ev":"pages","gen":1,"n":1,"done":true,"sizes":[[612,792]],"changed":[0],"applied":0}'"#
    + "\nwhile read l; do :; done\n")  // reads every edit, never answers
  let t = Txp(main: dir.appendingPathComponent("main.tex"), executable: s.path)
  t.noPageTimeout = 1
  var pages = 0
  t.onPages = { _ in pages += 1 }
  t.start()
  defer { t.stop() }
  try await waitFor(5) { pages > 0 }
  t.change("main.tex", 0, 0, "x")
  try await waitFor(15) { t.restartCount > 0 }  // main-actor tests share one thread under load
  #expect(t.restartCount > 0)
}

/// P5: Txp, the pages a driver reported just before it exited are kept.
@MainActor @Test func txpLastEventsBeforeExitKept() async throws {
  let dir = try project()
  defer { try? FileManager.default.removeItem(at: dir) }
  let s = try script(#"echo '{"ev":"pages","gen":1,"n":1,"done":true,"sizes":[[612,792]],"changed":[0],"applied":0}'; exit 1"# + "\n")
  var seen = 0
  for _ in 0..<15 {
    let t = Txp(main: dir.appendingPathComponent("main.tex"), executable: s.path)
    var pages = 0
    t.onPages = { _ in pages += 1 }
    t.start()
    try await waitFor(15) { t.restartCount > 0 }
    try await waitFor(3) { pages > 0 }  // delivered, however slowly the main queue runs under load
    t.stop()
    if pages > 0 { seen += 1 }
  }
  #expect(seen == 15)
}

/// P6: TeXpresso's lost start is recognised whichever comes first: the empty done report (stdout) or the
/// "No fences" line (stderr).
@MainActor @Test func txpLostStartEitherOrder() async throws {
  let dir = try project()
  defer { try? FileManager.default.removeItem(at: dir) }
  let s = try script(#"echo '{"ev":"pages","gen":1,"n":0,"done":true,"sizes":[],"changed":[],"applied":0}'"# + "\n"
    + "sleep 0.3\necho 'No fences, assuming process finished' >&2\nwhile read l; do :; done\n")
  let t = Txp(main: dir.appendingPathComponent("main.tex"), executable: s.path)
  t.start()
  defer { t.stop() }
  try await waitFor(15) { t.restartCount > 0 }  // main-actor tests share one thread under load
  #expect(t.restartCount > 0)
}
