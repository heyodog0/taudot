// History on the PDF (TaudotHistory/HistoryPDF.swift, TaudotPDF/VersionPDF.swift): a version's text and where its
// changes are, the version's folder, and end to end (off screen) a version typeset by the live pdfTeX with its changes
// marked, a mark clicked, the diff's current change outlined, and the saved PDF reopened at once.
// Screenshots: TAUDOT_HISTORY_SHOTS=<dir> writes history-pdf-<light|dark>.png (the diff beside the version's PDF).
import AppKit
import Foundation
import Testing
@testable import TaudotHistory
@testable import TaudotPDF

private let bob = HistoryUser(id: "6ae7eb869c93d6e28d0854b5", name: "Bob Smith", initials: "BS", hue: 135)
private let you = HistoryUser(id: "a", name: "Alice Ng", initials: "AN", hue: 200, mine: true)

private func diff(_ parts: [(HistoryDiff.Kind, String, HistoryUser?)], path: String = "main.tex", at: Date = Date() - 300) -> HistoryDiff {
  var s = "", out: [HistoryDiff.Chunk] = []
  for (k, t, u) in parts {
    let i = (s as NSString).length
    s += t
    out.append(.init(kind: k, range: NSRange(location: i, length: (t as NSString).length), user: u, time: at))
  }
  let n = { (k: HistoryDiff.Kind) in parts.filter { $0.0 == k }.reduce(0) { $0 + $1.1.utf8.count } }
  return HistoryDiff(path: path, fromV: 12, toV: 15, text: s, chunks: out, inserted: n(.insert), deleted: n(.delete))
}

@Test func versionTextAndChangePlaces() {
  let d = diff([
    (.same, "ab\ncé ", nil), (.insert, " new words\n", bob), (.same, "x", nil), (.delete, "gone", you), (.same, "y\n", nil),
    (.insert, " \n", bob), (.same, "z", nil),
  ])
  let v = d.version()
  #expect(v.text == "ab\ncé  new words\nxy\n \nz")
  #expect(v.changes.count == 2)  // the whitespace-only insertion has nothing to mark
  let ins = v.changes[0], del = v.changes[1]
  // "cé " is 4 bytes; the insertion's leading space is left out of its place
  #expect(ins.index == 0 && ins.kind == .insert && ins.line == 2 && ins.column == 5 && ins.endLine == 2 && ins.endColumn == 14)
  #expect(del.index == 1 && del.kind == .delete && del.line == 3 && del.column == 1 && del.endColumn == 1 && del.text == "gone")
  #expect(del.user == you)
}

@Test func versionFolderPlan() throws {
  let project = FileManager.default.temporaryDirectory.appendingPathComponent("vplan-\(UUID().uuidString.prefix(6))")
  try FileManager.default.createDirectory(at: project.appendingPathComponent("figs"), withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: project) }
  for p in ["main.tex", "intro.tex", "figs/a.png", "now.tex"] { try Data("x".utf8).write(to: project.appendingPathComponent(p)) }
  let files = [
    HistoryFile(path: "main.tex", op: .edited), HistoryFile(path: "intro.tex"), HistoryFile(path: "figs/a.png", editable: false),
    HistoryFile(path: "old.tex", op: .removed, deletedAtV: 14), HistoryFile(path: "gone.tex"), HistoryFile(path: "was.tex"),
  ]
  let plan = VersionFolder.plan(files: files, since: ["main.tex", "figs/a.png", "was.tex"], renamedSince: ["was.tex": "now.tex"], project: project)
  let by = Dictionary(plan.map { ($0.path, $0.source) }, uniquingKeysWith: { a, _ in a })
  #expect(by["main.tex"] == .history)  // changed since: history's text
  #expect(by["intro.tex"] == .copy("intro.tex"))  // unchanged since: the project's copy
  #expect(by["figs/a.png"] == .blob(today: "figs/a.png"))  // binary changed since: its blob at the version
  #expect(by["gone.tex"] == .history)  // not in the folder: history's text
  #expect(by["was.tex"] == .history)
  #expect(by["old.tex"] == nil)  // removed in the range: not at the version
}

