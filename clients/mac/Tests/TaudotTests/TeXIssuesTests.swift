// TeX errors and warnings from real TeXpresso output (Tests/tex-logs: the driver's stderr for small broken documents,
// with the lines its other processes write into it, and the documents), merged with the one-line summaries the PDF
// pane passes on today; plain words; the Claude prompt; the diagnostics in a real Neovim.
import Foundation
import Testing
@testable import TaudotNeovim
import TaudotShared

private let logs = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../tex-logs").standardized

/// The log's issues and the `Error:` summaries, merged as the app does.
private func corpus(_ name: String) -> (issues: [TeXIssue], source: [String]) {
  let raw = (try? String(contentsOf: logs.appendingPathComponent(name + ".txt"), encoding: .utf8)) ?? ""
  var b = TeXLogBuffer()
  var sums: [TeXIssue] = []
  for l in raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
    b.apply(line: l)
    if l.hasPrefix("Error: "), let x = TeXOutput.summary(String(l.dropFirst(7))) { sums.append(x) }
  }
  let src = ((try? String(contentsOf: logs.appendingPathComponent(name + ".tex"), encoding: .utf8)) ?? "").components(separatedBy: "\n")
  // as the app shows them: a pass's rerun notices are for the app to wait on, not issues
  let xs = TeXOutput.dedupe(TeXOutput.parseLog(b.lines, main: "main.tex") + sums, main: "main.tex")
  return (xs.filter { !TeXOutput.asksRerun($0.message) }, src)
}

private func errors(_ xs: [TeXIssue]) -> [TeXIssue] { xs.filter { $0.severity == .error } }

@Suite struct TeXIssuesTests {
  @Test func unbalancedBraces() throws {
    let c = corpus("braces")
    let e = try #require(errors(c.issues).first)
    #expect(errors(c.issues).count == 1)
    #expect(e.line == 4 && e.file == nil)
    #expect(e.message == "Too many }'s")
    #expect(e.plain == "There's a } with no matching {.")
    #expect(e.column(in: c.source[3]) == 11)  // "Some text }|"
  }

  @Test func undefinedControlSequence() throws {
    let c = corpus("undefined")
    let e = try #require(errors(c.issues).first)
    #expect(errors(c.issues).count == 1)
    #expect(e.line == 4 && e.plain == "Unknown command \\foobar.")
    #expect(e.column(in: c.source[3]) == 9)  // "A \foobar|"
  }

  @Test func missingDollar() {
    let es = errors(corpus("dollar").issues)
    #expect(es.map(\.line) == [4, 5])
    #expect(es.allSatisfy { $0.plain?.hasPrefix("Math outside math mode") == true })
  }

  @Test func missingEnd() throws {
    let e = try #require(errors(corpus("noend").issues).first)
    #expect(e.line == 5)
    #expect(e.plain == "\\begin{itemize} (line 3) isn't closed before \\end{document}.")
  }

  @Test func fileNotFound() {
    // the follow-up "Undefined control sequence" errors on the same line are dropped
    let es = errors(corpus("nofile").issues)
    #expect(es.count == 1)
    #expect(es.first?.line == 4 && es.first?.plain == "Can't find the file chapters/missing.tex.")
    let pk = errors(corpus("nopkg").issues)
    #expect(pk.count == 1 && pk.first?.plain == "Can't find the file nosuchpackage.sty.")
  }

