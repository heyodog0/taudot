// NativeTextView in Metal mode: still the storage, undo, input methods and the commands that work on characters, but
// everything that needs to know where text is on screen comes from our layout (TextLayout) instead of TextKit's,
// which is never asked to lay anything out.
import AppKit
import TaudotShared

/// Selection state for moves that extend it or keep a column.
@MainActor final class MetalMoves {
  /// The fixed end of a selection extended by moves, and the selection it produced.
  var anchor: Int?
  var extended: NSRange?
  /// The x up/down moves keep, and the caret it produced.
  var goal: CGFloat?
  var goalAt: NSRange?
}

extension NativeTextView {
  private var lay: TextLayout? { owner?.textLayout }

  // MARK: never TextKit

  public override func draw(_ dirtyRect: NSRect) {
    if isMetal { return }
    super.draw(dirtyRect)
  }

  public override func updateInsertionPointStateAndRestartTimer(_ restartFlag: Bool) {
    // (AppKit calls this on its own, e.g. on window updates; a blink restarts only when the caret moves, the text
    // changes or focus does, through updateCaret, else a busy main thread kept it solid)
    if isMetal {
      if caretShown != (caretAlwaysShown || (window?.isKeyWindow == true && window?.firstResponder === self)) { updateCaret() }
      return
    }
    super.updateInsertionPointStateAndRestartTimer(restartFlag)
  }

  public override func scrollRangeToVisible(_ range: NSRange) {
    guard isMetal, let o = owner else { super.scrollRangeToVisible(range); return }
    o.metalScrollToVisible(range)
  }

  public override var textContainerOrigin: NSPoint {
    guard let l = lay else { return super.textContainerOrigin }
    return NSPoint(x: l.origin.x - (textContainer?.lineFragmentPadding ?? 5), y: l.origin.y)
  }

  // MARK: geometry for input methods, popups, checks

