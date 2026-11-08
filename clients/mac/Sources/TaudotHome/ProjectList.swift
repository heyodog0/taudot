// The home window's list model: projects from the engine's `projects.list` (docs/api.md), filtered, searched and
// sorted the way Overleaf's dashboard does it. No AppKit here, so it is tested on its own.
import Foundation

public struct HomeProject: Sendable, Equatable, Identifiable {
  public var id: String
  public var name: String
  public var ownerName: String
  public var ownerEmail: String
  public var lastUpdated: Date?
  public var lastUpdatedBy: String?
  public var lastUpdatedById: String?
  /// `owner`, `readWrite`, `review`, `readOnly` or `readAndWrite` (link sharing).
  public var accessLevel: String
  public var archived: Bool
  public var trashed: Bool
  /// The folder on this Mac that mirrors it, if any.
  public var localFolder: String?
  /// When the engine last opened that folder.
  public var lastOpened: Date?

  public var isMine: Bool { accessLevel == "owner" }
  public var isLocal: Bool { localFolder != nil }
  /// The Owner column: "You" for your own projects, as on overleaf.com.
  public var ownerLabel: String { isMine ? "You" : ownerName }

  public init(id: String, name: String, ownerName: String = "", ownerEmail: String = "", lastUpdated: Date? = nil,
              lastUpdatedBy: String? = nil, lastUpdatedById: String? = nil, accessLevel: String = "owner", archived: Bool = false, trashed: Bool = false,
              localFolder: String? = nil, lastOpened: Date? = nil) {
    self.id = id; self.name = name; self.ownerName = ownerName; self.ownerEmail = ownerEmail
    self.lastUpdated = lastUpdated; self.lastUpdatedBy = lastUpdatedBy; self.lastUpdatedById = lastUpdatedById; self.accessLevel = accessLevel
    self.archived = archived; self.trashed = trashed; self.localFolder = localFolder; self.lastOpened = lastOpened
  }

  /// From one entry of `projects.list`.
  public init?(json p: [String: Any]) {
    guard let id = p["id"] as? String else { return nil }
    let owner = p["owner"] as? [String: Any]
    let by = p["last_updated_by"] as? [String: Any]
    self.init(id: id, name: p["name"] as? String ?? "Untitled",
              ownerName: owner?["name"] as? String ?? "", ownerEmail: owner?["email"] as? String ?? "",
              lastUpdated: (p["last_updated"] as? String).flatMap(ProjectList.parseDate),
              lastUpdatedBy: by?["name"] as? String, lastUpdatedById: by?["id"] as? String,
              accessLevel: p["access_level"] as? String ?? "readOnly",
              archived: p["archived"] as? Bool ?? false, trashed: p["trashed"] as? Bool ?? false,
              localFolder: p["local_folder"] as? String,
              lastOpened: (p["last_opened"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) })
  }
}

/// Overleaf's dashboard filters. All, Mine and Shared leave out archived and trashed projects.
public enum ProjectFilter: String, CaseIterable, Sendable {
  case all, mine, shared, archived, trashed

  public var title: String {
    switch self {
    case .all: "All"
    case .mine: "Mine"
    case .shared: "Shared"
    case .archived: "Archived"
    case .trashed: "Trash"
    }
  }

  public func matches(_ p: HomeProject) -> Bool {
    switch self {
    case .all: !p.archived && !p.trashed
    case .mine: p.isMine && !p.archived && !p.trashed
    case .shared: !p.isMine && !p.archived && !p.trashed
    case .archived: p.archived
    case .trashed: p.trashed
    }
  }
}

public enum ProjectSortKey: String, Sendable { case name, owner, lastModified }

public struct ProjectQuery: Sendable, Equatable {
  public var filter: ProjectFilter = .all
  public var search: String = ""
  public var sort: ProjectSortKey = .lastModified
  /// Last modified sorts newest first when this is false, as Overleaf's default.
  public var ascending: Bool = false
  public init(filter: ProjectFilter = .all, search: String = "", sort: ProjectSortKey = .lastModified, ascending: Bool = false) {
    self.filter = filter; self.search = search; self.sort = sort; self.ascending = ascending
  }
}

