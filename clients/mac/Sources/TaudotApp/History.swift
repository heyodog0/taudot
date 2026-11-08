// The window's side of History (TaudotHistory): the sidebar's third tab shows the versions, and while it is the
// visible tab the editor column shows the selected file's changes read-only, in both editor modes, with a bar to go
// back to editing. The diff and the version's PDF move together: the diff's current change is shown on the pages, a
// mark clicked is the diff's current change, a double-click in the diff is a forward search, and the arrows of either
// bar step through the changes. Owner: the history agent (docs/agents/history.md); ProjectWindow only calls wireHistory().
import AppKit
import TaudotHistory
import TaudotNeovim
import TaudotReview
import TaudotShared

extension ProjectWindow {
  func wireHistory() {
    let h = HistoryController(source: EngineHistorySource(socket: engineSocket, folder: folder), mainFile: mainFile)
    history = h
    sidebar.history = h.pane
    h.colorFor = { [weak self] u in self?.historyColor(u) ?? HistoryColors.margin(u) }
    h.onBack = { [weak self] in self?.leaveHistory() }
    h.onError = { [weak self] e in self?.status.note(e) }
    let s = TaudotSettings.shared
    let size = s.fontSize > 0 ? CGFloat(s.fontSize) : 13
    h.diffView.font = NSFont(name: s.fontFamily.replacingOccurrences(of: "'", with: ""), size: size)
      ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    wireHistoryPDF(h)
    let previous = sidebar.onTabChange
    sidebar.onTabChange = { [weak self] t in
      previous?(t)
      self?.historyTabChanged(t)
    }
    if sidebar.tab == .history { historyTabChanged(.history) }
    if let c = ProcessInfo.processInfo.environment["TAUDOT_HISTORYCHECK"] { Task { await historyCheck(URL(fileURLWithPath: c)) } }
  }

