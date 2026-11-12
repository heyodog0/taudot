// TaudotPDF: the PDF pane of the Mac app (docs/mac-app.md). TeXpresso typesets, the engine feeds it live edits
// (or the folder is watched), PDFPaneView draws the pages.
import AppKit
import TaudotCursor
import TaudotShared

@MainActor public final class TaudotPDFPane: PDFPane {
  public let pane = PDFPaneView(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
  public var view: NSView { pane }
  public var onInverseSearch: (@MainActor (_ path: String, _ line: Int) -> Void)?
  /// Double-click or Cmd-click with the clicked word's column (UTF-8 bytes in the line, nil when the word wasn't found
  /// in the source). Called instead of `onInverseSearch` when set.
  public var onInverseSearchWord: (@MainActor (_ path: String, _ line: Int, _ column: Int?) -> Void)?
  /// For benches: what the last word-level forward and inverse search found.
  public private(set) var lastForwardWord: String?
  public private(set) var lastInverse: (path: String, line: Int, column: Int?, word: String?)?
  /// Status lines ("32 pages, typeset in 210 ms", restarts, TeX errors).
  public var onStatus: (@MainActor (String) -> Void)?
  /// Every line the typesetter (txp-headless) writes to stderr, in order, on the main actor, without the newline:
  /// TeX's output as JSON (`["append-lines","log",...]`, `["truncate-lines","log",N]`, also for "out"), Tectonic's
  /// `Error: ...` summary, the driver's notes. After a restart (`onStatus` says "texpresso: ..., restarting") the
  /// lines come from a new process and its log starts over.
  public var onDriverLine: (@MainActor (String) -> Void)?
  /// BibTeX's warnings and errors (its .blg), the whole list after each BibTeX run, and once at open from the cached
  /// run when the .bbl comes from the cache. Empty when BibTeX had nothing to say.
  public var onBibIssues: (@MainActor ([BibTeXIssue]) -> Void)?
  public private(set) var bibIssues: [BibTeXIssue] = []
  /// Each edit's latency, from the engine's doc.changed (or a file save) to its page on screen, in ms.
  public var onEditShown: (@MainActor (_ ms: Double, _ page: Int) -> Void)?

  public internal(set) var folder: URL?
  public private(set) var txp: (any Typesetter)?
  /// The typesetter this project got (nil before it is chosen: with the engine, at project.open).
  public private(set) var engine: EngineChoice?
  /// The typesetter asked for (`engine` may differ: a live pdfTeX year that isn't installed runs TeXpresso).
  private(set) var requested: EngineChoice?
  private var feed: EngineFeed?
  private var watch: FolderWatch?
  internal(set) var synctex: SyncTex?
  /// A jump asked for before SyncTeX was in: replayed as it was asked (deliberate or a cursor follow).
  private(set) var pendingJump: (path: String, line: Int, column: Int?, deliberate: Bool)?
  /// What TeXpresso was sent, per path relative to the folder, as UTF-8 (columns are byte offsets in a line).
  private var sources: [String: [UInt8]] = [:] { didSet { sourceLinesCache.removeAll() } }
  /// `sources` split into lines, made on first use after a change (the issues list asks for many lines per log).
  private var sourceLinesCache: [String: [String]] = [:]
  private var syncGen = 0
  /// Outside edits waiting for the typeset with them (EditMarks.swift), and how many went up.
  var editMarks: [PendingEditMark] = []
  public internal(set) var editMarksShown = 0
  var syncGenForMarks: Int { syncGen }
  var syncInstalledForMarks: Int { syncInstalled }
  func relativePath(_ p: String) -> String { relative(p) }
  /// The report generation whose SyncTeX is installed: an older one's, slower to come, never replaces it.
  private var syncInstalled = 0
  /// The pane's session: `close()` bumps it, so work started for one folder (a version) never lands on the next.
  /// Every task that awaits captures it and checks it after each await.
  private(set) var openGen = 0
  private var jumpSeq = 0
  /// The source line the deliberate highlight is for.
  var markFor: (path: String, line: Int)?
  /// Bumped by every new mark: a click's fade from before it is stale.
  var clickFadeGen = 0
  /// For benches: the last cross-reference followed (its key and where its label is).
  public private(set) var lastRef: (key: String, path: String, line: Int)?
  /// The latest jump's word search has ended (found or not).
  private var jumpDone = true
  /// For benches: the latest forward search has finished looking for its word.
  public var forwardSearchDone: Bool { jumpDone }
  /// Words read off the pages, by page, then by region.
  private var pageWords: [Int: [String: [(raw: String, rect: CGRect)]]] = [:]
  private var editAt: CFTimeInterval = 0  // first edit not yet on screen
  public private(set) var lastPages: PagesEvent?
  var openedMainName: String?
  /// The page cache: shown at open, saved after a typeset settles.
  var cacheShown = false
  var openedMain: String? { get { openedMainName } }
  var cacheDirty: Set<Int> = []
  /// Times each page was reported changed: a save keeps a page clean only if it didn't change while being rendered.
  var cacheChanges: [Int: Int] = [:]
  var cacheScales: [Int: Double] = [:]
  var cacheTask: Task<Void, Never>?
  var lastSynctexText: String?
  /// For benches: when the cached pages went up (CACurrentMediaTime), and how many.
  public private(set) var cacheShownAt: CFTimeInterval = 0
  public private(set) var cachePagesShown = 0
  /// txp-render's glyphs per page (exact words, the cursor), and the reads in flight.
  var glyphCache: [Int: PageGlyphs] = [:]
  var glyphTasks: [Int: Task<PageGlyphs?, Never>] = [:]
  /// Source positions ↔ glyphs, for the cursor dot and click-to-letter (nil before SyncTeX, or with txp-headless).
  var cursorMap: CursorMap?
  /// The cursor as the editor last gave it, to place the dot again when pages or glyphs change.
  var caretAt: (path: String, line: Int, column: Int, text: String)?
  /// The text a line was last aligned with in this glyph epoch (`caretTyping`).
  var caretAnchor: (key: String, text: String)?
  /// The cursor line whose pages' glyphs were last looked up, with the `glyphEpoch` it was done in: looked up again
  /// only on another line, or once the pages or SyncTeX changed (never in a loop when a page's glyphs can't be read).
  var caretLookedUp = ""
  /// Bumped when pages change, new SyncTeX comes or the pane closes: glyph lookups made before are out of date.
  var glyphEpoch = 0
  /// When the editor sent the latest cursor move (CACurrentMediaTime's clock), for the latency trace.
  var caretSentAt: CFTimeInterval?
  /// Why the dot was hidden or kept for the latest event, and the tally.
  var caretWhy = ""
  var caretOutcomes: [String: Int] = [:]
  /// For benches: words came from glyphs (true) or OCR.
  public private(set) var wordsFromGlyphs = 0, wordsFromOCR = 0
  /// Review comments drawn on the pages (`setComments`), and a generation to drop stale placements.
  private var comments: [PDFComment] = []
  private var notesGen = 0
  // History's version pane (VersionPDF.swift)
  var versionFolder: URL?
  /// The version's PDF is saved beside its files (opened from there, or saved once it settled).
  public internal(set) var versionSaved = false
  var changeList: [PDFChange] = []
  var changesGen = 0
  var changesDone = false
  /// A change's mark on the pages was clicked (its id).
  public var onChangeClick: (@MainActor (String) -> Void)?
  /// The changes were all looked for on the pages (after `setChanges` or a typesetting).
  public var onChangesPlaced: (@MainActor () -> Void)?
  /// A click on a comment's note on the PDF (its id). The app jumps Neovim there and selects its card.
  public var onCommentClick: (@MainActor (String) -> Void)?
  /// The pinned card's Reply (Return) and Resolve, for a comment id.
  public var onCommentReply: (@MainActor (_ id: String, _ text: String) -> Void)?
  public var onCommentResolve: (@MainActor (_ id: String) -> Void)?
  /// A new comment written on the PDF: text selected there, mapped back to its source range, and what was typed.
  public var onCommentCreate: (@MainActor (_ range: PDFCommentDraft, _ text: String) -> Void)?
  /// A drag's generation, to drop a stale word read.
  private var selectGen = 0
  /// The comments toggle changed (the PDF's right-click menu, or `showComments`), for a View menu's tick.
  public var onShowCommentsChanged: (@MainActor (Bool) -> Void)?

  /// The page: white, sepia or dark (Settings ▸ PDF, UserDefaults `taudot.pdfPage`, read at start; the app sets it
  /// again on every settings change). Applies at once: the driver recolours, every page is drawn again.
  public var pageStyle: PDFPaneView.PageStyle {
    get { pane.pageStyle }
    set {
      guard newValue != pane.pageStyle else { return }
      txp?.pageStyle = newValue.rawValue  // before the pane asks for new renders
      pane.setPageStyle(newValue)
      cacheScales = [:]  // the page cache too, in the new style
      if openedMain != nil { scheduleCacheSave() }
    }
  }
  /// The style of the page images in the page cache on disk.
  var cacheStyle = "white"

  /// The page cache's root (nil: `PageCache.root`, from the environment). Tests give each pane its own.
  public let cacheRoot: URL?
  /// No page cache: $TAUDOT_PAGE_CACHE=off, unless this pane has its own root.
  var cacheOff: Bool { cacheRoot == nil && PageCache.off }

  public init(cacheRoot: URL? = nil) {
    self.cacheRoot = cacheRoot
    pane.renderer = { [weak self] page, scale, x, y, w, h in
      await self?.txp?.render(page: page, scale: scale, x: x, y: y, w: w, h: h)
    }
    pane.onLastPageInView = { [weak self] p in self?.txp?.goal(p) }
    pane.canRender = { [weak self] in self?.txp != nil }
    pane.onDoubleClick = { [weak self] page, x, y in Task { await self?.syncClick(page: page, x: x, y: y) } }
    pane.forward.dimWhenIdle = Self.highlightFollows
    pageStyle = PDFPaneView.PageStyle(rawValue: UserDefaults.standard.string(forKey: "taudot.pdfPage") ?? "") ?? .white
    pane.notes.onClick = { [weak self] id in self?.onCommentClick?(id) }
    pane.changes.onClick = { [weak self] id in self?.onChangeClick?(id) }
    pane.notes.onReply = { [weak self] id, text in self?.onCommentReply?(id, text) }
    pane.notes.onResolve = { [weak self] id in self?.onCommentResolve?(id) }
    pane.selection.onSend = { [weak self] d, text in self?.onCommentCreate?(d, text) }
    pane.onSelect = { [weak self] page, a, b, done in self?.select(page: page, from: a, to: b, done: done) }
    pane.onTap = { [weak self] page, x, y in Task { await self?.followRef(page: page, x: x, y: y) } }
    pane.notes.onShownChanged = { [weak self] on in self?.onShowCommentsChanged?(on) }
    pane.onPageShown = { [weak self] page in
      guard let self else { return }
      if self.editAt > 0 { Latency.shared.record(.pageShown, key: Latency.shared.lastKey, value: Int64(page)) }
      self.glyphsWanted(page)
      self.editShown(page)
      guard self.editAt > 0 else { return }
      let ms = (CACurrentMediaTime() - self.editAt) * 1000
      self.editAt = 0
      self.onEditShown?(ms, page)
    }
  }

  /// The main .tex of a folder: `main.tex` if there is one, else a top-level .tex with \documentclass.
  public static func findMain(in folder: URL) -> String? {
    let fm = FileManager.default
    if fm.fileExists(atPath: folder.appendingPathComponent("main.tex").path) { return "main.tex" }
    let names = (try? fm.contentsOfDirectory(atPath: folder.path))?.filter { $0.hasSuffix(".tex") }.sorted() ?? []
    return names.first { n in
      guard let s = try? String(contentsOf: folder.appendingPathComponent(n), encoding: .utf8) else { return false }
      return s.contains("\\documentclass")
    }
  }

  public func open(folder: URL, main: String, engineSocket: URL?) {
    close()
    self.folder = folder
    openedMainName = main
    showCache(folder: folder, main: main)
    let mainText = try? String(contentsOf: folder.appendingPathComponent(main), encoding: .utf8)
    if engineSocket == nil {
      startTypesetter(choose(compiler: nil, image: nil, mainText: mainText))
    } else {
      // the project's compiler and TeX Live image come with project.open; a slow or absent engine: the source decides
      DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
        MainActor.assumeIsolated {
          guard let self, self.folder == folder, self.txp == nil else { return }
          self.startTypesetter(self.choose(compiler: nil, image: nil, mainText: mainText))
        }
      }
    }
    if let engineSocket {
      let f = EngineFeed(socket: engineSocket.path, folder: folder, sink: feedSink())
      f.onNote = { [weak self] s in self?.onStatus?(s) }
      f.onEdit = { [weak self] path in if self?.held.contains(path) == false { self?.edited() } }
      f.onProject = { [weak self] compiler, image in
        guard let self else { return }
        self.overleafCompiler = compiler.isEmpty ? nil : compiler
        self.lastImage = image
        let c = self.choose(compiler: compiler.isEmpty ? nil : compiler, image: image, mainText: mainText)
        self.check("project: compiler \(compiler) image \(image) → \(c)")
        self.engineChosen(c)  // the docs are opened (again) right after this
      }
      f.start()
      feed = f
    }
    let w = FolderWatch(folder: folder) { [weak self] rel in self?.fileSaved(rel) }
    w.start()
    watch = w
    if let p = ProcessInfo.processInfo.environment["TAUDOT_PDF_CHECK"] { startCheck(URL(fileURLWithPath: p)) }
  }

