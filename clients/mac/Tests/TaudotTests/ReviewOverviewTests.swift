// The Comments tab's All (the overview) and scrolling over the margin.
import AppKit
import Testing
@testable import TaudotReview
@testable import TaudotShared

private let ada = ReviewUser(id: "u-ada", name: "Ada Lovelace", initials: "AL")
private let me = ReviewUser(id: "u-me", name: "Me", initials: "M")

private func ov(_ id: String, _ path: String, line: Int? = nil, kind: ReviewKind = .comment, quote: String = "q", text: String = "",
                by: ReviewUser = ada, resolved: Bool = false, mine: Bool = false) -> OverviewItem {
  OverviewItem(id: id, kind: kind, path: path, line: line, quote: quote, author: by, text: text, resolved: resolved, mine: mine)
}

@Test func sidebarOrderIsFilesThenFoldersNatural() {
  let paths = ["sections/b.tex", "main.tex", "fig10.tex", "appendix.tex", "sections/a/x.tex", "fig2.tex", "sections/a.tex"]
  #expect(paths.sorted(by: sidebarOrder) == ["appendix.tex", "fig2.tex", "fig10.tex", "main.tex", "sections/a.tex", "sections/b.tex", "sections/a/x.tex"])
}

@Test func overviewGroupsByFileInSidebarOrder() {
  let items = [
    ov("c", "sections/intro.tex"), ov("a2", "main.tex", line: 30), ov("a1", "main.tex", line: 4),
    ov("d", "appendix.tex"), ov("e", "appendix.tex"),
  ]
  let s = Overview.sections(items, filter: .open)
  #expect(s.map(\.path) == ["appendix.tex", "main.tex", "sections/intro.tex"])
  #expect(s[1].items.map(\.id) == ["a1", "a2"])  // by line where known
  #expect(s[0].items.map(\.id) == ["d", "e"])  // as given (text order) where not
}

@Test func overviewFiltersAndSearch() {
  let items = [
    ov("open", "main.tex", text: "Is this the right word?"), ov("done", "main.tex", resolved: true),
    ov("ins", "main.tex", kind: .insert, quote: "(citation needed)"),
    ov("mine", "b.tex", quote: "bijection", text: "check", by: me, mine: true),
    ov("mineDone", "b.tex", by: me, resolved: true, mine: true),
  ]
  func ids(_ f: OverviewFilter, _ q: String = "") -> [String] { Overview.sections(items, filter: f, query: q).flatMap { $0.items.map(\.id) } }
  #expect(ids(.open) == ["mine", "open", "ins"])
  #expect(ids(.resolved) == ["mineDone", "done"])
  #expect(ids(.mine) == ["mine"])
  // Every word, anywhere: quote, message, author, path; case and accents aside.
  #expect(ids(.open, "RIGHT word") == ["open"])
  #expect(ids(.open, "citation") == ["ins"])
  #expect(ids(.open, "ada") == ["open", "ins"])
  #expect(ids(.open, "b.tex") == ["mine"])
  #expect(ids(.open, "bijéction") == ["mine"])
  #expect(ids(.open, "nothing like it").isEmpty)
}

@Test func overviewDecodesGuiLua() {
  let v: Value = .map([(.string("files"), .array([.map([
    (.string("path"), .string("main.tex")),
    (.string("items"), .array([.map([
      (.string("id"), .string("t1")), (.string("kind"), .string("comment")), (.string("path"), .string("main.tex")),
      (.string("line"), .int(4)), (.string("quote"), .string("word")), (.string("text"), .string("hi")),
      (.string("replies"), .int(2)), (.string("ts"), .float(1_700_000_000_000)), (.string("resolved"), .bool(false)),
      (.string("mine"), .bool(true)), (.string("color"), .string("#336699")),
      (.string("author"), .map([(.string("user_id"), .string("u")), (.string("name"), .string("Ada")), (.string("initials"), .string("A"))])),
    ])])),
  ])]))])
  let it = Overview.items(v)
  #expect(it.count == 1 && it[0].id == "t1" && it[0].line == 4 && it[0].replies == 2 && it[0].mine && it[0].author.name == "Ada")
  #expect(it[0].ts == Date(timeIntervalSince1970: 1_700_000_000))
}

