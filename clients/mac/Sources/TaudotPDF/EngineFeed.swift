// Live edits from the taudot engine (docs/api.md): project.open by folder, doc.open + doc.subscribe per .tex doc,
// each doc.changed edit handed on as it arrives (UTF-8 byte offsets on both sides, so it maps one to one).
import Foundation

/// A JSON-RPC 2.0 connection over a Unix socket, one JSON object per line. Callbacks on the main actor.
@MainActor public final class JSONRPCConnection {
  private let fd: Int32
  private let read: FileHandle
  private var waiting: [Int: CheckedContinuation<JSONObject, Error>] = [:]
  private var nextId = 0
  public var onNotification: ((String, [String: Any]) -> Void)?
  public var onClose: (() -> Void)?
  public private(set) var closed = false

  public struct RPCError: Error, CustomStringConvertible { public var description: String }

  public init(socket path: String) throws {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw RPCError(description: "socket: \(errno)") }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw RPCError(description: "path too long") }
    withUnsafeMutableBytes(of: &addr.sun_path) { p in
      for (i, b) in bytes.enumerated() { p[i] = b }
      p[bytes.count] = 0
    }
    let r = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard r == 0 else {
      let e = errno
      Darwin.close(fd)
      throw RPCError(description: "connect \(path): \(String(cString: strerror(e)))")
    }
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    self.fd = fd
    read = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    let box = LineBuffer()
    read.readabilityHandler = { [weak self] h in
      let d = h.availableData
      if d.isEmpty {
        h.readabilityHandler = nil
        DispatchQueue.main.async { MainActor.assumeIsolated { self?.didClose() } }
        return
      }
      let lines = box.take(d)
      guard !lines.isEmpty else { return }
      DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(lines) } }
    }
  }

  private func handle(_ lines: [Data]) {
    for l in lines {
      if closed { return }  // read before a close, handled after it: nobody is listening any more
      guard let m = try? JSONSerialization.jsonObject(with: l) as? [String: Any] else { continue }
      if let id = m["id"] as? Int, m["method"] == nil {
        guard let c = waiting.removeValue(forKey: id) else { continue }
        if let e = m["error"] as? [String: Any] { c.resume(throwing: RPCError(description: e["message"] as? String ?? "error")) }
        else { c.resume(returning: JSONObject(m["result"] as? [String: Any] ?? [:])) }
      } else if let method = m["method"] as? String {
        onNotification?(method, m["params"] as? [String: Any] ?? [:])
      }
    }
  }

  private func didClose() {
    guard !closed else { return }
    closed = true
    for (_, c) in waiting { c.resume(throwing: RPCError(description: "connection closed")) }
    waiting = [:]
    Darwin.close(fd)
    onClose?()
  }

  public func close() {
    read.readabilityHandler = nil
    shutdown(fd, SHUT_RDWR)
    didClose()
  }

  public func call(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
    if closed { throw RPCError(description: "connection closed") }
    nextId += 1
    let id = nextId
    var line = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params])
    line.append(0x0A)
    return try await withCheckedThrowingContinuation { c in
      waiting[id] = c
      let ok = line.withUnsafeBytes { p -> Bool in
        var off = 0
        while off < p.count {
          let n = Darwin.write(fd, p.baseAddress! + off, p.count - off)
          if n <= 0 { return false }
          off += n
        }
        return true
      }
      if !ok { waiting.removeValue(forKey: id)?.resume(throwing: RPCError(description: "write failed")) }
    }.v
  }
}

/// A JSON object handed across a continuation (only ever touched on the main actor).
struct JSONObject: @unchecked Sendable {
  var v: [String: Any]
  init(_ v: [String: Any]) { self.v = v }
}

final class LineBuffer: @unchecked Sendable {
  private var buf = Data()
  func take(_ d: Data) -> [Data] {
    buf.append(d)
    var out: [Data] = []
    while let nl = buf.firstIndex(of: 0x0A) {
      out.append(Data(buf[buf.startIndex..<nl]))
      buf.removeSubrange(buf.startIndex...nl)
    }
    return out
  }
}

/// Feeds the engine's live edits of every .tex doc of a folder's project into a sink. Reconnects every 2 s while the
/// engine isn't there. `liveDocs` are the paths it serves (relative to the folder): their file saves can be ignored.
@MainActor public final class EngineFeed {
  public struct Sink {
    public var open: @MainActor (_ path: String, _ text: String) -> Void
    public var change: @MainActor (_ path: String, _ pos: Int, _ del: Int, _ ins: String) -> Void
  }
  let socket: String
  let folder: URL
  let sink: Sink
  private var conn: JSONRPCConnection?
  private var projectId = ""
  private var paths: [String: String] = [:]  // doc_id → path
  /// The seq each doc's text is at here: a `doc.changed` at or below it was already applied (the engine replays from
  /// `since_seq` on subscribe and may also send the same change live, docs/api.md; a reopen while someone types does
  /// that) and is dropped, or TeXpresso and the pane's copy would get it twice.
  private var seqs: [String: Int] = [:]
  /// Changes dropped as already applied (for the pane's self-check).
  public private(set) var duplicates = 0
  private var stopped = false
  public private(set) var liveDocs: Set<String> = []
  public var onNote: ((String) -> Void)?
  /// Time of the last doc.changed handed on (for latency traces).
  public var onEdit: ((String) -> Void)?
  /// project.open's compile settings (`pdflatex`, `texlive-full:2026.1`; empty when the engine doesn't say), before
  /// the docs are opened: the pane picks its typesetter here.
  public var onProject: ((_ compiler: String, _ image: String) -> Void)?

