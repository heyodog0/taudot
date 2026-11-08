import AppKit
import Testing
@testable import TaudotReview
@testable import TaudotShared

private func s(_ x: String) -> Value { .string(x) }
private func i(_ x: Int) -> Value { .int(Int64(x)) }
private func m(_ pairs: [(String, Value)]) -> Value { .map(pairs.map { (.string($0.0), $0.1) }) }

private func item(_ id: String, line: Int, kind: ReviewKind = .comment, resolved: Bool = false, text: String = "A comment") -> ReviewItem {
  ReviewItem(
    id: id, kind: kind, threadID: kind == .comment ? id : nil, author: ReviewUser(id: "u1", name: "Ada Lovelace", initials: "AL"),
    color: "#3b82f6", ts: Date(timeIntervalSinceNow: -300), quote: "word",
    messages: kind == .comment ? [ReviewMessage(id: "m-\(id)", text: text, ts: Date(timeIntervalSinceNow: -300), user: ReviewUser(id: "u1", name: "Ada Lovelace", initials: "AL"), mine: false)] : [],
    range: ReviewRange(line: line, col: 0, endLine: line, endCol: 4), resolved: resolved)
}

// ---- model ----------------------------------------------------------------------------------------------------------

@Test func decodesReviewPayload() {
  let user = m([("user_id", s("u-bot")), ("name", s("Ada Lovelace")), ("initials", s("AL"))])
  let payload = m([
    ("buf", i(3)), ("path", s("main.tex")), ("doc_id", s("d1")), ("me", s("u-me")), ("supported", .bool(true)), ("track", .bool(false)),
    ("items", .array([
      m([("id", s("t1")), ("kind", s("comment")), ("thread_id", s("t1")), ("author", user), ("color", s("#8cf8f7")),
         ("ts", i(1_700_000_000_000)), ("quote", s("answer")), ("line", i(10)), ("col", i(4)), ("end_line", i(10)), ("end_col", i(10)),
         ("resolved", .bool(false)),
         ("messages", .array([m([("id", s("m1")), ("text", s("Is it?")), ("ts", .float(1.7e12)), ("user", user), ("mine", .bool(false))])]))]),
      m([("id", s("c1")), ("kind", s("tracked_insert")), ("author", user), ("ts", i(1)), ("quote", s(" (citation)")),
         ("line", i(12)), ("col", i(0)), ("end_line", i(12)), ("end_col", i(11)), ("resolved", .bool(false)), ("messages", .map([]))]),
      m([("id", s("bad")), ("kind", s("nope"))]),
    ])),
  ])
  let st = ReviewState(payload)
  #expect(st.buf == 3 && st.path == "main.tex" && st.me == "u-me" && st.supported)
  #expect(st.items.count == 2)
  #expect(st.items[0].range == ReviewRange(line: 10, col: 4, endLine: 10, endCol: 10))
  #expect(st.items[0].messages.first?.text == "Is it?")
  #expect(st.items[0].author.initials == "AL")
  #expect(st.items[1].kind == .insert && st.items[1].messages.isEmpty)
  #expect(NSColor(hex: st.items[0].color!) != nil)

  let cur = ReviewCursor(m([("buf", i(3)), ("line", i(10)), ("col", i(5)), ("here", .array([s("t1")])),
                            ("visual", m([("line", i(1)), ("col", i(0)), ("end_line", i(1)), ("end_col", i(3))]))]))
  #expect(cur.here == ["t1"] && cur.visual == ReviewRange(line: 1, col: 0, endLine: 1, endCol: 3))
  #expect(ReviewCursor(m([("buf", i(3)), ("line", i(0)), ("col", i(0)), ("here", .array([])), ("visual", .null)])).visual == nil)
}

