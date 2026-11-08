// History on the PDF: the paper as it was at the selected version (or at the end of a compared range), typeset by the
// project's typesetter on a pane of its own, with the range's changes marked on its pages in their authors' colours.
// A bar on top switches between it and the current PDF. A mark clicked selects that change in the diff view, and the
// diff view's current change is outlined on the pages.
import AppKit
import TaudotPDF
import TaudotShared

@MainActor public final class HistoryPDFController {
  public let pdf: TaudotPDFPane
  public let view: HistoryPDFView
  public let source: HistorySource
  /// The project folder (unchanged files and figures are copied from it).
  public let project: URL
  public var mainFile: String?
  /// The project's typesetter (the main PDF pane's), so the version is typeset as the paper is.
  public var engine: EngineChoice?
  public var colorFor: (HistoryUser) -> NSColor = HistoryColors.margin
  /// A mark was clicked: the change's file and its index in that file's diff (`HistoryDiff.changes`).
  public var onPickChange: ((_ path: String, _ index: Int) -> Void)?
  /// The bar's switch: true shows the current PDF (the app's own pane, under this one).
  public var onShowCurrent: ((Bool) -> Void)?
  /// Something went wrong (the status bar shows it).
  public var onError: ((String) -> Void)?
  /// The bar's previous/next change buttons (or ⌥↑/⌥↓ on the pages): -1 or 1 (the diff view steps, the PDF follows).
  public var onStep: ((Int) -> Void)? {
    get { view.onStep }
    set { view.onStep = newValue }
  }

  public private(set) var version: Int?
  public private(set) var range: HistoryRange?
  public private(set) var changes: [PDFChange] = []
  /// Binary files of the version that are today's copies (changed since).
  public private(set) var binaryToday: [String] = []
  public private(set) var showingCurrent = false
  private var task: Task<Void, Never>?
  private var selected: String?
  /// The change outlined on the pages ("path#index").
  public var selectedChange: String? { selected }

  /// `cacheRoot`: the PDF pane's page cache (tests give their own; nil: the app's).
  public init(source: HistorySource, project: URL, mainFile: String?, cacheRoot: URL? = nil) {
    pdf = TaudotPDFPane(cacheRoot: cacheRoot)
    self.source = source
    self.project = project
    self.mainFile = mainFile
    view = HistoryPDFView(pdf: pdf.view)
    view.onMode = { [weak self] current in self?.setShowingCurrent(current) }
    pdf.onChangeClick = { [weak self] id in
      guard let self, let (p, i) = Self.split(id) else { return }
      self.selected = id
      self.onPickChange?(p, i)
    }
    pdf.onStatus = { [weak self] s in self?.typesetterStatus(s) }
    pdf.onChangesPlaced = { [weak self] in self?.placedStatus() }
  }

  static func id(_ path: String, _ index: Int) -> String { "\(path)#\(index)" }
  public static func split(_ id: String) -> (String, Int)? {
    guard let h = id.lastIndex(of: "#"), let i = Int(id[id.index(after: h)...]) else { return nil }
    return (String(id[..<h]), i)
  }

  func setShowingCurrent(_ on: Bool) {
    showingCurrent = on
    view.showingCurrent = on
    onShowCurrent?(on)
  }

  /// A range was picked (its files from history's tree): the PDF at its end, with its changes. `head`: the newest
  /// version, so files unchanged since can be copied rather than fetched.
  public func show(_ r: HistoryRange, files: [HistoryFile], head: Int?) {
    guard r != range else { return }
    range = r
    task?.cancel()
    task = Task { [weak self] in
      guard let self else { return }
      do {
        if version != r.toV {
          view.status = "Getting version \(r.toV)…"
          pdf.setChanges([])
          let made = try await VersionFolder.make(source: source, project: project, version: r.toV, files: files, head: head)
          if Task.isCancelled || range != r { return }
          binaryToday = made.binaryToday
          version = r.toV
          let main = mainFile.flatMap { FileManager.default.fileExists(atPath: made.folder.appendingPathComponent($0).path) ? $0 : nil }
            ?? TaudotPDFPane.findMain(in: made.folder) ?? "main.tex"
          view.status = "Typesetting version \(r.toV)…"
          pdf.openVersion(folder: made.folder, main: main, engine: engine)
          view.fadeIn()
        }
        let c = try await collect(r, files: files)
        if Task.isCancelled || range != r { return }
        changes = c
        pdf.setChanges(c)
        if pdf.versionSaved || pdf.syncTex != nil { placedStatus() }
      } catch {
        if Task.isCancelled { return }
        if range == r { range = nil }  // not shown: the same range asked again tries again
        view.status = "Couldn't get version \(r.toV)"
        onError?("history: version \(r.toV): \(error)")
      }
    }
  }

