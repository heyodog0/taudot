// Pane keys, Rex-style: focus the sidebar (today the comments margin), Neovim or the PDF, cycle and move between
// them, zoom one. The focused pane carries a thin accent line at its top; Neovim's cursor is hollow when it isn't
// focused (EditorView.focused).
//
//   ⌘[ / ⌘]     previous / next visible pane (wrapping)      ⌘⌥← / ⌘⌥→  pane to the left / right
//   ⌘1 ⌘2 ⌘3    sidebar / Neovim / PDF (shown if hidden)      ⌃⌘S (⇧⌘\)  show / hide the sidebar
//   ⌘E          zoom the focused pane; again restores          ⇧⌘E / ⇧⌘M  sidebar: Files / Comments
import AppKit
import TaudotReview

extension ProjectWindow {
  /// Sidebar, editor, PDF: left to right, as in the split view.
  var panes: [NSView] { [sidebar, editorBox, pdf.view] }

  func visible(_ i: Int) -> Bool { i == 3 ? claudeShown : !panes[i].isHidden }

  /// Focus targets: 0 sidebar, 1 Neovim, 2 PDF, 3 the Claude pane (under Neovim, in the editor column).
  func focusable(_ i: Int) -> Bool {
    if panesHiding.contains(i == 3 ? 1 : i) { return false }
    switch i {
    case 1: return visible(1) && !editorHost.isHidden
    case 3: return visible(1) && claudeShown
    default: return visible(i)
    }
  }
  /// Left to right, the Claude pane after Neovim (it's below it).
  var focusOrder: [Int] { [0, 1, 3, 2].filter(focusable) }
  func paneView(_ i: Int) -> NSView { i == 3 ? (claude?.view ?? editorBox) : i == 1 ? editorView : panes[i] }

  // MARK: focus

  /// Focus pane `i`, showing it first if it is hidden (leaving a zoom if that is why).
  func focus(pane i: Int) {
    if !focusable(i) {
      if zoom != nil { unzoom(animated: false) }
      let column = i == 3 ? 1 : i
      if !visible(column) { setPane(panes[column], hidden: false) }
      if i == 3 && !claudeShown { setClaude(shown: true) }
    }
    focusedPane = i
    // Neovim or the sidebar's tab (tree, or the selected card) takes the keys; the PDF takes none yet, so the
    // window does (no keys reach Neovim).
    switch i {
    case 0: window.makeFirstResponder(nil); sidebar.focus()
    case 1: giveEditorKeys()
    case 3: window.makeFirstResponder(claude?.view)
    default: window.makeFirstResponder(nil)
    }
    updateFocusLine(animated: true)
  }

  /// The one way the editor column takes the keys (A12): the live editor, or History's read-only diff while it covers
  /// the editor, so keys never go to text the user can't see.
  func giveEditorKeys() {
    if historyCoversEditor, let d = history?.diffView { window.makeFirstResponder(d.textView); return }
    window.makeFirstResponder(editorResponder)
  }

  /// The editor focused for an action that moves its cursor (an issue, a comment, inverse search): History, if it
  /// covers the editor, is left first so the place is shown.
  func focusEditorToJump() {
    if historyCoversEditor { leaveHistory() } else { focus(pane: 1) }
  }

  /// The visible pane `step` away from the focused one; `wrap` false stops at the ends.
  func paneStep(_ step: Int, wrap: Bool) -> Int? {
    let vis = focusOrder
    guard !vis.isEmpty else { return nil }
    guard let at = vis.firstIndex(of: focusedPane) else { return vis.first }
    let j = at + step
    if wrap { return vis[(j % vis.count + vis.count) % vis.count] }
    return vis.indices.contains(j) ? vis[j] : nil
  }

