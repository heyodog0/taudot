// Byte-offset text operations for the native editor, the Swift twin of clients/nvim/lua/taudot/ot.lua.
//
// An op is a list of retains, deletes and inserts with lengths in UTF-8 bytes: ot.js's TextOperation (MIT, Tim
// Baumann), written from crates/ot2's history::TextOperation, which is the same op counted in UTF-16 units.
// crates/ot2/tests/byte_fixtures.rs computes expected results with ot2; TaudotEditorTests checks them.

import Foundation

/// The engine's edit: delete `del` bytes at byte offset `pos`, then insert `ins` there.
public struct Edit: Equatable, Sendable {
  public var pos: Int
  public var del: Int
  public var ins: String

  public init(pos: Int, del: Int, ins: String) {
    self.pos = pos
    self.del = del
    self.ins = ins
  }
}

public struct Op: Equatable, Sendable {
  public enum Comp: Equatable, Sendable {
    case retain(Int), delete(Int), insert([UInt8])

    var count: Int {
      switch self {
      case let .retain(n), let .delete(n): return n
      case let .insert(s): return s.count
      }
    }

    var isDelete: Bool { if case .delete = self { return true } else { return false } }
    var isInsert: Bool { if case .insert = self { return true } else { return false } }

    /// The first `n` bytes, and what is left.
    func split(_ n: Int) -> (Comp, Comp?) {
      if n >= count { return (self, nil) }
      switch self {
      case let .retain(k): return (.retain(n), .retain(k - n))
      case let .delete(k): return (.delete(n), .delete(k - n))
      case let .insert(s): return (.insert(Array(s[..<n])), .insert(Array(s[n...])))
      }
    }
  }

  public var comps: [Comp] = []
  /// Length of the text the op applies to.
  public var base = 0
  /// Length of the text it makes.
  public var target = 0

  /// An edit that doesn't fit the text.
  public struct OutOfRange: Error {}
  /// Two ops that don't start from (or meet at) the same length.
  public struct LengthMismatch: Error {}

  public init() {}

  /// An op from components, normalized.
  init(comps: [Comp]) {
    for c in comps { push(c) }
  }

  public static func identity(_ len: Int) -> Op {
    var o = Op()
    o.retain(len)
    return o
  }

  // The builders keep an op in one form: neighbours of a kind merged, nothing empty, and an insert next to a delete
  // before it.
  mutating func retain(_ n: Int) {
    if n == 0 { return }
    base += n
    target += n
    if case let .retain(k)? = comps.last { comps[comps.count - 1] = .retain(k + n) } else { comps.append(.retain(n)) }
  }

  mutating func insert(_ s: [UInt8]) {
    if s.isEmpty { return }
    target += s.count
    let n = comps.count
    switch comps.last {
    case let .insert(t)?:
      comps[n - 1] = .insert(t + s)
    case .delete?:
      if n >= 2, case let .insert(t) = comps[n - 2] {
        comps[n - 2] = .insert(t + s)
      } else {
        comps.insert(.insert(s), at: n - 1)
      }
    default:
      comps.append(.insert(s))
    }
  }

  mutating func delete(_ n: Int) {
    if n == 0 { return }
    base += n
    if case let .delete(k)? = comps.last { comps[comps.count - 1] = .delete(k + n) } else { comps.append(.delete(n)) }
  }

  mutating func push(_ c: Comp) {
    switch c {
    case let .retain(n): retain(n)
    case let .delete(n): delete(n)
    case let .insert(s): insert(s)
    }
  }

  /// The op for one edit on a text `len` bytes long.
  public static func from(_ e: Edit, len: Int) throws -> Op {
    guard e.pos >= 0, e.del >= 0, e.pos + e.del <= len else { throw OutOfRange() }
    var o = Op()
    o.retain(e.pos)
    o.insert(Array(e.ins.utf8))
    o.delete(e.del)
    o.retain(len - e.pos - e.del)
    return o
  }

  /// The op for edits applied in order to a text `len` bytes long.
  public static func from(_ edits: [Edit], len: Int) throws -> Op {
    var o = identity(len)
    for e in edits { o = try compose(o, from(e, len: o.target)) }
    return o
  }

  /// The edits the op makes, applied in order: one per insert and one per delete.
  public var edits: [Edit] {
    var out: [Edit] = []
    var pos = 0
    for c in comps {
      switch c {
      case let .insert(s):
        out.append(Edit(pos: pos, del: 0, ins: String(decoding: s, as: UTF8.self)))
        pos += s.count
      case let .delete(n):
        out.append(Edit(pos: pos, del: n, ins: ""))
      case let .retain(n):
        pos += n
      }
    }
    return out
  }

  public var isNoop: Bool { comps.allSatisfy { if case .retain = $0 { return true } else { return false } } }

  /// Walks a component list, handing out parts of the current component.
  private struct Cursor {
    let comps: [Comp]
    var i = 0
    var head: Comp?

    init(_ comps: [Comp]) {
      self.comps = comps
      head = comps.first
    }

    mutating func whole() -> Comp {
      let h = head!
      i += 1
      head = i < comps.count ? comps[i] : nil
      return h
    }

    mutating func take(_ n: Int) -> Comp {
      let (a, rest) = head!.split(n)
      if let rest {
        head = rest
      } else {
        i += 1
        head = i < comps.count ? comps[i] : nil
      }
      return a
    }
  }

