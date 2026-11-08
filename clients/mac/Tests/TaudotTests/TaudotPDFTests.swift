import Foundation
import Testing
import AppKit
@testable import TaudotPDF
import TaudotCursor

// A hand-made SyncTeX 1 file: one page, one vbox holding a line (hbox) of glue and kerns from main.tex line 5,
// and a footer kern from line 9. Unit 1, magnification 1000: coordinates in sp (65536 per TeX point).
let sp = 65536
let sample = """
  SyncTeX Version:1
  Input:1:./main.tex
  Input:2:/usr/share/texmf/article.cls
  Output:pdf
  Magnification:1000
  Unit:1
  X Offset:0
  Y Offset:0
  Content:
  !100
  {1
  [1,4:\(72 * sp),\(700 * sp):\(400 * sp),\(600 * sp),0
  (1,5:\(72 * sp),\(100 * sp):\(400 * sp),\(8 * sp),\(2 * sp)
  g1,5:\(80 * sp),\(100 * sp)
  k1,5:\(150 * sp),\(100 * sp):\(1 * sp)
  g1,6:\(200 * sp),\(100 * sp)
  )
  (1,7:\(72 * sp),\(120 * sp):\(400 * sp),\(8 * sp),\(2 * sp)
  g1,7:\(80 * sp),\(120 * sp)
  )
  ]
  k1,9:\(300 * sp),\(750 * sp):\(1 * sp)
  }1
  Postamble:
  Count:9
  """

@Test func syncTexParses() {
  let st = SyncTex(sample)
  #expect(st.inputs[1] == "./main.tex")
  #expect(st.pages.count == 1)
  #expect(st.pages[0].count == 8)
  let k = 72 / 72.27
  #expect(abs(st.pages[0][1].x - 72 * k) < 1e-9)
  #expect(st.pages[0][2].parent == 1)
}

@Test func syncTexForward() {
  let st = SyncTex(sample)
  let f = st.forward(file: "main.tex", line: 7)
  #expect(f?.page == 0)
  #expect(abs((f?.y ?? 0) - (120 * 72 / 72.27 - 6)) < 1e-6)
  // a blank line goes to the next line that produced something
  #expect(st.forward(file: "main.tex", line: 6)?.y == st.forward(file: "main.tex", line: 6)?.y)
  #expect(st.forward(file: "/abs/path/main.tex", line: 5)?.page == 0)
  #expect(st.forward(file: "other.tex", line: 5) == nil)
}

@Test func syncTexInverse() {
  let st = SyncTex(sample)
  let k = 72 / 72.27
  // inside the first line, right of the glue at x 80: line 5
  #expect(st.inverse(page: 0, x: 100 * k, y: 98 * k)?.line == 5)
  // right of the glue from line 6 (same typeset line): line 6
  #expect(st.inverse(page: 0, x: 210 * k, y: 98 * k)?.line == 6)
  #expect(st.inverse(page: 0, x: 100 * k, y: 118 * k)?.line == 7)
  #expect(st.inverse(page: 3, x: 0, y: 0) == nil)
}

@Test func rubberBandCurve() {
  #expect(rubber(0, 100) == 0)
  #expect(rubber(50, 100) < 50 && rubber(50, 100) > 0)
  #expect(rubber(1e6, 100) < 100)
  #expect(rubber(-30, 100) == -rubber(30, 100))
  for x in [1.0, 20, 200, 900] as [CGFloat] { #expect(abs(unrubber(rubber(x, 400), 400) - x) < 1e-6 * x + 1e-9) }
}

/// A file named by $TAUDOT_SYNCTEX (e.g. txp-headless's output for a real paper) parses into pages and nodes.
@Test func syncTexRealFile() throws {
  guard let p = ProcessInfo.processInfo.environment["TAUDOT_SYNCTEX"] else { return }
  let st = SyncTex(try String(contentsOfFile: p, encoding: .utf8))
  print("synctex file: \(st.inputs.count) inputs, \(st.pages.count) pages, \(st.pages.map(\.count).reduce(0, +)) nodes")
  #expect(st.pages.count > 0)
  let f = st.forward(file: "main.tex", line: 361)
  print("forward main.tex:361 -> \(String(describing: f))")
  #expect(f != nil)
}

/// txp-headless end to end on a two-page doc in a temp folder: pages, a render, an edit that changes page 2 only,
/// SyncTeX. Skipped when txp-headless or texpresso-xetex isn't built.
@MainActor @Test func txpEndToEnd() async throws {
  let fm = FileManager.default
  guard fm.isExecutableFile(atPath: TxpPaths.headless), fm.isExecutableFile(atPath: TxpPaths.xetex) else { return }
  let dir = fm.temporaryDirectory.appendingPathComponent("txp-test-\(UUID().uuidString.prefix(6))")
  try fm.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? fm.removeItem(at: dir) }
  let para = (1...14).map { "Paragraph \($0). " + String(repeating: "Some words to fill the line. ", count: 12) }
  let text = "\\documentclass{article}\n\\begin{document}\n" + para.joined(separator: "\n\n") + "\n\\end{document}\n"
  try text.write(to: dir.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)

  let txp = Txp(main: dir.appendingPathComponent("main.tex"))
  var events: [PagesEvent] = []
  txp.onPages = { events.append($0) }
  txp.start()
  defer { txp.stop() }
  func waitFor(_ cond: () -> Bool) async throws {
    for _ in 0..<300 where !cond() { try await Task.sleep(for: .milliseconds(20)) }
  }
  try await waitFor { events.last?.done == true }
  let first = try #require(events.last)
  #expect(first.n == 2)
  #expect(abs(first.sizes[0].width - 612) < 1)

  try await Task.sleep(for: .milliseconds(800))  // the idle aux reruns roll the pages back for a moment
  var img: TileImage?
  for _ in 0..<10 where img == nil {
    img = await txp.render(page: 0, scale: 1, x: 0, y: 0, w: 100, h: 50)
    if img == nil { try await Task.sleep(for: .milliseconds(100)) }
  }
  #expect(img?.width == 100 && img?.height == 50)

  // an edit on page 2: only page 2 changes
  try await Task.sleep(for: .milliseconds(800))  // the idle aux reruns
  txp.open("main.tex", text)
  let at = text.utf8.count - "\n\\end{document}\n".utf8.count
  events = []
  txp.change("main.tex", at, 0, " Added.")
  try await waitFor { events.contains { $0.done && !$0.changed.isEmpty } }
  let changed = Set(events.flatMap(\.changed))
  #expect(changed == [1])

  let st = SyncTex(try #require(await txp.synctex()))
  #expect(st.forward(file: "main.tex", line: 3)?.page == 0)
}

@Test func texErrorLines() {
  // Tectonic's summary line, plain stderr: kept whole, with file and line
  #expect(TxpProcess.texError(#"Error: main.tex:4: LaTeX Error: Missing \begin{document}."#)
    == #"main.tex:4: LaTeX Error: Missing \begin{document}."#)
  #expect(TxpProcess.texError("Error: sections/intro.tex:12: Undefined control sequence")
    == "sections/intro.tex:12: Undefined control sequence")
  // TeX's own `!` line (JSON), with its l.N pointer
  #expect(TxpProcess.texError(#"["append-lines", "out", "! Text line contains an invalid character.", "\nl.38 ^^[", "\n        nd{document}"]"#)
    == "! Text line contains an invalid character. l.38 ^^[")
  #expect(TxpProcess.texError(#"["append-lines", "out", "! Emergency stop"]"#) == "! Emergency stop")
  // not errors
  #expect(TxpProcess.texError(#"["append-lines", "log", "! Emergency stop"]"#) == nil)
  #expect(TxpProcess.texError(#"["append-lines", "out", "(ts1cmr.fd) [1]"]"#) == nil)
  #expect(TxpProcess.texError("[info] output 1 pages long") == nil)
  #expect(TxpProcess.texError("Error: ") == nil)
}

// A source line (12) holding a whole paragraph: three typeset lines of words (x) and kerns, a figure box (60 pt tall)
// whose glue also carries line 12, and a footer kern from line 12.
let paragraph = """
  SyncTeX Version:1
  Input:1:./main.tex
  Magnification:1000
  Unit:1
  Content:
  {1
  [1,4:\(72 * sp),\(700 * sp):\(400 * sp),\(600 * sp),0
  (1,12:\(72 * sp),\(160 * sp):\(400 * sp),\(60 * sp),0
  g1,12:\(72 * sp),\(160 * sp)
  )
  (1,12:\(72 * sp),\(200 * sp):\(400 * sp),\(8 * sp),\(2 * sp)
  x1,12:\(80 * sp),\(200 * sp)
  k1,12:\(120 * sp),\(200 * sp):\(3 * sp)
  x1,12:\(130 * sp),\(200 * sp)
  )
  (1,12:\(72 * sp),\(212 * sp):\(400 * sp),\(8 * sp),\(2 * sp)
  x1,12:\(80 * sp),\(212 * sp)
  (1,12:\(100 * sp),\(212 * sp):\(40 * sp),\(8 * sp),\(2 * sp)
  x1,12:\(102 * sp),\(212 * sp)
  )
  x1,12:\(150 * sp),\(212 * sp)
  )
  (1,12:\(72 * sp),\(224 * sp):\(400 * sp),\(8 * sp),\(2 * sp)
  x1,12:\(80 * sp),\(224 * sp)
  )
  ]
  k1,12:\(300 * sp),\(750 * sp):\(1 * sp)
  }1
  """

