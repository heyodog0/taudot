// The Quiet design's Google Docs pieces: the review bar, the selected card sliding to its text, the preview modes,
// the connector setting.
import AppKit
import Testing
@testable import TaudotReview
@testable import TaudotShared

private let linus = ReviewUser(id: "u-l", name: "Linus Yarrow", initials: "LY")
private let ada = ReviewUser(id: "u-a", name: "Ada Lovelace", initials: "AL")
private func note(_ id: String, _ line: Int, resolved: Bool = false) -> ReviewItem {
  ReviewItem(id: id, kind: .comment, threadID: id, author: ada, quote: "q",
             messages: [ReviewMessage(id: "m" + id, text: "note", ts: nil, user: ada, mine: false)],
             range: ReviewRange(line: line, col: 0, endLine: line, endCol: 1), resolved: resolved)
}
private func change(_ id: String, _ line: Int, col: Int = 0, by u: ReviewUser = linus, kind: ReviewKind = .insert, min: Double = 0) -> ReviewItem {
  ReviewItem(id: id, kind: kind, author: u, ts: Date(timeIntervalSince1970: 1_700_000_000 + min * 60), quote: "w\(id)",
             range: ReviewRange(line: line, col: col, endLine: line, endCol: col + 2))
}

@Test func reviewBarSaysWhereYouAre() {
  let items = [note("n1", 1), change("a", 5), change("b", 9, by: ada), note("n2", 12), note("r", 14, resolved: true),
               change("c", 20), change("d", 21, min: 1), change("e", 22, min: 2)]
  let g = ReviewGrouping.group(items.filter { $0.kind != .comment || !$0.resolved })
  func t(_ id: String, _ k: ReviewKinds = .all, resolved: Bool = false) -> String {
    ReviewPosition.text(g.first { $0.id == id } ?? items.first { $0.id == id }, in: items, kinds: k, showResolved: resolved)
  }
  #expect(t("a") == "Suggestion 1 of 5 · Linus")
  #expect(t("b") == "Suggestion 2 of 5 · Ada")
  #expect(t("group:c") == "Suggestions 3–5 of 5 · Linus")
  #expect(t("n2") == "Comment 2 of 2 · Ada")
  #expect(t("r", resolved: true) == "Comment 3 of 3 · Ada")
  #expect(ReviewPosition.text(nil, in: items, kinds: .all, showResolved: false) == "5 suggestions")
  #expect(ReviewPosition.text(nil, in: items, kinds: .comments, showResolved: false) == "2 comments")
}

@MainActor @Test func theBarShowsTheRightActions() {
  let bar = ReviewBar(frame: .zero)
  var verbs: [ReviewVerb] = [], all: [Bool] = [], previews: [String] = [], closed = 0
  bar.onVerb = { verbs.append($0) }
  bar.onAllInFile = { all.append($0) }
  bar.onPreview = { previews.append($0) }
  bar.onClose = { closed += 1 }
  bar.show(text: "Suggestion 4 of 73 · Linus", comment: false)
  #expect(bar.label.stringValue == "Suggestion 4 of 73 · Linus")
  #expect(!bar.buttons["accept"]!.isHidden && !bar.buttons["acceptAll"]!.isHidden && bar.buttons["reply"]!.isHidden)
  for k in ["previous", "next", "accept", "reject", "acceptAll", "rejectAll", "close"] { bar.buttons[k]!.performClick(nil) }
  #expect(verbs == [.previous, .next, .accept, .reject] && all == [true, false] && closed == 1)
  bar.show(text: "Comment 2 of 5 · Ada", comment: true)
  #expect(bar.buttons["accept"]!.isHidden && !bar.buttons["reply"]!.isHidden && !bar.buttons["resolve"]!.isHidden)
  bar.buttons["reply"]!.performClick(nil); bar.buttons["resolve"]!.performClick(nil)
  #expect(verbs.suffix(2) == [.reply, .resolve])
  bar.preview.selectedSegment = 1
  bar.preview.sendAction(bar.preview.action, to: bar.preview.target)
  #expect(previews == ["accepted"])
  bar.setPreview("accepted")
  #expect(!bar.buttons["reply"]!.isEnabled)  // read-only while previewing
  bar.setPreview("off")
  #expect(bar.buttons["reply"]!.isEnabled && bar.preview.selectedSegment == 0)
}

