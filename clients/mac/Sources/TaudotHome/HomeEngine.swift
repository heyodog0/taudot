// The home window's connection to the taudot engine: account.*, projects.list, project.clone, project.forget
// (docs/api.md, Accounts and projects). Starts the engine when nothing listens on its socket, as the CLI does.
import Foundation
import TaudotPDF
import TaudotShared

@MainActor public final class HomeEngine {
  public let socket: URL
  private var conn: JSONRPCConnection?
  /// `clone.progress` notifications.
  public var onCloneProgress: (([String: Any]) -> Void)?

  public init(socket: URL) { self.socket = socket }

  public struct Failure: Error, CustomStringConvertible { public var description: String }

  public func call(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
    let c = try await connection()
    return try await c.call(method, params)
  }

  private func connection() async throws -> JSONRPCConnection {
    if let c = conn, !c.closed { return c }
    let c: JSONRPCConnection
    if let ok = try? JSONRPCConnection(socket: socket.path) {
      c = ok
    } else {
      try await startEngine()
      c = try JSONRPCConnection(socket: socket.path)
    }
    c.onNotification = { [weak self] method, params in
      if method == "clone.progress" { self?.onCloneProgress?(params) }
    }
    c.onClose = { [weak self] in self?.conn = nil }
    conn = c
    return c
  }

  /// `taudot rpc engine.info` starts the engine (launchd service or a detached `taudot serve`) and waits for it.
  private func startEngine() async throws {
    // The bundle's engine: its launch agent is installed or repointed at launch (BundledTools.ensured), which also
    // starts it.
    if await BundledTools.ensured.value != nil, (try? JSONRPCConnection(socket: socket.path)) != nil { return }
    guard let bin = HomeEngine.taudotBinary() else {
      throw Failure(description: "The sync engine isn't running and the taudot command wasn't found. Run ./install.sh in the taudot folder.")
    }
    let home = socket.deletingLastPathComponent().path
    let status: Int32 = try await withCheckedThrowingContinuation { cont in
      let p = Process()
      p.executableURL = bin
      p.arguments = ["rpc", "--home", home, "engine.info"]
      p.standardOutput = FileHandle.nullDevice
      p.standardError = FileHandle.nullDevice
      p.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
      do { try p.run() } catch { cont.resume(throwing: error) }
    }
    if status != 0 { throw Failure(description: "Couldn't start the sync engine; see \(home)/logs/engine.log.") }
  }

  /// `$TAUDOT_BIN/taudot`, the app bundle's, `~/.local/bin/taudot` (install.sh), Homebrew's and /usr/local's bin,
  /// then `$PATH`.
  public static func taudotBinary() -> URL? {
    let env = ProcessInfo.processInfo.environment
    if env["TAUDOT_BIN"] == nil, let b = BundledTools.engine { return b }
    var dirs = [env["TAUDOT_BIN"], NSHomeDirectory() + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"].compactMap { $0 }
    dirs += (env["PATH"] ?? "").split(separator: ":").map(String.init)
    // `texsync` is the engine's name before the rename (2026-11-04): an older install still works.
    for name in ["taudot", "texsync"] {
      for d in dirs {
        let u = URL(fileURLWithPath: d).appendingPathComponent(name)
        if FileManager.default.isExecutableFile(atPath: u.path) { return u }
      }
    }
    return nil
  }

  public func close() { conn?.close(); conn = nil }
}
