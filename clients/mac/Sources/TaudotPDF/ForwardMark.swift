// The forward-search mark: a soft box on the cursor's word and a faint band over its typeset line, with a tick in
// the margin. It stays while the cursor stays, glides (~120 ms, ease-out) to the next place when the cursor moves,
// dims to an underline after ~10 s without a move, and goes when the cursor leaves the document. One animation per
// jump: it appears, glides or stays (MarkPlan).
import AppKit
import QuartzCore

@MainActor final class ForwardMark {
  static let glide = 0.12
  static let idle = 10.0
  /// Seconds without a move before it dims (tests shorten it).
  var idleAfter = ForwardMark.idle

  /// Lives in the pages view's layer (document points), above the pages, so it can glide from page to page.
  let layer = CALayer()
  private(set) var mark: MarkPlan.Mark?
  private var lines: [CALayer] = []
  private var ticks: [CALayer] = []
  private var boxes: [CALayer] = []
  private var dimTimer: DispatchWorkItem?
  private(set) var counts = (appear: 0, glide: 0, stay: 0)
  /// The page origins (document points) and the zoom, from the pane.
  var origin: (Int) -> CGPoint = { _ in .zero }
  var magnification: () -> CGFloat = { 1 }

  init() {
    layer.anchorPoint = .zero
    layer.zPosition = 10
  }

  var dimmed: Bool { mark?.dimmed ?? false }

  /// Shows a mark at `words` and `lines` of `page` (page points); returns what it did.
  @discardableResult
  func show(page: Int, words: [CGRect], lines newLines: [CGRect], color: CGColor, tint: MarkColor.Tint) -> MarkPlan {
    let plan = MarkPlan.decide(current: mark, page: page, words: words, lines: newLines)
    switch plan {
    case .stay: counts.stay += 1
    case .glide: counts.glide += 1
    case .appear: counts.appear += 1
    }
    defer { armDim() }
    if plan == .stay { return plan }
    let o = origin(page)
    let m = magnification()
    laidOutAt = m
    let lineFrames = newLines.map { LineMark.band($0).offsetBy(dx: o.x, dy: o.y) }
    let tickFrames = newLines.prefix(1).map { LineMark.tick($0, magnification: m).offsetBy(dx: o.x, dy: o.y) }
    let boxFrames = words.map { $0.insetBy(dx: -1.5, dy: -1).offsetBy(dx: o.x, dy: o.y) }
    let big = words.contains { $0.height > LineMark.maxLine }
    if plan == .appear { clear(animated: false) }
    CATransaction.begin()
    CATransaction.setAnimationDuration(Self.glide)
    CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
    // layers that move: their frames animate (implicit actions); new ones fade in where they land; extra ones fade out
    lines = place(lines, lineFrames, appear: plan == .appear) { l, r in
      l.cornerRadius = min(3, r.height / 4)
      l.backgroundColor = color.copy(alpha: tint.band)
      l.borderColor = color.copy(alpha: tint.bandEdge)
      l.borderWidth = max(0.5, 0.75 / m)
    }
    ticks = place(ticks, tickFrames, appear: plan == .appear) { t, r in
      t.cornerRadius = r.width / 2
      t.backgroundColor = color.copy(alpha: tint.tick)
    }
    boxes = place(boxes, boxFrames, appear: plan == .appear) { b, r in
      b.cornerRadius = min(4, r.height / 3)
      // a figure-sized box (a graphic) gets a light tint: the image stays readable under it
      b.backgroundColor = color.copy(alpha: big ? tint.band * 0.6 : tint.word)
      b.borderColor = color.copy(alpha: tint.wordEdge)
      b.borderWidth = big ? 2 : 1.25
      let u = b.sublayers?.first ?? { let u = CALayer(); b.addSublayer(u); return u }()
      u.frame = CGRect(x: 1.5, y: r.height - 2.6, width: max(0, r.width - 3), height: 1.2)
      u.backgroundColor = color.copy(alpha: 0.7)
      u.opacity = 0  // the underline it dims to
    }
    CATransaction.commit()
    mark = MarkPlan.Mark(page: page, words: words, lines: newLines)
    return plan
  }