@MainActor @Test func overviewListKeyboardAndClick() {
  let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
  let v = OverviewView(frame: w.contentView!.bounds)
  w.contentView!.addSubview(v)
  v.items = [ov("a", "main.tex", line: 1, text: "one"), ov("b", "main.tex", line: 2, text: "two"), ov("c", "z.tex", text: "three"),
             ov("r", "main.tex", resolved: true)]
  v.layoutSubtreeIfNeeded()
  #expect(v.shownFiles == ["main.tex", "z.tex"] && v.shownIDs == ["a", "b", "c"])
  var revealed: [String] = []
  v.onReveal = { revealed.append($0.id) }
  v.focus()
  #expect(v.selectedItem?.id == "a")  // the first item, not the file's header
  let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber,
                              context: nil, characters: String(UnicodeScalar(NSDownArrowFunctionKey)!),
                              charactersIgnoringModifiers: String(UnicodeScalar(NSDownArrowFunctionKey)!), isARepeat: false, keyCode: 125)!
  v.table.keyDown(with: down)
  v.table.keyDown(with: down)
  #expect(v.selectedItem?.id == "c")  // ↓ skips the z.tex header
  let ret = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber,
                             context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
  v.table.keyDown(with: ret)
  #expect(revealed == ["c"])
  // Filter and search rebuild the list; the selection stays when it can.
  v.filter = .resolved
  #expect(v.shownIDs == ["r"])
  v.filter = .open
  v.query = "two"
  #expect(v.shownIDs == ["b"] && v.empty.isHidden)
  v.query = "zzz"
  #expect(v.shownIDs.isEmpty && !v.empty.isHidden && v.empty.stringValue == "Nothing matches")
}

@MainActor private final class RecordingNvim: NeovimBridge {
  var calls: [[Value]] = []
  var answer: Value = .bool(true)
  var handlers: [String: @MainActor ([Value]) -> Void] = [:]
  func notify(_ name: String, _ handler: @escaping @MainActor ([Value]) -> Void) { handlers[name] = handler }
  func execLua(_ code: String, _ args: [Value]) async throws -> Value {
    calls.append(args)
    return answer
  }
  func command(_ cmd: String) async throws {}
}

@MainActor @Test func allFetchesTheOverviewAndARowRevealsIt() async throws {
  let s = SidebarView(frame: NSRect(x: 0, y: 0, width: 280, height: 600))
  s.tab = .comments
  s.scope = .file
  let nv = RecordingNvim()
  let c = ReviewController(nvim: nv, sidebar: s)
  try await c.attach(channel: 1)
  nv.answer = .map([(.string("ok"), .bool(true))])
  nv.calls = []
  s.scope = .all
  #expect(s.margin.isHidden && !s.overview.isHidden && s.overviewVisible)
  for _ in 0..<50 where !nv.calls.contains(where: { $0.first == .string("overview") }) { try? await Task.sleep(for: .milliseconds(20)) }
  let call = try #require(nv.calls.first { $0.first == .string("overview") })
  // Its answer fills the list.
  let req: Value = call[2]["req"]
  let item: Value = .map([(.string("id"), .string("t9")), (.string("kind"), .string("comment")), (.string("path"), .string("b.tex")),
                          (.string("resolved"), .bool(true)), (.string("author"), .map([(.string("name"), .string("Ada"))]))])
  nv.handlers["taudot_review_done"]?([.map([(.string("req"), req), (.string("ok"), .bool(true)),
                                              (.string("result"), .map([(.string("files"), .array([.map([(.string("path"), .string("b.tex")), (.string("items"), .array([item]))])]))]))])])
  #expect(s.overview.items.map(\.id) == ["t9"])
  // A change elsewhere: asked again (while All shows).
  nv.calls = []
  nv.handlers["taudot_overview_changed"]?([.map([])])
  for _ in 0..<50 where !nv.calls.contains(where: { $0.first == .string("overview") }) { try? await Task.sleep(for: .milliseconds(20)) }
  #expect(nv.calls.contains { $0.first == .string("overview") })
  // Clicking a (resolved) row: back to This File, resolved shown so its card can be selected, Neovim reveals it.
  nv.calls = []
  guard let first = s.overview.items.first else { return }
  s.overview.onReveal?(first)
  #expect(s.scope == .file && !s.margin.isHidden && s.margin.showResolved)
  for _ in 0..<50 where !nv.calls.contains(where: { $0.first == .string("reveal") }) { try? await Task.sleep(for: .milliseconds(20)) }
  let rv = nv.calls.first { $0.first == .string("reveal") }
  #expect(rv?[1] == .string("t9") && rv?[2]["path"] == .string("b.tex"))
  UserDefaults.standard.removeObject(forKey: "taudot.sidebar.scope")
  UserDefaults.standard.removeObject(forKey: "taudot.sidebar.tab")
}

// ---- scrolling over the margin ----------------------------------------------------------------------------------

private final class RecordingEditor: NSView {
  var got: [(NSPoint, CGFloat, NSEvent.Phase)] = []
  override func scrollWheel(with e: NSEvent) {
    // As EditorView does: an event without a window carries screen coordinates.
    let p = e.window == nil ? convert(window!.convertPoint(fromScreen: e.locationInWindow), from: nil) : convert(e.locationInWindow, from: nil)
    got.append((p, e.scrollingDeltaY, e.phase))
  }
}

