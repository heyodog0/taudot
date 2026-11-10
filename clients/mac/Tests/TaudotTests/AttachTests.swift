// tau-attach (clients/attach): a program in a pty shared by several terminals and outliving them. The Claude pane
// runs claude this way (editfix item 7).
import Foundation
import Testing

/// clients/attach/tau-attach, built if it isn't (cc, no dependencies).
func tauAttach() throws -> String {
  let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../attach").standardized
  let bin = dir.appendingPathComponent("tau-attach").path
  let src = dir.appendingPathComponent("tau-attach.c").path
  let fm = FileManager.default
  let stale = (try? fm.attributesOfItem(atPath: src)[.modificationDate] as? Date).flatMap { s in
    (try? fm.attributesOfItem(atPath: bin)[.modificationDate] as? Date).map { $0 < s } } ?? true
  if stale {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = [dir.appendingPathComponent("build.sh").path]
    try p.run(); p.waitUntilExit()
  }
  return bin
}

/// A short socket path (Unix sockets allow ~104 bytes) in a fresh directory, removed by `cleanup`.
func attachSocket() throws -> (path: String, cleanup: () -> Void) {
  let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ta-\(UInt32.random(in: 0...UInt32.max))")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  return (dir.appendingPathComponent("s").path, { try? FileManager.default.removeItem(at: dir) })
}

