// The sidebar (Files | Comments): docs/agents/margin-sidebar.md.
import AppKit
import Testing
@testable import TaudotReview
@testable import TaudotShared

// ---- the tree's rules (pure) ----------------------------------------------------------------------------------------

@Test func filterHidesTaudotGitBuildAndIgnored() {
  let f = FileFilter(gitignore: "# build output\nbuild/\n*.tmp\n!keep.tmp\n/notes.txt\nfigs/raw/\n")
  for (p, dir) in [(".taudot", true), (".taudot-state.json", false), (".git", true), (".DS_Store", false),
                   ("main.aux", false), ("main.log", false), ("main.synctex.gz", false), ("main.fdb_latexmk", false),
                   ("main.xdv", false), ("main.bbl", false), ("main.pdf", false), ("build", true), ("x.tmp", false),
                   ("notes.txt", false), ("figs/raw", true), ("sub/.DS_Store", false)] {
    #expect(f.hides(p, isDirectory: dir), "\(p) hidden")
  }
  for (p, dir) in [("main.tex", false), ("refs.bib", false), ("figs", true), ("figs/plot.pdf", false), ("keep.tmp", false),
                   ("sub/notes.txt", false), ("build.tex", false), ("figs/raw.png", false), (".latexmkrc", false)] {
    #expect(!f.hides(p, isDirectory: dir), "\(p) shown")
  }
}

@Test func treeOrderIsFoldersFirstThenNatural() {
  let names: [(String, Bool)] = [("fig10.png", false), ("b.tex", false), ("sections", true), ("Fig2.png", false), ("appendix", true), ("A.tex", false)]
  let sorted = names.sorted { fileOrder(($0.0, $0.1), ($1.0, $1.1)) }.map(\.0)
  #expect(sorted == ["appendix", "sections", "A.tex", "b.tex", "Fig2.png", "fig10.png"])
  #expect(FileNode(url: URL(fileURLWithPath: "/x/a.bib"), rel: "a.bib", isDirectory: false, parent: nil).symbol == "books.vertical")
  #expect(FileNode(url: URL(fileURLWithPath: "/x/a.PNG"), rel: "a.PNG", isDirectory: false, parent: nil).kind == .image)
}

// ---- on a temp folder -----------------------------------------------------------------------------------------------

private func project() -> URL {
  let d = FileManager.default.temporaryDirectory.appendingPathComponent("taudot-sidebar-\(UUID().uuidString)")
  let fm = FileManager.default
  try! fm.createDirectory(at: d.appendingPathComponent("figs"), withIntermediateDirectories: true)
  try! fm.createDirectory(at: d.appendingPathComponent("sections"), withIntermediateDirectories: true)
  try! fm.createDirectory(at: d.appendingPathComponent(".git"), withIntermediateDirectories: true)
  for f in ["main.tex", "main.aux", "main.pdf", "refs.bib", "figs/plot.pdf", "figs/photo.png", "sections/intro.tex", ".gitignore"] {
    try! (f == ".gitignore" ? "*.bak\n" : "x").write(to: d.appendingPathComponent(f), atomically: true, encoding: .utf8)
  }
  try! "x".write(to: d.appendingPathComponent("old.bak"), atomically: true, encoding: .utf8)
  return d
}

@MainActor private func filesView(_ d: URL) -> FilesView {
  let v = FilesView(frame: NSRect(x: 0, y: 0, width: 260, height: 500))
  v.folder = d
  return v
}

