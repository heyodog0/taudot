// metaltext: per-key cost of the native editor in an off-screen window (handler, display, commit), on the PaperA copy.
// Runs only with METALTEXT_BENCH=1 (a measurement, not a check).
import AppKit
import Foundation
import QuartzCore
import Testing
@testable import TaudotEditor
@testable import TaudotShared

@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["METALTEXT_BENCH"] == "1"))
func metalTextKeyCost() async throws {
  let path = (ProcessInfo.processInfo.environment["TAUDOT_PERF_DOC"] ?? "") + "/main.tex"
  let text = try String(contentsOfFile: path, encoding: .utf8)
  let w = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 800, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
  w.orderFront(nil)
  let metal = ProcessInfo.processInfo.environment["METALTEXT_MODE"] == "metal"
  let v = NativeEditorView(frame: w.contentView!.bounds, metal: metal)
  v.autoresizingMask = [.width, .height]
  w.contentView!.addSubview(v)
  v.show(NativeDoc(docID: "d", path: "main.tex", text: text, seq: 1, conn: nil), buffer: 1)
  w.makeFirstResponder(v.textView)
  for _ in 0..<400 where !v.laidOutAhead { try await Task.sleep(for: .milliseconds(5)) }
  v.jump(line: 177, col: 0)
  w.displayIfNeeded(); CATransaction.flush()
  var handler: [Double] = [], display: [Double] = [], prep: [Double] = [], frame: [Double] = []
  let chars = Array("the quick brown fox jumps over the lazy dog and keeps typing ")
  for i in 0..<(Int(ProcessInfo.processInfo.environment["METALTEXT_KEYS"] ?? "") ?? 240) {
    let c = String(chars[i % chars.count])
    let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: Latency.now, windowNumber: w.windowNumber,
                             context: nil, characters: c, charactersIgnoringModifiers: c, isARepeat: false, keyCode: 0)!
    let t0 = CACurrentMediaTime()
    v.textView.keyDown(with: e)
    let t1 = CACurrentMediaTime()
    spinOnce()  // the highlight's perform
    w.displayIfNeeded()
    CATransaction.flush()
    let t2 = CACurrentMediaTime()
    handler.append((t1 - t0) * 1000); display.append((t2 - t1) * 1000)
    if let mv = v.metalView { prep.append(mv.lastKeyTimes.0 * 1000); frame.append(mv.lastKeyTimes.1 * 1000) }
    if ProcessInfo.processInfo.environment["METALTEXT_PACE"] != "0" { try await Task.sleep(for: .milliseconds(33)) }
  }
  func q(_ a: [Double], _ p: Double) -> Double { let s = a.sorted(); return s[min(s.count - 1, Int(Double(s.count) * p))] }
  func row(_ n: String, _ a: [Double]) -> String { String(format: "%@ p50 %.2f p95 %.2f p99 %.2f max %.2f", n, q(a, 0.5), q(a, 0.95), q(a, 0.99), a.max()!) }
  var rows = [row("handler", Array(handler.dropFirst(20))), row("display+commit", Array(display.dropFirst(20))),
              row("total", zip(handler, display).dropFirst(20).map { $0 + $1 })]
  if !prep.isEmpty { rows += [row("  highlight+size", Array(prep.dropFirst(20))), row("  frame", Array(frame.dropFirst(20)))] }
  let out = rows.joined(separator: "\n")
  print("METALTEXT_BENCH \(metal ? "metal" : "textkit")\n" + out)
  try? out.write(toFile: (ProcessInfo.processInfo.environment["METALTEXT_OUT"] ?? "/dev/null"), atomically: true, encoding: .utf8)
  w.orderOut(nil)
}

@MainActor func spinOnce() { RunLoop.main.run(until: Date()) }

