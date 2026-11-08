// History (TaudotHistory, docs/agents/history.md): decoding the engine's results, the list's rows, picking the file,
// the diff's colours, and the controller driving both views from a fake source. All off screen.
//
// Screenshots: TAUDOT_HISTORY_SHOTS=<dir> writes history-<light|dark>.png of the sidebar pane beside the diff, from the
// fake (or, with TAUDOT_HISTORY_SOCKET and TAUDOT_HISTORY_FOLDER, from a running engine and a project folder).
import AppKit
import Foundation
import Testing
@testable import TaudotHistory
@testable import TaudotShared
import TaudotReview

private func alice() -> [String: Any] { ["user_id": "a", "name": "Alice", "initials": "A", "hue": 237, "mine": true] }
private func bob() -> [String: Any] { ["user_id": "b", "name": "Bob Smith", "initials": "BS", "hue": 135, "mine": false] }

// ---- decoding ---------------------------------------------------------------------------------------------------------

@Test func decodesUpdatesPage() {
  let page = UpdatesPage([
    "updates": [
      ["from_v": 8, "to_v": 10, "start_ts": 1_793_980_986_804.0, "end_ts": 1_793_980_995_340.0, "users": [alice()],
       "labels": [], "paths": [],
       "ops": [["op": "remove", "path": "u.tex", "at_v": 9], ["op": "rename", "path": "refs.bib", "new_path": "biblio.bib", "at_v": 8]]],
      ["from_v": 5, "to_v": 8, "start_ts": 1.0, "end_ts": 2.0, "users": [bob(), alice()],
       "labels": [["id": "l", "comment": "first draft", "version": 8, "user_id": "b", "name": "Bob", "created_at": "2026-11-06T18:52:57.223Z", "mine": false]],
       "paths": ["main.tex", "sections/intro.tex"], "ops": [], "origin": ["kind": "upload"]],
    ],
    "next_before": 5, "head": 10,
  ])
  #expect(page.head == 10 && page.nextBefore == 5)
  #expect(page.groups.count == 2)
  let g = page.groups[0]
  #expect(g.fromV == 8 && g.toV == 10 && g.users.first?.mine == true)
  #expect(g.ops[1] == HistoryFileOp(kind: .rename, path: "refs.bib", newPath: "biblio.bib", atV: 8))
  #expect(g.summary == "1 file renamed, 1 file deleted")
  let g2 = page.groups[1]
  #expect(g2.summary == "main.tex and 1 more")
  #expect(g2.labels.first?.comment == "first draft")
  #expect(g2.labels.first?.created != nil)
  #expect(g2.originText == "Uploaded")
  #expect(abs(g.end.timeIntervalSince1970 - 1_793_980_995.34) < 0.001)
}

@Test func summariesOfOneFileOp() {
  let at = Date()
  func g(_ ops: [HistoryFileOp]) -> VersionGroup { VersionGroup(fromV: 0, toV: 1, start: at, end: at, users: [], ops: ops) }
  #expect(g([HistoryFileOp(kind: .add, path: "a.tex", atV: 0)]).summary == "Added a.tex")
  #expect(g([HistoryFileOp(kind: .rename, path: "a", newPath: "b", atV: 0)]).summary == "Renamed a → b")
  #expect(g([]).summary == "No changes")
}

@Test func diffOffsetsAreConvertedFromUTF8Bytes() {
  // "é" is 2 bytes and 1 UTF-16 unit; "𝔸" 4 bytes and 2 units.
  let text = "é𝔸ab\nold\n"
  let d = HistoryDiff([
    "path": "m.tex", "from": 1, "to": 2, "binary": false, "text": text,
    "chunks": [
      ["kind": "insert", "start": 0, "end": 6, "user": bob(), "ts": 5000.0],
      ["kind": "same", "start": 6, "end": 9],
      ["kind": "delete", "start": 9, "end": 13, "user": alice(), "ts": 6000.0],
    ],
    "inserted": 6, "deleted": 4,
  ])
  let ns = text as NSString
  #expect(d.chunks.count == 3)
  #expect(ns.substring(with: d.chunks[0].range) == "é𝔸")
  #expect(ns.substring(with: d.chunks[1].range) == "ab\n")
  #expect(ns.substring(with: d.chunks[2].range) == "old\n")
  #expect(d.chunks[0].user?.name == "Bob Smith")
  #expect(d.chunks[2].time == Date(timeIntervalSince1970: 6))
  #expect(d.changes.count == 2)
}

