// The review pane's keys (like Mail's list), the verbs the Review menu shares, the hints, and the filter rule.
import AppKit
import Testing
@testable import TaudotReview
@testable import TaudotShared

private let ada = ReviewUser(id: "u-ada", name: "Ada Lovelace", initials: "AL")
private let alan = ReviewUser(id: "u-alan", name: "Alan Turing", initials: "AT")
private func note(_ id: String, _ line: Int) -> ReviewItem {
  ReviewItem(id: id, kind: .comment, threadID: id, author: ada, quote: "q",
             messages: [ReviewMessage(id: "m" + id, text: "note \(id)", ts: nil, user: ada, mine: false)], range: ReviewRange(line: line, col: 0, endLine: line, endCol: 1))
}
private func change(_ id: String, _ line: Int, by u: ReviewUser = alan) -> ReviewItem {
  ReviewItem(id: id, kind: .insert, author: u, ts: Date(), quote: "text \(id)", range: ReviewRange(line: line, col: 0, endLine: line, endCol: 2))
}

@MainActor private final class Pane {
  let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
  let m = ReviewMarginView(frame: NSRect(x: 0, y: 0, width: 320, height: 800))
  var sent: [ReviewAction] = []
  init(_ items: [ReviewItem]) {
    UserDefaults.standard.set(true, forKey: ReviewMarginView.keyHintKey)
    w.contentView!.addSubview(m)
    m.animationDuration = 0
    m.geometry = FixedLineGeometry(lineHeight: 20, top: 0, lineCount: 100, viewHeight: 800)
    m.state = ReviewState(buf: 1, items: items)
    m.confirm = { _, done in done(true) }
    m.onAction = { [unowned self] in sent.append($0) }
    m.layoutSubtreeIfNeeded()
  }
  func key(_ code: UInt16, _ chars: String, _ mods: NSEvent.ModifierFlags = []) {
    let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: w.windowNumber, context: nil,
                             characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    if !mods.isEmpty, m.performKeyEquivalent(with: e) { return }
    m.keyDown(with: e)
  }
  var gotos: [String] { sent.compactMap { if case let .goto(id) = $0 { id } else { nil } } }
}
private let down = String(UnicodeScalar(NSDownArrowFunctionKey)!), up = String(UnicodeScalar(NSUpArrowFunctionKey)!)

@MainActor @Test func arrowsMoveTheSelectionAndTheEditorFollows() {
  let p = Pane([note("a", 2), change("b", 10), note("c", 20), change("d", 30, by: ada)])
  #expect(p.w.makeFirstResponder(p.m))
  #expect(p.m.selectedID == "a")  // focus selects the first
  p.key(125, down)
  #expect(p.m.selectedID == "b" && p.gotos.last == "b")
  p.key(125, down); p.key(125, down)
  #expect(p.m.selectedID == "d")
  p.key(126, up)
  #expect(p.m.selectedID == "c" && p.gotos.last == "c")
  p.key(115, "")  // Home
  #expect(p.m.selectedID == "a")
  p.key(119, "")  // End
  #expect(p.m.selectedID == "d")
}

@MainActor @Test func acceptRejectResolveThenTheNext() {
  let p = Pane([note("a", 2), change("b", 10), change("c", 20, by: ada), note("d", 30)])
  p.w.makeFirstResponder(p.m)
  p.m.select("b")
  p.key(36, "\r", [.command])  // ⌘↩
  #expect(p.sent.contains(.accept("b")) && p.m.selectedID == "c" && p.gotos.last == "c")
  p.key(51, "\u{7f}", [.command])  // ⌘⌫
  #expect(p.sent.contains(.reject("c")) && p.m.selectedID == "d")
  p.key(15, "r", [.command])  // ⌘R
  #expect(p.sent.contains(.resolve("d")) && p.m.selectedID == "c")  // the last: back to the one before
  // Accept on a comment: nothing (a beep), nothing sent.
  p.m.select("a")
  let n = p.sent.count
  p.key(36, "\r", [.command])
  #expect(p.sent.count == n)
}

@MainActor @Test func returnRepliesOrOpensSpaceTogglesEscLeaves() {
  let p = Pane([note("a", 2), change("g1", 10), change("g2", 11), change("e", 40)])
  p.w.makeFirstResponder(p.m)
  p.m.select("a")
  p.key(36, "\r")  // Return on a comment: its reply field
  #expect(p.w.firstResponder === p.m.card("a")?.reply)
  p.w.makeFirstResponder(p.m)
  p.m.select("group:g1")
  #expect(!p.m.card("group:g1")!.isCompact)
  p.key(49, " ")  // Space: collapse, still selected
  #expect(p.m.card("group:g1")!.isCompact && p.m.selectedID == "group:g1")
  p.key(36, "\r")  // Return on a suggestion: open it again
  #expect(!p.m.card("group:g1")!.isCompact)
  // ⌘↩ on the group accepts all of it.
  p.key(36, "\r", [.command])
  #expect(p.sent.contains(.acceptAll(["g1", "g2"])) && p.m.selectedID == "e")
  // Esc: the editor takes the keys back.
  let ed = NSTextView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
  p.w.contentView!.addSubview(ed)
  p.m.editorView = ed
  p.key(53, "\u{1b}")
  #expect(p.w.firstResponder === ed)
}