@MainActor @Test func filesShowTheProjectFiltered() {
  let d = project()
  defer { try? FileManager.default.removeItem(at: d) }
  UserDefaults.standard.removeObject(forKey: FilesView.collapsedKey(d))
  let v = filesView(d)
  // The root's files first, then a section per folder with its files.
  #expect(v.shownRows == [".gitignore", "main.tex", "refs.bib", "figs/", "  photo.png", "  plot.pdf", "sections/", "  intro.tex"])
  #expect(v.rows.first == .project(d.lastPathComponent))
  // Collapsing a section is remembered for the project.
  v.collapse("figs")
  #expect(v.shownRows == [".gitignore", "main.tex", "refs.bib", "figs/ (collapsed)", "sections/", "  intro.tex"])
  let again = filesView(d)
  #expect(again.shownRows.contains("figs/ (collapsed)") && !again.shownRows.contains("  plot.pdf"))
  // ← on a file goes up to its section, ← there closes it, → opens it again.
  v.select("sections/intro.tex")
  v.collapseSelected()
  #expect(v.selectedNodes.map(\.rel) == ["sections"])
  v.collapseSelected()
  #expect(v.shownRows.last == "sections/ (collapsed)")
  v.expandSelected()
  #expect(v.shownRows.last == "  intro.tex")
  // Return or a click on a section toggles it.
  v.select("figs")
  v.openSelected()
  #expect(v.shownRows.contains("  photo.png"))
  UserDefaults.standard.removeObject(forKey: FilesView.collapsedKey(d))
}

@MainActor @Test func theFileOpenInNeovimIsSelected() {
  let d = project()
  defer { try? FileManager.default.removeItem(at: d) }
  UserDefaults.standard.removeObject(forKey: FilesView.collapsedKey(d))
  let v = filesView(d)
  v.collapse("sections")
  v.current = d.appendingPathComponent("sections/intro.tex")
  #expect(v.selectedNodes.map(\.rel) == ["sections/intro.tex"])  // its section opened to show it
  v.current = d.appendingPathComponent("main.tex")
  #expect(v.selectedNodes.map(\.rel) == ["main.tex"])
  UserDefaults.standard.removeObject(forKey: FilesView.collapsedKey(d))
}

@MainActor private final class RecordingNvim: NeovimBridge {
  var calls: [[Value]] = []
  var answer: Value = .map([(.string("ok"), .bool(true))])
  func notify(_ name: String, _ handler: @escaping @MainActor ([Value]) -> Void) {}
  func execLua(_ code: String, _ args: [Value]) async throws -> Value {
    calls.append(args)
    return answer
  }
  func command(_ cmd: String) async throws {}
}

@MainActor @Test func openingAFileGoesToNeovimImagesToQuickLook() async {
  let d = project()
  defer { try? FileManager.default.removeItem(at: d) }
  let s = SidebarView(frame: NSRect(x: 0, y: 0, width: 280, height: 600))
  s.folder = d
  let nv = RecordingNvim()
  let c = ReviewController(nvim: nv, sidebar: s)
  var results: [(ReviewAction, String?)] = []
  c.onResult = { results.append(($0, $1)) }
  var previewed: [URL] = []
  s.files.onPreview = { previewed.append($0) }
  s.files.open(s.files.tree!.node(rel: "main.tex")!)
  for _ in 0..<50 where results.isEmpty { try? await Task.sleep(for: .milliseconds(20)) }
  let path = d.appendingPathComponent("main.tex").standardizedFileURL.path
  #expect(nv.calls.last.map { $0[0] == .string("open") && $0[2]["path"] == .string(path) } == true)
  #expect(results.first?.0 == .open(path) && results.first?.1 == nil)
  s.files.open(s.files.tree!.node(rel: "figs/photo.png")!)
  #expect(previewed.map(\.lastPathComponent) == ["photo.png"] && nv.calls.count == 1)
  // Neovim's buffer comes back in the payload: the tree follows it.
  c.receive({ var st = ReviewState(buf: 3); st.file = d.appendingPathComponent("refs.bib").path; return st }())
  #expect(s.files.selectedNodes.map(\.rel) == ["refs.bib"])
}

