// What the Vim engine needs from an editor: the text, the selection, edits (which go through the editor's normal
// edit path, so they sync and undo), and the few things only the view knows (screen lines, scrolling).
import Foundation

@MainActor public protocol VimBuffer: AnyObject {
  var text: NSString { get }
  /// The caret (length 0) or the visual selection.
  var selection: NSRange { get set }
  func replace(_ range: NSRange, with string: String)
  /// One undo step for everything between these.
  func beginChange()
  func endChange()
  func undo()
  func redo()
  /// The UTF-16 offset `count` display lines below (negative: above) `loc`, keeping its x position.
  func displayLine(from loc: Int, by count: Int) -> Int
  /// The screen row (display line) holding `loc`: its first offset and the offset just past its last character
  /// (the next row's start, or the line's end before its newline). `g0`, `g$`.
  func displayLineEdges(at loc: Int) -> (start: Int, end: Int)
  /// First and last line (0-based) on screen.
  var screenLines: ClosedRange<Int> { get }
  /// Scroll by lines (smoothly where the view can); the caret is moved by the engine.
  func scroll(lines: Int)
  /// The system clipboard (register `+`).
  var clipboard: String? { get set }
  /// Show the mode, a pending command line, or a message.
  func status(_ text: String)
}

extension VimBuffer {
  /// Without soft wrap: the whole line.
  public func displayLineEdges(at loc: Int) -> (start: Int, end: Int) {
    var a = 0, e = 0, c = 0
    text.getLineStart(&a, end: &e, contentsEnd: &c, for: NSRange(location: min(loc, text.length), length: 0))
    return (a, c)
  }
}

/// A key as Vim names it: one character, or `<Esc>`, `<CR>`, `<BS>`, `<C-r>`, `<Left>`…
public struct VimKey: Equatable, Sendable {
  public var name: String
  public init(_ name: String) { self.name = name }

  /// Parse Vim notation: `d2w<Esc>` → d, 2, w, <Esc>.
  public static func parse(_ s: String) -> [VimKey] {
    var out: [VimKey] = []
    var i = s.startIndex
    while i < s.endIndex {
      if s[i] == "<", let close = s[i...].firstIndex(of: ">"), s.distance(from: i, to: close) > 1 {
        out.append(VimKey(String(s[i...close])))
        i = s.index(after: close)
      } else {
        out.append(VimKey(String(s[i])))
        i = s.index(after: i)
      }
    }
    return out
  }
}