@MainActor private final class RecordingNvim: NeovimBridge {
  var calls: [[Value]] = []
  var answer: Value = .bool(true)
  var handlers: [String: @MainActor ([Value]) -> Void] = [:]
  func notify(_ name: String, _ handler: @escaping @MainActor ([Value]) -> Void) { handlers[name] = handler }
  func execLua(_ code: String, _ args: [Value]) async throws -> Value { calls.append(args); return answer }
  func command(_ cmd: String) async throws {}
}

@MainActor @Test func reviewingShowsTheBarAndPreviewsHideTheCards() async throws {
  let s = SidebarView(frame: NSRect(x: 0, y: 0, width: 300, height: 700))
  s.tab = .comments
  s.scope = .file
  let nv = RecordingNvim()
  let c = ReviewController(nvim: nv, sidebar: s)
  try await c.attach(channel: 1)
  nv.answer = .map([(.string("ok"), .bool(true))])
  s.margin.animationDuration = 0
  s.margin.geometry = FixedLineGeometry(lineHeight: 20, top: 0, lineCount: 100, viewHeight: 700)
  c.receive(ReviewState(buf: 1, items: [change("a", 5), change("b", 9, by: ada), note("n", 12)]))
  #expect(c.bar.isHidden)
  c.verb(.next)  // ⌥⌘↓: the bar comes, Neovim jumps
  #expect(!c.bar.isHidden && c.reviewing)
  s.margin.cursor = ReviewCursor(buf: 1, line: 9, col: 1, here: ["b"])
  #expect(c.bar.label.stringValue == "Suggestion 2 of 2 · Ada")
  s.margin.cursor = ReviewCursor(buf: 1, line: 12, col: 0, here: ["n"])
  #expect(c.bar.label.stringValue == "Comment 1 of 1 · Ada" && c.bar.isComment)
  // A preview from Neovim: no cards, a notice, the bar's modes follow.
  nv.handlers["taudot_preview"]?([.map([(.string("mode"), .string("accepted"))])])
  s.margin.place()
  #expect(s.margin.previewMode == "accepted" && !s.margin.previewLabel.isHidden && s.margin.card("a")?.isHidden == true)
  #expect(c.bar.preview.selectedSegment == 1)
  // ✕: the bar goes, and so does the preview.
  nv.calls = []
  c.bar.onClose?()
  #expect(c.bar.isHidden && !c.reviewing)
  for _ in 0..<50 where !nv.calls.contains(where: { $0.first == .string("preview") }) { try? await Task.sleep(for: .milliseconds(20)) }
  #expect(nv.calls.contains { $0.first == .string("preview") && $0[2]["mode"] == .string("off") })
  nv.handlers["taudot_preview"]?([.map([(.string("mode"), .string("off"))])])
  s.margin.place()
  #expect(s.margin.previewMode == nil && s.margin.card("a")?.isHidden == false)
  UserDefaults.standard.removeObject(forKey: "taudot.sidebar.tab")
  UserDefaults.standard.removeObject(forKey: "taudot.sidebar.scope")
}

@MainActor @Test func theSelectedCardSlidesToItsTextAndClicksGoBothWays() {
  UserDefaults.standard.removeObject(forKey: ConnectorMode.key)
  let m = ReviewMarginView(frame: NSRect(x: 0, y: 0, width: 300, height: 700))
  m.animationDuration = 0
  m.geometry = FixedLineGeometry(lineHeight: 20, top: 0, lineCount: 100, viewHeight: 700)
  m.state = ReviewState(buf: 1, items: [note("a", 5), note("b", 6)])
  m.layoutSubtreeIfNeeded()
  #expect(m.connectorStyle == .all)  // the default: a line from every card to its text
  let before = m.targetFrames()
  var sent: [ReviewAction] = []
  m.onAction = { sent.append($0) }
  // A click on the card: selected, slid 8 pt toward the text, and Neovim's cursor goes into its text.
  m.card("a")!.onSelect?()
  let after = m.targetFrames()
  #expect(m.selectedID == "a" && after["a"]!.minX - before["a"]!.minX == 8)
  #expect(sent.contains(.goto("a")))
  // Its neighbour makes room under the opened card.
  #expect(after["b"]!.minY >= after["a"]!.maxY)
  // The cursor in the other's text selects that card.
  m.cursor = ReviewCursor(buf: 1, line: 6, col: 0, here: ["b"])
  #expect(m.selectedID == "b")
  // The setting: lines for the selected card only.
  UserDefaults.standard.set("selected", forKey: ConnectorMode.key)
  #expect(m.connectorStyle == .selected)
  UserDefaults.standard.removeObject(forKey: ConnectorMode.key)
}