/// The paper at version 15: three changes (Bob's sentence, your deletion, your new line) between filler paragraphs.
private func versionDiff() -> HistoryDiff {
  let filler = (1...3).map { "Paragraph \($0) is here to fill the page with ordinary words so the changes sit in running text." }
    .joined(separator: "\n\n")
  return diff([
    (.same, "\\documentclass{article}\n\\begin{document}\n\\section{Introduction}\n" + filler + "\n\nOverleaf keeps every version of a project. ", nil),
    (.insert, "We show who changed what and when, coloured by author, without leaving the editor.", bob),
    (.same, "\n\nTaudot edits the same project from Neovim or a native editor, so collaborators in the browser see each change live. ", nil),
    (.delete, "Earlier drafts called this a plugin. ", you),
    (.same, "The history view reads Overleaf's own history service.\n\n\\subsection{Why}\nReviewing a coauthor's pass is easier when the changes stand out.\n", nil),
    (.insert, "Labels mark the versions worth coming back to.\n", you),
    (.same, "\n" + filler + "\n\\end{document}\n", nil),
  ])
}

@MainActor private func waitFor(_ seconds: Double = 60, _ cond: () -> Bool) async throws {
  let end = Date().addingTimeInterval(seconds)
  while !cond() && Date() < end { try await Task.sleep(for: .milliseconds(20)) }
}

