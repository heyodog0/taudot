// The embedded Neovim as the app sees it: NeovimBridge, plus the redraw stream for the editor view.
import Foundation
import TaudotShared

@MainActor public final class Neovim: NeovimBridge {
  public let rpc: RPCConnection
  let process: NeovimProcess?
  private var handlers: [String: [@MainActor ([Value]) -> Void]] = [:]
  /// Each `redraw` notification's batches, in order, on the main actor.
  public var onRedraw: (([Value]) -> Void)?
  /// The process exited (or the stream closed).
  public var onExit: (() -> Void)?

  /// Start `nvim --embed`.
  public convenience init(args: [String] = [], cwd: URL? = nil, env: [String: String] = [:], nvim: String? = nil) throws {
    let p = try NeovimProcess(nvim: nvim, args: args, cwd: cwd, env: env)
    self.init(rpc: p.rpc, process: p)
  }

  /// Wrap an existing connection (tests).
  public init(rpc: RPCConnection, process: NeovimProcess? = nil) {
    self.rpc = rpc
    self.process = process
    rpc.onMessage = { [weak self] msg in
      DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(msg) } }
    }
    rpc.onClose = { [weak self] in
      DispatchQueue.main.async { MainActor.assumeIsolated { self?.onExit?() } }
    }
  }

  private func handle(_ msg: RPCConnection.Incoming) {
    if Self.stats != nil { Self.count(msg) }
    switch msg {
    case .notification("redraw", let batches):
      onRedraw?(batches)
    case .notification(let name, let args):
      for h in handlers[name] ?? [] { h(args) }
    case .request(let id, let method, _):
      rpc.respond(id, error: .string("Taudot: no handler for \(method)"))
    }
  }

  // MARK: NeovimBridge

  public func notify(_ name: String, _ handler: @escaping @MainActor ([Value]) -> Void) {
    handlers[name, default: []].append(handler)
  }

  public func execLua(_ code: String, _ args: [Value]) async throws -> Value {
    if Self.stats != nil { Self.bump("> lua " + code.prefix(60).replacingOccurrences(of: "\n", with: " ")) }
    return     try await rpc.request("nvim_exec_lua", [.string(code), .array(args)])
  }

  public func command(_ cmd: String) async throws {
    _ = try await rpc.request("nvim_command", [.string(cmd)])
  }

  // MARK: more

  public func request(_ method: String, _ params: [Value]) async throws -> Value {
    if Self.stats != nil { Self.bump("> " + method) }
    return     try await rpc.request(method, params)
  }

  /// Fire-and-forget request (errors are logged): input and resize must not wait.
  public func send(_ method: String, _ params: [Value]) {
    if Self.stats != nil { Self.bump("> " + method) }
    rpc.request(method, params) { r in
      if case .failure(let e) = r { FileHandle.standardError.write("Taudot: \(method): \(e)\n".data(using: .utf8)!) }
    }
  }

  /// Our channel id, so Lua can `vim.rpcnotify` us.
  public func channelID() async throws -> Int {
    let info = try await rpc.request("nvim_get_api_info", [])
    return info[0]?.int ?? 0
  }

  public func input(_ keys: String) { send("nvim_input", [.string(keys)]) }

  public func terminate() { process?.terminate() }
  /// SIGKILL (a Neovim stuck in Lua ignores SIGTERM).
  public func kill() { process?.kill() }

  // MARK: TAUDOT_RPCSTATS=1: what goes over the wire, per kind, every 5 s on stderr (finding what runs at rest).

  static var stats: [String: Int]? = ProcessInfo.processInfo.environment["TAUDOT_RPCSTATS"] != nil ? [:] : nil
  static var statsTimer: Timer?
  static func bump(_ k: String) {
    stats?[k, default: 0] += 1
    guard statsTimer == nil else { return }
    statsTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
      MainActor.assumeIsolated {
        let s = (stats ?? [:]).sorted { $0.value > $1.value }.map { "  \($0.value)\t\($0.key)" }.joined(separator: "\n")
        FileHandle.standardError.write("taudot rpc (5 s):\n\(s)\n".data(using: .utf8)!)
        stats = [:]
      }
    }
  }
  static func count(_ msg: RPCConnection.Incoming) {
    switch msg {
    case .notification("redraw", let batches):
      bump("< redraw")
      for b in batches { if let n = b.array?.first?.string { bump("<   " + n) } }
    case .notification(let name, _): bump("< " + name)
    case .request(_, let method, _): bump("< request " + method)
    }
  }
}