@Test func treeFilesAndAutoSelect() {
  let files = [
    HistoryFile(path: "a.png", editable: false),
    HistoryFile(path: "main.tex"),
    HistoryFile(path: "refs.bib", op: .edited),
    HistoryFile(path: "old.tex", op: .removed, deletedAtV: 3),
    HistoryFile(path: "s/intro.tex", op: .edited),
    HistoryFile(path: "r.bib", op: .renamed, newPath: "q.bib"),
  ]
  #expect(autoSelectFile(files, previous: nil, main: "main.tex")?.path == "s/intro.tex")  // first changed .tex
  #expect(autoSelectFile(files, previous: "q.bib", main: nil)?.finalPath == "q.bib")       // previous, renamed
  #expect(autoSelectFile(files, previous: "main.tex", main: nil)?.path == "s/intro.tex")   // previous unchanged: a changed one
  let none = files.map { var f = $0; f.op = nil; return f }
  #expect(autoSelectFile(none, previous: "refs.bib", main: "main.tex")?.path == "refs.bib")
  #expect(autoSelectFile(none, previous: nil, main: "main.tex")?.path == "main.tex")
  let decoded = HistoryFile(["path": "r.bib", "op": "renamed", "new_path": "q.bib", "deleted_at_v": NSNull(), "editable": true])
  #expect(decoded == HistoryFile(path: "r.bib", op: .renamed, newPath: "q.bib"))
}

@Test func rowsHaveDayHeadingsAndLabelFilter() {
  var cal = Calendar(identifier: .gregorian)
  cal.timeZone = TimeZone(identifier: "UTC")!
  let now = Date(timeIntervalSince1970: 1_793_980_000)  // 2026-11-06
  let h: TimeInterval = 3600
  let label = HistoryLabel(id: "l", comment: "v1", version: 3)
  let gs = [
    VersionGroup(fromV: 5, toV: 6, start: now, end: now, users: []),
    VersionGroup(fromV: 4, toV: 5, start: now - h, end: now - h, users: []),
    VersionGroup(fromV: 2, toV: 3, start: now - 24 * h, end: now - 24 * h, users: [], labels: [label]),
    VersionGroup(fromV: 0, toV: 2, start: now - 400 * h, end: now - 400 * h, users: []),
  ]
  let rows = HistoryRows.build(gs, labelsOnly: false, hasMore: true, now: now, calendar: cal)
  #expect(rows.count == 4 + 3 + 1)
  #expect(rows[0] == .day("Today"))
  #expect(rows[3] == .day("Yesterday"))
  #expect(rows.last == .more)
  let labelled = HistoryRows.build(gs, labelsOnly: true, hasMore: false, now: now, calendar: cal)
  #expect(labelled == [.day("Yesterday"), .group(gs[2])])
}

@Test func compareRangeIsTheUnion() {
  let t = Date()
  let a = VersionGroup(fromV: 5, toV: 8, start: t, end: t, users: [])
  let b = VersionGroup(fromV: 0, toV: 5, start: t, end: t, users: [])
  #expect(HistoryRange.union(a, b) == HistoryRange(fromV: 0, toV: 8))
  #expect(HistoryRange(fromV: 8, toV: 2) == HistoryRange(fromV: 2, toV: 8))
}

// ---- the diff's colours -----------------------------------------------------------------------------------------------

@Test @MainActor func diffIsTintedByAuthor() {
  let d = HistoryDiff(path: "m.tex", fromV: 0, toV: 1, text: "new\nsame\ngone\n", chunks: [
    .init(kind: .insert, range: NSRange(location: 0, length: 4), user: HistoryUser(id: "b", name: "Bob", initials: "B"), time: nil),
    .init(kind: .same, range: NSRange(location: 4, length: 5), user: nil, time: nil),
    .init(kind: .delete, range: NSRange(location: 9, length: 5), user: HistoryUser(id: "a", name: "Alice", initials: "A", mine: true), time: nil),
  ], inserted: 4, deleted: 5)
  let s = HistoryDiffView.attributed(d, font: .monospacedSystemFont(ofSize: 12, weight: .regular), dark: false) { u in
    u.mine ? TaudotColor.coral : .systemBlue
  }
  let ins = s.attributes(at: 1, effectiveRange: nil)
  #expect((ins[.backgroundColor] as? NSColor)?.usingColorSpace(.sRGB)?.blueComponent ?? 0 > 0.5)
  #expect((ins[.toolTip] as? String)?.hasPrefix("Added by Bob") == true)
  #expect(s.attributes(at: 5, effectiveRange: nil)[.backgroundColor] == nil)
  let del = s.attributes(at: 10, effectiveRange: nil)
  #expect(del[.strikethroughStyle] as? Int == NSUnderlineStyle.single.rawValue)
  #expect((del[.strikethroughColor] as? NSColor) == TaudotColor.coral)
  #expect((del[.toolTip] as? String)?.hasPrefix("Deleted by you") == true)
}

@Test @MainActor func marginColoursCoralOnlyForYou() {
  let me = HistoryUser(id: "a", name: "Alice", initials: "A", mine: true)
  let other = HistoryUser(id: "b", name: "Bob", initials: "B")
  #expect(HistoryColors.margin(me) == TaudotColor.coral)
  #expect(HistoryColors.margin(other) != TaudotColor.coral)
  #expect(HistoryColors.margin(other) == HistoryColors.margin(other))
}

