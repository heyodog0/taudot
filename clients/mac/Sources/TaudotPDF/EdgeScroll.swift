// Trackpad scrolling with our own rubber band at the edges.
//
// AppKit's elastic bounce-back runs at 60 Hz even on a 120 Hz display (measured: the view moves every other frame
// while it eases back), which shows as a judder at the top and bottom. So elasticity is off and trackpad (precise)
// scroll events are applied here: each event moves the view at once; a push past an edge becomes an overscroll with
// resistance; when the finger lifts (or momentum carries into the edge) it eases back once, on the view's own display
// link, and the rest of that momentum is dropped. Mouse wheels go to AppKit as before (clean stop at the edges).
import AppKit
import QuartzCore

/// Centers the document when it is narrower or shorter than the view, and adds the rubber band's overscroll.
final class CenteringClipView: NSClipView {
  /// Past the edge, in document points (negative: before the start).
  var overscroll = CGPoint.zero

  override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
    var r = super.constrainBoundsRect(NSRect(origin: proposedBounds.origin - overscroll, size: proposedBounds.size))
    if let doc = documentView {
      if r.width > doc.frame.width { r.origin.x = (doc.frame.width - r.width) / 2 }
      if r.height > doc.frame.height { r.origin.y = (doc.frame.height - r.height) / 2 }
    }
    r.origin = r.origin + overscroll
    return r
  }

  /// The origin without the overscroll.
  var base: CGPoint { bounds.origin - overscroll }
}

extension CGPoint {
  static func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
  static func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
}

/// The resistance curve (as UIScrollView's): x points of push show as less and less, never past `d`.
func rubber(_ x: CGFloat, _ d: CGFloat) -> CGFloat {
  let s: CGFloat = x < 0 ? -1 : 1
  return s * (1 - 1 / (abs(x) * 0.55 / d + 1)) * d
}

func unrubber(_ y: CGFloat, _ d: CGFloat) -> CGFloat {
  let s: CGFloat = y < 0 ? -1 : 1
  let f = min(abs(y) / d, 0.999)
  return s * (1 / (1 - f) - 1) * d / 0.55
}

final class PDFScrollView: NSScrollView {
  private var raw = CGPoint.zero  // the push past the edge, in view points, before resistance
  /// 0 undecided, 1 vertical, 2 horizontal, 3 free (for one gesture). A straight swipe stays on its axis; one that
  /// keeps moving sideways too (a circle, a diagonal) is freed, so it scrolls both ways.
  private var lockAxis: Int = 0
  /// Recent motion across the locked axis (leaky sum, points): above `unlockAfter`, the lock is dropped.
  private var offAxis: CGFloat = 0
  private let unlockAfter: CGFloat = 20
  private var dropMomentum = false
  private var momentumPush = 0  // momentum events that pushed into the edge
  private var link: CADisplayLink?
  private var releaseFrom = CGPoint.zero  // overscroll in view points when the ease back started
  private var releaseAt: CFTimeInterval = 0
  static let releaseTau = 0.075  // s; critically damped, settles in ~0.5 s

  override init(frame: NSRect) {
    super.init(frame: frame)
    verticalScrollElasticity = .none
    horizontalScrollElasticity = .none
  }
  required init?(coder: NSCoder) { fatalError() }

  var clip: CenteringClipView { contentView as! CenteringClipView }

  /// Scroll range of the base origin, per axis (equal ends when the document fits).
  private func range() -> (x: ClosedRange<CGFloat>, y: ClosedRange<CGFloat>) {
    guard let doc = documentView?.frame else { return (0...0, 0...0) }
    let b = clip.bounds
    let x = doc.width > b.width ? 0...(doc.width - b.width) : ((doc.width - b.width) / 2)...((doc.width - b.width) / 2)
    let y = doc.height > b.height ? 0...(doc.height - b.height) : ((doc.height - b.height) / 2)...((doc.height - b.height) / 2)
    return (x, y)
  }

