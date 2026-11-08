// An EditorGeometry of equal lines under a scroll offset: for ReviewHost and tests, before the real editor exists.
import AppKit
import TaudotShared

@MainActor public final class FixedLineGeometry: EditorGeometry {
  public var buffer: Int
  public var lineHeight: CGFloat { didSet { changed() } }
  /// y of line 0's top; negative once scrolled down.
  public var top: CGFloat { didSet { changed() } }
  public var lineCount: Int { didSet { changed() } }
  /// Height of the editor view, for visibleLines.
  public var viewHeight: CGFloat { didSet { changed() } }
  private var handlers: [@MainActor () -> Void] = []

  public init(buffer: Int = 1, lineHeight: CGFloat = 18, top: CGFloat = 0, lineCount: Int = 100, viewHeight: CGFloat = 600) {
    self.buffer = buffer
    self.lineHeight = lineHeight
    self.top = top
    self.lineCount = lineCount
    self.viewHeight = viewHeight
  }

  public func y(ofLine line: Int) -> CGFloat? {
    guard line >= 0, line < lineCount else { return nil }
    return top + CGFloat(line) * lineHeight
  }
  public var visibleLines: ClosedRange<Int> {
    let first = max(0, Int((-top / lineHeight).rounded(.down)))
    let last = max(first, min(lineCount - 1, Int(((viewHeight - top) / lineHeight).rounded(.up))))
    return first...last
  }
  public func onChange(_ handler: @escaping @MainActor () -> Void) { handlers.append(handler) }
  /// Monospaced columns from the view's left edge (nil: unknown, the default).
  public var cellWidth: CGFloat?
  public var textLeft: CGFloat = 0
  public func x(ofColumn c: Int) -> CGFloat? { cellWidth.map { textLeft + CGFloat(c) * $0 } }
  public func changed() { for h in handlers { h() } }
}
