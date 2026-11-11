// Item 10: "When I zoom in while previewing a comment, the comment margins zoom weird." A comment's card pinned (and
// one hovered) on the PDF while the view zooms: in, out, a pinch's steps around a point, back to fit. Each step
// records the cards' frames against their note markers (pane coordinates).
import AppKit
import Foundation
import Testing
@testable import TaudotPDF

@MainActor func zoomPane() -> (PDFPaneView, NSWindow) {
  let view = PDFPaneView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
  let window = NSWindow(contentRect: NSRect(x: -12000, y: -12000, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  window.contentView = view
  window.orderFront(nil)
  view.setSizes([CGSize(width: 612, height: 792), CGSize(width: 612, height: 792)])
  view.notes.defaults = UserDefaults(suiteName: "zoom-\(UUID().uuidString.prefix(6))")!
  let line = CGRect(x: 72, y: 260, width: 400, height: 9)
  view.notes.set(
    [PlacedNote(id: "a", page: 0, line: line, side: .right, slot: 0), PlacedNote(id: "b", page: 0, line: line, side: .right, slot: 1),
     PlacedNote(id: "c", page: 0, line: line.offsetBy(dx: 0, dy: 14), side: .right, slot: 0)],
    comments: [PDFComment(id: "a", path: "main.tex", line: 1, author: "Ana", firstMessage: "Is this the right figure for the main result?"),
               PDFComment(id: "b", path: "main.tex", line: 1, author: "Ben", firstMessage: "Yes"),
               PDFComment(id: "c", path: "main.tex", line: 2, author: "Cy", firstMessage: "Typo")])
  return (view, window)
}

/// The marker of `id` in pane coordinates.
@MainActor func markerRect(_ view: PDFPaneView, _ id: String) -> NSRect? {
  guard let n = view.notes.notes.first(where: { $0.id == id }), let r = view.notes.rects[id] else { return nil }
  let p = view.pages[n.page]
  return view.pagesView.convert(r.offsetBy(dx: p.origin.x, dy: p.origin.y), to: view)
}

@MainActor @Test func pinnedCommentCardFollowsItsNoteThroughZoom() async throws {
  let (view, window) = zoomPane()
  defer { window.close() }
  let pa = try #require(view.notePoint("a"))
  #expect(view.clickPages(at: pa) && view.notePinned == "a")
  var rows: [String] = []
  var gaps: [CGFloat] = [], sizes: [NSSize] = []
  func record(_ what: String) {
    view.layoutSubtreeIfNeeded()
    guard let card = view.pinnedCardFrame, let m = markerRect(view, "a") else { rows.append("\(what): card hidden"); return }
    // the card's right edge to the marker's left (a right-side note: the card is left of it), and its top vs the marker
    let gap = m.minX - card.maxX, dy = card.maxY - m.midY
    gaps.append(gap); sizes.append(card.size)
    rows.append(String(format: "%@: mag %.2f marker %.1f,%.1f %.1fx%.1f card %.1f,%.1f %.0fx%.0f gap %.1f dy %.1f", what,
      view.scrollView.magnification, m.minX, m.minY, m.width, m.height, card.minX, card.minY, card.width, card.height, gap, dy))
  }
  record("start")
  for m in [1.25, 1.5, 2.0, 1.5, 1.0, 0.75] { view.scrollView.magnification = m; record("set") }
  // a pinch: steps around the marker
  let c = view.scrollView.contentView.convert(pa, from: view.pagesView)
  for m in stride(from: 0.8, through: 2.4, by: 0.2) { view.scrollView.setMagnification(m, centeredAt: c); record("pinch") }
  view.scrollView.magnification = 1
  record("end")
  print(rows.joined(separator: "\n"))
  let g0 = try #require(gaps.first)
  #expect(gaps.allSatisfy { abs($0 - g0) < 1.5 }, "the card kept its distance to its note: \(gaps)")
  #expect(Set(sizes.map { "\($0)" }).count == 1, "the card kept its size: \(sizes)")
}

/// The hover card (a comment previewed by pointing at its note) while the view zooms under the pointer.
@MainActor @Test func hoverCommentCardFollowsItsNoteThroughZoom() async throws {
  let (view, window) = zoomPane()
  defer { window.close() }
  let pa = try #require(view.notePoint("c"))
  view.hoverPages(at: pa)
  #expect(view.noteCardShown == "c")
  var rows: [String] = []
  var gaps: [CGFloat] = []
  var sizes: [NSSize] = []
  func record(_ what: String) {
    guard let card = view.notes.hoverCardFrameForTest, let m = markerRect(view, "c") else { rows.append("\(what): no card (\(view.noteCardShown ?? "-"))"); return }
    gaps.append(m.minX - card.maxX)
    sizes.append(card.size)
    rows.append(String(format: "%@: mag %.2f marker %.1f,%.1f card %.1f,%.1f %.0fx%.0f", what, view.scrollView.magnification,
      m.minX, m.midY, card.minX, card.midY, card.width, card.height))
  }
  record("start")
  let c = view.scrollView.contentView.convert(pa, from: view.pagesView)
  for m in stride(from: 1.0, through: 2.4, by: 0.2) {
    view.scrollView.setMagnification(m, centeredAt: c)
    // the pointer stays where it was on screen: what's under it now
    view.hoverPages(at: view.pagesView.convert(view.scrollView.contentView.convert(c, to: nil), from: nil))
    record("pinch")
  }
  print(rows.joined(separator: "\n"))
  #expect(rows.allSatisfy { !$0.contains("no card") }, "the card stayed while zooming over its note")
  let g0 = try #require(gaps.first)
  #expect(gaps.allSatisfy { abs($0 - g0) < 1.5 }, "the card kept its distance to its note: \(gaps)")
  #expect(Set(sizes.map { "\($0)" }).count == 1, "the card kept its size (it grew a point a frame): \(sizes)")
}