// ---- the controller over a fake ---------------------------------------------------------------------------------------

@MainActor final class FakeHistorySource: HistorySource {
  var pages: [Int?: UpdatesPage] = [:]
  var trees: [HistoryRange: [HistoryFile]] = [:]
  var diffs: [String: HistoryDiff] = [:]
  var calls: [String] = []
  func updates(before: Int?) async throws -> UpdatesPage {
    calls.append("updates \(before.map(String.init) ?? "-")")
    return pages[before] ?? UpdatesPage(groups: [], nextBefore: nil, head: nil)
  }
  func labels() async throws -> [HistoryLabel] { [] }
  /// Nanoseconds each tree call takes (a slow engine).
  var treeDelay: UInt64 = 0
  func tree(_ r: HistoryRange) async throws -> [HistoryFile] {
    calls.append("tree \(r.fromV)-\(r.toV)")
    if treeDelay > 0 { try? await Task.sleep(nanoseconds: treeDelay) }
    return trees[r] ?? []
  }
  func diff(path: String, _ r: HistoryRange) async throws -> HistoryDiff {
    calls.append("diff \(path) \(r.fromV)-\(r.toV)")
    guard let d = diffs["\(path) \(r.fromV)-\(r.toV)"] else { throw HistoryError(description: "no diff") }
    return d
  }
  /// "path@version" → text (nil: binary).
  var files: [String: String?] = [:]
  func file(path: String, version: Int) async throws -> String? {
    calls.append("file \(path)@\(version)")
    guard let t = files["\(path)@\(version)"] else { throw HistoryError(description: "no file") }
    return t
  }
}

@MainActor private func historySample() -> FakeHistorySource {
  let f = FakeHistorySource()
  let now = Date()
  let you = HistoryUser(id: "a", name: "Alice Ng", initials: "AN", hue: 200, mine: true)
  let bob = HistoryUser(id: "6ae7eb869c93d6e28d0854b5", name: "Bob Smith", initials: "BS", hue: 135)
  let carol = HistoryUser(id: "c", name: "Carol Diaz", initials: "CD", hue: 31)
  let g1 = VersionGroup(fromV: 12, toV: 15, start: now - 120, end: now - 60, users: [bob, you], paths: ["sections/intro.tex"])
  let g2 = VersionGroup(fromV: 9, toV: 12, start: now - 3000, end: now - 2400, users: [carol],
                        labels: [HistoryLabel(id: "l", comment: "Sent to advisor", version: 12, name: "Carol Diaz")], paths: ["main.tex", "refs.bib"])
  let g3 = VersionGroup(fromV: 8, toV: 9, start: now - 90000, end: now - 90000, users: [you],
                        ops: [HistoryFileOp(kind: .rename, path: "refs.bib", newPath: "biblio.bib", atV: 8)])
  let g4 = VersionGroup(fromV: 0, toV: 8, start: now - 200000, end: now - 190000, users: [you, bob], paths: ["main.tex"], origin: "upload")
  f.pages[nil] = UpdatesPage(groups: [g1, g2, g3, g4], nextBefore: nil, head: 15)
  f.trees[HistoryRange(fromV: 12, toV: 15)] = [
    HistoryFile(path: "main.tex"), HistoryFile(path: "biblio.bib"), HistoryFile(path: "figs/plot.pdf", editable: false),
    HistoryFile(path: "sections/intro.tex", op: .edited), HistoryFile(path: "sections/method.tex"),
  ]
  f.trees[HistoryRange(fromV: 9, toV: 15)] = [
    HistoryFile(path: "main.tex", op: .edited), HistoryFile(path: "biblio.bib", op: .edited),
    HistoryFile(path: "sections/intro.tex", op: .edited), HistoryFile(path: "figs/plot.pdf", editable: false),
  ]
  let text = """
  \\section{Introduction}
  Overleaf keeps every version of a project. We show who changed what and when, \
  coloured by author, without leaving the editor.

  Taudot edits the same project from Neovim or a native editor, so collaborators in the browser see each change live.
  Earlier drafts called this a plugin.
  The history view reads Overleaf's own history service.

  \\subsection{Why}
  Reviewing a coauthor's pass is easier when the changes stand out.

  """
  func chunks(_ parts: [(HistoryDiff.Kind, String, HistoryUser?)]) -> (String, [HistoryDiff.Chunk]) {
    var s = "", out: [HistoryDiff.Chunk] = []
    for (k, t, u) in parts {
      let at = (s as NSString).length
      s += t
      out.append(.init(kind: k, range: NSRange(location: at, length: (t as NSString).length), user: u, time: now - 100))
    }
    return (s, out)
  }
  let lines = text.components(separatedBy: "Earlier drafts called this a plugin.\n")
  let (t, c) = chunks([
    (.same, String(lines[0].prefix(upTo: lines[0].range(of: "We show")!.lowerBound)), nil),
    (.insert, "We show who changed what and when, coloured by author, without leaving the editor.", bob),
    (.same, "\n\nTaudot edits the same project from Neovim or a native editor, so collaborators in the browser see each change live.\n", nil),
    (.delete, "Earlier drafts called this a plugin.\n", you),
    (.same, "The history view reads Overleaf's own history service.\n\n\\subsection{Why}\nReviewing a coauthor's pass is easier when the changes stand out.\n", nil),
    (.insert, "Labels mark the versions worth coming back to.\n", you),
  ])
  f.diffs["sections/intro.tex 12-15"] = HistoryDiff(path: "sections/intro.tex", fromV: 12, toV: 15, text: t, chunks: c, inserted: 131, deleted: 37)
  f.diffs["sections/intro.tex 9-15"] = HistoryDiff(path: "sections/intro.tex", fromV: 9, toV: 15, text: t, chunks: c, inserted: 131, deleted: 37)
  return f
}

