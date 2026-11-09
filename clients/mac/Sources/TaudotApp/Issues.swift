// LaTeX errors and warnings (docs/agents/errors.md): the run's issues gathered from the PDF pane, shown in the issues
// strip (over the PDF, or atop the editor column while the PDF is hidden; ⌥⌘E expands it), published to Neovim as
// diagnostics, and handed to Claude ("Ask Claude to fix": the prompt typed at the Claude pane, not sent).
import AppKit
import SwiftUI
import TaudotNeovim
import TaudotPDF
import TaudotShared

/// The issues of the last completed run, errors and warnings (not badboxes). New ones wait until runs have stopped for
/// `settle` seconds (a half-typed line, a first pass without .aux, don't flash); fewer or the same show at once.
///
/// Without TeXpresso's log (`driverLine`, from the PDF pane's `onDriverLine`; e.g. before its first line) a run only reports the errors it typeset
/// again: TeXpresso restarts from a snapshot after an edit, so an error before that point isn't repeated. An issue
/// therefore stays while its source line is unchanged and no run reported it fixed; with the log, the log decides.
@MainActor final class IssuesModel {
  private(set) var shown: [TeXIssue] = []
  /// (issues, pulse: a new error came)
  var onChange: (([TeXIssue], Bool) -> Void)?
  var mainFileName: () -> String = { "main.tex" }
  var mainFile: String { mainFileName() }
  var settle: TimeInterval = 1.5
  /// How long a pass that asks for a rerun waits for the next one.
  var rerunWait: TimeInterval = 8
  /// Over/underfull boxes listed: on with the live pdfTeX (its line breaks are Overleaf's), off with TeXpresso (XeTeX
  /// breaks lines its own way, so its box warnings aren't the document's).
  var showBadboxes = false
  private var summaries: [TeXIssue] = []
  /// The last run's TeX issues (shown or waiting to), and BibTeX's last list.
  private var tex: [TeXIssue] = []
  private var bib: [TeXIssue] = []
  /// Where each citation key is cited (file nil: the main file), for BibTeX's missing entries: one call per list.
  var citeLocations: ([String]) -> [String: (file: String?, line: Int)] = { _ in [:] }
  private var log = TeXLogBuffer()
  private(set) var hasLog = false
  private var timer: Timer?
  /// The text of an issue's line as typeset (the PDF pane's sources), and what it was when the issue showed.
  var lineText: (TeXIssue) -> String? = { _ in nil }
  private var snaps: [TeXIssue: String] = [:]

  /// A "TeX: …" status of the PDF pane (Tectonic's `file:line: message`, or TeX's `! message l.N …`).
  func summary(_ s: String) {
    if let x = TeXOutput.summary(s) { summaries.append(x) }
  }

  /// TAUDOT_ISSUESDUMP=FILE (diagnostics): every list shown, appended, one issue per line.
  static let dumpFile: FileHandle? = ProcessInfo.processInfo.environment["TAUDOT_ISSUESDUMP"].flatMap {
    FileManager.default.createFile(atPath: $0, contents: nil)
    return FileHandle(forWritingAtPath: $0)
  }
  static func dump(_ xs: [TeXIssue], hasLog: Bool) {
    guard let f = dumpFile else { return }
    var s = "== \(Date().timeIntervalSince1970) \(xs.count) issues (log: \(hasLog))\n"
    for x in xs { s += "\(x.severity) \(x.file ?? "main"):\(x.line.map(String.init) ?? "-") \(x.message)\n" }
    f.write(Data(s.utf8))
  }

  /// One stderr line of the typesetter (`TaudotPDFPane.onDriverLine`): its log's events.
  func driverLine(_ l: String) {
    if log.apply(line: l) { hasLog = true }
  }

  /// The typesetter restarted: a new process, whose log starts over.
  func restarted() {
    log = TeXLogBuffer()
    hasLog = false  // until the new process's log says otherwise (A11)
  }

