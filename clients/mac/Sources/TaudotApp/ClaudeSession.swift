// Where the Claude pane's `claude` runs: behind tau-attach (clients/attach), so it outlives Taudot and more than one
// terminal can show it. With Settings ▸ Claude ▸ Run in Rex (on by default) and a Rex server answering, tau-attach's
// server runs in a block of the project's own Rex session (`taudot-<folder>`): the conversation also shows in the Rex
// app, on the user's other Mac, and to agents through `rex capture` / `rex send`. Otherwise Taudot starts it itself.
// Either way the pane's terminal runs `tau-attach attach SOCKET`, and reopening the project attaches to the same
// claude. (When Rex can attach to a block itself, `rex attach` replaces tau-attach in the block.)
import Foundation
import TaudotNeovim
import TaudotShared

enum ClaudeSession {
  enum How: String { case running = "already running", rex = "in Rex", local = "here" }

  /// tau-attach: $TAUDOT_ATTACH, the app's Resources/tau-attach, else the repo's clients/attach (development builds).
  static var tool: String? {
    let fm = FileManager.default
    if let t = ProcessInfo.processInfo.environment["TAUDOT_ATTACH"], fm.isExecutableFile(atPath: t) { return t }
    if let c = BundledTools.contents?.appendingPathComponent("Resources/tau-attach").path, fm.isExecutableFile(atPath: c) { return c }
    let dev = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../attach/tau-attach").standardized.path
    return fm.isExecutableFile(atPath: dev) ? dev : nil
  }

  /// A test run: a fake claude ($TAUDOT_CLAUDE). It never reaches the user's Rex server (only one named by
  /// $TAUDOT_REX_SERVER), keeps its sockets out of the user's caches, and its claude ends with the pane unless
  /// $TAUDOT_CLAUDE_KEEP is set (ClaudePane.stop).
  static var isTest: Bool { ProcessInfo.processInfo.environment["TAUDOT_CLAUDE"] != nil }

  /// A test's claudes, ended when the app exits, however it exits normally (the checks' `exit` skips the panes' stop).
  nonisolated(unsafe) static var testPids: [pid_t] = []
  static func endWithUs(_ pid: Int) {
    if testPids.isEmpty { atexit { for p in ClaudeSession.testPids { kill(p, SIGTERM) } } }
    testPids.append(pid_t(pid))
  }

  /// The project's socket: one per folder, a short path (Unix sockets allow ~104 bytes). $TAUDOT_CLAUDE_SOCKETS
  /// moves the directory (tests).
  static func socket(for folder: URL) -> String {
    let env = ProcessInfo.processInfo.environment
    let dir = env["TAUDOT_CLAUDE_SOCKETS"]
      ?? (isTest ? NSTemporaryDirectory() + "taudot-claude-tests"
          : FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("taudot/claude").path)
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    var h: UInt64 = 0xcbf29ce484222325  // FNV-1a of the folder's path
    for b in folder.standardizedFileURL.path.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
    return dir + "/" + String(format: "%016llx", h) + ".s"
  }

  /// The Rex session's label for a project.
  static func label(for folder: URL) -> String {
    let name = folder.lastPathComponent.map { $0.isLetter || $0.isNumber || "._-".contains($0) ? $0 : "-" }
    return "taudot-" + String(name)
  }

