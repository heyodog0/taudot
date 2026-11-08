// A version of the project on disk, for its PDF: every file as it was at the version, in a folder of its own that
// never changes once made (so its typesetting can be kept with it). Text comes from history; a file that hasn't
// changed since is copied from the project folder instead (no request). Binary files (figures) changed since come
// from history's blobs by hash (docs/history.md), else the version's zip, else they're today's copies.
import CryptoKit
import Foundation

/// A change of a diff at its place in the version's text (the range's end): 1-based lines, UTF-8 byte columns, the
/// end exclusive. A deletion is a place (end == start). Leading and trailing whitespace of an insertion is left out
/// of its place (it isn't on the page).
public struct VersionChange: Sendable, Equatable {
  /// Its index in `HistoryDiff.changes`.
  public var index: Int
  public var kind: HistoryDiff.Kind
  public var line: Int
  public var column: Int
  public var endLine: Int
  public var endColumn: Int
  public var text: String
  public var user: HistoryUser?
  public var time: Date?
}

extension HistoryDiff {
  /// The text at the range's end (what isn't deleted) and where each change is in it. Insertions of nothing but
  /// whitespace aren't listed (nothing to mark on the page).
  public func version() -> (text: String, changes: [VersionChange]) {
    let ns = text as NSString
    var out = ""
    var line = 1, col = 0
    func step(_ s: Substring.UTF8View, _ l: inout Int, _ c: inout Int) {
      for b in s { if b == 0x0A { l += 1; c = 0 } else { c += 1 } }
    }
    var changes: [VersionChange] = []
    var k = 0
    for ch in chunks {
      let s = ns.substring(with: ch.range)
      switch ch.kind {
      case .same:
        out += s
        step(Substring(s).utf8, &line, &col)
      case .insert:
        let core = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if !core.isEmpty, let r = s.range(of: core) {
          var l0 = line, c0 = col
          step(s[..<r.lowerBound].utf8, &l0, &c0)
          var l1 = l0, c1 = c0
          step(s[r].utf8, &l1, &c1)
          changes.append(VersionChange(index: k, kind: .insert, line: l0, column: c0, endLine: l1, endColumn: c1,
                                       text: s, user: ch.user, time: ch.time))
        }
        out += s
        step(Substring(s).utf8, &line, &col)
        k += 1
      case .delete:
        changes.append(VersionChange(index: k, kind: .delete, line: line, column: col, endLine: line, endColumn: col,
                                     text: s, user: ch.user, time: ch.time))
        k += 1
      }
    }
    return (out, changes)
  }
}

/// A file of the project at a version as history stores it: its blob's hash (git's blob SHA-1), nil for text edited
/// since it was added. `kind`: "binary", "text" or "unknown".
public struct VersionBlob: Sendable, Equatable {
  public var path: String
  public var hash: String?
  public var kind: String
  public init(path: String, hash: String?, kind: String) {
    self.path = path
    self.hash = hash
    self.kind = kind
  }
}

/// Binary files at a version (`history.files_at`, `history.blob`, `history.zip_files`; docs/api.md, History).
@MainActor public protocol HistoryBlobSource: AnyObject {
  /// Every file at the version with its hash.
  func filesAt(version: Int) async throws -> [VersionBlob]
  /// The blob's file on disk (the engine's store, shared by every version and project).
  func blob(hash: String) async throws -> URL
  /// The fallback: `paths` out of the version's zip, each a file on disk (missing ones left out).
  func zipFiles(version: Int, paths: [String]) async throws -> [String: URL]
}

extension EngineHistorySource: HistoryBlobSource {
  public func filesAt(version: Int) async throws -> [VersionBlob] {
    let r = try await call("history.files_at", ["version": version])
    return (r["files"] as? [[String: Any]] ?? []).compactMap { f in
      (f["path"] as? String).map { VersionBlob(path: $0, hash: f["hash"] as? String, kind: f["kind"] as? String ?? "unknown") }
    }
  }

  public func blob(hash: String) async throws -> URL {
    let r = try await call("history.blob", ["hash": hash])
    guard let f = r["file"] as? String else { throw HistoryError(description: "no file for blob \(hash)") }
    return URL(fileURLWithPath: f)
  }

  public func zipFiles(version: Int, paths: [String]) async throws -> [String: URL] {
    let r = try await call("history.zip_files", ["version": version, "paths": paths])
    var out: [String: URL] = [:]
    for f in r["files"] as? [[String: Any]] ?? [] {
      if let p = f["path"] as? String, let file = f["file"] as? String { out[p] = URL(fileURLWithPath: file) }
    }
    return out
  }
}

/// The hash history gives a file's bytes: git's blob SHA-1 (`blob <length>\0` then the bytes).
public func blobHash(_ data: Data) -> String {
  var h = Insecure.SHA1()
  h.update(data: Data("blob \(data.count)\0".utf8))
  h.update(data: data)
  return h.finalize().map { String(format: "%02x", $0) }.joined()
}

public enum VersionFolder {
  /// Where a project's versions are kept: ~/Library/Caches/Taudot/history/<the project folder's hash>
  /// ($TAUDOT_HISTORY_CACHE: another root, for tests).
  /// Tests: the root of every project's versions.
  nonisolated(unsafe) public static var base: URL?

