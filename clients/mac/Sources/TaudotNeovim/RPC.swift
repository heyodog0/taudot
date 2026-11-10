// msgpack-RPC over a pair of file descriptors (nvim --embed's stdio).
import Foundation
import TaudotShared

public struct NeovimError: Error, CustomStringConvertible, Sendable {
  public let message: String
  public init(_ m: String) { message = m }
  public var description: String { message }
}

/// The transport. Thread-safe; incoming messages are handed to `onMessage` on the reader thread, in order.
public final class RPCConnection: @unchecked Sendable {
  public enum Incoming: Sendable {
    case notification(String, [Value])
    case request(id: UInt32, method: String, params: [Value])
  }

  private let lock = NSLock()
  private var nextID: UInt32 = 1
  private var pending: [UInt32: @Sendable (Result<Value, NeovimError>) -> Void] = [:]
  private let writeFD: Int32
  private let readFD: Int32
  private var closed = false
  /// Called on the reader thread for each notification or request.
  public var onMessage: (@Sendable (Incoming) -> Void)?
  /// Called once when the stream ends.
  public var onClose: (@Sendable () -> Void)?

  public init(readFD: Int32, writeFD: Int32) {
    self.readFD = readFD
    self.writeFD = writeFD
  }

  public func start() {
    let t = Thread { [self] in readLoop() }
    t.name = "nvim-rpc-reader"
    t.qualityOfService = .userInteractive
    t.start()
  }

  private func readLoop() {
    var dec = MsgPackDecoder()
    var chunk = [UInt8](repeating: 0, count: 1 << 16)
    while true {
      let n = chunk.withUnsafeMutableBytes { read(readFD, $0.baseAddress, $0.count) }
      if n <= 0 { if n < 0 && errno == EINTR { continue }; break }
      dec.feed(chunk[0..<n])
      do {
        while let v = try dec.next() { dispatch(v) }
      } catch {
        FileHandle.standardError.write("Taudot: msgpack decode error \(error)\n".data(using: .utf8)!)
        break
      }
    }
    lock.lock()
    closed = true
    let waiting = pending; pending = [:]
    lock.unlock()
    for (_, cb) in waiting { cb(.failure(NeovimError("nvim exited"))) }
    onClose?()
  }

  private func dispatch(_ v: Value) {
    guard let a = v.array, let type = a.first?.int else { return }
    switch type {
    case 1 where a.count == 4:
      guard let id = a[1].int else { return }
      lock.lock(); let cb = pending.removeValue(forKey: UInt32(id)); lock.unlock()
      if a[2] != .null { cb?(.failure(NeovimError(Self.errorText(a[2])))) } else { cb?(.success(a[3])) }
    case 2 where a.count == 3:
      onMessage?(.notification(a[1].string ?? "", a[2].array ?? []))
    case 0 where a.count == 4:
      onMessage?(.request(id: UInt32(a[1].int ?? 0), method: a[2].string ?? "", params: a[3].array ?? []))
    default: break
    }
  }

  static func errorText(_ e: Value) -> String {
    if let s = e[1]?.string { return s }
    if let s = e.string { return s }
    return "\(e)"
  }

  private func write(_ bytes: [UInt8]) {
    bytes.withUnsafeBytes { raw in
      var off = 0
      while off < raw.count {
        let n = Foundation.write(writeFD, raw.baseAddress! + off, raw.count - off)
        if n < 0 { if errno == EINTR { continue }; return }
        off += n
      }
    }
  }

  /// Send a request; `done` runs on the reader thread.
  public func request(_ method: String, _ params: [Value], _ done: @escaping @Sendable (Result<Value, NeovimError>) -> Void) {
    lock.lock()
    if closed { lock.unlock(); done(.failure(NeovimError("nvim exited"))); return }
    let id = nextID; nextID &+= 1
    pending[id] = done
    write(MsgPack.encode(.array([.int(0), .int(Int64(id)), .string(method), .array(params)])))
    lock.unlock()
  }

  public func request(_ method: String, _ params: [Value]) async throws -> Value {
    try await withCheckedThrowingContinuation { (c: CheckedContinuation<Value, Error>) in
      request(method, params) { c.resume(with: $0.mapError { $0 as Error }) }
    }
  }

  public func notify(_ method: String, _ params: [Value]) {
    lock.lock()
    if !closed { write(MsgPack.encode(.array([.int(2), .string(method), .array(params)]))) }
    lock.unlock()
  }