  /// A run finished ("typeset"): its issues replace the shown ones.
  func runDone() {
    var found = (hasLog ? TeXOutput.parseLog(log.lines, main: mainFile) : []) + summaries
    if !hasLog {
      // the shown ones this run didn't reach: kept while their line reads as it did
      found += shown.filter { x in !bib.contains(x) && x.line != nil && snaps[x] != nil && lineText(x) == snaps[x] }
    }
    // Over/underfull boxes aren't shown with TeXpresso (`showBadboxes`): they come from how our engine (XeTeX, no microtype font expansion) breaks
    // lines, not from the document, so they don't match Overleaf's (pdfLaTeX) and mostly aren't the user's to fix.
    var all = TeXOutput.dedupe(found, main: mainFile).filter { showBadboxes || $0.severity != .badbox }
    // "Rerun to get cross-references right", "Citation(s) may have changed": this pass is provisional (TeXpresso runs
    // the next itself, as latexmk does for Overleaf). Its undefined references are mostly that; the notices aren't
    // the user's to act on.
    let rerun = all.contains { TeXOutput.asksRerun($0.message) }
    all.removeAll { TeXOutput.asksRerun($0.message) }
    summaries = []
    // Anything new waits until runs stop for `settle` s: a half-typed line, and TeXpresso's first pass (no .aux yet:
    // every reference and citation "undefined" for a second) don't flash. Fewer or the same show at once.
    let new = merged(all).filter { x in !shown.contains { TeXOutput.same($0, x) } }
    // keep what's shown (and a list still waiting to show: A11) until the next pass
    if new.isEmpty && rerun { return }
    tex = all
    cancelPending()
    if new.isEmpty { apply(merged(tex), pulse: false); return }
    let pulse = new.contains { $0.severity == .error }
    // a provisional pass waits longer for the next (shown anyway if none comes); BibTeX's list as it is by then
    timer = Timer.scheduledTimer(withTimeInterval: rerun ? max(settle, rerunWait) : settle, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { guard let self else { return }; self.apply(self.merged(self.tex), pulse: pulse) }
    }
  }

  /// BibTeX's warnings and errors (`TaudotPDFPane.onBibIssues`: the .blg after each BibTeX run, and at open from the
  /// cache), listed after TeX's as Overleaf does. A missing entry points at its \cite (`citeLocation`).
  func bibIssues(_ xs: [BibTeXIssue]) {
    let cited = citeLocations(Array(Set(xs.compactMap { $0.line == nil ? $0.key : nil })))
    bib = xs.map { b in
      var file = b.file, line = b.line
      if line == nil, let k = b.key, let at = cited[k] { file = at.file; line = at.line }
      if file == mainFile { file = nil }
      return TeXIssue(b.severity == .error ? .error : .warning, file: file, line: line, message: b.message)
    }
    // a run's list waiting to settle takes it up when it shows
    if timer == nil { apply(merged(tex), pulse: bib.contains { $0.severity == .error && !shown.contains($0) }) }
  }

  /// The one way a waiting list is dropped: the timer goes with it, so `timer == nil` means nothing waits (A11).
  private func cancelPending() {
    timer?.invalidate()
    timer = nil
  }

  /// TeX's issues, then BibTeX's (errors first overall).
  private func merged(_ t: [TeXIssue]) -> [TeXIssue] {
    let b = bib.filter { x in !t.contains { TeXOutput.same($0, x) } }
    return (t + b).filter { $0.severity == .error } + (t + b).filter { $0.severity != .error }
  }

  private func apply(_ xs: [TeXIssue], pulse: Bool) {
    timer = nil
    guard xs != shown || pulse else { return }
    shown = xs
    IssuesModel.dump(xs, hasLog: hasLog)
    var s: [TeXIssue: String] = [:]
    for x in xs { if let t = lineText(x) { s[x] = t } }
    snaps = s
    onChange?(xs, pulse)
  }
}

