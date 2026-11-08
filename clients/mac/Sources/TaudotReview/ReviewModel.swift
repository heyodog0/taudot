// The review state as clients/nvim/lua/taudot/gui.lua sends it (taudot_review, taudot_review_cursor).
import AppKit
import TaudotShared

public struct ReviewUser: Sendable, Equatable {
  public var id: String?
  public var name: String
  public var initials: String
  public init(id: String?, name: String, initials: String) {
    self.id = id
    self.name = name
    self.initials = initials
  }
}

public struct ReviewMessage: Sendable, Equatable, Identifiable {
  public var id: String
  public var text: String
  public var ts: Date?
  public var user: ReviewUser
  public var mine: Bool
  public init(id: String, text: String, ts: Date?, user: ReviewUser, mine: Bool) {
    self.id = id
    self.text = text
    self.ts = ts
    self.user = user
    self.mine = mine
  }
}

public enum ReviewKind: String, Sendable {
  case comment
  case insert = "tracked_insert"
  case delete = "tracked_delete"
}

/// A range in a buffer: 0-based rows, byte columns, end exclusive.
public struct ReviewRange: Sendable, Equatable {
  public var line, col, endLine, endCol: Int
  public init(line: Int, col: Int, endLine: Int, endCol: Int) {
    self.line = line
    self.col = col
    self.endLine = endLine
    self.endCol = endCol
  }
}

public struct ReviewItem: Sendable, Equatable, Identifiable {
  public var id: String
  public var kind: ReviewKind
  public var threadID: String?
  public var author: ReviewUser
  /// "#rrggbb", the colour Neovim draws this author with. Nil: pick one from the user id.
  public var color: String?
  public var ts: Date?
  public var quote: String
  public var messages: [ReviewMessage]
  public var range: ReviewRange
  public var resolved: Bool
  public var resolvedBy: ReviewUser?
  /// Screen rows above its line from the buffer's top, in the followed window (gui.lua's doc_row): the card's
  /// anchor in document space. nil: unknown (the margin then measures the line where it is now).
  public var docRow: Int?
  /// A grouped card (Overleaf's): the tracked changes it stands for, in text order. Empty for a single item.
  public var members: [ReviewItem] = []
  /// Where its text starts on screen within its (wrapped) line: the screen row (0: the line's first) and the column
  /// in the text area (gui.lua's start_wrap / start_scol). The connector ends there.
  public var startWrap: Int?
  /// The line its text shows on first (a range starting at a line's end begins on the next one).
  public var startLine: Int?
  public var startCol: Int?
  public var isGroup: Bool { !members.isEmpty }
  /// A tracked insertion and the tracked deletion of that same text by the same person: one card.
  public var isAddedThenRemoved: Bool {
    members.count == 2 && members[0].kind == .insert && members[1].kind == .delete && id.hasPrefix("pair:")
  }
  /// The ids an accept/reject of this card takes.
  public var changeIDs: [String] { isGroup ? members.flatMap(\.changeIDs) : (kind == .comment ? [] : [id]) }
  /// A tracked deletion and the insertion that replaces it, by the same person at the same place.
  public var isReplacement: Bool { members.count == 2 && id.hasPrefix("replace:") }
  /// A pair (added-then-removed, a replacement): one change to read, two to accept.
  public var isPair: Bool { isAddedThenRemoved || isReplacement }
  public init(
    id: String, kind: ReviewKind, threadID: String? = nil, author: ReviewUser, color: String? = nil, ts: Date? = nil,
    quote: String, messages: [ReviewMessage] = [], range: ReviewRange, resolved: Bool = false, resolvedBy: ReviewUser? = nil
  ) {
    self.id = id
    self.kind = kind
    self.threadID = threadID
    self.author = author
    self.color = color
    self.ts = ts
    self.quote = quote
    self.messages = messages
    self.range = range
    self.resolved = resolved
    self.resolvedBy = resolvedBy
  }
}

public struct ReviewState: Sendable, Equatable {
  public var buf: Int
  public var path: String?
  /// The followed buffer's absolute path (any file, synced or not): the file tree highlights it.
  public var file: String?
  public var docID: String?
  public var me: String?
  /// False when the server has no comment threads (Overleaf CE): comments show, but can't be answered.
  public var supported: Bool
  public var track: Bool
  public var items: [ReviewItem]
  /// The followed buffer is a synced doc (false: another file, items empty for that reason).
  public var synced = true
  /// Why gui.lua sent it (BufEnter, redraw, empty-held, ...), for the trace.
  public var reason: String?
  /// Me as the project knows me (name, initials, colour), when gui.lua has it.
  public var meUser: ReviewUser?
  public var meColor: String?
  /// The buffer's line count (the margin may overscroll past the last line only).
  public var lineCount: Int?
  /// The followed window's number/sign columns (cells before the text).
  public var textoff = 0
  public init(buf: Int = 0, path: String? = nil, docID: String? = nil, me: String? = nil, supported: Bool = true, track: Bool = false, items: [ReviewItem] = []) {
    self.buf = buf
    self.path = path
    self.docID = docID
    self.me = me
    self.supported = supported
    self.track = track
    self.items = items
  }
}

