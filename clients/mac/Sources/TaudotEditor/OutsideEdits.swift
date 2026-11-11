// Outside edits (editfix item 9): a change to a doc that didn't come from this window's editor — a coauthor's, or one
// made on disk (an editor or an agent outside Taudot; "Claude" when the Claude pane's claude was busy) — as the editors
// report them (`taudot_app_outside`, Neovim's taudot.app and the native editor alike). Kept since the project opened,
// newest first: who, where (its range moves with every later edit), what it replaced. The window shows them (the
// Changes list), follows them (Follow Edits), marks them on the PDF, and undoes one while its text is still as the
// edit left it. The editors tint the text themselves.
import AppKit
import Foundation
import TaudotShared

@MainActor public final class OutsideEdits {
  public init() {}
  public struct Change: Identifiable, Equatable, Sendable {
    public let id: Int
    public let path: String
    /// "Claude", "on disk", a coauthor's name.
    public let who: String
    public let disk: Bool
    public let colorKey: String
    public let time: Date
    /// Where its text is now (UTF-8 bytes): what the edit inserted, `new`; it replaced `old`.
    public var pos: Int
    public var len: Int
    public let new: [UInt8]
    public let old: [UInt8]
    /// The text there was changed since (by anyone): it can't be undone as it is.
    public var touched = false
    public var undone = false
  }

  public private(set) var changes: [Change] = []  // oldest first
  private var nextID = 1
  /// Each doc's text as the editor holds it (the text feed), bytes.
  private var texts: [String: [UInt8]] = [:]
  /// Called after every change to the list (a new edit, an undo, ranges moving).
  public var onChange: (() -> Void)?
  /// A new outside edit landed (after the list has it).
  public var onNew: ((Change) -> Void)?
  /// The Claude pane's claude wrote output this recently: a disk edit now is Claude's.
  public var claudeBusy: () -> Bool = { false }
  let keep = 200

  // ---- the text feed (every change, ours and theirs, in order)

  public func held(_ path: String, _ text: String) {
    texts[path] = Array(text.utf8)
  }

  public func changed(_ path: String, _ pos: Int, _ del: Int, _ ins: String) {
    guard var t = texts[path], pos >= 0, pos + del <= t.count else { return }
    // the last few edits with the text before each: an outside batch is reported right after its edits
    var r = recent[path] ?? []
    r.append((t, (pos, del, ins)))
    if r.count > 16 { r.removeFirst(r.count - 16) }
    recent[path] = r
    let b = Array(ins.utf8)
    t.replaceSubrange(pos..<(pos + del), with: b)
    texts[path] = t
    var moved = false
    for i in changes.indices where changes[i].path == path && !changes[i].undone {
      let c = changes[i]
      let a = c.pos, e = c.pos + c.len, end = pos + del
      if end <= a && !(del == 0 && pos == a && c.len > 0) {
        if pos < a || (del == 0 && pos == a) { changes[i].pos += b.count - del; moved = true }
      } else if pos >= e && !(del == 0 && pos == e && c.len == 0) {
        // after it: nothing moves
      } else {
        // into it: its text is no longer the edit's
        changes[i].touched = true
        let na = min(a, pos), ne = max(e, end) + b.count - del
        changes[i].pos = na
        changes[i].len = max(0, ne - na)
        moved = true
      }
    }
    if moved { onChange?() }
  }

  public func released(_ path: String) { texts[path] = nil }

  public func text(_ path: String) -> [UInt8]? { texts[path] }

  // ---- outside edits