  /// The project's typesetter as project.open names it (on every engine connect): started unless it is the one asked
  /// for already.
  func engineChosen(_ c: EngineChoice) {
    // against the request, not what runs: a missing TeX Live year falls back to TeXpresso every time, so comparing
    // with `engine` restarted TeXpresso on every engine reconnect
    guard requested != c else { return }
    if engine == c, txp != nil { requested = c; return }  // already running it (the fallback)
    startTypesetter(c)
  }

  /// Tests: makes the typesetter instead of Txp/LiveTex.
  var makeTypesetter: ((EngineChoice) -> any Typesetter)?

  /// Starts the typesetter for `choice` (stopping one already running): the live pdfTeX when it is there for that
  /// year, else TeXpresso.
  func startTypesetter(_ choice: EngineChoice) {
    guard let folder, let main = openedMainName else { return }
    txp?.stop()
    requested = choice
    var choice = choice
    // (tests' typesetters stand in for universal, not for a missing pdfTeX year)
    let (c, notes) = makeTypesetter == nil ? Self.runnable(choice) : Self.runnable(choice, universalMissing: { _ in nil })
    choice = c
    for n in notes { onStatus?(n) }
    defer { publishProject() }
    let t: any Typesetter
    if let make = makeTypesetter { install(make(choice), choice: choice); return }
    let cache = cacheOff ? nil : PageCache.dir(folder, root: cacheRoot)
    switch choice {
    case .texpresso: t = Txp(main: folder.appendingPathComponent(main), bibCache: cache)
    case .live(let year):
      t = LiveTex(main: folder.appendingPathComponent(main), year: year, state: cache?.appendingPathComponent("live-\(year)"))
    case .universal(let e):
      t = LiveTex(main: folder.appendingPathComponent(main), year: UniversalPaths.year,
                  state: cache?.appendingPathComponent("universal-\(e.rawValue)"), universal: e)
    }
    install(t, choice: choice)
  }

  /// What runs when `choice` can't: universal pdfLaTeX falls back to the patched pdfTeX, universal XeLaTeX/LuaLaTeX
  /// to TeXpresso, a missing patched pdfTeX year to TeXpresso; with the status lines saying so.
  static func runnable(_ choice: EngineChoice, universalMissing: (TexEngine) -> String? = { UniversalPaths.missing($0) },
                       liveMissing: (String) -> String? = { LiveTexPaths.missing($0) }) -> (EngineChoice, [String]) {
    var choice = choice, notes: [String] = []
    if case .universal(let e) = choice, let why = universalMissing(e) {
      choice = e == .pdflatex ? .live(year: EngineChoice.years[0]) : .texpresso
      notes.append("universal: \(why); typesetting with \(e == .pdflatex ? "pdfTeX" : "TeXpresso")")
    }
    if case .live(let year) = choice, let why = liveMissing(year) {
      notes.append("pdfTeX: \(why); typesetting with TeXpresso")
      choice = .texpresso
    }
    return (choice, notes)
  }

  /// Settings' universal switches (tests set their own: the real ones live in the shared defaults).
  var universalSwitches: (unicode: Bool, pdflatex: Bool)?
  /// The typesetter this project names now: its own engine (Settings), Overleaf's compiler, its main file.
  func choose(compiler: String?, image: String?, mainText: String?) -> EngineChoice {
    EngineChoice.choose(compiler: compiler, image: image, mainText: mainText, engine: folder.flatMap { UniversalSettings.engine(for: $0) },
                        universal: universalSwitches ?? (UniversalSettings.unicode(), UniversalSettings.pdflatex()))
  }