public enum ProjectList {
  /// The projects to show, in order.
  public static func visible(_ all: [HomeProject], _ q: ProjectQuery) -> [HomeProject] {
    let words = q.search.split(whereSeparator: \.isWhitespace).map(String.init)
    let shown = all.filter { p in
      q.filter.matches(p) && words.allSatisfy { w in
        p.name.range(of: w, options: [.caseInsensitive, .diacriticInsensitive]) != nil
          || p.ownerName.range(of: w, options: [.caseInsensitive, .diacriticInsensitive]) != nil
      }
    }
    return shown.sorted { a, b in
      let byName = a.name.localizedStandardCompare(b.name)
      let c: ComparisonResult
      switch q.sort {
      case .name: c = byName
      case .owner: c = a.ownerLabel.localizedStandardCompare(b.ownerLabel)
      case .lastModified:
        let (x, y) = (a.lastUpdated ?? .distantPast, b.lastUpdated ?? .distantPast)
        c = x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
      }
      if c == .orderedSame { return byName == .orderedAscending || (byName == .orderedSame && a.id < b.id) }
      return q.ascending ? c == .orderedAscending : c == .orderedDescending
    }
  }

  /// Projects opened on this Mac, most recent first; not trashed ones.
  public static func recent(_ all: [HomeProject], limit: Int = 5) -> [HomeProject] {
    Array(all.filter { $0.isLocal && $0.lastOpened != nil && !$0.trashed }
      .sorted { $0.lastOpened! > $1.lastOpened! }.prefix(limit))
  }

  nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()
  nonisolated(unsafe) private static let isoPlain = ISO8601DateFormatter()

  public static func parseDate(_ s: String) -> Date? { iso.date(from: s) ?? isoPlain.date(from: s) }

  /// "just now", "5 minutes ago", "3 hours ago", "yesterday", "4 days ago", else a date: Overleaf's style.
  public static func relative(_ date: Date?, now: Date = Date(), calendar: Calendar = .current) -> String {
    guard let date else { return "—" }
    let s = now.timeIntervalSince(date)
    if s < 60 { return "just now" }
    if s < 3600 { let m = Int(s / 60); return m == 1 ? "a minute ago" : "\(m) minutes ago" }
    if s < 86400 && calendar.isDate(date, inSameDayAs: now) { let h = Int(s / 3600); return h == 1 ? "an hour ago" : "\(h) hours ago" }
    let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
    if days <= 1 { return "yesterday" }
    if days < 7 { return "\(days) days ago" }
    let f = DateFormatter()
    f.calendar = calendar
    f.timeZone = calendar.timeZone
    f.locale = Locale(identifier: "en_GB")
    f.dateFormat = calendar.isDate(date, equalTo: now, toGranularity: .year) ? "d MMM" : "d MMM yyyy"
    return f.string(from: date)
  }

  /// A folder name from a project name, as `taudot clone` makes it: letters, digits, `-` and `_`; anything else
  /// becomes `-`.
  public static func folderName(_ name: String) -> String {
    let mapped = String(name.trimmingCharacters(in: .whitespaces).map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" })
    let s = mapped.split(separator: "-").joined(separator: "-")
    return s.isEmpty ? "overleaf-project" : s
  }

  /// Where to clone a project: `<root>/<name>`, or `<name>-2`, `-3`... when that is taken.
  public static func cloneFolder(root: URL, name: String, exists: (URL) -> Bool) -> URL {
    let base = folderName(name)
    var url = root.appendingPathComponent(base, isDirectory: true)
    var n = 2
    while exists(url) {
      url = root.appendingPathComponent("\(base)-\(n)", isDirectory: true)
      n += 1
    }
    return url
  }

  /// The Last Modified column: "yesterday by Alice", or just "an hour ago" when you made the change.
  public static func modified(_ p: HomeProject, me: String?, now: Date = Date(), calendar: Calendar = .current) -> String {
    let when = relative(p.lastUpdated, now: now, calendar: calendar)
    guard let by = p.lastUpdatedBy, !by.isEmpty, p.lastUpdatedById == nil || p.lastUpdatedById != me else { return when }
    return "\(when) by \(by)"
  }

  /// `~/x` for paths in the home folder.
  public static func abbreviate(_ path: String) -> String {
    let home = NSHomeDirectory()
    return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
  }
}