private func scrollEvent(_ dy: Int32, phase: Int64, momentum: Int64 = 0, at p: NSPoint, in w: NSWindow) -> NSEvent {
  let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0)!
  cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
  cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
  cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
  let s = w.convertPoint(toScreen: p)
  cg.location = CGPoint(x: s.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - s.y)
  return NSEvent(cgEvent: cg)!
}
// CGScrollPhase: began 1, changed 2, ended 4.

@MainActor private func marginInWindow(lines: Int, items: [ReviewItem]) -> (NSWindow, ReviewMarginView, RecordingEditor, FixedLineGeometry) {
  let w = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
  let ed = RecordingEditor(frame: NSRect(x: 300, y: 0, width: 600, height: 400))
  let m = ReviewMarginView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
  w.contentView!.addSubview(ed)
  w.contentView!.addSubview(m)
  m.animationDuration = 0
  let g = FixedLineGeometry(lineHeight: 20, top: 0, lineCount: lines, viewHeight: 400)
  m.geometry = g
  m.editorView = ed
  var st = ReviewState(buf: 1, items: items)
  st.lineCount = lines
  m.state = st
  m.layoutSubtreeIfNeeded()
  return (w, m, ed, g)
}

private func comment(_ id: String, line: Int) -> ReviewItem {
  ReviewItem(id: id, kind: .comment, threadID: id, author: ada, quote: "w",
             messages: [ReviewMessage(id: "m" + id, text: "a comment that takes a few lines in its card, \(id)", ts: nil, user: ada, mine: false)],
             range: ReviewRange(line: line, col: 0, endLine: line, endCol: 1))
}

@MainActor @Test func scrollOverTheMarginScrollsTheEditor() {
  let (w, m, ed, _) = marginInWindow(lines: 200, items: [comment("a", line: 3)])
  let at = m.convert(NSPoint(x: 40, y: 120), to: nil)
  m.scrollWheel(with: scrollEvent(-12, phase: 1, at: at, in: w))
  m.scrollWheel(with: scrollEvent(-30, phase: 2, at: at, in: w))
  m.scrollWheel(with: scrollEvent(0, phase: 4, at: at, in: w))
  m.scrollWheel(with: scrollEvent(-20, phase: 0, momentum: 1, at: at, in: w))  // momentum too
  #expect(ed.got.count == 4)
  #expect(ed.got.map(\.1) == [-12, -30, 0, -20])
  #expect(ed.got.map(\.2) == [.began, .changed, .ended, []])
  // On the editor's text, at the height the fingers are.
  let want = ed.convert(at, from: nil).y
  #expect(ed.got.allSatisfy { ed.bounds.contains($0.0) && abs($0.0.y - want) < 1 }, "\(ed.got.map(\.0)) want y \(want) in \(ed.bounds)")
  #expect(m.overscroll == 0)
}

@MainActor @Test func cardsThatDontFitGoInTheBelowPill() async {
  // 20 lines (all on screen), eight comments on the last two: the stack runs past the margin's bottom.
  let items = (0..<8).map { comment("c\($0)", line: 18 + $0 % 2) }
  let (w, m, ed, _) = marginInWindow(lines: 20, items: items)
  let f = m.targetFrames()
  #expect(f.values.allSatisfy { $0.maxY <= m.bounds.height - 30 } && f.count < 8)
  #expect(m.belowPill.count == 8 - f.count && !m.belowPill.isHidden)
  // Selecting a hidden one shows it (the selected card always has a place).
  m.select("c7")
  #expect(m.targetFrames()["c7"] != nil)
  // No lifting: the gesture goes to the editor.
  let at = m.convert(NSPoint(x: 40, y: 200), to: nil)
  m.scrollWheel(with: scrollEvent(-40, phase: 1, at: at, in: w))
  #expect(m.overscroll == 0 && ed.got.count == 1)
}

@MainActor @Test func overscrollStillWorksWhenOn() async {
  let items = (0..<8).map { comment("c\($0)", line: 18 + $0 % 2) }
  let (_, m, _, _) = marginInWindow(lines: 20, items: items)
  m.overscrollEnabled = true
  #expect(m.overscrollRange().hi >= 0)
}

@MainActor @Test func noOverscrollAwayFromTheEnd() {
  // A long buffer scrolled to its middle: pushing scrolls the editor; nothing lifts.
  let items = (0..<8).map { comment("c\($0)", line: 18 + $0 % 2) }
  let (w, m, ed, _) = marginInWindow(lines: 300, items: items)
  #expect(m.overscrollRange() == (0, 0))
  let at = m.convert(NSPoint(x: 40, y: 200), to: nil)
  m.scrollWheel(with: scrollEvent(-40, phase: 1, at: at, in: w))
  #expect(m.overscroll == 0 && ed.got.count == 1)
}
