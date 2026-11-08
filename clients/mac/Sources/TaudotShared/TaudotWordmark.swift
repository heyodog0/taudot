// Taudot's wordmark ("Hand"): the mark's tau as the T, round-capped geometric lowercase, and you as the coral
// period. Drawn in code, no assets. Geometry matches docs/design/logo/final/wordmark/ (build_wordmark.py, hand()).
//
//   TaudotWordmark().frame(height: 24)                     // "Taudot." in the foreground style, coral period
//   TaudotWordmark(dot: nil)                               // one colour, the period too
//   TaudotWordmark(period: false)                          // just the word
//   TaudotLockup().frame(height: 40)                       // the mark + the word (no period: the mark has the dot)
//
// Any foreground style works, translucent ones included: the ink is one outline filled once.
import SwiftUI

public struct TaudotWordmark: View {
  /// The period's colour; nil draws it in the foreground style.
  public var dot: Color?
  public var period: Bool
  public init(dot: Color? = TaudotMark.coral, period: Bool = true) {
    self.dot = dot
    self.period = period
  }

  public var body: some View {
    TaudotArtwork(art: period ? .wordmark : .word, dot: dot).accessibilityLabel("Taudot")
  }
}

/// The mark beside the word, sharing a baseline: for headers and About windows.
public struct TaudotLockup: View {
  /// The mark's dot colour; nil draws it in the foreground style.
  public var dot: Color?
  public init(dot: Color? = TaudotMark.coral) { self.dot = dot }

  public var body: some View {
    TaudotArtwork(art: .lockup, dot: dot).accessibilityLabel("Taudot")
  }
}

/// Ink and dot outlines in one coordinate space, with the box to fit.
struct TaudotArt {
  var ink: Path
  var dot: Path
  var box: CGRect

  static let wordmark = Hand.art(period: true)
  static let word = Hand.art(period: false)
  static let lockup: TaudotArt = {
    // The flat mark at 1.15x the cap height, its bottom on the baseline, a quarter cap height before the word.
    let w = Hand.art(period: false)
    let s = 1.15 * Hand.cap / 670
    let mx = -823 * s - 0.25 * Hand.cap
    let place = CGAffineTransform(translationX: -149, y: -190)
      .concatenating(CGAffineTransform(scaleX: s, y: s))
      .concatenating(CGAffineTransform(translationX: mx, y: -670 * s + Hand.ov))
    let ink = Path(TaudotMark.Glyph.tau.applying(place).cgPath.union(w.ink.cgPath))
    let top = min(w.box.minY, -670 * s + Hand.ov)
    return TaudotArt(ink: ink, dot: TaudotMark.Glyph.dot.applying(place),
                     box: CGRect(x: mx, y: top, width: w.box.maxX - mx, height: w.box.maxY - top))
  }()
}

struct TaudotArtwork: View {
  var art: TaudotArt
  var dot: Color?

  var body: some View {
    ZStack {
      if let dot {
        Fitted(art: art, part: .ink).fill(.foreground)
        Fitted(art: art, part: .dot).fill(dot)
      } else {
        Fitted(art: art, part: .both).fill(.foreground)
      }
    }
    .aspectRatio(art.box.width / art.box.height, contentMode: .fit)
    .accessibilityElement()
  }

  struct Fitted: Shape {
    enum Part { case ink, dot, both }
    var art: TaudotArt
    var part: Part

    func path(in rect: CGRect) -> Path {
      let box = art.box
      let s = min(rect.width / box.width, rect.height / box.height)
      let fit = CGAffineTransform(a: s, b: 0, c: 0, d: s,
                                  tx: rect.midX - box.midX * s, ty: rect.midY - box.midY * s)
      let p: Path
      switch part {
      case .ink: p = art.ink
      case .dot: p = art.dot
      case .both: p = Path(art.ink.cgPath.union(art.dot.cgPath))
      }
      return p.applying(fit)
    }
  }
}

/// The hand-drawn letters (build_wordmark.py's letters(), tau() and hand()). Baseline y = 0, y down.
enum Hand {
  static let xh: CGFloat = 500, asc: CGFloat = 740, cap: CGFloat = 700, ov: CGFloat = 10
  static let w: CGFloat = 112

