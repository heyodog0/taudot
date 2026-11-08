/// Aligns a source line's letters with the page's letters: an edit distance where the page side may start and end
/// anywhere (the typeset lines around a source line hold other lines' words). Page gaps are affine: a float, a
/// footnote or a citation's text between two halves of the line costs little more than one letter, so the line's
/// words stay together. Skipping a source letter (what we read as text but TeX didn't typeset) costs per letter.
enum Align {
  static let mismatch: Int32 = 30, skipSource: Int32 = 20, gapOpen: Int32 = 30, gapExtend: Int32 = 1

  /// For each source letter, the page letter it lands on (-1: skipped) and whether the two are the same letter.
  /// `far[j]`: page letter j is on a row next to the line's own rows; matching it costs 1, so of two equal readings
  /// (the same words in two headings) the one on the line's own rows wins.
  static func run(_ s: [UInt32], _ g: [UInt32], far: [Bool]? = nil) -> (match: [Int], same: [Bool], cost: Int) {
    let n = s.count, m = g.count
    guard n > 0 else { return ([], [], 0) }
    guard m > 0 else { return ([Int](repeating: -1, count: n), [Bool](repeating: false, count: n), n * Int(skipSource)) }
    let w = m + 1
    let hit: [Int32] = far.map { $0.map { $0 ? 1 : 0 } } ?? [Int32](repeating: 0, count: m)
    let big = Int32.max / 4
    // per cell: bits 0-1 how H was reached (0 diagonal, 1 skip source, 2 page gap), bit 2: the page gap continues one
    var dir = [UInt8](repeating: 0, count: (n + 1) * w)
    var hPrev = [Int32](repeating: 0, count: w)  // row 0: free start on the page
    var hCur = [Int32](repeating: 0, count: w)
    for i in 1...n {
      hCur[0] = Int32(i) * skipSource
      dir[i * w] = 1
      var e = big  // best cost ending in a page gap at (i, j)
      let si = s[i - 1]
      dir.withUnsafeMutableBufferPointer { d in
        let row = i * w
        for j in 1...m {
          var bits: UInt8 = 0
          let open = hCur[j - 1] + gapOpen + gapExtend, ext = e + gapExtend
          if ext <= open { e = ext; bits = 4 } else { e = open }
          var best = hPrev[j - 1] + (si == g[j - 1] ? hit[j - 1] : mismatch), how: UInt8 = 0
          let up = hPrev[j] + skipSource
          if up < best { best = up; how = 1 }
          if e < best { best = e; how = 2 }
          hCur[j] = best
          d[row + j] = how | bits
        }
      }
      swap(&hPrev, &hCur)
    }
    var j = 0
    for k in 1...m where hPrev[k] < hPrev[j] { j = k }  // free end on the page
    let cost = Int(hPrev[j])
    var match = [Int](repeating: -1, count: n), same = [Bool](repeating: false, count: n)
    var i = n
    var inGap = false
    while i > 0 && j > 0 {
      let c = dir[i * w + j]
      if inGap {
        inGap = c & 4 != 0
        j -= 1
        continue
      }
      switch c & 3 {
      case 0:
        match[i - 1] = j - 1
        same[i - 1] = s[i - 1] == g[j - 1]
        i -= 1; j -= 1
      case 1: i -= 1
      default:
        inGap = c & 4 != 0
        j -= 1
      }
    }
    return (match, same, cost)
  }
}