@Test func syncTexRowsOneTypesetLine() throws {
  let st = SyncTex(paragraph)
  let r = try #require(st.rows(file: "main.tex", line: 12))
  let pt = 72.0 / 72.27
  // the three typeset lines only: no figure box, no footer; the \mbox-like inner box folds into its line
  #expect(r.rows.count == 3)
  #expect(r.rows.allSatisfy { $0.rect.height < 12 })
  #expect(abs(r.rows[0].rect.minY - 192 * pt) < 0.01)
  #expect(abs(r.rows[2].rect.minY - 216 * pt) < 0.01)
  #expect(r.marks.first == 0 && r.marks.last == 2)
  #expect(r.marks.count == 7)  // the leaves of the three lines (x, k), in order
}

/// The forward mark's line band covers the one typeset line the word is on: its own height, never the paragraph.
@Test func lineBandIsOneTypesetLine() throws {
  let rows = try #require(SyncTex(paragraph).rows(file: "main.tex", line: 12)).rows.map(\.rect)
  #expect(rows.count == 3)
  let mid = rows[1]
  let word = CGRect(x: mid.minX + 40, y: mid.minY + 1, width: 30, height: mid.height - 2)
  let lines = LineMark.lines(word: [word], rows: rows)
  #expect(lines == [mid])
  let band = LineMark.band(lines[0])
  #expect(band.height < mid.height + 4)  // one line's height, a little padding
  #expect(band.width >= mid.width && band.width < mid.width + 8)  // the whole line, edge to edge
  #expect(band.contains(word))
  for other in [rows[0], rows[2]] { #expect(!band.contains(CGPoint(x: other.midX, y: other.midY))) }  // no neighbour
  // a word hyphenated across two lines: both lines, each its own band
  let split = [CGRect(x: rows[0].maxX - 20, y: rows[0].minY + 1, width: 18, height: 6),
               CGRect(x: rows[1].minX, y: rows[1].minY + 1, width: 12, height: 6)]
  #expect(LineMark.lines(word: split, rows: rows) == [rows[0], rows[1]])
  // an enclosing taller box (a figure, a paragraph) never wins over the line, and alone it gets no band
  let figure = CGRect(x: 72, y: 150, width: 400, height: 120)
  #expect(LineMark.lines(word: [word], rows: [figure] + rows) == [mid])
  #expect(LineMark.lines(word: [word], rows: [figure]).isEmpty)
  #expect(LineMark.lines(word: [CGRect(x: 0, y: 700, width: 5, height: 5)], rows: rows).isEmpty)
  // the margin tick: left of the line, centred on it; bigger in page points when zoomed out
  let t1 = LineMark.tick(mid, magnification: 1), tq = LineMark.tick(mid, magnification: 0.25)
  #expect(t1.maxX < mid.minX && abs(t1.midY - mid.midY) < 0.01)
  #expect(t1.height < 20 && tq.height >= 14 / 0.25 - 0.01 && tq.width > t1.width)
}

@MainActor @Test func markColorChoice() {
  #expect(MarkColor.hex(MarkColor.color(hex: "#f5c400")!) == "#f5c400")
  #expect(MarkColor.color(hex: "nope") == nil)
  #expect(MarkColor.presets.first?.key == "accent")
  let light = MarkColor.Tint(dark: false), dark = MarkColor.Tint(dark: true)
  #expect(light.band < light.word && light.band <= 0.15)  // the line fainter than the word
  #expect(dark.band > light.band && dark.word > light.word)
  // right-click ▸ Highlight Colour ▸ Yellow stores it, and the menu then ticks it
  let saved = UserDefaults.standard.string(forKey: MarkColor.key)
  defer { UserDefaults.standard.set(saved, forKey: MarkColor.key) }
  let view = PDFPaneView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
  let sub = view.contextMenu().item(withTitle: "Highlight Colour")?.submenu
  let yellow = sub?.item(withTitle: "Yellow")
  #expect(yellow != nil && sub?.item(withTitle: "Custom…") != nil)
  if let yellow, let action = yellow.action { _ = (yellow.target as? NSObject)?.perform(action, with: yellow) }
  #expect(MarkColor.stored == "#f5c400")
  #expect(view.contextMenu().item(withTitle: "Highlight Colour")?.submenu?.item(withTitle: "Yellow")?.state == .on)
}

/// Comments on the PDF: each on the typeset line its start column falls on (from a fake SyncTeX map), resolved ones
/// left out, notes on one line stacked outward without overlapping, in the wider margin.
@Test func commentNotePlacement() throws {
  let st = SyncTex(paragraph)
  let text = "alpha beta gamma delta epsilon zeta eta"  // 7 words over the 7 records of the 3 typeset lines
  let rows = try #require(st.rows(file: "main.tex", line: 12)).rows.map(\.rect)
  let cs = [
    PDFComment(id: "a", path: "main.tex", line: 12, column: 0, author: "Ana"),  // alpha: line 1
    PDFComment(id: "b", path: "main.tex", line: 12, column: 36, author: "Ben"),  // eta: line 3
    PDFComment(id: "c", path: "main.tex", line: 12, column: 6, author: "Chen"),  // beta: line 1 too
    PDFComment(id: "d", path: "main.tex", line: 12, column: 23, author: "Ana"),  // epsilon: line 2
    PDFComment(id: "r", path: "main.tex", line: 12, column: 0, author: "Ana", resolved: true),
    PDFComment(id: "x", path: "other.tex", line: 3, author: "Ana"),  // not in SyncTeX
  ]
  let placed = NotePlacement.place(
    cs, rows: { st.rows(file: $0, line: $1) }, source: { $1 == 12 ? text : nil }, pageWidth: { _ in 612 })
  #expect(placed.map(\.id) == ["a", "b", "c", "d"])
  let by = Dictionary(uniqueKeysWithValues: placed.map { ($0.id, $0) })
  #expect(by["a"]!.line == rows[0] && by["c"]!.line == rows[0])
  #expect(by["d"]!.line == rows[1] && by["b"]!.line == rows[2])
  #expect(by["a"]!.slot == 0 && by["c"]!.slot == 1 && by["b"]!.slot == 0)
  // text 72–472 pt of a 612 pt page: the right margin is wider
  #expect(placed.allSatisfy { $0.side == .right })
  #expect(NotePlacement.side(text: CGRect(x: 200, y: 0, width: 380, height: 9), pageWidth: 612) == .left)
  #expect(NotePlacement.side(text: CGRect(x: 108, y: 0, width: 396, height: 9), pageWidth: 612) == .right)  // a tie
  let ma = NotePlacement.marker(by["a"]!, size: 10, pageWidth: 612), mc = NotePlacement.marker(by["c"]!, size: 10, pageWidth: 612)
  #expect(ma.minX > rows[0].maxX && ma.maxX < 612)
  #expect(abs(ma.midY - rows[0].midY) < 0.01)
  #expect(mc.minX >= ma.maxX && !mc.intersects(ma))  // stacked outward, apart
  #expect(NotePlacement.marker(by["a"]!, size: 30, pageWidth: 612).width == 30)
  // zoomed out, markers taller than a line: laid out so none overlap, all still in the margin
  let big = NotePlacement.markers(placed, size: 30, pageWidth: { _ in 612 })
  let bigRects = Array(big.values)
  #expect(bigRects.count == 4)
  for i in bigRects.indices { for j in bigRects.indices where i < j { #expect(!bigRects[i].insetBy(dx: 0.5, dy: 0.5).intersects(bigRects[j])) } }
  #expect(bigRects.allSatisfy { $0.minX > rows[0].maxX && $0.maxX <= 612 })
  // a line moved after the words were read: slots again
  var moved = placed
  moved[1].line = rows[0]
  #expect(NotePlacement.restack(moved).map(\.slot) == [0, 1, 2, 0])
  // the quote tint: one rect per typeset line
  let words = [
    WordMatch.PageWord("gamma", [CGRect(x: 300, y: 100, width: 30, height: 9)]),
    WordMatch.PageWord("delta", [CGRect(x: 335, y: 100, width: 30, height: 9)]),
    WordMatch.PageWord("eps", [CGRect(x: 370, y: 100, width: 20, height: 9)], hyphenBreak: true),
    WordMatch.PageWord("ilon", [CGRect(x: 72, y: 112, width: 20, height: 9)]),
  ]
  let span = NotePlacement.span(page: words, from: 0, to: 3)
  #expect(span == [CGRect(x: 300, y: 100, width: 90, height: 9), CGRect(x: 72, y: 112, width: 20, height: 9)])
  #expect(NotePlacement.span(page: words, from: 2, to: 1).isEmpty)
}

/// The toggle hides the notes and lets clicks through; a click on a note reports its comment.
@MainActor @Test func commentNoteToggleAndClick() throws {
  let saved = UserDefaults.standard.object(forKey: NotesOverlay.shownKey)
  defer { UserDefaults.standard.set(saved, forKey: NotesOverlay.shownKey) }
  UserDefaults.standard.removeObject(forKey: NotesOverlay.shownKey)
  let view = PDFPaneView(frame: NSRect(x: 0, y: 0, width: 700, height: 400))
  let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: true)
  window.isReleasedWhenClosed = false
  window.contentView = view
  defer { window.close() }
  view.setSizes([CGSize(width: 612, height: 792)])
  #expect(view.notes.shown)  // on by default
  let line = CGRect(x: 72, y: 200, width: 400, height: 9)
  view.notes.set(
    [PlacedNote(id: "a", page: 0, line: line, side: .right, slot: 0), PlacedNote(id: "b", page: 0, line: line, side: .right, slot: 1)],
    comments: [PDFComment(id: "a", path: "main.tex", line: 1, author: "Ana"), PDFComment(id: "b", path: "main.tex", line: 1, author: "Ben")])
  var clicked: [String] = []
  view.notes.onClick = { clicked.append($0) }
  var toggled: [Bool] = []
  view.notes.onShownChanged = { toggled.append($0) }
  let pa = try #require(view.notePoint("a")), pb = try #require(view.notePoint("b"))
  #expect(view.clickPages(at: pa) && view.clickPages(at: pb))
  #expect(clicked == ["a", "b"])
  #expect(!view.clickPages(at: NSPoint(x: pa.x - 150, y: pa.y)))  // on the text: not a note
  view.hoverPages(at: pa)
  #expect(view.noteCardShown == "a")
  view.hoverPages(at: nil)
  #expect(view.noteCardShown == nil)
  // a click pins the card open; it stays while scrolling, moving with its note
  #expect(view.clickPages(at: pa) && view.notePinned == "a" && clicked.last == "a")
  let f0 = try #require(view.pinnedCardFrame)
  let m0 = view.pagesView.convert(pa, to: view)
  view.scrollTo(page: 0, y: 260)
  view.notes.reposition()
  let f1 = try #require(view.pinnedCardFrame)
  let m1 = view.pagesView.convert(pa, to: view)
  #expect(m1.y != m0.y && abs((f1.minY - f0.minY) - (m1.y - m0.y)) < 1.5)  // moved with the note
  #expect(view.notePinned == "a")
  // hovering another note still shows its hover card; the pinned one stays
  view.hoverPages(at: view.notePoint("b")!)
  #expect(view.noteCardShown == "b" && view.notePinned == "a")
  view.hoverPages(at: nil)
  // hovering the pinned note: no second card
  view.hoverPages(at: view.notePoint("a")!)
  #expect(view.noteCardShown == nil)
  view.hoverPages(at: nil)
  // one at a time: clicking b pins b instead
  #expect(view.clickPages(at: view.notePoint("b")!) && view.notePinned == "b")
  #expect(view.subviews.filter { $0 is PinnedCard }.count == 1)
  // the note again: unpinned (and still reported, for the jump)
  #expect(view.clickPages(at: view.notePoint("b")!) && view.notePinned == nil && clicked.last == "b")
  // a click elsewhere on the PDF: unpinned, and the click goes on to the page
  _ = view.clickPages(at: view.notePoint("a")!)
  #expect(!view.clickPages(at: NSPoint(x: 200, y: 300)) && view.notePinned == nil && view.pinnedCardFrame == nil)
  // Esc: unpinned
  _ = view.clickPages(at: view.notePoint("a")!)
  view.escapeForTest()
  #expect(view.notePinned == nil)
  // the comments change but it is still there: stays pinned; it went away: unpinned
  _ = view.clickPages(at: view.notePoint("a")!)
  view.notes.set([PlacedNote(id: "a", page: 0, line: line, side: .right, slot: 0)],
    comments: [PDFComment(id: "a", path: "main.tex", line: 1, author: "Ana", replies: 1)])
  #expect(view.notePinned == "a")
  view.notes.set([], comments: [])
  #expect(view.notePinned == nil && view.subviews.filter { $0 is PinnedCard }.isEmpty)
  view.notes.set(
    [PlacedNote(id: "a", page: 0, line: line, side: .right, slot: 0), PlacedNote(id: "b", page: 0, line: line, side: .right, slot: 1)],
    comments: [PDFComment(id: "a", path: "main.tex", line: 1, author: "Ana"), PDFComment(id: "b", path: "main.tex", line: 1, author: "Ben")])
  clicked = []
  _ = view.clickPages(at: pa)  // pinned again: toggling comments off unpins
  #expect(view.notePinned == "a")
  // off from the right-click menu: remembered, clicks pass through
  let item = try #require(view.contextMenu().item(withTitle: "Show Comments on PDF"))
  #expect(item.state == .on)
  view.toggleComments(item)
  #expect(!view.notes.shown && toggled == [false] && view.notePinned == nil)
  #expect(UserDefaults.standard.object(forKey: NotesOverlay.shownKey) as? Bool == false)
  #expect(!view.clickPages(at: pa) && clicked.count == 1)
  #expect(view.contextMenu().item(withTitle: "Show Comments on PDF")?.state == .off)
  view.notes.shown = true
  #expect(view.clickPages(at: pa))
}

/// Selecting on the PDF: the drag's ends in reading order, the lines it covers while it lasts, then the words.
@Test func pdfSelectionGeometry() throws {
  let rows = [CGRect(x: 100, y: 100, width: 300, height: 10), CGRect(x: 100, y: 112, width: 300, height: 10),
              CGRect(x: 100, y: 124, width: 300, height: 10)]
  // dragged upwards: swapped
  let (s, e) = SelectionGeometry.ordered(CGPoint(x: 150, y: 128), CGPoint(x: 250, y: 104), rows: rows)
  #expect(s == CGPoint(x: 250, y: 104) && e == CGPoint(x: 150, y: 128))
  // right to left on one line: swapped
  #expect(SelectionGeometry.ordered(CGPoint(x: 300, y: 105), CGPoint(x: 120, y: 105), rows: rows).0.x == 120)
  let p = SelectionGeometry.provisional(rows: rows, start: s, end: e)
  #expect(p == [CGRect(x: 250, y: 100, width: 150, height: 10), rows[1], CGRect(x: 100, y: 124, width: 50, height: 10)])
  #expect(SelectionGeometry.provisional(rows: rows, start: CGPoint(x: 120, y: 113), end: CGPoint(x: 180, y: 115))
    == [CGRect(x: 120, y: 112, width: 60, height: 10)])
  // words: three a line, 40 pt each; "exam-"/"ple" hyphenated over lines 2 and 3
  func w(_ t: String, _ row: Int, _ i: Int) -> WordMatch.PageWord {
    WordMatch.PageWord(t, [CGRect(x: 100 + Double(i) * 50, y: rows[row].minY + 1, width: 40, height: 8)])
  }
  var words = [w("a", 0, 0), w("b", 0, 1), w("c", 0, 2), w("d", 1, 0), w("e", 1, 1),
               WordMatch.PageWord("example", [CGRect(x: 200, y: 113, width: 40, height: 8), CGRect(x: 100, y: 125, width: 20, height: 8)]),
               w("f", 2, 1), w("g", 2, 2)]
  // from the middle of "b" to the middle of "f"
  #expect(SelectionGeometry.pick(words: words, rows: rows, start: CGPoint(x: 170, y: 105), end: CGPoint(x: 170, y: 128))! == (1, 6))
  // ending inside "ple" on line 3: the hyphenated word is in, "f" isn't
  #expect(SelectionGeometry.pick(words: words, rows: rows, start: CGPoint(x: 210, y: 116), end: CGPoint(x: 110, y: 128))! == (5, 5))
  // between two words: nothing
  words = [w("a", 0, 0), w("b", 0, 1)]
  #expect(SelectionGeometry.pick(words: words, rows: rows, start: CGPoint(x: 141, y: 105), end: CGPoint(x: 148, y: 105)) == nil)
}

/// The selection's pill opens a draft card; Return sends it with the source range; Esc or a click gives it up. The
/// pinned card replies and resolves.
@MainActor @Test func pdfCommentFromSelectionAndReply() throws {
  let view = PDFPaneView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
  let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: true)
  window.isReleasedWhenClosed = false
  window.contentView = view
  defer { window.close() }
  view.setSizes([CGSize(width: 612, height: 792)])
  var sent: [(PDFCommentDraft, String)] = []
  view.selection.onSend = { sent.append(($0, $1)) }
  let d = PDFCommentDraft(path: "main.tex", line: 177, column: 31, endLine: 177, endColumn: 44, quote: "critical role")
  view.selection.show(page: 0, rects: [CGRect(x: 200, y: 150, width: 80, height: 10)])
  #expect(view.commentPillFrame == nil)  // no pill while dragging
  view.selection.offer(d)
  let pill = try #require(view.commentPillFrame)
  let end = view.toPane(NSPoint(x: view.pages[0].origin.x + 280, y: view.pages[0].origin.y + 160))
  #expect(pill.maxY <= end.y + 1 && abs(pill.midX - end.x) < pill.width)  // under the selection's end
  view.clickCommentPill()
  #expect(view.commentPillFrame == nil && view.draftCardFrame != nil)
  view.sendCardForTest("   ")  // blank: not sent
  #expect(sent.isEmpty && view.draftCardFrame != nil)
  view.sendCardForTest("Too strong?")
  #expect(sent.count == 1 && sent[0].0 == d && sent[0].1 == "Too strong?")
  #expect(view.selectionDraft == nil && view.draftCardFrame == nil && view.selectionRects.isEmpty)  // cleared
  // a plain click on the page gives a selection up
  view.selection.show(page: 0, rects: [CGRect(x: 200, y: 150, width: 80, height: 10)])
  view.selection.offer(d)
  #expect(!view.clickPages(at: NSPoint(x: 300, y: 400)))
  #expect(view.selectionRects.isEmpty && view.commentPillFrame == nil)
  // the pinned card: Reply (Return) and Resolve go out with its id
  let line = CGRect(x: 72, y: 200, width: 400, height: 9)
  view.notes.set([PlacedNote(id: "a", page: 0, line: line, side: .right, slot: 0)],
    comments: [PDFComment(id: "a", path: "main.tex", line: 1, author: "Ana", firstMessage: "Hm?")])
  var replies: [String] = [], resolved: [String] = []
  view.notes.onReply = { replies.append("\($0):\($1)") }
  view.notes.onResolve = { resolved.append($0) }
  _ = view.clickPages(at: try #require(view.notePoint("a")))
  #expect(view.notePinned == "a")
  view.sendCardForTest("Agreed", pinned: true)
  view.resolvePinnedForTest()
  #expect(replies == ["a:Agreed"] && resolved == ["a"])
  #expect(view.notes.pinnedCard?.field.string == "")  // cleared after sending
}

/// The thread on the PDF: the pinned card shows every message (author, time, text), scrolls when long with the
/// newest reply in view and the reply field under it; the hover card shows the first message and the reply count.
@MainActor @Test func pdfCommentThread() throws {
  let now = Date()
  var msgs = [PDFCommentMessage(author: "Ana Lima", color: "#e8590c", text: "Is “critical” too strong?", time: now.addingTimeInterval(-3 * 86400))]
  for n in 1...12 {
    let who = n % 2 == 0 ? "Ana Lima" : "Ben Okafor"
    let at = now.addingTimeInterval(Double(-3600 * (12 - n)))
    msgs.append(PDFCommentMessage(author: who, text: "Reply number \(n), long enough to wrap onto a second line of the card.", time: at, mine: n % 2 == 0))
  }
  let c = PDFComment(id: "a", path: "main.tex", line: 1, author: "Ana Lima", color: "#e8590c", messages: msgs)
  #expect(c.firstMessage == "Is “critical” too strong?" && c.replies == 12)
  #expect(PDFComment.ago(now.addingTimeInterval(-20), now: now) == "just now")
  #expect(!PDFComment.ago(now.addingTimeInterval(-7200), now: now).isEmpty)
  func labels(_ v: NSView) -> [String] {
    var out: [String] = []
    if let t = v as? NSTextField, !t.isEditable { out.append(t.stringValue) }
    if let sv = v as? NSScrollView, let d = sv.documentView { out += labels(d) }
    for s in v.subviews where !(v is NSScrollView) { out += labels(s) }
    return out
  }
  // hover: the first message and "12 replies", no thread
  let hover = NoteCard(c, color: .orange)
  let hl = labels(hover.view)
  #expect(hl.contains("Is “critical” too strong?") && hl.contains("12 replies"))
  #expect(!hl.contains { $0.hasPrefix("Reply number") })
  // pinned: the whole thread, each reply with its author and time
  let view = PDFPaneView(frame: NSRect(x: 0, y: 0, width: 700, height: 700))
  let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: true)
  window.isReleasedWhenClosed = false
  window.contentView = view
  defer { window.close() }
  view.setSizes([CGSize(width: 612, height: 792)])
  view.notes.set([PlacedNote(id: "a", page: 0, line: CGRect(x: 72, y: 200, width: 400, height: 9), side: .right, slot: 0)], comments: [c])
  _ = view.clickPages(at: try #require(view.notePoint("a")))
  let card = try #require(view.notes.pinnedCard)
  let pl = labels(card)
  #expect((1...12).allSatisfy { n in pl.contains { $0.hasPrefix("Reply number \(n),") } })
  #expect(pl.contains { $0.hasPrefix("Ben Okafor") && $0.contains("ago") })
  // long: it scrolls, at most maxThread tall, the newest reply in view
  let sv = try #require(card.content.scroll)
  let doc = try #require(sv.documentView)
  #expect(doc.frame.height > NoteCard.maxThread && sv.frame.height <= NoteCard.maxThread + 0.5)
  #expect(abs(sv.contentView.bounds.maxY - doc.frame.height) < 1)
  // the reply field under the thread
  let field = card.field.convert(card.field.bounds, to: card), thread = sv.convert(sv.bounds, to: card)
  #expect(field.maxY <= thread.minY + 1)
  // a short thread doesn't scroll
  let short = PDFComment(id: "b", path: "main.tex", line: 1, author: "Ben", messages: Array(msgs.prefix(2)))
  view.notes.set([PlacedNote(id: "b", page: 0, line: CGRect(x: 72, y: 300, width: 400, height: 9), side: .right, slot: 0)], comments: [short])
  _ = view.clickPages(at: try #require(view.notePoint("b")))
  let s2 = try #require(view.notes.pinnedCard?.content.scroll)
  #expect(abs(s2.frame.height - (s2.documentView?.frame.height ?? 0)) < 1)
}

/// One mark per jump, and it stays: it appears once, glides to each new place, stays put for the same place (an
/// inverse search's cursor-follow echo, a repeated ⌘⌥J), dims to an underline when idle, and goes when the cursor
/// leaves the document. No timed fade.
@MainActor @Test func oneMarkPerJump() async throws {
  let line = CGRect(x: 108, y: 500, width: 396, height: 9), word = CGRect(x: 275, y: 500, width: 18, height: 10)
  let other = CGRect(x: 108, y: 511, width: 396, height: 9), word2 = CGRect(x: 300, y: 511, width: 30, height: 10)
  let m = MarkPlan.Mark(page: 0, words: [word], lines: [line])
  #expect(MarkPlan.decide(current: nil, page: 0, words: [word], lines: [line]) == .appear)
  #expect(MarkPlan.decide(current: m, page: 0, words: [word], lines: [line]) == .stay)
  #expect(MarkPlan.decide(current: m, page: 0, words: [word], lines: []) == .stay)
  #expect(MarkPlan.decide(current: m, page: 0, words: [word2], lines: [other]) == .glide)
  #expect(MarkPlan.decide(current: m, page: 0, words: [], lines: [line]) == .glide)  // the word goes, the band stays
  #expect(MarkPlan.decide(current: m, page: 3, words: [word], lines: [line]) == .glide)  // to another page too
  var dim = m
  dim.dimmed = true
  #expect(MarkPlan.decide(current: dim, page: 0, words: [word], lines: [line]) == .appear)

  let view = PDFPaneView(frame: NSRect(x: 0, y: 0, width: 700, height: 900))
  view.setSizes([CGSize(width: 612, height: 792), CGSize(width: 612, height: 792)])
  // a slow read: the band first, then the word joins it → appear, then glide (the band doesn't move)
  view.reveal(page: 0, rects: [], lines: [line])
  view.reveal(page: 0, rects: [word], lines: [line])
  #expect(view.markCounts == (1, 1, 0))
  // a PDF double-click on the word, then its cursor-follow echo: nothing moves
  view.reveal(page: 0, rects: [word], lines: [line])
  view.reveal(page: 0, rects: [word], lines: [line])
  #expect(view.markCounts == (1, 1, 2))
  // the cursor moves on: one glide each, never a new appearance, whatever the time between
  view.reveal(page: 0, rects: [word2], lines: [other])
  view.reveal(page: 1, rects: [word], lines: [line])
  #expect(view.markCounts == (1, 3, 2) && view.markShown && !view.markDimmed)
  // the mark's layers sit where the word is, in the pages view (document points): no timed fade
  let boxes = view.forward.layer.sublayers ?? []
  #expect(boxes.allSatisfy { $0.opacity == 1 })
  let o = view.pages[1].origin
  #expect(boxes.contains { abs($0.frame.minY - (o.y + word.minY - 1)) < 0.5 })
  // idle: an underline; the next jump brings it back (appear)
  view.forward.dim()
  #expect(view.markDimmed)
  view.reveal(page: 1, rects: [word], lines: [line])
  #expect(view.markCounts.appear == 2 && !view.markDimmed)
  // the cursor left the document: gone
  view.clearMark()
  #expect(!view.markShown && view.revealed == nil)
}

/// The cursor dot: a coral caret from 0.72 em above the baseline to it, the dot (radius 0.17 em) under it, a ring
/// instead when the place is approximate; hidden for nil (the line typesets nothing).
@MainActor @Test func cursorDotGeometry() throws {
  let view = PDFPaneView(frame: NSRect(x: 0, y: 0, width: 700, height: 900))
  view.setSizes([CGSize(width: 612, height: 792), CGSize(width: 612, height: 792)])
  view.cursorDot.draw(page: 1, x: 300, top: 500, bottom: 512, baseline: 509.5, approximate: false)
  let layers = view.cursorDot.layer.sublayers ?? []
  let o = view.pages[1].origin
  let bar = layers[0], dot = layers[1], ring = layers[2]
  let em = 12 / 1.2
  #expect(!view.cursorDot.layer.isHidden)
  #expect(abs(bar.frame.midX - (o.x + 300)) < 0.01 && abs(bar.frame.width - 0.9) < 0.01)
  #expect(abs(bar.frame.maxY - (o.y + 509.5)) < 0.01 && abs(bar.frame.height - 0.72 * em) < 0.01)
  #expect(abs(dot.frame.width - 2 * 0.17 * em) < 0.01 && dot.frame.minY > o.y + 509.5)  // under the baseline
  #expect(!dot.isHidden && ring.isHidden)
  view.cursorDot.draw(page: 1, x: 300, top: 500, bottom: 512, baseline: 509.5, approximate: true)
  #expect(dot.isHidden && !ring.isHidden)
  view.showCaret(nil)
  #expect(view.cursorDot.layer.isHidden && view.caret == nil)
}

/// Only the coral dot follows the cursor; the highlight marks deliberate jumps (⌘⌥J, ]r, a click in the PDF) and
/// goes, with a quick fade, once the cursor leaves that line. "Highlight follows the cursor" brings the old way back.
@MainActor @Test func highlightOnlyOnDeliberateJumps() throws {
  // off by default (read-only check: writing the defaults would reach the other tests' settings observers)
  if UserDefaults.standard.object(forKey: "taudot.pdfHighlightFollows") == nil { #expect(!TaudotPDFPane.highlightFollows) }
  TaudotPDFPane.followsForTest = false
  defer { TaudotPDFPane.followsForTest = nil }
  let pdf = TaudotPDFPane()
  pdf.pane.setSizes([CGSize(width: 612, height: 792)])
  let line = CGRect(x: 108, y: 500, width: 396, height: 9), word = CGRect(x: 275, y: 500, width: 18, height: 10)
  // a deliberate jump (here: its mark, as jump draws it) for main.tex:177
  pdf.cursorMoved(path: "main.tex", line: 177, column: 40, deliberate: true)
  #expect(pdf.markFor?.line == 177)
  pdf.pane.reveal(page: 0, rects: [word], lines: [line])
  #expect(!pdf.pane.forward.dimWhenIdle)  // stays: no idle dim
  // the cursor moves within the line (another word): it stays, and isn't redrawn
  let counts = pdf.pane.markCounts
  pdf.cursorMoved(path: "main.tex", line: 177, column: 200, deliberate: false)
  #expect(pdf.pane.markShown && pdf.pane.markCounts == counts)
  // another line: it goes
  pdf.cursorMoved(path: "main.tex", line: 178, column: 0, deliberate: false)
  #expect(!pdf.pane.markShown && pdf.markFor == nil)
  // ordinary moves never bring it back
  pdf.cursorMoved(path: "main.tex", line: 179, column: 0, deliberate: false)
  #expect(!pdf.pane.markShown && pdf.markFor == nil)
  // follow mode: every move is a jump (the mark follows, dims when idle)
  TaudotPDFPane.followsForTest = true
  pdf.cursorMoved(path: "main.tex", line: 180, column: 0, deliberate: false)
  #expect(pdf.markFor == nil && pdf.pane.forward.dimWhenIdle)  // a follow jump isn't a deliberate mark
}

/// A Finder/Dock launch: launchd's PATH (/usr/bin:/bin) gets the usual install places (tectonic), and a driver that
/// dies never takes the app with it (its stdin is written after it exited: EPIPE, not SIGPIPE).
@MainActor @Test func driverLaunchEnvironmentAndDeadPipe() throws {
  let env = TxpPaths.environment(["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()])
  let path = env["PATH"]!.split(separator: ":").map(String.init)
  #expect(path.prefix(2) == ["/usr/bin", "/bin"] && path.contains("/opt/homebrew/bin") && path.contains("/usr/local/bin"))
  #expect(env["TEXPRESSO_XETEX"] != nil)
  // a driver that exits at once; then a burst of writes before the exit handler has run (this would SIGPIPE)
  let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("txs-deadpipe-\(UUID().uuidString.prefix(6))")
  try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: tmp) }
  let p = try TxpProcess(main: tmp.appendingPathComponent("main.tex"), tmp: tmp, executable: "/usr/bin/false")
  usleep(200_000)  // it has exited; the main queue hasn't heard yet
  for i in 0..<100 { p.change("main.tex", i, 0, "x") }
  #expect(Bool(true))  // still here
}

/// The page cache: the last run's pages, sizes and view position written, then read back at the next open.
@Test func pageCacheRoundTrip() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("txs-pagecache-\(UUID().uuidString.prefix(6))")
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = URL(fileURLWithPath: "/tmp/some-project")
  #expect(PageCache.load(folder, main: "main.tex", root: root) == nil)
  let ctx = CGContext(data: nil, width: 40, height: 52, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
  ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 52))
  PageCache.write(folder, page: 0, image: ctx.makeImage()!, root: root)
  PageCache.write(folder, synctex: "SyncTeX Version:1\n", root: root)
  PageCache.write(folder, index: .init(main: "main.tex", sizes: [[612, 792], [612, 792]], scales: [2, 0.8], topPage: 1, topY: 120, saved: Date()), root: root)
  let i = try #require(PageCache.load(folder, main: "main.tex", root: root))
  #expect(i.sizes.count == 2 && i.topPage == 1 && i.topY == 120 && i.scales == [2, 0.8])
  #expect(PageCache.load(folder, main: "other.tex", root: root) == nil)  // another main file: not this cache
  #expect(PageCache.image(folder, page: 0, root: root)?.width == 40 && PageCache.image(folder, page: 1, root: root) == nil)
  #expect(PageCache.synctex(folder, root: root)?.hasPrefix("SyncTeX") == true)
  #expect(PageCache.dir(folder, root: root) != PageCache.dir(URL(fileURLWithPath: "/tmp/another"), root: root))
  #expect(PageCache.dir(folder, root: root).path.hasPrefix(root.path))
}

/// Where the cursor dot hides: only where nothing is typeset (the preamble, a comment, a file not in the document);
/// anywhere else it shows, a ring at an estimate if need be.
@Test func cursorDotHidesOnlyOffTheDocument() {
  let lines = ["\\documentclass{article}", "% a comment", "\\usepackage{x}", "\\begin{document}",
               "Some text % and a comment", "% only a comment", "\\caption{A caption.}", "\\end{document}"]
  func at(_ l: Int, _ c: Int, main: Bool = true, doc: Bool = true) -> String? {
    TaudotPDFPane.notTypeset(inDocument: doc, main: main, lines: lines, line: l, column: c)
  }
  #expect(at(1, 3) == "preamble" && at(3, 0) == "preamble" && at(4, 2) == "preamble")
  #expect(at(5, 2) == nil)  // text
  #expect(at(5, 12) == "comment" && at(5, 20) == "comment")  // at and after the %
  #expect(at(6, 0) == "comment")
  #expect(at(7, 12) == nil)  // a caption: typeset (a ring if CursorMap has nothing)
  #expect(at(1, 3, main: false) == nil)  // an \\input file has no preamble
  #expect(at(5, 2, doc: false) == "other-file")
}

/// A click on a figure: the float around SyncTeX's line (or just before it: the image's box often carries
/// `\end{figure}` or the paragraph after) and its `\includegraphics`; a click on "Figure 3": its `\ref` and `\label`.
@Test func figureAndRefLookup() throws {
  let src = #"""
  Some text before, see Figure~\ref{fig:main} and \autoref{tab:speed}.
  % \begin{figure} commented out
  \begin{figure}[t]
  \centering
  \includegraphics[width=1\linewidth]{overview_A.png}
  \caption{Sketches here. \textbf{(A)} 24 tiny examples.}
  \label{fig:main}
  \end{figure}

  The paragraph after the figure, where SyncTeX often puts the image.
  \begin{figure*}
  \begin{subfigure}{0.5\linewidth}\includegraphics{a.pdf}\end{subfigure}
  \begin{subfigure}{0.5\linewidth}\includegraphics{plots/b.pdf}\end{subfigure}
  \caption{Two panels.}\label{fig:two}
  \end{figure*}
  \begin{table}
  \caption{Speed.}\label{tab:speed}
  \begin{tabular}{ll} a & b \\ \end{tabular}
  \end{table}
  Far away text.
  """#.components(separatedBy: "\n")
  let envs = FloatSource.environments(src)
  #expect(envs.map(\.kind) == ["figure", "figure*", "subfigure", "subfigure", "table"])
  let fig = try #require(FloatSource.around(src, line: 8))  // SyncTeX gave \end{figure}
  #expect(fig.begin == 3 && fig.end == 8 && fig.labels.map(\.key) == ["fig:main"])
  #expect(FloatSource.target(fig) == (5, 0))  // the \includegraphics line, its column
  #expect(FloatSource.around(src, line: 10)?.begin == 3)  // the paragraph after it
  #expect(FloatSource.around(src, line: 10, after: 0) == nil)  // a blank spot: only a float holding the line
  #expect(FloatSource.around(src, line: 1) == nil)  // text before the figure; the commented \begin doesn't count
  #expect(FloatSource.around(src, line: 20)?.kind == "table" && FloatSource.around(src, line: 20, after: 0) == nil)
  #expect(FloatSource.around(src + ["", "", "", "", "", "Later."], line: 26) == nil)  // far from any float
  // a figure with subfigures: the figure, its graphic nearest the line, or the one whose file matches
  let two = try #require(FloatSource.around(src, line: 13))
  #expect(two.kind == "figure*" && two.graphics.count == 2)
  #expect(FloatSource.target(two, near: 13).line == 13)
  #expect(FloatSource.target(two, file: "b").line == 13 && FloatSource.target(two, file: "a.pdf").line == 12)
  #expect(FloatSource.target(FloatSource.around(src, line: 17)!) == (16, 0))  // a table: no graphic, its \begin
  // cross-references
  let line = src[0]
  #expect(FloatSource.refs(line).map(\.key) == ["fig:main", "tab:speed"])
  let see = try #require(WordMatch.sourceWords(line).first { $0.text == "see" })
  #expect(FloatSource.ref(after: see.end, in: line)?.key == "fig:main")  // "see Figure 3": only "Figure" between
  let before = try #require(WordMatch.sourceWords(line).first { $0.text == "before" })
  #expect(FloatSource.ref(after: before.end, in: line) == nil)  // "see" is between: not a reference click
  let and = try #require(WordMatch.sourceWords(line).first { $0.text == "and" })
  #expect(FloatSource.ref(after: and.end, in: line)?.key == "tab:speed")
  #expect(FloatSource.ref(before: and.start, in: line)?.key == "fig:main")
  #expect(FloatSource.label("fig:two", in: src)! == (14, 21))
  #expect(FloatSource.label("nope", in: src) == nil)
  for w in ["3", "2.1", "A.4", "(5)", "Figure", "fig.", "Table"] { #expect(FloatSource.refLike(w), "\(w)") }
  for w in ["the", "games", "a", "RL"] { #expect(!FloatSource.refLike(w), "\(w)") }
}

@Test func sourceWordsSkipCommandsAndMath() {
  let w = WordMatch.sourceWords(#"The \textbf{fast} agent~\citep{smith20} wins $x^2$ 3 times, don't it? % not this"#)
  #expect(w.map(\.text) == ["the", "fast", "agent", "wins", "3", "times", "dont", "it"])
  #expect(w[1].start == 12 && w[1].end == 16)  // "fast", UTF-8 byte columns
  let u = WordMatch.sourceWords("Café naïve ﬁne")
  #expect(u.map(\.text) == ["cafe", "naive", "fine"])
  #expect(u[1].start == 6)  // é is two bytes
  #expect(WordMatch.wordIndex(w, column: 13) == 1)
  #expect(WordMatch.wordIndex(w, column: 16) == 1)  // just after the word
  #expect(WordMatch.wordIndex(w, column: 30) == 2 || WordMatch.wordIndex(w, column: 30) == 3)
  #expect(WordMatch.wordIndex([], column: 3) == nil)
}

@Test func wordMatchBothWays() throws {
  let src = WordMatch.sourceWords("the agent sees the screen and the agent acts on the exam\\-ple screen")
  func pw(_ t: [String]) -> [WordMatch.PageWord] {
    t.enumerated().map { WordMatch.PageWord($0.element, [CGRect(x: Double($0.offset) * 10, y: 0, width: 8, height: 8)]) }
  }
  // typeset: a line break hyphenates "example"; the OCR misread "screen" once
  var page = pw(["the", "agent", "sees", "the", "screen", "and", "the", "agent", "acts", "on", "the", "exam", "ple", "scrcen"])
  page[11].hyphenBreak = true
  // forward: the second "agent" (source word 7) is page word 7, picked by its neighbours, not the first
  let f = try #require(WordMatch.forward(source: src, target: 7, page: page))
  #expect(f.word.rects == page[7].rects)
  // the hyphenated word comes back as both halves
  let ex = try #require(src.firstIndex { $0.text == "example" })
  let h = try #require(WordMatch.forward(source: src, target: ex, page: page))
  #expect(h.word.rects.count == 2)
  // a misread word still matches
  let last = try #require(WordMatch.forward(source: src, target: src.count - 1, page: page))
  #expect(last.word.rects == page[13].rects)
  // inverse: clicking the second "the" (page 3) gives the source's second "the"
  let i = try #require(WordMatch.inverse(page: page, clicked: 3, source: src))
  #expect(i.word == src[3])
  let j = try #require(WordMatch.inverse(page: page, clicked: 12, source: src))  // "ple" → "example"
  #expect(j.word.text == "example")
  #expect(WordMatch.inverse(page: pw(["zebra"]), clicked: 0, source: src) == nil)
}

@Test func pageWordOrder() {
  let rows = [CGRect(x: 0, y: 20, width: 100, height: 10), CGRect(x: 0, y: 0, width: 100, height: 10)]
  let w = WordMatch.order([
    ("ple,", CGRect(x: 0, y: 21, width: 10, height: 8)), ("exam-", CGRect(x: 50, y: 1, width: 20, height: 8)),
    ("An", CGRect(x: 0, y: 1, width: 10, height: 8)), ("far", CGRect(x: 0, y: 60, width: 10, height: 8)),
  ], rows: rows)
  #expect(w.map(\.text) == ["an", "exam", "ple"])
  #expect(w[1].hyphenBreak && !w[0].hyphenBreak)
}

@Test func pageWordOrderDropsDoubleReads() {
  let rows = [CGRect(x: 0, y: 0, width: 100, height: 10)]
  let w = WordMatch.order([
    ("Figure", CGRect(x: 0, y: 1, width: 20, height: 8)), ("Figure", CGRect(x: 0.5, y: 3, width: 20, height: 5)),
    ("4", CGRect(x: 25, y: 1, width: 4, height: 8)),
  ], rows: rows)
  #expect(w.map(\.text) == ["figure", "4"])
  #expect(w[0].rects[0].height == 8)
}

/// After txp-headless restarts, it must still report the page in view early (the goal), not only once the whole
/// document is typeset: the next edit's first report is an early one for page 1.
@MainActor @Test func txpGoalSurvivesRestart() async throws {
  let fm = FileManager.default
  guard fm.isExecutableFile(atPath: TxpPaths.headless), fm.isExecutableFile(atPath: TxpPaths.xetex) else { return }
  let dir = fm.temporaryDirectory.appendingPathComponent("txp-goal-\(UUID().uuidString.prefix(6))")
  try fm.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? fm.removeItem(at: dir) }
  let para = (1...90).map { "Paragraph \($0). " + String(repeating: "Some words to fill the line. ", count: 12) }
  let text = "\\documentclass{article}\n\\begin{document}\n" + para.joined(separator: "\n\n") + "\n\\end{document}\n"
  try text.write(to: dir.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)

  let txp = Txp(main: dir.appendingPathComponent("main.tex"))
  var events: [PagesEvent] = []
  txp.onPages = { events.append($0) }
  txp.start()
  defer { txp.stop() }
  func waitFor(_ cond: () -> Bool) async throws {
    for _ in 0..<400 where !cond() { try await Task.sleep(for: .milliseconds(20)) }
  }
  try await waitFor { events.last?.done == true }
  #expect((events.last?.n ?? 0) > 8)
  txp.goal(0)
  txp.killForTest()
  try await waitFor { txp.restartCount == 1 && txp.proc != nil }
  txp.open("main.tex", text)  // what the pane's onRestart does (the engine's docs again)
  events = []
  try await waitFor { events.last?.done == true }
  try await Task.sleep(for: .milliseconds(2500))  // past the idle aux rerun
  events = []
  let at = text.utf8.count - text.drop { $0 != "P" }.utf8.count + "Paragraph 1.".utf8.count
  txp.change("main.tex", at, 0, " Added")
  try await waitFor { events.contains { $0.done } }
  let first = try #require(events.first)
  #expect(!first.done, "the first report after an edit on page 1 should be the early one for the goal")
  #expect(first.changed.contains(0))
}

/// The bibliography follows the citations: a document with no .bbl gets one from the driver's BibTeX run, a new
/// \cite and a new .bib entry (saved, then a rescan) end up in the PDF, and the .bbl is kept for the next open.
@MainActor @Test(.timeLimit(.minutes(2))) func bibliographyFollowsCitations() async throws {
  // the BibTeX pass is in driver.c: a txp-render built before it has none (on main after a merge, once)
  #expect(TxpPaths.staleDriver == nil, "\(TxpPaths.staleDriver ?? "")")
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("txs-bib-\(UUID().uuidString.prefix(6))")
  let cache = dir.appendingPathComponent("cache")
  try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: dir) }
  func doc(_ cites: String) -> String {
    "\\documentclass{article}\\begin{document}See \\cite{\(cites)}.\\bibliographystyle{plain}\\bibliography{refs}\\end{document}\n"
  }
  let main = dir.appendingPathComponent("main.tex")
  try doc("knuth").write(to: main, atomically: true, encoding: .utf8)
  let bib = dir.appendingPathComponent("refs.bib")
  try "@book{knuth, author={Donald Knuth}, title={The TeXbook}, year={1984}}\n".write(to: bib, atomically: true, encoding: .utf8)

  /// Starts the driver and waits until the page's text satisfies `ok` (checked after each report), or 40 s.
  func run(_ p: TxpProcess, until ok: @escaping (String) -> Bool) async -> String {
    var reports = 0
    p.onPages = { _ in reports += 1 }
    var seen = 0, text = ""
    for _ in 0..<400 {
      try? await Task.sleep(for: .milliseconds(100))
      guard reports > seen else { continue }
      seen = reports
      text = await p.glyphs(page: 0).map { $0.glyphs.map(\.t).joined() } ?? text
      if ok(text) { break }
    }
    return text
  }
  let p = try TxpProcess(main: main, tmp: dir, bibCache: cache)
  defer { p.kill() }
  var t = await run(p) { $0.contains("[1]") && $0.contains("Knuth") }
  #expect(t.contains("See[1]") && t.contains("Knuth"))
  #expect(FileManager.default.fileExists(atPath: cache.appendingPathComponent("main.bbl").path))

  // a new entry in the .bib (saved: a rescan), then cited
  try "@book{knuth, author={Donald Knuth}, title={The TeXbook}, year={1984}}\n@book{lamport, author={Leslie Lamport}, title={LaTeX}, year={1994}}\n"
    .write(to: bib, atomically: true, encoding: .utf8)
  p.rescan()
  p.open("main.tex", doc("knuth,lamport"))
  t = await run(p) { $0.contains("[1,2]") && $0.contains("Lamport") }
  #expect(t.contains("See[1,2]") && t.contains("Lamport") && !t.contains("?"))
  p.kill()

  // reopened: the kept .bbl is read at once (the first report already lists both entries)
  let q = try TxpProcess(main: main, tmp: dir, bibCache: cache)
  defer { q.kill() }
  try doc("knuth,lamport").write(to: main, atomically: true, encoding: .utf8)
  t = await run(q) { !$0.isEmpty }  // the first text: without the kept .bbl it would have no references yet
  #expect(t.contains("Lamport"))
}

/// Dark and sepia pages (Settings ▸ PDF): the driver recolours renders, text light on #1d1f21 when dark, and leaves
/// figures (an included image) as they are; the pane recolours its pages and draws them all again, live.
@MainActor @Test(.timeLimit(.minutes(2))) func pageStyleRecoloursAllButFigures() async throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("txs-style-\(UUID().uuidString.prefix(6))")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: dir) }
  // a 40×40 figure in a mid blue: dark mode would change it
  let ctx = CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
  ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
  let dest = CGImageDestinationCreateWithURL(dir.appendingPathComponent("fig.png") as CFURL, "public.png" as CFString, 1, nil)!
  CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
  CGImageDestinationFinalize(dest)
  let main = dir.appendingPathComponent("main.tex")
  try "\\documentclass{article}\\usepackage{graphicx}\\pagestyle{empty}\\begin{document}\\noindent\\rule{100pt}{20pt}\\par\\vspace{20pt}\\noindent\\includegraphics[width=100pt]{fig.png}\\end{document}\n"
    .write(to: main, atomically: true, encoding: .utf8)
  let p = try TxpProcess(main: main, tmp: dir)
  defer { p.kill() }
  var done = false
  p.onPages = { e in if e.done && e.n > 0 { done = true } }
  for _ in 0..<300 { if done { break }; try await Task.sleep(for: .milliseconds(100)) }
  #expect(done)
  /// The page at 1 px/pt, as (r, g, b) at a point (x, y from the page's top-left).
  func render() async throws -> (Int, Int) -> [Int] {
    var got: TileImage?
    for _ in 0..<50 {  // an aux rerun after the first report has no page for a moment
      got = await p.render(page: 0, scale: 1, x: 0, y: 0, w: 612, h: 792)
      if got != nil { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    let img = try #require(got)
    let s = img.surface
    s.lock(options: .readOnly, seed: nil)
    let bytes = Data(bytes: s.baseAddress, count: s.bytesPerRow * s.height), row = s.bytesPerRow
    s.unlock(options: .readOnly, seed: nil)
    return { x, y in let o = y * row + x * 4; return [Int(bytes[o + 2]), Int(bytes[o + 1]), Int(bytes[o])] }
  }
  // article's text block starts at 1in + \oddsidemargin etc.: find the rule and the figure by scanning the white page
  let white = try await render()
  var ruleAt: (Int, Int)?, figAt: (Int, Int)?
  for y in stride(from: 60, to: 400, by: 2) {
    for x in stride(from: 60, to: 400, by: 2) {
      let c = white(x, y)
      if ruleAt == nil, c.allSatisfy({ $0 < 30 }) { ruleAt = (x + 4, y + 4) }
      if figAt == nil, c[2] > 150, c[0] < 90 { figAt = (x + 4, y + 4) }
    }
  }
  let rule = try #require(ruleAt), fig = try #require(figAt)
  p.pageStyle("dark")
  let dark = try await render()
  #expect(dark(5, 5) == [0x1d, 0x1f, 0x21])  // the page
  #expect(dark(rule.0, rule.1).allSatisfy { $0 > 0xc0 })  // black ink → light
  #expect(dark(fig.0, fig.1) == white(fig.0, fig.1))  // the figure untouched
  p.pageStyle("sepia")
  let sepia = try await render()
  #expect(sepia(5, 5) == [0xf4, 0xec, 0xd8] && sepia(fig.0, fig.1) == white(fig.0, fig.1))
  p.pageStyle("white")
  #expect(try await render()(5, 5) == [255, 255, 255])

  // the pane: page colour, and every page drawn again
  let pane = PDFPaneView(frame: NSRect(x: 0, y: 0, width: 400, height: 500))
  pane.setSizes([CGSize(width: 612, height: 792), CGSize(width: 612, height: 792)])
  let before = pane.pages.map(\.ver)
  pane.setPageStyle(.dark)
  #expect(pane.pages.map(\.ver) == before.map { $0 + 1 })
  #expect(pane.pages[0].layer.backgroundColor == PDFPaneView.PageStyle.dark.paper)
  #expect(pane.appearance?.name == .darkAqua)
  pane.setSizes([CGSize(width: 612, height: 792), CGSize(width: 612, height: 792), CGSize(width: 612, height: 792)])
  #expect(pane.pages[2].layer.backgroundColor == PDFPaneView.PageStyle.dark.paper)  // a new page too
  pane.setPageStyle(.white)
  #expect(pane.appearance == nil && pane.pages[0].layer.backgroundColor == CGColor.white)
}

/// The typesetter's stderr hook: every line, in order, on the main actor, split across chunks, before `onError`.
@MainActor @Test func driverLinesReachTheHook() async throws {
  let fm = FileManager.default
  let tmp = fm.temporaryDirectory.appendingPathComponent("txs-lines-\(UUID().uuidString.prefix(6))")
  try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
  defer { try? fm.removeItem(at: tmp) }
  let fake = tmp.appendingPathComponent("fake-driver")
  try """
    #!/bin/sh
    printf '["append-lines","log","This is XeTeX"]\\n["append-li' >&2
    sleep 0.1
    printf 'nes","out","! Undefined control sequence.","\\\\nl.3 \\\\\\\\foo"]\\n' >&2
    printf 'Error: main.tex:3: Undefined control sequence\\n["truncate-lines","log",1]\\n' >&2
    sleep 0.1
    """.write(to: fake, atomically: true, encoding: .utf8)
  try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
  let p = try TxpProcess(main: tmp.appendingPathComponent("main.tex"), tmp: tmp, executable: fake.path)
  var seen: [String] = []
  p.onLine = { seen.append("line " + $0); #expect(Thread.isMainThread) }
  p.onError = { seen.append("error " + $0) }
  for _ in 0..<100 where seen.count < 6 { try await Task.sleep(for: .milliseconds(20)) }
  // lines in order whatever the chunks; a chunk's errors come after its lines
  #expect(seen.filter { $0.hasPrefix("line ") } == [
    #"line ["append-lines","log","This is XeTeX"]"#,
    #"line ["append-lines","out","! Undefined control sequence.","\nl.3 \\foo"]"#,
    "line Error: main.tex:3: Undefined control sequence",
    #"line ["truncate-lines","log",1]"#,
  ])
  #expect(seen.filter { $0.hasPrefix("error ") } == [#"error ! Undefined control sequence. l.3 \foo"#, "error main.tex:3: Undefined control sequence"])
  #expect(seen.firstIndex(of: #"error ! Undefined control sequence. l.3 \foo"#)! > 1)
}

/// The pane passes the real driver's lines on: TeX's log, with an undefined reference's warning in it.
@MainActor @Test func paneOnDriverLineGetsTheLog() async throws {
  let fm = FileManager.default
  guard fm.isExecutableFile(atPath: TxpPaths.headless), fm.isExecutableFile(atPath: TxpPaths.xetex) else { return }
  let dir = fm.temporaryDirectory.appendingPathComponent("txs-driverline-\(UUID().uuidString.prefix(6))")
  try fm.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? fm.removeItem(at: dir) }
  try "\\documentclass{article}\n\\begin{document}\nSee~\\ref{nowhere}.\n\\end{document}\n"
    .write(to: dir.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
  let pdf = TaudotPDFPane(cacheRoot: dir.appendingPathComponent("cache"))
  var lines: [String] = []
  pdf.onDriverLine = { lines.append($0) }
  pdf.open(folder: dir, main: "main.tex", engineSocket: nil)
  defer { pdf.close() }
  func logText() -> String {
    lines.compactMap { l -> String? in
      guard let a = try? JSONSerialization.jsonObject(with: Data(l.utf8)) as? [Any], a.count >= 3,
        a[0] as? String == "append-lines", a[1] as? String == "log" else { return nil }
      return a.dropFirst(2).compactMap { $0 as? String }.joined()
    }.joined()
  }
  for _ in 0..<300 where !logText().contains("nowhere") { try await Task.sleep(for: .milliseconds(20)) }
  #expect(logText().contains("LaTeX Warning: Reference `nowhere' on page 1 undefined on input line 3."))
}

/// Times, Helvetica & co. under XeTeX: the driver's in-memory tu<fam>.fd files give TeX Gyre (Overleaf's pdfTeX
/// metrics) instead of Latin Modern, with no font warning; a document's own .fd of that name wins.
@MainActor @Test func postscriptFontsGetTeXGyre() async throws {
  let fm = FileManager.default
  guard fm.isExecutableFile(atPath: TxpPaths.headless), fm.isExecutableFile(atPath: TxpPaths.xetex) else { return }
  func typeset(_ own: String?) async throws -> (fonts: [String], log: String) {
    let dir = fm.temporaryDirectory.appendingPathComponent("txs-gyre-\(UUID().uuidString.prefix(6))")
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }
    try "\\documentclass{article}\n\\usepackage{times}\n\\usepackage[scaled=.9]{helvet}\n\\begin{document}\nRoman \\textsl{slanted} \\textsf{sans}.\n\\end{document}\n"
      .write(to: dir.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
    if let own { try own.write(to: dir.appendingPathComponent("tuptm.fd"), atomically: true, encoding: .utf8) }
    let txp = Txp(main: dir.appendingPathComponent("main.tex"))
    var done = false, log = ""
    txp.onPages = { if $0.done && $0.n > 0 { done = true } }
    txp.onLine = { l in
      guard let a = try? JSONSerialization.jsonObject(with: Data(l.utf8)) as? [Any], a.count >= 3,
        a[0] as? String == "append-lines", a[1] as? String == "log" else { return }
      log += a.dropFirst(2).compactMap { $0 as? String }.joined()
    }
    txp.start()
    defer { txp.stop() }
    for _ in 0..<300 where !done { try await Task.sleep(for: .milliseconds(20)) }
    var g: PageGlyphs?
    for _ in 0..<30 where g == nil {
      g = await txp.glyphs(page: 0)
      if g == nil { try await Task.sleep(for: .milliseconds(100)) }
    }
    return (g?.fonts ?? [], log)
  }
  let ours = try await typeset(nil)
  #expect(ours.fonts.contains("TeX Gyre Termes Regular") && ours.fonts.contains("TeX Gyre Heros Regular"), "\(ours.fonts)")
  #expect(!ours.log.contains("Font shape `TU/ptm"), "\(ours.log)")
  #expect(!ours.fonts.contains { $0.hasPrefix("Latin Modern Roman") })
  // the document's own tuptm.fd (here: Latin Modern) is the one TeX reads
  let own = try await typeset("\\DeclareFontFamily{TU}{ptm}{}\n\\DeclareFontShape{TU}{ptm}{m}{n}{<->ssub * lmr/m/n}{}\n\\DeclareFontShape{TU}{ptm}{m}{sl}{<->ssub * lmr/m/sl}{}\n")
  #expect(!own.fonts.contains("TeX Gyre Termes Regular") && own.fonts.contains { $0.hasPrefix("Latin Modern Roman") }, "\(own.fonts)")
}

/// BibTeX's .blg as issues: warnings with their keys, errors with the .bib line, the stub's own locations dropped.
@Test func bibLogParses() {
  let blg = """
    This is BibTeX, Version 0.99d
    Capacity: max_strings=35307, hash_size=35307, hash_prime=30011
    The top-level auxiliary file: txs-bib.aux
    The style file: plain.bst
    I couldn't open database file nosuchfile.bib
    ---line 10 of file txs-bib.aux
     : \\bibdata{refs,nosuchfile
     :                         }
    I'm skipping whatever remains of this command
    Database file #1: refs.bib
    Repeated entry---line 4 of file refs.bib
     : @article{dup
     :             , author={C. Author}, title={Two}, journal={J}, year={2022}}
    I'm skipping whatever remains of this entry
    I was expecting a `,' or a `}'---line 5 of file refs.bib
     : @article{broken, author={D. Author} 
     :                                     title={Broken}, journal={J}, year={2023}}
    I'm skipping whatever remains of this entry
    Warning--I didn't find a database entry for "missing"
    Warning--empty journal in nojournal
    Warning--empty title in broken
    Warning--empty journal in broken
    Warning--empty year in broken
    Warning--can't use both author and editor fields in twoed
    (There were 3 error messages)
    """
  let issues = BibTeXIssue.parse(blg)
  #expect(issues == [
    BibTeXIssue(severity: .error, message: "I couldn't open database file nosuchfile.bib"),
    BibTeXIssue(severity: .error, message: "Repeated entry", file: "refs.bib", line: 4),
    BibTeXIssue(severity: .error, message: "I was expecting a `,' or a `}'", file: "refs.bib", line: 5),
    BibTeXIssue(severity: .warning, message: #"I didn't find a database entry for "missing""#, key: "missing"),
    BibTeXIssue(severity: .warning, message: "empty journal in nojournal", key: "nojournal"),
    BibTeXIssue(severity: .warning, message: "empty title in broken", key: "broken"),
    BibTeXIssue(severity: .warning, message: "empty journal in broken", key: "broken"),
    BibTeXIssue(severity: .warning, message: "empty year in broken", key: "broken"),
    BibTeXIssue(severity: .warning, message: "can't use both author and editor fields in twoed", key: "twoed"),
  ])
  // a warning with its location on the next line
  #expect(BibTeXIssue.parse("Warning--I'm ignoring dup's extra \"title\" field\n--line 7 of file refs.bib\n")
    == [BibTeXIssue(severity: .warning, message: #"I'm ignoring dup's extra "title" field"#, file: "refs.bib", line: 7)])
  #expect(BibTeXIssue.blg(fromDriverLine: #"["bib-log", "Warning--x\n"]"#) == "Warning--x\n")
  #expect(BibTeXIssue.blg(fromDriverLine: #"["append-lines", "log", "x"]"#) == nil)
}

/// The pane lists BibTeX's warnings after its run, and again at the next open from the cached run (no BibTeX).
@MainActor @Test func bibIssuesFromTheRunAndTheCache() async throws {
  let fm = FileManager.default
  guard fm.isExecutableFile(atPath: TxpPaths.headless), fm.isExecutableFile(atPath: TxpPaths.xetex) else { return }
  let dir = fm.temporaryDirectory.appendingPathComponent("txs-blg-\(UUID().uuidString.prefix(6))")
  try fm.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? fm.removeItem(at: dir) }
  try "@article{good, author={A. Author}, title={Good}, journal={J}, year={2020}}\n@article{nojournal, author={B. Author}, title={No journal}, year={2021}}\n"
    .write(to: dir.appendingPathComponent("refs.bib"), atomically: true, encoding: .utf8)
  try "\\documentclass{article}\n\\begin{document}\nSee \\cite{good,nojournal,missing}.\n\\bibliographystyle{plain}\n\\bibliography{refs}\n\\end{document}\n"
    .write(to: dir.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
  func open() async throws -> [BibTeXIssue] {
    let pdf = TaudotPDFPane(cacheRoot: dir.appendingPathComponent("cache"))
    var got: [BibTeXIssue]?
    pdf.onBibIssues = { got = $0 }
    pdf.open(folder: dir, main: "main.tex", engineSocket: nil)
    defer { pdf.close() }
    for _ in 0..<500 where got == nil { try await Task.sleep(for: .milliseconds(20)) }
    try await Task.sleep(for: .milliseconds(300))
    return got ?? []
  }
  let first = try await open()
  #expect(first.map(\.key) == ["missing", "nojournal"], "\(first)")
  #expect(first.allSatisfy { $0.severity == .warning })
  let again = try await open()  // the .bbl and .blg from the cache
  #expect(again == first)
}

/// The margin tick stays a few screen points wide and ~14 tall when the PDF is fitted to a narrow pane, and again
/// after the zoom changes (it was sized for a stale zoom: a fat pill ~7x too big).
@MainActor @Test func forwardTickKeepsScreenSize() throws {
  let line = CGRect(x: 108, y: 500, width: 396, height: 9), word = CGRect(x: 150, y: 500, width: 40, height: 10)
  // shown while the pane is a sliver (the zoom at its 0.1 floor), then the pane opens to ~480 pt
  let view = PDFPaneView(frame: NSRect(x: 0, y: 0, width: 50, height: 700))
  view.setSizes([CGSize(width: 612, height: 792), CGSize(width: 612, height: 792)])
  view.reveal(page: 0, rects: [word], lines: [line])
  view.setFrameSize(NSSize(width: 480, height: 700))
  view.setSizes([CGSize(width: 612, height: 792), CGSize(width: 612, height: 792)])
  let m = view.magnification
  let o = view.pages[0].origin
  let want = LineMark.tick(line, magnification: m).offsetBy(dx: o.x, dy: o.y)
  let got = view.forward.layer.sublayers?.map(\.frame).first { abs($0.maxX - want.maxX) < 40 && $0.width < 60 && $0.minX < o.x + line.minX }
  #expect(got.map { abs($0.height - want.height) < 0.5 && abs($0.width - want.width) < 0.5 } == true, "tick \(String(describing: got)), want \(want) at zoom \(m)")
  #expect(want.height * m < 30)
}

/// A pinned note's reply field wraps and grows with its text (the card grows downward, its top staying put); ⇧↩ and
/// ⌥↩ add a line, ↩ sends.
@MainActor @Test func noteReplyFieldGrows() throws {
  let saved = UserDefaults.standard.object(forKey: NotesOverlay.shownKey)
  defer { UserDefaults.standard.set(saved, forKey: NotesOverlay.shownKey) }
  UserDefaults.standard.removeObject(forKey: NotesOverlay.shownKey)
  let view = PDFPaneView(frame: NSRect(x: 0, y: 0, width: 700, height: 600))
  let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: true)
  window.isReleasedWhenClosed = false
  window.contentView = view
  defer { window.close() }
  view.setSizes([CGSize(width: 612, height: 792)])
  let line = CGRect(x: 72, y: 200, width: 400, height: 9)
  view.notes.set([PlacedNote(id: "a", page: 0, line: line, side: .right, slot: 0)],
    comments: [PDFComment(id: "a", path: "main.tex", line: 1, author: "Ana")])
  let pa = try #require(view.notePoint("a"))
  #expect(view.clickPages(at: pa))
  let card = try #require(view.notes.pinnedCard)
  card.layoutSubtreeIfNeeded()
  let f0 = card.frame, h0 = card.field.frame.height
  // one line: centred in the box, padded from its left edge
  #expect(card.field.textContainerInset.height > 2 && card.field.textContainerInset.width >= 3)
  #expect(window.makeFirstResponder(card.field))
  card.field.insertText(String(repeating: "a longer reply that has to wrap ", count: 6), replacementRange: card.field.selectedRange())
  card.layoutSubtreeIfNeeded()
  let f1 = card.frame
  #expect(card.field.frame.height > h0 + 10, "field \(h0) → \(card.field.frame.height)")
  #expect(f1.height > f0.height + 10 && abs(f1.maxY - f0.maxY) < 1.5, "card \(f0) → \(f1)")  // grew downward (y up)
  // the field stays inside the card, full width, with Resolve below it (not beside it)
  let box = card.field.convert(card.field.bounds, to: card)
  #expect(card.bounds.insetBy(dx: -0.5, dy: -0.5).contains(box), "field \(box) in card \(card.bounds)")
  let resolve = try #require(card.resolveButton)
  let rb = resolve.convert(resolve.bounds, to: card)
  #expect(rb.maxY < box.minY, "Resolve \(rb) under the field \(box)")
  #expect(box.width > card.bounds.width - 40)
  // ↩ sends and clears; the card shrinks back
  var sent: [String] = []
  card.onSend = { sent.append($0) }
  card.send()
  #expect(sent.count == 1 && card.field.string.isEmpty && abs(card.frame.height - f0.height) < 1.5)
}