public struct ReviewCursor: Sendable, Equatable {
  public var buf: Int
  public var line: Int
  public var col: Int
  /// Items under the cursor.
  public var here: [String]
  /// The visual selection, while in visual mode.
  public var visual: ReviewRange?
  /// Where that selection ends on screen (for the Comment pill); nil when off screen.
  public var visualEnd: SelectionEnd?
  /// Where the items under the cursor, and the cursor, are on screen (for the floating card); nil: unknown.
  public var at: ScreenAt?
  public init(buf: Int = 0, line: Int = 0, col: Int = 0, here: [String] = [], visual: ReviewRange? = nil, visualEnd: SelectionEnd? = nil) {
    self.buf = buf
    self.line = line
    self.col = col
    self.here = here
    self.visual = visual
    self.visualEnd = visualEnd
  }
}

/// The end of a selection on screen: the screen row within its (wrapped) buffer line, the grid column just after its
/// last character (0-based), and the grid's width in columns.
public struct SelectionEnd: Sendable, Equatable {
  public var wrap: Int
  public var screenCol: Int
  public var columns: Int
  public init(wrap: Int, screenCol: Int, columns: Int) {
    self.wrap = wrap
    self.screenCol = screenCol
    self.columns = columns
  }
}

/// Screen rows within each position's wrapped line (0: its first row) and screen columns (0-based, of a grid
/// `columns` wide), as gui.lua's cursor payload gives them in `at`. A missing one is off screen or unknown.
public struct ScreenAt: Sendable, Equatable {
  public struct Item: Sendable, Equatable {
    public var startWrap: Int?
    public var startCol: Int?
    public var endWrap: Int?
    public init(startWrap: Int? = nil, startCol: Int? = nil, endWrap: Int? = nil) {
      self.startWrap = startWrap
      self.startCol = startCol
      self.endWrap = endWrap
    }
  }
  public var columns: Int
  public var cursorWrap: Int?
  public var items: [String: Item]
  public init(columns: Int, cursorWrap: Int? = nil, items: [String: Item] = [:]) {
    self.columns = columns
    self.cursorWrap = cursorWrap
    self.items = items
  }
}

// ---- decoding -------------------------------------------------------------------------------------------------------

extension Value {
  subscript(_ key: String) -> Value {
    if case let .map(pairs) = self {
      for (k, v) in pairs where k == .string(key) {
        return v
      }
    }
    return .null
  }
  var string: String? {
    switch self {
    case let .string(s): return s
    case let .int(i): return String(i)
    case let .float(f): return String(f)
    case let .binary(b): return String(decoding: b, as: UTF8.self)
    default: return nil
    }
  }
  var int: Int? {
    switch self {
    case let .int(i): return Int(i)
    case let .float(f): return Int(f)
    default: return nil
    }
  }
  var double: Double? {
    switch self {
    case let .int(i): return Double(i)
    case let .float(f): return f
    default: return nil
    }
  }
  var bool: Bool {
    if case let .bool(b) = self { return b }
    return false
  }
  /// An array; an empty map too (Lua's {} can arrive as either).
  var array: [Value] {
    switch self {
    case let .array(a): return a
    default: return []
    }
  }
  var isNull: Bool { self == .null }
}

private func date(_ v: Value) -> Date? {
  v.double.map { Date(timeIntervalSince1970: $0 / 1000) }
}

extension ReviewUser {
  init(_ v: Value) {
    let name = v["name"].string ?? "?"
    self.init(id: v["user_id"].string, name: name, initials: v["initials"].string ?? String(name.prefix(1)).uppercased())
  }
}

extension ReviewMessage {
  init(_ v: Value) {
    self.init(id: v["id"].string ?? "", text: v["text"].string ?? "", ts: date(v["ts"]), user: ReviewUser(v["user"]), mine: v["mine"].bool)
  }
}

extension ReviewRange {
  init?(_ v: Value) {
    guard let l = v["line"].int, let c = v["col"].int else { return nil }
    self.init(line: l, col: c, endLine: v["end_line"].int ?? l, endCol: v["end_col"].int ?? c)
  }
}

