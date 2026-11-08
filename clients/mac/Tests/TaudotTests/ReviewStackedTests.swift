// Stacked mode: a compact list in document order that scrolls on its own; selecting goes to the text, the list stays.
import AppKit
import Testing
@testable import TaudotReview
@testable import TaudotShared

private let ada = ReviewUser(id: "u-ada", name: "Ada", initials: "A")
private let bob = ReviewUser(id: "u-bob", name: "Bob", initials: "B")
private func note(_ id: String, _ line: Int, by u: ReviewUser = ada) -> ReviewItem {
  ReviewItem(id: id, kind: .comment, threadID: id, author: u, quote: "q",
             messages: [ReviewMessage(id: "m" + id, text: "comment \(id)", ts: nil, user: u, mine: false)], range: ReviewRange(line: line, col: 0, endLine: line, endCol: 1))
}

@MainActor private func stacked(_ items: [ReviewItem], height: CGFloat = 500) -> (ReviewMarginView, FixedLineGeometry, [ReviewAction]) {
  let m = ReviewMarginView(frame: NSRect(x: 0, y: 0, width: 300, height: height))
  m.animationDuration = 0
  let g = FixedLineGeometry(lineHeight: 20, top: 0, lineCount: 2000, viewHeight: height)
  m.geometry = g
  m.state = ReviewState(buf: 1, items: items)
  m.cardLayout = .stacked
  m.layoutSubtreeIfNeeded()
  return (m, g, [])
}

@MainActor @Test func stackedIsAListFromTheTopInDocumentOrder() {
  let (m, g, _) = stacked([note("a", 900), note("b", 10), note("c", 400)])
  let f = m.targetFrames()
  #expect(m.shown.map(\.id) == ["b", "c", "a"])
  #expect(f["b"]!.minY < f["c"]!.minY && f["c"]!.minY < f["a"]!.minY)
  #expect(abs(f["b"]!.minY - (m.cardsTop + 6)) < 0.5)  // from the top, not at its line
  // Scrolling the editor doesn't move the list.
  g.top = -5000
  #expect(m.targetFrames()["b"] == f["b"])
  #expect(m.abovePill.isHidden && m.belowPill.isHidden)
}

@MainActor @Test func stackedScrollsOnItsOwnAndKeepsTheSelectionInView() {
  let (m, _, _) = stacked((0..<20).map { note("n\($0)", $0 * 50) }, height: 400)
  var sent: [ReviewAction] = []
  m.onAction = { sent.append($0) }
  let first = m.targetFrames()["n0"]!.minY
  // A two-finger scroll over the list scrolls the list (not the editor: nothing sent).
  let e = NSEvent(cgEvent: { let c = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -60, wheel2: 0, wheel3: 0)!
    c.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1); return c }())!
  m.scrollWheel(with: e)
  #expect(m.stackOffset == 60 && m.targetFrames()["n0"]!.minY == first - 60 && sent.isEmpty)
  // ↓ through the list: each selection goes to its text (reveal: centred, the PDF follows), the list stays unless
  // the selected card would leave the view.
  m.select("n1")
  let off = m.stackOffset
  sent = []
  _ = m.verb(.next)
  #expect(m.selectedID == "n2" && sent.contains(.reveal("n2", path: "")))
  #expect(m.stackOffset == off)  // still in view: the list didn't move
  for _ in 0..<12 { _ = m.verb(.next) }
  let sel = m.targetFrames()[m.selectedID!]!
  #expect(sel.maxY <= m.cardsBottom && sel.minY >= m.cardsTop, "the selected card stays in view: \(sel)")
  #expect(m.stackOffset > off)
}

@MainActor @Test func stackedClickGoesToTheTextAndOnlyItsLineShows() {
  let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
  final class Ed: NSView { override var isFlipped: Bool { true } }
  let ed = Ed(frame: NSRect(x: 300, y: 0, width: 600, height: 500))
  let (m, g, _) = stacked([note("a", 5), note("b", 10), note("c", 900)])
  w.contentView!.addSubview(ed)
  w.contentView!.addSubview(m)
  m.editorView = ed
  _ = g
  var sent: [ReviewAction] = []
  m.onAction = { sent.append($0) }
  m.card("b")!.onSelect?()
  #expect(m.selectedID == "b" && sent.contains(.reveal("b", path: "")))
  m.place()
  // Lines: only the selected card's, and only while its text is on screen.
  #expect(m.connectorLine("b")?.isHidden == false && m.connectorLine("a")?.isHidden != false)
  m.card("c")!.onSelect?()
  m.place()
  #expect(m.connectorLine("c")?.isHidden != false)  // line 900 is off screen
}

@MainActor @Test func onlyOneAuthor() {
  let (m, _, _) = stacked([note("a1", 5), note("b1", 10, by: bob), note("a2", 20), note("b2", 30, by: bob)])
  m.authorFilter = "u-ada"
  #expect(m.shown.map(\.id) == ["a1", "a2"])
  m.select("a1")
  _ = m.verb(.next)
  #expect(m.selectedID == "a2")
  m.authorFilter = nil
  #expect(m.shown.count == 4)
}
