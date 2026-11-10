// editfix bug 4: "I can't reach the end of a wrapped line" (native mode): a click past the end of a drawn row, and
// `$` / `g$` in vim mode, must put the caret at that row's end, where the row is drawn.
import AppKit
import Foundation
import Testing
@testable import TaudotEditor
@testable import TaudotShared
@testable import TaudotNeovim

@MainActor private func wrapSetup(width: CGFloat, size: CGFloat, text: String) -> (NativeEditorView, NSWindow, (String) -> Void) {
  let w = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
  w.isReleasedWhenClosed = false
  let v = NativeEditorView(frame: w.contentView!.bounds, metal: true)
  v.autoresizingMask = [.width, .height]
  w.contentView!.addSubview(v)
  var st = v.style
  st.fontSize = size
  v.apply(style: st)
  v.show(NativeDoc(docID: "w", path: "w.tex", text: text, seq: 0, conn: nil), buffer: 1)
  v.layoutSubtreeIfNeeded()
  v.vimEnabled = true
  w.makeFirstResponder(v.textView)
  return (v, w, { keys in for k in VimKey.parse(keys) { v.textView.keyDown(with: keyEvent(k.name, window: w)) } })
}

/// Sentences of many lengths: at most widths some rows end up holding one word.
private let wrapWords = ["proof", "lemma", "bound", "a", "theorem", "holds", "for", "every", "x"]
private let wrapText: String = {
  var lines: [String] = []
  for i in 1...14 {
    var words: [String] = []
    for j in 0..<(3 + i * 2) { words.append(wrapWords[(j + i) % wrapWords.count]) }
    lines.append("Line \(i): " + words.joined(separator: " "))
  }
  return lines.joined(separator: "\n") + "\n"
}()

/// The rows as the last frame drew them: a click past each one's end, and `$` on each drawn line, land on that row.
@MainActor @Test func clickAndDollarLandOnTheDrawnRow() async throws {
  var report: [String] = []
  let many = (0..<12).map { _ in wrapText }.joined()
  for width in [360.0, 470.0] as [CGFloat] {
    for size in [14.0, 17.0] as [CGFloat] {
      let (v, w, type) = wrapSetup(width: width, size: 13, text: many)
      defer { w.close() }
      let lay = try #require(v.textLayout), mv = try #require(v.metalView)
      // a font change, then a scroll to the middle before the layout ahead has run: paragraphs above are estimates
      var st = v.style
      st.fontSize = size
      v.apply(style: st)
      let clip = v.scroll.contentView
      clip.scroll(to: NSPoint(x: 0, y: v.documentHeight / 2))
      v.scroll.reflectScrolledClipView(clip)
      mv.render()
      let s = lay.text
      for d in mv.drawnLines {
        let p = lay.paras[d.k]
        guard p.laid, p.len > 0, p.lines > 1 else { continue }
        let a = Int(p.breaks[d.l]), b = d.l + 1 < p.lines ? Int(p.breaks[d.l + 1]) : p.len
        var e = b
        while e > a && [32, 9].contains(s.character(at: lay.starts[d.k] + e - 1)) { e -= 1 }
        let endX = lay.origin.x + CGFloat(p.xs[e] - p.xs[a])
        let off = lay.offset(at: CGPoint(x: endX + 30, y: d.top + lay.lineHeight / 2))
        let c = lay.caretRect(off)
        if abs(c.minY - (d.top + lay.spacing)) > 0.5 || abs(c.minX - endX) > 1 {
          report.append("w\(Int(width)) s\(Int(size)) para \(d.k) row \(d.l): click → para \(lay.paraIndex(off)) offset \(off - lay.starts[lay.paraIndex(off)]) drawn at y \(c.minY), row drawn at \(d.top + lay.spacing)")
        }
      }
      // `g$` / `g0` on each drawn row of a wrapped line: that row's last character / first, drawn on that row
      for d in mv.drawnLines.filter({ lay.paras[$0.k].laid && lay.paras[$0.k].lines > 1 }).prefix(4) {
        let p = lay.paras[d.k]
        let a = lay.starts[d.k] + Int(p.breaks[d.l]), b = lay.starts[d.k] + (d.l + 1 < p.lines ? Int(p.breaks[d.l + 1]) : p.len)
        v.textView.setSelectedRange(NSRange(location: a + (b - a) / 2, length: 0))
        type("<Esc>g$")
        let got = v.textView.selectedRange().location
        let gotTop = lay.caretRect(got).minY
        if got != b - 1 || abs(gotTop - (d.top + lay.spacing)) > 0.5 {
          report.append("w\(Int(width)) s\(Int(size)) para \(d.k) row \(d.l): g$ → \(got - lay.starts[d.k]) want \(b - 1 - lay.starts[d.k]), drawn y \(gotTop) row \(d.top + lay.spacing)")
        }
        type("g0")
        if v.textView.selectedRange().location != a {
          report.append("w\(Int(width)) s\(Int(size)) para \(d.k) row \(d.l): g0 → \(v.textView.selectedRange().location - lay.starts[d.k]) want \(a - lay.starts[d.k])")
        }
      }
      // `$` on a drawn wrapped line, then where its block is drawn
      if let d = mv.drawnLines.first(where: { lay.paras[$0.k].lines > 1 && $0.l == 0 }) {
        v.textView.setSelectedRange(NSRange(location: lay.starts[d.k], length: 0))
        type("<Esc>0$")
        mv.render()
        let p = lay.paras[d.k]
        let lastTop = mv.drawnLines.first { $0.k == d.k && $0.l == p.lines - 1 }?.top
        let caret = lay.caretRect(v.textView.selectedRange().location)
        if let lastTop, abs(caret.minY - (lastTop + lay.spacing)) > 0.5 {
          report.append("w\(Int(width)) s\(Int(size)) para \(d.k): $ drawn at y \(caret.minY), its last row at \(lastTop + lay.spacing)")
        }
      }
    }
  }
  let summary = "\(report.count) problems:\n" + report.prefix(30).joined(separator: "\n")
  #expect(report.isEmpty, "\(summary)")
}