final class Collected: @unchecked Sendable {
  private let lock = NSLock()
  private var data = Data()
  func add(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
  var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

/// A `tau-attach attach` client: its stdin a pipe, or a pty of `size` (rows, cols); its output collected.
final class AttachClient: @unchecked Sendable {
  let process = Process()
  let output = Collected()
  private var input: FileHandle
  private var ptyMaster: Int32 = -1

  init(_ bin: String, _ sock: String, size: (UInt16, UInt16)? = nil) throws {
    process.executableURL = URL(fileURLWithPath: bin)
    process.arguments = ["attach", sock]
    let out = Pipe()
    process.standardOutput = out
    if let size {
      var m: Int32 = 0, s: Int32 = 0
      var w = winsize(ws_row: size.0, ws_col: size.1, ws_xpixel: 0, ws_ypixel: 0)
      guard openpty(&m, &s, nil, nil, &w) == 0 else { throw POSIXError(.EIO) }
      ptyMaster = m
      process.standardInput = FileHandle(fileDescriptor: s, closeOnDealloc: true)
      input = FileHandle(fileDescriptor: m, closeOnDealloc: false)
    } else {
      let p = Pipe()
      process.standardInput = p
      input = p.fileHandleForWriting
    }
    let collected = output
    out.fileHandleForReading.readabilityHandler = { h in collected.add(h.availableData) }
    try process.run()
  }

  func type(_ s: String) { input.write(s.data(using: .utf8)!) }
  /// EOF on stdin (a pipe) or the terminal gone (a pty): the client detaches.
  func detach() { if ptyMaster >= 0 { close(ptyMaster); ptyMaster = -1 } else { try? input.close() } }
  func waitExit(_ seconds: Double = 3) async -> Int32? {
    for _ in 0..<Int(seconds * 50) where process.isRunning { try? await Task.sleep(for: .milliseconds(20)) }
    return process.isRunning ? nil : process.terminationStatus
  }
  deinit { if process.isRunning { process.terminate() }; if ptyMaster >= 0 { close(ptyMaster) } }
}

func runTool(_ bin: String, _ args: [String]) throws -> (Int32, String) {
  let p = Process()
  p.executableURL = URL(fileURLWithPath: bin)
  p.arguments = args
  let out = Pipe()
  p.standardOutput = out
  try p.run()
  p.waitUntilExit()
  return (p.terminationStatus, String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
}

func waitUntil(_ seconds: Double = 3, _ cond: () -> Bool) async {
  for _ in 0..<Int(seconds * 50) where !cond() { try? await Task.sleep(for: .milliseconds(20)) }
}

@Test func attachTwoClientsSeeTheSameProgram() async throws {
  let bin = try tauAttach(), (sock, cleanup) = try attachSocket()
  defer { cleanup() }
  let (st, _) = try runTool(bin, ["new", "-d", sock, "--", "sh", "-c", "echo started; exec cat"])
  #expect(st == 0)
  defer { if let pid = Int32(((try? runTool(bin, ["status", sock]))?.1 ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) { kill(pid, SIGKILL) } }
  let a = try AttachClient(bin, sock), b = try AttachClient(bin, sock)
  await waitUntil { a.output.text.contains("started") && b.output.text.contains("started") }
  #expect(a.output.text.contains("started") && b.output.text.contains("started"), "both get the replay")
  a.type("from-a\n")
  await waitUntil { b.output.text.contains("from-a") }
  #expect(b.output.text.contains("from-a"), "what one types, the other sees")
  b.type("from-b\n")
  await waitUntil { a.output.text.contains("from-b") }
  #expect(a.output.text.contains("from-b"))
  a.detach(); b.detach()
  let ea = await a.waitExit(), eb = await b.waitExit()
  #expect(ea == 0 && eb == 0, "EOF detaches")
}

@Test func attachTheClientThatTypedLastSetsTheSize() async throws {
  let bin = try tauAttach(), (sock, cleanup) = try attachSocket()
  defer { cleanup() }
  // prints the pty's size for every line typed
  _ = try runTool(bin, ["new", "-d", sock, "--", "sh", "-c", "while read l; do echo \"size $(stty size)\"; done"])
  defer { if let pid = Int32(((try? runTool(bin, ["status", sock]))?.1 ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) { kill(pid, SIGKILL) } }
  let a = try AttachClient(bin, sock, size: (30, 100))
  try await Task.sleep(for: .milliseconds(300))
  let b = try AttachClient(bin, sock, size: (20, 60))
  try await Task.sleep(for: .milliseconds(300))
  a.type("x\r")
  await waitUntil { a.output.text.contains("size 30 100") }
  #expect(a.output.text.contains("size 30 100"), "the first client's size (\(a.output.text.suffix(60)))")
  b.type("y\r")
  await waitUntil { b.output.text.contains("size 20 60") }
  #expect(b.output.text.contains("size 20 60"), "b typed: b's size (\(b.output.text.suffix(60)))")
  a.type("z\r")
  await waitUntil { a.output.text.components(separatedBy: "size 30 100").count > 2 }
  #expect(a.output.text.components(separatedBy: "size 30 100").count > 2, "a typed again: a's size")
  a.detach(); b.detach()
}

@Test func attachReattachKeepsTheProgramAndReplays() async throws {
  let bin = try tauAttach(), (sock, cleanup) = try attachSocket()
  defer { cleanup() }
  _ = try runTool(bin, ["new", "-d", sock, "--", "sh", "-c", "seq 1 200; exec cat"])
  defer { if let pid = Int32(((try? runTool(bin, ["status", sock]))?.1 ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) { kill(pid, SIGKILL) } }
  let pid0 = try runTool(bin, ["status", sock]).1
  let a = try AttachClient(bin, sock)
  a.type("before-detach\n")
  await waitUntil { a.output.text.components(separatedBy: "before-detach").count > 2 }
  a.detach()
  #expect(await a.waitExit() == 0)
  // the program kept running; a new client gets its output so far
  let (st, pid1) = try runTool(bin, ["status", sock])
  #expect(st == 0 && pid1 == pid0, "same program after a detach (pid \(pid0.trimmingCharacters(in: .newlines)) → \(pid1.trimmingCharacters(in: .newlines)))")
  let b = try AttachClient(bin, sock)
  await waitUntil { b.output.text.contains("before-detach") }
  let replayed = b.output.text.replacingOccurrences(of: "\r", with: "")
  #expect(replayed.contains("\n200\n") && replayed.contains("before-detach"), "replayed on reattach")
  b.detach()
}

@Test func attachTheProgramsExitEndsEveryClient() async throws {
  let bin = try tauAttach(), (sock, cleanup) = try attachSocket()
  defer { cleanup() }
  _ = try runTool(bin, ["new", "-d", sock, "--", "sh", "-c", "read l; exit 7"])
  let a = try AttachClient(bin, sock), b = try AttachClient(bin, sock)
  try await Task.sleep(for: .milliseconds(300))
  a.type("bye\n")
  let ea = await a.waitExit(), eb = await b.waitExit()
  #expect(ea == 7 && eb == 7, "both exit with the program's status (\(String(describing: ea)), \(String(describing: eb)))")
  #expect(!FileManager.default.fileExists(atPath: sock), "the socket goes with it")
  #expect(try runTool(bin, ["status", sock]).0 == 1)
  // and a new one can start there; a second `new` on a live one refuses
  _ = try runTool(bin, ["new", "-d", sock, "--", "sh", "-c", "exec cat"])
  #expect(try runTool(bin, ["new", "-d", sock, "--", "true"]).0 == 3)
  if let pid = Int32(try runTool(bin, ["status", sock]).1.trimmingCharacters(in: .whitespacesAndNewlines)) { kill(pid, SIGKILL) }
}
