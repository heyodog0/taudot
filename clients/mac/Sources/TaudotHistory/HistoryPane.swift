// The sidebar's History tab: the versions (day headings, then each group's time, authors in their colours, what
// changed and its labels), a filter (All History | Labels), and under it the files of the selected range with the
// changed ones marked. Click a version to see its changes; ⇧-click another to compare across both.
// The selection is one soft capsule behind the rows that glides to the version picked, and a range is a paler
// capsule over all its versions that grows and shrinks with ⇧ (instant while a key repeats, and with Reduce Motion).
// Until a range has been made once, a faint line under the list says how.
import AppKit
import TaudotReview
import TaudotShared

@MainActor public final class HistoryPane: NSView, NSTableViewDataSource, NSTableViewDelegate {
  public let filter = NSSegmentedControl(labels: ["All History", "Labels"], trackingMode: .selectOne, target: nil, action: nil)
  let versions = HistoryTable()
  let versionsScroll = NSScrollView()
  let filesTable = HistoryTable()
  let filesScroll = NSScrollView()
  let filesTitle = NSTextField(labelWithString: "")
  let status = NSTextField(wrappingLabelWithString: "")
  let material = NSVisualEffectView()
  let divider = NSView()
  /// The selected version's capsule and the range's (behind the rows, in the version list's coordinates).
  let focusLayer = CALayer()
  let rangeLayer = CALayer()
  /// The hint under the list ("⇧-click or ⇧↑↓ to compare a range").
  let hint = NSTextField(labelWithString: HistoryPane.hintText)
  static let hintText = "⇧-click or ⇧↑↓ to compare a range"
  static let rowTip = "Click to see this version's changes. ⇧-click or ⇧↑↓ to compare a range."
  static let rangeMadeKey = "taudot.history.rangeMade"
  /// Where "a range was made once" is kept (tests: a suite of their own).
  public var defaults: UserDefaults = .standard { didSet { updateHint(animated: false) } }
  private(set) var hintShown = false
  /// The next highlight move glides (false while a key repeats).
  private var glide = true

  /// Clear space at the top for the sidebar's header (its tabs).
  public var topInset: CGFloat = ReviewMarginView.headerHeight { didSet { needsLayout = true } }
  /// Share of the height under the filter that the version list takes.
  public var versionsShare: CGFloat = 0.62

  public var rows: [HistoryRow] = [] { didSet { versions.reloadData(); syncSelection() } }
  public var files: [HistoryFile] = [] { didSet { filesTable.reloadData(); syncFileSelection(); updateFilesTitle() } }
  /// The range shown; with `compareAnchor` set, the span from it to the group clicked last.
  public var selection: HistoryRange? { didSet { syncSelection(); updateFilesTitle() } }
  /// The version the keys move from: the last one picked, or the moving end of a ⇧-extended range.
  public var keyGroup: VersionGroup? {
    didSet {
      updateHighlight(animated: true)
      guard let f = keyGroup, let r = rows.firstIndex(where: { if case .group(let g) = $0 { g.fromV == f.fromV } else { false } }) else { return }
      versions.scrollRowToVisible(r)
    }
  }
  public var selectedFile: String? { didSet { syncFileSelection() } }
  public var colorFor: (HistoryUser) -> NSColor = HistoryColors.margin

  public var onSelectGroup: ((VersionGroup, _ extend: Bool) -> Void)?
  public var onSelectFile: ((HistoryFile) -> Void)?
  public var onFilter: ((Bool) -> Void)?
  public var onLoadMore: (() -> Void)?

  /// A message instead of the lists (loading, an error, no history).
  public var message: String? {
    didSet {
      status.stringValue = message ?? ""
      status.isHidden = message == nil
    }
  }

