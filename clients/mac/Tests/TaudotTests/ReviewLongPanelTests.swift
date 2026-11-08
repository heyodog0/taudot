// Long review panels: suggestions grouped and compact, the Comments / Suggestions filter, deleting behind •••.
import AppKit
import Testing
@testable import TaudotReview
@testable import TaudotShared

private let grace = ReviewUser(id: "u-grace", name: "Grace Hopper", initials: "GH")
private let alan = ReviewUser(id: "u-alan", name: "Alan Turing", initials: "AT")
private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

private func change(_ id: String, _ line: Int, by u: ReviewUser = grace, kind: ReviewKind = .insert, min: Double = 0, text: String = "word") -> ReviewItem {
  ReviewItem(id: id, kind: kind, author: u, ts: t0.addingTimeInterval(min * 60), quote: text, range: ReviewRange(line: line, col: 0, endLine: line, endCol: 2))
}
private func note(_ id: String, _ line: Int) -> ReviewItem {
  ReviewItem(id: id, kind: .comment, threadID: id, author: alan, quote: "q",
             messages: [ReviewMessage(id: "m" + id, text: "a note", ts: nil, user: alan, mine: false)], range: ReviewRange(line: line, col: 0, endLine: line, endCol: 1))
}

@Test func suggestionsGroupByAuthorNearbyAndSoon() {
  let items = [
    change("a", 10), { var b = change("b", 10, kind: .delete, min: 1, text: "other"); b.range = ReviewRange(line: 10, col: 30, endLine: 10, endCol: 30); return b }(), change("c", 12, min: 2),  // a run: within 2 lines, minutes
    change("d", 20, min: 3),  // too far down
    change("e", 21, by: alan, min: 3),  // another author
    change("f", 22, by: alan, min: 90),  // same author, near, but an hour and a half later
    change("g", 30), note("n", 30), change("h", 30),  // a comment breaks the run
  ]
  let g = ReviewGrouping.group(items)
  #expect(g.map(\.id) == ["group:a", "d", "e", "f", "g", "n", "h"])
  let first = g[0]
  #expect(first.isGroup && first.members.map(\.id) == ["a", "b", "c"] && first.changeIDs == ["a", "b", "c"])
  #expect(first.range.line == 10 && first.range.endLine == 12 && first.ts == t0.addingTimeInterval(120))
  #expect(g[1].changeIDs == ["d"] && g[5].changeIDs.isEmpty)
  #expect(ReviewGrouping.counts(items) == (1, 8))
}

@MainActor private func margin(_ items: [ReviewItem]) -> ReviewMarginView {
  let m = ReviewMarginView(frame: NSRect(x: 0, y: 0, width: 300, height: 800))
  m.animationDuration = 0
  m.geometry = FixedLineGeometry(lineHeight: 20, top: 0, lineCount: 100, viewHeight: 800)
  m.state = ReviewState(buf: 1, items: items)
  m.layoutSubtreeIfNeeded()
  return m
}

@MainActor @Test func groupedCompactCardsExpandWhenSelected() {
  let m = margin([change("a", 10, text: "kept"), change("b", 11, kind: .delete, min: 1, text: "gone"), change("c", 40), note("n", 50)])
  #expect(m.shown.map(\.id) == ["group:a", "c", "n"])
  let g = m.card("group:a")!, single = m.card("c")!, comment = m.card("n")!
  // One line each unless selected; comments stay full cards.
  #expect(g.isCompact && single.isCompact && !comment.isCompact)
  #expect(m.targetFrames()["group:a"]!.height == ReviewCardView.compactHeight)
  // The cursor on any of its changes selects the group; it opens with its changes and Accept all / Reject all.
  m.cursor = ReviewCursor(buf: 1, line: 11, col: 0, here: ["b"])
  #expect(m.selectedID == "group:a" && !g.isCompact)
  #expect(m.targetFrames()["group:a"]!.height > 3 * ReviewCardView.compactHeight)
  var sent: [ReviewAction] = []
  m.onAction = { sent.append($0) }
  let accept = g.subviews.compactMap { $0 as? ButtonRow }.first?.buttons.last
  accept?.performClick(nil)
  #expect(sent.last == .acceptAll(["a", "b"]))
  // A single suggestion's compact ✓.
  let ok = single.subviews.compactMap { $0 as? NSButton }.first { $0.toolTip?.hasPrefix("Accept") == true }
  ok?.performClick(nil)
  #expect(sent.last == .accept("c"))
}