// MARK: - the strip

/// What the strip shows; the window updates it.
@MainActor final class IssuesStripState: ObservableObject {
  @Published var issues: [TeXIssue] = []
  @Published var expanded = false
  /// 40 % of the pane's height: the list scrolls past it.
  @Published var maxList: CGFloat = 300
  @Published var warningsOpen = false
  /// Bumped for a new error: the dot pulses once.
  @Published var pulse = 0
  /// Screenshots: the first row as if hovered (its sparkle shown).
  @Published var hoverFirst = false
}

/// The one place TeX's issues show: docked at the top of the PDF pane (as Overleaf shows its errors over the PDF), or
/// of the editor column while the PDF is hidden. Collapsed: "● 2 errors", the first error's title, "Fix all with
/// Claude", a chevron. Expanded: the header without the preview, then one compact row per error (warnings folded);
/// a row's click goes there, its sparkle (on hover) asks Claude to fix it. Gone when the run is clean.
struct IssuesStrip: View {
  @ObservedObject var state: IssuesStripState
  let mainFile: String
  let source: (TeXIssue) -> String?
  let onJump: (TeXIssue) -> Void
  let onAsk: (TeXIssue) -> Void
  let onAskAll: () -> Void

  var errors: [TeXIssue] { state.issues.filter { $0.severity == .error } }
  var warnings: [TeXIssue] { state.issues.filter { $0.severity != .error } }
  var tint: Color { errors.isEmpty ? .orange : .red }

  var counts: String {
    var parts: [String] = []
    if !errors.isEmpty { parts.append("\(errors.count) error\(errors.count == 1 ? "" : "s")") }
    if !warnings.isEmpty { parts.append("\(warnings.count) warning\(warnings.count == 1 ? "" : "s")") }
    return parts.joined(separator: " · ")
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      if state.expanded {
        Divider().opacity(0.6)
        list
      }
      Divider()
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .background(tint.opacity(0.10))
    .shadow(color: .black.opacity(state.expanded ? 0.22 : 0.10), radius: state.expanded ? 8 : 3, y: 2)
  }

  var header: some View {
    HStack(spacing: 8) {
      PulseDot(color: tint, pulse: state.pulse)
      Text(counts).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
      if !state.expanded, let first = state.issues.first {
        Text(first.plain ?? first.message).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
          .foregroundStyle(.primary.opacity(0.85))
        Text(place(first)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
          .layoutPriority(-1)
      }
      Spacer(minLength: 6)
      if !state.issues.isEmpty {
        Button(action: onAskAll) {
          Label(state.issues.count == 1 ? "Fix with Claude" : "Fix all with Claude", systemImage: "sparkles")
            .font(.system(size: 11, weight: .medium))
        }
        .buttonStyle(.borderless)
        .help("Opens Claude (⌘J) with one prompt for every error and warning, not sent")
      }
      Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
        .rotationEffect(.degrees(state.expanded ? 180 : 0))
    }
    .padding(.horizontal, 12)
    .frame(height: 30)
    .contentShape(Rectangle())
    .onTapGesture { withAnimation(.easeOut(duration: 0.18)) { state.expanded.toggle() } }
    .help(state.expanded ? "Collapse (⌥⌘E)" : "Show the issues (⌥⌘E)")
  }

  func place(_ x: TeXIssue) -> String { (x.file ?? mainFile) + (x.line.map { ":\($0)" } ?? "") }

  var list: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(errors.enumerated()), id: \.offset) { i, x in row(x, hovered: i == 0 && state.hoverFirst) }
        if !warnings.isEmpty {
          Button {
            withAnimation(.easeOut(duration: 0.15)) { state.warningsOpen.toggle() }
          } label: {
            HStack(spacing: 6) {
              Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                .rotationEffect(.degrees(state.warningsOpen ? 90 : 0))
              Text("\(warnings.count) warning\(warnings.count == 1 ? "" : "s")").font(.system(size: 12, weight: .medium))
              Spacer()
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
            .padding(.horizontal, 8).padding(.vertical, 5)
          }
          .buttonStyle(.plain)
          if state.warningsOpen || errors.isEmpty { ForEach(Array(warnings.enumerated()), id: \.offset) { _, x in row(x) } }
        }
      }
      .padding(.horizontal, 4).padding(.vertical, 4)
    }
    .frame(maxHeight: state.maxList)
    .fixedSize(horizontal: false, vertical: true)
  }

  func row(_ x: TeXIssue, hovered: Bool = false) -> some View {
    IssueRow(issue: x, mainFile: mainFile, line: source(x), onJump: { onJump(x) }, onAsk: { onAsk(x) }, hover: hovered)
  }
}