  public override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    material.material = .sidebar
    material.blendingMode = .behindWindow
    material.state = .followsWindowActiveState
    addSubview(material)
    filter.controlSize = .small
    filter.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    filter.selectedSegment = 0
    filter.target = self
    filter.action = #selector(filterClicked)
    filter.setToolTip("Every version", forSegment: 0)
    filter.setToolTip("Only labelled versions", forSegment: 1)
    addSubview(filter)
    for (t, s) in [(versions, versionsScroll), (filesTable, filesScroll)] {
      let col = NSTableColumn(identifier: .init("c"))
      t.addTableColumn(col)
      t.headerView = nil
      t.backgroundColor = .clear
      t.intercellSpacing = .zero
      t.style = .plain
      t.selectionHighlightStyle = .regular
      t.dataSource = self
      t.delegate = self
      t.target = self
      t.action = #selector(clicked(_:))
      s.documentView = t
      s.drawsBackground = false
      s.hasVerticalScroller = true
      s.autohidesScrollers = true
      s.scrollerStyle = .overlay
      addSubview(s)
    }
    versions.allowsMultipleSelection = false
    versions.wantsLayer = true
    for l in [rangeLayer, focusLayer] {
      l.cornerRadius = 7
      l.opacity = 0
      l.actions = ["contents": NSNull()]
    }
    hint.font = .systemFont(ofSize: 11)
    hint.alignment = .center
    hint.lineBreakMode = .byTruncatingTail
    hint.toolTip = Self.rowTip
    hint.alphaValue = 0
    addSubview(hint)
    versions.onKey = { [weak self] k in self?.key(k) ?? false }
    filesTitle.font = .systemFont(ofSize: 11, weight: .semibold)
    filesTitle.textColor = .secondaryLabelColor
    addSubview(filesTitle)
    divider.wantsLayer = true
    addSubview(divider)
    status.font = .systemFont(ofSize: 12)
    status.textColor = .secondaryLabelColor
    status.alignment = .center
    status.isHidden = true
    addSubview(status)
  }
  required init?(coder: NSCoder) { fatalError() }
  public override var isFlipped: Bool { true }
  public override func updateLayer() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
      focusLayer.backgroundColor = TaudotColor.selection.cgColor
      rangeLayer.backgroundColor = TaudotColor.selection.withAlphaComponent(TaudotColor.selection.alphaComponent * 0.5).cgColor
      hint.textColor = TaudotColor.secondary.withAlphaComponent(0.8)
    }
  }
  public override var wantsUpdateLayer: Bool { true }

  public override func layout() {
    super.layout()
    material.frame = bounds
    filter.sizeToFit()
    let fy = topInset + 6
    filter.frame.origin = NSPoint(x: ((bounds.width - filter.frame.width) / 2).rounded(), y: fy)
    let top = filter.frame.maxY + 8
    let avail = max(0, bounds.height - top)
    let vh = (avail * versionsShare).rounded()
    let hh: CGFloat = hintShown ? 22 : 0
    versionsScroll.frame = NSRect(x: 0, y: top, width: bounds.width, height: vh - hh)
    hint.frame = NSRect(x: 12, y: top + vh - 20, width: bounds.width - 24, height: 16)
    divider.frame = NSRect(x: 12, y: top + vh, width: bounds.width - 24, height: 1)
    filesTitle.sizeToFit()
    filesTitle.frame = NSRect(x: 16, y: top + vh + 8, width: bounds.width - 32, height: filesTitle.frame.height)
    let fTop = filesTitle.frame.maxY + 4
    filesScroll.frame = NSRect(x: 0, y: fTop, width: bounds.width, height: max(0, bounds.height - fTop))
    versions.tableColumns.first?.width = versionsScroll.contentSize.width
    filesTable.tableColumns.first?.width = filesScroll.contentSize.width
    let sh = status.sizeThatFits(NSSize(width: bounds.width - 40, height: 200)).height
    status.frame = NSRect(x: 20, y: top + 24, width: bounds.width - 40, height: sh)
    updateHighlight(animated: false)
  }

  private func updateFilesTitle() {
    let n = files.filter(\.changed).count
    filesTitle.stringValue = files.isEmpty ? "" : (n == 0 ? "No files changed" : n == 1 ? "1 file changed" : "\(n) files changed").uppercased()
    needsLayout = true
  }

  // ---- table ------------------------------------------------------------------------------------------------------

  public func numberOfRows(in t: NSTableView) -> Int { t === versions ? rows.count : files.count }

  public func tableView(_ t: NSTableView, heightOfRow row: Int) -> CGFloat {
    guard t === versions else { return 24 }
    switch rows[row] {
    case .day: return 28
    case .more: return 30
    case .group(let g): return GroupCell.height(g, width: t.bounds.width > 0 ? t.bounds.width : 280)
    }
  }

  public func tableView(_ t: NSTableView, shouldSelectRow row: Int) -> Bool {
    if t === filesTable { return files[row].op != .removed || true }
    if case .group = rows[row] { return true }
    return false
  }

  public func tableView(_ t: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
    let v = HistoryRowView()
    v.capsule = t !== versions  // the versions' capsule is the gliding layer
    return v
  }

  public func tableView(_ t: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
    if t === filesTable {
      let c = FileRowCell()
      c.set(files[row])
      return c
    }
    switch rows[row] {
    case .day(let s):
      let c = DayCell()
      c.label.stringValue = s
      return c
    case .more:
      let c = DayCell()
      c.label.stringValue = "Load older versions…"
      c.label.textColor = .controlAccentColor
      return c
    case .group(let g):
      let c = GroupCell()
      c.set(g, colorFor: colorFor, inRange: inRange(g))
      c.toolTip = Self.rowTip
      return c
    }
  }

  func inRange(_ g: VersionGroup) -> Bool {
    guard let s = selection, s != .of(g) else { return false }
    return g.fromV >= s.fromV && g.toV <= s.toV
  }

  @objc private func clicked(_ t: NSTableView) {
    let row = t.clickedRow
    guard row >= 0 else { return }
    if t === filesTable {
      onSelectFile?(files[row])
      return
    }
    switch rows[row] {
    case .group(let g): onSelectGroup?(g, NSEvent.modifierFlags.contains(.shift))
    case .more: onLoadMore?()
    case .day: break
    }
  }

  /// ↑ ↓ through the versions; with ⇧ the range from where it started grows or shrinks, as in a Finder list.
  func key(_ e: NSEvent) -> Bool {
    guard let s = selection else { return false }
    let groups = rows.compactMap { if case .group(let g) = $0 { g } else { nil } }
    guard let i = keyGroup.flatMap({ f in groups.firstIndex { $0.fromV == f.fromV } })
      ?? groups.firstIndex(where: { $0.toV == s.toV }) ?? groups.firstIndex(where: { $0.fromV == s.fromV }) else { return false }
    glide = !e.isARepeat
    defer { glide = true }
    switch e.keyCode {
    case 125 where i + 1 < groups.count: onSelectGroup?(groups[i + 1], e.modifierFlags.contains(.shift)); return true
    case 126 where i > 0: onSelectGroup?(groups[i - 1], e.modifierFlags.contains(.shift)); return true
    default: return false
    }
  }

  @objc private func filterClicked() { onFilter?(filter.selectedSegment == 1) }

  // ---- the gliding selection and the hint ---------------------------------------------------------------------------

  /// Reduce Motion (the system's, or TAUDOT_REDUCE_MOTION=1; tests set `reduceMotionForTest`).
  nonisolated(unsafe) static var reduceMotionForTest: Bool?
  static var reduceMotion: Bool {
    reduceMotionForTest ?? (NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
      || ProcessInfo.processInfo.environment["TAUDOT_REDUCE_MOTION"] == "1")
  }

  /// The row the keys move from (the moving end), else the range's newest.
  var focusRow: Int? {
    guard let s = selection else { return nil }
    let groups = rows.enumerated().compactMap { i, r -> (Int, VersionGroup)? in if case .group(let g) = r { (i, g) } else { nil } }
    if let k = keyGroup, let f = groups.first(where: { $0.1.fromV == k.fromV && $0.1.fromV >= s.fromV && $0.1.toV <= s.toV }) { return f.0 }
    return groups.first { $0.1.toV == s.toV }?.0
  }

  /// The selection is a range of more than one version.
  var isRange: Bool {
    guard let s = selection else { return false }
    return !rows.contains { if case .group(let g) = $0 { HistoryRange.of(g) == s } else { false } }
  }

  /// Tests: the capsules' frames (in the list's coordinates; nil: not shown).
  var highlightFrames: (focus: CGRect?, range: CGRect?) {
    (focusLayer.opacity > 0 ? focusLayer.frame : nil, rangeLayer.opacity > 0 ? rangeLayer.frame : nil)
  }

  func updateHighlight(animated: Bool) {
    guard let host = versions.layer else { return }
    for l in [rangeLayer, focusLayer] where l.superlayer !== host { host.insertSublayer(l, at: 0) }
    let s = selection
    var rangeRows: [Int] = []
    if let s {
      for (i, r) in rows.enumerated() { if case .group(let g) = r, g.fromV >= s.fromV, g.toV <= s.toV { rangeRows.append(i) } }
    }
    let focus = focusRow.flatMap { $0 < versions.numberOfRows ? versions.rect(ofRow: $0) : nil }
    let range = rangeRows.isEmpty || !isRange ? nil
      : rangeRows.filter { $0 < versions.numberOfRows }.map { versions.rect(ofRow: $0) }.reduce(nil as CGRect?) { acc, r in acc.map { $0.union(r) } ?? r }
    CATransaction.begin()
    let glides = animated && glide && !Self.reduceMotion && window != nil
    if glides {
      CATransaction.setAnimationDuration(0.18)
      CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
    } else {
      CATransaction.setDisableActions(true)
    }
    if let f = focus {
      // from nothing: it appears where it is (a fade, no glide from a corner)
      if focusLayer.opacity == 0 { CATransaction.setDisableActions(true); focusLayer.frame = f.insetBy(dx: 8, dy: 1); CATransaction.setDisableActions(!glides) }
      focusLayer.frame = f.insetBy(dx: 8, dy: 1)
      focusLayer.opacity = 1
    } else {
      focusLayer.opacity = 0
    }
    if let r = range {
      if rangeLayer.opacity == 0, let f = focus { CATransaction.setDisableActions(true); rangeLayer.frame = f.insetBy(dx: 8, dy: 1); CATransaction.setDisableActions(!glides) }
      rangeLayer.frame = r.insetBy(dx: 6, dy: 0)
      rangeLayer.opacity = 1
    } else {
      if let f = focus { rangeLayer.frame = f.insetBy(dx: 8, dy: 1) }
      rangeLayer.opacity = 0
    }
    CATransaction.commit()
  }

  /// The hint shows while one version is selected, until a range has been made once (then never again).
  static func hintShown(selection: HistoryRange?, isRange: Bool, rangeMade: Bool) -> Bool {
    selection != nil && !isRange && !rangeMade
  }

  func updateHint(animated: Bool) {
    if isRange, !defaults.bool(forKey: Self.rangeMadeKey) { defaults.set(true, forKey: Self.rangeMadeKey) }
    let on = Self.hintShown(selection: selection, isRange: isRange, rangeMade: defaults.bool(forKey: Self.rangeMadeKey))
    guard on != hintShown else { return }
    hintShown = on
    if on { needsLayout = true; layoutSubtreeIfNeeded() }
    if animated && window != nil {
      NSAnimationContext.runAnimationGroup({ c in
        c.duration = on ? 0.2 : 0.35
        hint.animator().alphaValue = on ? 1 : 0
      }, completionHandler: { [weak self] in
        MainActor.assumeIsolated { if let self, !self.hintShown { self.needsLayout = true } }  // the list takes the room back
      })
    } else {
      hint.alphaValue = on ? 1 : 0
      needsLayout = true
    }
  }

  private func syncSelection() {
    // The newest group of the range is the selected row; the others in the range are tinted by their cells.
    var set = IndexSet()
    if let s = selection {
      for (i, r) in rows.enumerated() { if case .group(let g) = r, g.toV == s.toV { set.insert(i) } }
    }
    versions.selectRowIndexes(set, byExtendingSelection: false)
    versions.enumerateAvailableRowViews { v, row in
      if case .group(let g) = self.rows[row], let c = v.view(atColumn: 0) as? GroupCell { c.inRange = self.inRange(g) }
    }
    updateHighlight(animated: true)
    updateHint(animated: true)
  }

  private func syncFileSelection() {
    let i = files.firstIndex { $0.finalPath == selectedFile || $0.path == selectedFile }
    filesTable.selectRowIndexes(i.map { IndexSet(integer: $0) } ?? IndexSet(), byExtendingSelection: false)
  }

  public func focus() { window?.makeFirstResponder(versions) }
  public override var acceptsFirstResponder: Bool { true }
  public override func becomeFirstResponder() -> Bool {
    // only if focus is still here a turn later: keys may have moved on (⇧⌘H, then an issue jump to the editor)
    DispatchQueue.main.async { [weak self] in if let self, self.window?.firstResponder === self { self.focus() } }
    return true
  }
}

