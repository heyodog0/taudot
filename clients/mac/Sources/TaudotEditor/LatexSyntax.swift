// LaTeX tokens for highlighting: comments, commands, environment names, math, brackets. Works on UTF-16 (NSString)
// ranges so it maps straight onto the text view's storage. Math state at a range's start comes from scanning back
// for the last math opener or closer, so a paragraph can be highlighted on its own after an edit.
import Foundation

public enum LatexToken: Equatable, Sendable {
  case comment, command, env, math, bracket
}

public enum LatexSyntax {
  static let mathEnvs: Set<String> = [
    "equation", "equation*", "align", "align*", "gather", "gather*", "multline", "multline*", "eqnarray", "eqnarray*",
    "displaymath", "math", "flalign", "flalign*", "alignat", "alignat*",
  ]

  private static let backslash: unichar = 92, percent: unichar = 37, dollar: unichar = 36, lbrace: unichar = 123,
    rbrace: unichar = 125, lbrack: unichar = 91, rbrack: unichar = 93, newline: unichar = 10, lparen: unichar = 40, rparen: unichar = 41

  static func isLetter(_ c: unichar) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 64 }

  /// Is `loc` inside display math (`\[`, or a math environment)? Looks back at most `window` characters, in one
  /// pass: the nearest `\[`, `\]`, or `\begin{…}`/`\end{…}` of a math environment decides.
  public static func inDisplayMath(_ s: NSString, at loc: Int, window: Int = 20000) -> Bool {
    let from = max(0, loc - window)
    let n = loc - from
    guard n > 0 else { return false }
    // a little past loc, to read an environment's name that starts just before it
    let extra = min(40, s.length - loc)
    var buf = [unichar](repeating: 0, count: n + extra)
    s.getCharacters(&buf, range: NSRange(location: from, length: n + extra))
    var i = n - 1
    while i >= 0 {
      // (`\\[2pt]` is a line break, not display math)
      if buf[i] == backslash && i + 1 < buf.count && !(i > 0 && buf[i - 1] == backslash) {
        let d = buf[i + 1]
        if d == lbrack && i + 1 < n { return true }
        if d == rbrack && i + 1 < n { return false }
        if d == 98 || d == 101 {  // b(egin) / e(nd)
          let word: [unichar] = d == 98 ? Array("begin{".utf16) : Array("end{".utf16)
          let j = i + 1
          if j + word.count <= buf.count, Array(buf[j..<(j + word.count)]) == word {
            let nameStart = j + word.count
            var k = nameStart
            while k < buf.count && k < nameStart + 20 && buf[k] != rbrace { k += 1 }
            if k < buf.count && buf[k] == rbrace && nameStart <= n {
              let name = String(utf16CodeUnits: Array(buf[nameStart..<k]), count: k - nameStart)
              if mathEnvs.contains(name) { return d == 98 }
            }
          }
        }
      }
      i -= 1
    }
    return false
  }

  /// Tokens in `range` of `s`, in order.
  public static func tokens(_ s: NSString, in range: NSRange) -> [(NSRange, LatexToken)] {
    var out: [(NSRange, LatexToken)] = []
    let end = range.location + range.length
    // the range's characters, read once (character(at:) on a text storage is a message send each)
    var buf = [unichar](repeating: 0, count: range.length)
    s.getCharacters(&buf, range: range)
    let base = range.location
    var i = range.location
    var display = inDisplayMath(s, at: range.location)
    var inline: unichar = 0  // `$` or `(` while in inline math
    var mathStart = display ? i : -1
    func closeMath(_ at: Int) {
      if mathStart >= 0 && at > mathStart { out.append((NSRange(location: mathStart, length: at - mathStart), .math)) }
      mathStart = -1
    }
    while i < end {
      let c = buf[i - base]
      if c == percent {
        closeMath(i)
        var j = i
        while j < end && buf[j - base] != newline { j += 1 }
        out.append((NSRange(location: i, length: j - i), .comment))
        if display || inline != 0 { mathStart = j }
        i = j
        continue
      }
      if c == backslash && i + 1 < end {
        let d = buf[i + 1 - base]
        if !isLetter(d) {
          // \[ \] \( \) and escapes
          if d == lbrack && inline == 0 && !display { display = true; out.append((NSRange(location: i, length: 2), .command)); i += 2; mathStart = i; continue }
          if d == rbrack && display { closeMath(i); display = false; out.append((NSRange(location: i, length: 2), .command)); i += 2; continue }
          if d == lparen && inline == 0 && !display { inline = lparen; out.append((NSRange(location: i, length: 2), .command)); i += 2; mathStart = i; continue }
          if d == rparen && inline == lparen { closeMath(i); inline = 0; out.append((NSRange(location: i, length: 2), .command)); i += 2; continue }
          i += 2
          continue
        }
        var j = i + 1
        while j < end && isLetter(buf[j - base]) { j += 1 }
        let name = s.substring(with: NSRange(location: i + 1, length: j - i - 1))
        if mathStart >= 0 { closeMath(i) }
        out.append((NSRange(location: i, length: j - i), .command))
        if (name == "begin" || name == "end") && j < end && buf[j - base] == lbrace {
          var k = j + 1
          while k < end && buf[k - base] != rbrace && buf[k - base] != newline { k += 1 }
          if k < end && buf[k - base] == rbrace {
            out.append((NSRange(location: j, length: 1), .bracket))
            let env = s.substring(with: NSRange(location: j + 1, length: k - j - 1))
            out.append((NSRange(location: j + 1, length: k - j - 1), .env))
            out.append((NSRange(location: k, length: 1), .bracket))
            j = k + 1
            if mathEnvs.contains(env) { display = name == "begin" }
          }
        }
        i = j
        if display || inline != 0 { mathStart = i }
        continue
      }
      if c == dollar && !display {
        let dbl = i + 1 < end && buf[i + 1 - base] == dollar
        let n = dbl ? 2 : 1
        if inline == dollar { closeMath(i); inline = 0; out.append((NSRange(location: i, length: n), .math)); i += n; continue }
        if inline == 0 { inline = dollar; out.append((NSRange(location: i, length: n), .math)); i += n; mathStart = i; continue }
      }
      if c == lbrace || c == rbrace || c == lbrack || c == rbrack {
        if mathStart < 0 { out.append((NSRange(location: i, length: 1), .bracket)) }
      }
      i += 1
    }
    closeMath(end)
    return out
  }
}