  /// The op that applies `a`, then `b`.
  public static func compose(_ a: Op, _ b: Op) throws -> Op {
    guard a.target == b.base else { throw LengthMismatch() }
    var out = Op()
    var x = Cursor(a.comps), y = Cursor(b.comps)
    while x.head != nil || y.head != nil {
      if x.head?.isDelete == true {
        out.push(x.whole())
      } else if y.head?.isInsert == true {
        out.push(y.whole())
      } else {
        let n = min(x.head!.count, y.head!.count)
        let p = x.take(n), q = y.take(n)
        switch (p, q) {
        case (.insert, .delete): break
        case (_, .delete): out.delete(n)
        case let (.insert(s), _): out.insert(s)
        default: out.retain(n)
        }
      }
    }
    return out
  }

  /// (a', b') with compose(a, b') == compose(b, a'). On equal insert positions `a` goes first.
  public static func transform(_ a: Op, _ b: Op) throws -> (Op, Op) {
    guard a.base == b.base else { throw LengthMismatch() }
    var a2 = Op(), b2 = Op()
    var x = Cursor(a.comps), y = Cursor(b.comps)
    while x.head != nil || y.head != nil {
      if case let .insert(s)? = x.head {
        _ = x.whole()
        a2.insert(s)
        b2.retain(s.count)
      } else if case let .insert(s)? = y.head {
        _ = y.whole()
        a2.retain(s.count)
        b2.insert(s)
      } else {
        let n = min(x.head!.count, y.head!.count)
        let p = x.take(n), q = y.take(n)
        switch (p.isDelete, q.isDelete) {
        case (true, false): a2.delete(n)
        case (false, true): b2.delete(n)
        case (false, false): a2.retain(n); b2.retain(n)
        case (true, true): break
        }
      }
    }
    return (a2, b2)
  }

  /// Move a byte position through the op. `stickLeft` stays before text inserted at the position. A position inside
  /// deleted text moves to where the delete was.
  public func map(_ p: Int, stickLeft: Bool = false) -> Int {
    var src = 0, dst = 0
    for c in comps {
      switch c {
      case let .insert(s):
        if src > p || (src == p && stickLeft) { return dst + (p - src) }
        dst += s.count
      case let .delete(n):
        if p < src + n { return dst }
        src += n
      case let .retain(n):
        if p < src + n { return dst + (p - src) }
        src += n
        dst += n
      }
    }
    return dst + (p - src)
  }
}

extension Array where Element == UInt8 {
  /// Apply edits in order.
  public func applying(_ edits: [Edit]) -> [UInt8] {
    var s = self
    for e in edits { s.replaceSubrange(e.pos..<(e.pos + e.del), with: Array(e.ins.utf8)) }
    return s
  }
}

// MARK: diff

extension Op {
  /// The op turning `a` into `b`, as fine as a line diff refined to characters (ot.lua's `diff`): changes far apart
  /// stay apart, so an op transformed past this one keeps its own edits between them. Used to rebase unconfirmed edits
  /// on text that changed meanwhile. Cuts only between whole UTF-8 characters.
  public static func diff(_ a: [UInt8], _ b: [UInt8]) -> Op {
    if a == b { return identity(a.count) }
    func lines(_ s: [UInt8]) -> [Range<Int>] {
      var out: [Range<Int>] = []
      var start = 0
      for i in s.indices where s[i] == 10 { out.append(start..<(i + 1)); start = i + 1 }
      if start < s.count { out.append(start..<s.count) }
      return out
    }
    let la = lines(a), lb = lines(b)
    let diff = lb.map { b[$0] }.difference(from: la.map { a[$0] })
    var removed = Set<Int>(), inserted = Set<Int>()
    for c in diff {
      switch c {
      case let .remove(offset, _, _): removed.insert(offset)
      case let .insert(offset, _, _): inserted.insert(offset)
      }
    }
    var o = Op()
    var i = 0, j = 0
    func at(_ ls: [Range<Int>], _ k: Int, _ total: Int) -> Int { k < ls.count ? ls[k].lowerBound : total }
    while i < la.count || j < lb.count {
      if i < la.count, j < lb.count, !removed.contains(i), !inserted.contains(j) {
        o.retain(la[i].count)
        i += 1
        j += 1
        continue
      }
      // a hunk: the removed lines of a here, the inserted lines of b here
      let i0 = i, j0 = j
      while i < la.count && removed.contains(i) { i += 1 }
      while j < lb.count && inserted.contains(j) { j += 1 }
      if i == i0 && j == j0 { break }  // (can't happen: lines left on one side only are removed or inserted)
      for c in refine(Array(a[at(la, i0, a.count)..<at(la, i, a.count)]), Array(b[at(lb, j0, b.count)..<at(lb, j, b.count)])) {
        o.push(c)
      }
    }
    if o.base == a.count, o.target == b.count, o.apply(a) == b { return o }
    var whole = Op()
    for c in refine(a, b) { whole.push(c) }
    return whole
  }

  /// Common prefix and suffix kept (whole characters), the middle replaced.
  static func refine(_ a: [UInt8], _ b: [UInt8]) -> [Comp] {
    func cont(_ s: [UInt8], _ i: Int) -> Bool { i < s.count && s[i] >= 0x80 && s[i] < 0xC0 }
    let n = min(a.count, b.count)
    var p = 0
    while p < n && a[p] == b[p] { p += 1 }
    while p > 0 && (cont(a, p) || cont(b, p)) { p -= 1 }
    var s = 0
    while s < n - p && a[a.count - 1 - s] == b[b.count - 1 - s] { s += 1 }
    while s > 0 && cont(a, a.count - s) { s -= 1 }
    return [.retain(p), .insert(Array(b[p..<(b.count - s)])), .delete(a.count - s - p), .retain(s)]
  }

  /// The text this op makes from `s`.
  public func apply(_ s: [UInt8]) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(target)
    var i = 0
    for c in comps {
      switch c {
      case let .retain(n): out += s[i..<(i + n)]; i += n
      case let .delete(n): i += n
      case let .insert(t): out += t
      }
    }
    return out
  }
}