  public static func root(_ project: URL) -> URL {
    let base = Self.base ?? ProcessInfo.processInfo.environment["TAUDOT_HISTORY_CACHE"].map { URL(fileURLWithPath: $0) }
      ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Taudot/history")
    let h = SHA256.hash(data: Data(project.standardizedFileURL.path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    return base.appendingPathComponent(h)
  }

  public static func folder(_ project: URL, version: Int) -> URL { root(project).appendingPathComponent("v\(version)") }

  /// Marks a finished folder (a half-made one is made again). It lists the binary files that are today's copies; a
  /// folder with any is made again next time, in case they can be had then. (Folders from before figures were had at
  /// their version used `.taudot-version` and are made again.)
  static let doneName = ".taudot-version-2"

  /// What the folder for `version` needs: each file at the version and where its content comes from.
  public enum Source: Equatable, Sendable {
    /// The project folder's copy (unchanged since the version).
    case copy(String)
    /// History's text at the version.
    case history
    /// A binary file that changed since, or isn't in the project any more: its blob at the version. The project's
    /// copy (if any) is at the path given.
    case blob(today: String?)
  }

  /// `files`: history's tree for a range ending at `version` (removed ones are left out); `since`: the paths (as
  /// they were at `version`) that changed between it and now.
  public static func plan(files: [HistoryFile], since: Set<String>, renamedSince: [String: String], project: URL)
    -> [(path: String, source: Source)]
  {
    let fm = FileManager.default
    var out: [(String, Source)] = []
    for f in files where f.op != .removed {
      let p = f.finalPath
      let now = renamedSince[p] ?? p
      let here = fm.fileExists(atPath: project.appendingPathComponent(now).path)
      let changed = since.contains(p) || !here
      if f.editable { out.append((p, changed ? .history : .copy(now))) }
      else { out.append((p, changed ? .blob(today: here ? now : nil) : .copy(now))) }
    }
    return out
  }

  /// Makes (or finds) the folder for `version`. `head`: the newest version (nil: assume files may have changed).
  /// `binaryToday`: binary files that couldn't be had at the version (today's copies, or left out when there's none).
  @MainActor public static func make(source: HistorySource, project: URL, version: Int, files: [HistoryFile], head: Int?)
    async throws -> (folder: URL, binaryToday: [String])
  {
    let fm = FileManager.default
    let dest = folder(project, version: version)
    if let marker = try? String(contentsOf: dest.appendingPathComponent(doneName), encoding: .utf8), marker.isEmpty {
      return (dest, [])
    }
    var since: Set<String> = []
    var renamed: [String: String] = [:]
    if head.map({ $0 > version }) ?? true {
      let later = try await source.tree(HistoryRange(fromV: version, toV: head ?? version))
      for f in later where f.changed {
        since.insert(f.path)
        if f.op == .renamed, let n = f.newPath { renamed[f.path] = n }
      }
    }
    let plan = plan(files: files, since: since, renamedSince: renamed, project: project)
    let tmp = dest.deletingLastPathComponent().appendingPathComponent(".v\(version)-\(UUID().uuidString.prefix(6))")
    try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    // history's texts a few at a time
    let wanted = plan.filter { $0.source == .history }.map(\.path)
    var texts: [String: String?] = [:]
    var i = 0
    while i < wanted.count {
      let batch = Array(wanted[i..<min(i + 6, wanted.count)])
      let tasks = batch.map { p in Task { @MainActor in (p, try await source.file(path: p, version: version)) } }
      for t in tasks {
        let (p, text) = try await t.value
        texts[p] = text
      }
      i += 6
    }
    let blobs = await binaries(plan, source: source, project: project, version: version)
    var today: [String] = []
    for (p, s) in plan {
      let to = tmp.appendingPathComponent(p)
      try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
      switch s {
      case .copy(let now):
        try fm.copyItem(at: project.appendingPathComponent(now), to: to)
      case .history:
        if let t = texts[p] ?? nil { try Data(t.utf8).write(to: to) }
      case .blob(let now):
        if let from = blobs[p], (try? fm.copyItem(at: from, to: to)) != nil { continue }
        today.append(p)
        if let now { try fm.copyItem(at: project.appendingPathComponent(now), to: to) }
      }
    }
    try Data(today.joined(separator: "\n").utf8).write(to: tmp.appendingPathComponent(doneName))
    if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
    try fm.moveItem(at: tmp, to: dest)
    return (dest, today)
  }

  /// The binary files the plan needs at the version, each a file on disk: today's copy when its hash matches the
  /// version's, else the blob (fetched once, kept by hash), else out of the version's zip. Those that can't be had
  /// are left out.
  @MainActor static func binaries(_ plan: [(path: String, source: Source)], source: HistorySource, project: URL, version: Int)
    async -> [String: URL]
  {
    let need = plan.compactMap { p, s -> (String, String?)? in if case .blob(let now) = s { return (p, now) } else { return nil } }
    guard !need.isEmpty, let blobs = source as? HistoryBlobSource else { return [:] }
    var out: [String: URL] = [:]
    if let at = try? await blobs.filesAt(version: version) {
      let hashes = Dictionary(at.compactMap { b in b.hash.map { (b.path, $0) } }, uniquingKeysWith: { a, _ in a })
      for (p, now) in need {
        guard let h = hashes[p] else { continue }
        if let now {
          let here = project.appendingPathComponent(now)
          if let d = try? Data(contentsOf: here, options: .mappedIfSafe), blobHash(d) == h {
            out[p] = here
            continue
          }
        }
        if let f = try? await blobs.blob(hash: h) { out[p] = f }
      }
    }
    let left = need.map(\.0).filter { out[$0] == nil }
    if !left.isEmpty, let z = try? await blobs.zipFiles(version: version, paths: left) {
      for (p, f) in z { out[p] = f }
    }
    return out
  }
}
