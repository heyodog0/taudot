// A small SyncTeX reader, the Swift twin of clients/preview/synctex.ts (format notes there): page point → source line
// (inverse search), source line → page point (forward search). Coordinates are PDF points from the page's top-left.
import CoreGraphics
import Foundation

public struct SyncTex: Sendable {
  public struct Node: Sendable {
    public var kind: UInt8  // one of [ ( v h k g $ x r
    public var tag: Int, line: Int
    public var x: Double, y: Double, w: Double, h: Double, d: Double
    public var parent: Int  // index of the enclosing box in the page's nodes, -1 at the top
  }

  public var inputs: [Int: String] = [:]
  public var pages: [[Node]] = []  // pages[0] is page 1

  public init(_ text: String) {
    var unit = 1.0, mag = 1000.0, k = 1.0
    var content = false
    var page = -1
    var stack: [Int] = []
    func input(_ l: Substring) {
      let rest = l.dropFirst("Input:".count)
      guard let c = rest.firstIndex(of: ":"), let tag = Int(rest[..<c]) else { return }
      inputs[tag] = String(rest[rest.index(after: c)...])
    }
    for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
      let l = raw.hasSuffix("\r") ? raw.dropLast() : raw
      if !content {
        if l.hasPrefix("Input:") { input(l) }
        else if l.hasPrefix("Unit:") { unit = Double(l.dropFirst(5)) ?? 1 }
        else if l.hasPrefix("Magnification:") { mag = Double(l.dropFirst(14)).flatMap { $0 == 0 ? nil : $0 } ?? 1000 }
        else if l == "Content:" {
          content = true
          k = unit * mag / 1000 / 65536 * (72 / 72.27)
        }
        continue
      }
      guard let c = l.utf8.first else { continue }
      switch c {
      case UInt8(ascii: "I"):
        if l.hasPrefix("Input:") { input(l) }
        continue
      case UInt8(ascii: "P"):
        if l.hasPrefix("Postamble:") { break }
        continue
      case UInt8(ascii: "{"):
        if let n = Int(l.dropFirst()), n >= 1 {
          while pages.count < n { pages.append([]) }
          page = n - 1
          pages[page] = []
          stack.removeAll()
        }
        continue
      case UInt8(ascii: "}"):
        page = -1
        continue
      case UInt8(ascii: "]"), UInt8(ascii: ")"):
        if page >= 0 { _ = stack.popLast() }
        continue
      default: break
      }
      if c == UInt8(ascii: "P") { break }
      guard page >= 0, "[(vhkg$xr".utf8.contains(c) else { continue }
      // TAG,LINE:X,Y[:W[,H,D]]
      var nums: [Int] = []
      nums.reserveCapacity(7)
      var cur = 0, neg = false, inNum = false
      for b in l.utf8.dropFirst() {
        if b >= 48 && b <= 57 { cur = cur * 10 + Int(b - 48); inNum = true }
        else if b == UInt8(ascii: "-") && !inNum { neg = true }
        else if b == UInt8(ascii: ",") || b == UInt8(ascii: ":") {
          nums.append(neg ? -cur : cur); cur = 0; neg = false; inNum = false
          if nums.count == 7 { break }
        } else { break }
      }
      if inNum && nums.count < 7 { nums.append(neg ? -cur : cur) }
      guard nums.count >= 4 else { continue }
      let node = Node(
        kind: c, tag: nums[0], line: nums[1], x: Double(nums[2]) * k, y: Double(nums[3]) * k,
        w: nums.count > 4 ? Double(nums[4]) * k : 0, h: nums.count > 5 ? Double(nums[5]) * k : 0,
        d: nums.count > 6 ? Double(nums[6]) * k : 0, parent: stack.last ?? -1)
      pages[page].append(node)
      if c == UInt8(ascii: "[") || c == UInt8(ascii: "(") { stack.append(pages[page].count - 1) }
    }
  }

  private static let leaf: Set<UInt8> = Set("gk$xh".utf8)

  /// Inverse search: the source of the point (x, y), in points from the top-left of `page` (0-based).
  public func inverse(page: Int, x: Double, y: Double) -> (file: String, line: Int)? {
    guard page >= 0, page < pages.count, !pages[page].isEmpty else { return nil }
    let nodes = pages[page]
    // the smallest hbox that contains the point (a typeset line, or something inside one)
    var best = -1, bestArea = Double.infinity
    let tol = 1.0
    for (i, n) in nodes.enumerated() where n.kind == UInt8(ascii: "(") && n.w > 0 {
      if x < n.x - tol || x > n.x + n.w + tol || y < n.y - n.h - tol || y > n.y + n.d + tol { continue }
      let area = n.w * (n.h + n.d + 0.1)
      if area < bestArea { best = i; bestArea = area }
    }
    func within(_ i: Int, _ box: Int) -> Bool {
      var p = nodes[i].parent
      while p >= 0 { if p == box { return true }; p = nodes[p].parent }
      return false
    }
    var pick: Node?
    if best >= 0 {
      var left: Node?, first: Node?
      var i = best + 1
      while i < nodes.count {
        if !within(i, best) {
          if nodes[i].parent < best { break }
          i += 1; continue
        }
        let n = nodes[i]
        i += 1
        guard Self.leaf.contains(n.kind) else { continue }
        if first == nil { first = n }
        if n.x <= x && (left == nil || n.x >= left!.x) { left = n }
      }
      pick = left ?? first ?? nodes[best]
    } else {
      var bestD = Double.infinity
      for n in nodes where Self.leaf.contains(n.kind) {
        let d = abs(n.y - y) * 4 + abs(n.x - x)
        if d < bestD { pick = n; bestD = d }
      }
    }
    guard let pick, let file = inputs[pick.tag] else { return nil }
    return (file, pick.line)
  }

  /// Forward search: where line `line` (1-based) of `file` landed. y is the top of the first box, h its height.
  public func forward(file: String, line: Int) -> (page: Int, x: Double, y: Double, h: Double)? {
    let tags = Set(inputs.filter { Self.samePath($0.value, file) }.keys)
    guard !tags.isEmpty else { return nil }
    // the exact line, else the closest line after it (blank and comment lines produce nothing), else before it
    var after = Int.max, before = -1
    for nodes in pages {
      for n in nodes where tags.contains(n.tag) {
        if n.line >= line { after = min(after, n.line) } else { before = max(before, n.line) }
      }
    }
    let target = after != .max ? after : before
    guard target >= 0 else { return nil }
    // glue and math are words and formulas; kerns and boxes alone can be page furniture (footers carry the line
    // where the page was shipped), so they only count when the line has no glue or math anywhere
    func strong(_ n: Node) -> Bool { n.kind == UInt8(ascii: "g") || n.kind == UInt8(ascii: "$") }
    let hasStrong = pages.contains { $0.contains { tags.contains($0.tag) && $0.line == target && strong($0) } }
    func use(_ n: Node) -> Bool {
      tags.contains(n.tag) && n.line == target
        && (hasStrong ? strong(n) : n.kind != UInt8(ascii: "[") && n.kind != UInt8(ascii: "v"))
    }
    for (p, nodes) in pages.enumerated() {
      var top = Double.infinity, bottom = -Double.infinity, x = Double.infinity
      for n in nodes where use(n) {
        top = min(top, n.y - max(n.h, 6))
        bottom = max(bottom, n.y + n.d)
        x = min(x, n.x)
      }
      if top < .infinity { return (p, x, top, max(bottom - top, 8)) }
    }
    return nil
  }

  /// A typeset line: an hbox on `page`, `rect` in points from the page's top-left.
  public struct Row: Equatable, Sendable {
    public var page: Int
    public var rect: CGRect
  }

  /// Where line `line` of `file` landed, one entry per typeset line (in page order), plus the row of each of its
  /// leaf records in order. A source line can hold a whole paragraph (or caption): that's many rows, and how far the
  /// cursor is through the line's words picks one of the marks, so one row.
  ///
  /// Dropped when the line has other rows: rows taller than three text lines (a figure's box, whose glue carries the
  /// caption's line), narrow ones (margin line numbers), and rows away from the line's main block (page furniture:
  /// headers and footers carry the line where the page was shipped). The main block is the run of rows less than
  /// 30 pt apart holding the most records; other runs stay if they hold at least a quarter as many and more than two
  /// (a paragraph continued on the next page).
  public func rows(file: String, line: Int) -> (rows: [Row], marks: [Int])? {
    let tags = Set(inputs.filter { Self.samePath($0.value, file) }.keys)
    guard !tags.isEmpty else { return nil }
    var after = Int.max, before = -1
    for nodes in pages {
      for n in nodes where tags.contains(n.tag) {
        if n.line >= line { after = min(after, n.line) } else { before = max(before, n.line) }
      }
    }
    let target = after != .max ? after : before
    guard target >= 0 else { return nil }
    struct Found { var row: Row; var marks: [Int] = []; var words = 0 }
    var found: [Found] = []
    var order: [Int] = []  // row of each leaf, in order
    var index: [String: Int] = [:]
    let wordy: Set<UInt8> = Set("xg$".utf8)
    for (p, nodes) in pages.enumerated() {
      for (i, n) in nodes.enumerated() where tags.contains(n.tag) && n.line == target {
        guard n.kind != UInt8(ascii: "[") && n.kind != UInt8(ascii: "v") && n.kind != UInt8(ascii: "(") else { continue }
        // the typeset line: climb from the node's hbox to enclosing hboxes of the same height (an \mbox sits inside
        // its line), not to taller ones
        var b = n.parent
        while b >= 0, nodes[b].kind == UInt8(ascii: "("), nodes[b].parent >= 0 {
          let q = nodes[nodes[b].parent]
          guard q.kind == UInt8(ascii: "("), q.h + q.d <= nodes[b].h + nodes[b].d + 3 else { break }
          b = nodes[b].parent
        }
        let r: CGRect
        if b >= 0, nodes[b].kind == UInt8(ascii: "("), nodes[b].w > 0 {
          let h = nodes[b]
          r = CGRect(x: h.x, y: h.y - max(h.h, 6), width: h.w, height: max(h.h, 6) + h.d)
        } else {
          r = CGRect(x: n.x, y: n.y - max(n.h, 6), width: max(n.w, 8), height: max(n.h, 6) + max(n.d, 2))
        }
        let key = "\(p):\(Int(r.minX * 10)):\(Int(r.minY * 10))"
        let k: Int
        if let e = index[key] { k = e } else { k = found.count; index[key] = k; found.append(Found(row: Row(page: p, rect: r))) }
        if wordy.contains(n.kind) { found[k].words += 1 }
        order.append(k)
        _ = i
      }
    }
    guard !found.isEmpty else { return nil }
    var count = [Int](repeating: 0, count: found.count)
    for k in order { count[k] += 1 }
    var keep = found.indices.filter { found[$0].row.rect.height <= 30 }
    if keep.isEmpty { keep = Array(found.indices) }
    let widest = keep.map { found[$0].row.rect.width }.max() ?? 0
    let wide = keep.filter { found[$0].row.rect.width >= widest * 0.4 }
    if !wide.isEmpty { keep = wide }
    // runs of rows less than 30 pt apart, page by page
    let sorted = keep.sorted { (found[$0].row.page, found[$0].row.rect.minY) < (found[$1].row.page, found[$1].row.rect.minY) }
    var runs: [[Int]] = []
    for k in sorted {
      if let last = runs.last?.last, found[last].row.page == found[k].row.page,
        found[k].row.rect.minY - found[last].row.rect.maxY < 30
      {
        runs[runs.count - 1].append(k)
      } else {
        runs.append([k])
      }
    }
    let weight = runs.map { $0.reduce(0) { $0 + count[$1] + found[$1].words } }
    let top = weight.max() ?? 0
    keep = zip(runs, weight).filter { $0.1 == top || ($0.1 * 4 >= top && $0.1 > 2) }.flatMap(\.0)
    keep.sort()
    var newIndex: [Int: Int] = [:]
    for (n, k) in keep.enumerated() { newIndex[k] = n }
    let marks = order.compactMap { newIndex[$0] }
    return (keep.map { found[$0].row }, marks.isEmpty ? [0] : marks)
  }

  /// The typeset line at (x, y) on `page`: the smallest hbox around the point, widened to enclosing hboxes of the
  /// same height (as `rows` does).
  public func row(page: Int, x: Double, y: Double) -> CGRect? {
    guard page >= 0, page < pages.count else { return nil }
    let nodes = pages[page]
    var best = -1, bestArea = Double.infinity
    for (i, n) in nodes.enumerated() where n.kind == UInt8(ascii: "(") && n.w > 0 {
      if x < n.x - 1 || x > n.x + n.w + 1 || y < n.y - n.h - 1 || y > n.y + n.d + 1 { continue }
      let area = n.w * (n.h + n.d + 0.1)
      if area < bestArea { best = i; bestArea = area }
    }
    guard best >= 0 else { return nil }
    var b = best
    while nodes[b].parent >= 0 {
      let q = nodes[nodes[b].parent]
      guard q.kind == UInt8(ascii: "("), q.h + q.d <= nodes[b].h + nodes[b].d + 3 else { break }
      b = nodes[b].parent
    }
    let h = nodes[b]
    guard h.h + h.d <= 30 else { return nil }
    return CGRect(x: h.x, y: h.y - max(h.h, 6), width: h.w, height: max(h.h, 6) + h.d)
  }

  /// Paths in SyncTeX data can be absolute, or relative with `./`. Compare by normalised suffix.
  public static func samePath(_ a: String, _ b: String) -> Bool {
    func norm(_ s: String) -> String {
      var s = s
      if s.hasPrefix("./") { s.removeFirst(2) }
      s = s.replacingOccurrences(of: "/./", with: "/")
      if s.hasPrefix("/private/") { s.removeFirst("/private".count) }
      return s
    }
    let x = norm(a), y = norm(b)
    return x == y || x.hasSuffix("/" + y) || y.hasSuffix("/" + x)
  }
}
