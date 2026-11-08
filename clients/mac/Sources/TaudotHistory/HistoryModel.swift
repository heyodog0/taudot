// The History view's data, decoded from the engine's history.* results (docs/api.md, History). Pure: no views.
import AppKit
import Foundation

public struct HistoryUser: Sendable, Equatable, Hashable {
  public var id: String?
  public var name: String
  public var initials: String
  /// Overleaf's hue for this user (degrees); the app colours authors as the margin does instead.
  public var hue: Double
  public var mine: Bool
  public init(id: String?, name: String, initials: String, hue: Double = 100, mine: Bool = false) {
    self.id = id
    self.name = name
    self.initials = initials
    self.hue = hue
    self.mine = mine
  }
  init(_ d: [String: Any]) {
    self.init(id: d["user_id"] as? String, name: d["name"] as? String ?? "Anonymous", initials: d["initials"] as? String ?? "?",
              hue: (d["hue"] as? NSNumber)?.doubleValue ?? 100, mine: d["mine"] as? Bool ?? false)
  }
}

public struct HistoryLabel: Sendable, Equatable, Identifiable {
  public var id: String
  public var comment: String
  public var version: Int
  public var userID: String?
  public var name: String?
  public var created: Date?
  public var mine: Bool
  public init(id: String, comment: String, version: Int, userID: String? = nil, name: String? = nil, created: Date? = nil, mine: Bool = false) {
    self.id = id
    self.comment = comment
    self.version = version
    self.userID = userID
    self.name = name
    self.created = created
    self.mine = mine
  }
  init?(_ d: [String: Any]) {
    guard let id = d["id"] as? String, let v = d["version"] as? Int else { return nil }
    self.init(id: id, comment: d["comment"] as? String ?? "", version: v, userID: d["user_id"] as? String, name: d["name"] as? String,
              created: (d["created_at"] as? String).flatMap(HistoryLabel.iso), mine: d["mine"] as? Bool ?? false)
  }
  static func iso(_ s: String) -> Date? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
  }
}

/// A file added, renamed or removed in a version group.
public struct HistoryFileOp: Sendable, Equatable {
  public enum Kind: String, Sendable { case add, rename, remove }
  public var kind: Kind
  public var path: String
  public var newPath: String?
  public var atV: Int
}

/// Overleaf's group of consecutive versions `fromV..toV`; the project at `toV` is the state after it.
public struct VersionGroup: Sendable, Equatable, Identifiable {
  public var fromV: Int
  public var toV: Int
  public var start: Date
  public var end: Date
  public var users: [HistoryUser]
  public var labels: [HistoryLabel]
  /// Docs whose text changed.
  public var paths: [String]
  public var ops: [HistoryFileOp]
  public var origin: String?
  public var id: Int { toV }
  public init(fromV: Int, toV: Int, start: Date, end: Date, users: [HistoryUser], labels: [HistoryLabel] = [], paths: [String] = [],
              ops: [HistoryFileOp] = [], origin: String? = nil) {
    self.fromV = fromV
    self.toV = toV
    self.start = start
    self.end = end
    self.users = users
    self.labels = labels
    self.paths = paths
    self.ops = ops
    self.origin = origin
  }
  init?(_ d: [String: Any]) {
    guard let f = d["from_v"] as? Int, let t = d["to_v"] as? Int else { return nil }
    let ms = { (k: String) in Date(timeIntervalSince1970: ((d[k] as? NSNumber)?.doubleValue ?? 0) / 1000) }
    self.init(
      fromV: f, toV: t, start: ms("start_ts"), end: ms("end_ts"),
      users: (d["users"] as? [[String: Any]] ?? []).map(HistoryUser.init),
      labels: (d["labels"] as? [[String: Any]] ?? []).compactMap(HistoryLabel.init),
      paths: d["paths"] as? [String] ?? [],
      ops: (d["ops"] as? [[String: Any]] ?? []).compactMap { o in
        guard let k = (o["op"] as? String).flatMap(HistoryFileOp.Kind.init(rawValue:)), let p = o["path"] as? String else { return nil }
        return HistoryFileOp(kind: k, path: p, newPath: o["new_path"] as? String, atV: o["at_v"] as? Int ?? 0)
      },
      origin: (d["origin"] as? [String: Any])?["kind"] as? String)
  }

