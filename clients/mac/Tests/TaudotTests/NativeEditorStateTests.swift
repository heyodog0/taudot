// sm-sync's state-machine checks for NativeEditor's connection and opens (docs/state-machines.md A7, A8), against a
// small fake engine on a Unix socket: JSON-RPC, one object per line, answers chosen by each test.
import AppKit
import Foundation
import Testing
@testable import TaudotEditor
import TaudotPDF

/// A fake engine: accepts connections on `path`, answers each request with `answer(method, params, n)` (`n`: how many
/// times that method was called before, over all connections).
final class FakeEditorEngine: @unchecked Sendable {
  enum Reply { case ok([String: Any]), fail(String), late(Double, [String: Any]) }
  let path: String
  private let lock = NSLock()
  private var listener: Int32 = -1
  private var clients: [Int32] = []
  private var calls: [String: Int] = [:]
  private(set) var connections = 0
  var answer: (String, [String: Any], Int) -> Reply

  init(path: String, answer: @escaping (String, [String: Any], Int) -> Reply) {
    self.path = path
    self.answer = answer
  }

  func count(_ method: String) -> Int { lock.withLock { calls[method] ?? 0 } }
  var connected: Int { lock.withLock { connections } }

  func start() {
    unlink(path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { p in
      for (i, b) in path.utf8.enumerated() { p[i] = b }
      p[path.utf8.count] = 0
    }
    _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    listen(fd, 8)
    listener = fd
    Thread.detachNewThread { [self] in
      while true {
        let c = accept(fd, nil, nil)
        if c < 0 { return }
        var one: Int32 = 1
        setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        lock.withLock { clients.append(c); connections += 1 }
        Thread.detachNewThread { [self] in serve(c) }
      }
    }
  }

  /// Close every client connection, as an engine restart does (the listener stays).
  func dropClients() {
    let cs = lock.withLock { let x = clients; clients = []; return x }
    for c in cs { shutdown(c, SHUT_RDWR) }
  }

  func stop() {
    dropClients()
    if listener >= 0 { close(listener); listener = -1 }
    unlink(path)
  }

  private func serve(_ c: Int32) {
    var buf = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
      let n = read(c, &chunk, chunk.count)
      if n <= 0 { close(c); return }
      buf.append(contentsOf: chunk[0..<n])
      while let nl = buf.firstIndex(of: 10) {
        let line = buf[buf.startIndex..<nl]
        buf = Data(buf[(nl + 1)...])
        guard let m = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let method = m["method"] as? String else { continue }
        let n = lock.withLock { () -> Int in let k = calls[method] ?? 0; calls[method] = k + 1; return k }
        let reply = answer(method, m["params"] as? [String: Any] ?? [:], n)
        guard let id = m["id"] else { continue }
        func send(_ obj: [String: Any]) {
          var d = try! JSONSerialization.data(withJSONObject: obj)
          d.append(10)
          _ = d.withUnsafeBytes { write(c, $0.baseAddress, d.count) }
        }
        switch reply {
        case .ok(let r): send(["jsonrpc": "2.0", "id": id, "result": r])
        case .fail(let e): send(["jsonrpc": "2.0", "id": id, "error": ["code": -32000, "message": e]])
        case .late(let s, let r):
          DispatchQueue.global().asyncAfter(deadline: .now() + s) { send(["jsonrpc": "2.0", "id": id, "result": r]) }
        }
      }
    }
  }
}

private func fakeSocket(_ tag: String) -> String { "/tmp/tdsm-\(getpid())-\(tag).sock" }

/// Answers for a project with three docs; `doc.open` gives each its path as text.
private func basic(_ m: String, _ p: [String: Any], _ n: Int) -> FakeEditorEngine.Reply {
  switch m {
  case "project.open":
    return .ok(["project_id": "p", "me": ["user_id": "u1"], "docs": ["a.tex", "b.tex", "c.tex"].map { ["path": $0, "doc_id": "id-" + $0] }])
  case "doc.open":
    let path = p["path"] as? String ?? ""
    return .ok(["doc_id": "id-" + path, "text": path + "\n", "seq": 0, "editable": true])
  case "doc.ranges": return .ok(["ranges": [], "seq": 0])
  case "thread.list": return .ok(["supported": true, "threads": []])
  case "project.status": return .ok(["connection": "online", "users": []])
  case "engine.info": return .ok(["instance": "i1"])
  default: return .ok([:])
  }
}