// ---- colours ----------------------------------------------------------------------------------------------------------

public enum HistoryColors {
  /// As the margin colours an author (ReviewItem.authorColor: Neovim's colour, else one from the user ID); coral for you.
  public static func margin(_ u: HistoryUser) -> NSColor {
    if u.mine { return TaudotColor.coral }
    return ReviewItem(id: "", kind: .comment, author: ReviewUser(id: u.id, name: u.name, initials: u.initials), quote: "",
                      range: ReviewRange(line: 0, col: 0, endLine: 0, endCol: 0)).authorColor
  }
  /// Overleaf's own: hsl(hue, 70%, 50%).
  public static func overleaf(_ u: HistoryUser) -> NSColor {
    let h = u.hue / 360, s = 0.7, l = 0.5
    let v = l + s * min(l, 1 - l)
    return NSColor(calibratedHue: h, saturation: v == 0 ? 0 : 2 * (1 - l / v), brightness: v, alpha: 1)
  }
}

// ---- views ------------------------------------------------------------------------------------------------------------

final class HistoryTable: NSTableView {
  var onKey: ((NSEvent) -> Bool)?
  override func keyDown(with e: NSEvent) {
    if onKey?(e) == true { return }
    super.keyDown(with: e)
  }
  override func validateProposedFirstResponder(_ r: NSResponder, for e: NSEvent?) -> Bool { true }
}