/// The same keys into bare text views: TextKit 2, TextKit 1, and the storage alone.
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["METALTEXT_BENCH"] == "1"))
func metalTextKitVariants() async throws {
  let text = try String(contentsOfFile: (ProcessInfo.processInfo.environment["TAUDOT_PERF_DOC"] ?? "") + "/main.tex", encoding: .utf8)
  let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
  var lines: [String] = []
  for mode in ["tk2", "tk1", "storage"] {
    let w = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 800, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
    w.orderFront(nil)
    let sv = NSScrollView(frame: w.contentView!.bounds)
    let tv = NSTextView(usingTextLayoutManager: mode != "tk1")
    tv.frame = NSRect(origin: .zero, size: sv.contentSize)
    tv.isVerticallyResizable = true
    tv.autoresizingMask = [.width]
    tv.textContainer?.widthTracksTextView = true
    tv.isRichText = false
    tv.allowsUndo = true
    tv.font = font
    if mode == "tk1" { tv.layoutManager?.allowsNonContiguousLayout = true }
    sv.documentView = tv
    w.contentView!.addSubview(sv)
    tv.string = text
    let storage = NSTextStorage(string: text, attributes: [.font: font])
    let at = (text as NSString).range(of: "\\section{Introduction}").location
    tv.setSelectedRange(NSRange(location: at == NSNotFound ? 20000 : at, length: 0))
    tv.scrollRangeToVisible(tv.selectedRange())
    w.makeFirstResponder(tv)
    w.displayIfNeeded(); CATransaction.flush()
    var times: [Double] = []
    var loc = tv.selectedRange().location
    for i in 0..<200 {
      let t0 = CACurrentMediaTime()
      if mode == "storage" {
        storage.replaceCharacters(in: NSRange(location: loc, length: 0), with: "x"); loc += 1
      } else {
        tv.insertText(i % 7 == 6 ? " " : "x", replacementRange: tv.selectedRange())
        w.displayIfNeeded(); CATransaction.flush()
      }
      times.append((CACurrentMediaTime() - t0) * 1000)
    }
    let s = Array(times.dropFirst(20)).sorted()
    lines.append(String(format: "%@ p50 %.3f p95 %.3f max %.3f", mode, s[s.count / 2], s[Int(Double(s.count) * 0.95)], s.last!))
    w.orderOut(nil)
  }
  print("METALTEXT_KIT\n" + lines.joined(separator: "\n"))
}

/// An NSTextView that never draws or scrolls itself: what keeping it as the model and input costs per key.
final class SilentTextView: NSTextView {
  override func draw(_ dirtyRect: NSRect) {}
  override func scrollRangeToVisible(_ range: NSRange) {}
  override var isOpaque: Bool { false }
}

@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["METALTEXT_BENCH"] == "1"))
func metalTextSilentModel() async throws {
  let text = try String(contentsOfFile: (ProcessInfo.processInfo.environment["TAUDOT_PERF_DOC"] ?? "") + "/main.tex", encoding: .utf8)
  let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
  var lines: [String] = []
  for mode in (ProcessInfo.processInfo.environment["METALTEXT_MODES"] ?? "tk1,tk2").split(separator: ",").map(String.init) {
    let w = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 800, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
    w.orderFront(nil)
    let tv = SilentTextView(usingTextLayoutManager: mode == "tk2")
    tv.frame = NSRect(x: 0, y: 0, width: 800, height: 900)
    tv.isVerticallyResizable = false
    tv.isHorizontallyResizable = false
    tv.textContainer?.widthTracksTextView = false
    tv.textContainer?.size = NSSize(width: 1e7, height: 1e7)
    tv.isRichText = false
    tv.allowsUndo = true
    tv.font = font
    tv.layoutManager?.allowsNonContiguousLayout = true
    tv.layoutManager?.backgroundLayoutEnabled = false
    w.contentView!.addSubview(tv)
    tv.string = text
    let at = (text as NSString).range(of: "\\section{Introduction}").location
    tv.setSelectedRange(NSRange(location: at, length: 0))
    w.makeFirstResponder(tv)
    w.displayIfNeeded(); CATransaction.flush()
    var times: [Double] = []
    for i in 0..<(Int(ProcessInfo.processInfo.environment["METALTEXT_KEYS"] ?? "") ?? 300) {
      let c = i % 7 == 6 ? " " : "x"
      let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber,
                               context: nil, characters: c, charactersIgnoringModifiers: c, isARepeat: false, keyCode: 0)!
      let t0 = CACurrentMediaTime()
      tv.keyDown(with: e)
      w.displayIfNeeded(); CATransaction.flush()
      times.append((CACurrentMediaTime() - t0) * 1000)
    }
    let s = Array(times.dropFirst(20)).sorted()
    let laid = tv.layoutManager.map { "\($0.firstUnlaidCharacterIndex())" } ?? "-"
    lines.append(String(format: "silent %@ p50 %.3f p95 %.3f max %.3f firstUnlaid %@", mode, s[s.count / 2], s[Int(Double(s.count) * 0.95)], s.last!, laid))
    w.orderOut(nil)
  }
  print("METALTEXT_SILENT\n" + lines.joined(separator: "\n"))
}