/// The header's dot: one pulse (bigger, then back) each time `pulse` changes.
struct PulseDot: View {
  let color: Color
  let pulse: Int
  @State var big = false
  var body: some View {
    Circle().fill(color).frame(width: 7, height: 7)
      .scaleEffect(big ? 1.9 : 1)
      .onChange(of: pulse) { _, _ in
        withAnimation(.easeOut(duration: 0.18)) { big = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { withAnimation(.easeInOut(duration: 0.3)) { big = false } }
      }
  }
}

/// One issue: the title (plain words) with file:line and, on hover, a sparkle that asks Claude to fix it; TeX's text
/// small below; the source line with the spot underlined. A click goes there.
struct IssueRow: View {
  let issue: TeXIssue
  let mainFile: String
  let line: String?
  let onJump: () -> Void
  let onAsk: () -> Void
  @State var hover: Bool

  init(issue: TeXIssue, mainFile: String, line: String?, onJump: @escaping () -> Void, onAsk: @escaping () -> Void, hover: Bool = false) {
    self.issue = issue; self.mainFile = mainFile; self.line = line; self.onJump = onJump; self.onAsk = onAsk
    _hover = State(initialValue: hover)
  }

  var tint: Color { issue.severity == .error ? .red : .orange }
  var place: String { (issue.file ?? mainFile) + (issue.line.map { ":\($0)" } ?? "") }

  var body: some View {
    HStack(alignment: .top, spacing: 7) {
      Circle().fill(tint).frame(width: 6, height: 6).padding(.top, 5)
      VStack(alignment: .leading, spacing: 2) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text(issue.plain ?? issue.message).font(.system(size: 12.5, weight: .medium)).fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 6)
          Text(place).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
          Button(action: onAsk) {
            Image(systemName: "sparkles").font(.system(size: 11, weight: .medium))
          }
          .buttonStyle(.borderless)
          .help("Ask Claude to fix")
          .opacity(hover ? 1 : 0)
          .accessibilityLabel("Ask Claude to fix")
        }
        if issue.plain != nil {
          Text(issue.message).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
        if let line, let snip = snippet(line) {
          Text(snip).font(.system(size: 11, design: .monospaced)).lineLimit(1)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.05)))
            .padding(.top, 1)
        }
      }
    }
    .padding(.horizontal, 8).padding(.vertical, 5)
    .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(hover ? 0.06 : 0)))
    .contentShape(Rectangle())
    .onHover { hover = $0 }
    .onTapGesture(perform: onJump)
  }
  /// The source line, its indentation dropped and cut around the spot, the token before the spot underlined in the
  /// tint (the command, or the word).
  func snippet(_ raw: String) -> AttributedString? {
    let lead = raw.prefix { $0 == " " || $0 == "\t" }.count
    let text = String(raw.dropFirst(lead))
    guard !text.isEmpty else { return nil }
    let chars = Array(text)
    var spot = issue.column(in: raw).map { max(0, min($0 - lead, chars.count)) }
    var from = 0
    let width = 64
    if let s = spot, s > width - 8 { from = s - (width - 8) }
    let to = min(chars.count, from + width)
    var out = AttributedString(from > 0 ? "…" : "")
    let shown = Array(chars[from..<to])
    spot = spot.map { $0 - from }
    var start = spot ?? 0
    if let s = spot, s > 0 {
      start = s - 1
      while start > 0, !shown[start - 1].isWhitespace, shown[start] != "\\" { start -= 1 }
      if let b = shown[..<s].lastIndex(of: "\\"), b >= start - 1, !shown[b..<s].contains(where: \.isWhitespace) { start = b }
    }
    for (i, c) in shown.enumerated() {
      var a = AttributedString(String(c))
      if let s = spot, i >= start, i < max(s, start + 1) {
        a.foregroundColor = tint
        a.underlineStyle = Text.LineStyle(pattern: .solid, color: tint)
      }
      out += a
    }
    if to < chars.count { out += AttributedString("…") }
    return out
  }
}