  /// Overleaf's compiler for this project (project.open), nil before it comes or without the engine.
  var overleafCompiler: String?
  /// The TeX Live image project.open named.
  var lastImage: String?
  /// The engine the project names: Overleaf's compiler, else its main file's.
  var projectEngine: TexEngine? {
    if let c = overleafCompiler { return TexEngine(compiler: c) }
    guard let folder, let main = openedMainName,
      let s = try? String(contentsOf: folder.appendingPathComponent(main), encoding: .utf8) else { return nil }
    return TexEngine.fromSource(s)
  }
  /// What runs the project, in words (Settings ▸ PDF).
  var runningName: String? {
    switch engine {
    case .texpresso: return "TeXpresso"
    case .live: return "pdfTeX (patched, live)"
    case .universal(let e): return "\(e.title) on universal"
    case nil: return nil
    }
  }
  /// Tells Settings ▸ PDF this is the project it talks about (opened, came to the front, or its engine changed).
  func publishProject() {
    CurrentProject.set(folder: folder, engine: projectEngine, running: runningName)
    if projectObservers.isEmpty {
      let nc = NotificationCenter.default
      projectObservers.append(nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] n in
        let w = UncheckedBox(n.object as AnyObject?)
        MainActor.assumeIsolated {
          guard let self, w.v != nil, w.v === self.pane.window, self.folder != nil else { return }
          self.publishProject()
        }
      })
      projectObservers.append(nc.addObserver(forName: UniversalSettings.changed, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.engineSettingsChanged() }
      })
    }
  }
  private var projectObservers: [NSObjectProtocol] = []

  /// Settings ▸ PDF changed an engine switch or this project's engine: the typesetter it names now, if another.
  func engineSettingsChanged() {
    guard let folder, let main = openedMainName, engine != nil else { return }
    let text = try? String(contentsOf: folder.appendingPathComponent(main), encoding: .utf8)
    let c = choose(compiler: overleafCompiler, image: lastImage, mainText: text)
    guard c != requested else { return }
    check("settings: engine → \(c)")
    startTypesetter(c)
  }

  /// Runs `t` as the pane's typesetter (`choice`: which one it is, nil for a saved PDF).
  func install(_ t: any Typesetter, choice: EngineChoice?) {
    engine = choice
    t.pageStyle = pageStyle.rawValue  // sent when it starts
    resetParaCount()
    txp = t
    cursorFeed.reset()
    t.onPages = { [weak self] e in self?.pagesEvent(e) }
    if let lt = t as? LiveTex {
      lt.onPara = { [weak self] o in
        guard let self, !Self.paraOff, o.applied > self.paraRetired else { return }
        self.pane.showPara(o)
      }
    }
    t.onError = { [weak self] s in
      self?.check("tex error: \(s)")
      self?.onStatus?("TeX: \(s)")
    }
    t.onLine = { [weak self] l in
      guard let self else { return }
      self.onDriverLine?(l)
      if let blg = BibTeXIssue.blg(fromDriverLine: l) {
        self.bibIssues = BibTeXIssue.parse(blg)
        self.onBibIssues?(self.bibIssues)
      }
    }
    t.onNote = { [weak self] s in
      self?.check("note: \(s)")
      self?.onStatus?(s)
    }
    t.onRestart = { [weak self] in
      guard let self else { return }
      self.check("txp restarted")
      self.inFlight = []  // the new process counts from 0; the reopen sends the docs whole
      self.resetParaCount()
      Task { try? await self.feed?.reopen() }
    }
    if let g = pane.pagesInView.max() { t.goal(g) }
    t.start()
    pane.queueRefresh()  // renders may go out again
    // the open editor buffers TeXpresso had (a switch after project.open, or a start after the fallback timer)
    for (path, b) in sources.sorted(by: { $0.key < $1.key }) { t.open(path, String(decoding: b, as: UTF8.self)) }
    let name = choice == nil ? "saved PDF" : choice == .texpresso ? "texpresso" : (t as? LiveTex)?.label ?? "pdfTeX"
    onStatus?(cacheShown ? "the last PDF; typesetting…" : "\(name): first run")
  }

  // ---- self-check (TAUDOT_PDF_CHECK=file) ----------------------------------------------------------------------
  private var checkLog: FileHandle?
  private var reads = 0, readsInFlight = 0, readsMaxInFlight = 0
  /// Engine edits sent to txp-headless and not yet in a report: (its command count after the edit, arrival time).
  private var inFlight: [(n: Int, at: CFTimeInterval)] = []
  /// Edits a report showed on pages in view, waiting for one of those pages to be swapped in.
  private var awaiting: [(pages: Set<Int>, edits: [CFTimeInterval], report: CFTimeInterval)] = []

  /// Self-check: an engine edit's way to the screen. Each edit is covered by the first report whose `applied` count
  /// reaches it; if that report changed a page in view, the edit is on screen when that page's new tiles are swapped
  /// in ("edit shown"), else it changed nothing visible ("edit offscreen").
  private func editsReported(_ e: PagesEvent) {
    guard checkLog != nil, e.applied >= 0 else { return }
    let covered = inFlight.filter { $0.n <= e.applied }
    guard !covered.isEmpty else { return }
    inFlight.removeAll { $0.n <= e.applied }
    let visible = Set(pane.pagesInView).intersection(e.changed)
    if visible.isEmpty {
      for c in covered { check(String(format: "edit offscreen: arrived %.4f report %.4f", c.at, CACurrentMediaTime())) }
    } else {
      awaiting.append((visible, covered.map(\.at), CACurrentMediaTime()))
    }
  }

  private func editShown(_ page: Int) {
    guard checkLog != nil else { return }
    let now = CACurrentMediaTime()
    for a in awaiting where a.pages.contains(page) {
      for t in a.edits { check(String(format: "edit shown: arrived %.4f report %.4f shown %.4f page %d", t, a.report, now, page)) }
    }
    awaiting.removeAll { $0.pages.contains(page) }
  }

  func check(_ s: String) {
    guard let checkLog else { return }
    checkLog.write(Data(String(format: "%.3f %@\n", CACurrentMediaTime(), s).utf8))
  }

  /// Logs page events, restarts, main-thread stalls over 150 ms and Vision reads; every 2 s compares the copy of each
  /// engine doc kept for word matching with the engine's own text (a drift is logged with where it starts).
  private func startCheck(_ url: URL) {
    FileManager.default.createFile(atPath: url.path, contents: nil)
    checkLog = FileHandle(forWritingAtPath: url.path)
    check("check: on")
    var last = CACurrentMediaTime()
    Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        let now = CACurrentMediaTime()
        if now - last > 0.15 { self?.check(String(format: "STALL main thread %.0f ms", (now - last) * 1000)) }
        last = now
      }
    }
    Task { [weak self] in
      while let self, self.checkLog != nil {
        try? await Task.sleep(for: .seconds(2))
        guard let feed = self.feed else { continue }
        self.check("state: \(self.pane.pageCount) pages on screen, txp restarts \(self.txp?.restartCount ?? 0), duplicates dropped \(feed.duplicates), Vision reads \(self.reads) (max \(self.readsMaxInFlight) at once)")
        for path in feed.liveDocs.sorted() where !self.held.contains(path) {  // an editor's: unconfirmed edits differ
          guard let e = await feed.docText(path) else { continue }
          let mine = self.sources[path] ?? []
          let theirs = Array(e.text.utf8)
          if mine == theirs { continue }
          // edits may still be on their way: look again once they've had time to arrive
          try? await Task.sleep(for: .milliseconds(400))
          guard let e2 = await feed.docText(path), e2.seq == e.seq else { continue }
          let m = self.sources[path] ?? []
          if m == theirs { continue }
          let at = (0..<min(m.count, theirs.count)).first { m[$0] != theirs[$0] } ?? min(m.count, theirs.count)
          let ctx = { (b: [UInt8]) in String(decoding: b[max(0, at - 20)..<min(b.count, at + 20)], as: UTF8.self) }
          self.check("DRIFT \(path) seq \(e.seq): mine \(m.count) bytes, engine \(theirs.count), first difference at \(at): mine \(ctx(m).debugDescription) engine \(ctx(theirs).debugDescription)")
        }
      }
    }
  }

  public func close() {
    saveCacheIndex()
    openGen += 1
    overleafCompiler = nil
    lastImage = nil
    // every generation moves on, so in-flight placements, reads and jumps drop their results
    syncGen += 1
    notesGen += 1
    changesGen += 1
    selectGen += 1
    nextJump()
    pendingJump = nil
    changesDone = false
    changeList = []
    pane.changes.set([], changes: [])
    lastSynctexText = nil
    pageWords = [:]
    glyphCache = [:]
    glyphTasks = [:]
    cursorMap = nil
    glyphEpoch += 1
    bibIssues = []
    cacheTask?.cancel()
    cacheTask = nil
    feed?.stop()
    watch?.stop()
    txp?.stop()
    feed = nil
    watch = nil
    txp = nil
    synctex = nil
    sources = sources.filter { held.contains($0.key) }
    versionFolder = nil
  }

  private func edited() {
    if editAt == 0 { editAt = CACurrentMediaTime() }
  }

  /// What the engine's stream does to the typesetter (docs no editor holds).
  func feedSink() -> EngineFeed.Sink {
    .init(
      open: { [weak self] path, text in
        guard let self else { return }
        if self.held.contains(path) {  // the editor's text, not the engine's (a typesetter restart's reopen)
          self.txp?.open(path, String(decoding: self.sources[path] ?? [], as: UTF8.self))
          return
        }
        self.sources[path] = Array(text.utf8)
        self.txp?.open(path, text)
      },
      change: { [weak self] path, pos, del, ins in
        guard let self, !self.held.contains(path) else { return }
        guard self.typeset(path, pos, del, ins) else {
          // an edit that doesn't fit our copy (TeXpresso would refuse it too): send the docs whole again
          self.check("bad change \(path) @\(pos) -\(del) of \(self.sources[path]?.count ?? -1): reopening")
          Task { try? await self.feed?.reopen() }
          return
        }
      })
  }
  func feedOpenForTest(_ path: String, _ text: String) { feedSink().open(path, text) }
  func feedChangeForTest(_ path: String, _ pos: Int, _ del: Int, _ ins: String) { feedSink().change(path, pos, del, ins) }

  /// One edit to the typesetter, after our copy of the doc (false: it doesn't fit the copy, nothing sent).
  private func typeset(_ path: String, _ pos: Int, _ del: Int, _ ins: String) -> Bool {
    guard var b = sources[path], pos >= 0, del >= 0, pos + del <= b.count else { return false }
    b.replaceSubrange(pos..<(pos + del), with: Array(ins.utf8))
    sources[path] = b
    txp?.change(path, pos, del, ins)
    Latency.shared.record(.typesetSent, key: Latency.shared.lastKey, value: Int64(txp?.sent ?? -1))
    if checkLog != nil, let n = txp?.sent { inFlight.append((n, CACurrentMediaTime())) }
    return true
  }

  // ---- the editor's own text (docs/agents/pdfpipe.md, step 2) ------------------------------------------------------
  /// Docs an editor in this window holds. Their text comes from the editor, every change to its buffer in order (the
  /// user's edits, the remote ones it merged, a rebase's), not from the engine's stream: the typesetter's text is the
  /// editor's after every step, and a keystroke reaches it without the engine round trip. Kept across `close()` (the
  /// editor still holds them); the engine's stream takes a doc back when the editor lets it go.
  private var held: Set<String> = []

  /// The editor holds `path`, with this text now.
  public func editorHolds(_ path: String, text: String) {
    held.insert(path)
    let b = Array(text.utf8)
    guard sources[path] != b else { return }
    if sources[path] != nil { edited() }
    sources[path] = b
    txp?.open(path, text)
  }

  /// The editor's text of `path` changed: `del` bytes at `pos` replaced with `ins` (UTF-8 offsets, in order).
  public func editorChanged(_ path: String, _ pos: Int, _ del: Int, _ ins: String) {
    guard held.contains(path) else { return }
    edited()
    if !typeset(path, pos, del, ins) {  // a bug somewhere: the engine's text again, until the editor says more
      check("bad editor change \(path) @\(pos) -\(del) of \(sources[path]?.count ?? -1): back to the engine's")
      editorReleased(path)
    }
  }

  /// The editor let `path` go: the engine's stream again (its text, whole).
  public func editorReleased(_ path: String) {
    guard held.remove(path) != nil else { return }
    Task { try? await feed?.reopen() }
  }

  /// For benches: time the next edit from `t` (CACurrentMediaTime) instead of from its arrival here.
  public func noteEdit(at t: CFTimeInterval) { editAt = t }
  /// Docs the engine feeds live (0 until it has connected).
  public var liveDocCount: Int { feed?.liveDocs.count ?? 0 }

  private func fileSaved(_ rel: String) {
    guard let folder, let txp else { return }
    if feed?.liveDocs.contains(rel) == true { return }
    // BibTeX's input: TeX never reads it, the driver runs BibTeX again if it changed (clients/render/driver.c)
    if rel.hasSuffix(".bib") || rel.hasSuffix(".bst") { txp.rescan(); return }
    guard let text = try? String(contentsOf: folder.appendingPathComponent(rel), encoding: .utf8) else { return }
    edited()
    sources[rel] = Array(text.utf8)
    txp.open(rel, text)
  }

  /// The paragraph preview: edits already in a PDF (a preview of fewer comes too late to show); TAUDOT_PARA=0 off.
  private var paraRetired = -1
  /// A new driver counts edits from 0 again: the previews' and PDFs' `applied` restart.
  private func resetParaCount() {
    paraRetired = -1
    pane.para.covered = Int.min
  }
  static let paraOff = ProcessInfo.processInfo.environment["TAUDOT_PARA"] == "0"

  private func pagesEvent(_ e: PagesEvent) {
    lastPages = e
    check("pages gen \(e.gen) lost_starts \(e.lostStarts) applied \(e.applied) n \(e.n) done \(e.done) changed \(e.changed) edit \(e.editUs / 1000) ms")
    let first = pane.pageCount == 0
    // Pages only go away once a run is done and still has fewer: a report on the way (or a TeXpresso that lost its
    // pages, see Txp) leaves the pages it doesn't mention on screen, and a done run with no pages at all (a broken
    // document, or a restart on the way) leaves the last PDF up rather than a blank pane.
    var sizes = e.sizes
    if sizes.count < pane.pageCount && (!e.done || sizes.isEmpty) {
      sizes += pane.pageSizes[sizes.count...]
    }
    let had = pane.pageCount
    pane.setSizes(sizes)
    if had > 0 && pane.pageCount == 0 { check("BLANK: no pages on screen") }
    if !first { for i in e.changed { pane.markChanged(i); pageWords[i] = nil } }
    if e.applied >= 0 {
      paraRetired = max(paraRetired, e.applied)
      pane.retirePara(applied: e.applied, changed: e.changed, pages: e.n)
    }
    pagesChangedForGlyphs(e)
    cacheDirty.formUnion(e.changed)
    for i in e.changed { cacheChanges[i, default: 0] += 1 }
    if e.done && e.n > 0 { scheduleCacheSave() }
    editsReported(e)
    if e.done && editAt > 0 && !pane.swapPending { editAt = 0 }  // an edit that changed nothing in view
    // A PDF with the edits that changes no page in view (a space at a paragraph's end typesets nothing new): the
    // screen is already right for them. Said at once (pageShown -1), not credited to the next edit's swap.
    if !e.done, editAt > 0, !pane.swapPending, Set(pane.pagesInView).isDisjoint(with: e.changed) {
      Latency.shared.record(.pageShown, key: Latency.shared.lastKey, value: -1)
      editAt = 0
    }
    let ms = e.editUs >= 0 ? Double(e.editUs) / 1000 : 0
    if e.n == 0 && e.done && pane.pageCount > 0 {
      onStatus?("no pages from this run (showing the last PDF), typeset in \(Int(ms)) ms")
    } else {
      onStatus?("\(e.n) page\(e.n == 1 ? "" : "s"), \(e.done ? "typeset" : "page in view") in \(Int(ms)) ms")
    }
    // SyncTeX once reports have been quiet for 250 ms: right after a "done" TeXpresso may start an aux rerun and roll
    // its SyncTeX back (then it reads as empty). Empty data never replaces good data.
    // A display page has no SyncTeX and changes nothing about it: a settled document's SyncTeX still installs.
    if e.display { return }
    syncGen += 1
    let g = syncGen, og = openGen
    if e.done, let t = txp {
      Task {
        try? await Task.sleep(for: .milliseconds(250))
        guard g == self.syncGen, og == self.openGen, let text = await t.synctex() else { return }
        guard og == self.openGen, g > self.syncInstalled else { return }
        let st = await Task.detached { SyncTex(text) }.value
        guard og == self.openGen, g > self.syncInstalled, !st.pages.isEmpty else { return }
        self.syncInstalled = g
        self.syncRunOpen = og
        self.lastSynctexText = text
        self.synctex = st
        self.placeComments()
        if self.versionFolder != nil {
          // the PDF saved beside it is the typesetter's latest: only when no report came since this one
          if g == self.syncGen { self.saveVersion(synctex: text) }
          self.placeChanges()
        }
        self.synctexForCursor(text)
        self.placeEditMarks()
        if let j = self.pendingJump {
          self.pendingJump = nil
          self.jump(path: j.path, line: j.line, column: j.column, deliberate: j.deliberate)
        }
      }
    }
  }

  private func relative(_ p: String) -> String {
    var p = p
    if p.hasPrefix("./") { p.removeFirst(2) }
    guard let folder else { return p }
    for base in [folder.path, folder.resolvingSymlinksInPath().path] where p.hasPrefix(base + "/") {
      return String(p.dropFirst(base.count + 1))
    }
    return p
  }

  /// The SyncTeX data of the last finished typesetting (nil before the first; at open, the page cache's until then).
  public var syncTex: SyncTex? { synctex }
  /// `syncTex` is this open's own run's, not the page cache's from last time (benches wait for it).
  public var syncTexFromRun: Bool { synctex != nil && syncRunOpen == openGen }
  private var syncRunOpen = -1
  /// For tests: what a double-click at (x, y) points of `page` would report.
  public func inverse(page: Int, x: Double, y: Double) -> (path: String, line: Int)? {
    guard let r = synctex?.inverse(page: page, x: x, y: y) else { return nil }
    return (relative(r.file), r.line)
  }

  /// Line `line` (1-based) of a source file, from what TeXpresso was sent, else from disk.
  public func sourceLine(_ path: String, _ line: Int) -> String? {
    let rel = relative(path)
    if sources[rel] != nil { let ls = cachedLines(rel); return line >= 1 && line <= ls.count ? ls[line - 1] : nil }
    var bytes = sources[rel]
    if bytes == nil, let folder {
      let url = rel.hasPrefix("/") ? URL(fileURLWithPath: rel) : folder.appendingPathComponent(rel)
      bytes = (try? Data(contentsOf: url)).map { Array($0) }
    }
    guard let bytes, line >= 1 else { return nil }
    var n = 1, start = 0
    for (i, c) in bytes.enumerated() where c == 10 {
      if n == line { return String(decoding: bytes[start..<i], as: UTF8.self) }
      n += 1
      start = i + 1
    }
    return n == line ? String(decoding: bytes[start...], as: UTF8.self) : nil
  }

  public func jump(path: String, line: Int) { jump(path: path, line: line, column: nil) }

  /// The highlight (word box and line band) follows the cursor everywhere: Settings ▸ PDF, off by default. Off, only
  /// the coral dot follows it and the highlight marks deliberate jumps.
  public static var highlightFollows: Bool {
    followsForTest ?? ProcessInfo.processInfo.environment["TAUDOT_HIGHLIGHT_FOLLOWS"].map { $0 == "1" }  // benches
      ?? UserDefaults.standard.bool(forKey: "taudot.pdfHighlightFollows")
  }
  /// Tests set this instead of the defaults (a defaults write reaches every window's settings observer).
  nonisolated(unsafe) static var followsForTest: Bool?
  /// The cursor, once it rests, to the typesetter (tau-live readies a key there: docs/universal.md, the scout).
  lazy var cursorFeed = CursorFeed { [weak self] p, l, c in self?.txp?.cursor(p, line: l, column: c) }

  /// The editor's cursor came to rest on a line or word (cursor-follow). `deliberate`: ⌘⌥J / <leader>av, ]r, ⌥⌘↓ —
  /// the highlight goes there. Otherwise (the follow mode off) the highlight from the last deliberate jump stays while
  /// the cursor is on its line and fades out quickly once it leaves; the dot does the following.
  /// `fades`: a click's jump (a double-click in Neovim): the mark only shows where the word is, and fades by itself
  /// after `clickMarkHold`, as a click in the PDF's does (the user: it stayed on for good while the cursor sat there).
  public func cursorMoved(path: String, line: Int, column: Int?, deliberate: Bool, fades: Bool = false) {
    cursorFeed.moved(relative(path), line: line, column: column ?? 0)
    let follows = Self.highlightFollows
    pane.forward.dimWhenIdle = follows
    if deliberate && fades {
      jump(path: path, line: line, column: column, deliberate: true)
      clickMarked(path, line)
      return
    }
    if deliberate || follows {
      jump(path: path, line: line, column: column, deliberate: deliberate)
      return
    }
    if let m = markFor, m.path != relative(path) || m.line != line {
      markFor = nil
      pane.clearMark()  // a quick fade
    }
  }

  /// A deliberate mark now shows for this source line (it goes when the cursor leaves it). Any new mark cancels a
  /// click's pending fade.
  func marked(_ path: String, _ line: Int) {
    markFor = (relative(path), line)
    clickFadeGen += 1
  }

  /// Seconds a click's mark stays before it fades (tests shorten it).
  nonisolated(unsafe) static var clickMarkHold: TimeInterval = 1.5

  /// A click in the PDF marked this line: the mark only confirms where the editor went, so it fades by itself after
  /// `clickMarkHold`, even with the cursor still on that line. Clicks in a row: each one's timer replaces the last
  /// (the user's report: clicking from line to line left the highlight on for good).
  func clickMarked(_ path: String, _ line: Int) {
    marked(path, line)
    let gen = clickFadeGen
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.clickMarkHold) { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.clickFadeGen == gen, self.markFor != nil else { return }
        self.markFor = nil
        self.pane.clearMark()  // a quick fade
      }
    }
  }

  /// A new jump (or a clear): earlier word searches are dropped, and none is running until one starts.
  @discardableResult func nextJump() -> Int {
    jumpSeq += 1
    jumpDone = true
    return jumpSeq
  }

  /// The cursor went somewhere the PDF has nothing for (a buffer that isn't a .tex file): the mark goes.
  public func clearMark() {
    nextJump()
    pane.clearMark()
  }

  /// Forward search. With a column (a UTF-8 byte offset, Neovim's), the word under the cursor is boxed, over a faint
  /// band across the typeset line it is on: SyncTeX gives
  /// the typeset lines of the source line, the cursor's place among its words picks one, and the words read off that
  /// line and its neighbours are matched against the source line's. When the word can't be found, or with no column,
  /// the band alone marks one typeset line: the cursor's, else the paragraph's first.
  public func jump(path: String, line: Int, column: Int?) { jump(path: path, line: line, column: column, deliberate: true) }

  func jump(path: String, line: Int, column: Int?, deliberate: Bool) {
    if deliberate { marked(path, line) }
    trace("jump: \(path):\(line) col \(column.map(String.init) ?? "-")")
    guard let st = synctex else { pendingJump = (path, line, column, deliberate); return }
    guard let (rows, marks) = st.rows(file: path, line: line) else {
      // the cursor is on something not typeset (a \label, a comment, the preamble): the mark stays where it was (it
      // dims when idle); a reference's \label, for one, is shown at its float
      nextJump()
      return
    }
    let seq = nextJump()
    lastForwardWord = nil
    // the dot is on the exact letter already: the mark gives the line (band and tick) and leaves the word to the dot
    if !deliberate, let c = pane.caret, !c.approximate, let at = caretAt, at.path == relative(path), at.line == line,
      let row = st.row(page: c.page, x: c.x, y: (c.top + c.bottom) / 2), row.height <= LineMark.maxLine
    {
      jumpDone = true
      pane.reveal(page: c.page, rects: [], lines: [row])
      return
    }
    var k = marks.first ?? 0
    guard let column, let text = sourceLine(path, line) else {
      markRow(rows[k])
      return
    }
    let words = WordMatch.sourceWords(text)
    guard let t = WordMatch.wordIndex(words, column: column) else {
      markRow(rows[k])
      return
    }
    if words.count > 1, marks.count > 1 {
      k = marks[Int((Double(t) / Double(words.count - 1) * Double(marks.count - 1)).rounded())]
    }
    let near = Self.nearRows(st, rows, k)
    // one mark per jump: the mark waits for the word (cached reads take a few ms, the first read of a line ~200 ms)
    // and moves once, band and box together; only a read slower than 350 ms puts the band up first
    let row = rows[k]
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
      MainActor.assumeIsolated {
        guard let self, seq == self.jumpSeq, self.lastForwardWord == nil, !self.jumpDone else { return }
        self.markRow(row)
      }
    }
    jumpDone = false
    Task {
      defer { if seq == self.jumpSeq { self.jumpDone = true } }
      let page = rows[k].page
      var near = near
      var found = await self.read(page: page, rows: near)
      guard seq == self.jumpSeq else { return }
      // the estimate can be further off (a paragraph in a \parbox is broken only at its closing brace, so SyncTeX's
      // marks don't follow the text): then the source line's other typeset lines on the page too
      let rest = rows.filter { $0.page == page && !near.contains($0.rect) }.map(\.rect)
      if WordMatch.forward(source: words, target: t, page: WordMatch.order(found, rows: near)) == nil, !rest.isEmpty {
        near += rest
        near.sort { $0.minY < $1.minY }
        found += await self.read(page: page, rows: rest)
        guard seq == self.jumpSeq else { return }
      }
      if ProcessInfo.processInfo.environment["TAUDOT_WORDS_DEBUG"] != nil {
        FileHandle.standardError.write("words: k \(k) near \(near.map { Int($0.minY) }) page \(WordMatch.order(found, rows: near).map(\.text)) source \(words.map(\.text)) t \(t)\n".data(using: .utf8)!)
      }
      if let m = WordMatch.forward(source: words, target: t, page: WordMatch.order(found, rows: near)) {
        self.lastForwardWord = m.word.text
        self.pane.reveal(page: page, rects: m.word.rects, lines: LineMark.lines(word: m.word.rects, rows: near))
      } else {
        self.markRow(rows[k])
      }
    }
  }

  /// The typeset lines to read for a word estimated on row `k`: it and one either side on the same page (the estimate
  /// is by word count, so it can be one off), and at either end the typeset line before or after too: a source line
  /// can start or end inside one whose records carry another line (a caption is typeset when TeX reads its closing
  /// brace).
  static func nearRows(_ st: SyncTex, _ rows: [SyncTex.Row], _ k: Int) -> [CGRect] {
    var near = rows.indices.filter { abs($0 - k) <= 1 && rows[$0].page == rows[k].page }.map { rows[$0].rect }
    let r = rows[k].rect
    if k == 0, let above = st.row(page: rows[k].page, x: r.midX, y: r.minY - 4), above.maxY <= r.minY + 1 { near.append(above) }
    if k == rows.count - 1, let below = st.row(page: rows[k].page, x: r.midX, y: r.maxY + 4), below.minY >= r.maxY - 1 {
      near.append(below)
    }
    return near
  }

  /// Marks a typeset line with the band alone; a taller row (a figure, a display) with a box, never a band.
  private func markRow(_ r: SyncTex.Row) {
    if r.rect.height <= LineMark.maxLine { pane.reveal(page: r.page, rects: [], lines: [r.rect]) }
    else { pane.reveal(page: r.page, rects: [r.rect]) }
  }

  /// The words on `rows` of `page`: each typeset line read on its own (Vision mixes up lines set close together, as
  /// in captions), in parallel, cached until the page changes.
  private func read(page: Int, rows: [CGRect]) async -> [(raw: String, rect: CGRect)] {
    guard let txp else { return [] }
    // txp-render's glyphs: every word with its exact box (~7 ms a page, once); OCR only without them
    if let g = await glyphPage(page) {
      wordsFromGlyphs += 1
      return rows.flatMap { r in g.words(in: r.insetBy(dx: -3, dy: -2)).map { (raw: $0.raw, rect: $0.rect) } }
    }
    wordsFromOCR += 1
    var out: [(raw: String, rect: CGRect)] = []
    var todo: [(String, CGRect)] = []
    for r in rows {
      let region = r.insetBy(dx: -3, dy: -2)
      let key = "\(region)"
      if let c = pageWords[page]?[key] { out += c } else { todo.append((key, region)) }
    }
    let s = PageText.scale
    let tasks = todo.map { (key, region) in
      Task { () -> (String, [(raw: String, rect: CGRect)]) in
        let x = max(0, Int((region.minX * s).rounded(.down))), y = max(0, Int((region.minY * s).rounded(.down)))
        let w = Int((region.width * s).rounded(.up)), h = Int((region.height * s).rounded(.up))
        self.reads += 1
        self.readsInFlight += 1
        self.readsMaxInFlight = max(self.readsMaxInFlight, self.readsInFlight)
        defer { self.readsInFlight -= 1 }
        guard let img = await txp.render(page: page, scale: s, x: x, y: y, w: w, h: h) else { return (key, []) }
        let drawn = CGRect(x: Double(x) / s, y: Double(y) / s, width: Double(img.width) / s, height: Double(img.height) / s)
        return (key, await Task.detached(priority: .userInitiated) { PageText.words(img, region: drawn, scale: s) }.value)
      }
    }
    var read: [(String, [(raw: String, rect: CGRect)])] = []
    for t in tasks { read.append(await t.value) }
    for (key, words) in read {
      pageWords[page, default: [:]][key] = words
      out += words
    }
    return out
  }

  /// Inverse search from a point of `page` (points from its top-left): what a double-click or Cmd-click does.
  public func syncClick(page: Int, x: Double, y: Double) async {
    guard let st = synctex, let r = st.inverse(page: page, x: x, y: y) else { return }
    if let f = figureAt(st, page: page, x: x, y: y, hit: r) {
      lastInverse = (f.path, f.line, f.column, "figure")
      clickMarked(f.path, f.line)
      if let cb = onInverseSearchWord { cb(f.path, f.line, f.column) } else { onInverseSearch?(f.path, f.line) }
      return
    }
    // the exact letter, from the glyphs (txp-render)
    if await glyphPage(page) != nil, let map = cursorMap,
      let pos = map.source(page: page, x: x, y: y, text: { [weak self] f, l in self?.sourceLine(f, l) }), !pos.approximate
    {
      let path = relative(pos.file)
      if let row = st.row(page: page, x: x, y: y), let g = glyphCache[page],
        let w = g.words(in: CGRect(x: x - 1, y: row.minY, width: 2, height: row.height)).first ?? g.words(in: row).min(by: { abs($0.rect.midX - x) < abs($1.rect.midX - x) })
      {
        pane.reveal(page: page, rects: [w.rect], lines: [row])
      }
      lastInverse = (path, pos.line, pos.column, nil)
      clickMarked(path, pos.line)
      if let cb = onInverseSearchWord { cb(path, pos.line, pos.column) } else { onInverseSearch?(path, pos.line) }
      return
    }
    let path = relative(r.file)
    let w = await inverseWord(st, page: page, x: x, y: y, path: path, line: r.line)
    lastInverse = (path, w?.line ?? r.line, w?.column, w?.word)
    clickMarked(path, w?.line ?? r.line)
    if let cb = onInverseSearchWord { cb(path, w?.line ?? r.line, w?.column) }
    else { onInverseSearch?(path, w?.line ?? r.line) }
  }

  /// The source word under a click: the page word at the point, matched in the clicked source line (else the lines
  /// either side, which can share the typeset line). Flashes the word that was clicked.
  private func inverseWord(_ st: SyncTex, page: Int, x: Double, y: Double, path: String, line: Int) async
    -> (line: Int, column: Int, word: String)?
  {
    guard let row = st.row(page: page, x: x, y: y) else { return nil }
    let found = await read(page: page, rows: [row])
    let words = WordMatch.order(found, rows: [row])
    let hit = words.firstIndex { w in w.rects.contains { $0.insetBy(dx: -1.5, dy: -2).contains(CGPoint(x: x, y: y)) } }
      ?? words.indices.min { abs(words[$0].rects[0].midX - x) < abs(words[$1].rects[0].midX - x) }
    guard let hit else { return nil }
    pane.reveal(page: page, rects: words[hit].rects, lines: LineMark.lines(word: words[hit].rects, rows: [row]))
    let m = matchSource(path: path, near: line, words: words, index: hit)
    let best = m.map { (line: $0.line, column: $0.word.start, word: $0.word.text, score: $0.score) }
    return best.map { ($0.line, $0.column, $0.word) }
  }
}