@MainActor private func until(_ seconds: Double, _ f: () -> Bool) async -> Bool {
  let end = Date().addingTimeInterval(seconds)
  while Date() < end {
    if f() { return true }
    try? await Task.sleep(for: .milliseconds(20))
  }
  return f()
}

private func tmpFolder() -> URL {
  let u = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tdsm-\(UUID().uuidString)")
  try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
  return u
}

/// A7: the engine isn't up when the window starts: the editor keeps trying, and opens the project once it is.
@MainActor @Test func nativeEditorRetriesAFailedStart() async throws {
  let sock = fakeSocket("a")
  unlink(sock)
  let ed = NativeEditor(folder: tmpFolder(), socket: URL(fileURLWithPath: sock))
  defer { ed.stop() }
  await #expect(throws: (any Error).self) { try await ed.start(main: "a.tex") }
  let engine = FakeEditorEngine(path: sock, answer: basic)
  engine.start()
  defer { engine.stop() }
  #expect(await until(6) { ed.projectID == "p" && ed.doc?.path == "a.tex" }, "never connected after the engine came up")
}

/// A7: after a restart, project.open fails once on the new (live) connection: the editor must try again, not sit
/// offline on an open socket.
@MainActor @Test func nativeEditorRetriesWhenProjectOpenFails() async throws {
  let sock = fakeSocket("b")
  let engine = FakeEditorEngine(path: sock) { m, p, n in m == "project.open" && n == 1 ? .fail("busy") : basic(m, p, n) }
  engine.start()
  defer { engine.stop() }
  let ed = NativeEditor(folder: tmpFolder(), socket: URL(fileURLWithPath: sock))
  defer { ed.stop() }
  try await ed.start(main: "a.tex")
  engine.dropClients()
  #expect(await until(6) { engine.count("project.open") >= 3 && ed.connection != "offline" && ed.conn?.closed == false },
          "stuck after a failed project.open: \(ed.connection), \(engine.count("project.open")) opens")
}

/// A7: two reconnects at once (the close's timer and a manual one) make one connection, not two.
@MainActor @Test func nativeEditorReconnectsOnce() async throws {
  let sock = fakeSocket("c")
  let engine = FakeEditorEngine(path: sock, answer: basic)
  engine.start()
  defer { engine.stop() }
  let ed = NativeEditor(folder: tmpFolder(), socket: URL(fileURLWithPath: sock))
  defer { ed.stop() }
  try await ed.start(main: "a.tex")
  #expect(engine.connected == 1)
  ed.conn?.close()
  async let x: Void = ed.reconnect()
  async let y: Void = ed.reconnect()
  _ = await (x, y)
  try? await Task.sleep(for: .milliseconds(1200))
  #expect(engine.connected == 2, "\(engine.connected) connections for one reconnect")
  #expect(engine.count("doc.subscribe") == 2, "the doc was reopened \(engine.count("doc.subscribe") - 1) times")
}

/// A8: opening b then c, b's answer coming last, shows c; two opens of one doc subscribe once.
@MainActor @Test func nativeEditorConcurrentOpens() async throws {
  let sock = fakeSocket("d")
  let engine = FakeEditorEngine(path: sock) { m, p, n in
    if m == "doc.open", p["path"] as? String == "b.tex" { return .late(0.4, ["doc_id": "id-b.tex", "text": "b.tex\n", "seq": 0]) }
    return basic(m, p, n)
  }
  engine.start()
  defer { engine.stop() }
  let ed = NativeEditor(folder: tmpFolder(), socket: URL(fileURLWithPath: sock))
  defer { ed.stop() }
  try await ed.start(main: "a.tex")
  async let b: Void = ed.open(path: "b.tex")
  try? await Task.sleep(for: .milliseconds(50))
  async let c: Void = ed.open(path: "c.tex")
  _ = try await (b, c)
  #expect(ed.current == "c.tex", "showing \(ed.current ?? "nil") after opening b then c")
  let before = engine.count("doc.subscribe")
  ed.stop()
  let ed2 = NativeEditor(folder: tmpFolder(), socket: URL(fileURLWithPath: sock))
  defer { ed2.stop() }
  try await ed2.start(main: "a.tex")
  let subs = engine.count("doc.subscribe")
  async let b1: Void = ed2.open(path: "b.tex")
  async let b2: Void = ed2.open(path: "b.tex")
  _ = try await (b1, b2)
  #expect(engine.count("doc.subscribe") - subs == 1, "b.tex subscribed \(engine.count("doc.subscribe") - subs) times")
  _ = before
}