/// TextKit 2 never asked for layout (zero-size frame), its checking off, the insertion point not updated.
final class QuietTK2: NSTextView {
  override func draw(_ dirtyRect: NSRect) {}
  override func scrollRangeToVisible(_ range: NSRange) {}
  override func updateInsertionPointStateAndRestartTimer(_ restartFlag: Bool) {}
}

@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["METALTEXT_BENCH"] == "1"))
func metalTextQuietTK2() async throws {
  let text = try String(contentsOfFile: (ProcessInfo.processInfo.environment["TAUDOT_PERF_DOC"] ?? "") + "/main.tex", encoding: .utf8)
  let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
  let w = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 800, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
  w.orderFront(nil)
  let tv = QuietTK2(usingTextLayoutManager: true)
  tv.frame = NSRect(x: 0, y: 0, width: 0, height: 0)
  tv.isVerticallyResizable = false
  tv.isHorizontallyResizable = false
  tv.isRichText = false
  tv.allowsUndo = true
  tv.font = font
  tv.isAutomaticTextCompletionEnabled = false
  tv.isAutomaticLinkDetectionEnabled = false
  tv.isAutomaticDataDetectionEnabled = false
  tv.isGrammarCheckingEnabled = false
  tv.isContinuousSpellCheckingEnabled = false
  tv.isAutomaticSpellingCorrectionEnabled = false
  tv.isAutomaticTextReplacementEnabled = false
  tv.isAutomaticQuoteSubstitutionEnabled = false
  tv.isAutomaticDashSubstitutionEnabled = false
  tv.inlinePredictionType = .no
  tv.smartInsertDeleteEnabled = false
  w.contentView!.addSubview(tv)
  tv.string = text
  let ns = text as NSString
  var at = ns.range(of: "\\section{Introduction}").location
  tv.setSelectedRange(NSRange(location: at, length: 0))
  w.makeFirstResponder(tv)
  w.displayIfNeeded(); CATransaction.flush()
  var times: [Double] = []
  for i in 0..<(Int(ProcessInfo.processInfo.environment["METALTEXT_KEYS"] ?? "") ?? 600) {
    if i % 60 == 59 { at = tv.selectedRange().location + 700; tv.setSelectedRange(NSRange(location: min(at, (tv.string as NSString).length), length: 0)) }
    let c = i % 7 == 6 ? " " : "x"
    let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber,
                             context: nil, characters: c, charactersIgnoringModifiers: c, isARepeat: false, keyCode: 0)!
    let t0 = CACurrentMediaTime()
    tv.keyDown(with: e)
    w.displayIfNeeded(); CATransaction.flush()
    times.append((CACurrentMediaTime() - t0) * 1000)
  }
  let s = Array(times.dropFirst(20)).sorted()
  print(String(format: "METALTEXT_QUIET\nquiet tk2 p50 %.3f p95 %.3f p99 %.3f max %.3f tk2 %@", s[s.count / 2], s[Int(Double(s.count) * 0.95)], s[Int(Double(s.count) * 0.99)], s.last!, tv.textLayoutManager == nil ? "no" : "yes"))
  w.orderOut(nil)
}

