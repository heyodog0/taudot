// Keys (with IME and dead keys through NSTextInputClient), mouse, and trackpad scrolling that follows the finger.
import AppKit
import TaudotShared

extension EditorView: @preconcurrency NSTextInputClient {
  // MARK: keys

  static let specialKeys: [Int: String] = [
    NSUpArrowFunctionKey: "Up", NSDownArrowFunctionKey: "Down", NSLeftArrowFunctionKey: "Left",
    NSRightArrowFunctionKey: "Right", NSHomeFunctionKey: "Home", NSEndFunctionKey: "End",
    NSPageUpFunctionKey: "PageUp", NSPageDownFunctionKey: "PageDown", NSDeleteFunctionKey: "Del",
    NSInsertFunctionKey: "Insert", NSHelpFunctionKey: "Help",
  ]
  static let keyCodes: [UInt16: String] = [36: "CR", 76: "kEnter", 48: "Tab", 51: "BS", 53: "Esc", 117: "Del", 49: "Space"]

  /// The Neovim key notation for an event, or nil to let the text input system handle it.
  public func keyNotation(_ e: NSEvent) -> String? {
    let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let ctrl = f.contains(.control), shift = f.contains(.shift), alt = f.contains(.option), cmd = f.contains(.command)
    let meta = alt && isMeta(e)
    func wrap(_ name: String, shiftOK: Bool = true) -> String {
      var m = ""
      if cmd { m += "D-" }
      if ctrl { m += "C-" }
      if meta { m += "M-" }
      if shift && shiftOK { m += "S-" }
      return m.isEmpty && name.count == 1 ? name : "<\(m)\(name)>"
    }
    if let name = Self.keyCodes[e.keyCode] {
      if name == "Space" { return (ctrl || meta || cmd || shift) ? wrap("Space") : nil }
      return wrap(name)
    }
    if let scalar = e.charactersIgnoringModifiers?.unicodeScalars.first {
      let v = Int(scalar.value)
      if let name = Self.specialKeys[v] { return wrap(name) }
      if v >= NSF1FunctionKey && v <= NSF35FunctionKey { return wrap("F\(v - NSF1FunctionKey + 1)") }
    }
    guard ctrl || meta || cmd else { return nil }
    guard var ch = e.charactersIgnoringModifiers, !ch.isEmpty else { return nil }
    // charactersIgnoringModifiers keeps Shift: "A" for Shift-a. Neovim wants <C-S-a> for that, <M-A> is fine.
    var shiftOK = false
    if ctrl || cmd, let c = ch.first, c.isLetter, c.isUppercase { ch = ch.lowercased(); shiftOK = true }
    if ch == "<" { ch = "lt" }
    if ch == "\\" { ch = "Bslash" }
    if ch == "|" { ch = "Bar" }
    return wrap(ch, shiftOK: shiftOK)
  }

  /// Left and right Option can be Meta separately (VimR does this too): e.g. right Option still types accents.
  func isMeta(_ e: NSEvent) -> Bool {
    let raw = e.modifierFlags.rawValue
    let left = raw & UInt(NX_DEVICELALTKEYMASK) != 0, right = raw & UInt(NX_DEVICERALTKEYMASK) != 0
    if !left && !right { return optionAsMeta }
    return (left && optionAsMeta) || (right && rightOptionAsMeta)
  }

  /// `typingResumesTerminal`: out of Terminal mode (scrolled back), go back in before the key. Once per return: the
  /// keys after it, before Neovim reports the mode, would otherwise send another `i` to the program as text.
  @discardableResult func resumeTerminal() -> Bool {
    guard typingResumesTerminal, ui.modeName == "normal", !terminalResumePending else { return false }
    terminalResumePending = true
    nvim.input("i")
    return true
  }

