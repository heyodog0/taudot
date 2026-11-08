// History's state and the two views it drives: the sidebar pane (versions, files) and the diff in the editor column.
// Picking a version shows its own changes; ⇧-picking another compares across both (Overleaf's Compare). The file shown
// stays the same across versions when it changed there, else the first changed .tex (autoSelectFile).
import AppKit
import TaudotShared

@MainActor public final class HistoryController {
  public let source: HistorySource
  public let pane = HistoryPane(frame: NSRect(x: 0, y: 0, width: 280, height: 600))
  public let diffView = HistoryDiffView(frame: NSRect(x: 0, y: 0, width: 700, height: 600))
  /// The project's main file, picked when nothing else is.
  public var mainFile: String?
  public var colorFor: (HistoryUser) -> NSColor = HistoryColors.margin {
    didSet {
      pane.colorFor = colorFor
      diffView.colorFor = colorFor
      refreshRows()
      diffView.render()
    }
  }
  /// Leave History (the app switches the sidebar back and hides the diff).
  public var onBack: (() -> Void)? {
    get { diffView.onBack }
    set { diffView.onBack = newValue }
  }
  /// Something went wrong (the status bar shows it).
  public var onError: ((String) -> Void)?

  public private(set) var groups: [VersionGroup] = []
  public private(set) var nextBefore: Int?
  public private(set) var range: HistoryRange?
  /// The group a comparison starts from (the one clicked before ⇧-click).
  public private(set) var anchor: VersionGroup?
  public private(set) var files: [HistoryFile] = []
  public private(set) var file: HistoryFile?
  public private(set) var labelsOnly = false
  /// The newest version (from the last page of versions).
  public private(set) var head: Int?
  /// A range's files are in (the PDF follows).
  public var onRange: ((HistoryRange, [HistoryFile], Int?) -> Void)?
  /// The range `files` belong to: differs from `range` while a picked range's tree is loading.
  public private(set) var filesRange: HistoryRange?
  private var loading: Task<Void, Never>?
  /// A range's tree (then its first diff). Only a new range cancels it.
  private var loadingTree: Task<Void, Never>?
  /// One file's diff in the current range. Picks and mark clicks replace it; they never cancel the tree.
  private var loadingDiff: Task<Void, Never>?
  private var treeLoading: Bool { filesRange != range }

  public init(source: HistorySource, mainFile: String? = nil) {
    self.source = source
    self.mainFile = mainFile
    pane.onSelectGroup = { [weak self] g, extend in self?.select(g, extend: extend) }
    pane.onSelectFile = { [weak self] f in self?.pick(f) }
    pane.onFilter = { [weak self] on in
      self?.labelsOnly = on
      self?.refreshRows()
    }
    pane.onLoadMore = { [weak self] in self?.loadMore() }
    diffView.onStepPast = { [weak self] by in self?.stepFile(by) ?? false }
  }

  /// The files whose changes the next/previous arrows go through, in the files list's order.
  var changedFiles: [HistoryFile] { files.filter { $0.changed && $0.editable } }

  /// Next/previous past a file's last (first) change: the next (previous) changed file, at its first (last) change.
  /// False when there's no other file (the arrows wrap in this one).
  func stepFile(_ by: Int) -> Bool {
    let fs = changedFiles
    guard !treeLoading, fs.count > 1, let r = range, let cur = file, let i = fs.firstIndex(of: cur) else { return false }
    let f = fs[(i + by + fs.count) % fs.count]
    loadingDiff?.cancel()
    loadingDiff = Task { [weak self] in
      guard let self else { return }
      await self.showDiff(f, r)
      guard let d = self.diffView.diff, self.file == f, !d.changes.isEmpty else { return }
      self.diffView.select(by > 0 ? 0 : d.changes.count - 1)
    }
    return true
  }

  /// History came on screen: fetch the newest versions (again, so new ones show), keep what was selected, else pick
  /// the newest.
  public func activate() {
    loading?.cancel()
    if groups.isEmpty { pane.message = "Loading history…" }
    loading = Task { [weak self] in
      guard let self else { return }
      do {
        let page = try await source.updates(before: nil)
        if Task.isCancelled { return }
        merge(page.groups, newest: true)
        if let h = page.head { head = h }
        if nextBefore == nil || groups.count <= page.groups.count { nextBefore = page.nextBefore }
        pane.message = groups.isEmpty ? "No history yet." : nil
        refreshRows()
        if range == nil, let g = groups.first { select(g, extend: false) }
      } catch {
        if Task.isCancelled { return }
        pane.message = "Couldn't load the history.\n\(error)"
        onError?("history: \(error)")
      }
    }
  }

  public func loadMore() {
    guard let before = nextBefore else { return }
    loading?.cancel()
    loading = Task { [weak self] in
      guard let self else { return }
      do {
        let page = try await source.updates(before: before)
        merge(page.groups, newest: false)
        nextBefore = page.nextBefore
        refreshRows()
      } catch {
        onError?("history: \(error)")
      }
    }
  }