  @objc func focusNextPane(_ sender: Any?) { if let i = paneStep(1, wrap: true) { focus(pane: i) } }
  @objc func focusPreviousPane(_ sender: Any?) { if let i = paneStep(-1, wrap: true) { focus(pane: i) } }
  /// ⌘⌥← / ⌘⌥→ go by column: the Claude pane shares Neovim's, so from either the next one is the sidebar or PDF.
  func paneSide(_ dir: Int) -> Int? {
    let col = focusedPane == 3 ? 1 : focusedPane
    var c = col + dir
    while (0..<3).contains(c) {
      if c == 1 { if let i = [1, 3].first(where: focusable) { return i } } else if focusable(c) { return c }
      c += dir
    }
    return nil
  }
  @objc func focusPaneRight(_ sender: Any?) { if let i = paneSide(1) { focus(pane: i) } }
  @objc func focusPaneLeft(_ sender: Any?) { if let i = paneSide(-1) { focus(pane: i) } }
  @objc func focusSidebar(_ sender: Any?) { focus(pane: 0) }
  @objc func focusEditor(_ sender: Any?) { focus(pane: 1) }
  /// ⌥⌘↓ / ⌥⌘↑ from any pane: Neovim gets the keys and goes to the next / previous comment (]r / [r).
  @objc func nextComment(_ sender: Any?) { focusEditorToJump(); review?.verb(.next) }
  @objc func previousComment(_ sender: Any?) { focusEditorToJump(); review?.verb(.previous) }
  /// Review ▸ Review Suggestions…: the review bar, at the first item if none is here.
  @objc func reviewStart(_ sender: Any?) { focusEditorToJump(); review?.startReview() }
  /// Review ▸ Show ▸ Markup / Preview All Accepted / Preview All Rejected (tags 10, 11, 12).
  @objc func reviewPreview(_ sender: Any?) {
    guard let tag = (sender as? NSMenuItem)?.tag else { return }
    review?.preview(tag == 11 ? "accepted" : tag == 12 ? "rejected" : "off")
  }
  // Review ▸ (margin-keys.md): on the selected card, else the one at the cursor, then the next item.
  @objc func reviewAcceptOrReply(_ sender: Any?) {
    // A comment's reply takes the keys (the pane); a suggestion leaves them where they were.
    if review?.margin.currentItem?.kind == .comment, !p_sidebarHidden { focus(pane: 0) }
    if review?.verb(.acceptOrReply) != true { NSSound.beep() }
  }
  @objc func reviewReject(_ sender: Any?) { if review?.verb(.reject) != true { NSSound.beep() } }
  @objc func reviewResolve(_ sender: Any?) { if review?.verb(.resolve) != true { NSSound.beep() } }
  @objc func reviewNewComment(_ sender: Any?) { margin.newComment() }
  @objc func reviewAcceptAll(_ sender: Any?) { sidebar.allInFile(accept: true) }
  @objc func reviewRejectAll(_ sender: Any?) { sidebar.allInFile(accept: false) }
  @objc func reviewShow(_ sender: Any?) {
    guard let tag = (sender as? NSMenuItem)?.tag else { return }
    sidebar.kinds = ReviewKinds(rawValue: tag)
  }
  private var p_sidebarHidden: Bool { sidebar.isHidden || sidebar.tab != .comments }
  @objc func focusPDF(_ sender: Any?) { focus(pane: 2) }
  /// ⇧⌘E / ⇧⌘M: that sidebar tab, the sidebar shown and focused.
  @objc func showSidebarFiles(_ sender: Any?) { sidebar.tab = .files; focus(pane: 0) }
  @objc func showSidebarComments(_ sender: Any?) { sidebar.tab = .comments; focus(pane: 0) }

  /// After any event: follow focus changes made by clicks or by the panes themselves.
  func trackFocus() {
    let fr = window.firstResponder
    func host(_ i: Int) -> NSView { i == 1 ? editorHost : paneView(i) }  // pane 1: the editor, its pill and floating cards
    if let v = fr as? NSView, let i = [3, 0, 1, 2].first(where: { $0 != 3 || claude != nil ? v === host($0) || v.isDescendant(of: host($0)) : false }),
       i != focusedPane {
      focusedPane = i
    }
    if !focusable(focusedPane), let i = focusOrder.first { focusedPane = i }
    updateFocusLine(animated: true)
  }

  /// A click in a pane focuses it.
  func clicked(_ e: NSEvent) {
    guard e.window === window, let content = window.contentView else { return }
    let p = content.convert(e.locationInWindow, from: nil)
    for i in [0, 2, 1, 3] where focusable(i) {
      let v = paneView(i)
      if v.convert(v.bounds, to: content).contains(p) {
        if i != 1 && i != 3 && window.firstResponder === editorResponder { window.makeFirstResponder(nil) }
        focusedPane = i
      }
    }
    // The floating panel (strip and edges included) is above the editor: a click on it is the Claude pane's.
    if !claudeFloat.isHidden, claudeFloat.convert(claudeFloat.bounds, to: content).contains(p), let c = claude {
      focusedPane = 3
      if window.firstResponder !== c.view { window.makeFirstResponder(c.view) }
    }
  }

