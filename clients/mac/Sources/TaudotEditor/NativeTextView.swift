// The text view's keys: completion (opens on `\`, `{`, `,`; ↑↓ to move, Tab or Return to accept, Esc to close),
// `}` closing a `\begin`, Return opening an indented line inside one, ⌘/ toggling `% `.
import AppKit
import TaudotShared

public struct CompletionItem: Equatable {
  public var label: String
  public var kind: String
  public var detail: String
  public var insert: String
  /// Byte offset in `insert` for the caret.
  public var cursor: Int?
}

public struct CompletionResult: Equatable {
  /// UTF-16 offsets in the view's text.
  public var from: Int
  public var to: Int
  public var context: String?
  public var items: [CompletionItem]
}

@MainActor public final class NativeTextView: NSTextView {
  weak var owner: NativeEditorView?
  private var completing: CompletionResult?
  private var request = 0

  var popup: CompletionPopup? { owner?.popup }
  /// Vim's caret shape (VimEngine.cursorShape); nil: the system's bar. Anything else is drawn by `caretView` (TextKit 2
  /// draws its own insertion indicator and doesn't ask `drawInsertionPoint`), in the theme's cursor colour with the
  /// character under it in the background colour, like Neovim. It blinks at the system rate, solid while the caret
  /// moves or the text changes and for half a second after. The system caret is hidden meanwhile.
  var caretShape: VimEngine.CursorShape? {
    didSet {
      guard caretShape != oldValue else { return }
      insertionPointColor = caretShape == nil ? cursorColor : .clear
      updateCaret()
    }
  }
  /// The theme's cursor colour (the system caret's, and ours).
  var cursorColor: NSColor = .textColor {
    didSet { if caretShape == nil { insertionPointColor = cursorColor }; caretView.needsDisplay = true }
  }
  /// Vim's normal and visual modes (for checks).
  var blockCaret: Bool { caretShape == .block }
  /// Draw the caret even when the window isn't key (checks).
  var caretAlwaysShown = false
  let caretView = VimCaretView()
  /// Metal mode's extended selections and kept column (NativeTextView+Metal.swift).
  let metalMoves = MetalMoves()
  private var keyObservers: [NSObjectProtocol] = []

  /// Metal mode: the caret is drawn by MetalTextView; shown (window key, keys here) and in a blink's on phase.
  var caretShown = false
  var caretOn = true
  var isMetal: Bool { owner?.textLayout != nil }
  /// Metal: draw the caret now (bar: only without a selection).
  var caretVisible: Bool { caretShown && caretOn && (caretShape != nil || selectedRange().length == 0) && markedRange().length == 0 }

  /// The block caret's width at an offset: its character's, at least half an "M".
  func blockWidth(at loc: Int) -> CGFloat {
    guard let f = font else { return 8 }
    let s = string as NSString
    var w = ("M" as NSString).size(withAttributes: [.font: f]).width
    if loc < s.length, s.character(at: loc) != 10 {
      let ch = s.substring(with: s.rangeOfComposedCharacterSequence(at: loc))
      w = max(w * 0.5, (ch as NSString).size(withAttributes: [.font: f]).width)
    }
    return w
  }

  /// Put our caret where the selection's head is now.
  func updateCaret() {
    if isMetal {
      let shown = caretAlwaysShown || (window?.isKeyWindow == true && window?.firstResponder === self)
      caretShown = shown
      if shown { restartBlink() } else { stopBlink() }
      owner?.metalView?.setNeedsRender()
      return
    }
    if caretView.superview == nil { addSubview(caretView) }
    guard let shape = caretShape, let f = font,
          caretAlwaysShown || (window?.isKeyWindow == true && window?.firstResponder === self) else {
      caretView.isHidden = true
      stopBlink()
      return
    }
    let loc = min(selectedRange().location, (string as NSString).length)
    guard let r = caretRect(loc) else { caretView.isHidden = true; stopBlink(); return }
    let s = string as NSString
    var ch = ""
    var w = ("M" as NSString).size(withAttributes: [.font: f]).width
    if loc < s.length, s.character(at: loc) != 10 {
      ch = s.substring(with: s.rangeOfComposedCharacterSequence(at: loc))
      w = max(w * 0.5, (ch as NSString).size(withAttributes: [.font: f]).width)
    }
    let h = min(r.height, ceil(f.ascender - f.descender + f.leading))
    caretView.frame = NSRect(x: r.minX, y: r.minY, width: w, height: h).integral
    caretView.shape = shape
    caretView.char = ch
    caretView.font = (loc < s.length ? textStorage?.attribute(.font, at: loc, effectiveRange: nil) as? NSFont : nil) ?? f
    caretView.color = cursorColor
    caretView.background = backgroundColor
    caretView.isHidden = false
    restartBlink()
    caretView.needsDisplay = true
  }

