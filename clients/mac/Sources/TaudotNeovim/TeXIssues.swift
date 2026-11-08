// TeX's errors and warnings as issues: parsed from the typesetter's output (TeXpresso's log stream, or the one-line
// summaries the PDF pane passes on today), told in plain words where we know the message, and published to Neovim as
// `vim.diagnostic` (namespace `taudot_tex`) so the user's signs, virtual text, ]d and Trouble show them.
import Foundation
import TaudotShared

public struct TeXIssue: Equatable, Sendable, Hashable {
  public enum Severity: Int, Sendable, Comparable {
    case error = 0, warning = 1, badbox = 2
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
  }
  public var severity: Severity
  /// Project-relative (as TeX names it), nil: the main file.
  public var file: String?
  /// 1-based.
  public var line: Int?
  /// TeX's text, one line ("Undefined control sequence", "LaTeX Error: File `x.sty' not found").
  public var message: String
  /// What TeX showed of the line up to the error (`l.12 A \foo` → "A \foo"); "..." in front when TeX cut it.
  public var context: String?

  public init(_ severity: Severity, file: String? = nil, line: Int? = nil, message: String, context: String? = nil) {
    self.severity = severity; self.file = file; self.line = line; self.message = message; self.context = context
  }

  /// The message in plain words, or nil when we don't know it (show TeX's).
  public var plain: String? { TeXIssue.plain(message, context: context) }

  /// 0-based column of the error spot in `source` (the line's text), from the context; nil if it can't be placed.
  public func column(in source: String) -> Int? {
    guard var c = context, !c.isEmpty else { return nil }
    if c.hasPrefix("...") {
      c.removeFirst(3)
      guard !c.isEmpty, let r = source.range(of: c) else { return nil }
      return source.distance(from: source.startIndex, to: r.upperBound)
    }
    guard source.hasPrefix(c) else {
      // TeX prints the line after its own processing (spaces collapsed): place it by the last word.
      let last = c.split(separator: " ").last.map(String.init) ?? c
      guard let r = source.range(of: last) else { return nil }
      return source.distance(from: source.startIndex, to: r.upperBound)
    }
    return c.count
  }

  /// "Ask Claude to fix all errors": one line (a newline would send it), every error with its lines and TeX's message.
  public static func claudePromptAll(_ xs: [TeXIssue], mainFile: String) -> String {
    let items = xs.map { x -> String in
      let f = x.file ?? mainFile
      guard let l = x.line else { return "@\(f): \(x.message)" }
      return "@\(f)#L\(max(1, l - 6))-\(l + 4) line \(l): \(x.message)"
    }
    if xs.allSatisfy({ $0.severity == .error }) {
      return "Fix these LaTeX errors: " + items.joined(separator: "; ") + ". Keep each change minimal; fix only these errors."
    }
    // errors and warnings: each item says which it is
    let tagged = zip(xs, items).map { x, i in (x.severity == .error ? "error " : "warning ") + i }
    return "Fix these LaTeX errors and warnings: " + tagged.joined(separator: "; ")
      + ". Keep each change minimal; fix only these. If fixing a warning would mean rewording the text (an overfull"
      + " line, say), leave it and tell me instead."
  }

  /// The prompt for "Ask Claude to fix": the lines around it as a Claude Code file reference, not sent.
  public func claudePrompt(mainFile: String) -> String {
    let f = file ?? mainFile
    let what = severity == .error ? "error" : "warning"
    guard let l = line else { return "Fix this LaTeX \(what) in @\(f): \(message). Keep the change minimal." }
    return "Fix this LaTeX \(what). @\(f)#L\(max(1, l - 6))-\(l + 4) \(what.capitalized) at line \(l): \(message). Keep the change minimal."
  }
}

// MARK: - plain words

