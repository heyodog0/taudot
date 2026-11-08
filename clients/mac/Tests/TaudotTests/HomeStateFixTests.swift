// statefix A22: the home window's sign-in state with answers arriving out of order.
import AppKit
import Foundation
import Testing
@testable import TaudotHome

/// A fake engine on a unix socket, newline-delimited JSON-RPC: each method answers after its own delay, from a
/// thread of its own, so answers can overtake each other.
final class FakeHomeEngine: @unchecked Sendable {
  let path: String
  let answers: [String: (delay: Double, result: [String: Any])]
  private var fd: Int32 = -1
  init(_ answers: [String: (delay: Double, result: [String: Any])]) throws {
    self.answers = answers
    path = NSTemporaryDirectory() + "home-fake-\(getpid())-\(Int.random(in: 0..<1_000_000)).sock"
    unlink(path)
    fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var a = sockaddr_un()
    a.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &a.sun_path) { b in _ = path.utf8CString.withUnsafeBytes { memcpy(b.baseAddress!, $0.baseAddress!, min(b.count, $0.count)) } }
    let ok = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    guard ok == 0, listen(fd, 4) == 0 else { throw CocoaError(.fileWriteUnknown) }
    let lfd = fd
    Thread.detachNewThread { [self] in
      while true {
        let c = accept(lfd, nil, nil)
        if c < 0 { return }
        Thread.detachNewThread { self.serve(c) }
      }
    }
  }
  private func serve(_ c: Int32) {
    let wlock = NSLock()
    var buf = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
      let n = read(c, &chunk, chunk.count)
      if n <= 0 { close(c); return }
      buf.append(contentsOf: chunk[0..<n])
      while let nl = buf.firstIndex(of: 10) {
        let line = buf[buf.startIndex..<nl]
        buf = Data(buf[(nl + 1)...])
        guard let m = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let id = m["id"], let method = m["method"] as? String else { continue }
        let ans = answers[method] ?? (0, [:])
        let reply = try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": ans.result]) + Data([10])
        DispatchQueue.global().asyncAfter(deadline: .now() + ans.delay) {
          wlock.lock(); defer { wlock.unlock() }
          _ = reply.withUnsafeBytes { write(c, $0.baseAddress!, reply.count) }
        }
      }
    }
  }
  func stop() { close(fd); unlink(path) }
}

/// A22: the launch's account.status (signed out, slow) answering after a sign-in that already succeeded must not sign
/// the window out again.
@MainActor @Test func a22LateStatusDoesNotUndoASignIn() async throws {
  let e = try FakeHomeEngine([
    "account.status": (0.5, ["logged_in": false]),
    "account.login": (0, ["logged_in": true, "user_id": "u1", "email": "me@example.com"]),
    "projects.list": (0, ["projects": []]),
  ])
  defer { e.stop() }
  let h = HomeWindow(socket: URL(fileURLWithPath: e.path), server: "http://localhost:1")
  var states: [String] = []
  h.onState = { states.append($0) }
  h.check()
  try? await Task.sleep(for: .milliseconds(100))
  let err = await h.signIn(cookie: "c")
  #expect(err == nil)
  #expect(h.window.title == "Projects")
  try? await Task.sleep(for: .milliseconds(800))
  #expect(h.window.title == "Projects", "still signed in after the late status (states: \(states))")
  #expect(!states.contains("signedOut"))
}

/// A23: the project opened in a window while "Remove the local copy?" is up: Move to Trash then does nothing (the
/// folder stays, the engine isn't told to forget it).
@MainActor @Test func a23RemoveLocalRechecksOpen() async throws {
  let e = try FakeHomeEngine([
    "project.forget": (0, [:]),
    "projects.list": (0, ["projects": []]),
  ])
  defer { e.stop() }
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("a23-\(getpid())-\(Int.random(in: 0..<1_000_000))")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: dir) }
  let h = HomeWindow(socket: URL(fileURLWithPath: e.path), server: "http://localhost:1")
  var open = false
  h.isOpen = { _ in open }
  var answer: ((Bool) -> Void)?
  h.confirm = { _, done in answer = done }
  let p = HomeProject(id: "p1", name: "Paper", ownerName: "Me", lastUpdated: nil, accessLevel: "owner", archived: false,
                      trashed: false, localFolder: dir.path, lastOpened: nil)
  h.removeLocal(p)
  #expect(answer != nil, "asked")
  open = true  // opened from Finder meanwhile
  answer?(true)
  try? await Task.sleep(for: .milliseconds(500))
  #expect(FileManager.default.fileExists(atPath: dir.path), "the open project's folder is not trashed")
}
