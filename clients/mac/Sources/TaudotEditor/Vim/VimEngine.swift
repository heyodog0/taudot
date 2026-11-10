// Vim keys for the native editor (Settings ▸ Editor ▸ Vim keys): a focused Vim, like Xcode's or Zed's, not Neovim.
// Modes normal, insert, visual (char, line) and replace; motions, operators with motions and text objects (incl. LaTeX
// ones: i$ a$ for math, ie ae for environments, % on \begin/\end), counts, registers ("a–"z, "+ for the clipboard),
// marks, `.` repeat, / ? n N * #, and a few `:` commands. Every edit goes through VimBuffer.replace, the editor's own
// edit path, so it syncs and undoes like typing; one command is one undo step.
import Foundation

@MainActor public final class VimEngine {
  public enum Mode: String, Sendable { case normal = "NORMAL", insert = "INSERT", visual = "VISUAL", visualLine = "V-LINE", replace = "REPLACE" }

  public private(set) var mode: Mode = .normal { didSet { if mode != oldValue { showMode(); onMode?(mode) } } }
  public var onMode: ((Mode) -> Void)?

  /// The caret's shape, as Neovim draws it by default: a block in normal and visual mode, half a block while an
  /// operator waits for its motion, a bar in insert mode, an underline in replace mode and after `r`.
  public enum CursorShape: Sendable { case block, halfBlock, bar, underline }
  public var cursorShape: CursorShape {
    switch mode {
    case .insert: return .bar
    case .replace: return .underline
    default:
      if prefix == "r" || prefix == "vr" { return .underline }
      if op != nil { return .halfBlock }
      return .block
    }
  }
  public var onCursorShape: ((CursorShape) -> Void)?
  private var lastShape: CursorShape = .block
  let buf: VimBuffer
  public var shiftWidth = 2

  // pending state of the command being typed
  private var count: Int?
  private var opCount: Int?
  private var register: Character?
  private var op: String?
  private var prefix = ""
  private var opPrefix = ""  // "g" seen after an operator (dgg, dgj)

  private var registers: [Character: (text: String, linewise: Bool)] = [:]
  private var marks: [Character: Int] = [:]
  private var lastFind: (kind: Character, char: String)?
  private var search: (pattern: String, forward: Bool)?
  public private(set) var cmdline: String?
  private var cmdKind: Character = ":"
  private var desiredCol: Int?
  private var anchor = 0
  private var head = 0
  private var lastVisual: (anchor: Int, head: Int, line: Bool)?

  // `.` and undo grouping
  private var cmdKeys: [VimKey] = []
  private var lastChange: [VimKey] = []
  private var lastInsert = ""
  private var changed = false
  private var inChange = false
  private var insertStart = 0
  private var insertIsChange = false
  private var replaying = false

  public init(buffer: VimBuffer) {
    buf = buffer
  }

  /// Normal-mode commands of the app's (]r [r to cycle through comments, ga gx gC): key sequence → run with the
  /// count. A sequence that turns out not to be one goes to Vim as typed (]] still moves by section).
  public var commands: [String: (Int) -> Void] = [:]
  /// `/` or `?` in normal mode: return true when the app's find bar takes the search (FindController); the bar then
  /// hands its pattern back with setSearch, so n and N continue it.
  public var onSearchKey: ((Character) -> Bool)?
  private var custom: [VimKey] = []

  var s: NSString { buf.text }
  /// The caret; in visual mode the moving end of the selection.
  var cursor: Int {
    get { mode == .visual || mode == .visualLine ? head : buf.selection.location }
    set { buf.selection = NSRange(location: max(0, min(newValue, s.length)), length: 0) }
  }

  // MARK: keys

  /// Handle a key. False: not consumed (insert mode lets the text view type it).
  @discardableResult
  public func handle(_ k: VimKey) -> Bool {
    defer {
      let shape = cursorShape
      if shape != lastShape { lastShape = shape; onCursorShape?(shape) }
    }
    if cmdline != nil { cmdlineKey(k); return true }
    switch mode {
    case .insert:
      if k.name == "<Esc>" || k.name == "<C-[>" || k.name == "<C-c>" { leaveInsert(); return true }
      return false
    case .replace:
      replaceModeKey(k)
      return true
    default:
      if mode == .normal && op == nil && register == nil && !commands.isEmpty && !(custom.isEmpty && Int(k.name) != nil) {
        let seq = (custom + [k]).map(\.name).joined()
        if let f = commands[seq] {
          custom = []
          let n = count ?? 1
          reset()
          cmdKeys = []
          f(n)
          return true
        }
        if commands.keys.contains(where: { $0.hasPrefix(seq) }) {
          custom.append(k)
          return true
        }
        if !custom.isEmpty {
          let pending = custom
          custom = []
          for p in pending { cmdKeys.append(p); normalKey(p) }
        }
      }
      cmdKeys.append(k)
      normalKey(k)
      if count == nil && op == nil && prefix.isEmpty && register == nil && cmdline == nil {
        commandDone()
      }
      return true
    }
  }

  /// Feed keys in Vim notation (tests, `.`).
  public func feed(_ keys: String) {
    for k in VimKey.parse(keys) where !handle(k) {
      // Insert mode: type it.
      let ins = k.name == "<CR>" ? "\n" : (k.name == "<Tab>" ? "\t" : k.name)
      if k.name == "<BS>" {
        if cursor > 0 { let r = s.rangeOfComposedCharacterSequence(at: cursor - 1); buf.replace(r, with: ""); cursor = r.location }
      } else if !ins.hasPrefix("<") || ins.count == 1 {
        let at = cursor
        buf.replace(NSRange(location: at, length: 0), with: ins)
        cursor = at + (ins as NSString).length
      }
    }
  }

  private func commandDone() {
    if changed {
      lastChange = cmdKeys
      insertIsChange = mode == .insert
    }
    cmdKeys = []
    changed = false
    if inChange && mode != .insert { buf.endChange(); inChange = false }
    if mode == .normal { clampNormal() }
  }

  // MARK: the text changing under the engine (A9)

  /// The text was replaced (another file shown): offsets into the old text (visual ends, marks, `gv`, an insert's
  /// start) and a command half typed mean nothing in this one. Back to normal mode with none of them.
  public func textReplaced() {
    reset()
    custom = []
    cmdKeys = []
    changed = false
    if inChange { buf.endChange(); inChange = false }
    marks = [:]
    lastVisual = nil
    anchor = 0; head = 0; insertStart = 0
    desiredCol = nil
    cmdline = nil
    mode = .normal
  }

