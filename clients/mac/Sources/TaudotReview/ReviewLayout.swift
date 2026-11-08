// Where the cards go: each wants the y of its line; overlapping ones are pushed apart, as Google Docs does.
import CoreGraphics

public enum ReviewLayout {
  /// Tops for cards in text order. `anchors`: the top each card wants (its line's y); `heights`: each card's height.
  /// Without a selection, cards only move down. With one, it keeps its anchor; the cards after it are pushed down
  /// below it and the ones before it are pushed up above it, as far as needed and no further.
  public static func stack(anchors: [CGFloat], heights: [CGFloat], selected: Int? = nil, gap: CGFloat = 8) -> [CGFloat] {
    let n = anchors.count
    precondition(heights.count == n)
    guard n > 0 else { return [] }
    var y = anchors
    let s = selected.map { min(max($0, 0), n - 1) }
    func down(_ from: Int, _ to: Int) {
      var i = max(from, 1)
      while i < to {
        y[i] = max(anchors[i], y[i - 1] + heights[i - 1] + gap)
        i += 1
      }
    }
    guard let s else {
      down(1, n)
      return y
    }
    down(1, s)  // the ones before the selection stack as usual...
    down(s + 1, n)
    var i = s - 1
    while i >= 0 {  // ...then move up as far as the selected card needs
      y[i] = min(y[i], y[i + 1] - heights[i] - gap)
      i -= 1
    }
    return y
  }
}