/// The selection as the Files tab draws it: a soft rounded capsule, not the system's blue bar (the version list's
/// is a layer of the pane's that glides between rows: none here).
final class HistoryRowView: NSTableRowView {
  var capsule = true
  override func drawSelection(in dirtyRect: NSRect) {
    guard capsule else { return }
    let r = bounds.insetBy(dx: 8, dy: 1)
    TaudotColor.selection.setFill()
    NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7).fill()
  }
  override var isEmphasized: Bool { get { false } set {} }
}

final class DayCell: NSTableCellView {
  let label = NSTextField(labelWithString: "")
  override init(frame: NSRect) {
    super.init(frame: frame)
    label.font = .systemFont(ofSize: 11, weight: .semibold)
    label.textColor = .secondaryLabelColor
    addSubview(label)
  }
  required init?(coder: NSCoder) { fatalError() }
  override func layout() {
    super.layout()
    label.sizeToFit()
    label.frame.origin = NSPoint(x: 16, y: ((bounds.height - label.frame.height) / 2).rounded() - (isFlipped ? 0 : 2))
  }
}

/// A coloured dot and a name.
final class AuthorChip: NSView {
  let dot = NSView()
  let name = NSTextField(labelWithString: "")
  init(_ u: HistoryUser, color: NSColor) {
    super.init(frame: .zero)
    dot.wantsLayer = true
    dot.layer?.backgroundColor = color.cgColor
    dot.layer?.cornerRadius = 4
    addSubview(dot)
    name.stringValue = u.mine ? "You" : u.name
    name.font = .systemFont(ofSize: 12, weight: .medium)
    name.textColor = .labelColor
    name.lineBreakMode = .byTruncatingTail
    addSubview(name)
  }
  required init?(coder: NSCoder) { fatalError() }
  var width: CGFloat { 14 + ceil((name.stringValue as NSString).size(withAttributes: [.font: name.font!]).width) + 2 }
  override func layout() {
    super.layout()
    dot.frame = NSRect(x: 0, y: ((bounds.height - 8) / 2).rounded(), width: 8, height: 8)
    name.frame = NSRect(x: 12, y: ((bounds.height - name.intrinsicContentSize.height) / 2).rounded(), width: bounds.width - 12, height: name.intrinsicContentSize.height)
  }
}