  /// `old` layers moved onto `frames` (pairwise), more made or the rest dropped; `style` sets each one's look.
  private func place(_ old: [CALayer], _ frames: [CGRect], appear: Bool, style: (CALayer, CGRect) -> Void) -> [CALayer] {
    var out: [CALayer] = []
    for (i, r) in frames.enumerated() {
      if i < old.count && !appear {
        let l = old[i]
        l.removeAnimation(forKey: "fade")
        l.opacity = 1
        l.frame = r  // glides
        style(l, r)
        out.append(l)
      } else {
        let l = CALayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        l.frame = r
        style(l, r)
        layer.addSublayer(l)
        CATransaction.commit()
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 0
        a.toValue = 1
        a.duration = Self.glide
        l.add(a, forKey: "in")
        out.append(l)
      }
    }
    for l in old.dropFirst(frames.count) where !appear { fadeAway(l) }
    return out
  }

  private func fadeAway(_ l: CALayer) {
    CATransaction.begin()
    CATransaction.setAnimationDuration(Self.glide)
    CATransaction.setCompletionBlock { l.removeFromSuperlayer() }
    l.opacity = 0
    CATransaction.commit()
  }

  /// Dims after `idle` s without a move (the follow mode); a deliberate jump's mark stays until the cursor leaves
  /// its line.
  var dimWhenIdle = true {
    didSet { if !dimWhenIdle { dimTimer?.cancel(); dimTimer = nil } }
  }

  private func armDim() {
    dimTimer?.cancel()
    guard dimWhenIdle else { return }
    let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.dim() } }
    dimTimer = w
    DispatchQueue.main.asyncAfter(deadline: .now() + idleAfter, execute: w)
  }

  /// After a while without a move: just an underline under the word (or nothing on the line but its tick gone).
  func dim() {
    guard var m = mark, !m.dimmed else { return }
    trace("mark: dimmed (idle)")
    m.dimmed = true
    mark = m
    CATransaction.begin()
    CATransaction.setAnimationDuration(0.6)
    for l in lines + ticks { l.opacity = 0 }
    for b in boxes {
      b.backgroundColor = b.backgroundColor?.copy(alpha: 0)
      b.borderColor = b.borderColor?.copy(alpha: 0)
      b.sublayers?.first?.opacity = 1
    }
    CATransaction.commit()
  }

  /// The cursor left the document (another file, a line SyncTeX doesn't have): the mark goes.
  func clear(animated: Bool = true) {
    if animated, mark != nil { trace("mark: cleared") }
    dimTimer?.cancel()
    for l in lines + ticks + boxes {
      if animated { fadeAway(l) } else { l.removeFromSuperlayer() }
    }
    lines = []
    ticks = []
    boxes = []
    mark = nil
  }

  /// Pages moved (a re-layout): the mark follows without animating.
  /// After a zoom change: the tick and the band's edge are sized in screen points, so they follow the zoom.
  func rescale() {
    guard mark != nil, abs(magnification() - laidOutAt) > 0.0005 else { return }
    relayout()
  }
  private var laidOutAt: CGFloat = 0

  func relayout() {
    guard let m = mark else { return }
    let o = origin(m.page), mag = magnification()
    laidOutAt = mag
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for (l, r) in zip(lines, m.lines) { l.frame = LineMark.band(r).offsetBy(dx: o.x, dy: o.y) }
    for (t, r) in zip(ticks, m.lines) { t.frame = LineMark.tick(r, magnification: mag).offsetBy(dx: o.x, dy: o.y) }
    for l in lines { l.borderWidth = max(0.5, 0.75 / mag) }
    for t in ticks { t.cornerRadius = t.frame.width / 2 }
    for (b, r) in zip(boxes, m.words) { b.frame = r.insetBy(dx: -1.5, dy: -1).offsetBy(dx: o.x, dy: o.y) }
    CATransaction.commit()
  }
}
