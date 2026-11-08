// A small `nvim --embed` client, enough for ReviewHost and the margin's tests: msgpack-RPC over stdio, no UI.
// The app uses TaudotNeovim's (shell's) instead; this one only exists so the margin can be built and tested alone.
import Foundation
import TaudotShared

public enum Msgpack {
  public static func encode(_ v: Value, into out: inout [UInt8]) {
    func be<T: FixedWidthInteger>(_ x: T) { withUnsafeBytes(of: x.bigEndian) { out += $0 } }
    switch v {
    case .null: out.append(0xc0)
    case let .bool(b): out.append(b ? 0xc3 : 0xc2)
    case let .int(i):
      if i >= 0 && i < 128 { out.append(UInt8(i)) }
      else if i < 0 && i >= -32 { out.append(UInt8(bitPattern: Int8(i))) }
      else { out.append(0xd3); be(i) }
    case let .float(d): out.append(0xcb); be(d.bitPattern)
    case let .string(s):
      let b = Array(s.utf8)
      if b.count < 32 { out.append(0xa0 | UInt8(b.count)) } else { out.append(0xdb); be(UInt32(b.count)) }
      out += b
    case let .binary(b): out.append(0xc6); be(UInt32(b.count)); out += b
    case let .array(a):
      if a.count < 16 { out.append(0x90 | UInt8(a.count)) } else { out.append(0xdd); be(UInt32(a.count)) }
      for x in a { encode(x, into: &out) }
    case let .map(m):
      if m.count < 16 { out.append(0x80 | UInt8(m.count)) } else { out.append(0xdf); be(UInt32(m.count)) }
      for (k, x) in m { encode(k, into: &out); encode(x, into: &out) }
    }
  }

  struct Short: Error {}

  /// Decode one value at `i`, advancing it. Throws Short when the bytes end first.
  static func decode(_ b: [UInt8], _ i: inout Int) throws -> Value {
    func need(_ n: Int) throws { if i + n > b.count { throw Short() } }
    func u(_ n: Int) throws -> UInt64 {
      try need(n)
      var x: UInt64 = 0
      for k in 0..<n { x = x << 8 | UInt64(b[i + k]) }
      i += n
      return x
    }
    func str(_ n: Int) throws -> Value {
      try need(n)
      let s = String(decoding: b[i..<(i + n)], as: UTF8.self)
      i += n
      return .string(s)
    }
    func arr(_ n: Int) throws -> Value { .array(try (0..<n).map { _ in try decode(b, &i) }) }
    func map(_ n: Int) throws -> Value { .map(try (0..<n).map { _ in (try decode(b, &i), try decode(b, &i)) }) }
    func ext(_ n: Int) throws -> Value {
      // Neovim's Buffer, Window, Tabpage: the handle as an int.
      try need(1 + n)
      i += 1
      var j = i
      let v = (try? decode(b, &j)) ?? .null
      i += n
      return v
    }
    try need(1)
    let t = b[i]
    i += 1
    switch t {
    case 0x00...0x7f: return .int(Int64(t))
    case 0x80...0x8f: return try map(Int(t & 0x0f))
    case 0x90...0x9f: return try arr(Int(t & 0x0f))
    case 0xa0...0xbf: return try str(Int(t & 0x1f))
    case 0xc0: return .null
    case 0xc2: return .bool(false)
    case 0xc3: return .bool(true)
    case 0xc4: return .binary(try { let n = Int(try u(1)); try need(n); defer { i += n }; return Array(b[i..<(i + n)]) }())
    case 0xc5: return .binary(try { let n = Int(try u(2)); try need(n); defer { i += n }; return Array(b[i..<(i + n)]) }())
    case 0xc6: return .binary(try { let n = Int(try u(4)); try need(n); defer { i += n }; return Array(b[i..<(i + n)]) }())
    case 0xc7: return try ext(Int(try u(1)))
    case 0xc8: return try ext(Int(try u(2)))
    case 0xc9: return try ext(Int(try u(4)))
    case 0xca: return .float(Double(Float(bitPattern: UInt32(try u(4)))))
    case 0xcb: return .float(Double(bitPattern: try u(8)))
    case 0xcc: return .int(Int64(try u(1)))
    case 0xcd: return .int(Int64(try u(2)))
    case 0xce: return .int(Int64(try u(4)))
    case 0xcf: return .int(Int64(bitPattern: try u(8)))
    case 0xd0: return .int(Int64(Int8(bitPattern: UInt8(try u(1)))))
    case 0xd1: return .int(Int64(Int16(bitPattern: UInt16(try u(2)))))
    case 0xd2: return .int(Int64(Int32(bitPattern: UInt32(try u(4)))))
    case 0xd3: return .int(Int64(bitPattern: try u(8)))
    case 0xd4: return try ext(1)
    case 0xd5: return try ext(2)
    case 0xd6: return try ext(4)
    case 0xd7: return try ext(8)
    case 0xd8: return try ext(16)
    case 0xd9: return try str(Int(try u(1)))
    case 0xda: return try str(Int(try u(2)))
    case 0xdb: return try str(Int(try u(4)))
    case 0xdc: return try arr(Int(try u(2)))
    case 0xdd: return try arr(Int(try u(4)))
    case 0xde: return try map(Int(try u(2)))
    case 0xdf: return try map(Int(try u(4)))
    default: return .int(Int64(Int8(bitPattern: t)))  // negative fixint
    }
  }