@MainActor private func historySettle(_ until: () -> Bool) async {
  for _ in 0..<200 where !until() { try? await Task.sleep(nanoseconds: 5_000_000) }
}

@Test @MainActor func controllerPicksNewestThenFileThenDiff() async {
  let f = historySample()
  let c = HistoryController(source: f, mainFile: "main.tex")
  c.activate()
  await historySettle { c.diffView.diff != nil }
  #expect(f.calls == ["updates -", "tree 12-15", "diff sections/intro.tex 12-15"])
  #expect(c.range == HistoryRange(fromV: 12, toV: 15))
  #expect(c.pane.rows.first == .day("Today"))
  #expect(c.pane.files.first?.path == "sections/intro.tex")  // changed files first
  #expect(c.pane.selectedFile == "sections/intro.tex")
  #expect(c.diffView.title.stringValue == "sections/intro.tex")
  #expect(c.diffView.subtitle.stringValue.contains("Bob Smith and you"))

  // ⇧-click an older group: compare across both.
  c.select(c.groups[1], extend: true)
  await historySettle { c.diffView.diff?.fromV == 9 }
  #expect(c.range == HistoryRange(fromV: 9, toV: 15))
  #expect(f.calls.suffix(2) == ["tree 9-15", "diff sections/intro.tex 9-15"])  // same file kept
  #expect(c.diffView.subtitle.stringValue.hasPrefix("Changes from"))

  // A binary file: a message, no diff call.
  let n = f.calls.count
  c.pick(HistoryFile(path: "figs/plot.pdf", editable: false))
  await historySettle { c.diffView.diff == nil }
  #expect(f.calls.count == n)
  #expect(!c.diffView.placeholder.isHidden)

  // Labels only.
  c.pane.onFilter?(true)
  #expect(c.pane.rows.count == 2)
}

@Test @MainActor func nextChangeWalksTheChanges() async {
  let f = historySample()
  let c = HistoryController(source: f)
  let w = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 700, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
  c.diffView.frame = NSRect(x: 0, y: 0, width: 700, height: 300)
  w.contentView = c.diffView
  c.activate()
  await historySettle { c.diffView.diff != nil }
  let changes = c.diffView.diff!.changes
  c.diffView.next()
  #expect(c.diffView.current != nil)
  let first = c.diffView.current!
  c.diffView.next()
  #expect(c.diffView.current == (first + 1) % changes.count)
  #expect(c.diffView.textView.selectedRange() == changes[c.diffView.current!].range)
  c.diffView.prev()
  #expect(c.diffView.current == first)
}

@Test @MainActor func mergeKeepsOneGroupPerSpan() {
  let c = HistoryController(source: FakeHistorySource())
  let t = Date()
  c.merge([VersionGroup(fromV: 5, toV: 8, start: t, end: t, users: []), VersionGroup(fromV: 0, toV: 5, start: t, end: t, users: [])], newest: true)
  // The newest group grew while History was away.
  c.merge([VersionGroup(fromV: 5, toV: 11, start: t, end: t, users: [])], newest: true)
  #expect(c.groups.map(\.toV) == [11, 5])
}

// ---- screenshots ------------------------------------------------------------------------------------------------------