  /// A centre line, stroked with round caps and joins.
  static func stroke(_ p: Path, _ width: CGFloat) -> CGPath {
    p.cgPath.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 4)
  }

  static func line(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) -> Path {
    var p = Path()
    p.move(to: CGPoint(x: x0, y: y0))
    p.addLine(to: CGPoint(x: x1, y: y1))
    return p
  }

  /// Each lowercase letter's centre lines and advance, from x = 0 at its left outer edge.
  static func letter(_ ch: Character) -> ([Path], CGFloat) {
    let h = w / 2
    let rc = xh / 2 + ov - h  // bowl radius on the centre line
    let cx = h + rc, cy = -xh / 2
    let bowl = Path(ellipseIn: CGRect(x: cx - rc, y: cy - rc, width: 2 * rc, height: 2 * rc))
    let wide = 2 * (rc + h)
    let top = -xh + h, foot = -h
    switch ch {
    case "o": return ([bowl], wide)
    case "a": return ([bowl, line(cx + rc, top, cx + rc, foot)], wide)
    case "d": return ([bowl, line(cx + rc, -asc + h, cx + rc, foot)], wide)
    case "u":
      // The bowl's bottom half, open at the top, with a full right stem.
      let ucy = foot + ov - rc
      var u = Path()
      u.move(to: CGPoint(x: h, y: top))
      u.addLine(to: CGPoint(x: h, y: ucy))
      u.addArc(center: CGPoint(x: h + rc, y: ucy), radius: rc, startAngle: .degrees(180), endAngle: .degrees(0),
               clockwise: true)
      return ([u, line(h + 2 * rc, top, h + 2 * rc, foot)], wide)
    case "t":
      // A stem whose foot curls right like the tau's, and a crossbar at the x-height.
      let la = 0.18 * xh, ra = 0.30 * xh, rt = 0.26 * xh
      let sx = h + la
      var t = Path()
      t.move(to: CGPoint(x: sx, y: -0.86 * asc + h))
      t.addLine(to: CGPoint(x: sx, y: foot - rt))
      t.addArc(center: CGPoint(x: sx + rt, y: foot - rt), radius: rt, startAngle: .degrees(180),
               endAngle: .degrees(90), clockwise: true)
      t.addLine(to: CGPoint(x: sx + rt + 0.10 * xh, y: foot))
      return ([t, line(h, top, sx + ra, top)], sx + max(ra, rt + 0.10 * xh) + h)
    default: return ([], 0)
    }
  }

  /// The T: the mark's two curves (before the lean), refitted so they sit on the cap line and the baseline.
  static func tau() -> (CGPath, CGFloat) {
    let wb = w * 150 / 142, ws = w  // the mark's bar is a touch heavier than its stem
    let k = (cap - wb / 2 - ws / 2) / (753 - 300)
    let x0 = 262 - wb / 2 / k
    func f(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: (x - x0) * k, y: (y - 300) * k - cap + wb / 2) }
    var bar = Path()
    bar.move(to: f(262, 420))
    bar.addCurve(to: f(400, 300), control1: f(270, 330), control2: f(320, 300))
    bar.addLine(to: f(770, 300))
    var stem = Path()
    stem.move(to: f(560, 330))
    stem.addCurve(to: f(600, 680), control1: f(552, 480), control2: f(552, 590))
    stem.addCurve(to: f(760, 744), control1: f(636, 748), control2: f(700, 760))
    let right = max(f(770, 300).x + wb / 2, f(760, 744).x + ws / 2)
    return (stroke(bar, wb).union(stroke(stem, ws)), right)
  }

  static func art(period: Bool) -> TaudotArt {
    let gap = 0.11 * xh
    var (ink, right) = tau()
    var x = right + gap - 0.02 * xh
    for ch in "audot" {
      let (paths, adv) = letter(ch)
      for p in paths {
        ink = ink.union(stroke(p.applying(CGAffineTransform(translationX: x, y: 0)), w))
      }
      x += adv + (ch == "t" ? 0 : gap)
    }
    var dot = Path()
    if period {
      let r = 0.62 * w
      x += 0.10 * xh
      dot = Path(ellipseIn: CGRect(x: x, y: -2 * r, width: 2 * r, height: 2 * r))
      x += 2 * r
    }
    return TaudotArt(ink: Path(ink), dot: dot, box: CGRect(x: 0, y: -asc, width: x, height: asc + ov))
  }
}