// ---- review comments as notes on the PDF ----------------------------------------------------------------------------

extension TaudotPDFPane {
  /// The review comments to show (the same items as the review margin), on every change. Resolved ones are hidden.
  /// They are placed now if SyncTeX is in, and again after each typesetting.
  public func setComments(_ c: [PDFComment]) {
    guard c != comments else { return }
    comments = c
    placeComments()
  }

  /// Comments on the PDF: on by default, remembered (UserDefaults `taudot.pdfShowComments`).
  public var showComments: Bool {
    get { pane.notes.shown }
    set { pane.notes.shown = newValue }
  }

  public func toggleComments() { pane.notes.shown.toggle() }

  /// Pulses a comment's note (e.g. when its card is selected).
  public func pulseComment(_ id: String) { pane.notes.pulse(id) }

  /// For tests and benches: where the notes are.
  public var placedNotes: [PlacedNote] { pane.notes.notes }

  private func placeComments() {
    notesGen += 1
    let gen = notesGen
    guard let st = synctex else { pane.notes.set([], comments: comments); return }
    let comments = self.comments
    // SyncTeX lookups scan every page (~10 ms a comment on a 32-page paper): off the main thread
    var text: [String: String] = [:]
    for c in comments where !c.resolved { text["\(c.path)\n\(c.line)"] = sourceLine(c.path, c.line) }
    let lines = text
    let widths = pane.pageSizes.map(\.width)
    let byID = Dictionary(comments.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    Task {
      var placed = await Task.detached(priority: .userInitiated) {
        NotePlacement.place(
          comments, rows: { st.rows(file: $0, line: $1) }, source: { lines["\($0)\n\($1)"] },
          pageWidth: { $0 < widths.count ? widths[$0] : 612 })
      }.value
      guard gen == self.notesGen else { return }
      self.pane.notes.set(placed, comments: comments)
      // then the quoted words, read off the page one comment at a time (cached per page, so cheap once read)
      var changed = false
      for i in placed.indices {
        guard gen == self.notesGen else { return }
        guard let c = byID[placed[i].id] else { continue }
        let q = await self.quoteRects(st, c, page: placed[i].page)
        guard gen == self.notesGen else { return }
        if !q.words.isEmpty { placed[i].words = q.words; changed = true }
        // the note goes beside the line the quote starts on, which the read pins down better than the estimate
        if let l = q.line, l != placed[i].line { placed[i].line = l; changed = true }
      }
      if changed { self.pane.notes.set(NotePlacement.restack(placed), comments: self.comments) }
    }
  }

  /// The quoted words on `page`: the start word (the comment's line and column) to the end word, matched as forward
  /// search matches the cursor's word; just the start word when the end isn't found on that page.
  func quoteRects(_ st: SyncTex, _ c: PDFComment, page: Int,
                  rows look: ((String, Int) -> (rows: [SyncTex.Row], marks: [Int])?)? = nil) async -> (words: [CGRect], line: CGRect?) {
    let rowsOf = look ?? { st.rows(file: $0, line: $1) }
    guard let col = c.column else { return ([], nil) }
    func near(_ line: Int, _ column: Int?) -> (words: [WordMatch.SourceWord], t: Int, rows: [CGRect])? {
      guard let (rows, marks) = rowsOf(c.path, line), let text = sourceLine(c.path, line) else { return nil }
      let words = WordMatch.sourceWords(text)
      guard let t = WordMatch.wordIndex(words, column: column ?? 0) else { return nil }
      let k = NotePlacement.row(marks: marks, words: words, column: column)
      guard k < rows.count, rows[k].page == page else { return nil }
      return (words, t, Self.nearRows(st, rows, k))
    }
    guard let a = near(c.line, col) else { return ([], nil) }
    let endCol = c.endColumn.map { max(0, $0 - 1) }  // exclusive end: the last quoted byte
    let b = endCol.flatMap { near(c.endLine, $0) }
    var rows = a.rows
    if let b {
      // and every typeset line between the two on this page
      let top = a.rows.map(\.minY).min() ?? 0, bottom = b.rows.map(\.maxY).max() ?? 0
      for r in b.rows where !rows.contains(r) { rows.append(r) }
      var y = top
      while y < bottom {
        if let r = st.row(page: page, x: a.rows[0].midX, y: y + 1), !rows.contains(r), r.height <= LineMark.maxLine { rows.append(r); y = r.maxY }
        else { y += 4 }
      }
    }
    rows.sort { $0.minY < $1.minY }
    var found = await read(page: page, rows: rows)
    var ordered = WordMatch.order(found, rows: rows)
    // the row estimate can be further off (a caption, a \parbox): then all of the line's typeset lines on the page
    if WordMatch.forward(source: a.words, target: a.t, page: ordered) == nil, let all = rowsOf(c.path, c.line) {
      let rest = all.rows.filter { $0.page == page && !rows.contains($0.rect) && $0.rect.height <= LineMark.maxLine }.map(\.rect)
      if !rest.isEmpty {
        rows = (rows + rest).sorted { $0.minY < $1.minY }
        found += await read(page: page, rows: rest)
        ordered = WordMatch.order(found, rows: rows)
      }
    }
    guard let s = WordMatch.forward(source: a.words, target: a.t, page: ordered),
      let si = ordered.firstIndex(where: { $0.rects.first == s.word.rects.first })
    else { return ([], nil) }
    var ei = si
    if let b, let e = WordMatch.forward(source: b.words, target: b.t, page: ordered),
      let j = ordered.lastIndex(where: { $0.rects.contains(e.word.rects.last!) }), j >= si, j - si < 400
    {
      ei = j
    }
    let span = NotePlacement.span(page: ordered, from: si, to: ei)
    return (span, LineMark.lines(word: Array(s.word.rects.prefix(1)), rows: rows).first)
  }
}

// ---- selecting text on the PDF to comment on it ---------------------------------------------------------------------

extension TaudotPDFPane {
  /// The typeset lines a drag covers on a page, top to bottom: SyncTeX's line at each end and every line between.
  private func rowsBetween(_ st: SyncTex, page: Int, _ a: CGPoint, _ b: CGPoint) -> [CGRect] {
    let ends = [a, b].compactMap { st.row(page: page, x: $0.x, y: $0.y) }.filter { $0.height <= LineMark.maxLine }
    guard let top = ends.min(by: { $0.minY < $1.minY }), let bottom = ends.max(by: { $0.maxY < $1.maxY }) else { return [] }
    var rows = [top]
    var y = top.maxY + 0.5
    while y < bottom.minY {
      if let r = st.row(page: page, x: top.midX, y: y) ?? st.row(page: page, x: bottom.midX, y: y), r.height <= LineMark.maxLine,
        r.minY >= (rows.last?.maxY ?? 0) - 1
      {
        if !rows.contains(r) { rows.append(r) }
        y = r.maxY + 0.5
      } else {
        y += 1.5
      }
    }
    if !rows.contains(bottom) { rows.append(bottom) }
    return rows.sorted { $0.minY < $1.minY }
  }