  /// rex: $TAUDOT_REX, PATH, ~/.local/bin, Rex's own copy. Nil: no Rex installed.
  static var rex: String? {
    let fm = FileManager.default, env = ProcessInfo.processInfo.environment
    if let r = env["TAUDOT_REX"] { return fm.isExecutableFile(atPath: r) ? r : nil }
    let home = fm.homeDirectoryForCurrentUser.path
    let dirs = (env["PATH"] ?? "").split(separator: ":").map(String.init) + [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
    for d in dirs where fm.isExecutableFile(atPath: d + "/rex") { return d + "/rex" }
    let app = home + "/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"
    return fm.isExecutableFile(atPath: app) ? app : nil
  }

  /// Arguments that pick the Rex server: $TAUDOT_REX_SERVER (tests: a server of their own), else rex's own choice;
  /// never starting one.
  static var rexServer: [String] {
    (ProcessInfo.processInfo.environment["TAUDOT_REX_SERVER"].map { ["-S", $0] } ?? []) + ["--autostart=false"]
  }

  /// claude's pid behind `sock`, or nil when nothing runs there.
  static func pid(_ sock: String) -> Int? {
    guard let t = tool, let r = run(t, ["status", sock], timeout: 2), r.status == 0 else { return nil }
    return Int(r.out.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  /// Makes sure `command` runs behind the project's socket: it already does, else in a Rex block (`inRex` and a Rex
  /// server answering), else started here. Nil: tau-attach is missing or nothing could start it.
  static func ensure(folder: URL, command: String, env: [String: String], inRex: Bool) -> (sock: String, how: How)? {
    guard let t = tool else { return nil }
    let sock = socket(for: folder)
    if pid(sock) != nil { return (sock, .running) }
    // `exec` through sh: the command may carry arguments, and PATH is the shell's
    let start = [t, "new", sock, "--", "/bin/sh", "-c", "exec " + command]
    let rexOK = inRex && (!isTest || ProcessInfo.processInfo.environment["TAUDOT_REX_SERVER"] != nil)
    if rexOK, startInRex(folder: folder, start: start) {
      for _ in 0..<100 { if pid(sock) != nil { return (sock, .rex) }; usleep(50_000) }
    }
    if pid(sock) != nil { return (sock, .rex) }
    // here: in the background (-d); it outlives Taudot too
    var e = ProcessInfo.processInfo.environment.merging(env) { _, b in b }
    for k in e.keys where k == "CLAUDECODE" || k.hasPrefix("CLAUDE_CODE_") { e[k] = nil }  // not a child of a Claude session
    let local = [t, "new", "-d", sock, "--", "/bin/sh", "-c", "exec " + command]
    guard let r = run(local[0], Array(local.dropFirst()), env: e, cwd: folder, timeout: 5), r.status == 0 || r.status == 3 else { return nil }
    return pid(sock) != nil ? (sock, .local) : nil
  }

  /// A window running `start` in the project's Rex session (made if it isn't there; the user's other sessions are
  /// never touched). False when Rex isn't installed, no server answers, or the call fails.
  static func startInRex(folder: URL, start: [String]) -> Bool {
    guard let rex else { return false }
    guard let ls = run(rex, rexServer + ["ls", "--json"], timeout: 3), ls.status == 0,
          let j = try? JSONSerialization.jsonObject(with: Data(ls.out.utf8)) as? [String: Any] else { return false }
    let name = label(for: folder)
    let sessions = j["sessions"] as? [[String: Any]] ?? []
    let mine = sessions.first { $0["label"] as? String == name }?["session_id"] as? String
    let args: [String]
    if let mine {
      args = rexServer + ["window", "new", "-s", mine, "claude", "-c", folder.path, "--focus=false", "--json", "--"] + start
    } else {
      args = rexServer + ["new", name, "-c", folder.path, "--window", "claude", "--json", "--"] + start
    }
    return run(rex, args, timeout: 5)?.status == 0
  }

  /// Runs a program and returns its status and output; nil if it can't start or outlasts `timeout`.
  static func run(_ exe: String, _ args: [String], env: [String: String]? = nil, cwd: URL? = nil, timeout: Double) -> (status: Int32, out: String)? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    if let env { p.environment = env }
    if let cwd { p.currentDirectoryURL = cwd }
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    p.standardInput = FileHandle.nullDevice
    let done = DispatchSemaphore(value: 0)
    p.terminationHandler = { _ in done.signal() }
    guard (try? p.run()) != nil else { return nil }
    let reader = DispatchQueue(label: "taudot.claude.run")
    var data = Data()
    let read = DispatchSemaphore(value: 0)
    reader.async { data = out.fileHandleForReading.readDataToEndOfFile(); read.signal() }
    if done.wait(timeout: .now() + timeout) == .timedOut { p.terminate(); return nil }
    _ = read.wait(timeout: .now() + 1)
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
  }
}
