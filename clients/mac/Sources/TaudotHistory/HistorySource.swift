// Where the History view gets its data: the engine's history.* methods (docs/api.md, History), behind a protocol so
// tests can hand the views canned versions.
import Foundation
import TaudotPDF

@MainActor public protocol HistorySource: AnyObject {
  func updates(before: Int?) async throws -> UpdatesPage
  func labels() async throws -> [HistoryLabel]
  func tree(_ r: HistoryRange) async throws -> [HistoryFile]
  func diff(path: String, _ r: HistoryRange) async throws -> HistoryDiff
  /// A file's text at a version (nil: a binary file, which history doesn't serve).
  func file(path: String, version: Int) async throws -> String?
}

/// The engine over its socket. Opens the project for the folder first (`project.open {folder}`: the one already
/// open, as the editor opened it).
@MainActor public final class EngineHistorySource: HistorySource {
  public let socket: URL
  public let folder: URL
  private var conn: JSONRPCConnection?
  public private(set) var projectID: String?
  /// Groups per page.
  public var pageSize = 30

  public init(socket: URL, folder: URL) {
    self.socket = socket
    self.folder = folder
  }

  func call(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
    let c: JSONRPCConnection
    if let ok = conn, !ok.closed {
      c = ok
    } else {
      c = try JSONRPCConnection(socket: socket.path)
      c.onClose = { [weak self] in self?.conn = nil }
      conn = c
    }
    if projectID == nil {
      let r = try await c.call("project.open", ["folder": folder.path])
      projectID = r["project_id"] as? String
    }
    guard let pid = projectID else { throw HistoryError(description: "the engine didn't name the project") }
    var p = params
    p["project_id"] = pid
    return try await c.call(method, p)
  }

  public func updates(before: Int?) async throws -> UpdatesPage {
    var p: [String: Any] = ["min_count": pageSize]
    if let before { p["before"] = before }
    return UpdatesPage(try await call("history.updates", p))
  }

  public func labels() async throws -> [HistoryLabel] {
    ((try await call("history.labels", [:]))["labels"] as? [[String: Any]] ?? []).compactMap(HistoryLabel.init)
  }

  public func tree(_ r: HistoryRange) async throws -> [HistoryFile] {
    ((try await call("history.tree", ["from": r.fromV, "to": r.toV]))["files"] as? [[String: Any]] ?? []).compactMap(HistoryFile.init)
  }

  public func diff(path: String, _ r: HistoryRange) async throws -> HistoryDiff {
    HistoryDiff(try await call("history.diff", ["path": path, "from": r.fromV, "to": r.toV]))
  }

  public func file(path: String, version: Int) async throws -> String? {
    let r = try await call("history.file", ["path": path, "version": version])
    return r["binary"] as? Bool == true ? nil : r["text"] as? String ?? ""
  }

  public func close() {
    conn?.close()
    conn = nil
  }
}

public struct HistoryError: Error, CustomStringConvertible {
  public var description: String
  public init(description: String) { self.description = description }
}