@MainActor @Test func versionPDFMarksChanges() async throws {
  guard LiveTexPaths.missing("2026") == nil else { return }
  let fm = FileManager.default
  let tmp = fm.temporaryDirectory.appendingPathComponent("vpdf-\(UUID().uuidString.prefix(6))")
  let project = tmp.appendingPathComponent("project")
  try fm.createDirectory(at: project, withIntermediateDirectories: true)
  defer { try? fm.removeItem(at: tmp) }
  VersionFolder.base = testVersionCache
  let d = versionDiff()
  let vtext = d.version().text
  // today the paper has moved on (version 16), and there's a binary file that hasn't changed
  try "\\documentclass{article}\\begin{document}Today.\\end{document}\n".write(to: project.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
  try Data([0, 1, 2, 3]).write(to: project.appendingPathComponent("data.bin"))
  let f = FakeHistorySource()
  let r = HistoryRange(fromV: 12, toV: 15)
  let files = [HistoryFile(path: "main.tex", op: .edited), HistoryFile(path: "data.bin", editable: false)]
  f.trees[r] = files
  f.trees[HistoryRange(fromV: 15, toV: 16)] = [HistoryFile(path: "main.tex", op: .edited), HistoryFile(path: "data.bin", editable: false)]
  f.diffs["main.tex 12-15"] = d
  f.files["main.tex@15"] = vtext

  let p = HistoryPDFController(source: f, project: project, mainFile: "main.tex", cacheRoot: project.appendingPathExtension("cache"))
  let win = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 640, height: 860), styleMask: [.borderless], backing: .buffered, defer: false)
  win.contentView = p.view
  var picked: [(String, Int)] = []
  p.onPickChange = { picked.append(($0, $1)) }
  p.show(r, files: files, head: 16)
  try await waitFor { p.pdf.changesPlaced }
  defer { p.close() }

  // the version's folder: history's text for what changed since, the project's copy of the rest
  let folder = VersionFolder.folder(project, version: 15)
  #expect(try String(contentsOf: folder.appendingPathComponent("main.tex"), encoding: .utf8) == vtext)
  #expect(fm.contentsEqual(atPath: folder.appendingPathComponent("data.bin").path, andPath: project.appendingPathComponent("data.bin").path))
  #expect(f.calls.contains("tree 15-16") && f.calls.contains("file main.tex@15"))

  // three changes, all on page 1: the insertions boxed line by line, the deletion a place in its line
  let placed = p.pdf.placedChanges
  #expect(Set(placed.map(\.id)) == ["main.tex#0", "main.tex#1", "main.tex#2"])
  let byID = Dictionary(placed.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
  let bobs = try #require(byID["main.tex#0"]), del = try #require(byID["main.tex#1"]), mine = try #require(byID["main.tex#2"])
  #expect(bobs.page == 0 && !bobs.rects.isEmpty && bobs.rects.allSatisfy { $0.width > 20 && $0.height > 4 && $0.height < 20 })
  #expect(bobs.rects.count >= 2)  // Bob's sentence runs over two typeset lines
  #expect(del.rects.count == 1 && del.rects[0].width == 0 && del.rects[0].height > 4)
  #expect(!mine.rects.isEmpty && mine.rects[0].minY > del.rects[0].maxY)
  // the box holds the inserted words: the page's text under it
  #expect(p.view.status.contains("3 changes"), "\(p.view.status)")

  // a mark clicked: the change goes to the diff view
  let at = p.pdf.pane.pagePoint(0, CGPoint(x: bobs.rects[0].midX, y: bobs.rects[0].midY))
  #expect(p.pdf.pane.clickPages(at: at))
  #expect(picked.last.map { $0.0 == "main.tex" && $0.1 == 0 } == true)
  // hovered for ~1 s, moving over the change's two lines (mouse-moved events, as the window sends them): the card
  // shows once, after a short delay, and stays; it's small (never a tall sliver) and never takes the mouse
  let ov = p.pdf.pane.changes
  let (shows, hides) = (ov.cardShows, ov.cardHides)
  let pv = p.pdf.pane.pagesView
  func move(_ r: CGRect, _ dx: CGFloat) throws {
    let pt = pv.convert(p.pdf.pane.pagePoint(0, CGPoint(x: r.minX + dx, y: r.midY)), to: nil)
    let e = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: pt, modifierFlags: [], timestamp: 0, windowNumber: win.windowNumber,
                                            context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
    pv.mouseMoved(with: e)
  }
  try move(bobs.rects[0], 5)
  #expect(ov.popoverShown == nil)  // not at once
  for i in 0..<20 {
    try move(bobs.rects[i % 2], CGFloat(5 + i * 4))
    try await Task.sleep(for: .milliseconds(50))
  }
  #expect(ov.popoverShown == "main.tex#0" && ov.cardShows == shows + 1 && ov.cardHides == hides, "shows \(ov.cardShows - shows), hides \(ov.cardHides - hides)")
  let card = try #require(ov.popoverSize)
  #expect(card.width >= ChangeCard.minWidth && card.width <= ChangeCard.maxWidth + 40 && card.height > 30 && card.height < 220, "card \(card)")
  let cf = try #require(ov.cardFrame)
  let hitAt = p.pdf.pane.convert(CGPoint(x: cf.midX, y: cf.midY), to: nil)
  #expect(!(win.contentView?.hitTest(win.contentView!.convert(hitAt, from: nil)).map { $0 is HoverCardView } ?? false))
  // the pointer leaves: gone after a moment
  #expect(!ov.hover(nil) && ov.popoverShown == "main.tex#0")
  try await Task.sleep(for: .milliseconds(450))
  #expect(ov.popoverShown == nil && ov.cardHides == hides + 1)
  // the diff's current change: outlined on the page
  p.select(path: "main.tex", index: 2)
  #expect(p.pdf.pane.changes.selected == "main.tex#2")
  // the bar's arrows step the diff (which moves the PDF)
  var steps: [Int] = []
  p.onStep = { steps.append($0) }
  p.view.nextButton.performClick(nil)
  p.view.prevButton.performClick(nil)
  #expect(steps == [1, -1])
  // a forward search from the diff: the version's PDF comes back if the current one was shown, the place is marked
  p.setShowingCurrent(true)
  let line = vtext.components(separatedBy: "\n").firstIndex { $0.contains("We show who") }! + 1
  p.forward(path: "main.tex", line: line, column: 50)
  try await waitFor(5) { p.pdf.pane.markShown }
  #expect(!p.showingCurrent && p.pdf.pane.markShown && p.pdf.markFor?.line == line)

  // kept: shown again, the saved PDF opens without typesetting
  try await waitFor { p.pdf.versionSaved }
  #expect(p.pdf.versionSaved)
  p.close()
  let t0 = Date()
  p.show(r, files: files, head: 16)
  try await waitFor(10) { p.pdf.changesPlaced }
  #expect(p.pdf.engine == nil && p.pdf.changesPlaced)
  #expect(Date().timeIntervalSince(t0) < 3, "reopened in \(Date().timeIntervalSince(t0)) s")
  #expect(p.pdf.placedChanges.count == 3)

  if let dir = ProcessInfo.processInfo.environment["TAUDOT_HISTORY_SHOTS"] {
    try await historyPDFShots(dir, p, d)
  }
}

