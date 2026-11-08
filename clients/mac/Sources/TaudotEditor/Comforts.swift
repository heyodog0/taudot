// The native editor's comforts as pure functions on NSString, the same rules as clients/nvim/lua/taudot/comforts:
// `\begin` auto-close and rename, ⌘/ comment toggling, fuzzy filtering of completion items.
import Foundation

public enum Comforts {
  /// The environment of a `\begin{env}` ending exactly at `loc` (just typed its `}`).
  public static func beginEnding(_ s: NSString, at loc: Int) -> String? {
    let line = s.lineRange(for: NSRange(location: max(0, loc - 1), length: 0))
    let pre = s.substring(with: NSRange(location: line.location, length: loc - line.location))
    guard pre.hasSuffix("}"), let r = pre.range(of: "\\begin{", options: .backwards) else { return nil }
    let name = pre[r.upperBound..<pre.index(before: pre.endIndex)]
    return name.isEmpty || name.contains("}") || name.contains("{") ? nil : String(name)
  }

  /// The range of the name in the `\end{env}` closing the environment begun just before `from`, counting nested
  /// ones of the same name, or nil when it isn't closed.
  public static func matchingEnd(_ s: NSString, from: Int, env: String, limit: Int = 400_000) -> NSRange? {
    let b = "\\begin{\(env)}", e = "\\end{\(env)}"
    var depth = 1
    var at = from
    let end = min(s.length, from + limit)
    while at < end {
      let r = NSRange(location: at, length: end - at)
      let fb = s.range(of: b, options: [], range: r), fe = s.range(of: e, options: [], range: r)
      if fe.location == NSNotFound { return nil }
      if fb.location != NSNotFound && fb.location < fe.location {
        if !commented(s, fb.location) { depth += 1 }
        at = fb.location + fb.length
      } else {
        if !commented(s, fe.location) {
          depth -= 1
          if depth == 0 { return NSRange(location: fe.location + 5, length: (env as NSString).length) }
        }
        at = fe.location + fe.length
      }
    }
    return nil
  }

  /// Is `loc` after an unescaped `%` on its line?
  static func commented(_ s: NSString, _ loc: Int) -> Bool {
    let line = s.lineRange(for: NSRange(location: loc, length: 0))
    var i = line.location
    while i < loc {
      let c = s.character(at: i)
      if c == 92 { i += 2; continue }
      if c == 37 { return true }
      i += 1
    }
    return false
  }

  /// `\begin{env}` at the start of the line holding `loc` (after indent), with nothing but its arguments after it:
  /// (indent, env, the location just after `}`).
  public static func beginLine(_ s: NSString, lineAt loc: Int) -> (indent: String, env: String, after: Int)? {
    let line = s.lineRange(for: NSRange(location: loc, length: 0))
    var text = s.substring(with: line)
    if text.hasSuffix("\n") { text.removeLast() }
    let indent = String(text.prefix { $0 == " " || $0 == "\t" })
    let rest = text.dropFirst(indent.count)
    guard rest.hasPrefix("\\begin{"), let close = rest.firstIndex(of: "}") else { return nil }
    let env = String(rest[rest.index(rest.startIndex, offsetBy: 7)..<close])
    let tail = rest[rest.index(after: close)...]
    if env.isEmpty || env.contains("{") || tail.contains("\\end{") { return nil }
    let after = line.location + (indent as NSString).length + (String(rest[...close]) as NSString).length
    return (indent, env, after)
  }

  /// Toggle `% ` on whole lines: all commented → uncomment, else comment at their common indent. Blank lines kept.
  public static func toggleComment(_ lines: [String]) -> [String] {
    let nonblank = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    if nonblank.isEmpty { return lines }
    let all = nonblank.allSatisfy { $0.drop { $0 == " " || $0 == "\t" }.hasPrefix("%") }
    let indent = nonblank.map { $0.prefix { $0 == " " || $0 == "\t" }.count }.min() ?? 0
    return lines.map { l in
      if l.trimmingCharacters(in: .whitespaces).isEmpty { return l }
      if all {
        let ind = l.prefix { $0 == " " || $0 == "\t" }
        var rest = l.dropFirst(ind.count).dropFirst()
        if rest.hasPrefix(" ") { rest = rest.dropFirst() }
        return String(ind) + rest
      }
      return String(l.prefix(indent)) + "% " + l.dropFirst(indent)
    }
  }

  /// Fuzzy match: every character of `query` in order (case-insensitive). Score: lower is better (prefix first,
  /// then tighter matches).
  public static func fuzzy(_ query: String, _ label: String) -> Int? {
    if query.isEmpty { return 0 }
    let q = Array(query.lowercased()), l = Array(label.lowercased())
    var qi = 0, first = -1, last = 0
    for (i, c) in l.enumerated() where qi < q.count && c == q[qi] {
      if first < 0 { first = i }
      last = i
      qi += 1
    }
    guard qi == q.count else { return nil }
    let prefix = label.lowercased().hasPrefix(query.lowercased()) || label.lowercased().dropFirst().hasPrefix(query.lowercased())
    return (prefix ? 0 : 1000) + (last - first) * 10 + first
  }
}
