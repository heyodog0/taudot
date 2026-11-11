// The window's side of outside edits (editfix item 9; the list is OutsideEdits, in TaudotEditor): each one the editors
// report goes to the Changes tab and to the PDF (its lines tinted, fading); with View ▸ Follow Edits the editor and the
// PDF go to it, but never while the user types (it waits for 2 s without a key); without, an edit off screen shows a
// small pill over the editor that goes there (and turns Follow on).
import AppKit
import TaudotEditor
import TaudotShared

extension ProjectWindow {
  /// Seconds without a key before Follow Edits moves the view.
  static let followIdle: CFTimeInterval = 2

  func wireOutside() {
    sidebar.changes = changesView
    changesView.following = followEdits
    changesView.onFollow = { [weak self] on in self?.followEdits = on }
    changesView.onJump = { [weak self] c in self?.goTo(c, focus: true) }
    changesView.onUndo = { [weak self] c in self?.undoOutside(c) }
    outside.claudeBusy = { [weak self] in self.map { CACurrentMediaTime() - $0.claudeOutputAt < 20 } ?? false }
    outside.onChange = { [weak self] in self?.outsideChanged() }
    outside.onNew = { [weak self] c in self?.outsideLanded(c) }
    editPill.onClick = { [weak self] in
      guard let self, let c = self.editPill.change else { return }
      self.editPill.hide()
      self.followEdits = true
      self.goTo(c, focus: false)
    }
    // a key in this window: the user is typing (Follow Edits waits)
    typingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
      if let self, e.window === self.window { self.lastTyped = CACurrentMediaTime() }
      return e
    }
  }

  /// `taudot_app_outside path edits author origin source` from either editor.
  func wireOutsideNotify() {
    bridge.notify("taudot_app_outside") { [weak self] args in
      guard let self, args.count >= 2, let p = args[0].string, let es = args[1].array else { return }
      let path = p.hasPrefix("/") ? String(p.dropFirst()) : p
      let edits = es.compactMap { e -> (pos: Int, del: Int, ins: String)? in
        guard let pos = e["pos"]?.int, let del = e["del"]?.int else { return nil }
        return (pos, del, e["ins"]?.string ?? "")
      }
      var author: [String: Any]?
      if args.count > 2, case .map = args[2] {
        author = [:]
        if let id = args[2]["user_id"]?.string { author?["user_id"] = id }
        if let n = args[2]["name"]?.string { author?["name"] = n }
      }
      let origin = args.count > 3 ? args[3].string : nil
      let source = args.count > 4 ? args[4].string : nil
      self.outside.outside(path, edits: edits, author: author, origin: origin, source: source)
    }
  }

  private func outsideChanged() {
    changesView.update(outside)
    let n = outside.changes.count
    sidebar.changesLabel = n > 0 ? "Changes \(n)" : "Changes"
  }

  private func outsideLanded(_ c: OutsideEdits.Change) {
    let lines = outside.lines(of: c)
    let follow = followEdits && CACurrentMediaTime() - lastTyped >= Self.followIdle
    if let lines {
      var cols: (Int, Int, Int)?
      if lines.count == 1, let (_, col) = outside.line(of: c), let t = outside.text(c.path) {
        // the line's length, for the PDF's narrowing to the typeset lines the edit is on
        var s = c.pos - col, e = c.pos
        while e < t.count && t[e] != 0x0A { e += 1 }
        s = max(0, s)
        cols = (col, col + c.len, e - s)
      }
      pdf.markEdit(path: c.path, lines: lines, cols: cols.map { (start: $0.0, end: $0.1, length: $0.2) },
                   color: OutsideEdits.color(c), reveal: follow)
    }
    if followEdits {
      if follow { goTo(c, focus: false) } else { followLater(c) }
      return
    }
    if !onScreen(c) {
      let l = outside.line(of: c)?.line
      let above = editorPath == c.path && l.map { $0 - 1 < (margin.geometry?.visibleLines.lowerBound ?? 0) } == true
      editPill.show(c, line: l, above: above, in: editorBox)
    }
  }

  /// Follow waits until the user has stopped typing.
  private func followLater(_ c: OutsideEdits.Change) {
    pendingFollow = c
    guard followTimer == nil else { return }
    let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        guard CACurrentMediaTime() - self.lastTyped >= Self.followIdle else { return }
        self.followTimer?.invalidate()
        self.followTimer = nil
        if self.followEdits, let p = self.pendingFollow, let c = self.outside.changes.first(where: { $0.id == p.id }) {
          self.goTo(c, focus: false)
          if let lines = self.outside.lines(of: c) {
            self.pdf.markEdit(path: c.path, lines: lines, color: OutsideEdits.color(c), reveal: true)
          }
        }
        self.pendingFollow = nil
      }
    }
    RunLoop.main.add(t, forMode: .common)
    followTimer = t
  }

  /// The change's text is in the editor's view (its doc, its lines visible).
  func onScreen(_ c: OutsideEdits.Change) -> Bool {
    guard editorPath == nil || editorPath == c.path, let l = outside.line(of: c)?.line, let g = margin.geometry else { return false }
    return g.visibleLines.contains(l - 1)
  }

  /// The editor to the change (its doc opened if need be), and the PDF.
  func goTo(_ c: OutsideEdits.Change, focus: Bool) {
    guard let (line, col) = outside.line(of: c) else { return }
    let abs = folder.appendingPathComponent(c.path).path
    Task { _ = try? await self.bridge.execLua("require('taudot.preview').jump(...)", [.string(abs), .int(Int64(line)), .int(Int64(col))]) }
    if focus {
      focusEditorToJump()
      if let lines = outside.lines(of: c) { pdf.markEdit(path: c.path, lines: lines, color: OutsideEdits.color(c), reveal: true) }
    }
  }

  func undoOutside(_ c: OutsideEdits.Change) {
    guard let u = outside.undoEdit(c) else { NSSound.beep(); return }
    Task {
      let r = try? await self.bridge.execLua("return require('taudot.app').replace(...)",
                                             [.string(c.path), .int(Int64(u.pos)), .int(Int64(u.del)), .string(u.ins)])
      if case .bool(true) = r { self.outside.markUndone(c.id) } else { self.status.note("Undo: open \(c.path) first") }
    }
  }

  @objc func toggleFollowEdits(_ sender: Any?) { followEdits.toggle() }
}