@MainActor @Test func commentsSuggestionsFilter() {
  let d = FileManager.default.temporaryDirectory.appendingPathComponent("kinds-\(UUID().uuidString.prefix(6))")
  try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: d); UserDefaults.standard.removeObject(forKey: "taudot.sidebar.kinds." + d.standardizedFileURL.path) }
  let s = SidebarView(frame: NSRect(x: 0, y: 0, width: 300, height: 700))
  s.folder = d
  s.tab = .comments
  s.margin.geometry = FixedLineGeometry(lineHeight: 20, top: 0, lineCount: 100, viewHeight: 700)
  s.margin.animationDuration = 0
  s.margin.state = ReviewState(buf: 1, items: [change("a", 10), change("b", 40, by: alan), note("n", 20), note("o", 60)])
  s.layoutSubtreeIfNeeded()
  #expect(s.kinds == .all && s.margin.shown.count == 4)
  #expect(s.kindsControl.label(forSegment: 0) == "2 comments" && s.kindsControl.label(forSegment: 1) == "2 suggestions")
  s.kinds = .comments
  #expect(s.margin.shown.map(\.id) == ["n", "o"])
  s.kinds = .suggestions
  #expect(s.margin.shown.map(\.id) == ["a", "b"])
  s.kinds = []  // never neither
  #expect(!s.kinds.isEmpty)
  // Remembered for the project; the All list follows it.
  s.kinds = .suggestions
  #expect(s.overview.kinds == .suggestions)
  let again = SidebarView(frame: .zero)
  again.folder = d
  #expect(again.kinds == .suggestions)
}

@MainActor @Test func deleteIsBehindTheMoreMenuAndAsked() {
  let m = margin([note("n", 5)])
  var asked: [String] = []
  m.confirm = { q, done in asked.append(q); done(true) }
  var sent: [ReviewAction] = []
  m.onAction = { sent.append($0) }
  m.select("n")
  let card = m.card("n")!
  let tips = card.subviews.compactMap { ($0 as? NSButton)?.toolTip }
  #expect(tips.contains { $0.hasPrefix("Resolve") } && tips.contains("More") && !tips.contains("Delete thread"))
  let menu = card.moreMenu("n")
  #expect(menu.items.map(\.title) == ["Delete Comment…"])
  menu.performActionForItem(at: 0)
  #expect(asked == ["Delete this comment?"] && sent.contains(.delete("n")))
}

@MainActor @Test func acceptAllInTheFileIsAsked() {
  let s = SidebarView(frame: NSRect(x: 0, y: 0, width: 300, height: 700))
  s.tab = .comments
  s.margin.animationDuration = 0
  s.margin.geometry = FixedLineGeometry(lineHeight: 20, top: 0, lineCount: 100, viewHeight: 700)
  var st = ReviewState(buf: 1, items: [change("a", 10), change("b", 40, by: alan), note("n", 20)])
  st.path = "main.tex"
  s.margin.state = st
  var asked: [String] = []
  var answer = false
  s.margin.confirm = { q, done in asked.append(q); done(answer) }
  var sent: [ReviewAction] = []
  s.margin.onAction = { sent.append($0) }
  s.allInFile(accept: true)
  #expect(asked == ["Accept all 2 suggestions in main.tex?"] && sent.isEmpty)
  answer = true
  s.allInFile(accept: false)
  #expect(sent == [.rejectAll(["a", "b"])])
  UserDefaults.standard.removeObject(forKey: "taudot.sidebar.tab")
}