@MainActor private func historyPDFShots(_ dir: String, _ p: HistoryPDFController, _ d: HistoryDiff) async throws {
  for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
    let size = NSSize(width: 1240, height: 820)
    let root = HistoryShotView(frame: NSRect(origin: .zero, size: size))
    root.wantsLayer = true
    root.appearance = NSAppearance(named: appearance)
    let dv = HistoryDiffView(frame: NSRect(x: 0, y: 0, width: 560, height: size.height))
    dv.show(d, subtitle: "Changes from 1 Nov, 2:10 PM to Today 3:42 PM by Bob Smith and you")
    p.view.removeFromSuperview()
    p.view.frame = NSRect(x: 561, y: 0, width: size.width - 561, height: size.height)
    let line = NSBox(frame: NSRect(x: 560, y: 0, width: 1, height: size.height))
    line.boxType = .separator
    root.addSubview(dv)
    root.addSubview(line)
    root.addSubview(p.view)
    let w = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
    w.appearance = NSAppearance(named: appearance)
    w.contentView = root
    p.pdf.pageStyle = appearance == .darkAqua ? .dark : .white
    root.layoutSubtreeIfNeeded()
    dv.select(0)
    p.select(path: d.path, index: 0)
    try await waitFor(10) { p.pdf.pane.settled }
    // Bob's change hovered: its card
    if let b = p.pdf.placedChanges.first(where: { $0.id == "main.tex#0" }), let r = b.rects.last {
      _ = p.pdf.pane.changes.hover(p.pdf.pane.pagePoint(b.page, CGPoint(x: r.minX + 20, y: r.midY)))
    }
    try await Task.sleep(for: .milliseconds(600))
    p.pdf.raiseChangeMarks()  // cacheDisplay draws sublayers in order, not by zPosition as the screen does
    root.display()
    let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
    root.cacheDisplay(in: root.bounds, to: rep)
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dir).appendingPathComponent("history-pdf-\(name).png"))
  }
}

@Test func changePieces() {
  let src = ["\\documentclass{article}", "", "% a comment", "Some text here.", "  ", "More text.", "\\end{document}"]
  let line = { (l: Int) in l >= 1 && l <= src.count ? src[l - 1] : nil }
  func ch(_ k: PDFChange.Kind, _ l: Int, _ c: Int, _ el: Int, _ ec: Int) -> PDFChange {
    PDFChange(id: "x", kind: k, path: "main.tex", line: l, column: c, endLine: el, endColumn: ec, text: "", author: "", color: .gray, time: nil)
  }
  // an insertion over many lines: each line with something typeset, its own columns
  let p = TaudotPDFPane.pieces(ch(.insert, 1, 9, 6, 4)) { line($0) }
  #expect(p.map(\.line) == [1, 4, 6])
  #expect(p[0].from == 9 && p[0].to == 23 && p[1].from == 0 && p[1].to == 15 && p[2].to == 4)
  // a deletion on a blank line: its place, then the next lines with text
  let d = TaudotPDFPane.pieces(ch(.delete, 2, 0, 2, 0)) { line($0) }
  #expect(d.map(\.line) == [2, 4, 6, 7])
}