@Test @MainActor func historyScreenshots() async throws {
  let env = ProcessInfo.processInfo.environment
  guard let dir = env["TAUDOT_HISTORY_SHOTS"] else { return }
  try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
  for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
    let source: HistorySource
    if let sock = env["TAUDOT_HISTORY_SOCKET"], let folder = env["TAUDOT_HISTORY_FOLDER"] {
      source = EngineHistorySource(socket: URL(fileURLWithPath: sock), folder: URL(fileURLWithPath: folder))
    } else {
      source = historySample()
    }
    let c = HistoryController(source: source, mainFile: "main.tex")
    let size = NSSize(width: 1100, height: 680)
    let root = HistoryShotView(frame: NSRect(origin: .zero, size: size))
    root.wantsLayer = true
    root.appearance = NSAppearance(named: appearance)
    let side: CGFloat = 290
    c.pane.frame = NSRect(x: 0, y: 0, width: side, height: size.height)
    c.pane.topInset = 12
    c.diffView.frame = NSRect(x: side + 1, y: 0, width: size.width - side - 1, height: size.height)
    let line = NSBox(frame: NSRect(x: side, y: 0, width: 1, height: size.height))
    line.boxType = .separator
    root.addSubview(c.pane)
    root.addSubview(line)
    root.addSubview(c.diffView)
    let w = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
    w.appearance = NSAppearance(named: appearance)
    w.backgroundColor = appearance == .darkAqua ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.96, alpha: 1)
    w.contentView = root
    c.pane.material.state = .active
    c.activate()
    await historySettle { c.diffView.diff != nil && !(c.diffView.textView.string.isEmpty) }
    if env["TAUDOT_HISTORY_COMPARE"] != nil, c.groups.count > 1 {
      c.select(c.groups[1], extend: true)
      await historySettle { c.diffView.diff?.fromV == c.range?.fromV }
    }
    try await Task.sleep(nanoseconds: 300_000_000)
    root.layoutSubtreeIfNeeded()
    root.display()
    let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
    root.cacheDisplay(in: root.bounds, to: rep)
    let png = try #require(rep.representation(using: .png, properties: [:]))
    try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("history-\(name).png"))
  }
}

final class HistoryShotView: NSView {
  override var isFlipped: Bool { true }
  override func draw(_ r: NSRect) {
    (effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.95, alpha: 1)).setFill()
    r.fill()
  }
}

// ---- the sidebar's third tab ------------------------------------------------------------------------------------------

@Test @MainActor func sidebarGetsAHistoryTab() async throws {
  let s = SidebarView(frame: NSRect(x: 0, y: 0, width: 280, height: 600))
  s.reduceMotion = { true }
  let c = HistoryController(source: FakeHistorySource())
  var seen: [SidebarView.Tab] = []
  s.onTabChange = { seen.append($0) }
  s.history = c.pane
  s.layoutSubtreeIfNeeded()
  s.tab = .history
  #expect(seen.last == .history)
  #expect(!c.pane.isHidden && s.files.isHidden && s.margin.isHidden && s.overview.isHidden)
  #expect(c.pane.frame == s.bounds)
  s.tab = .files
  #expect(c.pane.isHidden && !s.files.isHidden)
  // The header's three tabs fit the narrowest sidebar.
  let tabs = try #require(s.subviews.flatMap(\.subviews).compactMap { $0 as? NSSegmentedControl }.first { $0.segmentCount == 3 })
  #expect(tabs.frame.minX >= 0 && tabs.frame.maxX <= s.bounds.width)
  if let dir = ProcessInfo.processInfo.environment["TAUDOT_HISTORY_SHOTS"] {
    s.tab = .history
    let w = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 280, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
    w.contentView = s
    s.layoutSubtreeIfNeeded()
    let rep = try #require(s.bitmapImageRepForCachingDisplay(in: NSRect(x: 0, y: 0, width: 280, height: 40)))
    s.cacheDisplay(in: NSRect(x: 0, y: 0, width: 280, height: 40), to: rep)
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dir).appendingPathComponent("sidebar-tabs.png"))
  }
}

/// The header's tabs keep clear of the filter button at every sidebar width (the narrowest is 180), and only drop
/// their words when they must. TAUDOT_HISTORY_SHOTS: header-<light|dark>.png, the header at 180, 220, 280 and 360.
@Test @MainActor func sidebarHeaderKeepsRoomBesideTheFilter() async throws {
  let widths: [CGFloat] = [180, 200, 220, 250, 280, 320, 360, 480]
  var words: [CGFloat: Bool] = [:]
  for w in widths {
    let s = SidebarView(frame: NSRect(x: 0, y: 0, width: w, height: 300))
    s.reduceMotion = { true }
    s.history = HistoryController(source: FakeHistorySource()).pane
    for t in [SidebarView.Tab.comments, .history, .files] {
      s.tab = t
      s.layoutSubtreeIfNeeded()
      #expect(s.tabsFrame.minX >= SidebarView.tabEdge, "width \(w) \(t): \(s.tabsFrame)")
      #expect(s.tabsFrame.maxX <= s.filterFrame.minX - SidebarView.tabGap, "width \(w) \(t): tabs \(s.tabsFrame) filter \(s.filterFrame)")
      #expect(s.tabsFrame.maxX <= s.inlineFrame.minX - SidebarView.tabGap && s.inlineFrame.maxX <= s.filterFrame.minX, "width \(w) \(t): tabs \(s.tabsFrame) eye \(s.inlineFrame)")
    }
    words[w] = s.tabsShowWords
  }
  #expect(words[480] == true && words[180] == false)
  guard let dir = ProcessInfo.processInfo.environment["TAUDOT_HISTORY_SHOTS"] else { return }
  for dark in [false, true] {
    let shown: [CGFloat] = [180, 220, 280, 360]
    let root = HistoryShotView(frame: NSRect(x: 0, y: 0, width: 380, height: CGFloat(shown.count) * 52 + 8))
    root.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    for (i, w) in shown.enumerated() {
      let s = SidebarView(frame: NSRect(x: 10, y: 8 + CGFloat(i) * 52, width: w, height: 44))
      s.reduceMotion = { true }
      s.history = HistoryController(source: FakeHistorySource()).pane
      s.tab = .comments
      root.addSubview(s)
    }
    let win = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: root.frame.width, height: root.frame.height), styleMask: [.borderless], backing: .buffered, defer: false)
    win.appearance = root.appearance
    win.contentView = root
    root.layoutSubtreeIfNeeded()
    let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
    root.cacheDisplay(in: root.bounds, to: rep)
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dir).appendingPathComponent("header-\(dark ? "dark" : "light").png"))
  }
}