extension ReviewItem {
  init?(_ v: Value) {
    guard let id = v["id"].string, let kind = ReviewKind(rawValue: v["kind"].string ?? ""), let range = ReviewRange(v) else {
      return nil
    }
    self.init(
      id: id, kind: kind, threadID: v["thread_id"].string, author: ReviewUser(v["author"]), color: v["color"].string,
      ts: date(v["ts"]), quote: v["quote"].string ?? "", messages: v["messages"].array.map(ReviewMessage.init), range: range,
      resolved: v["resolved"].bool, resolvedBy: v["resolved_by"].isNull ? nil : ReviewUser(v["resolved_by"]))
    docRow = v["doc_row"].int
    startWrap = v["start_wrap"].int
    startLine = v["start_line"].int
    startCol = v["start_scol"].int
  }
}

extension ReviewState {
  /// From a taudot_review payload.
  public init(_ v: Value) {
    self.init(
      buf: v["buf"].int ?? 0, path: v["path"].string, docID: v["doc_id"].string, me: v["me"].string,
      supported: v["supported"].isNull ? true : v["supported"].bool, track: v["track"].bool,
      items: v["items"].array.compactMap(ReviewItem.init))
    if !v["synced"].isNull { synced = v["synced"].bool }
    reason = v["reason"].string
    file = v["file"].string
    lineCount = v["line_count"].int
    textoff = v["textoff"].int ?? 0
    if !v["me_user"].isNull {
      meUser = ReviewUser(v["me_user"])
      meColor = v["me_user"]["color"].string
    }
  }
}

extension ReviewCursor {
  /// From a taudot_review_cursor payload.
  public init(_ v: Value) {
    self.init(
      buf: v["buf"].int ?? 0, line: v["line"].int ?? 0, col: v["col"].int ?? 0, here: v["here"].array.compactMap(\.string),
      visual: v["visual"].isNull ? nil : ReviewRange(v["visual"]),
      visualEnd: {
        let e = v["visual"]
        guard !e.isNull, let w = e["end_wrap"].int, let c = e["end_screen_col"].int, let n = e["columns"].int, n > 0 else { return nil }
        return SelectionEnd(wrap: w, screenCol: c, columns: n)
      }())
    let a = v["at"]
    if let n = a["columns"].int, n > 0 {
      var items: [String: ScreenAt.Item] = [:]
      if case let .map(pairs) = a["items"] {
        for (k, it) in pairs {
          guard let id = k.string else { continue }
          items[id] = ScreenAt.Item(startWrap: it["start_wrap"].int, startCol: it["start_col"].int, endWrap: it["end_wrap"].int)
        }
      }
      at = ScreenAt(columns: n, cursorWrap: a["cursor_wrap"].int, items: items)
    }
  }
}

// ---- colours ------------------------------------------------------------------------------------------------------

extension NSColor {
  /// "#rrggbb".
  public convenience init?(hex: String) {
    var s = hex
    if s.hasPrefix("#") { s.removeFirst() }
    guard s.count == 6, let n = UInt32(s, radix: 16) else { return nil }
    self.init(srgbRed: CGFloat((n >> 16) & 0xff) / 255, green: CGFloat((n >> 8) & 0xff) / 255, blue: CGFloat(n & 0xff) / 255, alpha: 1)
  }
}

extension ReviewItem {
  /// The author's colour: Neovim's, else one of the system colours picked from the user id.
  public var authorColor: NSColor {
    if let c = color, let n = NSColor(hex: c) { return n }
    let palette: [NSColor] = [.systemBlue, .systemOrange, .systemGreen, .systemPurple, .systemPink, .systemTeal, .systemIndigo]
    let key = author.id ?? author.name
    let h = key.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
    return palette[Int(h % UInt32(palette.count))]
  }
}

extension NSColor {
  /// This colour, darkened (light appearance) or lightened (dark) until it reads on a card's background.
  public func readable(dark: Bool) -> NSColor {
    let c = usingColorSpace(.sRGB) ?? self
    let lum = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
    if !dark && lum > 0.6 { return c.blended(withFraction: min(0.6, (lum - 0.45) * 1.5), of: .black) ?? c }
    if dark && lum < 0.3 { return c.blended(withFraction: min(0.6, (0.45 - lum) * 1.5), of: .white) ?? c }
    return c
  }
}

extension NSView {
  var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

extension FileBadges {
  /// From a taudot_files payload.
  public init(_ v: Value) {
    self.init()
    if case let .map(pairs) = v["comments"] {
      for (k, n) in pairs { if let path = k.string, let c = n.int { comments[path] = c } }
    }
    if case let .map(pairs) = v["people"] {
      for (k, list) in pairs {
        guard let path = k.string else { continue }
        people[path] = list.array.map { u in
          Person(name: u["name"].string ?? "?", initials: u["initials"].string ?? "?", color: u["color"].string)
        }
      }
    }
  }
}