  public override func keyDown(with event: NSEvent) {
    if onKeyDown?(event) == true { return }
    stats.keyDown(event.timestamp)
    NSCursor.setHiddenUntilMouseMoves(true)
    // Scrolled back in a terminal (out of Terminal mode): a key goes back to the prompt first, then to the program.
    // Esc only goes back (it would interrupt the program).
    if resumeTerminal() && event.keyCode == 53 { return }
    if markedText == nil, let k = keyNotation(event) {
      nvim.input(k)
      stats.handed()
      return
    }
    keyDownHandled = false
    interpretKeyEvents([event])
    stats.handed()
  }

  public override func performKeyEquivalent(with event: NSEvent) -> Bool {
    // Cmd-keys go to the menus first (super); unhandled ones reach Neovim as <D-...> through keyDown.
    // Ctrl-Tab and friends would otherwise be eaten by AppKit.
    if window?.firstResponder === self, event.type == .keyDown {
      let f = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      // Cmd-Ctrl-Space: the system emoji picker.
      if f.contains([.command, .control]) && event.keyCode == 49 { return super.performKeyEquivalent(with: event) }
      if f.contains(.control) && !f.contains(.command), let k = keyNotation(event) {
        resumeTerminal()  // (as keyDown: back to the prompt)
        nvim.input(k)
        return true
      }
    }
    return super.performKeyEquivalent(with: event)
  }

  public func insertText(_ string: Any, replacementRange: NSRange) {
    let s = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
    markedText = nil
    needsFrame = true; wake()
    if s.isEmpty { return }
    nvim.input(s.replacingOccurrences(of: "<", with: "<lt>"))
  }

  public override func doCommand(by selector: Selector) {
    // Keys AppKit turned into commands that keyNotation didn't take (rare): nothing to do.
  }

