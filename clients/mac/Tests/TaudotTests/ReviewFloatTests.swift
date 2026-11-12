// The floating card (margin hidden, cursor in a comment).
import AppKit
import Testing
@testable import TaudotReview
@testable import TaudotShared

private func comment(_ id: String, line: Int, col: Int = 10, endCol: Int = 20, age: TimeInterval = 300) -> ReviewItem {
  let u = ReviewUser(id: "u1", name: "Ada Lovelace", initials: "AL")
  return ReviewItem(
    id: id, kind: .comment, threadID: id, author: u, color: "#3b82f6", ts: Date(timeIntervalSinceNow: -age), quote: "word",
    messages: [ReviewMessage(id: "m-\(id)", text: "Comment \(id)", ts: Date(timeIntervalSinceNow: -age), user: u, mine: false)],
    range: ReviewRange(line: line, col: col, endLine: line, endCol: endCol))
}

@MainActor private struct Scene {
  let g = FixedLineGeometry(lineHeight: 20, top: 0)
  let host = FlippedView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
  let ed = FlippedView(frame: NSRect(x: 300, y: 0, width: 700, height: 600))
  let v = ReviewMarginView(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
  init(_ items: [ReviewItem], hidden: Bool = true) {
    host.addSubview(ed)
    host.addSubview(v)
    v.animationDuration = 0
    v.floating.fade = 0
    v.floating.leaveDelay = 0.05
    v.geometry = g
    v.editorView = ed
    v.isHidden = hidden
    v.state = ReviewState(buf: 1, items: items)
  }
  /// The cursor at (line, col) inside `here`, its row and the items' rows within their lines as gui.lua sends them.
  func cursor(_ line: Int, _ col: Int, here: [String], wrap: Int = 0, items: [String: ScreenAt.Item] = [:]) {
    var c = ReviewCursor(buf: 1, line: line, col: col, here: here)
    c.at = ScreenAt(columns: 70, cursorWrap: wrap, items: items)
    v.cursor = c
  }
  var frame: NSRect { host.convert(v.floating.stack.frame, to: ed) }
}

@MainActor @Test func floatsUnderItsCommentWhileTheMarginIsHidden() async {
  let s = Scene([comment("a", line: 5)])
  s.cursor(5, 12, here: ["a"], items: ["a": .init(startWrap: 0, startCol: 10, endWrap: 0)])
  #expect(s.v.floating.shownIDs == ["a"])
  #expect(s.v.floating.stack.superview === s.host && !s.v.floating.stack.isHidden)
  #expect(abs(s.frame.minY - (5 * 20 + 20 + 6)) < 0.01)  // just below the commented line
  #expect(abs(s.frame.minX - (10 * 10 - 12)) < 0.01)  // near the range's start (700 pt / 70 columns)
  let card = s.v.floating.card("a")!
  #expect(card.expanded && card.reply != nil)  // the thread, with its reply field

  // Scrolling: it moves with the text, in the same call.
  s.g.top = -40
  #expect(abs(s.frame.minY - (5 * 20 + 20 + 6 - 40)) < 0.01)
  s.g.top = 0

  // Typing in the range: the cursor and the range move, the same card stays, no fade.
  var it = comment("a", line: 5, endCol: 21)
  it.ts = s.v.state.items[0].ts
  it.messages = s.v.state.items[0].messages
  s.v.state = ReviewState(buf: 1, items: [it])
  s.cursor(5, 13, here: ["a"], items: ["a": .init(startWrap: 0, startCol: 10, endWrap: 0)])
  #expect(s.v.floating.card("a") === card && s.v.floating.stack.alphaValue == 1)

  // A moment out of the range (an edit on its edge) and back: nothing changes.
  s.cursor(5, 21, here: [])
  s.cursor(5, 20, here: ["a"], items: ["a": .init(startWrap: 0, startCol: 10, endWrap: 0)])
  try? await Task.sleep(for: .milliseconds(120))
  #expect(s.v.floating.shownIDs == ["a"] && s.v.floating.card("a") === card)

  // Leaving it for good: gone after the delay and the fade.
  s.cursor(9, 0, here: [])
  #expect(s.v.floating.shownIDs == ["a"])
  // (the fade's completion handler hides the stack: wait for it, not for a time)
  for _ in 0..<100 where !(s.v.floating.shownIDs.isEmpty && s.v.floating.stack.isHidden) { try? await Task.sleep(for: .milliseconds(20)) }
  #expect(s.v.floating.shownIDs.isEmpty && s.v.floating.stack.isHidden)
}

@MainActor @Test func floatKeepsClearOfTheCursorAndWrappedRows() {
  // A range over the second and third screen rows of line 5, the cursor in it: below the range's last row.
  let s = Scene([comment("a", line: 5)])
  s.cursor(5, 200, here: ["a"], wrap: 2, items: ["a": .init(startWrap: 1, startCol: 30, endWrap: 2)])
  #expect(abs(s.frame.minY - (5 * 20 + 3 * 20 + 6)) < 0.01)
  // The cursor moving between the range's rows (as a scroll drags it) moves nothing.
  s.cursor(5, 120, here: ["a"], wrap: 1, items: ["a": .init(startWrap: 1, startCol: 30, endWrap: 2)])
  #expect(abs(s.frame.minY - (5 * 20 + 3 * 20 + 6)) < 0.01)
  #expect(abs(s.frame.minX - (30 * 10 - 12)) < 0.01)
}

@MainActor @Test func floatsStackNewestFirstAboveWhenNoRoomBelow() {
  // (no settle timer in this test: settle() is called when wanted)
  let s = Scene([comment("old", line: 27, age: 900), comment("new", line: 27, age: 60)])
  s.cursor(27, 12, here: ["old", "new"], items: ["old": .init(startWrap: 0, startCol: 10, endWrap: 0), "new": .init(startWrap: 0, startCol: 10, endWrap: 0)])
  // Two threads at one place: one card (the newest) and a "1 of 2" switcher, not a stack over the text.
  #expect(s.v.floating.shownIDs == ["new"] && s.v.floating.pageCount == 2)
  #expect(!s.v.floating.switcher.isHidden && s.v.floating.switcher.label.stringValue == "1 of 2 comments here")
  #expect(s.v.floating.below == false)
  #expect(abs(s.frame.maxY - (27 * 20 - 6)) < 0.01)  // above the line
  #expect(s.v.floating.card("new")!.frame.minY > s.v.floating.switcher.frame.maxY)
  s.v.floating.step(1)
  #expect(s.v.floating.shownIDs == ["old"] && s.v.floating.switcher.label.stringValue == "2 of 2 comments here")
  s.v.floating.step(1)
  #expect(s.v.floating.shownIDs == ["new"])
  // Scrolling doesn't flip it while it has room...
  s.g.top = -100
  #expect(s.v.floating.below == false)
  // ...nor mid-scroll where it hasn't (the line near the top: it scrolls with its text)...
  s.g.top = -27 * 20 + 40
  #expect(s.v.floating.below == false)
  // ...and flips once the scroll has settled, then stays.
  s.v.floating.settle()
  #expect(s.v.floating.below == true)
  #expect(abs(s.frame.minY - (40 + 20 + 6)) < 0.01)
  s.g.top = -27 * 20 + 60
  #expect(s.v.floating.below == true)
}

@MainActor @Test func marginShownKeepsItsBehaviourHiddenFloats() {
  let s = Scene([comment("a", line: 5)], hidden: false)
  var sent: [ReviewAction] = []
  s.v.onAction = { sent.append($0) }
  s.cursor(5, 12, here: ["a"], items: ["a": .init(startWrap: 0, startCol: 10, endWrap: 0)])
  #expect(s.v.floating.shownIDs.isEmpty && s.v.selectedID == "a")
  // Hiding the margin: the card floats, nothing stays selected (the text's own highlight shows).
  s.v.isHidden = true
  #expect(s.v.floating.shownIDs == ["a"] && s.v.selectedID == nil)
  #expect(sent.last == .select(nil))
  // Moving within the range while hidden selects nothing.
  s.cursor(5, 14, here: ["a"], items: ["a": .init(startWrap: 0, startCol: 10, endWrap: 0)])
  #expect(s.v.selectedID == nil)
  // Shown again: no float, the card under the cursor selected.
  s.v.isHidden = false
  #expect(s.v.floating.shownIDs.isEmpty && s.v.selectedID == "a")
}

@MainActor @Test func floatingCardReplies() {
  let s = Scene([comment("a", line: 5)])
  var sent: [ReviewAction] = []
  s.v.onAction = { sent.append($0) }
  s.cursor(5, 12, here: ["a"])
  let card = s.v.floating.card("a")!
  card.reply!.string = "Agreed"
  card.send()
  #expect(sent == [.reply("a", text: "Agreed")])
  // A card with text in its field stays when the cursor leaves.
  s.cursor(9, 0, here: [])
  s.v.actionSucceeded(.reply("a", text: "Agreed"))
  #expect(card.reply!.string.isEmpty)
}

@MainActor @Test func noFloatWhileSelectingOrInAnotherBuffer() {
  let s = Scene([comment("a", line: 5)])
  var c = ReviewCursor(buf: 1, line: 5, col: 12, here: ["a"], visual: ReviewRange(line: 5, col: 10, endLine: 5, endCol: 14))
  s.v.cursor = c
  #expect(s.v.floating.shownIDs.isEmpty)  // the Comment pill's place
  c.visual = nil
  c.buf = 2
  s.v.cursor = c
  #expect(s.v.floating.shownIDs.isEmpty)
}

@Test func cursorPayloadDecodesScreenPositions() {
  let p: Value = .map([
    (.string("buf"), .int(1)), (.string("line"), .int(5)), (.string("col"), .int(3)), (.string("here"), .array([.string("a")])),
    (.string("visual"), .null),
    (.string("at"), .map([
      (.string("columns"), .int(80)), (.string("cursor_wrap"), .int(2)),
      (.string("items"), .map([(.string("a"), .map([(.string("start_wrap"), .int(1)), (.string("start_col"), .int(7)), (.string("end_wrap"), .int(2))]))])),
    ])),
  ])
  let c = ReviewCursor(p)
  #expect(c.at == ScreenAt(columns: 80, cursorWrap: 2, items: ["a": .init(startWrap: 1, startCol: 7, endWrap: 2)]))
}

@MainActor @Test func draftFloatsAtTheSelectionWhileHidden() {
  let s = Scene([comment("a", line: 5)])
  var sent: [ReviewAction] = []
  s.v.onAction = { sent.append($0) }
  // A selection on line 8 ending on its second screen row after column 30 (the pill's place), then ⌥⌘M.
  s.v.cursor = ReviewCursor(buf: 1, line: 8, col: 30, here: [], visual: ReviewRange(line: 8, col: 2, endLine: 8, endCol: 60),
                            visualEnd: SelectionEnd(wrap: 1, screenCol: 30, columns: 70))
  s.v.beginNewComment(quote: "the selected words")
  s.v.cursor = ReviewCursor(buf: 1, line: 8, col: 59, here: [])  // visual mode left
  #expect(s.v.floating.shownIDs == ["draft"])
  let d = s.v.floating.card("draft")!
  #expect(d.isDraft && d.reply != nil)
  #expect(abs(s.frame.minY - (8 * 20 + 2 * 20 + 6)) < 0.01)  // under the selection's last row
  #expect(abs(s.frame.minX - (30 * 10 - 12)) < 0.01)  // where the pill was
  // The cursor passing over another comment doesn't take it away.
  s.cursor(5, 12, here: ["a"], items: ["a": .init(startWrap: 0, startCol: 10, endWrap: 0)])
  #expect(s.v.floating.shownIDs == ["draft"])
  s.v.cursor = ReviewCursor(buf: 1, line: 8, col: 59, here: [])
  // Send: the comment goes with the selection's range; when it comes back its card takes the draft's place.
  d.reply!.string = "Needs a citation"
  d.send()
  #expect(sent.last == .comment(ReviewRange(line: 8, col: 2, endLine: 8, endCol: 60), text: "Needs a citation"))
  s.v.actionSucceeded(.comment(ReviewRange(line: 8, col: 2, endLine: 8, endCol: 60), text: "Needs a citation"))
  #expect(s.v.floating.shownIDs == ["draft"])  // until it's back
  var back = comment("new", line: 8, col: 2, endCol: 60, age: 0)
  back.messages[0].text = "Needs a citation"
  s.v.state = ReviewState(buf: 1, items: [s.v.state.items[0], back])
  #expect(s.v.draftItem == nil && s.v.floating.shownIDs == ["new"] && s.v.selectedID == nil)
  #expect(abs(s.frame.minX - (30 * 10 - 12)) < 0.01)  // where the draft was
  // Moving away lets it go.
  s.cursor(20, 0, here: [])
  #expect(s.v.floating.pinned == nil)
}

@MainActor @Test func floatingDraftCancels() {
  let s = Scene([])
  s.v.cursor = ReviewCursor(buf: 1, line: 3, col: 0, here: [], visual: ReviewRange(line: 3, col: 0, endLine: 3, endCol: 9),
                            visualEnd: SelectionEnd(wrap: 0, screenCol: 9, columns: 70))
  s.v.beginNewComment(quote: "x")
  s.v.cursor = ReviewCursor(buf: 1, line: 3, col: 8, here: [])
  var asked = false
  s.v.confirm = { _, done in asked = true; done(true) }
  let d = s.v.floating.card("draft")!
  d.cancel()  // empty: no question
  #expect(!asked && s.v.draftItem == nil)
}

@MainActor @Test func scrollingHoldsTheCardUntilItSettles() async {
  let s = Scene([comment("a", line: 10)])
  s.v.floating.settleDelay = 0.1
  s.cursor(10, 12, here: ["a"], items: ["a": .init(startWrap: 0, startCol: 10, endWrap: 0)])
  #expect(s.v.floating.shownIDs == ["a"])
  let f0 = s.frame
  // A fast scroll: the text moves, Neovim drags the cursor out of the range on the way.
  for k in 1...5 {
    s.g.top = CGFloat(-k * 20)
    if k == 2 { s.cursor(12, 0, here: []) }
    #expect(abs(s.frame.minY - (f0.minY - CGFloat(k * 20))) < 0.01, "frame \(k) moves with its text")
    #expect(s.v.floating.shownIDs == ["a"] && !s.v.floating.stack.isHidden, "frame \(k) shown")
  }
  #expect(s.v.floating.scrolling)
  // Still for the settle delay: the cursor is out, so it goes (after its leave delay and fade).
  for _ in 0..<100 where !s.v.floating.shownIDs.isEmpty { try? await Task.sleep(for: .milliseconds(20)) }
  #expect(!s.v.floating.scrolling && s.v.floating.shownIDs.isEmpty)
}

@MainActor @Test func cardMovesOnlyByItsFrameWhileScrolling() {
  let s = Scene([comment("a", line: 10)])
  s.cursor(10, 12, here: ["a"], items: ["a": .init(startWrap: 0, startCol: 10, endWrap: 0)])
  let card = s.v.floating.card("a")!
  let inner = card.frame
  var layouts = 0
  let obs = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: card, queue: nil) { _ in
    MainActor.assumeIsolated { layouts += 1 }
  }
  card.postsFrameChangedNotifications = true
  for k in 1...10 { s.g.top = CGFloat(-k * 7) }
  NotificationCenter.default.removeObserver(obs)
  // The stack is translated; the card inside it (its content, its shadow) never changes.
  #expect(card.frame == inner && layouts == 0)
  #expect(s.v.floating.stack.layer?.animationKeys()?.isEmpty ?? true)
}


@MainActor @Test func floatKeepsItsXWhenTheRangeStartScrollsAway() {
  // The range starts at column 30; Neovim's cursor payload knows it while its start is on screen, and gui.lua's
  // start column always. Scrolled so the start is above the view: the card stays where it was, never at the left wall.
  var it = comment("a", line: 10, age: 60)
  it.startCol = 30
  it.range = ReviewRange(line: 10, col: 30, endLine: 14, endCol: 5)
  let s = Scene([it])
  s.g.cellWidth = 8
  s.cursor(12, 2, here: ["a"], items: ["a": .init(startWrap: 0, startCol: 30, endWrap: 0)])
  let x0 = s.frame.minX
  #expect(x0 > 100)
  // Mid-scroll, the payload without the start (it is off screen now): same x.
  s.g.top = -230
  s.cursor(14, 1, here: ["a"], items: [:])
  #expect(abs(s.frame.minX - x0) < 0.5, "x \(s.frame.minX) vs \(x0)")
  // Settled, still from the range's start column, not 8.
  s.v.floating.settle()
  #expect(s.frame.minX > 100, "x \(s.frame.minX)")
}