@MainActor @Test func aScrollDoesntOpenTheCardsTheCursorPasses() async {
  let m = ReviewMarginView(frame: NSRect(x: 0, y: 0, width: 300, height: 700))
  m.animationDuration = 0
  let g = FixedLineGeometry(lineHeight: 20, top: 0, lineCount: 200, viewHeight: 700)
  m.geometry = g
  m.state = ReviewState(buf: 1, items: [note("a", 5), note("b", 20)])
  m.layoutSubtreeIfNeeded()
  // Scrolling, and Neovim drags the cursor into a comment: nothing opens yet.
  g.top = -10; g.top = -20
  m.cursor = ReviewCursor(buf: 1, line: 5, col: 0, here: ["a"])
  #expect(m.selectedID == nil)
  g.top = -30
  // Still: the selection follows the cursor once the scroll has settled.
  for _ in 0..<60 where m.selectedID == nil { try? await Task.sleep(for: .milliseconds(20)) }
  #expect(m.selectedID == "a")
  // Not scrolling: at once, as before.
  try? await Task.sleep(for: .milliseconds(300))
  m.cursor = ReviewCursor(buf: 1, line: 20, col: 0, here: ["b"])
  #expect(m.selectedID == "b")
}

@MainActor @Test func cardsNeverDrawUnderThePills() {
  let m = ReviewMarginView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
  m.animationDuration = 0
  m.coveredTop = 40
  let g = FixedLineGeometry(lineHeight: 20, top: -100, lineCount: 200, viewHeight: 400)
  m.geometry = g
  m.state = ReviewState(buf: 1, items: [note("up", 1), note("a", 6), note("b", 18), note("down", 40)])
  m.layoutSubtreeIfNeeded()
  m.place()
  #expect(!m.abovePill.isHidden && !m.belowPill.isHidden)
  // The cards' clip ends above the ↓ pill and starts below the ↑ pill (and the header over the panel).
  let clip = m.subviews.first { $0.subviews.contains { $0 is ReviewCardView } }!.frame
  #expect(clip.minY >= m.abovePill.frame.maxY && clip.maxY <= m.belowPill.frame.minY)
  #expect(m.abovePill.frame.minY >= 40)
}