  /// The focus line: on the pane that has the keys, whenever the window is key and more than one pane shows. It
  /// follows the pane's frame on every tick of a split animation, and slides (~180 ms) when the focus moves.
  func updateFocusLine(animated: Bool = true) {
    guard let content = window.contentView else { return }
    if focusLine.superview == nil {
      focusLine.wantsLayer = true
      focusLine.layer?.backgroundColor = accentColor.withAlphaComponent(0.85).cgColor
      content.addSubview(focusLine, positioned: .above, relativeTo: nil)
    }
    let key = window.isKeyWindow || lineIgnoresKey
    claudeFloat.setFocused(focusedPane == 3 && key)
    // The floating panel shows its focus by itself (not dimmed).
    let show = focusable(focusedPane) && focusOrder.count > 1 && key && !(focusedPane == 3 && !dockedNow)
    let f = lineTarget(focusedPane, in: content)
    if !show {
      focusLine.isHidden = true
      lineSlide = nil
      linePane = nil
      return
    }
    // The focus moved to another pane while the line was showing: slide from where it is.
    if let from = linePane, from != focusedPane, !focusLine.isHidden, animated, !reduceMotion {
      lineSlide = (focusLine.frame, CACurrentMediaTime())
      startLineTimer()
    }
    linePane = focusedPane
    var r = f
    if let (from, t0) = lineSlide {
      let k = min(1, (CACurrentMediaTime() - t0) / 0.18)
      let e = CGFloat(1 - pow(1 - k, 3))
      r = NSRect(x: from.minX + (f.minX - from.minX) * e, y: from.minY + (f.minY - from.minY) * e,
                 width: from.width + (f.width - from.width) * e, height: f.height)
      if k >= 1 { lineSlide = nil }
    }
    focusLine.frame = r
    focusLine.isHidden = false
    onLineFrame?()
  }

  /// The line's place on pane `i`: its top edge, 2 pt.
  func lineTarget(_ i: Int, in content: NSView) -> NSRect {
    let p = paneView(i)
    let r = p.convert(p.bounds, to: content)
    return NSRect(x: r.minX, y: content.isFlipped ? r.minY : r.maxY - 2, width: r.width, height: 2)
  }