/// TextKit mode (the native editor without Metal): `g$` / `g0` use TextKit's own row edges.
@MainActor @Test func gDollarInTextKitMode() async throws {
  let w = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 360, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
  w.isReleasedWhenClosed = false
  defer { w.close() }
  let v = NativeEditorView(frame: w.contentView!.bounds, metal: false)
  w.contentView!.addSubview(v)
  let line = (0..<40).map { wrapWords[$0 % wrapWords.count] }.joined(separator: " ")
  v.show(NativeDoc(docID: "t", path: "t.tex", text: line + "\n", seq: 0, conn: nil), buffer: 1)
  v.layoutSubtreeIfNeeded()
  v.vimEnabled = true
  w.makeFirstResponder(v.textView)
  func type(_ keys: String) { for k in VimKey.parse(keys) { v.textView.keyDown(with: keyEvent(k.name, window: w)) } }
  type("<Esc>0g$")
  let end = v.textView.selectedRange().location
  #expect(end > 0 && end < (line as NSString).length - 1, "g$ stops at the first row's end (\(end) of \((line as NSString).length))")
  // the next character starts the second row: one row down from the line's start
  let firstRowEnd = v.textView.firstRect(forCharacterRange: NSRange(location: end, length: 1), actualRange: nil)
  let nextRow = v.textView.firstRect(forCharacterRange: NSRange(location: end + 1, length: 1), actualRange: nil)
  #expect(nextRow.minY < firstRowEnd.minY - 1, "the character after g$ is on the next row (\(firstRowEnd.minY) → \(nextRow.minY))")
  type("g0")
  #expect(v.textView.selectedRange().location == 0)
  type("$")
  #expect(v.textView.selectedRange().location == (line as NSString).length - 1, "$ is still the line's last character")
}