@MainActor @Test func renameNewAndTrashOnDisk() {
  let d = project()
  defer { try? FileManager.default.removeItem(at: d) }
  let fm = FileManager.default
  let v = filesView(d)
  var errors: [String] = []
  v.onError = { errors.append($0) }
  let t = v.tree!
  #expect(v.rename(t.node(rel: "refs.bib")!, to: "library.bib"))
  #expect(fm.fileExists(atPath: d.appendingPathComponent("library.bib").path) && !fm.fileExists(atPath: d.appendingPathComponent("refs.bib").path))
  #expect(v.shownRows.contains("library.bib"))
  // A taken name or a slash: refused, nothing moves.
  #expect(!v.rename(t.node(rel: "library.bib")!, to: "main.tex") && errors.count == 1)
  #expect(!v.rename(t.node(rel: "library.bib")!, to: "a/b.bib"))
  #expect(fm.fileExists(atPath: d.appendingPathComponent("library.bib").path))
  // A folder renamed keeps its section's state.
  v.collapse("sections")
  #expect(v.rename(t.node(rel: "sections")!, to: "chapters"))
  #expect(v.shownRows.contains("chapters/ (collapsed)"))
  // New File: a free name in the selected section's folder (opened), then renamed inline.
  v.select("chapters")
  let n = v.create(directory: false)
  #expect(n?.rel == "chapters/untitled.tex" && fm.fileExists(atPath: d.appendingPathComponent("chapters/untitled.tex").path))
  #expect(v.create(directory: false)?.rel == "chapters/untitled 2.tex")
  #expect(v.shownRows.contains("  untitled.tex"))
  v.select(nil)
  #expect(v.create(directory: true)?.rel == "untitled folder")
  #expect(v.shownRows.contains("untitled folder/"))
  // Delete: asked first; No keeps it, Yes moves it to the Trash.
  var answer = false
  var asked: [String] = []
  v.confirm = { q, done in asked.append(q); done(answer) }
  v.select("main.tex")
  v.deleteSelected(nil)
  #expect(asked == ["Move “main.tex” to the Trash?"] && fm.fileExists(atPath: d.appendingPathComponent("main.tex").path))
  answer = true
  v.deleteSelected(nil)
  #expect(!fm.fileExists(atPath: d.appendingPathComponent("main.tex").path) && !v.shownRows.contains("main.tex"))
  UserDefaults.standard.removeObject(forKey: FilesView.collapsedKey(d))
}

@MainActor @Test func filesAddedOnDiskAppear() async {
  let d = project()
  defer { try? FileManager.default.removeItem(at: d) }
  let v = filesView(d)
  var changes = 0
  v.onDiskChange = { changes += 1 }
  try? "x".write(to: d.appendingPathComponent("from-overleaf.tex"), atomically: true, encoding: .utf8)
  for _ in 0..<150 where !v.shownRows.contains("from-overleaf.tex") { try? await Task.sleep(for: .milliseconds(20)) }
  #expect(v.shownRows.contains("from-overleaf.tex") && changes > 0)
}

// ---- tabs and the floating card -------------------------------------------------------------------------------------

@MainActor @Test func floatingCardFollowsTheTab() {
  let d = project()
  defer { try? FileManager.default.removeItem(at: d) }
  let host = FlippedView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
  let ed = FlippedView(frame: NSRect(x: 300, y: 0, width: 700, height: 600))
  let s = SidebarView(frame: NSRect(x: 0, y: 0, width: 280, height: 600))
  host.addSubview(ed)
  host.addSubview(s)
  s.folder = d
  let m = s.margin
  m.animationDuration = 0
  m.floating.fade = 0
  m.geometry = FixedLineGeometry(lineHeight: 20, top: 0)
  m.editorView = ed
  let u = ReviewUser(id: "u1", name: "Ada", initials: "A")
  m.state = ReviewState(buf: 1, items: [ReviewItem(id: "a", kind: .comment, threadID: "a", author: u, quote: "w",
                                                   messages: [ReviewMessage(id: "m", text: "hi", ts: nil, user: u, mine: false)],
                                                   range: ReviewRange(line: 5, col: 0, endLine: 5, endCol: 4))])
  s.tab = .comments
  m.cursor = ReviewCursor(buf: 1, line: 5, col: 1, here: ["a"])
  #expect(m.floating.shownIDs.isEmpty && m.selectedID == "a")  // Comments on screen: the margin's card
  s.tab = .files
  #expect(m.floating.shownIDs == ["a"] && m.selectedID == nil && !s.commentsVisible)  // Files: it floats
  s.tab = .comments
  #expect(m.floating.shownIDs.isEmpty && s.commentsVisible)
  s.isHidden = true  // the sidebar hidden: floats
  #expect(m.floating.shownIDs == ["a"])
  s.isHidden = false
  // The tab is remembered for the project.
  s.tab = .files
  let again = SidebarView(frame: .zero)
  again.folder = d
  #expect(again.tab == .files)
  UserDefaults.standard.removeObject(forKey: "taudot.sidebar.tab." + d.standardizedFileURL.path)
}