/// TextKit 2 text view as a scroll view's document view at full height, its viewport layout turned off.
final class NoViewportTK2: NSTextView {
  override func draw(_ dirtyRect: NSRect) {}
  override func scrollRangeToVisible(_ range: NSRange) {}
  override func updateInsertionPointStateAndRestartTimer(_ restartFlag: Bool) {}
}

final class NoViewport: NSObject, NSTextViewportLayoutControllerDelegate {
  func viewportBounds(for c: NSTextViewportLayoutController) -> CGRect { .zero }
  func textViewportLayoutController(_ c: NSTextViewportLayoutController, configureRenderingSurfaceFor f: NSTextLayoutFragment) {}
}

@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["METALTEXT_BENCH"] == "1"))
func metalTextNoViewport() async throws {
  let text = try String(contentsOfFile: (ProcessInfo.processInfo.environment["TAUDOT_PERF_DOC"] ?? "") + "/main.tex", encoding: .utf8)
  let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
  let w = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 800, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
  w.orderFront(nil)
  let sv = NSScrollView(frame: w.contentView!.bounds)
  let tv = NoViewportTK2(usingTextLayoutManager: true)
  tv.isVerticallyResizable = false
  tv.isHorizontallyResizable = false
  tv.textContainer?.widthTracksTextView = false
  tv.isRichText = false
  tv.allowsUndo = true
  tv.font = font
  tv.isAutomaticTextCompletionEnabled = false
  tv.isContinuousSpellCheckingEnabled = false
  tv.inlinePredictionType = .no
  sv.documentView = tv
  w.contentView!.addSubview(sv)
  let nv = NoViewport()
  tv.textLayoutManager!.textViewportLayoutController.delegate = nv
  tv.string = text
  tv.frame = NSRect(x: 0, y: 0, width: 800, height: 40000)
  let clip = sv.contentView
  clip.scroll(to: NSPoint(x: 0, y: 8000)); sv.reflectScrolledClipView(clip)
  let ns = text as NSString
  var at = ns.range(of: "\\section{Introduction}").location
  tv.setSelectedRange(NSRange(location: at, length: 0))
  w.makeFirstResponder(tv)
  w.displayIfNeeded(); CATransaction.flush()
  var frags = 0
  tv.textLayoutManager!.enumerateTextLayoutFragments(from: nil, options: [.ensuresLayout.subtracting(.ensuresLayout)]) { _ in frags += 1; return true }
  var times: [Double] = []
  for i in 0..<600 {
    if i % 60 == 59 { at = tv.selectedRange().location + 700; tv.setSelectedRange(NSRange(location: min(at, (tv.string as NSString).length), length: 0)) }
    if i % 30 == 0 { clip.scroll(to: NSPoint(x: 0, y: CGFloat(i * 30))); sv.reflectScrolledClipView(clip) }
    let c = i % 7 == 6 ? " " : "x"
    let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber,
                             context: nil, characters: c, charactersIgnoringModifiers: c, isARepeat: false, keyCode: 0)!
    let t0 = CACurrentMediaTime()
    tv.keyDown(with: e)
    w.displayIfNeeded(); CATransaction.flush()
    times.append((CACurrentMediaTime() - t0) * 1000)
  }
  var frags2 = 0
  tv.textLayoutManager!.enumerateTextLayoutFragments(from: nil, options: []) { _ in frags2 += 1; return true }
  let s = Array(times.dropFirst(20)).sorted()
  _ = nv
  print("delegate kept:", tv.textLayoutManager!.textViewportLayoutController.delegate === nv)
  print(String(format: "METALTEXT_NOVP\nnoviewport p50 %.3f p95 %.3f p99 %.3f max %.3f frags %d→%d", s[s.count / 2], s[Int(Double(s.count) * 0.95)], s[Int(Double(s.count) * 0.99)], s.last!, frags, frags2))
  w.orderOut(nil)
}