  /// `edits` (byte offsets, applied one after another) were applied to `path`; the feed has them already.
  public func outside(_ path: String, edits: [(pos: Int, del: Int, ins: String)], author: [String: Any]?, origin: String?, source: String?) {
    guard let now = texts[path], !edits.isEmpty else { return }
    // the text before the batch: kept by `changed`, which applied it just before the editor reported it
    guard let before = snapshot(path, edits: edits) else { return }
    // one replacement: the common prefix and suffix off
    var a = 0
    while a < before.count && a < now.count && before[a] == now[a] { a += 1 }
    var s = 0
    while s < before.count - a && s < now.count - a && before[before.count - 1 - s] == now[now.count - 1 - s] { s += 1 }
    // whole words ("waited" put in "Line 50 words" reads "+ waited", not "+ aited w"); this also keeps it out of a
    // UTF-8 sequence
    func word(_ b: UInt8) -> Bool { b >= 0x80 || (b >= 0x30 && b <= 0x39) || (b | 0x20 >= 0x61 && b | 0x20 <= 0x7A) }
    // (a boundary splits a word when the characters on both sides of it are word characters, in either text)
    while a > 0 && word(now[a - 1]) && ((a < now.count && word(now[a])) || (a < before.count && word(before[a]))) { a -= 1 }
    while s > 0, case let (en, eb) = (now.count - s, before.count - s), word(now[en]),
          (en > 0 && word(now[en - 1])) || (eb > 0 && word(before[eb - 1])) { s -= 1 }
    // (not inside a UTF-8 sequence)
    while a > 0 && a < now.count && (now[a] & 0xC0) == 0x80 { a -= 1 }
    while s > 0 && now.count - s < now.count && (now[now.count - s] & 0xC0) == 0x80 { s -= 1 }
    let new = Array(now[a..<(now.count - s)]), old = Array(before[a..<(before.count - s)])
    if new.isEmpty && old.isEmpty { return }
    let disk = source == "disk"
    let name = (author?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    let who: String
    if disk { who = claudeBusy() ? "Claude" : "on disk" } else if origin == "remote" { who = name ?? "a coauthor" } else { who = name.map { "\($0) (elsewhere)" } ?? "elsewhere" }
    let key = disk ? "disk" : (author?["user_id"] as? String ?? name ?? "?")
    let c = Change(id: nextID, path: path, who: who, disk: disk, colorKey: key, time: Date(), pos: a, len: new.count, new: new, old: old)
    nextID += 1
    changes.append(c)
    if changes.count > keep { changes.removeFirst(changes.count - keep) }
    onChange?()
    onNew?(c)
  }

  /// The text before the batch: kept by `changed` (the feed applies the batch just before the editor reports it).
  private var recent: [String: [(before: [UInt8], edit: (Int, Int, String))]] = [:]
  private func snapshot(_ path: String, edits: [(pos: Int, del: Int, ins: String)]) -> [UInt8]? {
    guard let r = recent[path], r.count >= edits.count else { return nil }
    let tail = r.suffix(edits.count)
    for (x, e) in zip(tail, edits) where x.edit.0 != e.pos || x.edit.1 != e.del || x.edit.2 != e.ins { return nil }
    return tail.first?.before
  }

  // ---- what the window asks

  /// Newest first.
  public var list: [Change] { changes.reversed() }

  /// The 1-based line (and byte column) where a change's text starts now.
  public func line(of c: Change) -> (line: Int, col: Int)? {
    guard let t = texts[c.path], c.pos <= t.count else { return nil }
    var line = 1, start = 0
    for i in 0..<c.pos where t[i] == 0x0A { line += 1; start = i + 1 }
    return (line, c.pos - start)
  }
  /// The lines it spans now (1-based, inclusive).
  public func lines(of c: Change) -> ClosedRange<Int>? {
    guard let (l, _) = line(of: c), let t = texts[c.path] else { return nil }
    let end = min(t.count, c.pos + c.len)
    let n = t[c.pos..<end].filter { $0 == 0x0A }.count
    return l...(l + n)
  }

  /// Undo is offered while the text there is still exactly what the edit left.
  public func canUndo(_ c: Change) -> Bool {
    guard !c.undone, let t = texts[c.path], c.pos + c.len <= t.count else { return false }
    return Array(t[c.pos..<(c.pos + c.len)]) == c.new
  }

  /// The replacement that undoes it (bytes at `pos`, `del` long, by `ins`), or nil.
  public func undoEdit(_ c: Change) -> (pos: Int, del: Int, ins: String)? {
    guard canUndo(c) else { return nil }
    return (c.pos, c.len, String(decoding: c.old, as: UTF8.self))
  }

  public func markUndone(_ id: Int) {
    guard let i = changes.firstIndex(where: { $0.id == id }) else { return }
    changes[i].undone = true
    onChange?()
  }

  /// One line for the list: what it did, shortened.
  public static func summary(_ c: Change) -> String {
    func clip(_ b: [UInt8]) -> String {
      let s = String(decoding: b, as: UTF8.self).replacingOccurrences(of: "\n", with: " ⏎ ").trimmingCharacters(in: .whitespaces)
      return s.count > 60 ? String(s.prefix(57)) + "…" : s
    }
    if c.old.isEmpty { return "+ " + clip(c.new) }
    if c.new.isEmpty { return "− " + clip(c.old) }
    return clip(c.old) + " → " + clip(c.new)
  }

  public static func color(_ c: Change) -> NSColor { c.disk ? NSColor.systemPurple : NativeEditor.color(c.colorKey) }
}