// ---- the Rex look -----------------------------------------------------------------------------------------------

@MainActor @Test func nestedFoldersAreSectionsByPath() {
  let d = project()
  defer { try? FileManager.default.removeItem(at: d) }
  try! FileManager.default.createDirectory(at: d.appendingPathComponent("figs/plots"), withIntermediateDirectories: true)
  try! "x".write(to: d.appendingPathComponent("figs/plots/a.png"), atomically: true, encoding: .utf8)
  let t = FileTree(root: d)
  #expect(FileRow.build(t, collapsed: []).compactMap { if case let .section(n, _, _) = $0 { n.rel } else { nil } } == ["figs", "figs/plots", "sections"])
  // A collapsed section hides the sections inside it too; it says how many files it holds.
  let rows = FileRow.build(t, collapsed: ["figs"])
  #expect(!rows.contains { $0.node?.rel == "figs/plots" })
  #expect(rows.contains { if case let .section(n, true, 2) = $0 { n.rel == "figs" } else { false } })
}

@Test func iconsByKind() {
  func n(_ name: String) -> FileNode { FileNode(url: URL(fileURLWithPath: "/p/" + name), rel: name, isDirectory: false, parent: nil) }
  #expect(n("a.tex").glyph == "doc.text" && n("a.bib").glyph == "books.vertical" && n("a.png").glyph == "photo")
  #expect(n("a.sty").glyph == "gearshape" && n("a.pdf").glyph == "doc.richtext" && n("a.txt").glyph == "doc")
}

@MainActor @Test func badgesAndFading() {
  let d = project()
  defer { try? FileManager.default.removeItem(at: d) }
  let long = "a-very-long-file-name-that-will-not-fit-in-the-sidebar-at-all.tex"
  try! "x".write(to: d.appendingPathComponent(long), atomically: true, encoding: .utf8)
  let v = filesView(d)
  // taudot_files: open comments in main.tex, Bob in refs.bib.
  let p: Value = .map([
    (.string("comments"), .map([(.string("main.tex"), .int(2))])),
    (.string("people"), .map([(.string("refs.bib"), .array([.map([(.string("name"), .string("Bob")), (.string("initials"), .string("B")), (.string("color"), .string("#ff8800"))])]))])),
  ])
  v.badges = FileBadges(p)
  #expect(v.badges.comments == ["main.tex": 2] && v.badges.people["refs.bib"]?.first?.name == "Bob")
  let main = v.cell("main.tex")!, refs = v.cell("refs.bib")!
  #expect(main.badges.comments == 2 && main.badges.personColor == nil && main.badges.width > 0)
  #expect(refs.badges.personColor != nil && refs.badges.comments == 0)
  // Monochrome: no colour on the glyphs; the current file's a shade stronger.
  #expect(main.glyph.contentTintColor == .secondaryLabelColor)
  v.current = d.appendingPathComponent("main.tex")
  #expect(main.glyph.contentTintColor == .labelColor)
  #expect(main.toolTip?.contains("2 open comments") == true && refs.toolTip?.contains("Bob here now") == true)
  // A long name fades at the right edge; a short one doesn't.
  let c = v.cell(long)!
  c.frame = NSRect(x: 0, y: 0, width: 260, height: 32)
  c.layoutSubtreeIfNeeded()
  c.name.layout()
  #expect(c.name.fades)
  main.frame = NSRect(x: 0, y: 0, width: 260, height: 32)
  main.layoutSubtreeIfNeeded()
  main.name.layout()
  #expect(!main.name.fades)
  // Hover shows the "•••".
  #expect(c.more.isHidden)
  c.hovered = true
  #expect(!c.more.isHidden)
}

@MainActor @Test func selectionIsAGlassCapsule() {
  let d = project()
  defer { try? FileManager.default.removeItem(at: d) }
  let v = filesView(d)
  v.frame = NSRect(x: 0, y: 0, width: 260, height: 500)
  v.layoutSubtreeIfNeeded()
  v.select("main.tex")
  let rv = v.table.rowView(atRow: v.row(of: "main.tex")!, makeIfNecessary: true) as? PillRowView
  #expect(rv?.pill != nil)
  #expect(rv?.pill is GlassCapsule)
  v.select("refs.bib")
  #expect(rv?.pill == nil)
}