  /// An edit not made through the engine (a collaborator's, from the engine): `deleted` UTF-16 units at `loc`
  /// replaced by `inserted`. Offsets after it move with the text; ones inside it go to its start.
  public func textEdited(at loc: Int, deleted: Int, inserted: Int) {
    func move(_ p: Int) -> Int { p < loc ? p : p >= loc + deleted ? p - deleted + inserted : loc }
    marks = marks.mapValues(move)
    anchor = move(anchor); head = move(head)
    lastVisual = lastVisual.map { (move($0.anchor), move($0.head), $0.line) }
    insertStart = move(insertStart)
  }

  private func reset() {
    count = nil; opCount = nil; register = nil; op = nil; prefix = ""; opPrefix = ""
  }

  private func edit(_ r: NSRange, _ str: String) {
    if !inChange { buf.beginChange(); inChange = true }
    buf.replace(r, with: str)
    changed = true
  }

  private func showMode() {
    switch mode {
    case .normal: buf.status("")
    default: buf.status("-- \(mode.rawValue) --")
    }
  }

  // MARK: text helpers

  func lineStart(_ p: Int) -> Int { s.lineRange(for: NSRange(location: min(p, s.length), length: 0)).location }
  func lineEnd(_ p: Int) -> Int {
    var e = 0, c = 0
    s.getLineStart(nil, end: &e, contentsEnd: &c, for: NSRange(location: min(p, s.length), length: 0))
    return c
  }
  /// Start of the line after the one holding `p` (or the end).
  func nextLineStart(_ p: Int) -> Int { NSMaxRange(s.lineRange(for: NSRange(location: min(p, s.length), length: 0))) }
  func lineIndex(_ p: Int) -> Int {
    var n = 0, i = 0
    let end = min(p, s.length)
    while i < end {
      let r = s.range(of: "\n", options: .literal, range: NSRange(location: i, length: end - i))
      if r.location == NSNotFound { break }
      n += 1
      i = r.location + 1
    }
    return n
  }
  func lineCount() -> Int { lineIndex(s.length) + 1 }
  func startOfLine(_ n: Int) -> Int {
    var i = 0, k = 0
    while k < n {
      let r = s.range(of: "\n", options: .literal, range: NSRange(location: i, length: s.length - i))
      if r.location == NSNotFound { return i }
      i = r.location + 1
      k += 1
    }
    return i
  }
  func firstNonBlank(_ p: Int) -> Int {
    var i = lineStart(p)
    let e = lineEnd(p)
    while i < e, isBlank(s.character(at: i)) { i += 1 }
    return i
  }
  func isBlank(_ c: unichar) -> Bool { c == 32 || c == 9 }
  func isSpace(_ c: unichar) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 }
  func next(_ p: Int) -> Int { p >= s.length ? s.length : NSMaxRange(s.rangeOfComposedCharacterSequence(at: p)) }
  func prev(_ p: Int) -> Int { p <= 0 ? 0 : s.rangeOfComposedCharacterSequence(at: p - 1).location }
  func charLen(_ p: Int) -> Int { p >= s.length ? 0 : s.rangeOfComposedCharacterSequence(at: p).length }
  func ch(_ p: Int) -> unichar { p >= 0 && p < s.length ? s.character(at: p) : 0 }

  /// In normal mode the caret sits on a character, not after the last one.
  func clampNormal() {
    let p = cursor, e = lineEnd(p), st = lineStart(p)
    if p >= e && e > st { cursor = prev(e) }
  }

  /// 0: blank, 1: word character, 2: other. `big`: everything not blank is 1.
  func cls(_ p: Int, big: Bool) -> Int {
    let c = ch(p)
    if isSpace(c) || p >= s.length { return 0 }
    if big { return 1 }
    if let u = Unicode.Scalar(c), CharacterSet.alphanumerics.contains(u) || c == 95 { return 1 }
    if c >= 0xD800 { return 1 }
    return 2
  }

  // MARK: word motions

  func wordForward(_ p0: Int, big: Bool, forChange: Bool = false) -> Int {
    var p = p0
    let n = s.length
    if p >= n { return n }
    let c = cls(p, big: big)
    if c != 0 { while p < n && cls(p, big: big) == c { p = next(p) } }
    if forChange && c != 0 { return p }
    // Whitespace, but an empty line counts as a word.
    while p < n && cls(p, big: big) == 0 {
      p = next(p)
      if p < n && ch(p) == 10 && ch(p - 1) == 10 { return p }
    }
    return p
  }

  func wordEnd(_ p0: Int, big: Bool) -> Int {
    let n = s.length
    var p = next(p0)
    while p < n && cls(p, big: big) == 0 { p = next(p) }
    if p >= n { return max(0, prev(n)) }
    let c = cls(p, big: big)
    while next(p) < n && cls(next(p), big: big) == c { p = next(p) }
    return p
  }

  func wordBack(_ p0: Int, big: Bool) -> Int {
    var p = prev(p0)
    while p > 0 && cls(p, big: big) == 0 {
      if ch(p) == 10 && ch(p - 1) == 10 { return p }
      p = prev(p)
    }
    let c = cls(p, big: big)
    while p > 0 && cls(prev(p), big: big) == c && c != 0 { p = prev(p) }
    return p
  }

  // MARK: motions

  struct Motion {
    var to: Int
    var linewise = false
    var inclusive = false
    var jump = false
  }

  /// A motion key (not needing another key). Nil if `k` isn't one.
  func motion(_ k: String, _ n: Int?) -> Motion? {
    let c = n ?? 1
    let p = cursor
    switch k {
    case "h", "<Left>", "<BS>":
      var q = p
      for _ in 0..<c where q > lineStart(p) { q = prev(q) }
      return Motion(to: q)
    case "l", "<Right>", " ":
      var q = p
      let e = lineEnd(p)
      for _ in 0..<c where q < e { q = next(q) }
      if op == nil && mode == .normal && q >= e && e > lineStart(p) { q = prev(e) }
      return Motion(to: q)
    case "j", "<Down>", "k", "<Up>", "<C-n>", "<C-p>", "+", "-", "<CR>":
      let down = ["j", "<Down>", "<C-n>", "+", "<CR>"].contains(k)
      let line = lineIndex(p) + (down ? c : -c)
      guard line >= 0 && line < lineCount() else { return Motion(to: p, linewise: true) }
      let st = startOfLine(line)
      if k == "+" || k == "-" || k == "<CR>" { return Motion(to: firstNonBlank(st), linewise: true) }
      let col = desiredCol ?? (p - lineStart(p))
      desiredCol = col
      return Motion(to: min(st + col, lineEnd(st)), linewise: true)
    case "0", "<Home>": return Motion(to: lineStart(p))
    case "^": return Motion(to: firstNonBlank(p))
    case "$", "<End>":
      var q = p
      for _ in 1..<c { q = nextLineStart(q) }
      desiredCol = Int.max
      let e = lineEnd(q)
      return Motion(to: (op == nil && mode == .normal && e > lineStart(q)) ? prev(e) : (op == nil ? e : max(lineStart(q), prev(e))), inclusive: op != nil)
    case "w", "W":
      var q = p
      for i in 0..<c { q = wordForward(q, big: k == "W", forChange: op == "c" && i == c - 1 && cls(q, big: k == "W") != 0) }
      // dw on a line's last word stops at the end of the line.
      if op != nil && lineIndex(q) > lineIndex(p) { q = max(p, lineEnd(prev(lineStart(q)))) }
      return Motion(to: q)
    case "e", "E":
      var q = p
      for _ in 0..<c { q = wordEnd(q, big: k == "E") }
      return Motion(to: q, inclusive: true)
    case "b", "B":
      var q = p
      for _ in 0..<c { q = wordBack(q, big: k == "B") }
      return Motion(to: q)
    case "G":
      let line = n.map { $0 - 1 } ?? (lineCount() - 1)
      return Motion(to: firstNonBlank(startOfLine(max(0, min(line, lineCount() - 1)))), linewise: true, jump: true)
    case "{", "}":
      var q = p
      for _ in 0..<c { q = paragraph(q, forward: k == "}") }
      return Motion(to: q, jump: true)
    case "%":
      guard let q = matchPair(p) else { return nil }
      return Motion(to: q, inclusive: true, jump: true)
    case "H", "M", "L":
      let sl = buf.screenLines
      let line: Int
      switch k {
      case "H": line = min(sl.upperBound, sl.lowerBound + c - 1)
      case "L": line = max(sl.lowerBound, sl.upperBound - c + 1)
      default: line = (sl.lowerBound + sl.upperBound) / 2
      }
      return Motion(to: firstNonBlank(startOfLine(min(line, lineCount() - 1))), linewise: true, jump: true)
    case ";", ",":
      guard let f = lastFind else { return nil }
      var kind = f.kind
      if k == "," { kind = ["f": "F", "F": "f", "t": "T", "T": "t"][kind] ?? kind }
      return find(kind, f.char, c, repeating: true)
    case "n", "N":
      guard let sr = search else { return nil }
      let fwd = k == "n" ? sr.forward : !sr.forward
      var q = p
      for _ in 0..<c { if let r = searchFrom(q, sr.pattern, forward: fwd) { q = r } }
      return Motion(to: q, jump: true)
    default:
      return nil
    }
  }

  func paragraph(_ p: Int, forward: Bool) -> Int {
    var line = lineIndex(p)
    let n = lineCount()
    func blank(_ l: Int) -> Bool {
      let st = startOfLine(l)
      return s.substring(with: NSRange(location: st, length: lineEnd(st) - st)).trimmingCharacters(in: .whitespaces).isEmpty
    }
    if forward {
      while line < n - 1 && blank(line) { line += 1 }
      while line < n - 1 && !blank(line) { line += 1 }
      return line == n - 1 && !blank(line) ? lineEnd(startOfLine(line)) : startOfLine(line)
    }
    while line > 0 && blank(line) { line -= 1 }
    while line > 0 && !blank(line) { line -= 1 }
    return startOfLine(line)
  }

  func find(_ kind: Character, _ c: String, _ n: Int, repeating: Bool = false) -> Motion? {
    let p = cursor
    let st = lineStart(p), e = lineEnd(p)
    var q = p
    let target = (c as NSString).character(at: 0)
    for i in 0..<n {
      switch kind {
      case "f", "t":
        var r = next(q)
        // `;` after t: skip the character right before the target.
        if kind == "t" && (repeating || i > 0) && ch(r) == target { r = next(r) }
        while r < e && ch(r) != target { r = next(r) }
        guard r < e else { return nil }
        q = r
      default:
        var r = prev(q)
        if kind == "T" && (repeating || i > 0) && r > st && ch(r) == target { r = prev(r) }
        while r > st && ch(r) != target { r = prev(r) }
        guard r >= st && ch(r) == target && r < q else { return nil }
        q = r
      }
    }
    if kind == "t" { q = prev(q) }
    if kind == "T" { q = next(q) }
    return Motion(to: q, inclusive: kind == "f" || kind == "t")
  }

  /// `%`: the matching bracket, or `\begin`↔`\end`.
  func matchPair(_ p: Int) -> Int? {
    // \begin{x} / \end{x} under the cursor
    let st = lineStart(p), e = lineEnd(p)
    let line = s.substring(with: NSRange(location: st, length: e - st)) as NSString
    var search = NSRange(location: 0, length: line.length)
    while true {
      let r = line.range(of: #"\\(begin|end)\{([^{}]*)\}"#, options: .regularExpression, range: search)
      if r.location == NSNotFound { break }
      if p - st >= r.location && p - st < NSMaxRange(r) {
        let tok = line.substring(with: r)
        let isBegin = tok.hasPrefix("\\begin")
        let env = String(tok.dropFirst(isBegin ? 7 : 5).dropLast())
        if isBegin {
          if let end = Comforts.matchingEnd(s, from: st + NSMaxRange(r), env: env) { return end.location - 5 }
        } else if let b = matchingBegin(before: st + r.location, env: env) {
          return b
        }
        return nil
      }
      search = NSRange(location: NSMaxRange(r), length: line.length - NSMaxRange(r))
    }
    let pairs: [unichar: (unichar, Bool)] = [40: (41, true), 91: (93, true), 123: (125, true), 41: (40, false), 93: (91, false), 125: (123, false)]
    var q = p
    while q < e && pairs[ch(q)] == nil { q += 1 }
    guard q < e, let (other, fwd) = pairs[ch(q)] else { return nil }
    let me = ch(q)
    var depth = 0
    var i = q
    while fwd ? i < s.length : i >= 0 {
      let c = ch(i)
      if c == me { depth += 1 } else if c == other { depth -= 1; if depth == 0 { return i } }
      i += fwd ? 1 : -1
    }
    return nil
  }

  func matchingBegin(before loc: Int, env: String) -> Int? {
    let b = "\\begin{\(env)}", e = "\\end{\(env)}"
    var depth = 1
    var end = loc
    while end > 0 {
      let r = NSRange(location: 0, length: end)
      let fb = s.range(of: b, options: .backwards, range: r), fe = s.range(of: e, options: .backwards, range: r)
      if fb.location == NSNotFound { return nil }
      if fe.location != NSNotFound && fe.location > fb.location { depth += 1; end = fe.location; continue }
      depth -= 1
      if depth == 0 { return fb.location }
      end = fb.location
    }
    return nil
  }

  // MARK: text objects

  /// `i`/`a` + object char: the range, and whether it is linewise.
  func textObject(_ inner: Bool, _ o: String, _ n: Int) -> (NSRange, Bool)? {
    let p = cursor
    switch o {
    case "w", "W":
      let big = o == "W"
      var a = p, b = p
      let c = cls(p, big: big)
      while a > lineStart(p) && cls(prev(a), big: big) == c { a = prev(a) }
      while b < lineEnd(p) && cls(b, big: big) == c { b = next(b) }
      for _ in 1..<max(1, n) { b = wordForward(b, big: big, forChange: true) }
      if !inner {
        let b0 = b
        while b < lineEnd(p) && isBlank(ch(b)) { b = next(b) }
        if b == b0 { while a > lineStart(p) && isBlank(ch(prev(a))) { a = prev(a) } }
      }
      return (NSRange(location: a, length: b - a), false)
    case "s":
      let st = paragraph(next(p), forward: false)
      var a = p
      while a > st {
        let c = ch(prev(a))
        if (c == 46 || c == 33 || c == 63) && isSpace(ch(a)) { break }
        if c == 10 && ch(a) == 10 { break }
        a = prev(a)
      }
      while a < s.length && isSpace(ch(a)) { a = next(a) }
      var b = p
      while b < s.length {
        let c = ch(b)
        if c == 46 || c == 33 || c == 63 { b = next(b); break }
        if c == 10 && ch(next(b)) == 10 { break }
        b = next(b)
      }
      if !inner { while b < s.length && isBlank(ch(b)) { b = next(b) } }
      return (NSRange(location: a, length: b - a), false)
    case "p":
      var first = lineIndex(p), last = first
      func blank(_ l: Int) -> Bool {
        let st = startOfLine(l)
        return s.substring(with: NSRange(location: st, length: lineEnd(st) - st)).trimmingCharacters(in: .whitespaces).isEmpty
      }
      let kind = blank(first)
      while first > 0 && blank(first - 1) == kind { first -= 1 }
      while last < lineCount() - 1 && blank(last + 1) == kind { last += 1 }
      if !inner { while last < lineCount() - 1 && blank(last + 1) { last += 1 } }
      let a = startOfLine(first), b = nextLineStart(startOfLine(last))
      return (NSRange(location: a, length: b - a), true)
    case "(", ")", "b", "{", "}", "B", "[", "]":
      let open: unichar = ["(": 40, ")": 40, "b": 40, "{": 123, "}": 123, "B": 123, "[": 91, "]": 91][o]!
      let close: unichar = open == 40 ? 41 : (open == 123 ? 125 : 93)
      var depth = 0, a = p
      if ch(p) == open { a = p } else {
        a = p - 1
        while a >= 0 {
          let c = ch(a)
          if c == close { depth += 1 } else if c == open { if depth == 0 { break }; depth -= 1 }
          a -= 1
        }
      }
      guard a >= 0 else { return nil }
      depth = 0
      var b = a + 1
      while b < s.length {
        let c = ch(b)
        if c == open { depth += 1 } else if c == close { if depth == 0 { break }; depth -= 1 }
        b += 1
      }
      guard b < s.length else { return nil }
      return inner ? (NSRange(location: a + 1, length: b - a - 1), false) : (NSRange(location: a, length: b - a + 1), false)
    case "\"", "'", "`":
      let q = (o as NSString).character(at: 0)
      let st = lineStart(p), e = lineEnd(p)
      var a = p
      while a >= st && ch(a) != q { a -= 1 }
      if a < st { return nil }
      var b = (a == p) ? p + 1 : p
      while b < e && ch(b) != q { b += 1 }
      if b >= e {
        // The cursor was on the closing quote.
        b = a; a -= 1
        while a >= st && ch(a) != q { a -= 1 }
        if a < st { return nil }
      }
      return inner ? (NSRange(location: a + 1, length: b - a - 1), false) : (NSRange(location: a, length: b - a + 1), false)
    case "$":
      // Inline math: the `$`s around the cursor in its paragraph.
      let pr = textObject(false, "p", 1)?.0 ?? NSRange(location: lineStart(p), length: lineEnd(p) - lineStart(p))
      var dollars: [Int] = []
      var i = pr.location
      while i < NSMaxRange(pr) {
        if ch(i) == 92 { i += 2; continue }
        if ch(i) == 36 { dollars.append(i); if ch(i + 1) == 36 { i += 1 } }
        i += 1
      }
      var k = 0
      while k + 1 < dollars.count {
        let a = dollars[k], b = dollars[k + 1]
        if p >= a && p <= b {
          let wide = ch(a + 1) == 36 ? 2 : 1
          return inner ? (NSRange(location: a + wide, length: b - a - wide), false) : (NSRange(location: a, length: b - a + wide), false)
        }
        k += 2
      }
      return nil
    case "e":
      // The innermost \begin{x}…\end{x} around the cursor.
      var search = NSRange(location: 0, length: min(s.length, nextLineStart(p)))
      let beginRe = try! NSRegularExpression(pattern: #"\\begin\{([^{}]*)\}"#)
      while true {
        // The last \begin before the cursor's line ends (NSString can't search a regex backwards).
        guard let r = beginRe.matches(in: s as String, range: search).last?.range else { return nil }
        let env = s.substring(with: NSRange(location: r.location + 7, length: r.length - 8))
        if let end = Comforts.matchingEnd(s, from: NSMaxRange(r), env: env) {
          let endTok = NSRange(location: end.location - 5, length: end.length + 6)
          if NSMaxRange(endTok) > p {
            if !inner { return (NSRange(location: r.location, length: NSMaxRange(endTok) - r.location), false) }
            // Inside: from the line after \begin's to the \end line, linewise when both stand on their own lines.
            let afterBegin = lineEnd(r.location) == NSMaxRange(r) || s.substring(with: NSRange(location: NSMaxRange(r), length: lineEnd(r.location) - NSMaxRange(r))).hasPrefix("[")
            if afterBegin && firstNonBlank(endTok.location) == endTok.location {
              let a = nextLineStart(r.location), b = lineStart(endTok.location)
              return (NSRange(location: a, length: max(0, b - a)), true)
            }
            return (NSRange(location: NSMaxRange(r), length: endTok.location - NSMaxRange(r)), false)
          }
        }
        search = NSRange(location: 0, length: r.location)
      }
    default:
      return nil
    }
  }

  // MARK: normal mode

  private func normalKey(_ key: VimKey) {
    let k = key.name
    let visual = mode == .visual || mode == .visualLine
    // A key completing a prefix.
    if !prefix.isEmpty { prefixKey(k); return }
    if k == "<Esc>" || k == "<C-c>" {
      if visual { exitVisual() }
      reset()
      return
    }
    if let d = Int(k), k.count == 1, d > 0 || count != nil {
      count = (count ?? 0) * 10 + d
      return
    }
    if k == "\"" { prefix = "\""; return }
    let n = count
    let total: Int? = (n != nil || opCount != nil) ? (n ?? 1) * (opCount ?? 1) : nil

    // Operators.
    if ["d", "c", "y", ">", "<"].contains(k) || (op == nil && visual && ["x", "X", "D", "C", "Y", "s", "S", "R", "~", "u", "U", "J", "p", "P", "r", "o", "O", "I", "A", ":"].contains(k)) {
      if visual { visualCommand(k); return }
      if let o = op {
        if o == k {  // dd, cc, yy, >>, <<
          linewiseLines(total ?? 1)
        }
        reset()
        return
      }
      op = k
      opCount = n
      count = nil
      return
    }
    if k == "g" || k == "f" || k == "F" || k == "t" || k == "T" || k == "'" || k == "`" || (op == nil && !visual && (k == "r" || k == "m" || k == "z"))
      || ((op != nil || visual) && (k == "i" || k == "a")) {
      prefix = k
      return
    }
    if (k == "/" || k == "?") && op == nil && !visual, let open = onSearchKey, open(Character(k)) { reset(); return }
    if k == "/" || k == "?" { cmdline = ""; cmdKind = Character(k); buf.status(k); return }
    if k == ":" { cmdline = ""; cmdKind = ":"; buf.status(":"); return }
    if !["j", "k", "<Down>", "<Up>", "<C-n>", "<C-p>"].contains(k) { if !["$"].contains(k) { desiredCol = nil } }
    if let m = motion(k, total) {
      apply(m)
      count = nil
      if op != nil { reset() }
      return
    }
    if let o = op, o.hasPrefix("g"), k == String(o.last!) {  // guu, gUU, g~~
      linewiseLines(total ?? 1)
      reset()
      return
    }
    if op != nil { reset(); return }  // unknown key cancels the operator
    count = nil
    command(k, n)
  }

  private func prefixKey(_ k: String) {
    let pfx = prefix
    prefix = ""
    let n = count
    let total: Int? = (n != nil || opCount != nil) ? (n ?? 1) * (opCount ?? 1) : nil
    if k == "<Esc>" { reset(); return }
    switch pfx {
    case "\"":
      register = Character(k)
    case "g":
      switch k {
      case "g":
        let line = (n ?? 1) - 1
        apply(Motion(to: firstNonBlank(startOfLine(max(0, min(line, lineCount() - 1)))), linewise: true, jump: true))
        count = nil
        if op != nil { reset() }
      case "j", "k":
        var q = cursor
        q = buf.displayLine(from: q, by: (k == "j" ? 1 : -1) * (total ?? 1))
        apply(Motion(to: q))
        count = nil
        if op != nil { reset() }
      case "$", "0", "<End>", "<Home>":
        // the screen row's last character / first (a soft-wrapped line has several rows)
        let (a, b) = buf.displayLineEdges(at: cursor)
        let end = k == "$" || k == "<End>"
        let last = b > a ? prev(b) : a
        apply(end ? Motion(to: op == nil && mode != .normal ? b : last, inclusive: op != nil) : Motion(to: a))
        count = nil
        if op != nil { reset() }
      case "u", "U", "~":
        if let o = op, o == "g" + k || (o == "gu" && k == "u") || (o == "gU" && k == "U") { linewiseLines(total ?? 1); reset() }
        else if mode == .visual || mode == .visualLine { visualCommand("g" + k) }
        else { op = "g" + k; opCount = n; count = nil }
      case "J":
        join(max(2, n ?? 2), spaces: false)
      case "v":
        if let v = lastVisual { anchor = v.anchor; head = v.head; mode = v.line ? .visualLine : .visual; select() }
      default: reset()
      }
    case "f", "F", "t", "T":
      lastFind = (Character(pfx), k)
      if let m = find(Character(pfx), k, total ?? 1) { apply(m) }
      count = nil
      if op != nil { reset() }
    case "r":
      guard k.count == 1 || k == "<CR>" else { return }
      let c = n ?? 1
      var e = cursor
      for _ in 0..<c { if e >= lineEnd(cursor) { return }; e = next(e) }
      let start = cursor
      edit(NSRange(location: start, length: e - start), String(repeating: k == "<CR>" ? "\n" : k, count: k == "<CR>" ? 1 : c))
      cursor = k == "<CR>" ? start + 1 : prev(start + c * (k as NSString).length)
    case "m":
      marks[Character(k)] = cursor
    case "'", "`":
      let key: Character = k == "'" || k == "`" ? "'" : Character(k)
      guard let at = marks[key] else { return }
      let m = pfx == "'" ? Motion(to: firstNonBlank(min(at, s.length)), linewise: true, jump: true) : Motion(to: min(at, s.length), jump: true)
      apply(m)
      if op != nil { reset() }
    case "i", "a":
      guard let (r, linewise) = textObject(pfx == "i", k, total ?? 1) else { reset(); return }
      if mode == .visual || mode == .visualLine {
        anchor = r.location
        head = max(r.location, NSMaxRange(r) - 1)
        if linewise { mode = .visualLine }
        select()
      } else if let o = op {
        perform(o, r, linewise: linewise)
        reset()
      }
    case "vr":
      let (r, _) = visualRange()
      guard k.count == 1 else { return }
      var out = ""
      var i = r.location
      while i < NSMaxRange(r) { out += ch(i) == 10 ? "\n" : k; i = next(i) }
      mode = .normal
      edit(r, out)
      cursor = r.location
    case "z":
      if k == "z" { buf.scroll(lines: lineIndex(cursor) - (buf.screenLines.lowerBound + buf.screenLines.upperBound) / 2) }
    default: break
    }
  }

  /// Move the cursor (or the visual head, or apply the pending operator).
  private func apply(_ m: Motion) {
    if m.jump { marks["'"] = cursor }
    if let o = op {
      let p = cursor
      var a = min(p, m.to), b = max(p, m.to)
      if m.linewise {
        a = lineStart(a)
        b = nextLineStart(b)
      } else if m.inclusive {
        b = next(b)
      }
      perform(o, NSRange(location: a, length: b - a), linewise: m.linewise)
      return
    }
    if mode == .visual || mode == .visualLine {
      head = m.to
      select()
      return
    }
    cursor = m.to
    if mode == .normal { clampNormal() }
  }

  private func linewiseLines(_ n: Int) {
    let a = lineStart(cursor)
    var b = a
    for _ in 0..<n { b = nextLineStart(b) }
    if op == "c" || op == "d" || op == "y" || op == ">" || op == "<" || (op ?? "").hasPrefix("g") {
      perform(op!, NSRange(location: a, length: b - a), linewise: true)
    }
  }

  // MARK: operators

  private func setRegister(_ text: String, linewise: Bool, yank: Bool) {
    let r = register ?? "\""
    if r == "+" || r == "*" { buf.clipboard = text }
    else if r.isUppercase, let lower = r.lowercased().first {
      let old = registers[lower]?.text ?? ""
      registers[lower] = (old + text, linewise || (registers[lower]?.linewise ?? false))
    } else if r != "_" {
      registers[r] = (text, linewise)
    }
    if r != "_" {
      registers["\""] = (text, linewise)
      if yank { registers["0"] = (text, linewise) }
    }
  }

  private func getRegister() -> (text: String, linewise: Bool)? {
    let r = register ?? "\""
    if r == "+" || r == "*" { return buf.clipboard.map { ($0, $0.hasSuffix("\n")) } }
    return registers[Character(r.lowercased())] ?? (r == "\"" ? nil : nil)
  }

  private func perform(_ o: String, _ r0: NSRange, linewise: Bool) {
    var r = NSIntersectionRange(r0, NSRange(location: 0, length: s.length))
    if r.length == 0 && r0.length > 0 { r = NSRange(location: min(r0.location, s.length), length: 0) }
    var text = s.substring(with: r)
    switch o {
    case "y":
      if linewise && !text.hasSuffix("\n") { text += "\n" }
      setRegister(text, linewise: linewise, yank: true)
      if !linewise { cursor = r.location } else if lineIndex(r.location) < lineIndex(cursor) { cursor = r.location }
    case "d":
      if linewise && !text.hasSuffix("\n") { text += "\n" }
      setRegister(text, linewise: linewise, yank: false)
      var del = r
      // The last line has no newline after it: take the one before.
      if linewise && NSMaxRange(r) == s.length && r.location > 0 && !s.substring(with: r).hasSuffix("\n") {
        del = NSRange(location: r.location - 1, length: r.length + 1)
      }
      edit(del, "")
      cursor = linewise ? firstNonBlank(min(del.location == r.location ? r.location : lineStart(del.location), s.length)) : r.location
      if mode == .visual || mode == .visualLine { mode = .normal }
    case "c":
      setRegister(linewise && !text.hasSuffix("\n") ? text + "\n" : text, linewise: linewise, yank: false)
      if linewise {
        let indent = String(text.prefix { $0 == " " || $0 == "\t" })
        var rr = r
        if text.hasSuffix("\n") { rr.length -= 1 }
        edit(rr, indent)
        enterInsert(at: rr.location + (indent as NSString).length, change: true)
      } else {
        edit(r, "")
        enterInsert(at: r.location, change: true)
      }
    case ">", "<":
      let first = lineIndex(r.location), last = lineIndex(max(r.location, NSMaxRange(r) - 1))
      for l in (first...last).reversed() {
        let st = startOfLine(l)
        let e = lineEnd(st)
        if e == st { continue }
        if o == ">" { edit(NSRange(location: st, length: 0), String(repeating: " ", count: shiftWidth)) }
        else {
          var k = 0
          while k < shiftWidth && st + k < e && isBlank(ch(st + k)) { k += 1 }
          if ch(st) == 9 { k = 1 }
          if k > 0 { edit(NSRange(location: st, length: k), "") }
        }
      }
      cursor = firstNonBlank(startOfLine(first))
      if mode != .normal { mode = .normal }
    case "gu", "gU", "g~", "~":
      let out: String
      switch o {
      case "gu": out = text.lowercased()
      case "gU": out = text.uppercased()
      default: out = String(text.map { c in let u = String(c).uppercased(); return u == String(c) ? Character(String(c).lowercased()) : Character(u) })
      }
      if out != text { edit(r, out) }
      cursor = r.location
      if mode != .normal { mode = .normal }
    default: break
    }
  }

  // MARK: commands

  private func command(_ k: String, _ n: Int?) {
    let c = n ?? 1
    let p = cursor
    switch k {
    case "x", "<Del>":
      var e = p
      for _ in 0..<c where e < lineEnd(p) { e = next(e) }
      if e > p { perform("d", NSRange(location: p, length: e - p), linewise: false) }
      clampNormal()
    case "X":
      var a = p
      for _ in 0..<c where a > lineStart(p) { a = prev(a) }
      if a < p { perform("d", NSRange(location: a, length: p - a), linewise: false) }
    case "s":
      var e = p
      for _ in 0..<c where e < lineEnd(p) { e = next(e) }
      perform("c", NSRange(location: p, length: e - p), linewise: false)
    case "S":
      op = "c"; linewiseLines(c); op = nil
    case "D", "C":
      var e = p
      for _ in 1..<c { e = nextLineStart(e) }
      e = lineEnd(e)
      perform(k == "D" ? "d" : "c", NSRange(location: p, length: e - p), linewise: false)
      if k == "D" { clampNormal() }
    case "Y":
      op = "y"; linewiseLines(c); op = nil
    case "p", "P":
      guard let (text, linewise) = getRegister() else { return }
      let t = String(repeating: text, count: c)
      if linewise {
        var at = k == "p" ? nextLineStart(p) : lineStart(p)
        var ins = t
        if k == "p" && at == s.length && !s.hasSuffix("\n") && s.length > 0 { ins = "\n" + String(t.dropLast()); at = s.length }
        edit(NSRange(location: at, length: 0), ins)
        cursor = firstNonBlank(ins.hasPrefix("\n") ? at + 1 : at)
      } else {
        let at = (k == "p" && p < lineEnd(p)) ? next(p) : p
        edit(NSRange(location: at, length: 0), t)
        cursor = max(at, at + (t as NSString).length - 1)
      }
    case "J":
      join(max(2, c), spaces: true)
    case "u":
      for _ in 0..<c { buf.undo() }
      clampNormal()
    case "<C-r>":
      for _ in 0..<c { buf.redo() }
      clampNormal()
    case ".":
      repeatLast(n)
    case "~":
      var e = p
      for _ in 0..<c where e < lineEnd(p) { e = next(e) }
      perform("g~", NSRange(location: p, length: e - p), linewise: false)
      cursor = e
      clampNormal()
    case "i": enterInsert(at: p, change: true)
    case "a": enterInsert(at: p < lineEnd(p) ? next(p) : p, change: true)
    case "I": enterInsert(at: firstNonBlank(p), change: true)
    case "A": enterInsert(at: lineEnd(p), change: true)
    case "o", "O":
      let indent = String(s.substring(with: NSRange(location: lineStart(p), length: lineEnd(p) - lineStart(p))).prefix { $0 == " " || $0 == "\t" })
      if k == "o" {
        let e = lineEnd(p)
        edit(NSRange(location: e, length: 0), "\n" + indent)
        enterInsert(at: e + 1 + (indent as NSString).length, change: true)
      } else {
        let st = lineStart(p)
        edit(NSRange(location: st, length: 0), indent + "\n")
        enterInsert(at: st + (indent as NSString).length, change: true)
      }
    case "R":
      mode = .replace
      changed = true
      if !inChange { buf.beginChange(); inChange = true }
    case "v", "V":
      anchor = p; head = p
      mode = k == "v" ? .visual : .visualLine
      select()
    case "*", "#":
      var a = p, b = p
      while a > 0 && cls(prev(a), big: false) == 1 { a = prev(a) }
      while b < s.length && cls(b, big: false) == 1 { b = next(b) }
      guard b > a else { return }
      let word = NSRegularExpression.escapedPattern(for: s.substring(with: NSRange(location: a, length: b - a)))
      search = ("\\b" + word + "\\b", k == "*")
      if let q = searchFrom(k == "*" ? p : a, search!.pattern, forward: k == "*") { marks["'"] = p; cursor = q }
    case "<C-d>", "<C-u>", "<C-f>", "<C-b>":
      let sl = buf.screenLines
      let h = max(1, sl.upperBound - sl.lowerBound)
      let by = (k == "<C-d>" || k == "<C-u>") ? max(1, h / 2) : max(1, h - 2)
      let dir = (k == "<C-d>" || k == "<C-f>") ? 1 : -1
      buf.scroll(lines: dir * by)
      let line = max(0, min(lineCount() - 1, lineIndex(p) + dir * by))
      cursor = firstNonBlank(startOfLine(line))
    default:
      break
    }
  }

  private func join(_ n: Int, spaces: Bool) {
    var p = cursor
    var at = p
    for _ in 1..<n {
      let e = lineEnd(p)
      guard e < s.length else { break }
      var b = e + 1
      while b < lineEnd(b) && isBlank(ch(b)) { b += 1 }
      var a = e
      if spaces { while a > lineStart(p) && isBlank(ch(a - 1)) { a -= 1 } }
      let sep = (!spaces || b == lineEnd(b) || ch(b) == 41 || a == lineStart(p)) ? "" : " "
      edit(NSRange(location: a, length: b - a), sep)
      at = a
      p = a
    }
    cursor = at
  }

  // MARK: insert and replace

  private func enterInsert(at p: Int, change: Bool) {
    if !inChange { buf.beginChange(); inChange = true }
    changed = changed || change
    cursor = p
    insertStart = p
    mode = .insert
  }

  private func leaveInsert() {
    let p = cursor
    if !replaying {
      lastInsert = p >= insertStart ? s.substring(with: NSRange(location: insertStart, length: p - insertStart)) : ""
    }
    mode = .normal
    if inChange { buf.endChange(); inChange = false }
    if p > lineStart(p) { cursor = prev(p) }
    clampNormal()
  }

  private func replaceModeKey(_ k: VimKey) {
    switch k.name {
    case "<Esc>", "<C-[>", "<C-c>":
      mode = .normal
      if inChange { buf.endChange(); inChange = false }
      if cursor > lineStart(cursor) { cursor = prev(cursor) }
    case "<BS>", "<Left>":
      if cursor > lineStart(cursor) { cursor = prev(cursor) }
    case "<CR>":
      edit(NSRange(location: cursor, length: 0), "\n")
      cursor += 1
    default:
      guard !k.name.hasPrefix("<") || k.name.count == 1 else { return }
      let p = cursor
      let len = p < lineEnd(p) ? charLen(p) : 0
      edit(NSRange(location: p, length: len), k.name)
      cursor = p + (k.name as NSString).length
    }
  }

  // MARK: visual

  private func select() {
    let a = min(anchor, head), b = max(anchor, head)
    if mode == .visualLine {
      let st = lineStart(a), e = nextLineStart(b)
      buf.selection = NSRange(location: st, length: e - st)
    } else {
      buf.selection = NSRange(location: a, length: next(b) - a)
    }
  }

  /// The selection as an operator range.
  private func visualRange() -> (NSRange, Bool) {
    let a = min(anchor, head), b = max(anchor, head)
    if mode == .visualLine { return (NSRange(location: lineStart(a), length: nextLineStart(b) - lineStart(a)), true) }
    return (NSRange(location: a, length: next(b) - a), false)
  }

  private func exitVisual() {
    lastVisual = (anchor, head, mode == .visualLine)
    marks["<"] = min(anchor, head)
    marks[">"] = max(anchor, head)
    let h = head
    mode = .normal
    cursor = h
    clampNormal()
  }

  private func visualCommand(_ k: String) {
    let (r, linewise) = visualRange()
    lastVisual = (anchor, head, mode == .visualLine)
    marks["<"] = r.location
    marks[">"] = max(r.location, NSMaxRange(r) - 1)
    switch k {
    case "d", "x", "X", "D":
      mode = .normal
      perform("d", (k == "X" || k == "D") ? NSRange(location: lineStart(r.location), length: nextLineStart(max(r.location, NSMaxRange(r) - 1)) - lineStart(r.location)) : r,
              linewise: linewise || k == "X" || k == "D")
      clampNormal()
    case "c", "s":
      mode = .normal
      perform("c", r, linewise: linewise)
    case "S", "R", "C":
      mode = .normal
      perform("c", NSRange(location: lineStart(r.location), length: nextLineStart(max(r.location, NSMaxRange(r) - 1)) - lineStart(r.location)), linewise: true)
    case "y", "Y":
      mode = .normal
      perform("y", k == "Y" ? NSRange(location: lineStart(r.location), length: nextLineStart(max(r.location, NSMaxRange(r) - 1)) - lineStart(r.location)) : r,
              linewise: linewise || k == "Y")
      cursor = r.location
    case ">", "<":
      perform(k, r, linewise: true)
    case "~", "u", "U", "g~", "gu", "gU":
      let o = ["~": "g~", "u": "gu", "U": "gU"][k] ?? k
      perform(o, r, linewise: linewise)
    case "J":
      mode = .normal
      cursor = r.location
      join(max(2, lineIndex(NSMaxRange(r) - 1) - lineIndex(r.location) + 1), spaces: true)
    case "p", "P":
      guard let reg = getRegister() else { return }
      mode = .normal
      edit(r, reg.linewise && !linewise ? "\n" + reg.text : reg.text)
      cursor = r.location
    case "r":
      prefix = "vr"
    case "o", "O":
      swap(&anchor, &head)
      select()
    case "I":
      mode = .normal
      enterInsert(at: r.location, change: true)
    case "A":
      mode = .normal
      enterInsert(at: linewise ? lineEnd(r.location) : NSMaxRange(r), change: true)
    case ":":
      cmdline = "'<,'>"
      cmdKind = ":"
      buf.status(":'<,'>")
    default: break
    }
  }

  // MARK: `.`

  private func repeatLast(_ n: Int?) {
    guard !lastChange.isEmpty else { return }
    var keys = lastChange
    if let n {
      // Replace the count the change was made with.
      while let f = keys.first, f.name.count == 1, f.name.first!.isNumber, f.name != "0" || keys.count < lastChange.count { keys.removeFirst() }
      keys = VimKey.parse(String(n)) + keys
    }
    let saved = (lastChange, lastInsert, insertIsChange)
    replaying = true
    let savedKeys = cmdKeys
    cmdKeys = []
    for k in keys { _ = handle(k) }
    if mode == .insert {
      let at = cursor
      buf.replace(NSRange(location: at, length: 0), with: saved.1)
      cursor = at + (saved.1 as NSString).length
      leaveInsert()
    }
    replaying = false
    (lastChange, lastInsert, insertIsChange) = saved
    cmdKeys = savedKeys
    changed = false
  }

  // MARK: search and `:`

  /// A search made elsewhere (the find bar): an ICU pattern n and N continue; `from`, where it started, is the
  /// jump mark (as after `/`).
  public func setSearch(pattern: String, forward: Bool, from: Int? = nil) {
    search = (pattern, forward)
    if let from { marks["'"] = from }
  }

  private func cmdlineKey(_ k: VimKey) {
    guard var line = cmdline else { return }
    switch k.name {
    case "<Esc>", "<C-c>":
      cmdline = nil
      buf.status("")
      if mode == .visual || mode == .visualLine { exitVisual() }
      return
    case "<BS>":
      if line.isEmpty { cmdline = nil; buf.status(""); return }
      line.removeLast()
    case "<CR>":
      cmdline = nil
      buf.status("")
      run(line)
      return
    default:
      if k.name.count == 1 || !k.name.hasPrefix("<") { line += k.name }
    }
    cmdline = line
    buf.status(String(cmdKind) + line)
  }

  private func run(_ line: String) {
    if cmdKind == "/" || cmdKind == "?" {
      let pattern = line.isEmpty ? (search?.pattern ?? "") : line
      search = (pattern, cmdKind == "/")
      if let q = searchFrom(cursor, pattern, forward: cmdKind == "/") {
        if let o = op {
          let a = min(cursor, q), b = max(cursor, q)
          perform(o, NSRange(location: a, length: b - a), linewise: false)
          reset()
        } else { marks["'"] = cursor; apply(Motion(to: q)) }
      } else {
        buf.status("Pattern not found: \(pattern)")
        reset()
      }
      return
    }
    ex(line)
    if mode == .visual || mode == .visualLine { exitVisual() }
  }

  func regex(_ pattern: String) -> NSRegularExpression? {
    // Vim's \< \> are word boundaries; smartcase.
    let p = pattern.replacingOccurrences(of: "\\<", with: "\\b").replacingOccurrences(of: "\\>", with: "\\b")
    let opts: NSRegularExpression.Options = p.contains(where: \.isUppercase) ? [] : [.caseInsensitive]
    return (try? NSRegularExpression(pattern: p, options: opts)) ?? (try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: pattern), options: opts))
  }

  func searchFrom(_ p: Int, _ pattern: String, forward: Bool) -> Int? {
    guard let re = regex(pattern) else { return nil }
    let all = re.matches(in: s as String, range: NSRange(location: 0, length: s.length)).map(\.range.location)
    if all.isEmpty { return nil }
    if forward { return all.first { $0 > p } ?? all.first }
    return all.last { $0 < p } ?? all.last
  }

  /// A Vim replacement as an NSRegularExpression template: `\1`…`\9` and `&` are groups, `\\` a backslash, `\n` a
  /// newline, `\&` an ampersand.
  static func template(_ r: String) -> String {
    var out = ""
    var it = r.makeIterator()
    while let c = it.next() {
      switch c {
      case "\\":
        guard let n = it.next() else { out += "\\\\"; break }
        if n.isNumber { out += "$" + String(n) }
        else if n == "n" { out += "\n" }
        else if n == "\\" { out += "\\\\" }
        else if n == "$" { out += "\\$" }
        else { out += String(n) }
      case "&": out += "$0"
      case "$": out += "\\$"
      default: out += String(c)
      }
    }
    return out
  }

  /// `:w`, `:{n}`, `:noh`, `:[range]s/pat/rep/[g]`.
  private func ex(_ cmd0: String) {
    let cmd = cmd0.trimmingCharacters(in: .whitespaces)
    if ["w", "w!", "wa", "update", "noh", "nohlsearch"].contains(cmd) { return }
    if cmd == "$" { apply(Motion(to: firstNonBlank(startOfLine(lineCount() - 1)), linewise: true, jump: true)); return }
    if let n = Int(cmd) { apply(Motion(to: firstNonBlank(startOfLine(max(0, min(n - 1, lineCount() - 1)))), linewise: true, jump: true)); return }
    // range
    var rest = Substring(cmd)
    var first = lineIndex(cursor), last = first
    func lineNum(_ t: inout Substring) -> Int? {
      if t.hasPrefix(".") { t.removeFirst(); return lineIndex(cursor) }
      if t.hasPrefix("$") { t.removeFirst(); return lineCount() - 1 }
      if t.hasPrefix("'"), t.count >= 2, let m = marks[t.dropFirst().first!] { t.removeFirst(2); return lineIndex(m) }
      let digits = t.prefix { $0.isNumber }
      if let n = Int(digits) { t.removeFirst(digits.count); return n - 1 }
      return nil
    }
    if rest.hasPrefix("%") { rest.removeFirst(); first = 0; last = lineCount() - 1 }
    else if let a = lineNum(&rest) {
      first = a; last = a
      if rest.hasPrefix(","), case _ = rest.removeFirst(), let b = lineNum(&rest) { last = b }
    }
    guard rest.hasPrefix("s"), rest.count > 1 else { buf.status("Not an editor command: \(cmd)"); return }
    rest.removeFirst()
    let delim = rest.removeFirst()
    let parts = rest.split(separator: delim, maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
    guard parts.count >= 2, let re = regex(parts[0].isEmpty ? (search?.pattern ?? "") : parts[0]) else { return }
    let global = parts.count > 2 && parts[2].contains("g")
    let tmpl = VimEngine.template(parts[1])
    var count = 0
    var lastLine: Int?
    for l in (min(first, last)...max(first, last)).reversed() where l < lineCount() {
      let st = startOfLine(l)
      let r = NSRange(location: st, length: lineEnd(st) - st)
      let line = s.substring(with: r)
      let matches = re.matches(in: line, range: NSRange(location: 0, length: (line as NSString).length))
      guard !matches.isEmpty else { continue }
      let use = global ? matches : [matches[0]]
      let m = NSMutableString(string: line)
      for mt in use.reversed() {
        let rep = re.replacementString(for: mt, in: line, offset: 0, template: tmpl)
        m.replaceCharacters(in: mt.range, with: rep)
      }
      edit(r, m as String)
      count += use.count
      lastLine = max(lastLine ?? l, l)
    }
    if let l = lastLine { cursor = startOfLine(l) }
    if count == 0 { buf.status("Pattern not found: \(parts[0])") }
    clampNormal()
    if inChange { buf.endChange(); inChange = false }
  }
}