/// A label's pill: a tag symbol and its text.
final class LabelPill: NSView {
  let text = NSTextField(labelWithString: "")
  let icon = NSImageView()
  init(_ l: HistoryLabel) {
    super.init(frame: .zero)
    wantsLayer = true
    icon.image = NSImage(systemSymbolName: "tag.fill", accessibilityDescription: "Label")
    icon.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
    addSubview(icon)
    text.stringValue = l.comment
    text.font = .systemFont(ofSize: 11, weight: .medium)
    text.lineBreakMode = .byTruncatingTail
    addSubview(text)
    toolTip = [l.comment, l.name.map { "by \($0)" }].compactMap { $0 }.joined(separator: " ")
  }
  required init?(coder: NSCoder) { fatalError() }
  override var wantsUpdateLayer: Bool { true }
  override func updateLayer() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.backgroundColor = TaudotColor.selected.withAlphaComponent(0.25).cgColor
      layer?.cornerRadius = bounds.height / 2
      text.textColor = TaudotColor.text
      icon.contentTintColor = TaudotColor.accent
    }
  }
  var width: CGFloat { min(170, 34 + ceil((text.stringValue as NSString).size(withAttributes: [.font: text.font!]).width)) }
  override func layout() {
    super.layout()
    icon.frame = NSRect(x: 7, y: (bounds.height - 11) / 2, width: 11, height: 11)
    text.frame = NSRect(x: 20, y: ((bounds.height - text.intrinsicContentSize.height) / 2).rounded(), width: bounds.width - 26, height: text.intrinsicContentSize.height)
  }
}