extension TeXIssue {
  static func firstMatch(_ s: String, _ pattern: String) -> [String]? {
    guard let re = try? NSRegularExpression(pattern: pattern), let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
    return (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: s).map { String(s[$0]) } ?? "" }
  }

  /// The last control sequence in TeX's context ("A \foobar" → "\foobar").
  static func lastCommand(_ context: String?) -> String? {
    guard let c = context, let m = firstMatch(c, #"(\\[A-Za-z@]+\*?|\\.)\s*$"#) else { return nil }
    return m[1]
  }

  public static func plain(_ message: String, context: String? = nil) -> String? {
    let m = message.hasPrefix("LaTeX Error: ") ? String(message.dropFirst(13)) : message
    if m.hasPrefix("Too many }'s") || m.hasPrefix("Extra }, or forgotten") { return "There's a } with no matching {." }
    if m.hasPrefix("Undefined control sequence") {
      return lastCommand(context).map { "Unknown command \($0)." } ?? "Unknown command."
    }
    // BibTeX's (.blg)
    if let k = TeXIssue.firstMatch(m, #"^I didn't find a database entry for "([^"]+)""#) { return "No entry \(k[1]) in the .bib files." }
    if let k = TeXIssue.firstMatch(m, #"^empty (\w+) in (\S+)$"#) { return "\(k[2]) has an empty \(k[1])." }
    if let k = TeXIssue.firstMatch(m, #"^can't use both author and editor fields in (\S+)$"#) { return "\(k[1]) has both an author and an editor." }
    if m.hasPrefix("Repeated entry") { return "This entry is in the .bib twice." }
    if m.hasPrefix("I couldn't open database file") { return "Can't find the .bib file." }
    if m.hasPrefix("Missing $ inserted") { return "Math outside math mode: put it in $…$, or a $ is missing." }
    if m.hasPrefix("Display math should end with $$") { return "Display math isn't closed the way it was opened." }
    if m.hasPrefix("Missing } inserted") { return "A { is never closed." }
    if m.hasPrefix("Missing { inserted") { return "A { is missing." }
    if m.hasPrefix("Extra alignment tab") { return "Too many & in this row for the table's columns." }
    if m.hasPrefix("Misplaced alignment tab character") { return "An & outside a table or alignment (write \\& for the sign)." }
    if m.hasPrefix("Double superscript") { return "Two ^ in a row: group them with { }." }
    if m.hasPrefix("Double subscript") { return "Two _ in a row: group them with { }." }
    if m.hasPrefix("Missing number") { return "A number was expected here." }
    if m.hasPrefix("Illegal unit of measure") { return "A length needs a unit (pt, cm, em…)." }
    if m.hasPrefix("There's no line here to end") { return "A \\\\ with no line to end (after a blank line or at the start)." }
    if m.hasPrefix("Lonely \\item") { return "\\item outside a list (itemize, enumerate…)." }
    if m.hasPrefix("Something's wrong--perhaps a missing \\item") { return "A list needs an \\item before its text." }
    if m.hasPrefix("Missing \\begin{document}") { return "Text before \\begin{document}." }
    if m.hasPrefix("Can be used only in preamble") { return "This command only works before \\begin{document}." }
    if let x = firstMatch(m, #"^Paragraph ended before (\\\S+) was complete"#) { return "A blank line or } is missing inside the argument of \(x[1])." }
    if let x = firstMatch(m, #"^\\begin\{([^}]*)\} on input line (\d+) ended by \\end\{([^}]*)\}"#) {
      return "\\begin{\(x[1])} (line \(x[2])) isn't closed before \\end{\(x[3])}."
    }
    if let x = firstMatch(m, #"^\\begin\{([^}]*)\} ended by \\end\{([^}]*)\}"#) { return "\\end{\(x[2])} doesn't match \\begin{\(x[1])}." }
    if let x = firstMatch(m, #"^Environment (\S+) undefined"#) { return "Unknown environment \(x[1]) (a missing \\usepackage?)." }
    if let x = firstMatch(m, #"^File `([^']*)' not found"#) { return "Can't find the file \(x[1])." }
    if let x = firstMatch(m, #"^Unknown option `([^']*)' for package `([^']*)'"#) { return "The package \(x[2]) has no option \(x[1])." }
    if let x = firstMatch(m, #"^Command (\\\S+) already defined"#) { return "\(x[1]) is defined twice." }
    if let x = firstMatch(m, #"^Citation `([^']*)'.* undefined"#) { return "The citation \(x[1]) isn't in the bibliography." }
    if let x = firstMatch(m, #"^Reference `([^']*)'.* undefined"#) { return "No \\label{\(x[1])} for this reference." }
    if m.hasPrefix("Token not allowed in a PDF string") { return "Math or a command in a heading: the PDF's bookmarks leave it out (\\texorpdfstring{…}{…} gives them text)." }
    if let x = firstMatch(m, #"^Label `([^']*)' multiply defined"#) { return "\\label{\(x[1])} is used twice." }
    if let x = firstMatch(m, #"^Overfull \\[hv]box \(([\d.]+)pt too (wide|high)\)"#) {
      return "\(x[2] == "wide" ? "Line" : "Box") too \(x[2]) by \(Int((Double(x[1]) ?? 0).rounded()))pt."
    }
    if let x = firstMatch(m, #"^Underfull \\[hv]box \(badness (\d+)\)"#) { return "Loosely set \(m.contains("vbox") ? "page" : "line") (badness \(x[1]))." }
    return nil
  }
}

// MARK: - parsing

public enum TeXOutput {
  /// One PDF-pane summary: `main.tex:4: Too many }'s` (Tectonic's `Error:` line) or `! Too many }'s. l.4 Some text }`
  /// (TeX's own `!` line with its pointer).
  public static func summary(_ s: String) -> TeXIssue? {
    var t = s.trimmingCharacters(in: .whitespaces)
    guard !t.isEmpty else { return nil }
    var file: String?, line: Int?, context: String?
    if let m = TeXIssue.firstMatch(t, #"^([^\s:]+):(\d+):\s*(.*)$"#) {
      file = m[1]; line = Int(m[2]); t = m[3]
    }
    if t.hasPrefix("! ") { t.removeFirst(2) }
    if let m = TeXIssue.firstMatch(t, #"^(.*?)\s+l\.(\d+)(?: (.*))?$"#) {
      t = m[1]; line = line ?? Int(m[2]); context = m[3].isEmpty ? nil : m[3]
    }
    t = clean(t)
    guard !t.isEmpty, !noise(t) else { return nil }
    return TeXIssue(.error, file: file, line: line, message: t, context: context)
  }

  static func clean(_ s: String) -> String {
    var t = s.trimmingCharacters(in: .whitespaces)
    while t.hasPrefix("! ") { t.removeFirst(2) }
    if !t.hasSuffix("...") { while t.hasSuffix(".") { t.removeLast() } }
    return t
  }

  /// Follow-ups that say nothing the first error didn't.
  static func noise(_ m: String) -> Bool {
    m.hasPrefix("Emergency stop") || m.hasPrefix("==> Fatal error") || m.hasPrefix("Halted") || m.hasPrefix("halted on potentially-recoverable error")
      || m.hasPrefix("TeX capacity exceeded, sorry [error message")
  }

  /// TeX's log (lines of the last run: after its last `**`): errors with their `l.N` pointer, LaTeX and package
  /// warnings with their input line, over/underfull boxes, in the file TeX was reading.
  public static func parseLog(_ all: [String], main: String? = nil) -> [TeXIssue] {
    let lines = unwrap(Array(all[(all.lastIndex(of: "**").map { $0 + 1 } ?? 0)...]))
    var out: [TeXIssue] = []
    var stack: [String] = []
    var i = 0
    // the file TeX was reading, as the user knows it: the innermost .tex (an error raised inside a class or package
    // shows up at the user's line that loaded it)
    func current() -> String? {
      stack.last(where: isSourceFile)
    }
    while i < lines.count {
      let l = lines[i]
      if l.hasPrefix("! ") {
        var msg = String(l.dropFirst(2))
        var line: Int?, context: String?
        var j = i + 1
        // the message may wrap; the pointer `l.N text` comes within a few lines
        while j < lines.count && j < i + 12 {
          if let m = TeXIssue.firstMatch(lines[j], #"^l\.(\d+)(?: (.*))?$"#) { line = Int(m[1]); context = m[2].isEmpty ? nil : m[2]; break }
          if lines[j].hasPrefix("! ") { break }
          // a message TeX wrapped at its 79 columns goes on
          if j == i + 1, l.count >= 79, !lines[j].isEmpty { msg += lines[j] }
          j += 1
        }
        let m = clean(msg)
        if !noise(m) { out.append(TeXIssue(.error, file: current(), line: line, message: m, context: context)) }
        i += 1
        continue
      }
      if let m = TeXIssue.firstMatch(l, #"^(?:LaTeX|Package [\w.-]+|Class [\w.-]+|LaTeX Font) Warning: (.*)$"#) {
        // continued on the next lines until a blank one; package warnings continue with `(pkg)  `
        var text = m[1]
        var j = i + 1
        while j < lines.count, !lines[j].trimmingCharacters(in: .whitespaces).isEmpty {
          let c = lines[j].replacingOccurrences(of: #"^\([\w.-]+\)\s+"#, with: "", options: .regularExpression)
          text += (text.hasSuffix(" ") || c.hasPrefix(" ") ? "" : " ") + c
          j += 1
        }
        var line: Int?
        if let n = TeXIssue.firstMatch(text, #"on input line (\d+)\.?$"#) { line = Int(n[1]); text = text.replacingOccurrences(of: #"\s*on input line \d+\.?$"#, with: "", options: .regularExpression) }
        if !summaryWarning(text) {
          out.append(TeXIssue(.warning, file: current(), line: line, message: clean(text)))
        }
        i = j
        continue
      }
      if let m = TeXIssue.firstMatch(l, #"^((?:Over|Under)full \\[hv]box \([^)]*\)).*?(?:at lines? (\d+))?(?:--\d+)?$"#) {
        out.append(TeXIssue(.badbox, file: current(), line: Int(m[2]), message: m[1]))
        // then TeX shows the box's contents up to a blank line: text, not files (its "(" and ")" are the document's)
        i += 1
        while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty, !lines[i].hasPrefix("! ") { i += 1 }
        continue
      }
      track(l, &stack)
      i += 1
    }
    return dedupe(out, main: main)
  }

  /// Errors TeX raises because of an earlier one on the same line: a missing file's name is then run as a command.
  static func followUp(_ x: TeXIssue, after earlier: [TeXIssue]) -> Bool {
    x.severity == .error && key(x.message).hasPrefix("Undefined control sequence")
      && earlier.contains { $0.line == x.line && ($0.file == x.file || $0.file == nil || x.file == nil) && key($0.message).contains("not found") }
  }

  /// TeX breaks its log lines at 79 characters: a line exactly that long goes on in the next one (not when it ends
  /// in "...", TeX's own cut, or the next starts an error).
  static func unwrap(_ ls: [String]) -> [String] {
    var out: [String] = []
    for l in ls {
      if let p = out.last, p.count == 79, !p.hasSuffix("..."), !l.hasPrefix("!") { out[out.count - 1] += l } else { out.append(l) }
    }
    return out
  }

  /// A warning that asks for another pass (LaTeX's, hyperref's, natbib's, rerunfilecheck's).
  public static func asksRerun(_ t: String) -> Bool {
    t.contains("Rerun to get") || t.hasPrefix("Label(s) may have changed") || t.hasPrefix("Citation(s) may have changed")
      || (t.hasPrefix("File `") && t.contains("has changed"))
  }

  static func summaryWarning(_ t: String) -> Bool {
    t.hasPrefix("There were undefined references") || t.hasPrefix("There were multiply-defined labels")
      || t.hasPrefix("Some font shapes were not available")
  }

  /// A name on TeX's file stack that is one of the user's sources: a .tex file, or a path without an extension
  /// (`\input{sec/intro}`). Not a parenthesis in the document's text that a box or message shows ("(Aside: …").
  static func isSourceFile(_ n: String) -> Bool {
    guard !n.isEmpty, n != ".", n.first != "." || n.hasPrefix("./") else { return false }
    let e = (n as NSString).pathExtension
    return e == "tex" || (e.isEmpty && n.contains("/") && !n.hasSuffix("/"))
  }

  /// TeX's `(file` / `)` file stack in a log line (best effort: TeX wraps long lines at 79 columns).
  static func track(_ l: String, _ stack: inout [String]) {
    var s = Substring(l)
    while let c = s.first {
      if c == "(" {
        s = s.dropFirst()
        let name = s.prefix { !$0.isWhitespace && $0 != ")" && $0 != "(" }
        stack.append(String(name))
        s = s.dropFirst(name.count)
      } else if c == ")" {
        if !stack.isEmpty { stack.removeLast() }
        s = s.dropFirst()
      } else {
        s = s.dropFirst()
      }
    }
  }

  /// One issue per (file, line, message); a file TeX names the main file is nil; errors first, then by place.
  public static func dedupe(_ xs: [TeXIssue], main: String? = nil) -> [TeXIssue] {
    var seen: [TeXIssue] = []
    for var x in xs {
      if let f = x.file {
        var n = f.hasPrefix("./") ? String(f.dropFirst(2)) : f
        if !n.contains(".") { n += ".tex" }
        x.file = (n == main || n == "main.tex" && main == nil) ? nil : n
      }
      if let k = seen.firstIndex(where: { same($0, x) }) {
        // the same error from two sources: keep what each knows
        if seen[k].context == nil { seen[k].context = x.context }
        if seen[k].file == nil { seen[k].file = x.file }
        continue
      }
      seen.append(x)
    }
    let all = seen
    seen.removeAll { followUp($0, after: all) }
    return seen.enumerated().sorted { a, b in
      if a.element.severity != b.element.severity { return a.element.severity < b.element.severity }
      return a.offset < b.offset
    }.map(\.element)
  }

  static func key(_ m: String) -> String {
    var t = m.hasPrefix("! ") ? String(m.dropFirst(2)) : m
    t = clean(t)
    if t.hasPrefix("! ") { t.removeFirst(2) }
    return t
  }

  public static func same(_ a: TeXIssue, _ b: TeXIssue) -> Bool {
    a.severity == b.severity && a.line == b.line && key(a.message) == key(b.message)
      && (a.file == b.file || a.file == nil || b.file == nil)
  }
}

/// TeXpresso's log buffer, kept from its `append-lines` / `truncate-lines` events (one element per line; a rollback
/// keeps the first N lines).
public struct TeXLogBuffer: Sendable {
  public private(set) var lines: [String] = []
  public init() {}
  /// `["append-lines", "log", …]` or `["truncate-lines", "log", N]`; other buffers are ignored. True if it changed.
  @discardableResult public mutating func apply(_ event: [Any]) -> Bool {
    guard event.count >= 3, event[1] as? String == "log", let kind = event[0] as? String else { return false }
    if kind == "append-lines" {
      for case let s as String in event.dropFirst(2) { lines.append(s.hasPrefix("\n") ? String(s.dropFirst()) : s) }
      return true
    }
    if kind == "truncate-lines", let n = (event[2] as? NSNumber)?.intValue {
      if n < lines.count { lines.removeLast(lines.count - n); return true }
    }
    return false
  }
  /// A log event cut by another process's stderr line (`… on in[info] synctex used 5 input files…`, the rest of
  /// the event up to ~20 lines later): the part before the intruder, waiting for its rest (40 lines at most).
  private var partial: String?
  private var partialAge = 0

  /// One stderr line of the driver (all of them may be passed; only the log's events count). True if the log changed.
  @discardableResult public mutating func apply(line: String) -> Bool {
    if let p = partial {
      if let a = Self.parse(p + line) { partial = nil; return apply(a) }
      partialAge += 1
      if partialAge > 40 { partial = nil }
    }
    guard line.hasPrefix("[\"append-lines\", \"log\"") || line.hasPrefix("[\"truncate-lines\", \"log\"") else { return false }
    if let a = Self.parse(line) { return apply(a) }
    // cut: keep it up to where the intruding line starts (`[info] `, `[synctex] `…), or whole
    var cut = line
    if let r = line.range(of: #"\[[a-z]+\] "#, options: .regularExpression, range: line.index(line.startIndex, offsetBy: 2)..<line.endIndex) {
      cut = String(line[..<r.lowerBound])
    }
    partial = cut
    partialAge = 0
    return false
  }

  /// TeXpresso writes some control characters raw inside its JSON strings: escaped before parsing.
  static func parse(_ line: String) -> [Any]? {
    var s = ""
    s.reserveCapacity(line.utf8.count)
    for u in line.unicodeScalars {
      if u.value < 0x20 { s += String(format: "\\u%04x", u.value) } else { s.unicodeScalars.append(u) }
    }
    return (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [Any]
  }
}

// MARK: - Neovim

public enum TeXDiagnostics {
  /// The `taudot.tex_errors` module, registered in the app's Neovim: `set(byfile)` with {abs path = {{lnum, col,
  /// severity, message, code}}} (0-based lnum/col, severity 1 error … 3 info); buffers loaded later get theirs on
  /// BufReadPost / BufWinEnter; files that are no longer listed are cleared. Matched by realpath.
  public static let lua = """
  package.preload['taudot.tex_errors'] = function()
    local M = {}
    local api = vim.api
    local ns = api.nvim_create_namespace('taudot_tex')
    M.ns = ns
    M.byfile = {}
    local function real(p)
      if p == nil or p == '' then return '' end
      return vim.uv.fs_realpath(p) or vim.fs.normalize(p)
    end
    local function apply(buf)
      if not api.nvim_buf_is_valid(buf) then return end
      local list = M.byfile[real(api.nvim_buf_get_name(buf))]
      if not list then vim.diagnostic.reset(ns, buf); return end
      local n = api.nvim_buf_line_count(buf)
      local ds = {}
      for _, d in ipairs(list) do
        local lnum = math.max(0, math.min(d[1], n - 1))
        local text = api.nvim_buf_get_lines(buf, lnum, lnum + 1, false)[1] or ''
        local col = math.max(0, math.min(d[2], #text))
        local ecol = col
        if col > 0 then
          -- the token before TeX's spot (a command: back to its backslash), else to the end of the line
          local s = text:sub(1, col):find('\\\\[%a@]*%*?$') or text:sub(1, col):find('%S+$')
          if s then col = s - 1; ecol = math.max(ecol, col + 1) end
        else
          ecol = #text
        end
        ds[#ds + 1] = { lnum = lnum, col = col, end_lnum = lnum, end_col = ecol, severity = d[3], message = d[4],
                        source = 'TeX', code = d[5] }
      end
      vim.diagnostic.set(ns, buf, ds)
    end
    function M.set(byfile)
      local new = {}
      for path, list in pairs(byfile or {}) do new[real(path)] = list end
      M.byfile = new
      for _, b in ipairs(api.nvim_list_bufs()) do
        if api.nvim_buf_is_loaded(b) then apply(b) end
      end
    end
    local g = api.nvim_create_augroup('taudot_tex_errors', { clear = true })
    api.nvim_create_autocmd({ 'BufReadPost', 'BufWinEnter' }, { group = g, callback = function(a)
      if next(M.byfile) then apply(a.buf) end
    end })
    return M
  end
  """

  /// The argument of `require('taudot.tex_errors').set(...)` for these issues: absolute path → diagnostics.
  public static func payload(_ issues: [TeXIssue], folder: URL, mainFile: String, sources: (String, Int) -> String?) -> Value {
    var byfile: [String: [Value]] = [:]
    for x in issues {
      let f = x.file ?? mainFile
      let abs = f.hasPrefix("/") ? f : folder.appendingPathComponent(f).path
      let lnum = max(0, (x.line ?? 1) - 1)
      let col = x.line.flatMap { sources(f, $0) }.flatMap { x.column(in: $0) } ?? 0
      let sev: Int64 = x.severity == .error ? 1 : x.severity == .warning ? 2 : 3
      let msg = x.plain.map { $0 + "  (" + x.message + ")" } ?? x.message
      byfile[abs, default: []].append(.array([.int(Int64(lnum)), .int(Int64(col)), .int(sev), .string(msg), .string(x.message)]))
    }
    return .map(byfile.map { (.string($0.key), .array($0.value)) })
  }
}