  public func respond(_ id: UInt32, error: Value = .null, result: Value = .null) {
    lock.lock()
    write(MsgPack.encode(.array([.int(1), .int(Int64(id)), error, result])))
    lock.unlock()
  }
}

/// `nvim --embed` as a child process.
public final class NeovimProcess: @unchecked Sendable {
  public let process = Process()
  public let rpc: RPCConnection

  /// `args` are passed after `--embed`. `cwd` is the working directory.
  public init(nvim: String? = nil, args: [String] = [], cwd: URL? = nil, env: [String: String] = [:]) throws {
    let exe = nvim ?? NeovimProcess.findNvim()
    let toChild = Pipe(), fromChild = Pipe()
    process.executableURL = URL(fileURLWithPath: exe)
    process.arguments = ["--embed", "--cmd", "lua " + NeovimProcess.watchdogLua] + args
    if let cwd { process.currentDirectoryURL = cwd }
    var e = ProcessInfo.processInfo.environment
    for (k, v) in env { e[k] = v }
    process.environment = e
    process.standardInput = toChild
    process.standardOutput = fromChild
    rpc = RPCConnection(readFD: fromChild.fileHandleForReading.fileDescriptor, writeFD: toChild.fileHandleForWriting.fileDescriptor)
    try process.run()
    // Keep the pipes alive with the process.
    pipes = (toChild, fromChild)
    rpc.start()
  }
  private var pipes: (Pipe, Pipe)?

  public func terminate() { if process.isRunning { process.terminate() } }

  /// SIGKILL: for a Neovim stuck in Lua, which handles SIGTERM only between events.
  public func kill() { if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) } }

  /// Neovim ends with us. It exits by itself when its stdin closes, but only between events: stuck in a Lua loop it
  /// would spin at 100% CPU for good, ignoring SIGTERM too. So a thread of its own (a luv thread: its own Lua state,
  /// which the main one can't block) waits in kqueue for our exit (no wake-ups until then) and SIGKILLs it. macOS;
  /// elsewhere nothing. One line: `--cmd "lua …"` runs it before any config, `--clean` too.
  static let watchdogLua = [
    "pcall(function()",
    "if not (jit and jit.os == 'OSX' and vim.uv.new_thread) then return end",
    "vim.uv.new_thread(function(parent)",
    "local ffi = require('ffi')",
    "ffi.cdef([[",
    "struct taudot_kevent { uintptr_t ident; int16_t filter; uint16_t flags; uint32_t fflags; intptr_t data; void *udata; };",
    "int kqueue(void);",
    "int kevent(int kq, const struct taudot_kevent *ch, int nch, struct taudot_kevent *ev, int nev, const void *timeout);",
    "int kill(int pid, int sig); int getpid(void);",
    "]])",
    "local C = ffi.C",
    "local kq = C.kqueue()",
    "if kq < 0 then return end",
    "local ch = ffi.new('struct taudot_kevent[1]')",
    // EVFILT_PROC, EV_ADD | EV_ONESHOT, NOTE_EXIT
    "ch[0].ident = parent; ch[0].filter = -5; ch[0].flags = 0x11; ch[0].fflags = 0x80000000",
    // ESRCH: we are gone already; EINTR: wait again; any other error: leave Neovim alone
    "if C.kevent(kq, ch, 1, nil, 0, nil) < 0 then if ffi.errno() ~= 3 then return end",
    "else local ev = ffi.new('struct taudot_kevent[1]')",
    "while C.kevent(kq, nil, 0, ev, 1, nil) < 0 do if ffi.errno() ~= 4 then return end end end",
    "C.kill(C.getpid(), 9)",
    "end, vim.uv.os_getppid())",
    "end)",
  ].joined(separator: " ")

  /// $TAUDOT_NVIM, else the app bundle's Neovim, else nvim on PATH, else the usual Homebrew places. A GUI app
  /// launched from Finder has a minimal PATH.
  public static func findNvim() -> String {
    if let n = ProcessInfo.processInfo.environment["TAUDOT_NVIM"] { return n }
    if let n = BundledTools.nvim { return n.path }
    let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
    let dirs = path.split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
    for d in dirs {
      let p = d + "/nvim"
      if FileManager.default.isExecutableFile(atPath: p) { return p }
    }
    return "/opt/homebrew/bin/nvim"
  }
}