  override func scrollWheel(with e: NSEvent) {
    guard e.hasPreciseScrollingDeltas, documentView != nil else { return super.scrollWheel(with: e) }
    if e.phase == .began || e.phase == .mayBegin {
      dropMomentum = false
      momentumPush = 0
      lockAxis = 0
      offAxis = 0
      if link != nil { stopRelease() }  // caught mid-bounce: carry on from where it is
      if e.phase == .began { flashScrollers() }
    }
    let momentum = !e.momentumPhase.isEmpty
    if momentum && dropMomentum { return }
    var dx = e.scrollingDeltaX, dy = e.scrollingDeltaY
    if lockAxis == 0 && !momentum && (abs(dx) + abs(dy)) > 0 {
      lockAxis = abs(dy) > abs(dx) * 2 ? 1 : abs(dx) > abs(dy) * 2 ? 2 : 3
    }
    if (lockAxis == 1 || lockAxis == 2) && !momentum {
      offAxis = offAxis * 0.9 + abs(lockAxis == 1 ? dx : dy)
      if offAxis > unlockAfter { lockAxis = 3 }
    }
    if lockAxis == 1 { dx = 0 } else if lockAxis == 2 { dy = 0 }
    let m = magnification
    let r = range()
    // horizontal only scrolls (and bounces) when the document is wider than the view
    let movedX = r.x.lowerBound < r.x.upperBound ? apply(-dx, axis: 0, range: r.x, m: m) : false
    let movedY = apply(-dy, axis: 1, range: r.y, m: m)
    if momentum && (movedX || movedY) { momentumPush += 1 }
    let over = raw.x != 0 || raw.y != 0
    let ended = e.phase == .ended || e.phase == .cancelled
    if over && ended {
      dropMomentum = true
      startRelease()
    } else if over && momentum && (momentumPush >= 5 || e.momentumPhase == .ended || abs(dx) + abs(dy) < 4) {
      // momentum carried into the edge: overshoot a little (more when faster), then ease back once
      dropMomentum = e.momentumPhase != .ended
      startRelease()
    }
  }

  /// Moves the view by `delta` view points on one axis; returns true when it pushed past the edge.
  private func apply(_ delta: CGFloat, axis: Int, range: ClosedRange<CGFloat>, m: CGFloat) -> Bool {
    guard delta != 0 else { return false }
    let dim = axis == 0 ? clip.bounds.width * m : clip.bounds.height * m
    var base = clip.base
    var pos = axis == 0 ? base.x : base.y
    var r = axis == 0 ? raw.x : raw.y
    var d = delta
    // first take back any overscroll
    if r != 0 && (r > 0) != (d > 0) {
      let take = (abs(d) >= abs(r)) ? -r : d
      r += take
      d -= take
    }
    var pushed = false
    if d != 0 {
      if r == 0 {
        let target = pos + d / m
        let clamped = min(max(target, range.lowerBound), range.upperBound)
        pos = clamped
        let left = (target - clamped) * m
        if left != 0 { r += left; pushed = true }
      } else {
        r += d
        pushed = true
      }
    }
    if axis == 0 { base.x = pos; raw.x = r } else { base.y = pos; raw.y = r }
    setOrigin(base: base)
    return pushed
  }

  /// Puts the view at `base` plus the rubber band of `raw`.
  private func setOrigin(base: CGPoint) {
    let m = magnification
    let w = clip.bounds.width * m, h = clip.bounds.height * m
    clip.overscroll = CGPoint(x: rubber(raw.x, w) / m, y: rubber(raw.y, h) / m)
    clip.setBoundsOrigin(base + clip.overscroll)
    reflectScrolledClipView(clip)
  }

  private func startRelease() {
    let m = magnification
    releaseFrom = CGPoint(x: clip.overscroll.x * m, y: clip.overscroll.y * m)
    releaseAt = CACurrentMediaTime()
    if link == nil {
      let l = displayLink(target: self, selector: #selector(releaseTick(_:)))
      l.add(to: .main, forMode: .common)
      link = l
    }
  }

  private func stopRelease() {
    link?.invalidate()
    link = nil
  }

  @objc private func releaseTick(_ l: CADisplayLink) {
    // critically damped: x(t) = x0 (1 + t/τ) e^(-t/τ), sampled at the time this frame will be shown
    let t = max(0, l.targetTimestamp - releaseAt) / Self.releaseTau
    let f = CGFloat((1 + t) * exp(-t))
    let m = magnification
    let w = clip.bounds.width * m, h = clip.bounds.height * m
    var o = CGPoint(x: releaseFrom.x * f, y: releaseFrom.y * f)
    if abs(o.x) < 0.5 && abs(o.y) < 0.5 { o = .zero }  // under a device pixel
    raw = CGPoint(x: o.x == 0 ? 0 : unrubber(o.x, w), y: o.y == 0 ? 0 : unrubber(o.y, h))
    let base = clip.base
    clip.overscroll = CGPoint(x: o.x / m, y: o.y / m)
    clip.setBoundsOrigin(base + clip.overscroll)
    reflectScrolledClipView(clip)
    if o == .zero { stopRelease() }
  }
}