// MARK: - the window's side

extension ProjectWindow {
  func wireIssues() {
    issues.mainFileName = { [weak self] in self?.mainFile ?? "main.tex" }
    issues.lineText = { [weak self] x in
      guard let self, let l = x.line else { return nil }
      return self.sourceLine(x.file ?? self.mainFile ?? "main.tex", l)
    }
    issues.onChange = { [weak self] xs, pulse in self?.showIssues(xs, pulse: pulse) }
    issues.citeLocations = { [weak self] ks in self?.citeLocations(of: ks) ?? [:] }
    let main = mainFile ?? "main.tex"
    let v = IssuesStrip(state: strip, mainFile: main,
                        source: { [weak self] x in x.line.flatMap { self?.sourceLine(x.file ?? self?.mainFile ?? "main.tex", $0) } },
                        onJump: { [weak self] x in self?.jump(to: x) },
                        onAsk: { [weak self] x in self?.askClaudeToFix(x) },
                        onAskAll: { [weak self] in self?.askClaudeToFixAll(nil) })
    let h = NSHostingView(rootView: v)
    h.sizingOptions = [.intrinsicContentSize]
    h.translatesAutoresizingMaskIntoConstraints = false
    h.isHidden = true
    stripView = h
    // where it goes follows the panes: the PDF's top, or the editor column's while the PDF is hidden or zoomed away
    stripObservers = [pdf.view, editorBox].map { v in
      v.observe(\.isHidden, options: [.new]) { [weak self] _, _ in
        DispatchQueue.main.async { MainActor.assumeIsolated { self?.placeStrip() } }
      }
    }
    placeStrip()
  }

  /// The strip's host: the PDF pane when it shows (over the page's top, as Overleaf), else the editor column (above
  /// Neovim, which moves down for it rather than being covered).
  func placeStrip() {
    guard let h = stripView else { return }
    let inPDF = !pdf.view.isHidden || editorBox.isHidden
    let host: NSView = inPDF ? pdf.view : editorBox
    if h.superview !== host {
      h.removeFromSuperview()
      host.addSubview(h, positioned: .above, relativeTo: nil)
      NSLayoutConstraint.activate([
        h.topAnchor.constraint(equalTo: host.topAnchor),
        h.leadingAnchor.constraint(equalTo: host.leadingAnchor),
        h.trailingAnchor.constraint(equalTo: host.trailingAnchor),
      ])
    }
    let pushColumn = !inPDF && !h.isHidden
    columnTop.isActive = false
    columnTop = pushColumn ? column.topAnchor.constraint(equalTo: h.bottomAnchor) : column.topAnchor.constraint(equalTo: editorBox.topAnchor)
    columnTop.isActive = true
    strip.maxList = max(120, host.bounds.height * 0.4)
  }