@Test func syntheticReviewInOverviewKinds() {
  let items = [OverviewItem(id: "c", path: "a.tex"), OverviewItem(id: "s", kind: .insert, path: "a.tex")]
  #expect(Overview.sections(items, filter: .open, kinds: .suggestions).flatMap { $0.items.map(\.id) } == ["s"])
  #expect(Overview.sections(items, filter: .open, kinds: .comments).flatMap { $0.items.map(\.id) } == ["c"])
}

@MainActor @Test func tabBadgeCountsOpenCommentsOnly() {
  let s = SidebarView(frame: NSRect(x: 0, y: 0, width: 300, height: 700))
  s.tab = .comments
  s.scope = .file
  s.margin.animationDuration = 0
  s.margin.geometry = FixedLineGeometry(lineHeight: 20, top: 0, lineCount: 100, viewHeight: 700)
  var done = note("r", 70)
  done.resolved = true
  // 5 open comments (one more resolved) and 73 suggestions: "Comments 5", the suggestions on the filter row.
  s.margin.state = ReviewState(buf: 1, items: (0..<5).map { note("n\($0)", $0 * 3) } + [done] + (0..<73).map { change("s\($0)", 20 + $0 % 40, min: Double($0)) })
  s.layoutSubtreeIfNeeded()
  let tabs = s.subviews.compactMap { $0 as? HeaderBar }.first!.subviews.compactMap { $0 as? NSSegmentedControl }.first { $0.label(forSegment: 0) == "Files" }!
  #expect(tabs.label(forSegment: 1) == "Comments 5")
  #expect(tabs.toolTip(forSegment: 1)?.hasPrefix("5 open comments · 73 suggestions") == true)
  #expect(s.kindsControl.label(forSegment: 0) == "5 comments" && s.kindsControl.label(forSegment: 1) == "73 suggestions")
  UserDefaults.standard.removeObject(forKey: "taudot.sidebar.tab")
  UserDefaults.standard.removeObject(forKey: "taudot.sidebar.scope")
}

@Test func addedThenRemovedIsOneItem() {
  let text = "a sentence that came in and later went out."
  var ins = change("i", 30, by: grace, kind: .insert, min: 0, text: text)
  ins.range = ReviewRange(line: 30, col: 10, endLine: 31, endCol: 20)
  var del = change("d", 30, by: grace, kind: .delete, min: 60 * 24 * 27, text: " " + text)  // a month later
  del.range = ReviewRange(line: 30, col: 10, endLine: 31, endCol: 20)
  let other = change("o", 30, by: alan, kind: .delete, min: 5, text: text)  // someone else's: not paired
  let g = ReviewGrouping.group([ins, del, other])
  #expect(g.map(\.id) == ["pair:i", "o"])
  #expect(g[0].isAddedThenRemoved && g[0].members.map(\.id) == ["i", "d"] && g[0].changeIDs == ["i", "d"])
  // Different text, or a deletion elsewhere: two cards as before.
  var far = del
  far.range = ReviewRange(line: 50, col: 0, endLine: 50, endCol: 3)
  #expect(ReviewGrouping.pairs([ins, far]).map(\.id) == ["i", "d"])
  var otherText = del
  otherText.quote = "something else"
  #expect(ReviewGrouping.pairs([ins, otherText]).map(\.id) == ["i", "d"])
}

