import Foundation

/// The records of a SyncTeX file (version 1, uncompressed) that tie source lines to page positions.
/// Positions are in PDF points from the page's top-left, y down: the frame of `PageGlyphs`.
public struct SyncTeX: Sendable {
  public struct Record: Sendable {
    /// `(` hbox, `[` vbox, `h` void hbox, `v` void vbox, `x` current point, `k` kern, `g` glue, `$` maths
    public var kind: Character
    public var tag: Int, line: Int
    public var x: Double, y: Double  // y: the baseline
    public var width: Double, height: Double, depth: Double
  }

  /// input tag → file name, as TeX opened it
  public private(set) var inputs: [Int: String] = [:]
  /// records of each page, pages[0] is the first page
  public private(set) var pages: [[Record]] = []
  /// (tag, line) → (page, record index) of every record of that line
  private var byLine: [Int64: [(Int, Int)]] = [:]

  public init(text: String) {
    var unit = 1.0, mag = 1000.0, xoff = 0.0, yoff = 0.0
    var scale = 1.0
    var inContent = false
    var page = -1
    for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
      let line = raw.last == "\r" ? raw.dropLast() : raw
      guard let first = line.first else { continue }
      if line.hasPrefix("Input:") {
        let rest = line.dropFirst(6)
        if let colon = rest.firstIndex(of: ":"), let tag = Int(rest[..<colon]) {
          inputs[tag] = String(rest[rest.index(after: colon)...])
        }
        continue
      }
      if !inContent {
        func number(_ prefix: String) -> Double? { line.hasPrefix(prefix) ? Double(line.dropFirst(prefix.count)) : nil }
        if let v = number("Unit:") { unit = v }
        if let v = number("Magnification:"), v != 0 { mag = v }
        if let v = number("X Offset:") { xoff = v }
        if let v = number("Y Offset:") { yoff = v }
        if line == "Content:" {
          inContent = true
          // scaled points → TeX points → PDF points
          scale = unit * mag / 1000 / 65536 * 72 / 72.27
        }
        continue
      }
      switch first {
      case "{":
        if let n = Int(line.dropFirst()), n >= 1 {
          while pages.count < n { pages.append([]) }
          page = n - 1
        }
        continue
      case "}":
        page = -1
        continue
      case "(", "[", "h", "v", "x", "k", "g", "$":
        break
      default:
        if line.hasPrefix("Postamble:") { return }
        continue
      }
      guard page >= 0 else { continue }
      // KIND TAG,LINE:X,Y[:W[,H,D]] (k and g: TAG,LINE:X,Y[:W])
      var nums = [Int](repeating: 0, count: 7)
      var count = 0, cur = 0, neg = false, digits = false
      for b in line.utf8.dropFirst() {
        if b >= 48 && b <= 57 { cur = cur * 10 + Int(b - 48); digits = true }
        else if b == 45 && !digits { neg = true }
        else if b == 44 || b == 58 {
          if count < 7 { nums[count] = neg ? -cur : cur; count += 1 }
          cur = 0; neg = false; digits = false
        } else { break }
      }
      if digits && count < 7 { nums[count] = neg ? -cur : cur; count += 1 }
      guard count >= 4 else { continue }
      let r = Record(kind: first, tag: nums[0], line: nums[1],
                     x: (Double(nums[2]) + xoff) * scale, y: (Double(nums[3]) + yoff) * scale,
                     width: count > 4 ? Double(nums[4]) * scale : 0, height: count > 5 ? Double(nums[5]) * scale : 0,
                     depth: count > 6 ? Double(nums[6]) * scale : 0)
      byLine[Self.key(r.tag, r.line), default: []].append((page, pages[page].count))
      pages[page].append(r)
    }
  }

  private static func key(_ tag: Int, _ line: Int) -> Int64 { Int64(tag) << 32 | Int64(line) }

  /// Tags of the inputs that are `file`: the same path, or one is a path suffix of the other ("main.tex" and
  /// "/x/main.tex", "./sec/a.tex" and "sec/a.tex").
  public func tags(of file: String) -> [Int] {
    func parts(_ s: String) -> [Substring] { s.split(separator: "/").filter { $0 != "." } }
    let want = parts(file)
    return inputs.compactMap { tag, name in
      let have = parts(name)
      let n = min(have.count, want.count)
      return n > 0 && have.suffix(n) == want.suffix(n) ? tag : nil
    }.sorted()
  }

  /// The records of line `line` (1-based) of `file`, with their page. Boxes (`(` and `[`) are left out unless `boxes`:
  /// a box carries the line where TeX opened it, which for a page or a float says little about where its words are.
  public func records(file: String, line: Int, boxes: Bool = false) -> [(page: Int, record: Record)] {
    var out: [(Int, Record)] = []
    for tag in tags(of: file) {
      for (p, i) in byLine[Self.key(tag, line)] ?? [] {
        let r = pages[p][i]
        if boxes || (r.kind != "(" && r.kind != "[" && r.kind != "v") { out.append((p, r)) }
      }
    }
    return out
  }

  /// Source lines with a record on `page` whose baseline is within `y0...y1`: what may have typeset a line there.
  public func lines(page: Int, y0: Double, y1: Double) -> [(file: String, line: Int)] {
    guard page >= 0 && page < pages.count else { return [] }
    var seen = Set<Int64>()
    var out: [(String, Int)] = []
    // hboxes count (a heading may have no other record), vboxes don't (a page, a float)
    for r in pages[page] where r.kind != "[" && r.kind != "v" && r.y >= y0 && r.y <= y1 {
      guard let file = inputs[r.tag], seen.insert(Self.key(r.tag, r.line)).inserted else { continue }
      out.append((file, r.line))
    }
    return out
  }
}