@MainActor @Test func linesEndOnTheirLines() {
  UserDefaults.standard.removeObject(forKey: ConnectorMode.key)
  // The margin and an "editor" side by side in a window: each line runs from its card into the text, ending at its
  // range's first character (column 4 + textoff 3, wrap row 1 for b), at the row's vertical middle.
  let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
  final class Ed: NSView { override var isFlipped: Bool { true } }
  let ed = Ed(frame: NSRect(x: 300, y: 0, width: 600, height: 700))
  let m = ReviewMarginView(frame: NSRect(x: 0, y: 0, width: 300, height: 700))
  w.contentView!.addSubview(ed)
  w.contentView!.addSubview(m)
  m.animationDuration = 0
  let g = FixedLineGeometry(lineHeight: 20, top: 0, lineCount: 200, viewHeight: 700)
  g.cellWidth = 8
  m.geometry = g
  m.editorView = ed
  var a = note("a", 10), b = note("b", 20)
  a.range.col = 4; a.startWrap = 0; a.startCol = 4
  // b starts at the end of line 19: its text shows from line 20, wrap row 1 there
  b.range = ReviewRange(line: 19, col: 80, endLine: 21, endCol: 3); b.startLine = 20; b.startWrap = 1; b.startCol = 12
  var st = ReviewState(buf: 1, items: [a, b])
  st.textoff = 3
  m.state = st
  m.layoutSubtreeIfNeeded()
  m.place()
  let cv = w.contentView!
  // Each ends in a dot just inside the panel at the seam (x 300), at its text's row's middle.
  for (id, want) in [("a", NSPoint(x: 300 - 3.5, y: 10 * 20 + 10)), ("b", NSPoint(x: 300 - 3.5, y: 20 * 20 + 20 + 10))] {
    guard let l = m.connectorLine(id), let path = l.path, let host = l.superlayer else { Issue.record("no line for \(id)"); continue }
    var last = CGPoint.zero, gotCurve = false
    path.applyWithBlock { e in
      let el = e.pointee
      switch el.type {
      case .addCurveToPoint: if !gotCurve { last = el.points[2]; gotCurve = true }  // the connector, not the dot's arcs
      default: break
      }
    }
    // The overlay is flipped and covers the content view: its coordinates are the window's, top-down.
    let overlay = cv.subviews.last!
    #expect(host === overlay.layer, "\(id): the line is drawn over both panes")
    let wantInOverlay = overlay.convert(want, from: cv)
    let wantFlipped = NSPoint(x: want.x, y: want.y)
    let end = NSPoint(x: last.x, y: last.y)
    let target = cv.isFlipped ? wantFlipped : overlay.convert(ed.convert(NSPoint(x: want.x - 300, y: want.y), to: cv), from: cv)
    _ = wantInOverlay
    #expect(abs(end.x - target.x) <= 1 && abs(end.y - target.y) <= 1, "\(id): ends at \(end), want \(target)")
    // Nothing of it over the editor.
    let box = overlay.convert(path.boundingBoxOfPath, to: cv)
    #expect(box.maxX <= 300 + 0.5, "\(id): reaches \(box.maxX) (the editor starts at 300)")
  }
  // The active (selected) line is bold in full colour; the others thin and muted.
  m.select("a")
  m.place()
  #expect(m.connectorLine("a")!.lineWidth == 2 && m.connectorLine("a")!.opacity == 1)
  #expect(m.connectorLine("b")!.lineWidth == 1 && abs(m.connectorLine("b")!.opacity - 0.35) < 0.01)
}

@MainActor @Test func aDraftOnTheFirstLinesIsFullyVisible() {
  let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
  let m = ReviewMarginView(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
  w.contentView!.addSubview(m)
  m.animationDuration = 0
  m.coveredTop = 40
  m.geometry = FixedLineGeometry(lineHeight: 20, top: 0, lineCount: 100, viewHeight: 600)
  m.state = ReviewState(buf: 1, items: [note("a", 2), note("b", 3)])
  m.layoutSubtreeIfNeeded()
  // A new comment on lines 0–1, as the + button opens it (the draft is selected and focused).
  m.beginNewComment(on: ReviewRange(line: 0, col: 0, endLine: 1, endCol: 9), quote: "\\documentclass{article}\n\\usepackage{graphicx}")
  let f = m.targetFrames()
  let d = try! #require(f["draft"])
  #expect(d.minY >= m.cardsTop && d.maxY <= m.cardsBottom, "draft \(d) in \(m.cardsTop)…\(m.cardsBottom)")
  // The cards after it shift down below it (not under it, not above the top).
  for id in ["a", "b"] { if let g = f[id] { #expect(g.minY >= d.maxY) } }
  // The quote shows backslashes as backslashes, upright.
  let q = m.card("draft")!.subviews.flatMap { [$0] + $0.subviews }.compactMap { $0 as? NSTextField }.first { $0.stringValue.hasPrefix("“") }
  #expect(q?.stringValue.contains("\\documentclass") == true)
  #expect(q.map { !NSFontManager.shared.traits(of: $0.font!).contains(.italicFontMask) } == true)
}

@MainActor @Test func theSelectedCardAtTheBottomGetsItsSpace() {
  let m = ReviewMarginView(frame: NSRect(x: 0, y: 0, width: 300, height: 500))
  m.animationDuration = 0
  m.geometry = FixedLineGeometry(lineHeight: 20, top: 0, lineCount: 100, viewHeight: 500)
  m.state = ReviewState(buf: 1, items: [note("a", 15), note("b", 22)])
  m.layoutSubtreeIfNeeded()
  m.select("b")
  let f = m.targetFrames()
  let b = try! #require(f["b"])
  #expect(b.maxY <= m.cardsBottom && b.minY >= m.cardsTop, "selected \(b) in \(m.cardsTop)…\(m.cardsBottom)")
  if let a = f["a"] { #expect(a.maxY <= b.minY) }
}