  /// A drag on the pages: the lines it covers while it lasts; when it ends, the words, their source range, the pill.
  func select(page: Int, from a: CGPoint, to b: CGPoint, done: Bool) {
    selectGen += 1
    let gen = selectGen
    guard let st = synctex else { return }
    let rows = rowsBetween(st, page: page, a, b)
    guard !rows.isEmpty else { return }
    let (s, e) = SelectionGeometry.ordered(a, b, rows: rows)
    pane.notes.unpin()
    pane.selection.show(page: page, rects: SelectionGeometry.provisional(rows: rows, start: s, end: e))
    guard done else { return }
    let clears = pane.selection.clears, og = openGen
    Task {
      let found = await self.read(page: page, rows: rows)
      guard gen == self.selectGen, clears == self.pane.selection.clears, og == self.openGen else { return }
      let words = WordMatch.order(found, rows: rows)
      guard let (i, j) = SelectionGeometry.pick(words: words, rows: rows, start: s, end: e) else {
        self.pane.selection.clear()
        return
      }
      self.pane.selection.show(page: page, rects: NotePlacement.span(page: words, from: i, to: j))
      guard let start = self.sourceWord(st, page: page, words: words, index: i),
        let end = self.sourceWord(st, page: page, words: words, index: j), start.path == end.path,
        (start.line, start.word.start) < (end.line, end.word.end)
      else {
        self.onStatus?("can't find that text in the source")
        return
      }
      self.pane.selection.offer(PDFCommentDraft(
        path: start.path, line: start.line, column: start.word.start, endLine: end.line, endColumn: end.word.end,
        quote: self.sourceText(start.path, from: (start.line, start.word.start), to: (end.line, end.word.end))))
    }
  }