  /// What the row says changed: "main.tex", "main.tex and 2 more", "Renamed refs.bib → biblio.bib".
  public var summary: String {
    if !paths.isEmpty {
      return paths.count == 1 ? paths[0] : "\(paths[0]) and \(paths.count - 1) more"
    }
    if ops.count == 1, let o = ops.first {
      switch o.kind {
      case .add: return "Added \(o.path)"
      case .remove: return "Deleted \(o.path)"
      case .rename: return "Renamed \(o.path) → \(o.newPath ?? "?")"
      }
    }
    if !ops.isEmpty {
      let added = ops.filter { $0.kind == .add }.count, removed = ops.filter { $0.kind == .remove }.count
      let renamed = ops.count - added - removed
      return [(added, "added"), (renamed, "renamed"), (removed, "deleted")].filter { $0.0 > 0 }
        .map { "\($0.0) \($0.0 == 1 ? "file" : "files") \($0.1)" }.joined(separator: ", ")
    }
    return "No changes"
  }

  /// Where the change came from, when it wasn't typed in an editor.
  public var originText: String? {
    switch origin {
    case "upload": return "Uploaded"
    case "dropbox": return "From Dropbox"
    case "git-bridge": return "From Git"
    case "github": return "From GitHub"
    case "file-restore": return "Restored a file"
    case "project-restore": return "Restored the project"
    case "history-resync", "history-migration": return "History repaired"
    default: return nil
    }
  }
}

/// One page of `history.updates`.
public struct UpdatesPage: Sendable {
  public var groups: [VersionGroup]
  public var nextBefore: Int?
  public var head: Int?
  public init(groups: [VersionGroup], nextBefore: Int?, head: Int?) {
    self.groups = groups
    self.nextBefore = nextBefore
    self.head = head
  }
  public init(_ d: [String: Any]) {
    self.init(groups: (d["updates"] as? [[String: Any]] ?? []).compactMap(VersionGroup.init),
              nextBefore: d["next_before"] as? Int, head: d["head"] as? Int)
  }
}

/// A file of `history.tree`.
public struct HistoryFile: Sendable, Equatable {
  public enum Op: String, Sendable { case edited, added, renamed, removed }
  public var path: String
  public var op: Op?
  public var newPath: String?
  public var deletedAtV: Int?
  public var editable: Bool
  public init(path: String, op: Op? = nil, newPath: String? = nil, deletedAtV: Int? = nil, editable: Bool = true) {
    self.path = path
    self.op = op
    self.newPath = newPath
    self.deletedAtV = deletedAtV
    self.editable = editable
  }
  init?(_ d: [String: Any]) {
    guard let p = d["path"] as? String else { return nil }
    self.init(path: p, op: (d["op"] as? String).flatMap(Op.init(rawValue:)), newPath: d["new_path"] as? String,
              deletedAtV: d["deleted_at_v"] as? Int, editable: d["editable"] as? Bool ?? true)
  }
  /// The name at the range's end, which `history.diff` wants.
  public var finalPath: String { newPath ?? path }
  public var changed: Bool { op != nil }
}

/// `history.diff`: the text with deletions in place, and who inserted or deleted what.
public struct HistoryDiff: Sendable, Equatable {
  public enum Kind: String, Sendable { case same, insert, delete }
  public struct Chunk: Sendable, Equatable {
    public var kind: Kind
    /// UTF-16 range in `text` (converted from the engine's UTF-8 bytes).
    public var range: NSRange
    public var user: HistoryUser?
    public var time: Date?
  }
  public var path: String
  public var fromV: Int
  public var toV: Int
  public var binary: Bool
  public var text: String
  public var chunks: [Chunk]
  public var inserted: Int
  public var deleted: Int

  public init(path: String, fromV: Int, toV: Int, binary: Bool = false, text: String, chunks: [Chunk], inserted: Int = 0, deleted: Int = 0) {
    self.path = path
    self.fromV = fromV
    self.toV = toV
    self.binary = binary
    self.text = text
    self.chunks = chunks
    self.inserted = inserted
    self.deleted = deleted
  }