/// The pill over the editor when an outside edit lands out of view (Follow off): who and where; a click goes there.
@MainActor final class EditPill: NSButton {
  private(set) var change: OutsideEdits.Change?
  var onClick: (() -> Void)?
  private var hideWork: DispatchWorkItem?

  init() {
    super.init(frame: .zero)
    // a solid accent pill, readable over any text
    isBordered = false
    wantsLayer = true
    layer?.cornerRadius = 11
    layer?.backgroundColor = NSColor.controlAccentColor.cgColor
    layer?.shadowOpacity = 0.25
    layer?.shadowRadius = 4
    layer?.shadowOffset = CGSize(width: 0, height: -1)
    font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
    target = self
    action = #selector(clicked)
    toolTip = "Go to this edit and follow the next ones (View ▸ Follow Edits)"
    isHidden = true
  }
  required init?(coder: NSCoder) { fatalError() }

  func show(_ c: OutsideEdits.Change, line: Int?, above: Bool = false, in host: NSView) {
    change = c
    let t = "\(above ? "↑" : "↓") \(c.who) edited \(c.path)\(line.map { ":\($0)" } ?? "") · Follow"
    attributedTitle = NSAttributedString(string: t, attributes: [.foregroundColor: NSColor.white, .font: font ?? .systemFont(ofSize: 11)])
    if superview !== host { removeFromSuperview(); host.addSubview(self, positioned: .above, relativeTo: nil) }
    sizeToFit()
    frame.size.width += 24
    frame.size.height = 22
    frame.origin = NSPoint(x: ((host.bounds.width - frame.width) / 2).rounded(), y: host.isFlipped ? host.bounds.height - frame.height - 36 : 36)  // (above a status line)
    autoresizingMask = [.minXMargin, .maxXMargin, host.isFlipped ? .minYMargin : .maxYMargin]
    isHidden = false
    hideWork?.cancel()
    let w = DispatchWorkItem { [weak self] in self?.hide() }
    hideWork = w
    DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: w)
  }

  func hide() { isHidden = true; change = nil }
  @objc private func clicked() { onClick?() }
}