  /// The source word a page word came from: SyncTeX's line at it, then the word matched among that line's words
  /// (or the lines either side, which can share the typeset line), as a double-click does.
  private func sourceWord(_ st: SyncTex, page: Int, words: [WordMatch.PageWord], index: Int)
    -> (path: String, line: Int, word: WordMatch.SourceWord)?
  {
    // SyncTeX's line at the word, else at its neighbours (a line's first word can have no record under it)
    var hit: (file: String, line: Int)?
    for k in [index, index + 1, index - 1, index + 2, index - 2] where k >= 0 && k < words.count {
      let r = words[k].rects[0]
      if let h = st.inverse(page: page, x: r.midX, y: r.midY) { hit = h; break }
    }
    guard let hit else { return nil }
    let path = relative(hit.file)
    return matchSource(path: path, near: hit.line, words: words, index: index).map { (path, $0.line, $0.word) }
  }

  /// The source word for page word `index`, among the words of SyncTeX's line and the lines around it: a paragraph's
  /// records carry the line where TeX broke it into lines, so a typeset line's words can come from a source line
  /// a few above (a paragraph written one sentence a line), or one below. Closer lines win unless a farther one
  /// matches clearly better.
  func matchSource(path: String, near line: Int, words: [WordMatch.PageWord], index: Int)
    -> (line: Int, word: WordMatch.SourceWord, score: Double)?
  {
    var best: (line: Int, word: WordMatch.SourceWord, score: Double)?
    for d in [0, -1, 1, -2, -3, 2, -4] {
      let l = line + d
      guard l >= 1, let text = sourceLine(path, l),
        let m = WordMatch.inverse(page: words, clicked: index, source: WordMatch.sourceWords(text))
      else { continue }
      if best == nil || m.score > best!.score + (d == 0 ? 0 : 0.5) { best = (l, m.word, m.score) }
      if best?.line == line && best!.score >= 2 { break }
    }
    return best
  }

  /// The source between two (line, byte column) places, its whitespace collapsed.
  private func sourceText(_ path: String, from a: (Int, Int), to b: (Int, Int)) -> String {
    var parts: [String] = []
    for l in a.0...b.0 {
      guard let text = sourceLine(path, l) else { continue }
      let bytes = Array(text.utf8)
      let lo = l == a.0 ? min(a.1, bytes.count) : 0, hi = l == b.0 ? min(b.1, bytes.count) : bytes.count
      if hi > lo { parts.append(String(decoding: bytes[lo..<hi], as: UTF8.self)) }
    }
    return parts.joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }
}

// ---- figures and cross-references -----------------------------------------------------------------------------------

extension TaudotPDFPane {
  /// What TeXpresso was sent of `rel`, as lines (cached until it changes).
  private func cachedLines(_ rel: String) -> [String] {
    if let ls = sourceLinesCache[rel] { return ls }
    let ls = String(decoding: sources[rel] ?? [], as: UTF8.self).components(separatedBy: "\n")
    sourceLinesCache[rel] = ls
    return ls
  }

  /// A source file's lines: what TeXpresso was sent, else the file on disk.
  public func sourceLines(_ path: String) -> [String] {
    let rel = relative(path)
    if sources[rel] != nil { return cachedLines(rel) }
    var bytes = sources[rel]
    if bytes == nil, let folder {
      let url = rel.hasPrefix("/") ? URL(fileURLWithPath: rel) : folder.appendingPathComponent(rel)
      bytes = (try? Data(contentsOf: url)).map { Array($0) }
    }
    guard let bytes else { return [] }
    return String(decoding: bytes, as: UTF8.self).components(separatedBy: "\n")
  }

  /// A double-click on a figure's graphic (where SyncTeX has no line of text, only the figure's box): the figure's
  /// `\includegraphics` line, found in the source around SyncTeX's line or the caption's (the image's box often
  /// carries `\end{figure}` or the paragraph after the float). Flashes the graphic. Nil on text.
  func figureAt(_ st: SyncTex, page: Int, x: Double, y: Double, hit: (file: String, line: Int)) -> (path: String, line: Int, column: Int)? {
    let row = st.row(page: page, x: x, y: y)
    if let row, row.height <= LineMark.maxLine { return nil }  // text: the word under the click
    // where to look: SyncTeX's line here, then the nearest lines of text below and above (a caption)
    var hits = [(relative(hit.file), hit.line)]
    for dir in [1.0, -1.0] {
      var d = 6.0
      while d < 320 {
        let yy = y + dir * d
        if let r = st.row(page: page, x: x, y: yy), r.height <= LineMark.maxLine, let h = st.inverse(page: page, x: r.midX, y: r.midY) {
          hits.append((relative(h.file), h.line))
          break
        }
        d += 4
      }
    }
    for (path, line) in hits {
      let lines = sourceLines(path)
      // no box under the click (a blank spot): only a float that holds the line, not one that ended before it
      guard let env = FloatSource.around(lines, line: line, after: row == nil ? 0 : 4) else { continue }
      let t = FloatSource.target(env, near: line)
      if let row { pane.reveal(page: page, rects: [row]) }
      return (path, t.line, t.column)
    }
    return nil
  }

