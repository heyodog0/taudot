// Outside edits on the PDF (editfix item 9): the typeset lines an edit made outside this window changed (a coauthor's,
// Claude's, another editor's) get a tint in its colour that fades over `seconds`, once the typeset with the edit has
// its SyncTeX. Follow Edits scrolls there too.
import AppKit
import QuartzCore

extension TaudotPDFPane {
  /// An outside edit at `path`, source `lines` (1-based); when it sits on one line, `cols` (its byte columns and that
  /// line's length) narrow it to the typeset lines it is on. `reveal`: scroll to it once placed.
  public func markEdit(path: String, lines: ClosedRange<Int>, cols: (start: Int, end: Int, length: Int)? = nil,
                       color: NSColor, reveal: Bool) {
    editMarks.append(PendingEditMark(path: relativePath(path), lines: lines, cols: cols, color: color, reveal: reveal,
                                     after: syncGenForMarks, at: CFAbsoluteTimeGetCurrent()))
    placeEditMarks()
  }

  /// Marks whose typeset has its SyncTeX now go up; ones older than 30 s (the edit typeset nothing) are dropped.
  func placeEditMarks() {
    let now = CFAbsoluteTimeGetCurrent()
    editMarks.removeAll { now - $0.at > 30 }
    guard let st = synctex, !editMarks.isEmpty else { return }
    var keep: [PendingEditMark] = []
    for m in editMarks {
      guard syncInstalledForMarks > m.after else { keep.append(m); continue }
      var byPage: [Int: [CGRect]] = [:]
      for l in m.lines {
        guard let (rows, marks) = st.rows(file: m.path, line: l) else { continue }
        var pick = Array(rows.indices)
        if let c = m.cols, m.lines.count == 1, !marks.isEmpty, c.length > 0 {
          // the typeset lines its columns fall on, by their share of the source line
          let k0 = marks[min(marks.count - 1, max(0, Int(Double(c.start) / Double(c.length) * Double(marks.count))))]
          let k1 = marks[min(marks.count - 1, max(0, Int(Double(max(c.end, c.start) ) / Double(c.length) * Double(marks.count))))]
          pick = Array(min(k0, k1)...max(k0, k1)).filter { rows.indices.contains($0) }
        }
        for i in pick { byPage[rows[i].page, default: []].append(rows[i].rect) }
      }
      for (page, rects) in byPage { pane.flashEdit(page: page, rects: rects, color: m.color) }
      if m.reveal, let (page, rects) = byPage.min(by: { $0.key < $1.key }), let top = rects.map(\.minY).min() {
        pane.revealIfHidden(page: page, y: top, h: (rects.map(\.maxY).max() ?? top) - top)
      }
      editMarksShown += 1
    }
    editMarks = keep
  }
}

struct PendingEditMark {
  let path: String
  let lines: ClosedRange<Int>
  let cols: (start: Int, end: Int, length: Int)?
  let color: NSColor
  let reveal: Bool
  let after: Int
  let at: CFAbsoluteTime
}

extension PDFPaneView {
  /// Seconds an outside edit's tint takes to fade.
  nonisolated(unsafe) public static var editFadeSeconds: CFTimeInterval = 4

  /// Tint `rects` (page points, y down) of `page` in `color`, fading out.
  func flashEdit(page: Int, rects: [CGRect], color: NSColor) {
    guard page < pages.count else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for r in rects {
      let l = CALayer()
      l.zPosition = 6
      l.frame = r.insetBy(dx: -2, dy: -1)
      l.cornerRadius = 2
      l.backgroundColor = color.withAlphaComponent(0.32).cgColor
      l.name = "editmark"
      pages[page].layer.addSublayer(l)
      let a = CABasicAnimation(keyPath: "opacity")
      a.fromValue = 1
      a.toValue = 0
      a.duration = Self.editFadeSeconds
      a.timingFunction = CAMediaTimingFunction(name: .easeIn)
      l.opacity = 0
      l.add(a, forKey: "fade")
      DispatchQueue.main.asyncAfter(deadline: .now() + Self.editFadeSeconds) { l.removeFromSuperlayer() }
    }
    CATransaction.commit()
  }

  /// Scroll so (page, y) is in view, a third of the way down, unless it is already well inside the view.
  func revealIfHidden(page: Int, y: CGFloat, h: CGFloat) {
    guard page < pages.count else { return }
    let b = scroll.contentView.bounds
    let top = pages[page].origin.y + y
    if top >= b.minY + b.height * 0.1 && top + h <= b.maxY - b.height * 0.1 { return }
    scrollTo(page: page, y: y)
  }

  /// For checks: the edit tints on the pages now (page, rect).
  public var editMarkRects: [(page: Int, rect: CGRect)] {
    pages.enumerated().flatMap { i, p in (p.layer.sublayers ?? []).filter { $0.name == "editmark" }.map { (i, $0.frame) } }
  }
}
