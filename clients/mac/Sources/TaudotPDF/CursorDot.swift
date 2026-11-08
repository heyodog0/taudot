// The editor's cursor on the PDF: a coral caret at the exact letter, with the logo's dot at its foot (coral is
// "you" in the brand). A ring instead of the dot when the place is approximate (the cursor in a command, a comment,
// maths that didn't match: the nearest typeset letter). Geometry as the renderer's host draws it
// (clients/render/cursor/Sources/taudot-cursor-host, `drawCursor`).
import AppKit
import QuartzCore
import TaudotCursor

@MainActor final class CursorDot {
  static let coral = CGColor(srgbRed: 1.0, green: 0.369, blue: 0.302, alpha: 1)

  /// In the pages view's layer (document points), above the pages and the forward mark.
  let layer = CALayer()
  private let bar = CALayer()
  private let dot = CAGradientLayer()
  private let dotMask = CAShapeLayer()
  private let ring = CAShapeLayer()
  private(set) var caret: Caret?
  var origin: (Int) -> CGPoint = { _ in .zero }
  /// How many times it was drawn (for benches).
  private(set) var draws = 0

  init() {
    layer.anchorPoint = .zero
    layer.zPosition = 11
    layer.isHidden = true
    bar.backgroundColor = Self.coral
    dot.type = .radial
    dot.colors = [CGColor(srgbRed: 1.0, green: 0.643, blue: 0.541, alpha: 1), Self.coral, CGColor(srgbRed: 0.886, green: 0.235, blue: 0.188, alpha: 1)]
    dot.locations = [0, 0.55, 1]
    dot.startPoint = CGPoint(x: 0.35, y: 0.3)
    dot.endPoint = CGPoint(x: 1.05, y: 1.05)
    dot.mask = dotMask
    ring.fillColor = nil
    ring.strokeColor = Self.coral
    for l in [bar, dot, ring] as [CALayer] { layer.addSublayer(l) }
  }

  /// Our own estimate when CursorMap has none (page, x, top, bottom, baseline): always a ring.
  private(set) var estimate: (page: Int, x: Double, top: Double, bottom: Double, baseline: Double)?
  var visible: Bool { caret != nil || estimate != nil }

  /// A ring at an estimate (page points): the line SyncTeX gives and, if the glyphs are read, the word.
  func showEstimate(page: Int, x: Double, top: Double, bottom: Double, baseline: Double) {
    caret = nil
    estimate = (page, x, top, bottom, baseline)
    draw(page: page, x: x, top: top, bottom: bottom, baseline: baseline, approximate: true)
  }

  /// The caret at `c` (page points), or nil: hidden (the line typesets nothing).
  func show(_ c: Caret?) {
    caret = c
    estimate = nil
    guard let c else {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      layer.isHidden = true
      CATransaction.commit()
      return
    }
    draw(page: c.page, x: c.x, top: c.top, bottom: c.bottom, baseline: c.baseline, approximate: c.approximate)
  }

  /// The caret's drawing (page points), as `show` does it.
  func draw(page: Int, x cx: Double, top: Double, bottom: Double, baseline: Double, approximate: Bool) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)  // it follows typing: no lag, no animation
    defer { CATransaction.commit() }
    let o = origin(page)
    let em = max(4, (bottom - top) / 1.2)
    let base = o.y + baseline, x = o.x + cx
    bar.frame = CGRect(x: x - 0.45, y: base - 0.72 * em, width: 0.9, height: 0.72 * em)
    let r = 0.17 * em
    let d = CGRect(x: x - r, y: base + 0.25 * r, width: 2 * r, height: 2 * r)
    dot.frame = d
    dotMask.path = CGPath(ellipseIn: CGRect(origin: .zero, size: d.size), transform: nil)
    ring.frame = d
    ring.lineWidth = max(0.6, r * 0.35)
    ring.path = CGPath(ellipseIn: CGRect(origin: .zero, size: d.size).insetBy(dx: ring.lineWidth / 2, dy: ring.lineWidth / 2), transform: nil)
    dot.isHidden = approximate
    ring.isHidden = !approximate
    layer.isHidden = false
    draws += 1
  }

  /// Pages moved: redraw where it is.
  func relayout() {
    if let e = estimate { showEstimate(page: e.page, x: e.x, top: e.top, bottom: e.bottom, baseline: e.baseline) } else { show(caret) }
  }
}