  /// A click on a cross-reference ("Figure 3", "Table 2", "(4)"): the PDF goes to what it points at and the editor to
  /// its `\label`. The `\ref`-like command is found from the source word just left of the click (or right, at a
  /// line's start), with nothing but reference words between them.
  public func followRef(page: Int, x: Double, y: Double) async {
    let dbg = ProcessInfo.processInfo.environment["TAUDOT_WORDS_DEBUG"] != nil
    func say(_ s: String) { if dbg { FileHandle.standardError.write("ref: \(s)\n".data(using: .utf8)!) } }
    guard let st = synctex, let row = st.row(page: page, x: x, y: y), row.height <= LineMark.maxLine else {
      say("no text row at \(x),\(y): \(String(describing: synctex?.row(page: page, x: x, y: y)))"); return
    }
    // the typeset lines around it too: a reference can start or end its line ("(Figure 3A)." alone on one)
    var rows = [row]
    if let above = st.row(page: page, x: row.midX, y: row.minY - 3), above.maxY <= row.minY + 1, above.height <= LineMark.maxLine { rows.insert(above, at: 0) }
    if let below = st.row(page: page, x: row.midX, y: row.maxY + 3), below.minY >= row.maxY - 1, below.height <= LineMark.maxLine { rows.append(below) }
    let found = await read(page: page, rows: rows)
    let words = WordMatch.order(found, rows: rows)
    say("rows \(rows.count) words \(words.map(\.text))")
    guard let hit = words.firstIndex(where: { w in w.rects.contains { $0.insetBy(dx: -1.5, dy: -2).contains(CGPoint(x: x, y: y)) } }),
      FloatSource.refLike(words[hit].text)
    else { return }
    var at: (file: String, line: Int)?
    for k in [hit, hit - 1, hit + 1, hit - 2, hit + 2] where k >= 0 && k < words.count {
      let r = words[k].rects[0]
      if let h = st.inverse(page: page, x: r.midX, y: r.midY) { at = h; break }
    }
    guard let at else { return }
    let path = relative(at.file)
    var ref: FloatSource.Ref?
    // the nearest real word to the left, then to the right
    if let k = (0..<hit).reversed().first(where: { !FloatSource.refLike(words[$0].text) }), hit - k <= 4,
      let m = matchSource(path: path, near: at.line, words: words, index: k)
    {
      ref = FloatSource.ref(after: m.word.end, line: m.line, in: sourceLines(path))
    }
    if ref == nil, let k = ((hit + 1)..<words.count).first(where: { !FloatSource.refLike(words[$0].text) }), k - hit <= 4,
      let m = matchSource(path: path, near: at.line, words: words, index: k)
    {
      ref = FloatSource.ref(before: m.word.start, line: m.line, in: sourceLines(path))
    }
    say("at \(path):\(at.line) hit \(words[hit].text) ref \(String(describing: ref))")
    guard let ref, let label = findLabel(ref.key, from: path) else { return }
    lastRef = (ref.key, label.path, label.line)
    lastInverse = (label.path, label.line, label.column, ref.key)
    // the PDF: a \label typesets nothing, so in a float its graphic (or first line), else the nearest line around
    // the label that SyncTeX has
    let lines = sourceLines(label.path)
    var candidates: [Int] = []
    if let env = FloatSource.around(lines, line: label.line, after: 0) {
      candidates.append(FloatSource.target(env).line)
      candidates.append(env.begin + 1)
    }
    candidates += [label.line, label.line - 1, label.line - 2, label.line + 1]
    if let l = candidates.first(where: { $0 >= 1 && st.rows(file: label.path, line: $0) != nil }) {
      jump(path: label.path, line: l, column: nil)
    }
    marked(label.path, label.line)  // the editor goes to the \label: the highlight stays while it is there
    onInverseSearchWord?(label.path, label.line, label.column)
  }

  /// `\label{key}` in the project: the clicked file first, then every .tex file in the folder.
  func findLabel(_ key: String, from path: String) -> (path: String, line: Int, column: Int)? {
    var files = [path]
    if let folder, let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
      var n = 0
      for case let u as URL in e where u.pathExtension == "tex" {
        n += 1
        if n > 400 { break }
        let rel = relative(u.path)
        if !files.contains(rel) { files.append(rel) }
      }
    }
    for f in files {
      if let l = FloatSource.label(key, in: sourceLines(f)) { return (f, l.line, l.column) }
    }
    return nil
  }
}

// ---- txp-render's glyphs: exact words, the cursor dot, click-to-letter --------------------------------------------------

extension TaudotPDFPane {
  /// A page's glyphs, read once per version of the page (a page TeXpresso reports changed is read again).
  func glyphPage(_ page: Int) async -> PageGlyphs? {
    guard txp?.hasGlyphs == true, let txp else { return nil }
    if let g = glyphCache[page] { return g }
    if let t = glyphTasks[page] { return await t.value }
    let t = Task { await txp.glyphs(page: page) }
    glyphTasks[page] = t
    let g = await t.value
    if glyphTasks[page] == t {
      glyphTasks[page] = nil
      if let g {
        glyphCache[page] = g
        cursorMap?.setPage(page, g)
      }
    }
    return g
  }

  /// A page came on screen with new content: if the cursor dot is on it, its glyphs at once (the dot moves behind
  /// the new letters); other pages' glyphs are read when something needs them (a click, forward search). While
  /// typing that's one `glyphs` a key otherwise, for nothing in the native editor (no dot).
  func glyphsWanted(_ page: Int) {
    guard txp?.hasGlyphs == true, caretAt != nil, pane.caret?.page == page || pane.caret == nil,
      glyphCache[page] == nil, glyphTasks[page] == nil
    else { return }
    Task {
      _ = await glyphPage(page)
      placeCaret()
    }
  }

  func pagesChangedForGlyphs(_ e: PagesEvent) {
    if !e.changed.isEmpty { glyphEpoch += 1 }
    for i in e.changed {
      glyphCache[i] = nil
      glyphTasks[i] = nil
    }
    if let map = cursorMap {
      map.update(synctex: map.synctex, changed: e.changed, count: e.n > 0 && !e.display ? e.n : nil)  // (a display page's n: through it)
    }
  }

  /// New SyncTeX (after a typeset): the cursor map follows it; the glyphs of the pages in view are read.
  func synctexForCursor(_ text: String) {
    guard txp?.hasGlyphs == true else { return }
    let og = openGen
    Task {
      let st = await Task.detached(priority: .userInitiated) { TaudotCursor.SyncTeX(text: text) }.value
      guard og == openGen else { return }
      glyphEpoch += 1
      if let map = cursorMap {
        map.update(synctex: st, changed: [])
      } else {
        let map = CursorMap(synctex: st) { _ in nil }  // pages come in through setPage
        for (p, g) in glyphCache { map.setPage(p, g) }
        cursorMap = map
      }
      for p in pane.pagesInView { _ = await glyphPage(p) }
      placeCaret()
    }
  }

  /// The editor's cursor moved, or its line changed (every key): the dot goes to that letter. `column` is a UTF-8
  /// byte offset into `text`, the line as the editor has it now (no typeset needed: between reports the dot is placed
  /// on the page already drawn). Hidden when the line typesets nothing.
  public func showCaret(path: String, line: Int, column: Int, text: String, sentAt: CFTimeInterval? = nil) {
    caretAt = (relative(path), line, column, text)
    caretSentAt = sentAt
    caretWhy = ""
    Latency.shared.section("pdf caret") { placeCaret() }
    // what this key got (for benches and the trace): a dot, a ring, the last dot kept, or hidden and why
    let outcome = !pane.caretVisible ? "hidden:" + (caretWhy.isEmpty ? "nil" : caretWhy.replacingOccurrences(of: " ", with: "-"))
      : caretWhy == "kept" ? "kept" : caretWhy == "estimate" ? "ring-estimate" : pane.caret?.approximate == true ? "ring" : "dot"
    caretOutcomes[outcome, default: 0] += 1
    trace("caret outcome: \(outcome) \(relative(path)):\(line):\(column)")
  }

  /// For benches: how cursor events came out (dot, ring, kept, hidden:<why>).
  public var caretOutcomeCounts: [String: Int] { caretOutcomes }

  /// For benches: the pages whose glyphs are read.
  public var glyphPagesRead: [Int] { glyphCache.keys.sorted() }
  /// For benches: CursorMap's view of a line.
  public func caretDebug(line: Int, column: Int) -> String {
    guard let map = cursorMap, let c = caretAt else { return "no map" }
    return "pages cached \((0..<40).filter { map.page($0) != nil }) " + map.debug(file: c.path, line: line, text: c.text, column: column)
  }
  /// For benches: the cursor map is ready.
  public var placedCursorMap: Bool { cursorMap != nil }

  /// No cursor to show (the editor left the .tex files).
  public func hideCaret() {
    caretAt = nil
    pane.showCaret(nil)
  }

  /// CursorMap's caret, cheaply while typing. Aligning a source line with its page (`Align.run`, letters × letters)
  /// took ~3 ms a key on a paragraph-long line, every key, because each key changes the line's text. The page doesn't
  /// change until the next PDF, so within one glyph epoch the line is aligned once, with the text it had then (the
  /// anchor), and the cursor's column is moved into that text: the dot goes where the new letters will be, which is
  /// what the page shows anyway (pdfpipe, step 3).
  func caretTyping(_ map: CursorMap, _ c: (path: String, line: Int, column: Int, text: String)) -> Caret? {
    let key = "\(c.path):\(c.line)#\(glyphEpoch)"
    if let a = caretAnchor, a.key == key, a.text != c.text {
      if let r = map.caret(file: c.path, line: c.line, text: a.text, column: Self.column(c.column, in: c.text, to: a.text)) {
        return r
      }
    }
    let r = map.caret(file: c.path, line: c.line, text: c.text, column: c.column)
    caretAnchor = r == nil ? nil : (key, c.text)
    return r
  }

  /// Byte column `col` of `new` moved into `old` (the same line before some edits): after the changed span it moves
  /// with the text after it, inside the span it goes to the span's start. Always on a UTF-8 character boundary of `old`.
  nonisolated static func column(_ col: Int, in new: String, to old: String) -> Int {
    let a = Array(old.utf8), b = Array(new.utf8)
    var p = 0
    while p < a.count, p < b.count, a[p] == b[p] { p += 1 }
    var s = 0
    while s < a.count - p, s < b.count - p, a[a.count - 1 - s] == b[b.count - 1 - s] { s += 1 }
    var x: Int
    if col <= p { x = col } else if col >= b.count - s { x = col - (b.count - a.count) } else { x = p }
    x = max(0, min(x, a.count))
    while x > 0, x < a.count, a[x] & 0xC0 == 0x80 { x -= 1 }
    return x
  }