  // MARK: blinking

  /// The system's blink periods (NSTextInsertionPointBlinkPeriodOn/Off, ms; AppKit's default 560 each), and how long
  /// the caret stays solid after it moves or the text changes. A period of 0 (or less): no blinking.
  var blinkOn: TimeInterval = NativeTextView.systemBlink("NSTextInsertionPointBlinkPeriodOn")
  var blinkOff: TimeInterval = NativeTextView.systemBlink("NSTextInsertionPointBlinkPeriodOff")
  var blinkRest: TimeInterval = 0.5
  private var blinkTimer: Timer?

  static func systemBlink(_ key: String) -> TimeInterval {
    let ms = UserDefaults.standard.object(forKey: key) as? Double ?? 560
    return ms / 1000
  }

  /// Solid now; blinking again after `blinkRest` at rest.
  private func restartBlink() {
    caretView.alphaValue = 1
    caretOn = true
    blinkTimer?.invalidate()
    blinkTimer = nil
    guard blinkOn > 0, blinkOff > 0 else { return }
    schedule(after: max(blinkRest, blinkOn), on: false)  // (at least one full on period first)
  }

  private func schedule(after t: TimeInterval, on: Bool) {
    let timer = Timer(timeInterval: t, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.isMetal ? self.caretShown : !self.caretView.isHidden else { return }
        self.caretView.alphaValue = on ? 1 : 0
        self.caretOn = on
        if self.isMetal { self.owner?.metalView?.setNeedsRender() }
        self.schedule(after: on ? self.blinkOn : self.blinkOff, on: !on)
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    blinkTimer = timer
  }

  private func stopBlink() {
    blinkTimer?.invalidate()
    blinkTimer = nil
    caretView.alphaValue = 1
    caretOn = true
  }

  /// For checks: Vim's caret is up (either editor), and where (this view's coordinates).
  var vimCaretShown: Bool { isMetal ? caretShape != nil && caretShown : !caretView.isHidden }
  var vimCaretFrame: NSRect {
    guard let l = owner?.textLayout else { return caretView.frame }
    let r = l.caretRect(min(selectedRange().location, (string as NSString).length))
    return NSRect(x: r.minX, y: r.minY, width: blockWidth(at: selectedRange().location), height: r.height)
  }

  /// For checks: the block is drawn (not in a blink's off phase).
  var caretLit: Bool { isMetal ? caretShown && caretOn && caretShape != nil : !caretView.isHidden && caretView.alphaValue > 0.5 }

  /// The caret's rect at a UTF-16 offset, in this view (from TextKit 2's layout).
  private func caretRect(_ loc: Int) -> NSRect? {
    guard let tlm = textLayoutManager, let tcs = tlm.textContentManager as? NSTextContentStorage,
          let at = tcs.location(tcs.documentRange.location, offsetBy: loc) else { return nil }
    var out: NSRect?
    tlm.enumerateTextSegments(in: NSTextRange(location: at), type: .selection, options: [.rangeNotRequired]) { _, frame, _, _ in
      out = frame
      return false
    }
    guard let r = out else { return nil }
    let o = textContainerOrigin
    return NSRect(x: r.minX + o.x, y: r.minY + o.y, width: r.width, height: r.height)
  }

  public override func becomeFirstResponder() -> Bool {
    defer { updateCaret() }
    return super.becomeFirstResponder()
  }

  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    for o in keyObservers { NotificationCenter.default.removeObserver(o) }
    keyObservers = []
    guard let w = window else { return }
    for n in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
      keyObservers.append(NotificationCenter.default.addObserver(forName: n, object: w, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.updateCaret() }
      })
    }
  }

  public override func keyDown(with e: NSEvent) {
    let key = Latency.shared.keyDown(at: e.timestamp)
    handle(e)
    Latency.shared.record(.handed, key: key)
    if isMetal, let o = owner { o.renderKey(key) } else { Latency.shared.awaitFrame(key: key) }
  }

  private func handle(_ e: NSEvent) {
    // Esc that would do nothing (normal mode, no list open) closes the find bar.
    if e.keyCode == 53, popup?.isVisible != true, owner?.vim.map({ $0.mode == .normal && $0.cmdline == nil }) ?? true,
       owner?.onFindEscape?() == true { return }
    if let v = owner?.vim, let k = VimKey.from(e) {
      if v.mode == .insert && v.cmdline == nil {
        if k.name == "<Esc>" || k.name == "<C-[>" || k.name == "<C-c>" { closePopup(); v.handle(k); return }
        super.keyDown(with: e)
        return
      }
      closePopup()
      if v.handle(k) { return }
    }
    super.keyDown(with: e)
  }


  // MARK: keys

  public override func performKeyEquivalent(with e: NSEvent) -> Bool {
    let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if mods == .command && e.charactersIgnoringModifiers == "/" && window?.firstResponder === self {
      toggleComment()
      return true
    }
    return super.performKeyEquivalent(with: e)
  }

  public override func insertText(_ string: Any, replacementRange: NSRange) {
    super.insertText(string, replacementRange: replacementRange)
    let s = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
    if s == "}" { closeBegin() }
    if completing != nil { refilter(typed: s) }
    if s == "\\" || s == "{" || s == "," { complete() }
  }

  public override func doCommand(by selector: Selector) {
    if popup?.isVisible == true {
      switch selector {
      case #selector(moveUp(_:)): popup?.move(-1); return
      case #selector(moveDown(_:)): popup?.move(1); return
      case #selector(insertTab(_:)), #selector(insertNewline(_:)): accept(); return
      case #selector(cancelOperation(_:)): closePopup(); return
      case #selector(deleteBackward(_:)):
        super.doCommand(by: selector)
        refilter(typed: "")
        return
      default: closePopup()
      }
    }
    if selector == #selector(insertNewline(_:)) { newline(); return }
    super.doCommand(by: selector)
  }

  public override func resignFirstResponder() -> Bool {
    closePopup()
    defer { updateCaret() }
    return super.resignFirstResponder()
  }

  /// A double-click (after it has selected the word): the app shows that place in the PDF, as Neovim mode does.
  public var onDoubleClick: (() -> Void)?

  /// Not under the pointer (a divider's grip overlaps the text's edge): leave the cursor alone. NSTextView sets the
  /// I-beam on every move inside its visible rect, which fought the grip's resize cursor (it showed only on the far
  /// side of the divider).
  private func covered(_ e: NSEvent) -> Bool {
    guard let c = window?.contentView, let top = c.hitTest(c.convert(e.locationInWindow, from: nil)) else { return false }
    return !top.isDescendant(of: self)
  }
  public override func mouseMoved(with event: NSEvent) { if !covered(event) { super.mouseMoved(with: event) } }
  public override func cursorUpdate(with event: NSEvent) { if !covered(event) { super.cursorUpdate(with: event) } }

  public override func mouseDown(with event: NSEvent) {
    if isMetal { metalMouseDown(event); return }
    closePopup()
    super.mouseDown(with: event)  // tracks until the mouse comes up
    if event.clickCount == 2 { onDoubleClick?() }
  }

  // MARK: ⌘/

  public func toggleComment() {
    let s = string as NSString
    let sel = selectedRange()
    var lines = s.lineRange(for: sel)
    // A selection ending at the start of a line doesn't take that line.
    if sel.length > 0, NSMaxRange(sel) == lines.location + lines.length, NSMaxRange(sel) > 0, s.character(at: NSMaxRange(sel) - 1) == 10 {
      lines = s.lineRange(for: NSRange(location: sel.location, length: sel.length - 1))
    }
    var text = s.substring(with: lines)
    let trailing = text.hasSuffix("\n")
    if trailing { text.removeLast() }
    let out = Comforts.toggleComment(text.components(separatedBy: "\n")).joined(separator: "\n") + (trailing ? "\n" : "")
    guard out != s.substring(with: lines), shouldChangeText(in: lines, replacementString: out) else { return }
    textStorage?.replaceCharacters(in: lines, with: out)
    didChangeText()
    let delta = (out as NSString).length - lines.length
    if sel.length == 0 {
      // The caret stays on the same character.
      let firstDelta = (out.components(separatedBy: "\n").first! as NSString).length - (text.components(separatedBy: "\n").first! as NSString).length
      setSelectedRange(NSRange(location: max(lines.location, sel.location + firstDelta), length: 0))
    } else {
      setSelectedRange(NSRange(location: lines.location, length: lines.length + delta - (trailing ? 1 : 0)))
    }
  }

  // MARK: \begin

  /// Just typed the `}` of `\begin{env}`: put `\end{env}` on a line below unless it is closed already.
  func closeBegin() {
    let s = string as NSString
    let loc = selectedRange().location
    guard let env = Comforts.beginEnding(s, at: loc), Comforts.matchingEnd(s, from: loc, env: env) == nil else { return }
    let line = s.lineRange(for: NSRange(location: loc, length: 0))
    let indent = String(s.substring(with: line).prefix { $0 == " " || $0 == "\t" })
    let lineEnd = NSMaxRange(line) - (s.substring(with: line).hasSuffix("\n") ? 1 : 0)
    let add = "\n" + indent + "\\end{\(env)}"
    let at = NSRange(location: lineEnd, length: 0)
    guard shouldChangeText(in: at, replacementString: add) else { return }
    textStorage?.replaceCharacters(in: at, with: add)
    didChangeText()
    setSelectedRange(NSRange(location: loc, length: 0))
  }

  var indentUnit: String { "  " }

  /// Return: keep the line's indent; on a `\begin` line, open an indented line inside (closing it if needed).
  func newline() {
    let s = string as NSString
    let loc = selectedRange().location
    let line = s.lineRange(for: NSRange(location: loc, length: 0))
    let lineText = s.substring(with: line)
    let indent = String(lineText.prefix { $0 == " " || $0 == "\t" })
    let lineEnd = NSMaxRange(line) - (lineText.hasSuffix("\n") ? 1 : 0)
    if loc == lineEnd, let b = Comforts.beginLine(s, lineAt: loc) {
      let closed = Comforts.matchingEnd(s, from: b.after, env: b.env) != nil
      let inner = "\n" + b.indent + indentUnit
      let add = inner + (closed ? "" : "\n" + b.indent + "\\end{\(b.env)}")
      insertText(add, replacementRange: selectedRange())
      setSelectedRange(NSRange(location: loc + (inner as NSString).length, length: 0))
      return
    }
    insertText("\n" + indent, replacementRange: selectedRange())
  }

  // MARK: completion

  func complete() {
    guard let o = owner, let ask = o.completer, let d = o.doc else { return }
    request += 1
    let mine = request
    let loc = selectedRange().location
    let s = string as NSString
    let line = s.lineRange(for: NSRange(location: loc, length: 0))
    let before = s.substring(with: NSRange(location: line.location, length: loc - line.location))
    let pos = Utf.utf8(d.text, loc)
    Task { @MainActor in
      guard let r = await ask(pos, before), mine == request, !r.items.isEmpty else {
        if mine == request { closePopup() }
        return
      }
      completing = r
      refilter(typed: "")
    }
  }

  /// Show the items matching what was typed since `from`, or close when the caret left the word.
  func refilter(typed: String) {
    guard let r = completing else { return }
    let s = string as NSString
    let loc = selectedRange().location
    guard loc >= r.from, loc - r.from < 200 else { closePopup(); return }
    let query = s.substring(with: NSRange(location: r.from, length: loc - r.from))
    let allowed: (Character) -> Bool = r.context == "command"
      ? { $0.isLetter || $0 == "\\" || $0 == "*" }
      : { !$0.isWhitespace && $0 != "}" && $0 != "{" && $0 != "," }
    if !query.allSatisfy(allowed) && !(r.context == "command" && query.isEmpty) { closePopup(); return }
    var scored: [(Int, Int, CompletionItem)] = []
    for (i, it) in r.items.enumerated() {
      if let sc = Comforts.fuzzy(query, it.label) { scored.append((sc, i, it)) }
    }
    scored.sort { ($0.0, $0.1) < ($1.0, $1.1) }
    let items = scored.prefix(200).map(\.2)
    if items.isEmpty { popup?.hide(); return }
    var actual = NSRange()
    let rect = firstRect(forCharacterRange: NSRange(location: r.from, length: 0), actualRange: &actual)
    popup?.show(items, below: rect, parent: window)
  }

  func closePopup() {
    completing = nil
    request += 1
    popup?.hide()
  }

  func accept() {
    guard let r = completing, let it = popup?.selected else { closePopup(); return }
    let loc = selectedRange().location
    let range = NSRange(location: r.from, length: max(0, loc - r.from))
    let ctx = r.context
    closePopup()
    insertText(it.insert, replacementRange: range)
    if let c = it.cursor {
      let pre = String(decoding: Array(it.insert.utf8)[..<min(c, it.insert.utf8.count)], as: UTF8.self)
      setSelectedRange(NSRange(location: r.from + (pre as NSString).length, length: 0))
    }
    let s = string as NSString
    let now = selectedRange().location
    if it.kind == "env" && ctx == "env" {
      // `\begin{fig` → `\begin{figure}` and its `\end`.
      let line = s.lineRange(for: NSRange(location: now, length: 0))
      let pre = s.substring(with: NSRange(location: line.location, length: now - line.location))
      if pre.range(of: "\\begin{", options: .backwards) != nil && !pre.hasSuffix("}") && pre.range(of: #"\\begin\{[^{}]*$"#, options: .regularExpression) != nil {
        if now < s.length && s.character(at: now) == 125 { setSelectedRange(NSRange(location: now + 1, length: 0)) } else { insertText("}", replacementRange: selectedRange()) }
        closeBegin()
      }
      return
    }
    // `\cite{}` and the like: ask for what goes in the braces.
    if it.kind == "command", now > 0, s.character(at: now - 1) == 123, now < s.length, s.character(at: now) == 125 {
      let name = it.label.dropFirst().lowercased()
      if name.contains("cite") || (name.hasSuffix("ref") && name != "href") || ["begin", "end", "input", "include", "includegraphics", "bibliography", "addbibresource"].contains(name) {
        complete()
      }
    }
  }
}