  public init(_ d: [String: Any]) {
    let text = d["text"] as? String ?? ""
    // Byte offsets → UTF-16 offsets, in one pass over the text.
    let bytes = Array(text.utf8)
    var map = [Int](repeating: 0, count: bytes.count + 1)
    var u16 = 0
    var i = 0
    while i < bytes.count {
      let b = bytes[i]
      let n = b < 0x80 ? 1 : b < 0xE0 ? 2 : b < 0xF0 ? 3 : 4
      for k in 0..<n where i + k <= bytes.count { map[i + k] = u16 }
      u16 += n == 4 ? 2 : 1
      i += n
    }
    map[bytes.count] = u16
    let at = { (b: Int) in map[max(0, min(b, bytes.count))] }
    let chunks: [Chunk] = (d["chunks"] as? [[String: Any]] ?? []).compactMap { c in
      guard let k = (c["kind"] as? String).flatMap(Kind.init(rawValue:)), let s = c["start"] as? Int, let e = c["end"] as? Int else { return nil }
      let from = at(s)
      return Chunk(kind: k, range: NSRange(location: from, length: at(e) - from),
                   user: (c["user"] as? [String: Any]).map(HistoryUser.init),
                   time: (c["ts"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) })
    }
    self.init(path: d["path"] as? String ?? "", fromV: d["from"] as? Int ?? 0, toV: d["to"] as? Int ?? 0,
              binary: d["binary"] as? Bool ?? false, text: text, chunks: chunks,
              inserted: d["inserted"] as? Int ?? 0, deleted: d["deleted"] as? Int ?? 0)
  }

  /// The changed chunks, in order (for next / previous change).
  public var changes: [Chunk] { chunks.filter { $0.kind != .same } }
}

/// The versions the diff shows: one group (its own changes) or, comparing, from one group's start to another's end.
public struct HistoryRange: Sendable, Hashable {
  public var fromV: Int
  public var toV: Int
  public init(fromV: Int, toV: Int) {
    self.fromV = min(fromV, toV)
    self.toV = max(fromV, toV)
  }
  public static func of(_ g: VersionGroup) -> HistoryRange { HistoryRange(fromV: g.fromV, toV: g.toV) }
  /// The span covering two groups, as Overleaf's compare does (`updateRangeUnion`).
  public static func union(_ a: VersionGroup, _ b: VersionGroup) -> HistoryRange {
    HistoryRange(fromV: min(a.fromV, b.fromV), toV: max(a.toV, b.toV))
  }
}

/// List rows: a day heading before the first group of each day, then the groups.
public enum HistoryRow: Equatable {
  case day(String)
  case group(VersionGroup)
  case more
}

public enum HistoryRows {
  /// Rows for `groups` (newest first), `labelsOnly` keeping groups that carry a label, with a "Load older" row when
  /// there are more pages.
  public static func build(_ groups: [VersionGroup], labelsOnly: Bool, hasMore: Bool, now: Date = Date(), calendar: Calendar = .current) -> [HistoryRow] {
    var rows: [HistoryRow] = []
    var lastDay: DateComponents?
    for g in groups where !labelsOnly || !g.labels.isEmpty {
      let day = calendar.dateComponents([.year, .month, .day], from: g.end)
      if day != lastDay {
        rows.append(.day(dayTitle(g.end, now: now, calendar: calendar)))
        lastDay = day
      }
      rows.append(.group(g))
    }
    if hasMore { rows.append(.more) }
    return rows
  }

  static func dayTitle(_ d: Date, now: Date, calendar: Calendar) -> String {
    if calendar.isDate(d, inSameDayAs: now) { return "Today" }
    if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(d, inSameDayAs: y) { return "Yesterday" }
    let f = DateFormatter()
    f.calendar = calendar
    f.timeZone = calendar.timeZone
    f.setLocalizedDateFormatFromTemplate(calendar.isDate(d, equalTo: now, toGranularity: .year) ? "EEEEdMMMM" : "dMMMMyyyy")
    return f.string(from: d)
  }
}

/// Which file to show for a new range, as Overleaf's History picks it (`utils/auto-select-file.ts`, in spirit): the
/// one shown before if it changed here, else the first changed .tex, else any changed text file, else the one shown
/// before, else the main file, else the first.
public func autoSelectFile(_ files: [HistoryFile], previous: String?, main: String?) -> HistoryFile? {
  let changed = files.filter { $0.changed && $0.op != .removed }
  if let p = previous, let f = changed.first(where: { $0.path == p || $0.finalPath == p }) { return f }
  if let f = changed.first(where: { $0.finalPath.hasSuffix(".tex") && $0.editable }) { return f }
  if let f = changed.first(where: { $0.editable }) { return f }
  if let p = previous, let f = files.first(where: { $0.finalPath == p && $0.op != .removed }) { return f }
  if let m = main, let f = files.first(where: { $0.finalPath == m }) { return f }
  return files.first(where: { $0.editable && $0.op != .removed }) ?? files.first
}

/// "3:42 PM", the time a group ended.
public func historyTime(_ d: Date) -> String {
  let f = DateFormatter()
  f.timeStyle = .short
  f.dateStyle = .none
  return f.string(from: d)
}