@Test func msgpackRoundTrips() {
  let v: Value = .array([.int(0), .int(-5), .int(300), .int(-70000), .string(String(repeating: "x", count: 40)), .bool(true), .null,
                         .float(1.5), m([("a", .array([]))])])
  var bytes: [UInt8] = []
  Msgpack.encode(v, into: &bytes)
  var buf = bytes + bytes.prefix(3)
  let out = Msgpack.drain(&buf)
  #expect(out == [v])
  #expect(buf.count == 3)
}

// ---- layout ---------------------------------------------------------------------------------------------------------

@Test func stackPushesDown() {
  #expect(ReviewLayout.stack(anchors: [0, 10, 200], heights: [50, 50, 50], gap: 8) == [0, 58, 200])
  #expect(ReviewLayout.stack(anchors: [0, 10, 70], heights: [50, 50, 50], gap: 8) == [0, 58, 116])
}

@Test func selectedKeepsItsPlace() {
  // The second is selected: it stays at 10; the first moves up above it, the third goes below.
  #expect(ReviewLayout.stack(anchors: [0, 10, 20], heights: [50, 50, 50], selected: 1, gap: 8) == [-48, 10, 68])
  // Far apart: nobody moves.
  #expect(ReviewLayout.stack(anchors: [0, 300, 600], heights: [50, 50, 50], selected: 1, gap: 8) == [0, 300, 600])
  // Cards before the selection still stack among themselves before moving up.
  #expect(ReviewLayout.stack(anchors: [0, 0, 500], heights: [50, 50, 50], selected: 2, gap: 8) == [0, 58, 500])
}

// ---- margin ---------------------------------------------------------------------------------------------------------

