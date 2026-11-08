// What the margin shows of a long review: comments and/or suggestions (tracked changes), and runs of suggestions by
// one person grouped into one card, as Overleaf does.
import Foundation

/// Which kinds the Comments tab shows (both by default; remembered per project).
public struct ReviewKinds: OptionSet, Sendable, Hashable {
  public let rawValue: Int
  public init(rawValue: Int) { self.rawValue = rawValue }
  public static let comments = ReviewKinds(rawValue: 1)
  public static let suggestions = ReviewKinds(rawValue: 2)
  public static let all: ReviewKinds = [.comments, .suggestions]
  public func shows(_ k: ReviewKind) -> Bool { contains(k == .comment ? .comments : .suggestions) }
}

public enum ReviewGrouping {
  /// Lines apart (from the last change's end) that still join a group.
  public static let lines = 2
  /// Time apart that still joins a group.
  public static let window: TimeInterval = 30 * 60

  /// Items in text order → the same with each run of tracked changes by one author (each within `lines` lines and
  /// `window` of the last) as one item whose `members` are the changes. A run of one stays as it is. Comments
  /// between changes break a run.
  public static func group(_ items: [ReviewItem]) -> [ReviewItem] {
    let items = pairs(items)
    var out: [ReviewItem] = []
    var run: [ReviewItem] = []
    func flush() {
      if run.count == 1 { out.append(run[0]) } else if let f = run.first, let l = run.last {
        var g = f
        g.id = "group:" + f.id
        g.members = run
        g.range = ReviewRange(line: f.range.line, col: f.range.col, endLine: l.range.endLine, endCol: l.range.endCol)
        g.ts = run.compactMap(\.ts).max()
        g.quote = run.map(\.quote).joined(separator: " ")
        out.append(g)
      }
      run = []
    }
    for it in items {
      if it.kind == .comment || it.id == "draft" { flush(); out.append(it); continue }
      if let last = run.last {
        let same = (last.author.id ?? last.author.name) == (it.author.id ?? it.author.name)
        let near = it.range.line - last.range.endLine <= lines
        let soon = { if let a = last.ts, let b = it.ts { abs(b.timeIntervalSince(a)) <= window } else { true } }()
        if !(same && near && soon) { flush() }
      }
      run.append(it)
    }
    flush()
    return out
  }

  /// An insertion later deleted (tracked) by the same person, the same text, where it is: one "added, then removed"
  /// item (members: the insertion, the deletion) in the insertion's place.
  public static func pairs(_ items: [ReviewItem]) -> [ReviewItem] {
    func key(_ u: ReviewUser) -> String { u.id ?? u.name }
    func text(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
    func pos(_ r: ReviewRange) -> (Int, Int) { (r.line, r.col) }
    func end(_ r: ReviewRange) -> (Int, Int) { (r.endLine, r.endCol) }
    var used = Set<String>()
    var pairOf: [String: ReviewItem] = [:]
    for ins in items where ins.kind == .insert && !text(ins.quote).isEmpty {
      guard let del = items.first(where: { d in
        d.kind == .delete && !used.contains(d.id) && key(d.author) == key(ins.author) && text(d.quote) == text(ins.quote)
          && pos(d.range) >= pos(ins.range) && pos(d.range) <= end(ins.range)
      }) else { continue }
      used.insert(del.id)
      var p = ins
      p.id = "pair:" + ins.id
      p.members = [ins, del]
      p.ts = [ins.ts, del.ts].compactMap { $0 }.max()
      pairOf[ins.id] = p
    }
    // A deletion and an insertion at the same place by the same person, soon after: a replacement.
    for del in items where del.kind == .delete && !used.contains(del.id) && !text(del.quote).isEmpty {
      guard let ins = items.first(where: { i in
        i.kind == .insert && !used.contains(i.id) && pairOf[i.id] == nil && key(i.author) == key(del.author) && text(i.quote) != text(del.quote)
          && (pos(i.range) == pos(del.range) || pos(i.range) == end(del.range))
          && { if let a = i.ts, let b = del.ts { abs(a.timeIntervalSince(b)) <= window } else { true } }()
      }) else { continue }
      used.insert(ins.id)
      var p = del
      p.id = "replace:" + del.id
      p.members = [del, ins]
      p.ts = [ins.ts, del.ts].compactMap { $0 }.max()
      pairOf[del.id] = p
    }
    return items.compactMap { it in used.contains(it.id) ? nil : (pairOf[it.id] ?? it) }
  }

  /// "5 comments · 97 suggestions" (open ones).
  public static func counts(_ items: [ReviewItem]) -> (comments: Int, suggestions: Int) {
    let open = items.filter { !$0.resolved }
    let c = open.filter { $0.kind == .comment }.count
    return (c, open.count - c)
  }
}