  func placeCaret() {
    guard let c = caretAt else { caretWhy = "no cursor"; pane.showCaret(nil); return }
    guard let map = cursorMap else {
      // no glyphs yet (or txp-headless): the estimate still places a ring
      caretWhy = "no map"
      if ProcessInfo.processInfo.environment["TAUDOT_DOT_FALLBACK"] != "0", notTypeset(c.path, c.line, c.column) == nil,
        let e = estimateCaret(c.path, c.line, c.column)
      {
        caretWhy = "estimate"
        pane.cursorDot.showEstimate(page: e.page, x: e.x, top: e.top, bottom: e.bottom, baseline: e.baseline)
      } else {
        pane.showCaret(nil)
      }
      return
    }
    let caret = caretTyping(map, c)
    if caret == nil { caretWhy = synctex?.rows(file: c.path, line: c.line) == nil ? "no record" : "map nil" }
    // its page's glyphs not read yet: read them, then place it (looked up once per line: a SyncTeX scan)
    let lookup = "\(c.path):\(c.line)#\(glyphEpoch)"
    if caret == nil, caretLookedUp != lookup, let rows = synctex?.rows(file: c.path, line: c.line)?.rows {
      caretLookedUp = lookup
      let missing = Set(rows.map(\.page)).filter { glyphCache[$0] == nil && glyphTasks[$0] == nil }
      if !missing.isEmpty {
        Task {
          var got = false
          for p in missing { if await glyphPage(p) != nil { got = true } }
          // placed again with what came (the lookup stays done for this line and epoch: no loop on a page that
          // can't be read)
          if got, self.caretAt?.path == c.path, self.caretAt?.line == c.line { self.placeCaret() }
        }
      }
    }
    // a page being read again after a typeset: the dot stays where it was until its glyphs are in (no blink)
    // somewhere that typesets nothing (the preamble, a comment, a file not in the document): no dot, not even the last
    if caret == nil, ProcessInfo.processInfo.environment["TAUDOT_DOT_FALLBACK"] != "0", let why = notTypeset(c.path, c.line, c.column) {
      caretWhy = why
      pane.showCaret(nil)
      return
    }
    if caret == nil, pane.caretVisible, let page = pane.caret?.page ?? pane.cursorDot.estimate?.page,
      glyphCache[page] == nil || !glyphTasks.isEmpty
    {
      caretWhy = "kept"
      return
    }
    // nothing from CursorMap: a ring at our best estimate, unless the cursor is somewhere that isn't typeset
    // ($TAUDOT_DOT_FALLBACK=0: hidden, as before, for benches)
    if caret == nil, ProcessInfo.processInfo.environment["TAUDOT_DOT_FALLBACK"] != "0" {
      if let why = notTypeset(c.path, c.line, c.column) { caretWhy = why; pane.showCaret(nil); return }
      if let e = estimateCaret(c.path, c.line, c.column) {
        caretWhy = "estimate"
        pane.cursorDot.showEstimate(page: e.page, x: e.x, top: e.top, bottom: e.bottom, baseline: e.baseline)
        return
      }
    }
    pane.showCaret(caret)
    if let t = caretSentAt, let c = caret {
      trace(String(format: "caret: %@ %.1f ms after the key", c.approximate ? "near" : "exact", (CACurrentMediaTime() - t) * 1000))
    }
  }
}

// ---- the page cache: the last run's pages at open ------------------------------------------------------------------

extension TaudotPDFPane {
  /// At open: the last run's pages, scroll position and SyncTeX from disk, at once; TeXpresso's pages replace them.
  func showCache(folder: URL, main: String) {
    cacheShown = false
    cacheDirty = []
    cacheChanges = [:]
    cacheScales = [:]
    let root = cacheRoot
    guard let idx = PageCache.load(folder, main: main, root: root) else { return }
    cacheStyle = idx.style ?? "white"
    pane.setSizes(idx.sizes.map { CGSize(width: $0[0], height: $0[1]) })
    pane.forgetRenders()  // a reused pane: its pages are another document's, the cached images go up instead
    pane.setViewTop(page: idx.topPage, y: idx.topY)
    cacheShown = true
    for (i, s) in idx.scales.enumerated() { cacheScales[i] = s }
    // the pages in view first, then the rest; decoded off the main thread
    let inView = pane.pagesInView
    let order = inView + (0..<idx.sizes.count).filter { !inView.contains($0) }
    // images in another page style: not shown (and saved again in this one)
    if cacheStyle != pageStyle.rawValue { cacheScales = [:] }
    else { Task {
      for p in order {
        guard let img = await Task.detached(priority: .userInitiated, operation: { PageCache.image(folder, page: p, root: root) }).value else { continue }
        guard self.folder == folder else { return }
        self.pane.showCached(page: p, image: img)
        self.cachePagesShown += 1
        if self.cacheShownAt == 0 && inView.contains(p) { self.cacheShownAt = CACurrentMediaTime(); trace("cache: first page shown") }
      }
    } }
    // SyncTeX: clicks and forward search before this run has its own
    Task {
      guard let text = await Task.detached(priority: .userInitiated, operation: { PageCache.synctex(folder, root: root) }).value else { return }
      let st = await Task.detached(priority: .userInitiated) { SyncTex(text) }.value
      if self.synctex == nil, self.folder == folder, !st.pages.isEmpty { self.synctex = st }
    }
  }

  /// A typeset settled: after 3 s without another, the changed pages go to disk (near the view sharp, the rest small).
  func scheduleCacheSave() {
    guard !cacheOff else { return }
    cacheTask?.cancel()
    cacheTask = Task {
      try? await Task.sleep(for: .seconds(3))
      guard !Task.isCancelled else { return }
      await saveCache()
    }
  }

  func saveCache() async {
    guard let folder, let txp, let main = openedMain else { return }
    let sizes = pane.pageSizes
    guard !sizes.isEmpty else { return }
    let top = pane.viewTop?.page ?? 0
    let t0 = CACurrentMediaTime()
    let style = pageStyle.rawValue
    let root = cacheRoot
    var n = 0
    for p in sizes.indices {
      let want = abs(p - top) <= 2 ? 2.0 : 0.8
      guard cacheDirty.contains(p) || (cacheScales[p] ?? 0) < want else { continue }
      if Task.isCancelled { return }
      let w = Int((sizes[p].width * want).rounded(.up)), h = Int((sizes[p].height * want).rounded(.up))
      let version = cacheChanges[p, default: 0]
      guard let img = await txp.render(page: p, scale: want, x: 0, y: 0, w: w, h: h) else { continue }
      await Task.detached(priority: .utility) {
        if let cg = PageCache.cgImage(img) { PageCache.write(folder, page: p, image: cg, root: root) }
      }.value
      // changed meanwhile (or the pane moved on): the image may be the old page; dirty still, saved next time
      guard self.folder == folder, cacheChanges[p, default: 0] == version else { continue }
      cacheDirty.remove(p)
      cacheScales[p] = want
      n += 1
    }
    if let text = lastSynctexText { await Task.detached(priority: .utility) { PageCache.write(folder, synctex: text, root: root) }.value }
    if style == pageStyle.rawValue { cacheStyle = style }  // every page is now in it
    saveCacheIndex(main: main)
    trace(String(format: "cache: saved %d page(s) in %.0f ms", n, (CACurrentMediaTime() - t0) * 1000))
  }

  func saveCacheIndex(main: String? = nil) {
    guard !cacheOff, let folder, let main = main ?? openedMain, !pane.pageSizes.isEmpty, !cacheScales.isEmpty else { return }
    let top = pane.viewTop
    PageCache.write(folder, index: PageCache.Index(
      main: main, sizes: pane.pageSizes.map { [Double($0.width), Double($0.height)] },
      scales: pane.pageSizes.indices.map { cacheScales[$0] ?? 0 }, topPage: top?.page ?? 0, topY: top?.y ?? 0, saved: Date(),
      style: cacheStyle), root: cacheRoot)
  }
}

// ---- the dot's fallback: a ring at our best estimate -----------------------------------------------------------------

extension TaudotPDFPane {
  /// Why a cursor position typesets nothing (the dot hides there), or nil: in the preamble of the main file, in a
  /// `%` comment, or in a file SyncTeX doesn't know (not part of the document).
  func notTypeset(_ path: String, _ line: Int, _ column: Int) -> String? {
    guard let st = synctex else { return nil }
    return Self.notTypeset(
      inDocument: st.inputs.values.contains(where: { SyncTex.samePath($0, path) }), main: path == openedMainName,
      lines: sourceLines(path), line: line, column: column)
  }

  /// The pure rule: not part of the document; the main file's preamble (up to `\begin{document}`); a `%` comment
  /// (the cursor at or after the `%`, or a line that is only a comment). nil: typeset, the dot belongs there.
  nonisolated static func notTypeset(inDocument: Bool, main: Bool, lines: [String], line: Int, column: Int) -> String? {
    if !inDocument { return "other-file" }
    if main, let b = lines.firstIndex(where: { FloatSource.code($0).contains("\\begin{document}") }), line <= b + 1 { return "preamble" }
    if line >= 1, line <= lines.count {
      let text = lines[line - 1]
      let code = FloatSource.code(text)
      if code.utf8.count <= column && code.utf8.count < text.utf8.count { return "comment" }
      if code.trimmingCharacters(in: .whitespaces).isEmpty && text.contains("%") { return "comment" }
    }
    return nil
  }

  /// Where the cursor's letter most likely is when CursorMap has no answer (a caption, a figure's text, a line not
  /// typeset yet): the typeset line our SyncTeX gives (as forward search picks it, by the cursor's place among the
  /// line's words), and on it the word matched from the page's glyphs when they are read, else the line's start.
  func estimateCaret(_ path: String, _ line: Int, _ column: Int) -> (page: Int, x: Double, top: Double, bottom: Double, baseline: Double)? {
    guard let st = synctex, let (rows, marks) = st.rows(file: path, line: line), !rows.isEmpty else { return nil }
    let text = caretAt?.text ?? sourceLine(path, line) ?? ""
    let words = WordMatch.sourceWords(text)
    var k = NotePlacement.row(marks: marks, words: words, column: column)
    if k >= rows.count { k = 0 }
    let row = rows[k].rect, page = rows[k].page
    var x = row.minX, top = row.minY, bottom = row.maxY
    var baseline = row.maxY - row.height * 0.22
    if row.height > LineMark.maxLine { bottom = top + 10; baseline = top + 8 }
    if let g = glyphCache[page], let t = WordMatch.wordIndex(words, column: column) {
      let near = Self.nearRows(st, rows, k)
      let found = near.flatMap { r in g.words(in: r.insetBy(dx: -3, dy: -2)).map { (raw: $0.raw, rect: $0.rect) } }
      let ordered = WordMatch.order(found, rows: near)
      if let m = WordMatch.forward(source: words, target: t, page: ordered), let r = m.word.rects.first {
        // the letter's share of the word
        let w = words[t], frac = Double(max(0, min(column - w.start, w.end - w.start))) / Double(max(1, w.end - w.start))
        x = r.minX + r.width * frac
        top = r.minY
        bottom = r.maxY
        baseline = r.maxY - r.height * 0.22
      }
    }
    return (page, Double(x), Double(top), Double(bottom), Double(baseline))
  }
}