/// A real-size paper (10 pages, two files): an insertion of the whole file that starts in the preamble (an upload),
/// one that starts on a blank line, and a paragraph deleted between two others are all marked.
@MainActor @Test func versionPDFMarksARealSizePaper() async throws {
  guard LiveTexPaths.missing("2026") == nil else { return }
  let fm = FileManager.default
  let tmp = fm.temporaryDirectory.appendingPathComponent("vpdf-big-\(UUID().uuidString.prefix(6))")
  let project = tmp.appendingPathComponent("project")
  try fm.createDirectory(at: project.appendingPathComponent("sections"), withIntermediateDirectories: true)
  defer { try? fm.removeItem(at: tmp) }
  VersionFolder.base = testVersionCache
  func para(_ i: Int) -> String {
    (0..<5).map { "Sentence \($0 + 1) of paragraph \(i) says something about the method in plain running words." }.joined(separator: "\n")
  }
  let mainText = "\\documentclass[twocolumn]{article}\n\\usepackage{amsmath}\n% notes for the authors\n\\title{A Paper}\n\\begin{document}\n\\maketitle\n"
    + (1...6).map { "\\section{Part \($0)}\n" + (1...8).map { para($0) }.joined(separator: "\n\n") }.joined(separator: "\n\n")
    + "\n\n\\input{sections/more}\n\\end{document}\n"
  let moreOld = (1...10).map { para(100 + $0) }.joined(separator: "\n\n") + "\n"
  // in sections/more.tex: a new paragraph (its insertion starts on the blank line before it), and paragraph 104 deleted
  let paras = (1...10).map { para(100 + $0) }
  let added = "\n\nAn added paragraph that a coauthor wrote, with enough words to wrap over a couple of typeset lines in a column."
  var moreParts: [(HistoryDiff.Kind, String, HistoryUser?)] = []
  moreParts.append((.same, paras[0...1].joined(separator: "\n\n"), nil))
  moreParts.append((.insert, added, bob))
  moreParts.append((.same, "\n\n" + paras[2] + "\n\n", nil))
  moreParts.append((.delete, paras[3] + "\n\n", you))
  moreParts.append((.same, paras[4...].joined(separator: "\n\n") + "\n", nil))
  let moreDiff = diff(moreParts, path: "sections/more.tex")
  let mainDiff = diff([(.same, "", nil), (.insert, mainText, you)], path: "main.tex")
  #expect(moreDiff.version().text != moreOld)
  try mainText.write(to: project.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
  try moreDiff.version().text.write(to: project.appendingPathComponent("sections/more.tex"), atomically: true, encoding: .utf8)
  let f = FakeHistorySource()
  let r = HistoryRange(fromV: 12, toV: 15)
  let files = [HistoryFile(path: "main.tex", op: .edited), HistoryFile(path: "sections/more.tex", op: .edited)]
  f.trees[r] = files
  f.diffs["main.tex 12-15"] = mainDiff
  f.diffs["sections/more.tex 12-15"] = moreDiff
  let p = HistoryPDFController(source: f, project: project, mainFile: "main.tex", cacheRoot: project.appendingPathExtension("cache"))
  let win = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 640, height: 860), styleMask: [.borderless], backing: .buffered, defer: false)
  win.contentView = p.view
  p.show(r, files: files, head: 15)  // nothing changed since: every file copied
  // settled: placed, and still placed a moment later (a rerun of pdfTeX places them again)
  for _ in 0..<3 {
    try await waitFor(120) { p.pdf.changesPlaced && p.changes.count == 3 }
    try await Task.sleep(for: .milliseconds(800))
  }
  defer { p.close() }
  #expect(p.pdf.pane.pageCount >= 6, "\(p.pdf.pane.pageCount) pages")
  let placed = p.pdf.placedChanges
  // the upload: boxed on every page but the last (where only the other file's text is)
  let upload = placed.filter { $0.id == "main.tex#0" }
  #expect(Set(upload.map(\.page)).count >= p.pdf.pane.pageCount - 2, "upload on pages \(upload.map(\.page))")
  #expect(upload.reduce(0) { $0 + $1.rects.count } > 100)
  #expect(placed.contains { $0.id == "sections/more.tex#0" && !$0.rects.isEmpty })  // starts on a blank line
  #expect(placed.contains { $0.id == "sections/more.tex#1" && $0.rects.count == 1 })  // a deleted paragraph
  #expect(p.view.status.contains("3 changes") && !p.view.status.contains("not on"), "\(p.view.status)")
}