/// Neovim mode: Neovim wraps on our grid, so `$` / `g$` land where its rows are drawn: the cell under the cursor is
/// the last non-blank one of its grid row (and, for `$`, the line's last character).
@MainActor @Test func neovimDollarOnItsRow() async throws {
  let nv = try Neovim(args: ["--clean", "-n"])
  defer { nv.terminate() }
  let v = TaudotNeovim.EditorView(nvim: nv, frame: NSRect(x: 0, y: 0, width: 320, height: 300))
  try await v.attach()
  func waitFor(_ cond: @escaping () -> Bool) async { for _ in 0..<300 where !cond() { try? await Task.sleep(for: .milliseconds(10)) } }
  await waitFor { v.ui.grids[1]?.width == v.cols }
  let words = (0..<30).map { wrapWords[$0 % wrapWords.count] }.joined(separator: " ")
  _ = try await nv.execLua("vim.o.wrap = true; vim.o.linebreak = true; vim.api.nvim_buf_set_lines(0, 0, -1, false, {...})", [.string(words)])
  func cursorCellIsRowEnd(_ what: String) async {
    try? await Task.sleep(for: .milliseconds(150))
    let m = v.ui
    guard let g = m.grids[m.cursorGrid], m.cursorRow < g.rows.count else { Issue.record("\(what): no cursor grid"); return }
    let row = g.rows[m.cursorRow].cells.map(\.text)
    let lastInk = row.lastIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? -1
    // (`g$` may sit on the row's trailing space, as Vim's does with 'linebreak': still on this row, not past it)
    #expect(m.cursorCol == lastInk || (what.hasPrefix("g$") && m.cursorCol == lastInk + 1),
            "\(what): cursor at column \(m.cursorCol), the row's last character at \(lastInk): \(row.joined())")
  }
  try await nv.command("normal! 0$")
  await cursorCellIsRowEnd("$")
  try await nv.command("normal! 0g$")
  await cursorCellIsRowEnd("g$ (first row)")
}

/// A font change keeps the same source position at the top: the character first on the top row before is on the
/// top row after, wherever the rewrap puts it in that row (shell_native's check, on lines that wrap).
@MainActor @Test(arguments: [(500.0, 2.0), (500.0, -2.0), (700.0, 3.0), (380.0, 1.0)])
func fontChangeKeepsTheTopPosition(width: Double, delta: Double) async throws {
  let w = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
  w.isReleasedWhenClosed = false
  defer { w.close() }
  let v = NativeEditorView(frame: w.contentView!.bounds, metal: true)
  v.autoresizingMask = [.width, .height]
  w.contentView!.addSubview(v)
  let text = (1...300).map { "Line \($0) of a test paragraph with some words that may wrap when the window is narrow enough to need it." }.joined(separator: "\n") + "\n"
  v.show(NativeDoc(docID: "k", path: "k.tex", text: text, seq: 0, conn: nil), buffer: 1)
  v.layoutSubtreeIfNeeded()
  try await Task.sleep(for: .milliseconds(300))  // laid out ahead
  let lay = try #require(v.textLayout), clip = v.scroll.contentView
  var report: [String] = []
  for (i, frac) in [0.0, 0.3, 0.7].enumerated() {
    // somewhere in the middle, the top row partly scrolled off by `frac`
    let y = lay.y(ofPara: 120 + 37 * i) + CGFloat(1 + i % 2) * lay.lineHeight + CGFloat(frac) * lay.lineHeight
    clip.scroll(to: NSPoint(x: 0, y: y))
    v.scroll.reflectScrolledClipView(clip)
    func topChar() -> Int { v.textView.characterIndexForInsertion(at: NSPoint(x: 40, y: clip.bounds.minY + 1)) }
    let a = topChar()
    var st = v.style
    st.fontSize += CGFloat(delta)
    v.apply(style: st)
    try await Task.sleep(for: .milliseconds(300))
    let b = topChar()
    // the same visual row: a's row (after the rewrap) is the one at the top
    if lay.visualLine(at: a) != lay.visualLine(at: b) {
      report.append("w\(Int(width)) \(delta > 0 ? "+" : "")\(Int(delta)) at \(frac): top char \(a) → \(b) (rows \(lay.visualLine(at: a)) vs \(lay.visualLine(at: b))); a's row top \(lay.caretRect(a).minY - lay.spacing), view top \(clip.bounds.minY), line height \(lay.lineHeight)")
    }
  }
  let summary = report.joined(separator: "\n")
  #expect(report.isEmpty, "\(summary)")
}
