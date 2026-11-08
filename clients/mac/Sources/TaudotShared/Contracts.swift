// The interfaces between the app's parts (docs/mac-app.md). The coordinator owns this file: propose changes as Requests.
import AppKit

/// A msgpack value, as Neovim sends and takes them.
public indirect enum Value: Sendable, Equatable {
  case null, bool(Bool), int(Int64), float(Double), string(String), binary([UInt8]), array([Value]), map([(Value, Value)])
  public static func == (a: Value, b: Value) -> Bool {
    switch (a, b) {
    case (.null, .null): return true
    case let (.bool(x), .bool(y)): return x == y
    case let (.int(x), .int(y)): return x == y
    case let (.float(x), .float(y)): return x == y
    case let (.string(x), .string(y)): return x == y
    case let (.binary(x), .binary(y)): return x == y
    case let (.array(x), .array(y)): return x == y
    case let (.map(x), .map(y)): return x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
    default: return false
    }
  }
}

/// The embedded Neovim, as the other parts see it. Implemented by TaudotNeovim.
@MainActor public protocol NeovimBridge: AnyObject {
  /// Handle `vim.rpcnotify(chan, name, ...)` from Lua (on the main actor).
  func notify(_ name: String, _ handler: @escaping @MainActor ([Value]) -> Void)
  /// `nvim_exec_lua`.
  func execLua(_ code: String, _ args: [Value]) async throws -> Value
  /// `nvim_command`.
  func command(_ cmd: String) async throws
}

/// Where the current buffer's lines are on screen. Implemented by TaudotNeovim's editor view; read by the margin.
@MainActor public protocol EditorGeometry: AnyObject {
  /// The buffer (Neovim buffer number) shown in the current window.
  var buffer: Int { get }
  /// Height of one text line, in points.
  var lineHeight: CGFloat { get }
  /// Top of a 0-based buffer line, in the editor view's coordinates (points, fractional while scrolling), or nil if
  /// it isn't laid out (folded, or far off screen).
  func y(ofLine line: Int) -> CGFloat?
  /// 0-based buffer lines at least partly visible.
  var visibleLines: ClosedRange<Int> { get }
  /// Called after every change of the above, including each animation frame of a smooth scroll.
  func onChange(_ handler: @escaping @MainActor () -> Void)
  /// The left edge of screen column `c` of the window (0: its first cell, before the number column), in the editor
  /// view's coordinates; nil if unknown (the margin's lines then end at its own edge).
  func x(ofColumn c: Int) -> CGFloat?
}

public extension EditorGeometry {
  func x(ofColumn c: Int) -> CGFloat? { nil }
}

/// The PDF pane, as the app sees it. Implemented by TaudotPDF.
@MainActor public protocol PDFPane: AnyObject {
  var view: NSView { get }
  /// Open a project folder (its main .tex) and keep the PDF live.
  func open(folder: URL, main: String, engineSocket: URL?)
  /// Forward search: scroll to (and briefly mark) this source line.
  func jump(path: String, line: Int)
  /// Double-click on the PDF: the source line under it.
  var onInverseSearch: (@MainActor (_ path: String, _ line: Int) -> Void)? { get set }
}
