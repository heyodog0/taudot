// BibTeX's log (.blg) as issues, for the app's issues list (Overleaf lists them too). txp-render sends the whole .blg
// after each BibTeX run as one stderr line, ["bib-log", text].
import Foundation

public struct BibTeXIssue: Equatable, Sendable {
  public enum Severity: String, Sendable { case warning, error }
  public var severity: Severity
  /// BibTeX's words, e.g. `empty journal in smith20`, `I didn't find a database entry for "foo"`.
  public var message: String
  /// The .bib (or .bst) file and line BibTeX points at, relative to the project folder; nil when it names none.
  public var file: String?
  public var line: Int?
  /// The citation key the message is about, when it names one (a missing entry, an empty field).
  public var key: String?

  public init(severity: Severity, message: String, file: String? = nil, line: Int? = nil, key: String? = nil) {
    self.severity = severity; self.message = message; self.file = file; self.line = line; self.key = key
  }

  /// The .blg text from a `["bib-log", text]` stderr line, or nil for any other line.
  public static func blg(fromDriverLine l: String) -> String? {
    guard l.hasPrefix("[\"bib-log\""), let a = try? JSONSerialization.jsonObject(with: Data(l.utf8)) as? [Any],
      a.count == 2, let s = a[1] as? String else { return nil }
    return s
  }

  /// Warnings and errors in a .blg, in order. Locations in the driver's own stub (txs-bib.aux) are dropped.
  public static func parse(_ blg: String) -> [BibTeXIssue] {
    var out: [BibTeXIssue] = []
    let lines = blg.components(separatedBy: "\n")
    // "---line 12 of file refs.bib" / "--line 12 of file refs.bib"
    func location(_ s: Substring) -> (file: String, line: Int)? {
      guard let r = s.range(of: #"-{2,3}line (\d+) of file (.+)$"#, options: .regularExpression) else { return nil }
      let parts = s[r].split(separator: " ", maxSplits: 4)
      guard parts.count == 5, let n = Int(parts[1]) else { return nil }
      return (String(parts[4]).trimmingCharacters(in: .whitespaces), n)
    }
    func ours(_ f: String) -> Bool { f.hasPrefix("txs-bib.") }
    for (i, raw) in lines.enumerated() {
      let l = Substring(raw.trimmingCharacters(in: .whitespacesAndNewlines))
      if l.hasPrefix("Warning--") {
        var w = BibTeXIssue(severity: .warning, message: String(l.dropFirst(9)))
        if i + 1 < lines.count, let loc = location(Substring(lines[i + 1])), lines[i + 1].hasPrefix("--"), !ours(loc.file) {
          w.file = loc.file; w.line = loc.line
        }
        w.key = key(in: w.message)
        out.append(w)
      } else if let loc = location(l), !l.hasPrefix("--") {
        // an error: "<what>---line N of file F" (then BibTeX's context lines " : ...", skipped)
        let what = l[..<l.range(of: #"-{3}line \d+ of file"#, options: .regularExpression)!.lowerBound]
        var e = BibTeXIssue(severity: .error, message: String(what))
        if !ours(loc.file) { e.file = loc.file; e.line = loc.line }
        out.append(e)
      } else if l.hasPrefix("I couldn't open") || l.hasPrefix("I found no ") {
        // "I found no \citation commands---while reading file txs-bib.aux"
        let msg = l.components(separatedBy: "---while reading file")[0]
        if !out.contains(where: { $0.message == msg }) { out.append(BibTeXIssue(severity: .error, message: msg)) }
      }
    }
    return out
  }

  /// `I didn't find a database entry for "foo"` → foo; `empty journal in smith20` → smith20.
  static func key(in m: String) -> String? {
    if let r = m.range(of: #"database entry for "[^"]+""#, options: .regularExpression) {
      return String(m[r].dropFirst(#"database entry for ""#.count).dropLast())
    }
    if m.hasPrefix("empty ") || m.hasPrefix("can't use both "), let r = m.range(of: " in ", options: .backwards) {
      return String(m[r.upperBound...]).trimmingCharacters(in: .whitespaces)
    }
    return nil
  }
}