  /// Every change of the range in the version's text files.
  func collect(_ r: HistoryRange, files: [HistoryFile]) async throws -> [PDFChange] {
    var out: [PDFChange] = []
    for f in files where f.editable && f.changed && f.op != .removed {
      let d = try await source.diff(path: f.finalPath, r)
      if Task.isCancelled { return [] }
      for c in d.version().changes {
        let u = c.user
        out.append(PDFChange(
          id: Self.id(f.finalPath, c.index), kind: c.kind == .delete ? .delete : .insert, path: f.finalPath,
          line: c.line, column: c.column, endLine: c.endLine, endColumn: c.endColumn, text: c.text,
          author: u.map { $0.mine ? "you" : $0.name } ?? "someone", color: u.map(colorFor) ?? .systemGray, time: c.time))
      }
    }
    return out
  }

  /// The diff view's current change: outlined on the pages and scrolled to.
  public func select(path: String, index: Int?) {
    let id = index.map { Self.id(path, $0) }
    guard id != selected || id == nil else { return }
    selected = id
    pdf.selectChange(id)
  }

  /// Forward search from the diff: the place in the version's PDF (the version's PDF shown, if the current one was).
  public func forward(path: String, line: Int, column: Int) {
    if showingCurrent { setShowingCurrent(false) }
    pdf.jump(path: path, line: line, column: column)
  }

  /// History closed: the version's typesetter stops (its folder and PDF stay for next time).
  public func close() {
    task?.cancel()
    pdf.close()
    pdf.setChanges([])
    range = nil
    version = nil
    selected = nil
  }

  private func typesetterStatus(_ s: String) {
    guard let v = version else { return }
    if pdf.changesPlaced { return }
    // the typesetter's own words while it works ("3 pages, page in view in 120 ms", "TeX Live 2025: fetching …")
    view.status = "Version \(v) · " + s
  }

  private func placedStatus() {
    guard let v = version, pdf.changesPlaced else { return }
    let on = Set(pdf.placedChanges.map(\.id))
    let n = changes.count, off = changes.filter { !on.contains($0.id) }.count
    var s = "Version \(v) · " + (n == 0 ? "no changes to the text" : n == 1 ? "1 change" : "\(n) changes")
    if off > 0 { s += off == n ? ", none on the pages" : ", \(off) not on the pages" }
    if !binaryToday.isEmpty { s += " · figures as they are today" }
    view.status = s
    view.statusTip = off > 0 ? "Changes outside the typeset text (the preamble, comments, macros) have no place on the pages." : nil
  }
}

/// The version's pane under a slim bar: "With changes | Current PDF" and what it shows.
@MainActor public final class HistoryPDFView: NSView {
  public let bar = NSVisualEffectView()
  public let mode = NSSegmentedControl(labels: ["With changes", "Current PDF"], trackingMode: .selectOne, target: nil, action: nil)
  let label = NSTextField(labelWithString: "")
  let line = NSView()
  public let prevButton = NSButton()
  public let nextButton = NSButton()
  public let content: NSView
  var onMode: ((Bool) -> Void)?
  var onStep: ((Int) -> Void)?
  static let barHeight: CGFloat = 34

  public var status: String {
    get { label.stringValue }
    set { label.stringValue = newValue; label.toolTip = newValue }
  }
  var statusTip: String? { didSet { if let t = statusTip { label.toolTip = status + "\n" + t } } }

