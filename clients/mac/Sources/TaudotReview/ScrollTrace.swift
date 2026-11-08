// TAUDOT_SCROLL_TRACE=<file>: for every scroll event the app gets, the view AppKit delivers it to (the hit-test
// view under the pointer) and its chain up to the window: which view swallows a scroll over the review panel.
import AppKit

@MainActor public enum ScrollEventTrace {
  private static var monitor: Any?
  private static let file: FileHandle? = {
    guard let p = ProcessInfo.processInfo.environment["TAUDOT_SCROLL_TRACE"] else { return nil }
    FileManager.default.createFile(atPath: p, contents: nil)
    return FileHandle(forWritingAtPath: p)
  }()
  public static var lines: [String] = []

  /// The view a scroll at `e` goes to, and its superviews.
  public static func chain(_ e: NSEvent) -> [NSView] {
    guard let w = e.window, let c = w.contentView else { return [] }
    let p = c.superview?.convert(e.locationInWindow, from: nil) ?? e.locationInWindow
    var v = (c.superview ?? c).hitTest(p)
    var out: [NSView] = []
    while let x = v { out.append(x); v = x.superview }
    return out
  }

  /// A line of its own (the margin says where it forwarded a scroll).
  public static func note(_ s: String) {
    guard monitor != nil else { return }
    let line = String(format: "%.4f   %@", CACurrentMediaTime(), s)
    lines.append(line)
    file?.write((line + "\n").data(using: .utf8)!)
  }

  public static func install(force: Bool = false) {
    guard monitor == nil, force || file != nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { e in
      MainActor.assumeIsolated {
        let names = chain(e).prefix(8).map { String(describing: type(of: $0)) }
        let line = String(format: "%.4f scroll dy %.1f phase %lu momentum %lu window %@ (#%ld) at %@ → %@", CACurrentMediaTime(), e.scrollingDeltaY,
                          e.phase.rawValue, e.momentumPhase.rawValue, e.window.map { String(describing: type(of: $0)) } ?? "nil", e.windowNumber,
                          NSStringFromPoint(e.locationInWindow), names.joined(separator: " < "))
        lines.append(line)
        file?.write((line + "\n").data(using: .utf8)!)
      }
      return e
    }
  }
}