  /// TAUDOT_HISTORYCHECK=FILE (Tests/history_app.sh): in the real window, in the background: open History, wait for a
  /// diff over the editor, snapshot the window to FILE.png, go Back to Editing; one ok/FAIL line per check in FILE.
  func historyCheck(_ out: URL) async {
    var lines: [String] = []
    func check(_ ok: Bool, _ what: String) { lines.append((ok ? "ok   " : "FAIL ") + what) }
    func wait(_ s: Double, _ f: () -> Bool) async { var t = 0.0; while !f() && t < s { try? await Task.sleep(for: .milliseconds(100)); t += 0.1 } }
    await wait(30) { editorStarted }
    check(editorStarted, "editor started (\(mode))")
    showSidebarHistory(nil)
    guard let h = history else { check(false, "history wired"); return }
    await wait(30) { h.diffView.diff != nil }
    check(sidebar.tab == .history && !h.pane.isHidden, "sidebar shows History")
    check(!h.groups.isEmpty, "versions listed (\(h.groups.count))")
    check(h.diffView.diff != nil, "a diff shown (\(h.diffView.diff?.path ?? "none"))")
    check(h.diffView.superview === editorBox && !h.diffView.isHidden, "diff over the editor column")
    window.contentView?.layoutSubtreeIfNeeded()
    let f = h.diffView.convert(h.diffView.bounds, to: nil), e = editorHost.convert(editorHost.bounds, to: nil)
    check(f == e, "diff covers the editor exactly (\(f) vs \(e))")
    // the PDF side: the version's pane over the PDF pane, typeset, its changes marked
    if let p = historyPDF, !pdf.view.isHidden {
      await wait(120) { p.pdf.changesPlaced }
      check(p.view.superview === pdf.view && !p.view.isHidden && p.view.frame == pdf.view.bounds, "version PDF over the PDF pane")
      check(p.pdf.changesPlaced && p.pdf.pane.pageCount > 0, "version \(p.version ?? -1) typeset (\(p.pdf.pane.pageCount) pages): \(p.view.status)")
      check(!p.pdf.placedChanges.isEmpty || p.changes.isEmpty, "changes marked on the pages (\(p.pdf.placedChanges.count) of \(p.changes.count))")
      if let first = p.pdf.placedChanges.first, let (path, i) = HistoryPDFController.split(first.id), let r = first.rects.first {
        _ = p.pdf.pane.clickPages(at: p.pdf.pane.pagePoint(first.page, CGPoint(x: r.midX, y: r.midY)))
        await wait(10) { h.diffView.diff?.path == path && h.diffView.current == i }
        check(h.diffView.diff?.path == path && h.diffView.current == i, "a mark clicked selects its change in the diff (\(first.id))")
        check(h.diffView.textView.selectedRange() == h.diffView.diff?.changes[i].range, "the diff's cursor on it")
        // the next change, from the diff or the PDF's bar: shown on the pages
        p.view.nextButton.performClick(nil)
        if let d = h.diffView.diff, let j = h.diffView.current {
          check(p.selectedChange == "\(d.path)#\(j)", "the PDF's next arrow moves the diff and the PDF (\(d.path)#\(j))")
        } else {
          check(false, "the PDF's next arrow moves the diff")
        }
      }
      p.pdf.raiseChangeMarks()
    }
    if let v = window.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
      v.cacheDisplay(in: v.bounds, to: rep)
      try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathExtension("png"))
    }
    h.diffView.backButton.performClick(nil)
    try? await Task.sleep(for: .milliseconds(300))
    check(h.diffView.isHidden && sidebar.tab != .history, "Back to Editing leaves History (\(sidebar.tab))")
    check(window.firstResponder === editorResponder, "the editor has the keys again")
    check(historyPDF?.view.isHidden ?? true, "the version PDF goes with it")
    try? (lines.joined(separator: "\n") + "\n").write(to: out, atomically: true, encoding: .utf8)
    NSApp.terminate(nil)
  }

  func historyTabChanged(_ t: SidebarView.Tab) {
    guard let h = history else { return }
    if t != .history {
      historyReturnTab = t
      showHistoryDiff(false)
      showHistoryPDF(false)
      return
    }
    h.mainFile = mainFile
    showHistoryDiff(true)
    showHistoryPDF(true)
    h.activate()
  }

  /// The PDF side: the version's pane over the PDF pane while History is open (a subview of it, so it follows the
  /// pane's frame), fed each range History picks; marks and the diff's current change select each other.
  func wireHistoryPDF(_ h: HistoryController) {
    let p = HistoryPDFController(source: h.source, project: folder, mainFile: mainFile)
    historyPDF = p
    p.colorFor = h.colorFor
    p.onError = { [weak self] e in self?.status.note(e) }
    p.onPickChange = { [weak h] path, i in h?.showChange(path: path, index: i) }
    h.onRange = { [weak self, weak p] r, files, head in
      guard let self, let p, self.historyPDFShown else { return }
      p.mainFile = self.mainFile
      p.engine = self.pdf.engine
      p.pdf.pageStyle = self.pdf.pageStyle
      p.show(r, files: files, head: head)
    }
    h.diffView.onCurrent = { [weak p] d, i in p?.select(path: d.path, index: i) }
    h.diffView.onForward = { [weak p] path, line, col in p?.forward(path: path, line: line, column: col) }
    p.onStep = { [weak h] by in h?.diffView.step(by) }
    h.diffView.vimKeys = native == nil
  }

  /// History's read-only diff is over the editor (A12: the live editor must not have the keys then).
  var historyCoversEditor: Bool { history.map { $0.diffView.superview != nil && !$0.diffView.isHidden } ?? false }

  var historyPDFShown: Bool { historyPDF.map { $0.view.superview != nil && !$0.view.isHidden } ?? false }

  func showHistoryPDF(_ on: Bool) {
    guard let p = historyPDF else { return }
    if on {
      if p.view.superview == nil {
        p.view.frame = pdf.view.bounds
        p.view.autoresizingMask = [.width, .height]
        pdf.view.addSubview(p.view)
      }
      p.view.isHidden = false
      // the range the file list belongs to (filesRange), not one whose tree is still loading (A5)
      if let h = history, let r = h.filesRange, !h.files.isEmpty { h.onRange?(r, h.files, h.head) }
    } else {
      p.view.isHidden = true
      p.close()
    }
  }

  /// The diff over the editor (not over the Claude pane under it).
  func showHistoryDiff(_ on: Bool) {
    guard let d = history?.diffView else { return }
    if on {
      if d.superview == nil {
        d.translatesAutoresizingMaskIntoConstraints = false
        editorBox.addSubview(d, positioned: .below, relativeTo: claudeFloat)
        NSLayoutConstraint.activate([
          d.leadingAnchor.constraint(equalTo: editorHost.leadingAnchor), d.trailingAnchor.constraint(equalTo: editorHost.trailingAnchor),
          d.topAnchor.constraint(equalTo: editorHost.topAnchor), d.bottomAnchor.constraint(equalTo: editorHost.bottomAnchor),
        ])
      }
      d.isHidden = false
      if editorBox.isHidden { setPane(editorBox, hidden: false) }
    } else {
      d.isHidden = true
    }
  }

  /// Back to Editing: the sidebar's previous tab, the editor focused.
  func leaveHistory() {
    sidebar.tab = historyReturnTab == .history ? .files : historyReturnTab
    focus(pane: 1)
  }

  /// ⇧⌘H: History in the sidebar, shown and focused.
  @objc func showSidebarHistory(_ sender: Any?) {
    sidebar.tab = .history
    focus(pane: 0)
  }

  /// An author as the margin colours them: coral for you, the colour of their comments and changes when the margin
  /// has any, else nil (HistoryColors.margin picks one from the ID, as the margin does).
  func historyColor(_ u: HistoryUser) -> NSColor? {
    if u.mine { return TaudotColor.coral }
    guard let id = u.id else { return nil }
    if let hex = margin.state.items.first(where: { $0.author.id == id && $0.color != nil })?.color { return NSColor(hex: hex) }
    if let hex = sidebar.overview.items.first(where: { $0.author.id == id && $0.color != nil })?.color { return NSColor(hex: hex) }
    return nil
  }
}