/// The completion list: a borderless child window under the word, kinds as small labels, details dimmed.
@MainActor final class CompletionPopup: NSObject, NSTableViewDataSource, NSTableViewDelegate {
  var style = EditorStyle()
  private var window: NSPanel?
  private let table = NSTableView()
  private var items: [CompletionItem] = []
  private weak var parent: NSWindow?
  /// Open (showing its list). Under an editor window that isn't on screen (background checks) it opens without being
  /// ordered in: a child window would order its parent in, onto the user's screen.
  private(set) var isVisible = false
  var selected: CompletionItem? { table.selectedRow >= 0 && table.selectedRow < items.count ? items[table.selectedRow] : nil }
  /// Labels shown, for checks.
  var labels: [String] { items.map(\.label) }

  private func make() -> NSPanel {
    let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 200), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    p.hasShadow = true
    p.isOpaque = false
    p.backgroundColor = .clear
    let box = NSVisualEffectView()
    box.material = .menu
    box.state = .active
    box.wantsLayer = true
    box.layer?.cornerRadius = 6
    box.layer?.masksToBounds = true
    let sv = NSScrollView()
    sv.drawsBackground = false
    sv.hasVerticalScroller = true
    sv.documentView = table
    table.addTableColumn(NSTableColumn(identifier: .init("c")))
    table.headerView = nil
    table.backgroundColor = .clear
    table.rowHeight = 20
    table.intercellSpacing = NSSize(width: 0, height: 0)
    table.dataSource = self
    table.delegate = self
    table.style = .plain
    table.target = self
    table.doubleAction = #selector(clicked)
    sv.frame = box.bounds
    sv.autoresizingMask = [.width, .height]
    box.addSubview(sv)
    p.contentView = box
    window = p
    return p
  }

  @objc func clicked() {
    if let tv = parent?.firstResponder as? NativeTextView { tv.accept() }
  }

  func show(_ list: [CompletionItem], below rect: NSRect, parent pw: NSWindow?) {
    let keep = selected?.label
    items = list
    let p = window ?? make()
    table.reloadData()
    let row = keep.flatMap { k in items.firstIndex { $0.label == k } } ?? 0
    table.selectRowIndexes([row], byExtendingSelection: false)
    table.scrollRowToVisible(row)
    let h = CGFloat(min(items.count, 10)) * table.rowHeight + 6
    p.setFrame(NSRect(x: rect.minX - 24, y: rect.minY - h - 2, width: 460, height: h), display: true)
    parent = pw
    isVisible = true
    guard pw?.isVisible == true else { return }
    if let pw, p.parent !== pw {
      p.parent?.removeChildWindow(p)
      pw.addChildWindow(p, ordered: .above)
    }
    p.orderFront(nil)
  }

  func hide() {
    isVisible = false
    guard let p = window, p.isVisible else { return }
    p.parent?.removeChildWindow(p)
    p.orderOut(nil)
  }

  func move(_ d: Int) {
    guard !items.isEmpty else { return }
    let r = max(0, min(items.count - 1, table.selectedRow + d))
    table.selectRowIndexes([r], byExtendingSelection: false)
    table.scrollRowToVisible(r)
  }

  func numberOfRows(in tableView: NSTableView) -> Int { items.count }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    let it = items[row]
    let f = NSTextField(labelWithString: "")
    f.lineBreakMode = .byTruncatingTail
    let size = max(11, style.fontSize - 1)
    let mono = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    let s = NSMutableAttributedString(string: it.label, attributes: [.font: mono, .foregroundColor: NSColor.labelColor])
    let short = ["command": "cmd"][it.kind] ?? it.kind
    s.append(NSAttributedString(string: "  " + short, attributes: [.font: NSFont.systemFont(ofSize: 9, weight: .medium), .foregroundColor: NSColor.tertiaryLabelColor]))
    if !it.detail.isEmpty {
      s.append(NSAttributedString(string: "  " + it.detail, attributes: [.font: NSFont.systemFont(ofSize: size - 1), .foregroundColor: NSColor.secondaryLabelColor]))
    }
    f.attributedStringValue = s
    let cell = NSTableCellView()
    cell.addSubview(f)
    f.frame = NSRect(x: 8, y: 2, width: 440, height: 16)
    return cell
  }
}

/// Vim's caret (NativeTextView.caretShape): a block with the character in the background colour on it, half a block,
/// or an underline.
final class VimCaretView: NSView {
  var shape: VimEngine.CursorShape = .block
  var char = ""
  var font: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
  var color: NSColor = .textColor
  var background: NSColor = .textBackgroundColor
  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override func draw(_ dirtyRect: NSRect) {
    let b = bounds
    let part: NSRect
    switch shape {
    case .block, .bar: part = b
    case .halfBlock: part = NSRect(x: 0, y: b.midY, width: b.width, height: b.height / 2)
    case .underline:
      let h = max(2, (b.height * 0.15).rounded())
      part = NSRect(x: 0, y: b.maxY - h, width: b.width, height: h)
    }
    color.setFill()
    part.fill()
    guard shape != .underline, !char.isEmpty else { return }
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(rect: part).addClip()
    (char as NSString).draw(at: .zero, withAttributes: [.font: font, .foregroundColor: background])
    NSGraphicsContext.restoreGraphicsState()
  }
}