@MainActor @Test func buttonsShowTheirKeysAndTheHintShowsOnce() {
  UserDefaults.standard.removeObject(forKey: ReviewMarginView.keyHintKey)
  let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
  let m = ReviewMarginView(frame: NSRect(x: 0, y: 0, width: 320, height: 800))
  w.contentView!.addSubview(m)
  m.animationDuration = 0
  m.geometry = FixedLineGeometry(lineHeight: 20, top: 0, lineCount: 100, viewHeight: 800)
  m.state = ReviewState(buf: 1, items: [note("a", 2), change("b", 10)])
  m.layoutSubtreeIfNeeded()
  let tips = (m.card("a")!.subviews + m.card("b")!.subviews).compactMap { ($0 as? NSButton)?.toolTip }
  #expect(tips.contains("Resolve  ⌘R · ⌥⌘R") && tips.contains("Accept  ⌘↩ · ⌥⌘↩") && tips.contains("Reject  ⌘⌫ · ⌥⌘⌫"))
  #expect(!m.keyHintVisible)
  w.makeFirstResponder(m)
  #expect(m.keyHintVisible && m.keyHint.subviews.compactMap { ($0 as? NSTextField)?.stringValue } == [KeyHintBar.text])
  m.keyHint.onClose?()
  #expect(!m.keyHintVisible)
  w.makeFirstResponder(nil)
  w.makeFirstResponder(m)
  #expect(!m.keyHintVisible)  // once
}

@MainActor @Test func cyclingFollowsTheFilter() {
  let p = Pane([note("a", 2), change("b", 10), note("c", 20), change("d", 30, by: ada)])
  p.m.kinds = .suggestions
  p.w.makeFirstResponder(p.m)
  #expect(p.m.selectedID == "b")
  p.key(125, down)
  #expect(p.m.selectedID == "d")  // c, a comment, skipped
  p.m.kinds = .comments
  p.m.select("a")
  p.key(125, down)
  #expect(p.m.selectedID == "c")
}

@MainActor @Test func cmdFGoesToTheAllSearch() {
  let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
  let s = SidebarView(frame: w.contentView!.bounds)
  w.contentView!.addSubview(s)
  s.tab = .comments
  s.scope = .file
  s.margin.state = ReviewState(buf: 1, items: [note("a", 2)])
  s.focus()
  #expect(w.firstResponder === s.margin)
  let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: w.windowNumber, context: nil,
                           characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3)!
  #expect(s.margin.performKeyEquivalent(with: e))
  #expect(s.scope == .all && (w.firstResponder as? NSView)?.isDescendant(of: s.overview.search) == true)
  UserDefaults.standard.removeObject(forKey: "taudot.sidebar.scope")
  UserDefaults.standard.removeObject(forKey: "taudot.sidebar.tab")
}

// Overlapping and nested ranges: a chosen card stays chosen while the cursor is in its range.
private func ranged(_ id: String, _ l: Int, _ c: Int, _ el: Int, _ ec: Int) -> ReviewItem {
  var it = note(id, l)
  it.range = ReviewRange(line: l, col: c, endLine: el, endCol: ec)
  return it
}

@MainActor @Test func overlappingRangesKeepTheChosenCard() {
  // top: 10:0–12:20; bottom: 11:5–14:0 (overlapping); inner: 10:4–10:9 (nested in top).
  let p = Pane([ranged("top", 10, 0, 12, 20), ranged("bottom", 11, 5, 14, 0), ranged("inner", 10, 4, 10, 9)])
  let m = p.m
  // Clicked (or ]r / ⌥⌘↓ landed on) the bottom card; the jump puts the cursor at its start, inside top too.
  m.card("bottom")!.onSelect?()
  #expect(m.selectedID == "bottom")
  m.cursor = ReviewCursor(buf: 1, line: 11, col: 5, here: ["top", "bottom"])
  #expect(m.selectedID == "bottom")  // not flipped back to top
  // Moving within both ranges: still bottom. Leaving bottom (into top only): top.
  m.cursor = ReviewCursor(buf: 1, line: 12, col: 2, here: ["top", "bottom"])
  #expect(m.selectedID == "bottom")
  m.cursor = ReviewCursor(buf: 1, line: 10, col: 1, here: ["top"])
  #expect(m.selectedID == "top")
  // Nothing chosen, several ranges here: the innermost (starting last).
  m.select(nil)
  m.cursor = ReviewCursor(buf: 1, line: 10, col: 6, here: ["top", "inner"])
  #expect(m.selectedID == "inner")
  // A landing on top while inside inner: top stays (the chosen one), until the cursor leaves top.
  m.land(on: "top")
  m.cursor = ReviewCursor(buf: 1, line: 10, col: 7, here: ["inner", "top"])
  #expect(m.selectedID == "top")
}

@MainActor @Test func floatingCardShowsTheLandedOneOfOverlapping() {
  let host = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
  final class Ed: NSView { override var isFlipped: Bool { true } }
  let ed = Ed(frame: NSRect(x: 300, y: 0, width: 700, height: 600))
  let m = ReviewMarginView(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
  host.addSubview(ed); host.addSubview(m)
  m.animationDuration = 0
  m.floating.fade = 0
  m.geometry = FixedLineGeometry(lineHeight: 20, top: 0, lineCount: 100, viewHeight: 600)
  m.editorView = ed
  m.isHidden = true
  m.state = ReviewState(buf: 1, items: [ranged("top", 10, 0, 12, 20), ranged("bottom", 11, 5, 14, 0)])
  // The jump to bottom, then the cursor in both: the floating card shows bottom (and its switcher, 2 here).
  m.land(on: "bottom")
  m.cursor = ReviewCursor(buf: 1, line: 11, col: 5, here: ["top", "bottom"])
  #expect(m.floating.shownIDs == ["bottom"] && m.floating.pageCount == 2)
  // Without a landing: the innermost (starting last).
  m.cursor = ReviewCursor(buf: 1, line: 30, col: 0, here: [])
  RunLoop.main.run(until: Date().addingTimeInterval(0.4))
  m.cursor = ReviewCursor(buf: 1, line: 12, col: 0, here: ["top", "bottom"])
  #expect(m.floating.shownIDs == ["bottom"])
}
