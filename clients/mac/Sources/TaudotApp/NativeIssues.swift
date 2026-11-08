// Native editor mode: the typeset's errors and warnings (`issues.shown`) as marks in the text: a wavy underline, a
// dot in the margin, and a card with "Ask Claude to fix" (TaudotEditor/Issues.swift draws them). Neovim mode gets
// `vim.diagnostic` instead (publishDiagnostics).
import AppKit
import TaudotEditor
import TaudotNeovim

extension ProjectWindow {
  /// Called with every new list (`showIssues`); an empty one clears the marks.
  func showNativeIssues(_ xs: [TeXIssue]) {
    guard let native else { return }
    native.setIssues(Self.editorIssues(xs, mainFile: mainFile ?? "main.tex") { [weak self, native] f, l in self?.sourceLine(f, l) ?? native.lineText(path: f, line: l) })
  }

  /// "Ask Claude to fix" on a card: the prompt with the line where the mark is now, typed into Claude (not sent).
  func wireNativeIssues() {
    native?.onAskClaude = { [weak self] _, prompt in self?.askClaude(prompt: prompt) }
  }

  /// The app's issues as the editor marks them: the main file for an issue TeX didn't name, TeX's context turned into
  /// a UTF-8 column in the line as the typesetter had it, badboxes as warnings. Issues without a line aren't marked
  /// (they stay in the strip).
  nonisolated static func editorIssues(_ xs: [TeXIssue], mainFile: String, sourceLine: (String, Int) -> String?) -> [EditorIssue] {
    xs.compactMap { x in
      guard let l = x.line, l >= 1 else { return nil }
      let path = x.file ?? mainFile
      let column = sourceLine(path, l).flatMap { src in x.column(in: src).map { String(src.prefix($0)).utf8.count } }
      return EditorIssue(severity: x.severity == .error ? .error : .warning, path: path, line: l, column: column,
                         message: x.message, plain: x.plain)
    }
  }
}

extension NativeCheck {
  /// TeX's errors as marks in the native text (editor agent): a typeset's issues (`issues.shown`) reach the editor as
  /// a wavy underline and a margin dot, the card on the caret's line says it in plain words, "Ask Claude to fix" types
  /// the prompt into Claude (TAUDOT_CLAUDE, a fake in the script), and a clean run clears them.
  func nativeIssues(_ ed: NativeEditor) async {
    let ns = ed.view.textView.string as NSString
    let lines = ns.components(separatedBy: "\n")
    var starts = [0]
    for l in lines.dropLast() { starts.append(starts.last! + (l as NSString).length + 1) }
    // a line with a command on it (not line 1, which gets the other error); TeX's context: the line up to its end
    let re = try! NSRegularExpression(pattern: #"\\[A-Za-z]+"#)
    guard let (n, cmd) = lines.indices.dropFirst().prefix(80).lazy.compactMap({ i -> (Int, NSRange)? in
      re.firstMatch(in: lines[i], range: NSRange(location: 0, length: (lines[i] as NSString).length)).map { (i, $0.range) }
    }).first, !lines[0].trimmingCharacters(in: CharacterSet.whitespaces).isEmpty else {
      check(false, "issues: no line with a command in the first 80"); return
    }
    let line = lines[n] as NSString
    let context = line.substring(to: NSMaxRange(cmd))
    let name = line.substring(with: cmd)
    p.issues.settle = 0.2
    p.pdf.onStatus?("TeX: main.tex:\(n + 1): Undefined control sequence")
    p.pdf.onStatus?("TeX: ! Undefined control sequence. l.\(n + 1) \(context)")
    p.pdf.onStatus?("TeX: main.tex:1: Too many }'s")
    p.pdf.onStatus?("1 page, typeset in 11 ms")
    var marks: [NSRange] = []
    for _ in 0..<30 where marks.count < 2 { await sleep(0.1); marks = ed.view.issueMarks }
    let want = NSRange(location: starts[n] + cmd.location, length: cmd.length)
    check(p.issues.shown.count == 2 && marks.count == 2, "issues: the typeset's 2 issues are marked in the text (\(p.issues.shown.count) shown, \(marks.count) marked)")
    check(marks.contains(want), "issues: the mark is on \(name), where TeX stopped (want \(want), got \(marks))")
    let lead = (lines[0] as NSString).length - (lines[0].drop { $0 == " " || $0 == "\t" } as Substring).utf16.count
    check(marks.contains { $0.location == lead && NSMaxRange($0) == (lines[0] as NSString).length },
          "issues: without TeX's context, the whole line is marked (line 1)")
    ed.view.textView.setSelectedRange(NSRange(location: starts[n], length: 0))
    await sleep(0.3)
    check(ed.view.issueCardText == "Unknown command \(name).", "issues: the caret on the line opens the card in plain words (\"\(ed.view.issueCardText)\")")
    ed.view.pressAskClaude()
    let prompt = "Fix this LaTeX error. @main.tex#L\(max(1, n + 1 - 6))-\(n + 1 + 4) Error at line \(n + 1): Undefined control sequence."
    var typed = ""
    for _ in 0..<60 where !typed.filter({ !$0.isWhitespace }).contains(prompt.filter { !$0.isWhitespace }) { await sleep(0.1); typed = await p.claude?.text() ?? "" }
    func flat(_ s: String) -> String { s.filter { !$0.isWhitespace } }
    check(flat(typed).contains(flat(prompt)) && p.focusedPane == 3, "issues: Ask Claude to fix types the prompt into Claude, not sent (\(typed.suffix(160)))")
    await press("2")
    // a clean run as the live pdfTeX reports it: its log (no errors), then the status. Without a log, issues whose line
    // still reads the same are kept (the run may not have reached them), so a bare status wouldn't clear them.
    p.issues.driverLine(#"["append-lines", "log", "**main.tex", "\n(./main.tex", "\nOutput written on main.pdf (1 page)."]"#)
    p.pdf.onStatus?("1 page, typeset in 9 ms")
    for _ in 0..<30 where !(ed.view.issueMarks.isEmpty && ed.view.issueCardText.isEmpty) { await sleep(0.1) }
    check(ed.view.issueMarks.isEmpty && ed.view.issueCardText.isEmpty,
          "issues: a clean run clears the marks and the card (marks \(ed.view.issueMarks), card \"\(ed.view.issueCardText)\", shown \(p.issues.shown.map(\.message)))")
  }
}