@MainActor @Test func addedThenRemovedCard() {
  let text = "a sentence that came in and later went out."
  var ins = change("i", 30, kind: .insert, text: text)
  ins.range = ReviewRange(line: 30, col: 10, endLine: 31, endCol: 20)
  var del = change("d", 30, kind: .delete, min: 60, text: text)
  del.range = ReviewRange(line: 30, col: 10, endLine: 31, endCol: 20)
  let m = margin([ins, del])
  #expect(m.shown.map(\.id) == ["pair:i"])
  let card = m.card("pair:i")!
  #expect(card.isCompact)
  var sent: [ReviewAction] = []
  m.onAction = { sent.append($0) }
  func tap(_ prefix: String) { card.subviews.compactMap { $0 as? NSButton }.first { $0.toolTip?.hasPrefix(prefix) == true }?.performClick(nil) }
  tap("Accept both")
  tap("Reject the removal")
  #expect(sent == [.acceptAll(["i", "d"]), .reject("d")])
  // The cursor in it selects the one card: the text, "Added … · removed …".
  m.cursor = ReviewCursor(buf: 1, line: 30, col: 12, here: ["i", "d"])
  #expect(m.selectedID == "pair:i" && !card.isCompact)
  let labels = card.subviews.compactMap { ($0 as? NSTextField)?.stringValue }
  #expect(labels.contains { $0.hasPrefix("Added ") && $0.contains("· removed ") } && labels.contains("Added, then removed: “\(text)”"))
}

@MainActor @Test func aSelectedSingleInsertionKeepsItsTextAndButtons() {
  let m = margin([change("i", 10, kind: .insert, text: "a new clause"), change("d", 40, kind: .delete, text: "old words")])
  for id in ["i", "d"] {
    m.select(id)
    let c = m.card(id)!
    #expect(!c.isCompact)
    let tips = c.subviews.compactMap { ($0 as? NSButton)?.toolTip }
    #expect(tips.contains { $0.hasPrefix("Accept") } && tips.contains { $0.hasPrefix("Reject") }, "\(id): \(tips)")
    let texts: [String] = c.subviews.compactMap { ($0 as? NSTextField)?.stringValue }
    let want = id == "i" ? "Add “a new clause”" : "Delete “old words”"
    #expect(texts.contains(want), "\(id): \(texts)")
  }
}

@MainActor @Test func suggestionsReadInPlainLanguage() {
  func text(_ it: ReviewItem) -> String { ReviewCardView.plain(it, size: 12).string }
  var del = change("d", 5, kind: .delete, text: "careful")
  del.range = ReviewRange(line: 5, col: 10, endLine: 5, endCol: 10)
  var ins = change("i", 5, kind: .insert, min: 1, text: "cautious")
  ins.range = ReviewRange(line: 5, col: 10, endLine: 5, endCol: 18)
  let g = ReviewGrouping.group([ins, del])
  #expect(g.map(\.id) == ["replace:d"] && g[0].isReplacement && g[0].changeIDs == ["d", "i"])
  #expect(text(g[0]) == "Replace “careful” with “cautious”")
  #expect(text(change("a", 1, text: " (see below)")) == "Add “(see below)”")
  #expect(text(change("x", 1, kind: .delete, text: "The")) == "Delete “The”")
  // Someone else's insertion there isn't a replacement.
  var other = ins
  other.author = alan
  #expect(ReviewGrouping.pairs([del, other]).map(\.id) == ["d", "i"])
  // Cards: one line, the sentence; a group reads "Grace: 3 changes" and lists them when selected.
  let m = margin([ins, del, change("e", 6, text: "notably"), { var f = change("f", 6, kind: .delete, min: 2, text: "very"); f.range = ReviewRange(line: 6, col: 20, endLine: 6, endCol: 20); return f }()])
  #expect(m.shown.map(\.id) == ["group:replace:d"])
  let card = m.card("group:replace:d")!
  let line = card.subviews.compactMap { ($0 as? NSTextField)?.stringValue }.first ?? ""
  #expect(line == "Grace: 3 changes")
  m.select("group:replace:d")
  let lines = card.subviews.compactMap { ($0 as? NSTextField)?.stringValue }
  #expect(lines.contains("Replace “careful” with “cautious”") && lines.contains("Add “notably”") && lines.contains("Delete “very”"))
  var sent: [ReviewAction] = []
  m.onAction = { sent.append($0) }
  card.subviews.compactMap { $0 as? ButtonRow }.first?.buttons.last?.performClick(nil)
  #expect(sent.last == .acceptAll(["d", "i", "e", "f"]))
}