  public init(socket: String, folder: URL, sink: Sink) {
    self.socket = socket
    self.folder = folder
    self.sink = sink
  }

  public func start() { Task { await self.loop() } }

  public func stop() {
    stopped = true
    conn?.close()
  }

  /// This attempt got through project.open (the engine is there).
  private var opened = false

  private func loop() async {
    while !stopped {
      opened = false
      do { try await runOnce() } catch { onNote?("engine: \(error)") }
      // a dropped connection (an engine restart) keeps `liveDocs`: its last mirror writes may still arrive as file
      // events, and must not be taken for an editor's saves. Only an engine that isn't there clears them.
      if !opened { liveDocs = [] }
      paths = [:]
      seqs = [:]
      if stopped { return }
      try? await Task.sleep(for: .seconds(2))
    }
  }

  private func runOnce() async throws {
    let c = try JSONRPCConnection(socket: socket)
    conn = c
    let closed = AsyncStream<Void> { cont in c.onClose = { cont.finish() } }
    c.onNotification = { [weak self, weak c] method, p in
      // only the current connection's, and none once stopped (the pane closed or moved to another folder)
      guard let self, !self.stopped, let c, c === self.conn else { return }
      self.notification(method, p)
    }
    let info = try await c.call("project.open", ["folder": folder.path])
    projectId = info["project_id"] as? String ?? ""
    opened = true
    onProject?(info["compiler"] as? String ?? "", info["image"] as? String ?? "")
    var live: Set<String> = []
    for d in info["docs"] as? [[String: Any]] ?? [] {
      guard let id = d["doc_id"] as? String, let path = d["path"] as? String, path.hasSuffix(".tex") else { continue }
      let rel = path.hasPrefix("/") ? String(path.dropFirst()) : path
      paths[id] = rel
      live.insert(rel)
    }
    liveDocs = live
    try await reopen()
    onNote?("engine: live edits (\(paths.count) docs)")
    for await _ in closed {}
  }

  /// The reopen pass running, and whether another was asked for while it ran.
  private var reopening: Task<Void, Error>?
  private var reopenWanted = false

  /// Opens every doc again and sends its whole text (after a restart of TeXpresso, or engine.lagged). Asked again
  /// while a pass runs: one more pass after it (not one per ask); every caller returns once the passes are done.
  public func reopen() async throws {
    reopenWanted = true
    if let t = reopening { return try await t.value }
    let t = Task { @MainActor in
      defer { self.reopening = nil }
      do {
        while self.reopenWanted, !self.stopped {
          self.reopenWanted = false
          try await self.reopenOnce()
        }
      } catch {
        self.reopenWanted = false  // the connection went: the next one opens every doc anyway
        throw error
      }
    }
    reopening = t
    try await t.value
  }

  private func reopenOnce() async throws {
    guard let c = conn, !c.closed else { return }
    for (id, path) in paths.sorted(by: { $0.value < $1.value }) {
      guard c === conn, !stopped else { return }
      let d = try await c.call("doc.open", ["project_id": projectId, "path": path])
      let seq = d["seq"] as? Int ?? 0
      seqs[id] = seq
      sink.open(path, d["text"] as? String ?? "")
      _ = try await c.call("doc.subscribe", ["doc_id": id, "since_seq": seq])
    }
  }

  /// The engine's text of a doc and its seq (for the pane's self-check).
  public func docText(_ path: String) async -> (text: String, seq: Int)? {
    guard let c = conn, !c.closed, paths.values.contains(path),
      let d = try? await c.call("doc.open", ["project_id": projectId, "path": path]), let t = d["text"] as? String
    else { return nil }
    return (t, d["seq"] as? Int ?? -1)
  }

  private func notification(_ method: String, _ p: [String: Any]) {
    switch method {
    case "doc.changed":
      guard let id = p["doc_id"] as? String, let path = paths[id] else { return }
      if let seq = p["seq"] as? Int {
        guard let have = seqs[id] else { return }  // not open yet: doc.open's text will include it
        if seq <= have { duplicates += 1; return }
        seqs[id] = seq
      }
      for e in p["edits"] as? [[String: Any]] ?? [] {
        sink.change(path, e["pos"] as? Int ?? 0, e["del"] as? Int ?? 0, e["ins"] as? String ?? "")
      }
      onEdit?(path)
    case "engine.lagged":
      Task { try? await self.reopen() }
    default: break
    }
  }
}