/// A version group: time (and labels) on the first line, the authors, then what changed.
final class GroupCell: NSTableCellView {
  let time = NSTextField(labelWithString: "")
  let summary = NSTextField(labelWithString: "")
  var chips: [AuthorChip] = []
  var pills: [LabelPill] = []
  let rangeBar = NSView()
  var inRange = false { didSet { rangeBar.isHidden = !inRange } }

  static func height(_ g: VersionGroup, width: CGFloat = 280) -> CGFloat {
    // The authors flow as layout() places them.
    let w = width - 34, font = NSFont.systemFont(ofSize: 12, weight: .medium)
    var authorRows = 1, cx: CGFloat = 0
    for u in g.users {
      let cw = min(w, 16 + ceil(((u.mine ? "You" : u.name) as NSString).size(withAttributes: [.font: font]).width))
      if cx > 0 && cx + cw > w { authorRows += 1; cx = 0 }
      cx += cw + 10
    }
    return 10 + 16 + CGFloat(authorRows) * 18 + 17 + (g.labels.isEmpty ? 0 : 22) + 8
  }

  override init(frame: NSRect) {
    super.init(frame: frame)
    time.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    time.textColor = .secondaryLabelColor
    addSubview(time)
    summary.font = .systemFont(ofSize: 11)
    summary.textColor = .secondaryLabelColor
    summary.lineBreakMode = .byTruncatingMiddle
    addSubview(summary)
    rangeBar.wantsLayer = true
    rangeBar.isHidden = true
    addSubview(rangeBar)
  }
  required init?(coder: NSCoder) { fatalError() }
  override var isFlipped: Bool { true }