// ---- the tab switch's motion ------------------------------------------------------------------------------------

@MainActor @Test func tabSwitchCrossfadesAndSlidesTowardTheTab() async {
  let d = project()
  defer { try? FileManager.default.removeItem(at: d) }
  let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
  let s = SidebarView(frame: w.contentView!.bounds)
  w.contentView!.addSubview(s)
  s.folder = d
  s.tab = .comments
  s.layoutSubtreeIfNeeded()
  defer { UserDefaults.standard.removeObject(forKey: "taudot.sidebar.tab." + d.standardizedFileURL.path) }
  var reduce = false
  s.reduceMotion = { reduce }

  func slide(_ l: CALayer?) -> (Double, Double)? {
    guard let g = l?.animation(forKey: "tabSwitch") as? CAAnimationGroup,
          let t = g.animations?.first(where: { ($0 as? CABasicAnimation)?.keyPath == "transform.translation.x" }) as? CABasicAnimation
    else { return nil }
    return ((t.fromValue as! NSNumber).doubleValue, (t.toValue as! NSNumber).doubleValue)
  }
  func fades(_ l: CALayer?) -> (Double, Double)? {
    guard let g = l?.animation(forKey: "tabSwitch") as? CAAnimationGroup,
          let o = g.animations?.first(where: { ($0 as? CABasicAnimation)?.keyPath == "opacity" }) as? CABasicAnimation
    else { return nil }
    return ((o.fromValue as! NSNumber).doubleValue, (o.toValue as! NSNumber).doubleValue)
  }

  // Files is the left tab: the new view comes in from the right, moving 8 pt left; the old one leaves the same way.
  s.tab = .files
  #expect(s.margin.isHidden && !s.files.isHidden)  // the state switches at once
  #expect(fades(s.files.layer)! == (0, 1))
  #expect(slide(s.files.layer)! == (8, 0))
  let ghost = s.leaving
  #expect(ghost != nil && fades(ghost?.layer)! == (1, 0) && slide(ghost?.layer)! == (0, -8))
  #expect(s.files.layer?.animation(forKey: "tabSwitch")?.duration == SidebarView.switchDuration)
  // Comments, to the right: from the left, moving right.
  s.tab = .comments
  #expect(ghost?.superview == nil)  // a quick second switch drops the first picture
  #expect(slide(s.margin.layer)! == (-8, 0) && slide(s.leaving?.layer)! == (0, 8))
  // The picture goes when it's done.
  try? await Task.sleep(for: .milliseconds(400))
  #expect(s.leaving == nil && s.subviews.allSatisfy { $0 === s.margin || $0 === s.files || $0 === s.overview || $0.className.contains("HeaderBar") })

  // Reduce Motion: the crossfade only.
  reduce = true
  s.tab = .files
  #expect(fades(s.files.layer)! == (0, 1) && slide(s.files.layer) == nil && slide(s.leaving?.layer) == nil)
  #expect(s.files.layer?.affineTransform() == .identity)
}

// ---- jumps ------------------------------------------------------------------------------------------------------

@MainActor @Test func jumpsAndShowResolvedGoToNeovim() async throws {
  let s = SidebarView(frame: NSRect(x: 0, y: 0, width: 280, height: 600))
  let nv = RecordingNvim()
  let c = ReviewController(nvim: nv, sidebar: s)
  nv.answer = .bool(true)
  try await c.attach(channel: 1)
  nv.calls = []
  c.jump(1)
  c.jump(-1, count: 3)
  s.margin.showResolved = true
  for _ in 0..<50 where nv.calls.count < 3 { try? await Task.sleep(for: .milliseconds(20)) }
  #expect(nv.calls.contains([.int(1), .int(1)]) && nv.calls.contains([.int(-1), .int(3)]))
  #expect(nv.calls.contains { $0.first == .string("show_resolved") && $0[2]["on"] == .bool(true) })
}
