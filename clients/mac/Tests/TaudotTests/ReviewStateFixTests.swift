// statefix (docs/state-machines.md) items in TaudotReview: A3 (a new comment's draft across a file switch, and its
// sending state), A18 (pending actions time out).
import AppKit
import Testing
@testable import TaudotReview
@testable import TaudotShared

private func item(_ id: String, line: Int, text: String = "A comment") -> ReviewItem {
  let u = ReviewUser(id: "u1", name: "Ada Lovelace", initials: "AL")
  return ReviewItem(
    id: id, kind: .comment, threadID: id, author: u, color: "#3b82f6", ts: Date(timeIntervalSinceNow: -300), quote: "word",
    messages: [ReviewMessage(id: "m-\(id)", text: text, ts: Date(timeIntervalSinceNow: -300), user: u, mine: false)],
    range: ReviewRange(line: line, col: 0, endLine: line, endCol: 4), resolved: false)
}

@MainActor private func margin(buf: Int, path: String, _ items: [ReviewItem]) -> ReviewMarginView {
  let v = ReviewMarginView(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
  v.animationDuration = 0
  v.geometry = FixedLineGeometry()
  v.state = ReviewState(buf: buf, path: path, items: items)
  v.layoutSubtreeIfNeeded()
  v.place()
  return v
}

/// A3: a comment drafted in a.tex is not shown (nor sendable) over b.tex; back in a.tex it is there with what was
/// typed, and it is sent to a.tex's buffer whichever buffer is current.
@MainActor @Test func a3DraftStaysWithItsFile() {
  let v = margin(buf: 1, path: "a.tex", [item("a", line: 1)])
  var sent: [ReviewAction] = []
  v.onAction = { sent.append($0) }
  let r = ReviewRange(line: 4, col: 2, endLine: 4, endCol: 9)
  v.beginNewComment(on: r, quote: "in a.tex")
  v.card("draft")!.reply!.insertText("Cite this", replacementRange: NSRange(location: 0, length: 0))
  // Neovim switches to b.tex.
  v.state = ReviewState(buf: 2, path: "b.tex", items: [item("b", line: 2)])
  #expect(!v.shown.contains { $0.id == "draft" }, "the draft is not shown over another file")
  #expect(v.draftItem == nil && v.card("draft") == nil)
  // The cursor moving in b.tex (selecting nothing, then a card) doesn't throw the draft away.
  v.select(nil)
  v.select("b")
  // Back to a.tex: the draft, with its text.
  v.state = ReviewState(buf: 1, path: "a.tex", items: [item("a", line: 1)])
  #expect(v.shown.map(\.id).contains("draft"))
  #expect(v.card("draft")?.reply?.string == "Cite this")
  // Sent: its buffer goes along (gui.act's `buf`), so it lands in a.tex even if b.tex is current by then.
  v.card("draft")!.reply!.keyDown(with: NSEvent.keyEvent(
    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\r",
    charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!)
  #expect(sent.last == .comment(r, text: "Cite this"))
  #expect(v.target(of: sent.last!) == 1)
  #expect(v.target(of: .comment(ReviewRange(line: 0, col: 0, endLine: 0, endCol: 1), text: "other")) == nil)
  let args = ReviewController.args(sent.last!, req: 7, buf: v.target(of: sent.last!))
  #expect(args.contains { $0.0 == .string("buf") && $0.1 == .int(1) })
}

/// A3: "sending" ends by itself when the comment never comes back (no payload needed to notice).
@MainActor @Test func a3SendingTimesOutWithoutAReload() async {
  let v = margin(buf: 1, path: "a.tex", [item("a", line: 1)])
  v.sendTimeout = 0.2
  let r = ReviewRange(line: 4, col: 0, endLine: 4, endCol: 5)
  v.beginNewComment(on: r, quote: "x")
  v.actionSucceeded(.comment(r, text: "lost"))
  #expect(v.draftItem != nil)
  try? await Task.sleep(for: .milliseconds(500))
  #expect(v.draftItem == nil, "the sending draft is dropped after its timeout")
}

/// A3: the comment coming back while another file shows doesn't match against that file's items; back home, it does.
@MainActor @Test func a3ComebackOnlyMatchesItsOwnFile() {
  let v = margin(buf: 1, path: "a.tex", [])
  let r = ReviewRange(line: 4, col: 0, endLine: 4, endCol: 5)
  v.beginNewComment(on: r, quote: "x")
  v.actionSucceeded(.comment(r, text: "same"))
  var lookalike = item("other", line: 4, text: "same")
  lookalike.range = r
  v.state = ReviewState(buf: 2, path: "b.tex", items: [lookalike])
  #expect(v.selectedID != "other", "a look-alike comment in b.tex doesn't take the draft's place")
  var back = item("c", line: 4, text: "same")
  back.range = r
  v.state = ReviewState(buf: 1, path: "a.tex", items: [back])
  #expect(v.draftItem == nil && v.selectedID == "c")
}

/// Neovim takes the action (`ok`) but its taudot_review_done never comes.
@MainActor private final class SilentNvim: NeovimBridge {
  func notify(_ name: String, _ handler: @escaping @MainActor ([Value]) -> Void) {}
  func execLua(_ code: String, _ args: [Value]) async throws -> Value { .map([(.string("ok"), .bool(true))]) }
  func command(_ cmd: String) async throws {}
}

/// A18: an action whose answer never comes fails after `actionTimeout` (said on its card, reported), instead of
/// staying pending forever.
@MainActor @Test func a18PendingActionsTimeOut() async {
  let v = margin(buf: 1, path: "a.tex", [item("a", line: 1)])
  let c = ReviewController(nvim: SilentNvim(), margin: v)
  c.actionTimeout = 0.2
  var results: [(ReviewAction, String?)] = []
  c.onResult = { results.append(($0, $1)) }
  c.send(.resolve("a"))
  try? await Task.sleep(for: .milliseconds(100))
  #expect(results.isEmpty && c.pendingCount == 1)
  try? await Task.sleep(for: .milliseconds(400))
  #expect(results.count == 1 && results.first?.1 != nil, "the action failed with a timeout")
  #expect(c.pendingCount == 0)
  #expect(v.card("a")?.error != nil, "its card says so")
}

/// A27: tab switches faster than the 200 ms slide (and one while the sidebar is hidden) leave no ghost snapshot behind.
@MainActor @Test func a27NoSidebarGhost() async {
  let w = NSWindow(contentRect: NSRect(x: -5000, y: 0, width: 300, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
  let s = SidebarView(frame: NSRect(x: 0, y: 0, width: 280, height: 600))
  w.contentView?.addSubview(s)
  s.layoutSubtreeIfNeeded()
  let before = Set(s.subviews.map(ObjectIdentifier.init))
  for t in [SidebarView.Tab.files, .comments, .files, .history, .comments] {
    s.tab = t
    try? await Task.sleep(for: .milliseconds(40))
  }
  s.isHidden = true
  s.tab = .files
  s.isHidden = false
  s.tab = .comments
  try? await Task.sleep(for: .milliseconds(500))
  let extra = s.subviews.filter { !before.contains(ObjectIdentifier($0)) && !$0.isHidden && $0.layer?.contents != nil }
  #expect(extra.isEmpty, "\(extra.count) ghost snapshot(s) left")
}