  /// New groups in, by version, newest first. A group that grew (the newest one, as edits arrive) replaces the old.
  func merge(_ new: [VersionGroup], newest: Bool) {
    var byFrom: [Int: VersionGroup] = [:]
    for g in groups { byFrom[g.fromV] = g }
    for g in new { byFrom[g.fromV] = g }
    groups = byFrom.values.sorted { $0.toV > $1.toV }
    // Drop groups that a newer, wider one now covers.
    var out: [VersionGroup] = []
    for g in groups where !out.contains(where: { $0.fromV <= g.fromV && $0.toV >= g.toV }) { out.append(g) }
    groups = out
    // The selected range follows its group when it grew.
    if let r = range, anchor == nil, let g = groups.first(where: { $0.fromV == r.fromV }), g.toV != r.toV { range = .of(g) }
    // The picks are kept as groups: the same groups as they are now (one that grew, or the wider one covering it), so
    // a later ⇧-pick compares up to where they end now.
    func current(_ g: VersionGroup) -> VersionGroup? {
      groups.first { $0.fromV == g.fromV } ?? groups.first { $0.fromV <= g.fromV && $0.toV >= g.toV }
    }
    if let a = anchorPick { anchorPick = current(a) ?? a }
    if let a = anchor { anchor = current(a) ?? a }
  }

  func refreshRows() {
    pane.rows = HistoryRows.build(groups, labelsOnly: labelsOnly, hasMore: nextBefore != nil)
    pane.selection = range
  }

  /// Show a group's changes, or with `extend` the span from the last plain pick to it.
  public func select(_ g: VersionGroup, extend: Bool) {
    if extend, let a = anchorPick {
      anchor = a
      range = .union(a, g)
    } else {
      anchorPick = g
      anchor = nil
      range = .of(g)
    }
    pane.selection = range
    pane.keyGroup = g
    loadTree()
  }
  /// The last group picked without ⇧, where a comparison starts.
  private var anchorPick: VersionGroup?

  private func loadTree() {
    guard let r = range else { return }
    loadingTree?.cancel()
    loadingDiff?.cancel()
    loadingTree = Task { [weak self] in
      guard let self else { return }
      do {
        let fs = try await source.tree(r)
        if Task.isCancelled || range != r { return }
        files = fs.sorted { ($0.changed ? 0 : 1, $0.finalPath) < ($1.changed ? 0 : 1, $1.finalPath) }
        filesRange = r
        pane.files = files
        onRange?(r, files, head)
        let previous = file?.finalPath
        guard let f = autoSelectFile(files, previous: previous, main: mainFile) else {
          diffView.showMessage("No files at this version.")
          return
        }
        loadingDiff?.cancel()
        loadingDiff = Task { [weak self] in await self?.showDiff(f, r) }
      } catch {
        if Task.isCancelled { return }
        diffView.showMessage("Couldn't load this version.\n\(error)")
      }
    }
  }

  /// A change of the range (a mark clicked on the PDF): its file in the diff view, and the change selected there.
  public func showChange(path: String, index: Int) {
    // While a new range's tree loads, the marks on screen are the old range's: their index means nothing here.
    guard let r = range, !treeLoading else { return }
    if diffView.diff?.path == path {
      diffView.select(index)
      return
    }
    guard let f = files.first(where: { $0.finalPath == path }) else { return }
    loadingDiff?.cancel()
    loadingDiff = Task { [weak self] in
      guard let self else { return }
      await self.showDiff(f, r)
      if self.diffView.diff?.path == path { self.diffView.select(index) }
    }
  }

  /// Show another file of the range.
  public func pick(_ f: HistoryFile) {
    guard let r = range else { return }
    if treeLoading {
      // A row of the old list: remember it as the file to keep when the new tree lands (autoSelectFile's previous).
      file = f
      pane.selectedFile = f.finalPath
      return
    }
    loadingDiff?.cancel()
    loadingDiff = Task { [weak self] in await self?.showDiff(f, r) }
  }

  private func showDiff(_ f: HistoryFile, _ r: HistoryRange) async {
    file = f
    pane.selectedFile = f.finalPath
    var sub = subtitle(r)
    if f.op == .renamed { sub = "Renamed from \(f.path) · " + sub }
    if f.op == .added { sub = "Added · " + sub }
    if !f.editable {
      diffView.showMessage("\(f.finalPath) isn't a text file, so there's no text to compare.", title: f.finalPath, subtitle: sub)
      return
    }
    // A removed file: its text up to the version it went (the range's end no longer has it).
    let rr = f.op == .removed ? HistoryRange(fromV: r.fromV, toV: max(r.fromV, (f.deletedAtV ?? r.toV))) : r
    do {
      let d = try await source.diff(path: f.op == .removed ? f.path : f.finalPath, rr)
      if Task.isCancelled || range != r { return }
      diffView.show(d, subtitle: sub)
    } catch {
      if Task.isCancelled { return }
      diffView.showMessage("Couldn't load \(f.finalPath) at this version.\n\(error)", title: f.finalPath, subtitle: sub)
    }
  }

  /// "Changes at 3:42 PM by Bob and you", or comparing: "Changes from 1 Nov, 2:10 PM to Today 3:42 PM".
  func subtitle(_ r: HistoryRange) -> String {
    let inRange = groups.filter { $0.fromV >= r.fromV && $0.toV <= r.toV }
    guard let newest = inRange.first, let oldest = inRange.last else { return "Versions \(r.fromV)–\(r.toV)" }
    var names: [String] = []
    for g in inRange { for u in g.users { let n = u.mine ? "you" : u.name; if !names.contains(n) { names.append(n) } } }
    let who = names.count <= 1 ? (names.first ?? "") : names.dropLast().joined(separator: ", ") + " and " + names.last!
    if inRange.count == 1 {
      return "Changes \(historyDateTime(newest.end)) by \(who)"
    }
    return "Changes from \(historyDateTime(oldest.start)) to \(historyDateTime(newest.end)) by \(who)"
  }
}