  func startLineTimer() {
    guard lineTimer == nil else { return }
    let t = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.updateFocusLine(animated: false)
        if self.lineSlide == nil { self.lineTimer?.invalidate(); self.lineTimer = nil }
      }
    }
    RunLoop.main.add(t, forMode: .common)
    lineTimer = t
  }

  /// Motion durations become 0 with System Settings ▸ Accessibility ▸ Reduce motion.
  var reduceMotion: Bool {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || ProcessInfo.processInfo.environment["TAUDOT_PANE_INSTANT"] != nil
  }

  /// ⌥⌘2 / ⌥⌘3: Neovim only / PDF only (focus it and zoom it); again, the layout back.
  @objc func neovimOnly(_ sender: Any?) { only(pane: 1) }
  @objc func pdfOnly(_ sender: Any?) { only(pane: 2) }
  func only(pane i: Int) {
    if let z = zoom, z.pane == i, focusedPane == i { unzoom(animated: true); return }
    if zoom != nil { unzoom(animated: false) }
    focus(pane: i)
    toggleZoom(nil)
  }

  // MARK: zoom

  /// ⌘E: the focused pane alone; again, the layout as it was.
  @objc func toggleZoom(_ sender: Any?) {
    if zoom != nil { unzoom(animated: true); return }
    settlePanes()  // the zoom keeps the layout an animation was going to, not a frame of it
    guard focusable(focusedPane), focusOrder.count > 1 else { return }
    // In the editor column, Neovim and the Claude pane zoom on their own: the other one hides too.
    let col = focusedPane == 3 ? 1 : focusedPane
    zoom = (col, panes.map(\.isHidden), widths(), claudeShown)
    if focusedPane == 1 && claudeShown { setClaude(shown: false) }
    if focusedPane == 3 { editorHost.isHidden = true; column.adjustSubviews(); layoutClaudeFloat() }
    var w: [CGFloat] = [0, 0, 0]
    w[col] = split.bounds.width
    animate(to: w, hide: Set((0..<3).filter { $0 != col }))
  }

  func unzoom(animated: Bool) {
    guard let z = zoom else { return }
    zoom = nil
    if editorHost.isHidden { editorHost.isHidden = false; column.adjustSubviews(); layoutClaudeFloat() }
    // (not a claude that exited meanwhile: no fresh session nobody asked for, A10; ⌘J starts one)
    if z.claude && !claudeShown, claude?.exited == false { setClaude(shown: true) }
    let target = (0..<3).map { z.hidden[$0] ? 0 : z.widths[$0] }
    let hide = Set((0..<3).filter { z.hidden[$0] })
    if animated {
      // Show them at no width, then open them up.
      for i in 0..<3 where !z.hidden[i] { panes[i].isHidden = false }
      setWidths((0..<3).map { $0 == z.pane ? split.bounds.width : 0 })
      animate(to: target, hide: hide)
    } else {
      for i in 0..<3 { panes[i].isHidden = z.hidden[i] }
      split.adjustSubviews()
      setWidths(target)
      parkHidden()
      for i in 0..<3 where !z.hidden[i] { paneWidths[ObjectIdentifier(panes[i])] = z.widths[i] }
      updateFocusLine(animated: false)
    }
  }

  /// Hidden side panes at their edge with no width (see setPane).
  func parkHidden() {
    for (i, p) in [sidebar, pdf.view].enumerated() where p.isHidden {
      p.frame = NSRect(x: i == 0 ? 0 : split.bounds.width, y: 0, width: 0, height: split.bounds.height)
    }
    hideStaleDividers()
  }

  /// NSSplitView leaves the divider layer of a pane hidden before the window showed (TAUDOT_NO_PDF, a hidden sidebar
  /// at launch) where that pane was, over the editor: hide divider layers that aren't between two visible panes.
  func hideStaleDividers() {
    splitGrips.layout(); columnGrips.layout()
    guard let layers = split.layer?.sublayers else { return }
    let vis = panes.filter { !$0.isHidden }
    let gaps = zip(vis, vis.dropFirst()).map { $0.0.frame.maxX }
    for l in layers where l.delegate === split && l.frame.width <= split.dividerThickness + 0.5 && l.frame.height > 20 {
      l.isHidden = !gaps.contains { abs($0 - l.frame.minX) <= 1 }
    }
  }

  /// Widths of the three panes (0 for hidden ones).
  func widths() -> [CGFloat] { panes.map { $0.isHidden ? 0 : $0.frame.width } }

  /// Place the dividers for these widths (hidden panes count as 0).
  func setWidths(_ w: [CGFloat]) {
    animatingPanes = true
    defer { animatingPanes = false }
    // One pane: it fills the split by itself. Otherwise not next to a hidden pane: moving that divider would bring
    // the pane back.
    if (0..<3).filter(visible).count < 2 { return }
    // The editor hidden: both dividers border it, and moving either would bring it back. Place the side panes.
    if !visible(1) {
      let h = split.bounds.height, d = split.dividerThickness
      if visible(0) { sidebar.frame = NSRect(x: 0, y: 0, width: w[0], height: h) }
      if visible(2) { let x = visible(0) ? w[0] + d : 0; pdf.view.frame = NSRect(x: x, y: 0, width: split.bounds.width - x, height: h) }
      hideStaleDividers()
      return
    }
    // Right divider first: panes reopening from no width need the room before the left one moves.
    if visible(2) { split.setPosition(split.bounds.width - w[2] - split.dividerThickness, ofDividerAt: 1) }
    if visible(0) { split.setPosition(w[0], ofDividerAt: 0) }
  }

  /// Move the dividers to `target` over ~150 ms (ease out), then hide the panes in `hide`.
  /// One animation at a time (A2): a new one takes over the panes the running one was still hiding (their targets are
  /// 0: `setPane` counts hiding panes as gone), so its end hides them too.
  func animate(to target: [CGFloat], hide newHide: Set<Int>) {
    let carried = (paneMotion?.hide ?? []).intersection(panesHiding)
    paneAnimation?.invalidate()
    paneAnimation = nil
    paneMotion = nil
    let hide = newHide.union(carried)
    let start = widths(), t0 = CACurrentMediaTime(), duration = 0.2
    panesHiding.formUnion(hide)
    // Neovim keeps its grid while the split moves (its text slides with the pane instead of reflowing every frame);
    // one resize at the end.
    editor?.holdGridSize = true
    claude?.view.holdGridSize = true
    let finish: @MainActor () -> Void = { [weak self] in
      guard let self else { return }
      self.paneAnimation?.invalidate()
      self.paneAnimation = nil
      self.paneMotion = nil
      // (a pane shown again meanwhile left panesHiding and stays)
      let gone = hide.intersection(self.panesHiding)
      self.panesHiding.subtract(gone)
      self.editor?.holdGridSize = false
      self.claude?.view.holdGridSize = false
      for i in gone { self.panes[i].isHidden = true }
      self.split.adjustSubviews()
      self.setWidths(target)
      self.parkHidden()
      if self.focusable(self.focusedPane) { self.focus(pane: self.focusedPane) } else { self.trackFocus() }
      if self.zoom == nil { self.savePanes() }
    }
    paneMotion = (hide, finish)
    if reduceMotion { finish(); return }
    paneAnimation = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, let timer = self.paneAnimation else { return }
        let k = min(1, (CACurrentMediaTime() - t0) / duration)
        let e = CGFloat(1 - pow(1 - k, 3))
        self.setWidths((0..<3).map { start[$0] + (target[$0] - start[$0]) * e })
        self.layoutClaudeFloat()
        self.updateFocusLine()
        if k >= 1 { timer.invalidate(); finish() }
      }
    }
    RunLoop.main.add(paneAnimation!, forMode: .common)
  }

  /// The running pane animation, if any, jumps to its end now (before a zoom captures the layout, a save, a close).
  func settlePanes() {
    guard let m = paneMotion else { return }
    m.finish()
  }
}