  func set(_ g: VersionGroup, colorFor: (HistoryUser) -> NSColor, inRange: Bool) {
    time.stringValue = [historyTime(g.end), g.originText].compactMap { $0 }.joined(separator: " · ")
    summary.stringValue = g.summary
    summary.toolTip = (g.paths + g.ops.map { o in o.kind == .rename ? "\(o.path) → \(o.newPath ?? "")" : o.path }).joined(separator: "\n")
    chips.forEach { $0.removeFromSuperview() }
    chips = g.users.map { AuthorChip($0, color: colorFor($0)) }
    chips.forEach(addSubview)
    pills.forEach { $0.removeFromSuperview() }
    pills = g.labels.map(LabelPill.init)
    pills.forEach(addSubview)
    self.inRange = inRange
    needsLayout = true
  }

  override func layout() {
    super.layout()
    let x: CGFloat = 20, w = bounds.width - x - 14
    var y: CGFloat = 8
    time.frame = NSRect(x: x, y: y, width: w, height: 15)
    y += 17
    var cx = x
    var rowY = y
    for c in chips {
      let cw = min(c.width, w)
      if cx > x && cx + cw > x + w { rowY += 18; cx = x }
      c.frame = NSRect(x: cx, y: rowY, width: cw, height: 17)
      cx += cw + 10
    }
    y = rowY + 19
    summary.frame = NSRect(x: x, y: y, width: w, height: 15)
    y += 18
    var px = x
    for p in pills {
      let pw = min(p.width, bounds.width - px - 14)
      p.frame = NSRect(x: px, y: y + 1, width: max(0, pw), height: 18)
      px += pw + 6
    }
    rangeBar.frame = NSRect(x: 10, y: 4, width: 3, height: bounds.height - 8)
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    effectiveAppearance.performAsCurrentDrawingAppearance { rangeBar.layer?.backgroundColor = TaudotColor.accent.cgColor }
  }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    viewDidChangeEffectiveAppearance()
  }
}

/// A file of the range: its name and folder, dimmed when unchanged, with a letter for what happened to it.
final class FileRowCell: NSTableCellView {
  let name = NSTextField(labelWithString: "")
  let badge = NSTextField(labelWithString: "")
  let icon = NSImageView()

  override init(frame: NSRect) {
    super.init(frame: frame)
    name.font = .systemFont(ofSize: 12)
    name.lineBreakMode = .byTruncatingMiddle
    addSubview(name)
    badge.font = .monospacedSystemFont(ofSize: 10, weight: .bold)
    badge.alignment = .center
    addSubview(badge)
    icon.symbolConfiguration = .init(pointSize: 11, weight: .regular)
    addSubview(icon)
  }
  required init?(coder: NSCoder) { fatalError() }

  func set(_ f: HistoryFile) {
    let shown = f.op == .renamed ? "\(f.path) → \(f.finalPath)" : f.finalPath
    name.stringValue = shown
    name.toolTip = shown
    name.textColor = f.changed ? .labelColor : .tertiaryLabelColor
    let (letter, color): (String, NSColor) = switch f.op {
    case .edited: ("M", .systemOrange)
    case .added: ("A", .systemGreen)
    case .renamed: ("R", .systemBlue)
    case .removed: ("D", .systemRed)
    case nil: ("", .clear)
    }
    badge.stringValue = letter
    badge.textColor = color
    if f.op == .removed {
      name.attributedStringValue = NSAttributedString(string: shown, attributes: [
        .strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: NSColor.secondaryLabelColor, .font: name.font!,
      ])
    }
    let symbol = !f.editable ? "photo" : f.finalPath.hasSuffix(".bib") ? "books.vertical" : "doc.text"
    icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    icon.contentTintColor = f.changed ? .secondaryLabelColor : .tertiaryLabelColor
  }

  override func layout() {
    super.layout()
    let h = name.intrinsicContentSize.height
    icon.frame = NSRect(x: 18, y: (bounds.height - 14) / 2, width: 14, height: 14)
    badge.frame = NSRect(x: bounds.width - 30, y: ((bounds.height - 14) / 2).rounded(), width: 16, height: 14)
    name.frame = NSRect(x: 38, y: ((bounds.height - h) / 2).rounded(), width: bounds.width - 38 - 34, height: h)
  }
}