  @Test func undefinedCitationAndReferenceAreWarnings() {
    let xs = corpus("cite").issues
    #expect(errors(xs).isEmpty)
    #expect(xs.filter { $0.severity == .warning }.compactMap(\.plain) == [
      "The citation knuth84 isn't in the bibliography.", "No \\label{sec:nope} for this reference.",
    ])
    #expect(xs.filter { $0.severity == .warning }.allSatisfy { $0.line == 3 })
    let box = xs.first { $0.severity == .badbox }
    #expect(box?.line == 4 && box?.plain == "Line too wide by 145pt.")
  }

  @Test func errorInAnInputFile() throws {
    let e = try #require(errors(corpus("subfile").issues).first)
    #expect(e.file == "sec/intro.tex" && e.line == 2)
    #expect(e.plain == "Unknown command \\badmacro.")  // the log's context, merged into the summary's
  }

  @Test func runawayArgument() {
    let es = errors(corpus("parend").issues)
    #expect(es.map(\.line) == [5, 5])
    #expect(es.first?.plain == "A blank line or } is missing inside the argument of \\text@command.")
  }

  @Test func labelsAndBoxes() {
    let xs = corpus("label2").issues
    #expect(xs.contains { $0.severity == .warning && $0.plain == "\\label{s} is used twice." })
    #expect(xs.filter { $0.severity == .badbox }.map(\.line) == [5, 6])
    let pk = corpus("pkgwarn").issues
    #expect(errors(pk).isEmpty && pk.contains { $0.severity == .warning && $0.line == 5 })
  }

  @Test func boxContentsAreNotFiles() {
    // A box's contents (shown after an over/underfull warning) are the document's text: its parentheses, balanced or
    // not ("(Aside: …", "(see"), aren't files. Seen on a real paper: every later issue went to a file "Aside:.tex".
    let log = ["**", "(main.tex", "LaTeX2e <2021-11-15>", "(article.cls", "Document Class: article", ")",
               "Overfull \\hbox (5.0pt too wide) in paragraph at lines 10--12",
               "[]\\TU/ptm/b/n/10 (Aside: a heading set in bold", "",
               "LaTeX Warning: Reference `x' on page 1 undefined on input line 20.", "",
               "Underfull \\hbox (badness 10000) in paragraph at lines 30--31",
               "[]\\TU/lmr/m/n/10 text (see", "[]\\TU/lmr/m/n/10 more", "",
               "(sec/intro.tex", "LaTeX Warning: Citation `k' on page 1 undefined on input line 2.", "", ")",
               "(HO text) (3.1.9a)", "LaTeX Warning: Reference `y' on page 1 undefined on input line 40.", "", ")"]
    let xs = TeXOutput.parseLog(log, main: "main.tex")
    let w = xs.filter { $0.severity == .warning }
    #expect(w.map(\.line) == [20, 2, 40])
    #expect(w.map(\.file) == [nil, "sec/intro.tex", nil])
    #expect(xs.filter { $0.severity == .badbox }.allSatisfy { $0.file == nil })
    #expect(!TeXOutput.isSourceFile("Aside:") && !TeXOutput.isSourceFile("HO") && !TeXOutput.isSourceFile("3.1.9a"))
    #expect(TeXOutput.isSourceFile("main.tex") && TeXOutput.isSourceFile("./sec/a.tex") && TeXOutput.isSourceFile("sec/intro"))
  }

  @Test func wrappedLogLines() {
    // TeX cut the warning at 79 characters, inside a word and before its line number
    let a = "LaTeX Warning: Citation `knuth1986texbookvol' on page 2 undefined on input line"
    #expect(a.count == 79)
    let l79 = String(a.prefix(79))
    let ys = TeXOutput.parseLog(["**", "(main.tex", l79, " 165.", "", ")"], main: "main.tex")
    #expect(ys.first?.line == 165 && ys.first?.message == "Citation `knuth1986texbookvol' on page 2 undefined")
    // rerun notices stay in the parse (the app waits on them)
    let r = TeXOutput.parseLog(["**", "(main.tex", "LaTeX Warning: Label(s) may have changed. Rerun to get cross-references right.", "", ")"])
    #expect(r.count == 1 && TeXOutput.asksRerun(r[0].message))
  }

  @Test func errorsComeFirst() {
    let xs = TeXOutput.dedupe([TeXIssue(.badbox, line: 1, message: "Overfull \\hbox (3pt too wide)"),
                               TeXIssue(.warning, line: 2, message: "Citation `a' undefined"),
                               TeXIssue(.error, line: 9, message: "Missing $ inserted")])
    #expect(xs.map(\.severity) == [.error, .warning, .badbox])
  }

  @Test func summaries() throws {
    // Tectonic's `Error:` line, and TeX's `!` line with its pointer (Txp's two forms)
    let a = try #require(TeXOutput.summary("main.tex:536: Extra }, or forgotten \\endgroup"))
    #expect(a.line == 536 && a.file == "main.tex" && a.message == "Extra }, or forgotten \\endgroup")
    #expect(a.plain == "There's a } with no matching {.")
    let b = try #require(TeXOutput.summary("! Undefined control sequence. l.12 \\foo"))
    #expect(b.line == 12 && b.context == "\\foo" && b.plain == "Unknown command \\foo.")
    let c = try #require(TeXOutput.summary("sec/intro:2: Undefined control sequence"))
    #expect(TeXOutput.dedupe([c]).first?.file == "sec/intro.tex")
    #expect(TeXOutput.summary("main.tex:9: Emergency stop") == nil)
    // the same error from both: one, with the pointer's context and the summary's file
    let m = TeXOutput.dedupe([b, TeXIssue(.error, file: "ch.tex", line: 12, message: "Undefined control sequence")])
    #expect(m.count == 1 && m.first?.file == "ch.tex" && m.first?.context == "\\foo")
  }

  @Test func claudePrompt() {
    let e = TeXIssue(.error, line: 536, message: "Extra }, or forgotten \\endgroup")
    #expect(e.claudePrompt(mainFile: "main.tex")
      == "Fix this LaTeX error. @main.tex#L530-540 Error at line 536: Extra }, or forgotten \\endgroup. Keep the change minimal.")
    let w = TeXIssue(.warning, file: "sec/a.tex", line: 2, message: "Citation `x' undefined")
    #expect(w.claudePrompt(mainFile: "main.tex").hasPrefix("Fix this LaTeX warning. @sec/a.tex#L1-6 Warning at line 2:"))
  }

  @Test func claudePromptForAllErrors() {
    let xs = [TeXIssue(.error, line: 5, message: "Undefined control sequence"),
              TeXIssue(.error, file: "sec/a.tex", line: 2, message: "Too many }'s")]
    let p = TeXIssue.claudePromptAll(xs, mainFile: "main.tex")
    #expect(p == "Fix these LaTeX errors: @main.tex#L1-9 line 5: Undefined control sequence; @sec/a.tex#L1-6 line 2: Too many }'s. Keep each change minimal; fix only these errors.")
    var mixed = xs
    mixed.append(TeXIssue(.warning, line: 7, message: "Reference `x' undefined"))
    let q = TeXIssue.claudePromptAll(mixed, mainFile: "main.tex")
    #expect(q.hasPrefix("Fix these LaTeX errors and warnings: error @main.tex#L1-9 line 5: Undefined control sequence;"))
    #expect(q.contains("; warning @main.tex#L1-11 line 7: Reference `x' undefined."))
    #expect(!p.contains("\n"))  // one line: a newline would send it
  }

  @Test func logBufferFollowsRollbacks() {
    var b = TeXLogBuffer()
    b.apply(line: #"["append-lines", "log", "**", "\n(main.tex", "\n! Too many }'s."]"#)
    #expect(b.lines == ["**", "(main.tex", "! Too many }'s."])
    b.apply(line: #"["truncate-lines", "log", 2]"#)
    #expect(b.lines == ["**", "(main.tex"])
    b.apply(line: #"["append-lines", "out", "ignored"]"#)
    // cut by another process's line, the rest later; raw control characters inside
    b.apply(line: "[\"append-lines\", \"log\", \"a\u{0c}b\", \"\\n[info] synctex used 4 input files")
    b.apply(line: "[synctex] Closed input: 4")
    b.apply(line: "c\"]")
    #expect(b.lines == ["**", "(main.tex", "a\u{0c}b", "c"])
  }

  @Test func plainWordsForCommonErrors() {
    #expect(TeXIssue.plain("Missing } inserted") == "A { is never closed.")
    #expect(TeXIssue.plain("LaTeX Error: Environment foo undefined") == "Unknown environment foo (a missing \\usepackage?).")
    #expect(TeXIssue.plain("Double superscript") == "Two ^ in a row: group them with { }.")
    #expect(TeXIssue.plain("Something new") == nil)
    // BibTeX's (.blg, through TaudotPDFPane.onBibIssues)
    #expect(TeXIssue.plain("I didn't find a database entry for \"knuth84\"") == "No entry knuth84 in the .bib files.")
    #expect(TeXIssue.plain("empty journal in lamport94") == "lamport94 has an empty journal.")
  }

  @Test @MainActor func neovimDiagnostics() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("txs-diag-\(UUID().uuidString.prefix(6))")
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("sec"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try "\\documentclass{article}\n\\begin{document}\nHello.\nA \\foobar command.\n\\end{document}\n".write(to: dir.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
    try "One.\nTwo \\bad.\n".write(to: dir.appendingPathComponent("sec/b.tex"), atomically: true, encoding: .utf8)
    let nv = try Neovim(args: ["--clean", "--headless", "-n"])
    defer { nv.terminate() }
    _ = try await nv.execLua(TeXDiagnostics.lua, [])
    try await nv.command("edit " + dir.appendingPathComponent("main.tex").path)
    let issues = [TeXIssue(.error, line: 4, message: "Undefined control sequence", context: "A \\foobar"),
                  TeXIssue(.warning, file: "sec/b.tex", line: 2, message: "Citation `k' undefined")]
    let src: (String, Int) -> String? = { f, l in
      (try? String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8))?.components(separatedBy: "\n")[l - 1]
    }
    let set = "require('taudot.tex_errors').set(...)"
    _ = try await nv.execLua(set, [TeXDiagnostics.payload(issues, folder: dir, mainFile: "main.tex", sources: src)])
    let get = "local ns = require('taudot.tex_errors').ns; return vim.tbl_map(function(d) return {d.lnum, d.col, d.end_col, d.severity, d.message} end, vim.diagnostic.get(0, {namespace = ns}))"
    let d = try await nv.execLua(get, [])
    // the command's span on line 4, error severity, plain words then TeX's text
    #expect(d == .array([.array([.int(3), .int(2), .int(9), .int(1), .string("Unknown command \\foobar.  (Undefined control sequence)")])]))
    // a file opened later gets its warning
    try await nv.command("edit " + dir.appendingPathComponent("sec/b.tex").path)
    let w = try await nv.execLua(get, [])
    let w0 = w.array?.first?.array ?? []
    #expect(w0.count == 5 && w0[0] == .int(1) && w0[3] == .int(2))
    // a clean run clears them
    _ = try await nv.execLua(set, [.map([])])
    #expect(try await nv.execLua("return #vim.diagnostic.get(nil, {namespace = require('taudot.tex_errors').ns})", []) == .int(0))
  }
}

/// A tool, not a test: TAUDOT_TEXLOG_DUMP=STDERR_FILE parses a captured txp-render stderr as the app does and writes
/// STDERR_FILE.log (TeX's log rebuilt) and STDERR_FILE.issues (one issue per line). Skipped otherwise.
@Test(.enabled(if: ProcessInfo.processInfo.environment["TAUDOT_TEXLOG_DUMP"] != nil))
func dumpIssuesFromCapturedStderr() throws {
  let path = ProcessInfo.processInfo.environment["TAUDOT_TEXLOG_DUMP"]!
  let main = ProcessInfo.processInfo.environment["TAUDOT_TEXLOG_MAIN"] ?? "main.tex"
  let raw = try String(contentsOfFile: path, encoding: .utf8)
  var b = TeXLogBuffer()
  var sums: [TeXIssue] = []
  for l in raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
    b.apply(line: l)
    if l.hasPrefix("Error: "), let x = TeXOutput.summary(String(l.dropFirst(7))) { sums.append(x) }
  }
  try b.lines.joined(separator: "\n").write(toFile: path + ".log", atomically: true, encoding: .utf8)
  let xs = TeXOutput.dedupe(TeXOutput.parseLog(b.lines, main: main) + sums, main: main)
  let out = xs.map { "\($0.severity) \($0.file ?? main):\($0.line.map(String.init) ?? "-") \($0.message)" }
  try out.joined(separator: "\n").write(toFile: path + ".issues", atomically: true, encoding: .utf8)
}