  func showIssues(_ xs: [TeXIssue], pulse: Bool) {
    strip.issues = xs
    if xs.isEmpty { strip.expanded = false }
    if pulse { strip.pulse += 1 }
    stripView?.isHidden = xs.isEmpty
    placeStrip()
    publishDiagnostics(xs)
    showNativeIssues(xs)
  }

  /// The line `l` (1-based) of `file` as the typesetter has it (else from disk).
  func sourceLine(_ file: String, _ l: Int) -> String? { pdf.sourceLine(file, l) }

  /// Each key's first `\cite…{…key…}`: the main file first (as typeset), then the folder's other .tex files (read
  /// once for all the keys, in the folder's order). A line is matched only if it holds "cite" and the key at all.
  func citeLocations(of keys: [String]) -> [String: (file: String?, line: Int)] {
    let main = mainFile ?? "main.tex"
    func pattern(_ key: String) -> NSRegularExpression? {
      try? NSRegularExpression(pattern: #"\\[A-Za-z]*cite[A-Za-z]*\*?(\[[^\]]*\])*\{[^}]*\b"# + NSRegularExpression.escapedPattern(for: key) + #"\b[^}]*\}"#)
    }
    func find(_ lines: [(Int, String)], _ key: String, _ re: NSRegularExpression) -> Int? {
      lines.first { ($0.1 as NSString).range(of: key, options: .literal).location != NSNotFound && re.firstMatch(in: $0.1, range: NSRange(location: 0, length: ($0.1 as NSString).length)) != nil }.map { $0.0 + 1 }
    }
    func citing(_ lines: [String]) -> [(Int, String)] { lines.enumerated().filter { ($0.element as NSString).range(of: "cite", options: .literal).location != NSNotFound }.map { ($0.offset, $0.element) } }
    var out: [String: (file: String?, line: Int)] = [:]
    var rest: [(String, NSRegularExpression)] = []
    let mainLines = citing(pdf.sourceLines(main))
    for k in keys {
      guard let re = pattern(k) else { continue }
      if let l = find(mainLines, k, re) { out[k] = (nil, l) } else { rest.append((k, re)) }
    }
    guard !rest.isEmpty, let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return out }
    var files: [(String, [(Int, String)])] = []
    for case let u as URL in e where u.pathExtension == "tex" {
      let rel = String(u.path.dropFirst(folder.path.count + 1))
      guard rel != main, let text = try? String(contentsOf: u, encoding: .utf8) else { continue }
      files.append((rel, citing(text.components(separatedBy: "\n"))))
    }
    for (k, re) in rest {
      for (rel, lines) in files { if let l = find(lines, k, re) { out[k] = (rel, l); break } }
    }
    return out
  }
  /// Neovim: `vim.diagnostic` in the `taudot_tex` namespace (the native editor: `showNativeIssues`).
  func publishDiagnostics(_ xs: [TeXIssue]) {
    guard native == nil, let nvim else { return }
    let main = mainFile ?? "main.tex"
    var cache: [String: [String]] = [:]
    let payload = TeXDiagnostics.payload(xs, folder: folder, mainFile: main) { [pdf] f, l in
      if cache[f] == nil { cache[f] = pdf.sourceLines(f) }
      return l >= 1 && l <= cache[f]!.count ? cache[f]![l - 1] : nil
    }
    let load = texDiagnosticsLoaded ? "" : TeXDiagnostics.lua + "\n"
    texDiagnosticsLoaded = true
    Task { _ = try? await nvim.execLua(load + "require('taudot.tex_errors').set(...)", [payload]) }
  }

  /// ⌥⌘E: the strip expands or collapses (where it is: over the PDF, or atop the editor column).
  @objc func toggleIssues(_ sender: Any?) {
    guard !issues.shown.isEmpty else { status.note("No errors or warnings"); return }
    placeStrip()
    withAnimation(.easeOut(duration: reduceMotion ? 0 : 0.18)) { strip.expanded.toggle() }
  }