/// ⇧↓ / ⇧↑ grow and shrink the range from where it started (Finder's list); a plain arrow moves on from its moving end.
@Test @MainActor func shiftArrowsGrowAndShrinkTheRange() async throws {
  let f = historySample()
  let c = HistoryController(source: f, mainFile: "main.tex")
  c.activate()
  await historySettle { c.range != nil }
  #expect(c.range == HistoryRange(fromV: 12, toV: 15))
  func press(_ code: UInt16, shift: Bool) throws {
    let e = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? [.shift, .function] : [.function],
                                          timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                          isARepeat: false, keyCode: code))
    #expect(c.pane.key(e))
  }
  try press(125, shift: true)
  #expect(c.range == HistoryRange(fromV: 9, toV: 15))
  try press(125, shift: true)
  #expect(c.range == HistoryRange(fromV: 8, toV: 15))
  try press(125, shift: true)
  #expect(c.range == HistoryRange(fromV: 0, toV: 15))
  try press(126, shift: true)
  #expect(c.range == HistoryRange(fromV: 8, toV: 15))
  try press(125, shift: false)  // on from the moving end (8–9), alone
  #expect(c.range == HistoryRange(fromV: 0, toV: 8))
  try press(126, shift: true)
  #expect(c.range == HistoryRange(fromV: 0, toV: 9))
}

/// The diff's cursor: it shows and moves (nothing can be typed); on a change, the change is current (the PDF goes to
/// its mark); ]c/[c and Vim's motions in Neovim mode; next/previous go on to the next file's changes at the ends; a
/// double-click (forward search) gives the place in the version's text, deleted text skipped.
@Test @MainActor func diffCursorKeysAndForwardSearch() async throws {
  let f = historySample()
  let d = try #require(f.diffs["sections/intro.tex 9-15"])
  let ns = d.text as NSString
  // biblio.bib changed too in 9–15 (first in the files list): one insertion
  f.diffs["biblio.bib 9-15"] = HistoryDiff(path: "biblio.bib", fromV: 9, toV: 15, text: "\\input{intro}\nNew.\n",
                                         chunks: [.init(kind: .same, range: NSRange(location: 0, length: 14), user: nil, time: nil),
                                                  .init(kind: .insert, range: NSRange(location: 14, length: 5), user: nil, time: nil)],
                                         inserted: 5, deleted: 0)
  let c = HistoryController(source: f, mainFile: "sections/intro.tex")
  let w = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 700, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
  c.diffView.frame = NSRect(x: 0, y: 0, width: 700, height: 300)
  w.contentView = c.diffView
  c.activate()
  await historySettle { c.diffView.diff != nil }
  c.select(c.groups[1], extend: true)  // 9–15: biblio.bib, main.tex, intro.tex changed
  await historySettle { c.diffView.diff?.fromV == 9 }
  let v = c.diffView, tv = v.textView
  var reported: [Int?] = []
  v.onCurrent = { _, i in reported.append(i) }
  w.makeFirstResponder(tv)
  func key(_ s: String, _ mods: NSEvent.ModifierFlags = []) throws {
    let e = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: w.windowNumber,
                                          context: nil, characters: s, charactersIgnoringModifiers: s, isARepeat: false, keyCode: 0))
    tv.keyDown(with: e)
  }
  // nothing can be typed
  tv.setSelectedRange(NSRange(location: 0, length: 0))
  try key("x")
  #expect(tv.string == d.text)
  // the cursor onto a change: it's current
  let ch = d.changes
  tv.setSelectedRange(NSRange(location: ch[1].range.location + 2, length: 0))
  #expect(v.current == 1 && reported.last == 1)
  // ]c / [c
  try key("]"); try key("c")
  #expect(v.current == 2 && tv.selectedRange() == ch[2].range)
  try key("["); try key("c")
  #expect(v.current == 1)
  #expect(tv.string == d.text)
  // Vim's motions only in Neovim mode
  tv.setSelectedRange(NSRange(location: 0, length: 0))
  try key("j")
  #expect(tv.selectedRange().location == 0)
  v.vimKeys = true
  try key("j")
  #expect(tv.selectedRange().location > 0 && tv.string == d.text)
  try key("G", [.shift])
  #expect(tv.selectedRange().location == ns.length)
  try key("g"); try key("g")
  #expect(tv.selectedRange().location == 0)
  // past the last change (of the last file): the first file's first; back before it: intro.tex's last
  v.select(ch.count - 1)
  v.next()
  await historySettle { v.diff?.path == "biblio.bib" && v.current == 0 }
  #expect(v.diff?.path == "biblio.bib" && v.current == 0 && c.pane.selectedFile == "biblio.bib")
  v.prev()
  await historySettle { v.diff?.path == "sections/intro.tex" && v.current != nil }
  #expect(v.diff?.path == "sections/intro.tex" && v.current == ch.count - 1)
  // forward search: the place in the version's text (no deleted text before it)
  var fwd: (String, Int, Int)?
  v.onForward = { fwd = ($0, $1, $2) }
  let del = try #require(d.chunks.first { $0.kind == .delete })
  let after = NSMaxRange(del.range) + 4  // "The " of the line after the deleted one
  tv.setSelectedRange(NSRange(location: after, length: 0))
  v.forwardSearch()
  let version = d.version().text.components(separatedBy: "\n")
  let f0 = try #require(fwd)
  #expect(f0.0 == "sections/intro.tex" && version[f0.1 - 1].hasPrefix("The history view") && f0.2 == 4, "\(f0)")
  // in a deletion: its place (the start of the line it was)
  tv.setSelectedRange(NSRange(location: del.range.location + 5, length: 0))
  v.forwardSearch()
  #expect(fwd.map { $0.1 == f0.1 && $0.2 == 0 } == true, "\(String(describing: fwd))")
}

