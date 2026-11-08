import AppKit
import Testing
@testable import TaudotReview
@testable import TaudotShared

// Where place() spends its time on a long review (the replica's shape: ~80 items over 700 lines), scrolling through.
@MainActor @Test func placeOnALongReviewStaysUnderTwoMs() async {
  let u = ReviewUser(id: "u", name: "Linus Yarrow", initials: "LY")
  var items: [ReviewItem] = []
  for k in 0..<80 {
    let line = 5 + k * 9
    items.append(k % 6 == 0
      ? ReviewItem(id: "c\(k)", kind: .comment, threadID: "c\(k)", author: u, quote: "q",
                   messages: [ReviewMessage(id: "m\(k)", text: "A comment with a few words that wraps onto a second line, \(k)", ts: nil, user: u, mine: false)],
                   range: ReviewRange(line: line, col: 0, endLine: line, endCol: 4))
      : ReviewItem(id: "s\(k)", kind: k % 2 == 0 ? .insert : .delete, author: u, ts: Date(timeIntervalSince1970: Double(k) * 7200), quote: "words \(k)",
                   range: ReviewRange(line: line, col: 3, endLine: line, endCol: 9)))
  }
  let g = FixedLineGeometry(lineHeight: 18, lineCount: 740, viewHeight: 900)
  let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
  let v = ReviewMarginView(frame: NSRect(x: 0, y: 0, width: 300, height: 900))
  w.contentView!.addSubview(v)
  v.animationDuration = 0
  v.geometry = g
  v.state = ReviewState(buf: 1, items: items)
  v.layoutSubtreeIfNeeded()
  v.place()
  // (the idle measuring runs on the main queue between events, as it would before a scroll)
  for _ in 0..<40 { try? await Task.sleep(for: .milliseconds(5)) }
  var worst = 0.0, total = 0.0
  var t = 0.0
  for k in 0..<1200 {
    g.top = -CGFloat(k) * 10
    let t0 = CACurrentMediaTime()
    v.place()
    let dt = (CACurrentMediaTime() - t0) * 1000
    total += dt
    if k > 5 { worst = max(worst, dt) }
    t = dt
  }
  _ = t
  print("long review: place mean \(String(format: "%.3f", total / 1200)) ms, worst \(String(format: "%.3f", worst)) ms")
  #expect(total / 1200 < 1)
  #expect(worst < 4)
}