  public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    let s = (string as? NSAttributedString) ?? NSAttributedString(string: (string as? String) ?? "")
    markedText = s.length == 0 ? nil : s
    needsFrame = true; wake()
  }

  public func unmarkText() { markedText = nil; needsFrame = true; wake() }
  public func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
  public func markedRange() -> NSRange { markedText.map { NSRange(location: 0, length: $0.length) } ?? NSRange(location: NSNotFound, length: 0) }
  public func hasMarkedText() -> Bool { markedText != nil }
  public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
  public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
  public func characterIndex(for point: NSPoint) -> Int { NSNotFound }

  public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
    guard let t = cursorTarget, let window else { return .zero }
    let r = NSRect(x: CGFloat(t.x) / scale, y: CGFloat(t.y) / scale, width: CGFloat(cw) / scale, height: lineHeight)
    return window.convertToScreen(convert(r, to: nil))
  }

  // MARK: focus

  public override func becomeFirstResponder() -> Bool {
    focused = true
    if attached { nvim.send("nvim_ui_set_focus", [.bool(true)]) }
    return true
  }

  public override func resignFirstResponder() -> Bool {
    focused = false
    if attached { nvim.send("nvim_ui_set_focus", [.bool(false)]) }
    return true
  }

  // MARK: mouse

  /// The topmost grid under a point (view coordinates) and the cell in it.
  func hit(_ p: NSPoint, grid only: Int? = nil) -> (grid: Int, row: Int, col: Int)? {
    let px = Float(p.x * scale), py = Float(p.y * scale)
    for w in ui.drawOrder.reversed() {
      guard let g = ui.grids[w.grid] else { continue }
      if let only, w.grid != only { continue }
      let r = windowRect(w, g)
      if only != nil || (px >= r.x && px < r.x + r.w && py >= r.y && py < r.y + r.h) {
        let row = max(0, min(g.height - 1, Int(((py - r.y) / ch).rounded(.down))))
        let col = max(0, min(g.width - 1, Int(((px - r.x) / cw).rounded(.down))))
        return (w.grid, row, col)
      }
    }
    return nil
  }

  func mouseMods(_ e: NSEvent) -> String {
    let f = e.modifierFlags
    var m = ""
    if f.contains(.shift) { m += "S" }
    if f.contains(.control) { m += "C" }
    if f.contains(.option) { m += "A" }
    if f.contains(.command) { m += "D" }
    return m
  }

  func mouse(_ e: NSEvent, button: String, action: String) {
    let p = convert(e.locationInWindow, from: nil)
    let only: Int? = action == "drag" || action == "release" ? mouseDownGrid : nil
    guard attached, let h = hit(p, grid: only) else { return }
    if action == "press" { mouseDownGrid = h.grid }
    if action == "drag" && (h.row, h.col) == lastMouseCell { return }
    lastMouseCell = (h.row, h.col)
    nvim.send("nvim_input_mouse", [.string(button), .string(action), .string(mouseMods(e)), .int(Int64(h.grid)), .int(Int64(h.row)), .int(Int64(h.col))])
  }

  public override func mouseDown(with e: NSEvent) { window?.makeFirstResponder(self); mouse(e, button: "left", action: "press") }
  public override func mouseDragged(with e: NSEvent) { mouse(e, button: "left", action: "drag") }
  public override func mouseUp(with e: NSEvent) { mouse(e, button: "left", action: "release") }
  public override func rightMouseDown(with e: NSEvent) { mouse(e, button: "right", action: "press") }
  public override func rightMouseDragged(with e: NSEvent) { mouse(e, button: "right", action: "drag") }
  public override func rightMouseUp(with e: NSEvent) { mouse(e, button: "right", action: "release") }
  public override func otherMouseDown(with e: NSEvent) { mouse(e, button: "middle", action: "press") }
  public override func otherMouseDragged(with e: NSEvent) { mouse(e, button: "middle", action: "drag") }
  public override func otherMouseUp(with e: NSEvent) { mouse(e, button: "middle", action: "release") }

  // MARK: scrolling
  //
  // Trackpad: the view follows the finger by pixels (`SmoothScroll.finger`) and Neovim is asked to scroll by screen
  // rows (<C-e>/<C-y>; synced buffers have 'smoothscroll', so one is one row) so that it stays at most a row ahead
  // of the finger: the rows coming into view then exist. Each `scroll_delta` that comes back pays off the finger
  // offset, so the text never jumps. Neovim is never asked past the end (the last row at the bottom) or the top;
  // there the gesture stops, and a part of a row pushed past it springs back once. When the gesture (with its
  // momentum) ends and every asked row has arrived, the leftover (under a row, in the direction of travel) eases out.

  public override func scrollWheel(with e: NSEvent) {
    guard attached else { return }
    // Events without a window (synthetic ones) carry screen coordinates.
    let p = e.window == nil && window != nil ? convert(window!.convertPoint(fromScreen: e.locationInWindow), from: nil) : convert(e.locationInWindow, from: nil)
    guard let h = hit(p), let w = ui.windows[h.grid], w.kind != .message, h.grid != 1 else { return }
    // A terminal in Terminal mode keeps its view at the bottom, so scrolling the window does nothing: hand Neovim
    // real wheel events, one a row's worth of movement. It leaves Terminal mode and scrolls back through the output
    // (from then on the smooth path below), or passes them to the program if it asked for the mouse.
    if ui.modeName == "terminal" {
      terminalWheel += e.hasPreciseScrollingDeltas ? -Double(e.scrollingDeltaY) * Double(scale) / Double(font.cellHeight) : -Double(e.scrollingDeltaY)
      while abs(terminalWheel) >= 1 {
        let up = terminalWheel < 0
        terminalWheel += up ? 1 : -1
        nvim.send("nvim_input_mouse", [.string("wheel"), .string(up ? "up" : "down"), .string(mouseMods(e)), .int(Int64(h.grid)), .int(Int64(h.row)), .int(Int64(h.col))])
      }
      return
    }
    terminalWheel = 0
    if !e.hasPreciseScrollingDeltas {
      // A mouse wheel: three rows a notch, animated by the spring.
      let rows = Int((-e.scrollingDeltaY * 3).rounded())
      if rows != 0 { scrollRows(grid: h.grid, win: w.win, rows) }
      if abs(e.scrollingDeltaX) > 0.5 {
        let dir = e.scrollingDeltaX > 0 ? "left" : "right"
        nvim.send("nvim_input_mouse", [.string("wheel"), .string(dir), .string(mouseMods(e)), .int(Int64(h.grid)), .int(Int64(h.row)), .int(Int64(h.col))])
      }
      return
    }
    let starts = e.phase == .began || e.phase == .mayBegin
    if starts || (fingerGrid != h.grid && e.momentumPhase == []) {
      if fingerGrid != 0 && fingerGrid != h.grid { fingerActive = false; settleFinger(force: true) }
      if fingerGrid != h.grid { fingerRequested = 0; fingerGesture += 1 }  // (its accounting starts over: A16)
      fingerGrid = h.grid
      fingerActive = true
      fingerPullBack = false
    }
    guard fingerGrid == h.grid, var s = scrolls[h.grid] else { return }
    if e.momentumPhase == .began { fingerActive = true }
    // Natural scrolling is already applied: positive deltaY moves the content down, which is scrolling up.
    let rows = -Double(e.scrollingDeltaY) * Double(scale) / Double(font.cellHeight)
    // At a known end of this window: pushing on does nothing (no overshoot and spring-back each time).
    let edge = edgeGrid == h.grid && edgeLines == w.lineCount ? fingerEdge : 0
    let pushing = edge != 0 && rows.sign == (edge > 0 ? .plus : .minus)
    if !pushing && rows != 0 { fingerEdge = 0 }
    if rows != 0 {
      s.finger += rows
      // At the end the view goes as far as Neovim will be (its rows still on their way), not further.
      if pushing { s.finger = edge > 0 ? min(s.finger, Double(fingerRequested)) : max(s.finger, Double(fingerRequested)) }
      // Never further than the kept rows (it can't get there: Neovim keeps up within a row).
      let lim = Double(max(1, s.height - 1))
      s.finger = min(max(s.finger, -lim), lim)
      scrolls[h.grid] = s
      fingerActiveUntil = CACurrentMediaTime() + 0.25
      // Keep Neovim ahead of the finger by more than the next event moves, so the rows coming into view exist
      // before they are drawn (one row ahead left blank rows at a flick's 2.5 rows an event).
      let lead = min(Double(max(1, s.height / 3)), 1 + abs(rows) * 2)
      var n = 0
      if rows > 0 { n = max(0, Int((s.finger + lead).rounded(.up)) - fingerRequested) }
      else { n = min(0, Int((s.finger - lead).rounded(.down)) - fingerRequested) }
      if n != 0 && !pushing {
        fingerRequested += n
        scrollRows(grid: h.grid, win: w.win, n, finger: true)
      }
      needsFrame = true
      wake()
    }
    let fingersUp = e.phase == .ended || e.phase == .cancelled
    let momentumDone = e.momentumPhase == .ended || e.momentumPhase == .cancelled
    if momentumDone {
      fingerActive = false
      settleFingerIfDone()
    } else if fingersUp {
      // Momentum may follow (its .began comes within a few ms); if not, the gesture is over.
      let g = h.grid
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
        guard let self, self.fingerGrid == g, CACurrentMediaTime() > self.fingerActiveUntil - 0.2 else { return }
        self.fingerActive = false
        self.settleFingerIfDone()
      }
    }
  }

  /// Once the gesture is over and every row asked for has arrived, ease the leftover (under a row) to where Neovim is.
  func settleFingerIfDone() {
    guard fingerGrid != 0, !fingerActive else { return }
    if fingerRequested == 0, let s = scrolls[fingerGrid], abs(s.finger) >= 0.5, !fingerPullBack,
       let win = ui.windows[fingerGrid]?.win {
      // Neovim is ahead by the lead: bring it back to the row nearest the view, so what's left to ease is under
      // half a row.
      fingerPullBack = true
      let n = Int(s.finger.rounded())
      fingerRequested += n
      scrollRows(grid: fingerGrid, win: win, n, finger: true)
      return
    }
    if fingerRequested == 0 { settleFinger(force: true); return }
    // Rows still on their way: wait for them, but not for ever.
    let g = fingerGrid
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
      guard let self, self.fingerGrid == g, !self.fingerActive else { return }
      self.settleFinger(force: true)
    }
  }

  func settleFinger(force: Bool) {
    fingerPullBack = false
    fingerGesture += 1
    guard fingerGrid != 0, var s = scrolls[fingerGrid] else { fingerGrid = 0; return }
    s.spring.position += s.finger
    s.finger = 0
    scrolls[fingerGrid] = s
    fingerGrid = 0
    fingerRequested = 0
    fingerActiveUntil = 0
    needsFrame = true
    wake()
  }

  /// Scroll a window by `n` screen rows (positive: down), never past the top or past the last row at the bottom.
  /// For the finger: when Neovim stops short (an end), stop the gesture there and spring back what was past it.
  func scrollRows(grid: Int, win: Int, _ n: Int, finger: Bool = false) {
    let gesture = fingerGesture
    Task { @MainActor in
      if finger { fingerReplies += 1 }
      let r = (try? await nvim.execLua(scrollLua, [.int(Int64(win)), .int(Int64(n))]))?.array
      if finger { fingerReplies -= 1 }
      let done = r?.first?.int ?? 0, moved = r.flatMap { $0.count > 1 ? $0[1].int : nil } ?? done
      // Count what Neovim really moved, not what was asked (scrolloff and the like can differ).
      let mine = finger && grid == fingerGrid && gesture == fingerGesture
      if mine { fingerRequested += moved - n }
      if ProcessInfo.processInfo.environment["TAUDOT_DEBUG"] != nil { FileHandle.standardError.write(String(format: "%.3f scroll n %d done %d moved %d finger %.2f requested %d\n", CACurrentMediaTime(), n, done, moved, scrolls[grid]?.finger ?? 0, fingerRequested).data(using: .utf8)!) }
      guard mine, done != n else { return }
      debugSnapBacks += 1
      fingerEdge = n.signum()
      edgeGrid = grid
      edgeLines = ui.windows[grid]?.lineCount ?? 0
      if var s = scrolls[grid] {
        // The view may show at most what Neovim will: the rows still to come, no more.
        let excess = n > 0 ? s.finger - Double(fingerRequested) : Double(fingerRequested) - s.finger
        if excess > 0 {
          let back = n > 0 ? excess : -excess
          s.finger -= back
          s.spring.position += back
        }
        scrolls[grid] = s
      }
      needsFrame = true
      wake()
    }
  }
}