/// The version list's selection: one capsule on the version picked (the moving end of a range), and a paler one over
/// the whole range; the ⇧ hint while one version is selected, gone for good (kept in the defaults) once a range is made.
@Test @MainActor func selectionCapsulesAndTheRangeHint() async throws {
  #expect(HistoryPane.hintShown(selection: HistoryRange(fromV: 12, toV: 15), isRange: false, rangeMade: false))
  #expect(!HistoryPane.hintShown(selection: HistoryRange(fromV: 9, toV: 15), isRange: true, rangeMade: false))
  #expect(!HistoryPane.hintShown(selection: HistoryRange(fromV: 12, toV: 15), isRange: false, rangeMade: true))
  #expect(!HistoryPane.hintShown(selection: nil, isRange: false, rangeMade: false))

  let suite = "taudot-history-test-\(UUID().uuidString.prefix(6))"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let f = historySample()
  let c = HistoryController(source: f, mainFile: "main.tex")
  c.pane.defaults = defaults
  let w = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 290, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
  c.pane.frame = NSRect(x: 0, y: 0, width: 290, height: 700)
  w.contentView = c.pane
  c.activate()
  await historySettle { c.range != nil }
  c.pane.layoutSubtreeIfNeeded()
  let rowOf = { (g: VersionGroup) in c.pane.rows.firstIndex { if case .group(let x) = $0 { x.fromV == g.fromV } else { false } }! }
  func rowRect(_ g: VersionGroup) -> CGRect { c.pane.versions.rect(ofRow: rowOf(g)) }
  // one version: its capsule, no range capsule, the hint
  var h = c.pane.highlightFrames
  #expect(h.focus.map { $0.midY == rowRect(c.groups[0]).midY && $0.width < rowRect(c.groups[0]).width } == true, "\(h)")
  #expect(h.range == nil)
  #expect(c.pane.hintShown && c.pane.hint.frame.minY >= c.pane.versionsScroll.frame.maxY)
  // ⇧-picked down to the third: the focus on the third, the range over the three, the hint gone, remembered
  c.select(c.groups[2], extend: true)
  h = c.pane.highlightFrames
  #expect(h.focus.map { $0.midY == rowRect(c.groups[2]).midY } == true, "\(h)")
  #expect(h.range.map { $0.minY <= rowRect(c.groups[0]).minY + 1 && $0.maxY >= rowRect(c.groups[2]).maxY - 1 } == true, "\(h)")
  #expect(!c.pane.hintShown && defaults.bool(forKey: HistoryPane.rangeMadeKey))
  // shrunk back with ⇧↑: the range follows
  let up = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.shift, .function], timestamp: 0, windowNumber: 0,
                                         context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: true, keyCode: 126))
  #expect(c.pane.key(up))
  h = c.pane.highlightFrames
  #expect(h.focus.map { $0.midY == rowRect(c.groups[1]).midY } == true && h.range.map { $0.maxY < rowRect(c.groups[2]).minY + 1 } == true, "\(h)")
  // one version again: no hint (a range was made once), nor in a new pane with the same defaults
  c.select(c.groups[0], extend: false)
  #expect(!c.pane.hintShown && c.pane.highlightFrames.range == nil)
  let p2 = HistoryPane(frame: NSRect(x: 0, y: 0, width: 290, height: 600))
  p2.defaults = defaults
  p2.rows = c.pane.rows
  p2.selection = HistoryRange.of(c.groups[0])
  #expect(!p2.hintShown)
  // rows say how to compare
  let cell = c.pane.versions.view(atColumn: 0, row: rowOf(c.groups[0]), makeIfNecessary: true)
  #expect(cell?.toolTip?.contains("⇧-click") == true)

  // shots: the hint (one version) and a range, light and dark
  if let dir = ProcessInfo.processInfo.environment["TAUDOT_HISTORY_SHOTS"] {
    for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
      for range in [false, true] {
        let fresh = try #require(UserDefaults(suiteName: suite + "-shot"))
        fresh.removePersistentDomain(forName: suite + "-shot")
        let c2 = HistoryController(source: historySample(), mainFile: "main.tex")
        c2.pane.defaults = fresh
        let root = HistoryShotView(frame: NSRect(x: 0, y: 0, width: 290, height: 640))
        root.wantsLayer = true
        root.appearance = NSAppearance(named: appearance)
        c2.pane.frame = root.bounds
        c2.pane.topInset = 12
        root.addSubview(c2.pane)
        let w2 = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 290, height: 640), styleMask: [.borderless], backing: .buffered, defer: false)
        w2.appearance = NSAppearance(named: appearance)
        w2.contentView = root
        c2.pane.material.state = .active
        c2.activate()
        await historySettle { c2.range != nil }
        if range { c2.select(c2.groups[2], extend: true) }
        try await Task.sleep(for: .milliseconds(500))
        root.layoutSubtreeIfNeeded()
        root.display()
        let rep = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!
          .write(to: URL(fileURLWithPath: dir).appendingPathComponent("history-\(range ? "range" : "hint")-\(name).png"))
        fresh.removePersistentDomain(forName: suite + "-shot")
      }
    }
  }
}

