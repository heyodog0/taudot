// Pixel-smooth scrolling for one window: keep the lines that scrolled out, animate the offset back to zero.
// The approach (a ring of 2×height rows and a critically damped spring on the offset) follows Neovide's.
import Foundation

/// A critically damped spring towards 0: reaches 2% of its start in `length` seconds; retargetable by adding to
/// `position` mid-flight (velocity carries over).
public struct Spring: Sendable {
  public var position: Double = 0
  public var velocity: Double = 0
  public init() {}

  /// Returns whether it is still moving.
  /// `epsilon`: stop once closer than this (and slow), e.g. half a pixel in the spring's units.
  public mutating func step(_ dt: Double, length: Double, epsilon: Double = 0.02) -> Bool {
    if position == 0 { velocity = 0; return false }
    if length <= dt { self = Spring(); return false }
    let omega = 4.0 / length
    let a = position, b = position * omega + velocity
    let c = exp(-omega * dt)
    position = (a + b * dt) * c
    velocity = c * (-a * omega - b * dt * omega + b)
    if abs(position) < epsilon && abs(velocity) < epsilon * 25 { self = Spring(); return false }
    return true
  }
}

/// The scrolled part of a window (rows between its top and bottom margins).
public struct SmoothScroll: Sendable {
  public private(set) var height = 0
  var ring: [Row?] = []
  /// For each slot, the absolute row (base + k) it was written for. A slot is only read back for that row: without
  /// this, an offset past the kept rows wrapped around the ring and drew rows saved at other moments.
  var ringAbs: [Int] = []
  var base = 0
  /// The animated offset in lines: line k of the ring is drawn at (k - offset) rows from the top.
  public var spring = Spring()
  /// Trackpad offset not yet absorbed by Neovim (lines, fractional; positive: content moved up).
  public var finger: Double = 0
  /// How many lines to show when a jump is too far to animate fully.
  public var farLines = 1

  public init() {}

  public var offset: Double { spring.position + finger }

  /// How far the drawn view trails `offset` because the rows it would show aren't known yet (rows). Kept so a flush
  /// (which moves `offset` and the rows together) doesn't disturb it; eases to 0 once the rows are there.
  public var lag: Double = 0

  /// Rows known right below the window (k = height, height+1, ...) and right above it (k = -1, -2, ...).
  func knownBelow() -> Int { var n = 0; while n < height, row(height + n) != nil { n += 1 }; return n }
  func knownAbove() -> Int { var n = 0; while n < height, row(-1 - n) != nil { n += 1 }; return n }

  /// The offset actually drawn: `offset`, but never further than the known rows, so no row is drawn blank where
  /// Neovim has text (a flick's first rows used to show empty until Neovim's redraw came).
  public var drawnOffset: Double {
    let d = offset - lag
    if d > 0 { return min(d, Double(knownBelow())) }
    if d < 0 { return max(d, -Double(knownAbove())) }
    return d
  }
  /// The view's top in absolute rows (sum of all deltas plus the offset): what the eye sees move, because row k is
  /// drawn at (k - offset).
  public var position: Double { Double(base) + drawnOffset }

  @inline(__always) func idx(_ k: Int) -> Int {
    let n = ring.count
    return ((base + k) % n + n) % n
  }

  /// Row k (0 is the window's first scrolled row; negative is above it; ≥ height below it), or nil if unknown.
  public func row(_ k: Int) -> Row? {
    guard !ring.isEmpty else { return nil }
    let i = idx(k)
    return ringAbs[i] == base + k ? ring[i] : nil
  }

  @inline(__always) mutating func put(_ k: Int, _ r: Row?) {
    let i = idx(k)
    ring[i] = r
    ringAbs[i] = r == nil ? Int.min : base + k
  }

  public mutating func reset(_ rows: ArraySlice<Row>) {
    height = rows.count
    ring = Array(repeating: nil, count: max(2 * height, 1))
    ringAbs = Array(repeating: Int.min, count: ring.count)
    base = 0
    for (k, r) in rows.enumerated() { put(k, r) }
    spring = Spring()
    finger = 0
    lag = 0
  }

  /// On Neovim's `flush`: the window's current rows and the `scroll_delta` since the last flush. If `fromFinger`,
  /// the delta pays off the trackpad offset instead of starting an animation.
  public mutating func flush(_ rows: ArraySlice<Row>, delta: Int, fromFinger: Bool = false) {
    if rows.count != height || ring.isEmpty { reset(rows); return }
    base += delta
    for (k, r) in rows.enumerated() { put(k, r) }
    guard delta != 0 else { return }
    let maxDelta = ring.count - height
    if fromFinger {
      finger -= Double(delta)
      // Never show more than the kept lines.
      finger = min(max(finger, -Double(maxDelta)), Double(maxDelta))
    } else if abs(delta) > maxDelta {
      let far = min(farLines, height)
      spring.position = -Double(far * delta.signum())
      let gap = delta > 0 ? (-far..<0) : (height..<height + far)
      for k in gap { put(k, nil) }
    } else {
      spring.position = min(max(spring.position - Double(delta), -Double(maxDelta)), Double(maxDelta))
    }
  }

  /// Advance the animation; returns whether it is still moving.
  public mutating func step(_ dt: Double, length: Double, epsilon: Double = 0.02) -> Bool {
    let moving = spring.step(dt, length: length, epsilon: epsilon)
    // Hold at the last known row, then catch up with the finger quickly (τ 30 ms).
    lag = offset - drawnOffset
    lag *= exp(-dt / 0.03)
    if abs(lag) < 0.01 { lag = 0 }
    lag = offset - Swift.max(Swift.min(offset - lag, Double(knownBelow())), -Double(knownAbove()))
    return moving || lag != 0
  }

  /// The ring rows to draw this frame, with their y in rows (fractional) from the top of the scrolled region.
  public func visible() -> [(k: Int, y: Double, row: Row)] {
    let o = drawnOffset
    let first = Int(floor(o))
    var out: [(Int, Double, Row)] = []
    for k in first...(first + height) {
      if let r = row(k) { out.append((k, Double(k) - o, r)) }
    }
    return out
  }
}