  func jump(to x: TeXIssue) {
    guard let line = x.line else { return }
    let path = x.file ?? mainFile ?? "main.tex"
    let abs = path.hasPrefix("/") ? path : folder.appendingPathComponent(path).path
    let col = sourceLine(path, line).flatMap { x.column(in: $0) }
    let c: Value = col.map { .int(Int64(max(0, $0 - 1))) } ?? .null
    Task { _ = try? await bridge.execLua("require('taudot.preview').jump(...)", [.string(abs), .int(Int64(line)), c]) }
    focusEditorToJump()
  }

  /// The prompt at Claude's input (⌘J's pane, started if needed), not sent: the user presses Return.
  func askClaude(prompt: String) {
    focus(pane: 3)
    Task {
      try? await Task.sleep(for: .milliseconds(10))
      await claude?.type(prompt)
    }
  }

  func askClaudeToFix(_ x: TeXIssue) { askClaude(prompt: x.claudePrompt(mainFile: mainFile ?? "main.tex")) }

  /// The strip's "Fix all with Claude", View ▸ Claude: one prompt for every error and warning shown.
  @objc func askClaudeToFixAll(_ sender: Any?) {
    let xs = issues.shown
    guard !xs.isEmpty else { status.note("No errors or warnings"); return }
    askClaude(prompt: TeXIssue.claudePromptAll(xs, mainFile: mainFile ?? "main.tex"))
  }

  /// TAUDOT_ISSUESSHOT=FILE (Tests/shell_issues_shots.sh): once the real run's issues show, the window with the strip
  /// collapsed, expanded (the first row as if hovered), atop the editor column with the PDF hidden, then "Fix all with
  /// Claude" done: one line per state in FILE ("collapsed N", "expanded N", "editor N", "fixall N").
  func issuesShot(_ out: URL) async {
    issues.settle = 0.3
    for _ in 0..<300 where issues.shown.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
    // then until it stops changing for 3 s (BibTeX's list comes a few seconds after the run's)
    var last = issues.shown, still = 0
    for _ in 0..<200 where still < 30 {
      try? await Task.sleep(for: .milliseconds(100))
      if issues.shown == last { still += 1 } else { last = issues.shown; still = 0 }
    }
    try? await Task.sleep(for: .seconds(1))
    if let x = issues.shown.first, let l = x.line {
      _ = try? await nvim?.execLua("vim.api.nvim_win_set_cursor(0, {...}); vim.cmd('normal! zz')", [.int(Int64(l)), .int(0)])
    }
    // what the run found (the script checks it): severity and line of each, e.g. "issues E5 E6 W3 W3 B4"
    let tag: [TeXIssue.Severity: String] = [.error: "E", .warning: "W", .badbox: "B"]
    var lines = "issues " + issues.shown.map { "\(tag[$0.severity]!)\($0.file.map { $0 + ":" } ?? "")\($0.line ?? 0)" }.joined(separator: " ") + "\n"
    func mark(_ s: String) async {
      try? await Task.sleep(for: .seconds(0.8))
      lines += "\(s) \(window.windowNumber)\n"
      try? lines.write(to: out, atomically: true, encoding: .utf8)
      try? await Task.sleep(for: .seconds(2))  // the capture
    }
    await mark("collapsed")
    strip.hoverFirst = true
    toggleIssues(nil)
    await mark("expanded")
    toggleIssues(nil)
    strip.hoverFirst = false
    setPane(pdf.view, hidden: true)
    await mark("editor")
    setPane(pdf.view, hidden: false)
    askClaudeToFixAll(nil)
    try? await Task.sleep(for: .seconds(3))  // claude's pane starts and the prompt is typed
    await mark("fixall")
  }

  /// View ▸ Claude ▸ Ask Claude to Fix the First Issue.
  @objc func askClaudeToFixFirst(_ sender: Any?) {
    guard let x = issues.shown.first else { status.note("No errors or warnings"); return }
    askClaudeToFix(x)
  }
}