// statefix A5: a file pick or a PDF mark click while a version's tree is loading must not cancel the tree load.
@Test @MainActor func pickDuringTreeLoadKeepsTheTree() async {
  let f = historySample()
  f.trees[HistoryRange(fromV: 9, toV: 12)] = [HistoryFile(path: "main.tex", op: .edited), HistoryFile(path: "biblio.bib", op: .edited)]
  f.diffs["main.tex 9-12"] = HistoryDiff(path: "main.tex", fromV: 9, toV: 12, text: "x", chunks: [], inserted: 1, deleted: 0)
  let c = HistoryController(source: f, mainFile: "main.tex")
  var ranges: [HistoryRange] = []
  c.onRange = { r, _, _ in ranges.append(r) }
  c.activate()
  await historySettle { c.diffView.diff != nil }
  f.treeDelay = 100_000_000
  c.select(c.groups[1], extend: false)  // 9-12, tree in flight
  try? await Task.sleep(nanoseconds: 10_000_000)
  c.pick(c.files[0])  // a row of the old list
  c.showChange(path: "sections/intro.tex", index: 0)  // a mark of the old range
  await historySettle { ranges.last == HistoryRange(fromV: 9, toV: 12) && c.diffView.diff?.fromV == 9 }
  #expect(ranges.last == HistoryRange(fromV: 9, toV: 12))
  #expect(c.files.map(\.path) == ["biblio.bib", "main.tex"])
  #expect(c.pane.files.map(\.path) == ["biblio.bib", "main.tex"])
  #expect(c.diffView.diff?.path == "main.tex" && c.diffView.diff?.fromV == 9)
}

// statefix A20: the newest group grows (edits arrive) after it was picked; a ⇧-pick then compares up to its new end.
@Test @MainActor func compareFromAGroupThatGrew() async {
  let f = historySample()
  let c = HistoryController(source: f, mainFile: "main.tex")
  c.activate()
  await historySettle { c.diffView.diff != nil }
  #expect(c.range == HistoryRange(fromV: 12, toV: 15))
  let g1 = c.groups[0]
  c.merge([VersionGroup(fromV: 12, toV: 18, start: g1.start, end: Date(), users: g1.users, paths: g1.paths)], newest: true)
  #expect(c.range == HistoryRange(fromV: 12, toV: 18))  // the selection followed
  c.select(c.groups[1], extend: true)
  #expect(c.range == HistoryRange(fromV: 9, toV: 18))
  #expect(c.anchor?.toV == 18)
}
