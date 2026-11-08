// Vim keys in the native editor: VimEngine over the text view. Edits go through the text view's own edit path
// (shouldChangeText / didChangeText), so they reach the engine, undo, and keep the comforts working in insert mode.
import AppKit

@MainActor final class TextViewVimBuffer: VimBuffer {
  weak var view: NativeEditorView?
  init(_ v: NativeEditorView) { view = v }
  var tv: NativeTextView { view!.textView }

  var text: NSString { tv.string as NSString }
  var selection: NSRange {
    get { tv.selectedRange() }
    set {
      tv.setSelectedRange(newValue)
      tv.scrollRangeToVisible(NSRange(location: newValue.location + newValue.length, length: 0))
    }
  }

  func replace(_ range: NSRange, with string: String) {
    guard tv.shouldChangeText(in: range, replacementString: string) else { return }
    tv.textStorage?.replaceCharacters(in: range, with: string)
    tv.didChangeText()
  }

  // A command runs within one key event, and AppKit's undo manager groups each event's edits into one step. Keep
  // typing before or after it out of that step. (A change that enters insert mode, like `cw`, undoes in two steps:
  // the change, then what was typed.)
  func beginChange() { tv.breakUndoCoalescing() }
  func endChange() { tv.breakUndoCoalescing() }

  func undo() { tv.undoManager?.undo() }
  func redo() { tv.undoManager?.redo() }

  func displayLine(from loc: Int, by count: Int) -> Int {
    var at = loc
    let sel = tv.selectedRange()
    tv.setSelectedRange(NSRange(location: loc, length: 0))
    for _ in 0..<abs(count) {
      if count > 0 { tv.moveDown(nil) } else { tv.moveUp(nil) }
    }
    at = tv.selectedRange().location
    tv.setSelectedRange(sel)
    return at
  }

  var screenLines: ClosedRange<Int> { view?.visibleLines ?? 0...0 }

  func scroll(lines: Int) {
    guard let v = view else { return }
    let clip = v.scroll.contentView
    let maxY = max(0, v.documentHeight - clip.bounds.height)
    let y = max(0, min(maxY, clip.bounds.minY + CGFloat(lines) * v.lineHeight))
    NSAnimationContext.runAnimationGroup { c in
      c.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
      clip.animator().setBoundsOrigin(NSPoint(x: clip.bounds.minX, y: y))
    }
    v.scroll.reflectScrolledClipView(clip)
  }

  var clipboard: String? {
    get { NSPasteboard.general.string(forType: .string) }
    set {
      NSPasteboard.general.clearContents()
      if let newValue { NSPasteboard.general.setString(newValue, forType: .string) }
    }
  }

  func status(_ text: String) { view?.vimStatus(text) }
}

extension VimKey {
  /// The key an event types, as Vim names it; nil for keys Vim mode leaves alone (⌘ shortcuts).
  static func from(_ e: NSEvent) -> VimKey? {
    let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if mods.contains(.command) { return nil }
    switch e.keyCode {
    case 53: return VimKey("<Esc>")
    case 36, 76: return VimKey("<CR>")
    case 51: return VimKey("<BS>")
    case 117: return VimKey("<Del>")
    case 48: return VimKey("<Tab>")
    case 123: return VimKey("<Left>")
    case 124: return VimKey("<Right>")
    case 125: return VimKey("<Down>")
    case 126: return VimKey("<Up>")
    case 115: return VimKey("<Home>")
    case 119: return VimKey("<End>")
    default: break
    }
    if mods.contains(.control), let c = e.charactersIgnoringModifiers?.lowercased(), c.count == 1 {
      return VimKey("<C-\(c)>")
    }
    guard let c = e.characters, !c.isEmpty else { return nil }
    return VimKey(c)
  }
}

extension NativeEditorView {
  /// Vim keys on or off (Settings ▸ Editor ▸ Vim keys).
  public var vimEnabled: Bool {
    get { vim != nil }
    set {
      guard newValue != (vim != nil) else { return }
      if newValue {
        let v = VimEngine(buffer: TextViewVimBuffer(self))
        v.onMode = { [weak self] _ in self?.vimModeChanged() }
        v.onCursorShape = { [weak self] _ in self?.vimModeChanged() }
        v.commands = vimCommands
        v.onSearchKey = onVimSearchKey
        vim = v
        vimBuffer = v.buf as? TextViewVimBuffer
      } else {
        vim = nil
        vimBuffer = nil
        vimStatus("")
      }
      vimModeChanged()
    }
  }

  func vimModeChanged() {
    textView.caretShape = vim.flatMap { $0.cursorShape == .bar ? nil : $0.cursorShape }
    textView.updateInsertionPointStateAndRestartTimer(true)
    textView.needsDisplay = true
  }

  func vimStatus(_ text: String) {
    vimLabel.stringValue = text
    vimLabel.isHidden = text.isEmpty
    vimLabel.sizeToFit()
    vimLabel.frame.origin = NSPoint(x: 10, y: bounds.height - vimLabel.frame.height - 6)
    onVimStatus?(text)
  }
}