/// One versions cache for every test in this process (tests run in parallel: one test's cleanup mustn't remove
/// another's version folders). Project folders differ, so their versions do too.
private let testVersionCache = FileManager.default.temporaryDirectory.appendingPathComponent("taudot-history-tests-\(getpid())")

/// A bullet added at the end of a list in a two-column paper: the insertion runs from the previous item's end through
/// the new `\item` to the `\end{itemize}` it ends on. That last line has nothing typeset of its own, and SyncTeX gives
/// it the new bullet's lines, which are boxed all the same; the other column's lines stay boxes of their own.
@MainActor @Test func versionPDFMarksAnInsertedBullet() async throws {
  guard LiveTexPaths.missing("2026") == nil else { return }
  let fm = FileManager.default
  let tmp = fm.temporaryDirectory.appendingPathComponent("vpdf-item-\(UUID().uuidString.prefix(6))")
  let project = tmp.appendingPathComponent("project")
  try fm.createDirectory(at: project, withIntermediateDirectories: true)
  defer { try? fm.removeItem(at: tmp) }
  VersionFolder.base = testVersionCache
  let words = (1...40).map { "Filler sentence \($0) of the left column, in plain words." }.joined(separator: "\n")
  let head = "\\documentclass[twocolumn]{article}\n\\begin{document}\n" + words + "\n\n\\begin{itemize}\n"
    + "\\item The first bullet, which says something about the method.\n\\item The second bullet ends here"
  let added = ", with a few words more.\n\\item Added bullet: a third point, on how the method compares with the usual baseline.\n\\end{itemize}"
  let tail = "\n\nA paragraph after the list.\n\\end{document}\n"
  let d = diff([(.same, head, nil), (.insert, added, bob), (.same, tail, nil)])
  let text = d.version().text
  try text.write(to: project.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
  let lines = text.components(separatedBy: "\n")
  let bullet = try #require(lines.firstIndex { $0.hasPrefix("\\item Added bullet") }) + 1
  #expect(lines[bullet] == "\\end{itemize}")
  let f = FakeHistorySource()
  let r = HistoryRange(fromV: 12, toV: 15)
  let files = [HistoryFile(path: "main.tex", op: .edited)]
  f.trees[r] = files
  f.diffs["main.tex 12-15"] = d
  let p = HistoryPDFController(source: f, project: project, mainFile: "main.tex", cacheRoot: project.appendingPathExtension("cache"))
  let win = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 640, height: 860), styleMask: [.borderless], backing: .buffered, defer: false)
  win.contentView = p.view
  p.show(r, files: files, head: 15)
  try await waitFor(120) { p.pdf.changesPlaced && p.changes.count == 1 }
  defer { p.close() }
  let st = try #require(p.pdf.synctex)
  let rows = try #require(st.rows(file: "main.tex", line: bullet)).rows.filter { $0.rect.height < 20 }
  #expect(rows.count >= 2, "the bullet's typeset lines \(rows)")
  let placed = p.pdf.placedChanges.filter { $0.id == "main.tex#0" }
  for row in rows {
    #expect(placed.contains { $0.page == row.page && $0.rects.contains { abs($0.midY - row.rect.midY) < 3 && $0.intersects(row.rect) } },
            "the bullet's line at \(row.rect) unmarked: \(placed)")
  }
  // no box spans both columns
  let half = (p.pdf.pane.pageSizes.first?.width ?? 612) / 2
  #expect(placed.allSatisfy { $0.rects.allSatisfy { $0.width < half } }, "\(placed)")
}