/// Scroll window `win` by `n` screen rows (<C-e> / <C-y>; one row each with 'smoothscroll'), clamped so the top
/// stays at the buffer's start and the end never rises above the window's bottom. Returns the rows asked of Neovim.
let scrollLua = """
local win, n = ...
local function top() return vim.api.nvim_win_call(win, vim.fn.winsaveview) end
-- Screen rows from view a's top down to view b's top (negative when b is above a).
local function between(a, b)
  local sa, sb = a.skipcol or 0, b.skipcol or 0
  if a.topline == b.topline and sa == sb then return 0 end
  local up = b.topline < a.topline or (b.topline == a.topline and sb < sa)
  if up then a, b, sa, sb = b, a, sb, sa end
  local r = vim.api.nvim_win_text_height(win, { start_row = a.topline - 1, start_vcol = sa, end_row = b.topline - 1, end_vcol = sb }).all
  return up and -r or r
end
local view = top()
if n > 0 then
  local rows = vim.api.nvim_win_text_height(win, { start_row = view.topline - 1, start_vcol = view.skipcol or 0 }).all
  local room = rows - vim.fn.getwininfo(win)[1].height
  if room <= 0 then return { 0, 0 } end
  n = math.min(n, room)
else
  if view.topline <= 1 and (view.skipcol or 0) == 0 then return { 0, 0 } end
  local above = vim.api.nvim_win_text_height(win, { start_row = 0, end_row = view.topline - 1, end_vcol = view.skipcol or 0 }).all
  if above <= 0 then return { 0, 0 } end
  n = -math.min(-n, above)
end
vim.api.nvim_win_call(win, function()
  vim.cmd('normal! ' .. math.abs(n) .. (n > 0 and '\\5' or '\\25'))
end)
return { n, between(view, top()) }
"""
