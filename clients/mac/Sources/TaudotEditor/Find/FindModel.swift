// The find bar's model: what is searched for (text and options), as an ICU regex for the native editor and as a Vim
// pattern for Neovim, the matches in a text, and replacing them. Pure: no views.
import Foundation

/// What the bar searches for.
public struct FindQuery: Equatable, Sendable {
  public var text: String
  /// Off: smart case (case-insensitive unless the text has a capital, as Vim's `ignorecase smartcase`). On: exact.
  public var matchCase: Bool
  public var wholeWord: Bool
  /// The text is a regular expression (ICU in the native editor, Vim's very magic `\v` in Neovim).
  public var regex: Bool

  public init(_ text: String = "", matchCase: Bool = false, wholeWord: Bool = false, regex: Bool = false) {
    self.text = text
    self.matchCase = matchCase
    self.wholeWord = wholeWord
    self.regex = regex
  }

  /// Case matters: the toggle, or smart case with a capital in the text (a regex's escapes like `\S` don't count).
  public var caseSensitive: Bool {
    if matchCase { return true }
    var s = text
    if regex { s = s.replacingOccurrences(of: #"\\."#, with: "", options: .regularExpression) }
    return s.contains { $0.isUppercase }
  }

  /// The ICU pattern, or an error message for a regex that doesn't compile.
  public func compiled() -> Result<NSRegularExpression, FindError> {
    guard !text.isEmpty else { return .failure(.empty) }
    var p = regex ? text : NSRegularExpression.escapedPattern(for: text)
    if wholeWord { p = #"(?<![\p{L}\p{N}_])(?:"# + p + #")(?![\p{L}\p{N}_])"# }
    do {
      return .success(try NSRegularExpression(pattern: p, options: caseSensitive ? [] : [.caseInsensitive]))
    } catch {
      return .failure(.badPattern(FindQuery.icuMessage(text)))
    }
  }

  /// A short reason a regex doesn't compile.
  static func icuMessage(_ p: String) -> String {
    var depth = 0
    var escaped = false
    var inClass = false
    for c in p {
      if escaped { escaped = false; continue }
      switch c {
      case "\\": escaped = true
      case "[": inClass = true
      case "]": inClass = false
      case "(" where !inClass: depth += 1
      case ")" where !inClass: depth -= 1
      default: break
      }
    }
    if escaped { return "Ends with a backslash" }
    if inClass { return "Unclosed [" }
    if depth > 0 { return "Unclosed (" }
    if depth < 0 { return "Unmatched )" }
    return "Not a valid pattern"
  }

  /// The same search as a Vim pattern: `\c`/`\C` for the case, `\V` (very nomagic, literal) or `\v` (very magic, the
  /// closest to the regexes people know) and `\<…\>` for whole words.
  public var vimPattern: String {
    let body = regex ? "\\v" + text : "\\V" + text.replacingOccurrences(of: "\\", with: "\\\\")
    let core = wholeWord ? (regex ? "\\v<%(" + text + ")>" : "\\V\\<" + body.dropFirst(2) + "\\>") : body
    return (caseSensitive ? "\\C" : "\\c") + core
  }

  /// Characters that mean something in a Vim pattern with 'magic' on.
  static let vimMagic: Set<Character> = ["\\", ".", "*", "[", "~", "^", "$"]

  /// The pattern as Neovim shows it back (its search echo, `/` history): a plain word stays `model`, not
  /// `\c\Vmodel`, when the user's 'ignorecase' / 'smartcase' already give the bar's case and nothing in it is magic.
  public func vimPattern(ignorecase: Bool, smartcase: Bool) -> String {
    guard !regex, !text.isEmpty, !text.contains(where: FindQuery.vimMagic.contains) else { return vimPattern }
    let core = wholeWord ? "\\<" + text + "\\>" : text
    let theirs = ignorecase ? (smartcase && text.contains { $0.isUppercase }) : true
    return theirs == caseSensitive ? core : (caseSensitive ? "\\C" : "\\c") + core
  }

  /// A pattern from Neovim's `/` history as a query: the bar's own, or a plain one (`model`, `\<cite\>`, typed at
  /// Neovim's own `/` too) read with the user's case options. Nil for anything else.
  public static func fromVim(_ p: String, ignorecase: Bool, smartcase: Bool) -> FindQuery? {
    if let q = fromVim(p) { return q }
    var s = Substring(p)
    var sens: Bool?
    if s.hasPrefix("\\C") { sens = true; s = s.dropFirst(2) } else if s.hasPrefix("\\c") { sens = false; s = s.dropFirst(2) }
    var word = false
    if s.hasPrefix("\\<"), s.hasSuffix("\\>"), s.count > 4 { s = s.dropFirst(2).dropLast(2); word = true }
    guard !s.isEmpty, !s.contains(where: vimMagic.contains) else { return nil }
    var q = FindQuery(String(s), wholeWord: word)
    let effective = sens ?? (ignorecase ? (smartcase && s.contains { $0.isUppercase }) : true)
    if !effective && q.caseSensitive { return nil }  // the bar can't search a capital case-insensitively
    q.matchCase = effective && !q.caseSensitive
    return q
  }

  /// A Vim pattern the bar wrote (`vimPattern`) back as a query, or nil for one written some other way.
  public static func fromVim(_ p: String) -> FindQuery? {
    var s = Substring(p)
    var sensitive: Bool?
    if s.hasPrefix("\\C") { sensitive = true; s = s.dropFirst(2) } else if s.hasPrefix("\\c") { sensitive = false; s = s.dropFirst(2) }
    guard let sens = sensitive else { return nil }
    var q: FindQuery
    if s.hasPrefix("\\v<%("), s.hasSuffix(")>") {
      q = FindQuery(String(s.dropFirst(5).dropLast(2)), wholeWord: true, regex: true)
    } else if s.hasPrefix("\\v") {
      q = FindQuery(String(s.dropFirst(2)), regex: true)
    } else if s.hasPrefix("\\V") {
      var body = s.dropFirst(2)
      var word = false
      if body.hasPrefix("\\<"), body.hasSuffix("\\>"), body.count >= 4 { body = body.dropFirst(2).dropLast(2); word = true }
      // \\ is a backslash; any other backslash is something the bar never writes.
      var out = ""
      var it = body.makeIterator()
      while let c = it.next() {
        if c == "\\" { guard it.next() == "\\" else { return nil }; out.append("\\") } else { out.append(c) }
      }
      q = FindQuery(out, wholeWord: word)
    } else {
      return nil
    }
    // Smart case already gives sensitive with a capital; otherwise sensitive means the toggle was on.
    q.matchCase = sens && !q.caseSensitive
    if !sens && q.caseSensitive { return nil }  // \c with a capital: not the bar's
    return q
  }

  /// Every match in `s`, in order. Empty matches (a regex like `x*`) are skipped.
  public func matches(in s: NSString, limit: Int = 100_000) -> Result<[NSRange], FindError> {
    switch compiled() {
    case .failure(let e): return .failure(e)
    case .success(let re):
      var out: [NSRange] = []
      re.enumerateMatches(in: s as String, options: [], range: NSRange(location: 0, length: s.length)) { m, _, stop in
        guard let r = m?.range, r.length > 0 else { return }
        out.append(r)
        if out.count >= limit { stop.pointee = true }
      }
      return .success(out)
    }
  }

  /// What a match is replaced with: the text as typed, or (regex) with `$1`, `\1` and `&`... expanded. Literal
  /// searches replace literally.
  public func replacement(for match: NSRange, in s: NSString, with template: String) -> String {
    guard regex, case .success(let re) = compiled(),
          let m = re.firstMatch(in: s as String, options: .withTransparentBounds, range: match)
    else { return template }
    return re.replacementString(for: m, in: s as String, offset: 0, template: FindQuery.icuTemplate(template))
  }

  /// A replacement as ICU takes it: `$1` and `\1` are groups, `\n` and `\t` a newline and a tab, `\\` a backslash;
  /// anything else as typed.
  static func icuTemplate(_ r: String) -> String {
    var out = ""
    var it = r.makeIterator()
    while let c = it.next() {
      switch c {
      case "\\":
        guard let n = it.next() else { out += "\\\\"; break }
        if n.isNumber { out += "$" + String(n) } else if n == "n" { out += "\n" } else if n == "t" { out += "\t" } else if n == "$" { out += "\\$" } else { out += "\\" + String(n) }
      case "$":
        out += "$"
      default: out.append(c)
      }
    }
    return out
  }

  /// A replacement for Vim's `:s`: in a literal search, the text exactly (`\`, `&`, `~` and the `/` delimiter
  /// escaped, newlines as `\r`); in a regex, as typed but with `$1` turned into `\1` (both forms work in both editors).
  public func vimReplacement(_ r: String) -> String {
    if !regex {
      var out = ""
      for c in r {
        switch c {
        case "\\", "&", "~", "/": out += "\\" + String(c)
        case "\n": out += "\\r"
        default: out.append(c)
        }
      }
      return out
    }
    var out = ""
    let chars = Array(r)
    var i = 0
    while i < chars.count {
      let c = chars[i]
      if c == "\\", i + 1 < chars.count { out.append(c); out.append(chars[i + 1]); i += 2; continue }
      if c == "$", i + 1 < chars.count, chars[i + 1].isNumber { out += "\\" + String(chars[i + 1]); i += 2; continue }
      if c == "/" { out += "\\/" } else { out.append(c) }
      i += 1
    }
    return out
  }
}

public enum FindError: Error, Equatable, Sendable {
  case empty
  case badPattern(String)
  public var message: String? {
    switch self {
    case .empty: return nil
    case .badPattern(let m): return m
    }
  }
}

/// What a search found: the number of matches and which one is current (1-based, 0: none), as "3 of 17".
public struct FindCount: Equatable, Sendable {
  public var current: Int
  public var total: Int
  /// The count stopped early (Neovim's searchcount timed out): "17+".
  public var incomplete: Bool
  public var error: String?
  public init(current: Int = 0, total: Int = 0, incomplete: Bool = false, error: String? = nil) {
    self.current = current
    self.total = total
    self.incomplete = incomplete
    self.error = error
  }

  /// "3 of 17", "17 matches", "No matches", or the regex's error.
  public var label: String {
    if let error { return error }
    if total == 0 { return "No matches" }
    let t = incomplete ? "\(total)+" : "\(total)"
    if current == 0 { return total == 1 ? "1 match" : "\(t) matches" }
    return "\(current) of \(t)"
  }
}

/// Matches in a text, and which is current. Positions are UTF-16 offsets.
public struct FindMatches: Equatable, Sendable {
  public var ranges: [NSRange] = []
  public var current: Int?
  public init(ranges: [NSRange] = [], current: Int? = nil) {
    self.ranges = ranges
    self.current = current
  }

  public var count: FindCount { FindCount(current: current.map { $0 + 1 } ?? 0, total: ranges.count) }

  /// The first match after `loc` (forward; at `loc` too when `inclusive`), or the last before it, wrapping around.
  public func index(from loc: Int, forward: Bool, inclusive: Bool = false) -> Int? {
    guard !ranges.isEmpty else { return nil }
    if forward {
      var lo = 0, hi = ranges.count
      while lo < hi { let m = (lo + hi) / 2; if ranges[m].location < loc || (!inclusive && ranges[m].location == loc) { lo = m + 1 } else { hi = m } }
      return lo < ranges.count ? lo : 0
    }
    var lo = 0, hi = ranges.count
    while lo < hi { let m = (lo + hi) / 2; if ranges[m].location < loc || (inclusive && ranges[m].location == loc) { lo = m + 1 } else { hi = m } }
    return lo > 0 ? lo - 1 : ranges.count - 1
  }

  /// The match that starts at `loc`, if any.
  public func index(at loc: Int) -> Int? {
    var lo = 0, hi = ranges.count
    while lo < hi { let m = (lo + hi) / 2; if ranges[m].location < loc { lo = m + 1 } else { hi = m } }
    return lo < ranges.count && ranges[lo].location == loc ? lo : nil
  }

  /// The text with every match replaced, as (range, replacement) pairs from last to first (apply in this order and
  /// the earlier ranges stay right).
  public func replacements(_ q: FindQuery, in s: NSString, with template: String) -> [(NSRange, String)] {
    ranges.reversed().map { ($0, q.replacement(for: $0, in: s, with: template)) }
  }
}