  public override func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
    guard let l = lay, let o = owner, let w = window else { return super.firstRect(forCharacterRange: range, actualRange: actualRange) }
    let n = (string as NSString).length
    let r = NSRange(location: min(range.location, n), length: min(range.length, n - min(range.location, n)))
    var rect = l.caretRect(r.location)
    if r.length > 0, let first = l.rects(r).first {
      rect = first
      let (_, end) = l.visualLine(at: r.location)
      actualRange?.pointee = NSRange(location: r.location, length: min(r.length, max(0, end - r.location)))
    } else {
      actualRange?.pointee = r
    }
    let inWindow = o.docView.convert(rect, to: nil)
    return w.convertToScreen(inWindow)
  }

  public override func characterIndex(for point: NSPoint) -> Int {
    guard let l = lay, let o = owner, let w = window else { return super.characterIndex(for: point) }
    let p = o.docView.convert(w.convertPoint(fromScreen: point), from: nil)
    return l.offset(at: p)
  }

  public override func characterIndexForInsertion(at point: NSPoint) -> Int {
    guard let l = lay else { return super.characterIndexForInsertion(at: point) }
    return l.offset(at: point)  // (this view's coordinates are the document's)
  }

  // MARK: moves that need lines on screen

  private func moveVertically(_ lines: Int, extend: Bool) {
    guard let l = lay else { return }
    let m = metalMoves
    let sel = selectedRange()
    var head: Int
    var anchor: Int
    if extend {
      if let a = m.anchor, m.extended == sel { anchor = a; head = a == sel.location ? NSMaxRange(sel) : sel.location }
      else { anchor = sel.location; head = NSMaxRange(sel) }
    } else {
      // a selection collapses to the end it moves toward, then moves
      head = lines < 0 ? sel.location : NSMaxRange(sel)
      anchor = head
    }
    let goal = m.goalAt == sel ? m.goal : nil
    let (to, gx) = l.offset(from: head, lines: lines, goal: goal)
    head = to
    let r = extend ? NSRange(location: min(anchor, head), length: abs(head - anchor)) : NSRange(location: head, length: 0)
    setSelectedRange(r)
    m.goal = gx
    m.goalAt = r
    m.anchor = extend ? anchor : nil
    m.extended = extend ? r : nil
    scrollRangeToVisible(NSRange(location: head, length: 0))
  }

  private func moveToLineEdge(end: Bool, extend: Bool) {
    guard let l = lay else { return }
    let m = metalMoves
    let sel = selectedRange()
    var anchor = sel.location, head = NSMaxRange(sel)
    if extend, let a = m.anchor, m.extended == sel { anchor = a; head = a == sel.location ? NSMaxRange(sel) : sel.location }
    if !extend { head = end ? NSMaxRange(sel) : sel.location }
    let (a, b) = l.visualLine(at: head)
    // a wrapped line's end is the next line's start: stay before it
    var to = end ? b : a
    if end && to > a && to < (string as NSString).length && (string as NSString).character(at: to) != 10 {
      let (na, _) = l.visualLine(at: to)
      if na == to { to = max(a, to - 1); if (string as NSString).character(at: to) != 32 { to = b } }
    }
    let r = extend ? NSRange(location: min(anchor, to), length: abs(to - anchor)) : NSRange(location: to, length: 0)
    setSelectedRange(r)
    m.anchor = extend ? anchor : nil
    m.extended = extend ? r : nil
    m.goal = nil
    scrollRangeToVisible(NSRange(location: to, length: 0))
  }

  private var pageLines: Int {
    guard let l = lay, let o = owner else { return 20 }
    return max(1, Int(o.scroll.contentView.bounds.height / l.lineHeight) - 1)
  }

  public override func moveUp(_ sender: Any?) { if isMetal { moveVertically(-1, extend: false) } else { super.moveUp(sender) } }
  public override func moveDown(_ sender: Any?) { if isMetal { moveVertically(1, extend: false) } else { super.moveDown(sender) } }
  public override func moveUpAndModifySelection(_ sender: Any?) { if isMetal { moveVertically(-1, extend: true) } else { super.moveUpAndModifySelection(sender) } }
  public override func moveDownAndModifySelection(_ sender: Any?) { if isMetal { moveVertically(1, extend: true) } else { super.moveDownAndModifySelection(sender) } }
  public override func pageUp(_ sender: Any?) { if isMetal { scrollBy(lines: -pageLines); moveVertically(-pageLines, extend: false) } else { super.pageUp(sender) } }
  public override func pageDown(_ sender: Any?) { if isMetal { scrollBy(lines: pageLines); moveVertically(pageLines, extend: false) } else { super.pageDown(sender) } }
  public override func pageUpAndModifySelection(_ sender: Any?) { if isMetal { scrollBy(lines: -pageLines); moveVertically(-pageLines, extend: true) } else { super.pageUpAndModifySelection(sender) } }
  public override func pageDownAndModifySelection(_ sender: Any?) { if isMetal { scrollBy(lines: pageLines); moveVertically(pageLines, extend: true) } else { super.pageDownAndModifySelection(sender) } }
  public override func moveToBeginningOfLine(_ sender: Any?) { if isMetal { moveToLineEdge(end: false, extend: false) } else { super.moveToBeginningOfLine(sender) } }
  public override func moveToEndOfLine(_ sender: Any?) { if isMetal { moveToLineEdge(end: true, extend: false) } else { super.moveToEndOfLine(sender) } }
  public override func moveToLeftEndOfLine(_ sender: Any?) { if isMetal { moveToLineEdge(end: false, extend: false) } else { super.moveToLeftEndOfLine(sender) } }
  public override func moveToRightEndOfLine(_ sender: Any?) { if isMetal { moveToLineEdge(end: true, extend: false) } else { super.moveToRightEndOfLine(sender) } }
  public override func moveToBeginningOfLineAndModifySelection(_ sender: Any?) { if isMetal { moveToLineEdge(end: false, extend: true) } else { super.moveToBeginningOfLineAndModifySelection(sender) } }
  public override func moveToEndOfLineAndModifySelection(_ sender: Any?) { if isMetal { moveToLineEdge(end: true, extend: true) } else { super.moveToEndOfLineAndModifySelection(sender) } }
  public override func moveToLeftEndOfLineAndModifySelection(_ sender: Any?) { if isMetal { moveToLineEdge(end: false, extend: true) } else { super.moveToLeftEndOfLineAndModifySelection(sender) } }
  public override func moveToRightEndOfLineAndModifySelection(_ sender: Any?) { if isMetal { moveToLineEdge(end: true, extend: true) } else { super.moveToRightEndOfLineAndModifySelection(sender) } }

  // MARK: scrolling without moving the caret

  func scrollBy(lines: Int) {
    guard let l = lay, let o = owner else { return }
    let clip = o.scroll.contentView
    let maxY = max(0, o.docView.frame.height - clip.bounds.height)
    clip.setBoundsOrigin(NSPoint(x: clip.bounds.minX, y: max(0, min(maxY, clip.bounds.minY + CGFloat(lines) * l.lineHeight))))
    o.scroll.reflectScrolledClipView(clip)
  }

  public override func scrollPageUp(_ sender: Any?) { if isMetal { scrollBy(lines: -pageLines) } else { super.scrollPageUp(sender) } }
  public override func scrollPageDown(_ sender: Any?) { if isMetal { scrollBy(lines: pageLines) } else { super.scrollPageDown(sender) } }
  public override func scrollLineUp(_ sender: Any?) { if isMetal { scrollBy(lines: -1) } else { super.scrollLineUp(sender) } }
  public override func scrollLineDown(_ sender: Any?) { if isMetal { scrollBy(lines: 1) } else { super.scrollLineDown(sender) } }
  public override func scrollToBeginningOfDocument(_ sender: Any?) { if isMetal { scrollBy(lines: -Int.max / 4) } else { super.scrollToBeginningOfDocument(sender) } }
  public override func scrollToEndOfDocument(_ sender: Any?) { if isMetal { scrollBy(lines: Int.max / 4) } else { super.scrollToEndOfDocument(sender) } }
  public override func centerSelectionInVisibleArea(_ sender: Any?) {
    guard let l = lay, let o = owner else { super.centerSelectionInVisibleArea(sender); return }
    let c = l.caretRect(selectedRange().location)
    let clip = o.scroll.contentView
    let maxY = max(0, o.docView.frame.height - clip.bounds.height)
    clip.setBoundsOrigin(NSPoint(x: clip.bounds.minX, y: max(0, min(maxY, c.midY - clip.bounds.height / 2))))
    o.scroll.reflectScrolledClipView(clip)
  }

  // MARK: mouse

  /// A click in the document view: place the caret, extend with ⇧, words on a double click, lines on a triple; drag
  /// to select (scrolling at the edges).
  func metalMouseDown(_ e: NSEvent) {
    guard let l = lay, let o = owner, let w = window else { return }
    closePopup()
    w.makeFirstResponder(self)
    let at = l.offset(at: o.docView.convert(e.locationInWindow, from: nil))
    let gran: NSSelectionGranularity = e.clickCount >= 3 ? .selectByParagraph : e.clickCount == 2 ? .selectByWord : .selectByCharacter
    let sel = selectedRange()
    var anchorRange = selectionRange(forProposedRange: NSRange(location: at, length: 0), granularity: gran)
    if e.modifierFlags.contains(.shift) {
      anchorRange = NSRange(location: sel.location, length: 0)
      let a = sel.location, b = at
      setSelectedRange(NSRange(location: min(a, b), length: abs(b - a)), affinity: .downstream, stillSelecting: true)
    } else {
      setSelectedRange(anchorRange, affinity: .downstream, stillSelecting: true)
    }
    metalMoves.goal = nil
    var done = false
    while !done {
      guard let ev = w.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .periodic], until: .distantFuture, inMode: .eventTracking, dequeue: true) else { break }
      switch ev.type {
      case .leftMouseUp:
        done = true
      case .leftMouseDragged:
        o.docView.autoscroll(with: ev)
        let p = l.offset(at: o.docView.convert(ev.locationInWindow, from: nil))
        let r = selectionRange(forProposedRange: NSRange(location: p, length: 0), granularity: gran)
        let u = NSUnionRange(anchorRange, r)
        setSelectedRange(u, affinity: .downstream, stillSelecting: true)
        o.metalView?.render()
      default: break
      }
    }
    setSelectedRange(selectedRange(), affinity: .downstream, stillSelecting: false)
    if e.clickCount == 2 { onDoubleClick?() }
  }

  // MARK: VoiceOver

  public override func accessibilityFrame() -> NSRect {
    guard isMetal, let o = owner, let w = window else { return super.accessibilityFrame() }
    return w.convertToScreen(o.scroll.convert(o.scroll.bounds, to: nil))
  }

  public override func accessibilityFrame(for range: NSRange) -> NSRect {
    guard isMetal else { return super.accessibilityFrame(for: range) }
    return firstRect(forCharacterRange: range, actualRange: nil)
  }

  public override func accessibilityRange(for point: NSPoint) -> NSRange {
    guard isMetal else { return super.accessibilityRange(for: point) }
    return NSRange(location: characterIndex(for: point), length: 0)
  }
}