@MainActor private func margin(_ items: [ReviewItem], geometry: FixedLineGeometry) -> ReviewMarginView {
  let v = ReviewMarginView(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
  v.animationDuration = 0
  v.geometry = geometry
  v.state = ReviewState(buf: 1, items: items)
  v.layoutSubtreeIfNeeded()
  v.place()
  return v
}

@MainActor @Test func cardsSitAtTheirLines() {
  let g = FixedLineGeometry(lineHeight: 20, top: 0)
  let v = margin([item("a", line: 5), item("b", line: 20)], geometry: g)
  let f = v.targetFrames()
  #expect(f["a"]?.minY == 100)
  #expect(f["b"]?.minY == 400)
  #expect(v.displayedFrames()["a"] == f["a"])
}

@MainActor @Test func overlappingCardsPushDown() {
  let g = FixedLineGeometry(lineHeight: 20)
  let v = margin([item("a", line: 5), item("b", line: 6), item("c", line: 7)], geometry: g)
  let f = v.targetFrames()
  #expect(f["a"]!.minY == 100)
  #expect(f["b"]!.minY == f["a"]!.maxY + 8)
  #expect(f["c"]!.minY == f["b"]!.maxY + 8)
}

@MainActor @Test func selectedCardStaysAndExpands() {
  let g = FixedLineGeometry(lineHeight: 20)
  // (lines low enough that "a", moving up for the selected card, stays below the panel's top)
  let v = margin([item("a", line: 10), item("b", line: 11), item("c", line: 12)], geometry: g)
  let collapsed = v.targetFrames()["b"]!.height
  var sent: [ReviewAction] = []
  v.onAction = { sent.append($0) }
  v.select("b")
  let f = v.targetFrames()
  #expect(f["b"]!.minY == 220)
  #expect(f["a"]!.maxY + 8 == 220)
  #expect(f["c"]!.minY == f["b"]!.maxY + 8)
  #expect(f["b"]!.height > collapsed)
  #expect(sent == [.select("b")])
}

@MainActor @Test func cardsFollowScrollingInTheSameCall() {
  let g = FixedLineGeometry(lineHeight: 20)
  let v = margin([item("a", line: 10)], geometry: g)
  #expect(v.displayedFrames()["a"]!.minY == 200)
  g.top = -37.5  // one frame of a smooth scroll
  #expect(v.displayedFrames()["a"]!.minY == 162.5)
}

@MainActor @Test func resolvedHiddenBehindToggle() {
  let g = FixedLineGeometry()
  let v = margin([item("a", line: 1), item("r", line: 3, resolved: true)], geometry: g)
  #expect(v.shown.map(\.id) == ["a"])
  v.showResolved = true
  #expect(v.shown.map(\.id) == ["a", "r"])
}

@MainActor @Test func cursorSelectsTheCardUnderIt() {
  let g = FixedLineGeometry()
  let v = margin([item("a", line: 1), item("b", line: 3)], geometry: g)
  v.cursor = ReviewCursor(buf: 1, line: 3, col: 1, here: ["b"])
  #expect(v.selectedID == "b")
  v.cursor = ReviewCursor(buf: 1, line: 8, col: 0, here: [])
  #expect(v.selectedID == nil)
}

@MainActor @Test func newCommentOpensADraft() {
  let g = FixedLineGeometry()
  let v = margin([item("a", line: 1)], geometry: g)
  v.cursor = ReviewCursor(buf: 1, line: 4, col: 0, here: [], visual: ReviewRange(line: 4, col: 0, endLine: 4, endCol: 5))
  v.beginNewComment(quote: "first")
  #expect(v.shown.map(\.id) == ["a", "draft"])
  #expect(v.selectedID == "draft")
  let draftTop = v.displayedFrames()["draft"]!.minY
  // Sent: the draft stays where it is until the comment comes back...
  let r = ReviewRange(line: 4, col: 0, endLine: 4, endCol: 5)
  v.actionSucceeded(.comment(r, text: "x"))
  #expect(v.shown.map(\.id) == ["a", "draft"])
  // ...then the real card takes its place, no jump.
  var back = item("c", line: 4, text: "x")
  back.range = r
  v.state = ReviewState(buf: 1, items: [item("a", line: 1), back])
  #expect(v.shown.map(\.id) == ["a", "c"])
  #expect(v.displayedFrames()["c"]!.minY == draftTop)
  #expect(v.draftItem == nil && v.selectedID == "c")
}

@MainActor private func key(_ code: UInt16, _ chars: String, _ mods: NSEvent.ModifierFlags = []) -> NSEvent {
  NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: 0, context: nil,
                   characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
}

@MainActor @Test func draftKeysAndButtons() {
  let g = FixedLineGeometry()
  let v = margin([item("a", line: 1), item("b", line: 9)], geometry: g)
  var sent: [ReviewAction] = []
  v.onAction = { sent.append($0) }
  let r = ReviewRange(line: 4, col: 2, endLine: 5, endCol: 3)
  v.beginNewComment(on: r, quote: "one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty")
  let d = v.card("draft")!
  // Others step back while drafting.
  #expect(v.card("a")!.alphaValue == 0.5 && d.alphaValue == 1)
  // The quote: at most 3 lines.
  let quote = d.subviews.compactMap { $0 as? QuoteBar }.first!
  #expect(quote.content.maximumNumberOfLines == 3)
  // The Comment button is off until there is text.
  let row = d.subviews.compactMap { $0 as? ButtonRow }.first!
  #expect(row.buttons.map(\.title) == ["Cancel", "Comment"])
  #expect(row.buttons[1].isEnabled == false)
  let tv = d.reply!
  tv.insertText("Does it", replacementRange: tv.selectedRange())
  #expect(row.buttons[1].isEnabled)
  // ⇧↩ is a new line, ↩ sends.
  tv.keyDown(with: key(36, "\r", .shift))
  tv.insertText("hold?", replacementRange: tv.selectedRange())
  #expect(tv.string == "Does it\nhold?")
  #expect(sent.filter { $0.kind == "comment" }.isEmpty)
  tv.keyDown(with: key(36, "\r"))
  #expect(sent.last == .comment(r, text: "Does it\nhold?"))
  // Sending: no second send.
  tv.keyDown(with: key(36, "\r"))
  #expect(sent.filter { $0.kind == "comment" }.count == 1)
}

@MainActor @Test func escapeAsksOnlyWhenTyped() {
  let g = FixedLineGeometry()
  let v = margin([item("a", line: 1)], geometry: g)
  var asked: [String] = []
  var answer = false
  v.confirm = { q, done in asked.append(q); done(answer) }
  let r = ReviewRange(line: 4, col: 0, endLine: 4, endCol: 3)
  // Nothing typed: Esc closes the draft at once.
  v.beginNewComment(on: r, quote: "abc")
  v.card("draft")!.reply!.keyDown(with: key(53, "\u{1b}"))
  #expect(asked.isEmpty && v.draftItem == nil)
  // Typed: asked; "no" keeps it, "yes" drops it.
  v.beginNewComment(on: r, quote: "abc")
  v.card("draft")!.reply!.insertText("draft", replacementRange: NSRange(location: 0, length: 0))
  v.card("draft")!.reply!.keyDown(with: key(53, "\u{1b}"))
  #expect(asked == ["Discard this comment?"] && v.draftItem != nil)
  answer = true
  v.card("draft")!.cancel()
  #expect(v.draftItem == nil)
}

@MainActor @Test func pillSitsUnderTheEndOfTheSelection() async {
  let g = FixedLineGeometry(lineHeight: 20, top: 0)
  let host = FlippedView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
  let ed = FlippedView(frame: NSRect(x: 300, y: 0, width: 700, height: 600))
  host.addSubview(ed)
  let v = margin([item("a", line: 1)], geometry: g)
  host.addSubview(v)
  v.editorView = ed
  v.pillDelay = 0.01
  // End on line 10, second screen row of it, after grid column 35 of 70.
  v.cursor = ReviewCursor(buf: 1, line: 10, col: 0, here: [], visual: ReviewRange(line: 9, col: 3, endLine: 10, endCol: 40),
                          visualEnd: SelectionEnd(wrap: 1, screenCol: 35, columns: 70))
  #expect(v.pill.isHidden)  // not at once: it waits for the selection to be still
  for _ in 0..<100 where v.pill.isHidden { try? await Task.sleep(for: .milliseconds(10)) }
  #expect(!v.pill.isHidden && v.pill.superview === host)
  let f = host.convert(v.pill.frame, to: ed)
  #expect(abs(f.minY - (10 * 20 + 20 + 20 + 4)) < 0.01)  // below the end's screen row
  #expect(abs(f.minX - (35 * 10 - 12)) < 0.01)  // 700 pt / 70 columns
  // Scrolling moves it with the text in the same call.
  g.top = -40
  #expect(abs(host.convert(v.pill.frame, to: ed).minY - (f.minY - 40)) < 0.01)
  // A changing selection hides it; it comes back once still.
  v.cursor.visualEnd = SelectionEnd(wrap: 1, screenCol: 40, columns: 70)
  #expect(v.pill.isHidden)
  for _ in 0..<100 where v.pill.isHidden { try? await Task.sleep(for: .milliseconds(10)) }
  #expect(!v.pill.isHidden)
  // A draft open: no pill. Selection gone: no pill.
  v.beginNewComment(quote: "x")
  #expect(v.pill.isHidden)
  v.select(nil)
  v.cursor.visual = nil
  v.cursor.visualEnd = nil
  try? await Task.sleep(for: .milliseconds(100))
  #expect(v.pill.isHidden)
}

@MainActor @Test func deleteAsksFirst() {
  let g = FixedLineGeometry()
  let v = margin([item("a", line: 1)], geometry: g)
  var sent: [ReviewAction] = []
  v.onAction = { sent.append($0) }
  var answer = false
  v.confirm = { _, done in done(answer) }
  v.select("a")
  sent = []
  let card = v.subviews.flatMap(\.subviews).compactMap { $0 as? ReviewCardView }.first!
  card.onAction?(.delete("a"))
  #expect(sent.isEmpty)
  answer = true
  card.onAction?(.delete("a"))
  #expect(sent == [.delete("a")])
}

@MainActor @Test func placeIsCheapEnoughForEveryFrame() {
  let g = FixedLineGeometry(lineHeight: 18, lineCount: 2000, viewHeight: 900)
  let items = (0..<60).map { item("i\($0)", line: $0 * 7, text: "Comment number \($0) with a few words in it") }
  let v = margin(items, geometry: g)
  v.place()
  let t0 = Date()
  for k in 0..<240 { g.top = -CGFloat(k) * 3.3 }  // 240 frames of scrolling
  let per = Date().timeIntervalSince(t0) / 240 * 1000
  print("place(): \(String(format: "%.3f", per)) ms per frame, 60 cards")
  #expect(per < 2)
  // Off-screen lines have no card (Quiet); the first one on screen sits exactly at its line.
  #expect(v.card("i0")?.isHidden == true)
  let f7 = v.displayedFrames()["i7"]?.minY ?? .nan
  #expect(abs(f7 - (49 * 18 - 239 * 3.3)) < 0.01, "i7 at \(f7)")
}

@MainActor @Test func layoutChangesAnimateThenSettle() async {
  let g = FixedLineGeometry(lineHeight: 20)
  let w = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 320, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
  let v = ReviewMarginView(frame: NSRect(x: 0, y: 0, width: 320, height: 600))
  w.contentView = v
  w.orderBack(nil)
  defer { w.orderOut(nil) }
  v.geometry = g
  v.state = ReviewState(buf: 1, items: [item("a", line: 10), item("b", line: 11), item("c", line: 12)])
  try? await Task.sleep(for: .milliseconds(400))
  v.animationDuration = 0.2
  v.select("b")
  // Right after: still near the old place, moving.
  let target = v.targetFrames()["a"]!
  let first = v.displayedFrames()["a"]!
  #expect(abs(first.minY - target.minY) > 5)
  // Mid-scroll during the animation: the scroll applies at once on top of the easing, and doesn't restart or
  // retarget it (what is left of the animation is the same offset from the new target, give or take the
  // microseconds between the two reads).
  // The clock is frozen across the two reads, so the comparison is at one animation time.
  let frozen = CACurrentMediaTime()
  v.now = { frozen }
  v.place()
  let left = v.displayedFrames()["a"]!.minY - v.targetFrames()["a"]!.minY
  g.top = -10
  let leftAfter = v.displayedFrames()["a"]!.minY - v.targetFrames()["a"]!.minY
  #expect(abs(leftAfter - left) < 0.01, "animation offset \(left) → \(leftAfter) across a scroll")
  v.now = CACurrentMediaTime
  for _ in 0..<150 where v.displayedFrames()["a"] != v.targetFrames()["a"] { try? await Task.sleep(for: .milliseconds(20)) }
  #expect(v.displayedFrames()["a"] == v.targetFrames()["a"])
  #expect(v.targetFrames()["a"]!.minY == target.minY - 10)
}

@MainActor @Test func cardsAreRightAlignedTowardTheText() {
  let g = FixedLineGeometry(lineHeight: 20)
  let v = margin([item("a", line: 5), item("b", line: 20)], geometry: g)
  let f = v.targetFrames()
  #expect(f["a"]!.maxX == 300 - v.textGap)
  #expect(f["a"]!.minX >= 10)
  v.select("b")
  let s = v.targetFrames()
  #expect(s["b"]!.maxX > f["b"]!.maxX && s["b"]!.maxX < 300)  // the selected card leans toward the text, inside the gap
  #expect(s["a"]!.maxX == f["a"]!.maxX)
}

/// The line's rect in the reply box: the text view's line fragment, in the box's coordinates.
@MainActor private func replyLines(_ card: ReviewCardView) -> (box: NSRect, first: NSRect, last: NSRect) {
  let tv = card.reply!, box = tv.superview!
  let lm = tv.layoutManager!
  lm.ensureLayout(for: tv.textContainer!)
  let n = max(1, lm.numberOfGlyphs)
  func rect(_ g: Int) -> NSRect {
    var r = lm.numberOfGlyphs == 0 ? lm.extraLineFragmentRect : lm.lineFragmentUsedRect(forGlyphAt: g, effectiveRange: nil)
    r.origin.y += tv.textContainerOrigin.y
    return box.convert(r, from: tv)
  }
  return (box.bounds, rect(0), rect(n - 1))
}

@MainActor @Test func replyTextIsCentredInItsField() {
  let card = ReviewCardView(item: item("a", line: 1))
  card.expanded = true
  card.frame.size.width = 280
  card.layoutContent(width: 280)
  card.reply!.string = "asdasd"
  card.reply!.didChangeText()
  // What NSTextView does on its own after an edit; it must not move the text inside the box.
  card.reply!.sizeToFit()
  card.layoutContent(width: 280)
  card.reply!.superview!.layoutSubtreeIfNeeded()
  var (box, line, _) = replyLines(card)
  #expect(box.height == ReplyTextView.minHeight)
  #expect(card.reply!.frame == box)
  #expect(abs(line.minY - (box.height - line.maxY)) <= 0.5)
  // Wrapped: the same space above the first line and below the last.
  card.reply!.string = String(repeating: "a longer reply that wraps ", count: 4)
  card.reply!.didChangeText()
  card.layoutContent(width: 280)
  card.reply!.superview!.layoutSubtreeIfNeeded()
  let wrapped = replyLines(card)
  #expect(wrapped.box.height > ReplyTextView.minHeight)
  #expect(abs(wrapped.first.minY - (wrapped.box.height - wrapped.last.maxY)) <= 0.5)
  // Empty (the placeholder): the insertion point's line is centred too.
  card.reply!.string = ""
  card.reply!.didChangeText()
  card.layoutContent(width: 280)
  card.reply!.superview!.layoutSubtreeIfNeeded()
  (box, line, _) = replyLines(card)
  #expect(box.height == ReplyTextView.minHeight)
}

@MainActor private final class FakeNvim: NeovimBridge {
  func notify(_ name: String, _ handler: @escaping @MainActor ([Value]) -> Void) {}
  func execLua(_ code: String, _ args: [Value]) async throws -> Value { .bool(true) }
  func command(_ cmd: String) async throws {}
}

@MainActor @Test func transientEmptyListKeepsTheCards() async {
  let g = FixedLineGeometry()
  let v = margin([], geometry: g)
  let c = ReviewController(nvim: FakeNvim(), margin: v)
  c.emptyHold = 0.15
  var applied: [Int] = []
  c.onStateApplied = { applied.append($0.items.count) }
  c.receive(ReviewState(buf: 1, items: [item("a", line: 1), item("b", line: 5)]))
  #expect(v.shown.count == 2)
  // Empty for the same buffer (ranges reloading, a float's moment): held...
  c.receive(ReviewState(buf: 1, items: []))
  #expect(v.shown.count == 2)
  // ...and dropped when the list comes back.
  c.receive(ReviewState(buf: 1, items: [item("a", line: 1), item("b", line: 5)]))
  try? await Task.sleep(for: .milliseconds(300))
  #expect(v.shown.count == 2)
  #expect(!applied.contains(0))
  // Empty that lasts: believed after the hold.
  c.receive(ReviewState(buf: 1, items: []))
  #expect(v.shown.count == 2)
  for _ in 0..<150 where !(v.shown.isEmpty && applied.last == 0) { try? await Task.sleep(for: .milliseconds(20)) }
  #expect(v.shown.isEmpty && applied.last == 0)
  // Another file, or one that isn't synced: at once.
  c.receive(ReviewState(buf: 1, items: [item("a", line: 1)]))
  var other = ReviewState(buf: 2, items: [])
  other.synced = false
  c.receive(other)
  #expect(v.shown.isEmpty)
}

/// Lines that wrap to several rows, like the editor: exact positions for the lines on screen, and outside them
/// the editor's estimate (one row per line, counted from the first visible line), which is wrong across wraps.
@MainActor private final class WrappedGeometry: EditorGeometry {
  var buffer = 1
  let lineHeight: CGFloat = 20
  let rows: [Int]  // screen rows of each line
  var scroll: CGFloat = 0 { didSet { for h in handlers { h() } } }  // document y at the view's top
  let viewHeight: CGFloat = 400
  private var handlers: [@MainActor () -> Void] = []
  init(rows: [Int]) { self.rows = rows }
  func docY(_ line: Int) -> CGFloat { CGFloat(rows.prefix(line).reduce(0, +)) * lineHeight }
  var visibleLines: ClosedRange<Int> {
    let first = (0..<rows.count).last { docY($0) <= scroll } ?? 0
    let last = (0..<rows.count).last { docY($0) < scroll + viewHeight } ?? first
    return first...last
  }
  func y(ofLine line: Int) -> CGFloat? {
    let v = visibleLines
    if v.contains(line) { return docY(line) - scroll }
    // the estimate beyond the laid-out lines: no wraps assumed
    if line > v.upperBound { return docY(v.upperBound) - scroll + CGFloat(line - v.upperBound) * lineHeight }
    return docY(v.lowerBound) - scroll - CGFloat(v.lowerBound - line) * lineHeight
  }
  func onChange(_ handler: @escaping @MainActor () -> Void) { handlers.append(handler) }
}

@MainActor @Test func cardsScrollAsOneColumn() {
  // Every third line wraps to 4 rows; comments on nearby lines (a long range spans the wrapped ones).
  let rows = (0..<120).map { $0 % 3 == 1 ? 4 : 1 }
  let g = WrappedGeometry(rows: rows)
  var items = [item("a", line: 10), item("b", line: 11), item("c", line: 13), item("d", line: 40), item("e", line: 41)]
  for i in items.indices { items[i].docRow = rows.prefix(items[i].range.line).reduce(0, +) }
  let v = ReviewMarginView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
  v.animationDuration = 0
  v.geometry = g
  v.state = ReviewState(buf: 1, items: items)
  v.layoutSubtreeIfNeeded()
  _ = v.targetFrames()
  let solves = v.solveCount
  let first = v.targetFrames()
  var worstPair: CGFloat = 0, worstLine: CGFloat = 0
  // Scroll down through the wrapped lines and back, in uneven steps (a flick's frames).
  // Quiet: cards only for lines on screen. While that set stays the same, the cards move as one column (no
  // re-stacking); the stack is solved again only when a card comes or goes.
  var s: CGFloat = 0
  var prev = first, changes = 0
  _ = worstLine
  for step in [3.5, 7, 12.25, 20, 31, 9, 2.5] + Array(repeating: 17.0, count: 40) + Array(repeating: -23.5, count: 30) {
    s = max(0, s + step)
    g.scroll = s
    let f = v.targetFrames()
    if Set(f.keys) != Set(prev.keys) { changes += 1; prev = f; continue }
    let ids = f.keys.sorted()
    // (while the top card is held under the top edge it pushes the rest: skip those frames)
    let held = v.cardsTop + 12
    if f.values.contains(where: { $0.minY < held }) || prev.values.contains(where: { $0.minY < held }) { prev = f; continue }
    for (a, b) in zip(ids, ids.dropFirst()) {
      let d0 = prev[b]!.minY - prev[a]!.minY, d = f[b]!.minY - f[a]!.minY
      // (a card held under the top edge doesn't move with the rest)
      if prev[a]!.minY > 10 && f[a]!.minY > 10 { worstPair = max(worstPair, abs(d - d0)) }
    }
    prev = f
  }
  #expect(worstPair < 0.01, "card-to-card distance changed by \(worstPair) pt while scrolling")
  #expect(v.solveCount - solves <= changes, "re-solved \(v.solveCount - solves) times for \(changes) changes of the cards on screen")
  #expect(changes > 0)
}
