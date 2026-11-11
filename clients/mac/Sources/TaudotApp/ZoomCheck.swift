// TAUDOT_ZOOMCHECK=FILE (Tests/zoom_check.sh, editfix item 10): comments in the margin beside their lines, one
// selected, while the editor's font steps bigger and smaller (⌘+ / ⌘− / ⌘0, View ▸ Bigger / Smaller / Actual Size).
// Every frame the editor draws, each card's top against its line's top (the margin's coordinates). Off screen, no keys.
import AppKit
import TaudotNeovim
import TaudotReview
import TaudotShared

@MainActor final class ZoomCheck {
  let p: ProjectWindow
  let out: URL
  var lines: [String] = []
  init(_ p: ProjectWindow, out: URL) { self.p = p; self.out = out }
  func sleep(_ s: Double) async { try? await Task.sleep(for: .milliseconds(Int(s * 1000))) }
  func check(_ ok: Bool, _ what: String) { lines.append("\(ok ? "ok  " : "FAIL") \(what)") }

  /// Per frame: (time, step, font size, per card: card top − its line's top).
  var frames: [(t: Double, step: String, size: CGFloat, off: [String: CGFloat])] = []
  var step = "start"

  func sample() {
    let m = p.margin
    guard let g = m.geometry else { return }
    var off: [String: CGFloat] = [:]
    let shown = m.displayedFrames()
    for it in m.shown {
      guard let f = shown[it.id], let y = g.y(ofLine: it.range.line) else { continue }
      off[it.id] = f.minY - (y + m.editorOffset)
    }
    frames.append((CACurrentMediaTime(), step, CGFloat(p.editorFontSize), off))
  }

  func run() async {
    await sleep(2)
    // three comments on lines far enough apart that the cards sit at their lines (none pushed by another)
    let rows = [3, 14, 26]
    for (k, l) in rows.enumerated() {
      let args: Value = .map([(.string("text"), .string("zoom \(k): a comment long enough to wrap onto a second line in its card")),
                              (.string("line"), .int(Int64(l))), (.string("col"), .int(0)),
                              (.string("end_line"), .int(Int64(l))), (.string("end_col"), .int(6))])
      _ = try? await (p.native?.bridge as NeovimBridge? ?? p.nvim)?.execLua("return require('taudot.gui').act(...)", [.string("comment"), .null, args])
    }
    for _ in 0..<50 where p.margin.state.items.filter({ $0.kind == .comment }).count < rows.count { await sleep(0.1) }
    p.setPane(p.sidebar, hidden: false)
    p.sidebar.tab = .comments
    p.sidebar.scope = .file
    await sleep(0.6)
    let ids = p.margin.shown.map(\.id)
    check(ids.count == rows.count, "three cards in the margin (\(ids.count)), mode \(p.mode)")
    if let mid = ids.dropFirst().first { p.margin.select(mid) }
    await sleep(0.5)
    p.margin.geometry?.onChange { [weak self] in self?.sample() }
    let size0 = p.editorFontSize
    sample()
    for (name, act) in [("bigger", { self.p.fontBigger(nil) }), ("bigger", { self.p.fontBigger(nil) }), ("bigger", { self.p.fontBigger(nil) }),
                        ("smaller", { self.p.fontSmaller(nil) }), ("actual", { self.p.fontActualSize(nil) })] as [(String, () -> Void)] {
      step = name
      act()
      await sleep(1.2)
      sample()
    }
    // settled after each step: every card at its line (the same offset as before any zoom)
    let base = frames.first?.off ?? [:]
    var settledBad: [String] = []
    var jumps: [String] = []
    for s in ["bigger", "smaller", "actual"] {
      guard let last = frames.last(where: { $0.step == s }) else { continue }
      // (only cards that started at their line: one held at the cards' top or pushed by the one above moves by design)
      for (id, o) in last.off where abs(base[id] ?? 99) < 1 && abs(o - (base[id] ?? o)) > 2 { settledBad.append("\(s) \(id.prefix(6)): \(Int(base[id] ?? 0)) → \(Int(o))") }
    }
    // during a step: a card more than half a line from its line, for a frame (after the first frame of the step)
    var prev: (String, [String: CGFloat])?
    for f in frames {
      for (id, o) in f.off where abs(base[id] ?? 99) < 1 && abs(o - (base[id] ?? o)) > 8 && prev?.0 == f.step {
        jumps.append(String(format: "%@ %.0f pt: %@ off by %.0f", f.step, f.size, String(id.prefix(6)), o - (base[id] ?? 0)))
      }
      prev = (f.step, f.off)
    }
    lines.append("info font \(size0) → \(p.editorFontSize); \(frames.count) frames")
    check(settledBad.isEmpty, "settled: every card at its line after each step \(settledBad)")
    check(jumps.isEmpty, "while zooming: no card left its line (\(jumps.count) frames) \(jumps.prefix(8))")
    if ProcessInfo.processInfo.environment["TAUDOT_ZOOMCHECK_FRAMES"] != nil {
      for f in frames { lines.append(String(format: "frame %.3f %@ %.0f %@", f.t - frames[0].t, f.step, f.size, f.off.sorted { $0.key < $1.key }.map { "\($0.key.prefix(4))=\(Int($0.value))" }.joined(separator: " "))) }
    }
    p.fontActualSize(nil)
    try? (lines.joined(separator: "\n") + "\n").write(to: out, atomically: true, encoding: .utf8)
    p.window.close()
    NSApp.terminate(nil)
  }
}