  /// "Current PDF": the version's pane hides and clicks below the bar go through to the app's own pane.
  public var showingCurrent = false {
    didSet {
      content.isHidden = showingCurrent
      mode.selectedSegment = showingCurrent ? 1 : 0
    }
  }

  init(pdf: NSView) {
    content = pdf
    super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
    addSubview(content)
    bar.material = .headerView
    bar.blendingMode = .withinWindow
    addSubview(bar)
    mode.controlSize = .small
    mode.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    mode.selectedSegment = 0
    mode.setToolTip("This version's PDF, its changes marked", forSegment: 0)
    mode.setToolTip("The PDF as it is now", forSegment: 1)
    mode.target = self
    mode.action = #selector(modeChanged)
    bar.addSubview(mode)
    for (b, sym, tip, sel) in [(prevButton, "chevron.up", "Previous change (⌥↑)", #selector(prev)), (nextButton, "chevron.down", "Next change (⌥↓)", #selector(next))] {
      b.bezelStyle = .accessoryBarAction
      b.isBordered = false
      b.image = NSImage(systemSymbolName: sym, accessibilityDescription: tip)
      b.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
      b.contentTintColor = .secondaryLabelColor
      b.toolTip = tip
      b.target = self
      b.action = sel
      bar.addSubview(b)
    }
    label.font = .systemFont(ofSize: 11)
    label.textColor = .secondaryLabelColor
    label.lineBreakMode = .byTruncatingTail
    bar.addSubview(label)
    line.wantsLayer = true
    bar.addSubview(line)
  }
  required init?(coder: NSCoder) { fatalError() }

  public override var isFlipped: Bool { true }

  @objc func modeChanged() { onMode?(mode.selectedSegment == 1) }

  /// Another version: its pages fade in.
  func fadeIn() {
    guard window != nil else { return }
    content.alphaValue = 0.2
    NSAnimationContext.runAnimationGroup { c in
      c.duration = 0.22
      c.timingFunction = CAMediaTimingFunction(name: .easeOut)
      content.animator().alphaValue = 1
    }
  }
  @objc func prev() { onStep?(-1) }
  @objc func next() { onStep?(1) }

  /// ⌥↑/⌥↓ on the version's pages: the previous/next change.
  public override func performKeyEquivalent(with e: NSEvent) -> Bool {
    if e.modifierFlags.intersection([.command, .control, .option, .shift]) == .option, !showingCurrent,
       let r = window?.firstResponder as? NSView, r.isDescendant(of: self) {
      if e.keyCode == 125 { onStep?(1); return true }
      if e.keyCode == 126 { onStep?(-1); return true }
    }
    return super.performKeyEquivalent(with: e)
  }

  public override func layout() {
    super.layout()
    let h = Self.barHeight
    bar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: h)
    content.frame = NSRect(x: 0, y: h, width: bounds.width, height: max(0, bounds.height - h))
    mode.sizeToFit()
    mode.frame.origin = NSPoint(x: 10, y: ((h - mode.frame.height) / 2).rounded())
    nextButton.frame = NSRect(x: bounds.width - 10 - 24, y: (h - 24) / 2, width: 24, height: 24)
    prevButton.frame = NSRect(x: nextButton.frame.minX - 26, y: (h - 24) / 2, width: 24, height: 24)
    label.sizeToFit()
    let lx = mode.frame.maxX + 12
    label.frame = NSRect(x: lx, y: ((h - label.frame.height) / 2).rounded(), width: max(0, prevButton.frame.minX - 8 - lx), height: label.frame.height)
    line.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1)  // (the bar isn't flipped)
    line.layer?.backgroundColor = NSColor.separatorColor.cgColor
  }

  public override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    line.layer?.backgroundColor = NSColor.separatorColor.cgColor
  }

  /// Showing the current PDF, only the bar takes clicks.
  public override func hitTest(_ p: NSPoint) -> NSView? {
    let v = super.hitTest(p)
    if showingCurrent, v === self { return nil }
    return v
  }
}