  /// Every complete value in `buf`; the rest stays.
  public static func drain(_ buf: inout [UInt8]) -> [Value] {
    var out: [Value] = []
    var i = 0
    while i < buf.count {
      var j = i
      guard let v = try? decode(buf, &j) else { break }
      out.append(v)
      i = j
    }
    if i > 0 { buf.removeFirst(i) }
    return out
  }
}

public struct NeovimError: Error, CustomStringConvertible {
  public let description: String
}

@MainActor public final class EmbeddedNeovim: NeovimBridge {
  private let process = Process()
  private let input = Pipe()
  private let output = Pipe()
  private var buffer: [UInt8] = []
  private var nextID: UInt32 = 1
  private var waiting: [UInt32: CheckedContinuation<Value, Error>] = [:]
  private var handlers: [String: [@MainActor ([Value]) -> Void]] = [:]
  public private(set) var channel: Int?
  public var onExit: (() -> Void)?

  /// Starts `nvim --embed --headless --clean` with `env` added to the environment and `rtp` prepended to runtimepath.
  public init(nvim: String = "nvim", args: [String] = ["--clean"], env: [String: String] = [:], cwd: URL? = nil) throws {
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    // (a watchdog: if this process dies without stop(), a crash or a test runner's kill, the Neovim it started
    // quits by itself once it has been re-parented, instead of spinning on its closed stdin)
    let watchdog = "lua local p = vim.uv.os_getppid(); local t = vim.uv.new_timer(); "
      + "t:start(1000, 1000, function() if vim.uv.os_getppid() ~= p then os.exit(0) end end)"
    process.arguments = [nvim, "--embed", "--headless", "-n", "--cmd", watchdog] + args  // -n: no swap files
    var e = ProcessInfo.processInfo.environment
    for (k, v) in env { e[k] = v }
    process.environment = e
    if let cwd { process.currentDirectoryURL = cwd }
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    output.fileHandleForReading.readabilityHandler = { [weak self] h in
      let d = h.availableData
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self?.received(d) }
      }
    }
    process.terminationHandler = { [weak self] _ in
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          guard let self else { return }
          for (_, c) in self.waiting { c.resume(throwing: NeovimError(description: "nvim exited")) }
          self.waiting = [:]
          self.onExit?()
        }
      }
    }
    try process.run()
  }

  public func stop() {
    output.fileHandleForReading.readabilityHandler = nil
    if process.isRunning { process.terminate() }
  }

  isolated deinit {
    if process.isRunning { process.terminate() }
  }

  private func received(_ d: Data) {
    if d.isEmpty { return }
    buffer += d
    for msg in Msgpack.drain(&buffer) {
      guard case let .array(a) = msg, let type = a.first?.int else { continue }
      if type == 1, a.count == 4, let id = a[1].int, let c = waiting.removeValue(forKey: UInt32(id)) {
        if a[2] != .null {
          let e = a[2].array.dropFirst().first?.string ?? a[2].string ?? "\(a[2])"
          c.resume(throwing: NeovimError(description: e))
        } else {
          c.resume(returning: a[3])
        }
      } else if type == 2, a.count == 3, let name = a[1].string {
        for h in handlers[name] ?? [] { h(a[2].array) }
      } else if type == 0, a.count == 4, let id = a[1].int {
        // We serve no requests.
        write(.array([.int(1), .int(Int64(id)), .string("not supported"), .null]))
      }
    }
  }

  private func write(_ v: Value) {
    var out: [UInt8] = []
    Msgpack.encode(v, into: &out)
    input.fileHandleForWriting.write(Data(out))
  }

  public func request(_ method: String, _ params: [Value]) async throws -> Value {
    let id = nextID
    nextID += 1
    return try await withCheckedThrowingContinuation { c in
      waiting[id] = c
      write(.array([.int(0), .int(Int64(id)), .string(method), .array(params)]))
    }
  }

  /// Our channel id (nvim_get_api_info).
  public func fetchChannel() async throws -> Int {
    let r = try await request("nvim_get_api_info", [])
    let c = r.array.first?.int ?? 0
    channel = c
    return c
  }

  // NeovimBridge
  public func notify(_ name: String, _ handler: @escaping @MainActor ([Value]) -> Void) {
    handlers[name, default: []].append(handler)
  }
  public func execLua(_ code: String, _ args: [Value]) async throws -> Value {
    try await request("nvim_exec_lua", [.string(code), .array(args)])
  }
  public func command(_ cmd: String) async throws {
    _ = try await request("nvim_command", [.string(cmd)])
  }
}
