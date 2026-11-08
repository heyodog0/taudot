// The sidebar's Files tab, quiet and on the sidebar's glass: the project's name on top, then the root's files, then a
// section per folder ("figures/plots", collapsible), each file a monochrome glyph and its name. Click or Return
// opens a file in Neovim (images: Quick Look); right-click or the row's "•••" for New File, New Folder, Rename,
// Move to Trash, Reveal in Finder. Follows the disk (FSEvents) and Neovim (the current file is the pill).
import AppKit
import CoreServices
import Quartz

// ---- the rows (pure) ------------------------------------------------------------------------------------------------

/// What the list shows, top to bottom.
public enum FileRow: Equatable {
  case project(String)
  /// A folder's section: its path from the root ("figures/plots"), collapsed or not, how many files it holds.
  case section(FileNode, collapsed: Bool, count: Int)
  case file(FileNode)

  public static func == (a: FileRow, b: FileRow) -> Bool {
    switch (a, b) {
    case let (.project(x), .project(y)): x == y
    case let (.section(x, c1, n1), .section(y, c2, n2)): x.rel == y.rel && c1 == c2 && n1 == n2
    case let (.file(x), .file(y)): x.rel == y.rel
    default: false
    }
  }
  public var node: FileNode? {
    switch self {
    case .project: nil
    case let .section(n, _, _), let .file(n): n
    }
  }

  /// The project row, the root's files, then every folder depth-first as a section of its own files. A collapsed
  /// section hides its files and the sections inside it.
  public static func build(_ tree: FileTree, collapsed: Set<String>) -> [FileRow] {
    var out: [FileRow] = [.project(tree.root.name)]
    func files(_ n: FileNode) -> [FileNode] { tree.children(n).filter { !$0.isDirectory } }
    for f in files(tree.root) { out.append(.file(f)) }
    func walk(_ dir: FileNode) {
      for d in tree.children(dir) where d.isDirectory {
        let fs = files(d)
        let c = collapsed.contains(d.rel)
        out.append(.section(d, collapsed: c, count: fs.count))
        if c { continue }
        for f in fs { out.append(.file(f)) }
        walk(d)
      }
    }
    walk(tree.root)
    return out
  }
}

/// Per file (path from the root): open comment threads, and the collaborators in it now (gui.lua's taudot_files).
public struct FileBadges: Equatable, Sendable {
  public struct Person: Equatable, Sendable {
    public var name: String
    public var initials: String
    public var color: String?
    public init(name: String, initials: String, color: String?) {
      self.name = name
      self.initials = initials
      self.color = color
    }
  }
  public var comments: [String: Int] = [:]
  public var people: [String: [Person]] = [:]
  public init(comments: [String: Int] = [:], people: [String: [Person]] = [:]) {
    self.comments = comments
    self.people = people
  }
}

extension FileNode {
  /// The row's glyph (monochrome): doc.text, books.vertical, photo, gearshape, doc.richtext (.pdf), doc.
  public var glyph: String {
    if url.pathExtension.lowercased() == "pdf" { return "doc.richtext" }
    return symbol
  }
}

// ---- the views ----------------------------------------------------------------------------------------------------

/// After the name: a dot in the colour of a collaborator who is in the file, and the open comments' count.
final class BadgeView: NSView {
  let person = NSView()
  let bubble = NSImageView()
  let count = NSTextField(labelWithString: "")
  var personColor: NSColor? { didSet { person.isHidden = personColor == nil; needsDisplay = true; needsLayout = true } }
  var comments = 0 { didSet { bubble.isHidden = comments == 0; count.isHidden = comments == 0; count.stringValue = "\(comments)"; needsLayout = true } }
  override init(frame: NSRect) {
    super.init(frame: frame)
    person.wantsLayer = true
    person.layer?.cornerRadius = 3.5
    person.isHidden = true
    bubble.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "comments")
    bubble.symbolConfiguration = .init(pointSize: 10, weight: .regular)
    bubble.contentTintColor = .tertiaryLabelColor
    bubble.isHidden = true
    count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    count.textColor = .tertiaryLabelColor
    count.isHidden = true
    for v in [person, bubble, count] { addSubview(v) }
  }
  required init?(coder: NSCoder) { fatalError() }
  override var wantsUpdateLayer: Bool { true }
  override func updateLayer() { person.layer?.backgroundColor = personColor?.cgColor }
  /// Its width as laid out (0 when it shows nothing).
  var width: CGFloat {
    var w: CGFloat = 0
    if comments > 0 { w += 14 + count.fittingSize.width + 2 }
    if personColor != nil { w += (w > 0 ? 6 : 0) + 7 }
    return w
  }
  override func layout() {
    super.layout()
    let h = bounds.height
    var x: CGFloat = 0
    if comments > 0 {
      bubble.frame = NSRect(x: x, y: ((h - 14) / 2).rounded(), width: 14, height: 14)
      x += 15
      let cw = count.fittingSize.width
      count.frame = NSRect(x: x, y: ((h - count.fittingSize.height) / 2).rounded(), width: cw, height: count.fittingSize.height)
      x += cw + 8
    }
    person.frame = NSRect(x: x, y: ((h - 7) / 2).rounded(), width: 7, height: 7)
  }
}

/// A name that fades out at the right edge instead of an ellipsis, as Rex's do.
final class FadingLabel: NSTextField {
  private let fade = CAGradientLayer()
  var fades: Bool { layer?.mask != nil }
  override func layout() {
    super.layout()
    wantsLayer = true
    if !isEditable && attributedStringValue.size().width > bounds.width - 4 {
      fade.frame = bounds
      fade.startPoint = CGPoint(x: 0, y: 0.5)
      fade.endPoint = CGPoint(x: 1, y: 0.5)
      fade.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
      fade.locations = [0, NSNumber(value: Double(max(0, 1 - 28 / max(bounds.width, 1)))), 1]
      layer?.mask = fade
    } else {
      layer?.mask = nil
    }
  }
}

public final class FileCell: NSTableCellView {
  let glyph = NSImageView()
  let name = FadingLabel(labelWithString: "")
  let badges = BadgeView()
  let more = NSButton(title: "•••", target: nil, action: nil)
  public var hovered = false { didSet { if hovered != oldValue { more.isHidden = !hovered; needsLayout = true } } }
  var current = false { didSet { glyph.contentTintColor = current ? .labelColor : .secondaryLabelColor } }
  override init(frame: NSRect) {
    super.init(frame: frame)
    glyph.symbolConfiguration = .init(pointSize: 13, weight: .regular)
    glyph.contentTintColor = .secondaryLabelColor
    name.font = .systemFont(ofSize: 13)
    name.lineBreakMode = .byClipping
    name.textColor = .labelColor
    more.isBordered = false
    more.font = .systemFont(ofSize: 11, weight: .semibold)
    more.contentTintColor = .tertiaryLabelColor
    more.isHidden = true
    more.setAccessibilityLabel("More")
    for v in [glyph, name, badges, more] { addSubview(v) }
    textField = name
  }
  required init?(coder: NSCoder) { fatalError() }
  public override func layout() {
    super.layout()
    let h = bounds.height
    glyph.frame = NSRect(x: 24, y: ((h - 18) / 2).rounded(), width: 18, height: 18)
    let right = bounds.width - 16
    more.frame = NSRect(x: right - 24, y: ((h - 18) / 2).rounded(), width: 24, height: 18)
    let bw = badges.width
    let end = more.isHidden ? right : right - 28
    badges.frame = NSRect(x: end - bw, y: 0, width: bw, height: h)
    let nh = name.fittingSize.height
    name.frame = NSRect(x: 50, y: ((h - nh) / 2).rounded(), width: max(20, end - bw - (bw > 0 ? 8 : 0) - 50), height: nh)
  }
}

final class SectionCell: NSTableCellView {
  let title = NSTextField(labelWithString: "")
  override init(frame: NSRect) {
    super.init(frame: frame)
    title.font = .systemFont(ofSize: 11, weight: .medium)
    title.textColor = .tertiaryLabelColor
    title.lineBreakMode = .byTruncatingMiddle
    addSubview(title)
    textField = title
  }
  required init?(coder: NSCoder) { fatalError() }
  override func layout() {
    super.layout()
    let th = title.fittingSize.height
    title.frame = NSRect(x: 22, y: ((bounds.height - th) / 2).rounded() - 2, width: bounds.width - 36, height: th)
  }
}

final class ProjectCell: NSTableCellView {
  let symbol = NSImageView()
  let title = NSTextField(labelWithString: "")
  override init(frame: NSRect) {
    super.init(frame: frame)
    symbol.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
    symbol.symbolConfiguration = .init(pointSize: 13, weight: .regular)
    symbol.contentTintColor = .secondaryLabelColor
    title.font = .systemFont(ofSize: 13, weight: .semibold)
    title.lineBreakMode = .byTruncatingTail
    addSubview(symbol)
    addSubview(title)
  }
  required init?(coder: NSCoder) { fatalError() }
  override func layout() {
    super.layout()
    let h = bounds.height
    symbol.frame = NSRect(x: 20, y: ((h - 20) / 2).rounded(), width: 22, height: 20)
    let th = title.fittingSize.height
    title.frame = NSRect(x: 50, y: ((h - th) / 2).rounded(), width: bounds.width - 64, height: th)
  }
}

/// The selection: a capsule of Liquid Glass (macOS 26; before, a quiet fill), inset from the edges. Hover shows the
/// row's "•••".
final class PillRowView: NSTableRowView {
  var onHover: ((Bool) -> Void)?
  private var area: NSTrackingArea?
  private var glass: NSView?
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let area { removeTrackingArea(area) }
    let a = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
    addTrackingArea(a)
    area = a
  }
  override func mouseEntered(with event: NSEvent) { onHover?(true) }
  override func mouseExited(with event: NSEvent) { onHover?(false) }
  var pillRect: NSRect { bounds.insetBy(dx: 10, dy: 2) }
  /// The glass view behind the cell while selected (tests).
  var pill: NSView? { glass }
  override var isSelected: Bool {
    didSet { if isSelected != oldValue { updatePill() } }
  }
  private func updatePill() {
    if isSelected, glass == nil {
      let v = GlassCapsule()
      v.frame = pillRect
      v.autoresizingMask = [.width]
      addSubview(v, positioned: .below, relativeTo: nil)
      glass = v
    } else if !isSelected, let g = glass {
      g.removeFromSuperview()
      glass = nil
    }
    needsDisplay = true
  }
  override func layout() {
    super.layout()
    glass?.frame = pillRect
  }
  override func drawSelection(in dirtyRect: NSRect) {}
  override func drawBackground(in dirtyRect: NSRect) {}
  override var isEmphasized: Bool { get { false } set {} }
}

/// A glass capsule, as Rex draws its selection: a faint fill, a soft inner sheen at the top, and a hairline rim that
/// is bright along the top edge and fades toward the bottom (the light catching the glass). Drawn, not
/// NSGlassEffectView: over the plain sidebar material that has nothing to refract and renders flat.
final class GlassCapsule: NSView {
  private let fill = CALayer()
  private let sheen = CAGradientLayer()
  private let rim = CAGradientLayer()
  private let rimShape = CAShapeLayer()
  private let sheenShape = CAShapeLayer()
  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.masksToBounds = false
    for l in [fill, sheen, rim] as [CALayer] {
      l.actions = ReviewMarginView.noActions
      layer?.addSublayer(l)
    }
    rimShape.fillColor = nil
    rimShape.strokeColor = NSColor.black.cgColor
    rimShape.lineWidth = 1
    rim.mask = rimShape
    sheenShape.fillColor = NSColor.black.cgColor
    sheen.mask = sheenShape
  }
  required init?(coder: NSCoder) { fatalError() }
  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }
  var dark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
  override func updateLayer() {
    let d = dark
    // fill: a touch lighter than the material (dark), a touch whiter (light)
    fill.backgroundColor = (d ? NSColor(white: 1, alpha: 0.075) : NSColor(white: 1, alpha: 0.55)).cgColor
    // rim: top bright, sides softer, bottom faint
    rim.colors = d
      ? [NSColor(white: 1, alpha: 0.30).cgColor, NSColor(white: 1, alpha: 0.10).cgColor, NSColor(white: 1, alpha: 0.05).cgColor]
      : [NSColor(white: 1, alpha: 0.95).cgColor, NSColor(white: 0, alpha: 0.08).cgColor, NSColor(white: 0, alpha: 0.14).cgColor]
    rim.locations = [0, 0.5, 1]
    sheen.colors = [NSColor(white: 1, alpha: d ? 0.06 : 0.35).cgColor, NSColor(white: 1, alpha: 0).cgColor]
    layer?.shadowColor = NSColor.black.cgColor
    layer?.shadowOpacity = d ? 0.25 : 0.08
    layer?.shadowRadius = 3
    layer?.shadowOffset = CGSize(width: 0, height: -1)
  }
  override func layout() {
    super.layout()
    let b = bounds
    let r = b.height / 2
    let path = CGPath(roundedRect: b, cornerWidth: r, cornerHeight: r, transform: nil)
    fill.frame = b
    fill.cornerRadius = r
    fill.cornerCurve = .continuous
    rim.frame = b
    rim.startPoint = CGPoint(x: 0.5, y: 0)
    rim.endPoint = CGPoint(x: 0.5, y: 1)
    rimShape.frame = b
    rimShape.path = CGPath(roundedRect: b.insetBy(dx: 0.5, dy: 0.5), cornerWidth: r - 0.5, cornerHeight: r - 0.5, transform: nil)
    sheen.frame = b
    sheen.startPoint = CGPoint(x: 0.5, y: 0)
    sheen.endPoint = CGPoint(x: 0.5, y: 0.6)
    sheenShape.frame = b
    sheenShape.path = path
    layer?.shadowPath = path
    needsDisplay = true
  }
}

/// The list: Return opens, ←/→ collapse and expand a section, ⌘⌫ deletes; Quick Look's panel asks it for the image.
final class FileTable: NSTableView {
  weak var files: FilesView?
  override func keyDown(with event: NSEvent) {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
    switch event.keyCode {
    case 36, 76 where flags.isEmpty: files?.openSelected()
    case 123 where flags.isEmpty: files?.collapseSelected()
    case 124 where flags.isEmpty: files?.expandSelected()
    case 51 where flags.contains(.command): files?.deleteSelected(nil)
    default: super.keyDown(with: event)
    }
  }
  override func menu(for event: NSEvent) -> NSMenu? {
    let row = self.row(at: convert(event.locationInWindow, from: nil))
    if row >= 0 && !selectedRowIndexes.contains(row) && files?.isSelectable(row) == true { selectRowIndexes([row], byExtendingSelection: false) }
    if row < 0 { deselectAll(nil) }
    return files?.contextMenu()
  }
  override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
  override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = files }
  override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = nil }
}

@MainActor public final class FilesView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, @preconcurrency QLPreviewPanelDataSource {
  public private(set) var tree: FileTree?
  let table = FileTable()
  let scroll = NSScrollView()
  public private(set) var rows: [FileRow] = []
  /// Open a file in the editor (the controller sends it to Neovim).
  public var onOpen: ((URL) -> Void)?
  /// Show an image (default: Quick Look).
  public var onPreview: ((URL) -> Void)?
  /// Ask before deleting; default an alert sheet. Tests answer it.
  public var confirm: ((String, @escaping @MainActor (Bool) -> Void) -> Void)?
  /// Something went wrong (a rename onto an existing name, no permission).
  public var onError: ((String) -> Void)?
  /// The file open in Neovim: its row is the pill (its sections opened to show it).
  public var current: URL? { didSet { if current != oldValue { showCurrent() } } }
  /// Comment and collaborator dots on the icons.
  public var badges = FileBadges() { didSet { if badges != oldValue { refreshBadges() } } }

  /// Sections collapsed (paths from the root), remembered per project.
  private(set) var collapsed: Set<String> = []
  private var stream: FSEventStreamRef?
  private var previewURL: URL?
  private var renaming: FileNode?

  public override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    table.files = self
    let col = NSTableColumn(identifier: .init("name"))
    col.isEditable = true
    col.resizingMask = .autoresizingMask
    table.addTableColumn(col)
    table.headerView = nil
    table.style = .plain
    table.backgroundColor = .clear
    table.gridStyleMask = []
    table.intercellSpacing = .zero
    table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
    table.dataSource = self
    table.delegate = self
    table.target = self
    table.action = #selector(clicked)
    table.allowsTypeSelect = true
    table.allowsMultipleSelection = true
    table.setAccessibilityIdentifier("taudot-files")
    table.setAccessibilityLabel("Files")
    scroll.documentView = table
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.drawsBackground = false
    scroll.automaticallyAdjustsContentInsets = false
    scroll.frame = bounds
    scroll.autoresizingMask = [.width, .height]
    material.material = .sidebar
    material.blendingMode = .behindWindow
    material.state = .followsWindowActiveState
    material.frame = bounds
    material.autoresizingMask = [.width, .height]
    addSubview(material)
    addSubview(scroll)
  }
  required init?(coder: NSCoder) { fatalError() }
  isolated deinit { stopWatching() }
  /// Under the list: the sidebar's translucent material (the desktop and the window behind show through).
  let material = NSVisualEffectView()
  public override func layout() {
    super.layout()
    table.tableColumns.first?.width = scroll.contentSize.width
  }

  /// The project folder (nil: nothing).
  public var folder: URL? {
    didSet {
      guard folder?.standardizedFileURL != oldValue?.standardizedFileURL else { return }
      stopWatching()
      tree = folder.map { FileTree(root: $0) }
      collapsed = Set(folder.flatMap { UserDefaults.standard.stringArray(forKey: Self.collapsedKey($0)) } ?? [])
      rebuild()
      showCurrent()
      if let folder { watch(folder) }
    }
  }

  static func collapsedKey(_ root: URL) -> String { "taudot.files.collapsed." + root.standardizedFileURL.path }
  private func saveCollapsed() {
    guard let folder else { return }
    UserDefaults.standard.set(collapsed.sorted(), forKey: Self.collapsedKey(folder))
  }

  private func rebuild() {
    rows = tree.map { FileRow.build($0, collapsed: collapsed) } ?? []
    table.reloadData()
  }

  // ---- data -------------------------------------------------------------------------------------------------------

  public func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

  public func tableView(_ t: NSTableView, heightOfRow row: Int) -> CGFloat {
    switch rows[row] {
    case .project: 40
    case .section: 28
    case .file: 28
    }
  }

  public func tableView(_ t: NSTableView, shouldSelectRow row: Int) -> Bool { isSelectable(row) }
  func isSelectable(_ row: Int) -> Bool {
    guard row >= 0 && row < rows.count else { return false }
    if case .project = rows[row] { return false }
    return true
  }

  public func tableView(_ t: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
    let v = PillRowView()
    v.onHover = { [weak self, weak v] on in
      guard let self, let v else { return }
      let r = self.table.row(for: v)
      (self.table.view(atColumn: 0, row: r, makeIfNecessary: false) as? FileCell)?.hovered = on
    }
    return v
  }

  public func tableView(_ t: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    switch rows[row] {
    case let .project(name):
      let c = (t.makeView(withIdentifier: .init("project"), owner: self) as? ProjectCell) ?? ProjectCell()
      c.identifier = .init("project")
      c.title.stringValue = name
      return c
    case let .section(n, isCollapsed, count):
      let c = (t.makeView(withIdentifier: .init("section"), owner: self) as? SectionCell) ?? SectionCell()
      c.identifier = .init("section")
      c.title.isEditable = false
      c.title.delegate = self
      c.title.stringValue = isCollapsed && count > 0 ? "\(n.rel)  ·  \(count)" : n.rel
      c.setAccessibilityLabel(n.rel + (isCollapsed ? ", collapsed" : ""))
      return c
    case let .file(n):
      let c = (t.makeView(withIdentifier: .init("file"), owner: self) as? FileCell) ?? FileCell()
      c.identifier = .init("file")
      c.name.stringValue = n.name
      c.name.isEditable = false
      c.name.delegate = self
      c.glyph.image = NSImage(systemSymbolName: n.glyph, accessibilityDescription: nil)
      c.current = current.flatMap { tree?.rel(of: $0) } == n.rel
      apply(badges, to: c, n)
      c.hovered = false
      c.more.target = self
      c.more.action = #selector(moreClicked(_:))
      return c
    }
  }

  private func apply(_ b: FileBadges, to c: FileCell, _ n: FileNode) {
    c.badges.comments = b.comments[n.rel] ?? 0
    c.badges.personColor = b.people[n.rel]?.first.map { p in p.color.flatMap { NSColor(hex: $0) } ?? .systemPurple }
    c.needsLayout = true
    var tip = n.rel
    if let k = b.comments[n.rel], k > 0 { tip += "\n\(k) open comment\(k == 1 ? "" : "s")" }
    if let ps = b.people[n.rel], !ps.isEmpty { tip += "\n" + ps.map(\.name).joined(separator: ", ") + " here now" }
    c.toolTip = tip
  }

  private func refreshBadges() {
    for r in 0..<rows.count {
      if case let .file(n) = rows[r], let c = table.view(atColumn: 0, row: r, makeIfNecessary: false) as? FileCell { apply(badges, to: c, n) }
    }
  }

  /// The file row's cell (tests: its icon's dots, its fade; ReviewHost: a hovered row).
  public func cell(_ rel: String) -> FileCell? {
    row(of: rel).flatMap { table.view(atColumn: 0, row: $0, makeIfNecessary: true) as? FileCell }
  }

  public func tableView(_ t: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
    if case let .file(n) = rows[row] { return n.name }
    return nil
  }

  // ---- what's selected ------------------------------------------------------------------------------------------

  var selectedNodes: [FileNode] {
    table.selectedRowIndexes.compactMap { r in r < rows.count ? rows[r].node : nil }
  }
  /// Rows as shown, for tests: section paths with "/", their files indented, the root's files as they are.
  public var shownRows: [String] {
    rows.compactMap { r in
      switch r {
      case .project: nil
      case let .section(n, c, _): n.rel + "/" + (c ? " (collapsed)" : "")
      case let .file(n): (n.rel.contains("/") ? "  " : "") + n.name
      }
    }
  }

  func row(of rel: String) -> Int? { rows.firstIndex { $0.node?.rel == rel } }

  /// Select a row by its path (tests, and after a change).
  func select(_ rel: String?) {
    guard let rel, let r = row(of: rel) else { table.deselectAll(nil); return }
    table.selectRowIndexes([r], byExtendingSelection: false)
  }

  private func showCurrent() {
    guard let tree, let c = current, let rel = tree.rel(of: c) else {
      if current == nil { table.deselectAll(nil) }
      return
    }
    // Its sections opened, then the pill on it.
    var opened = false
    var path = ""
    for part in rel.split(separator: "/").dropLast() {
      path = path.isEmpty ? String(part) : path + "/" + part
      if collapsed.remove(path) != nil { opened = true }
    }
    if opened { saveCollapsed(); rebuild() }
    for (k, row) in rows.enumerated() {
      if case let .file(n) = row, let c = table.view(atColumn: 0, row: k, makeIfNecessary: false) as? FileCell { c.current = n.rel == rel }
    }
    guard let r = row(of: rel) else { return }
    table.selectRowIndexes([r], byExtendingSelection: false)
    // (once laid out: before, the table has no height and any row would scroll to the top)
    DispatchQueue.main.async { [weak self] in
      guard let self, let r = self.row(of: rel) else { return }
      self.layoutSubtreeIfNeeded()
      self.table.scrollRowToVisible(r)
    }
  }

  /// Keyboard focus into the list.
  public func focus() {
    window?.makeFirstResponder(table)
    if table.selectedRow < 0, let r = rows.indices.first(where: isSelectable) { table.selectRowIndexes([r], byExtendingSelection: false) }
  }

  // ---- sections ---------------------------------------------------------------------------------------------------

  /// Open a folder's section (and remember it).
  public func expand(_ rel: String) {
    guard collapsed.remove(rel) != nil else { return }
    saveCollapsed()
    let sel = selectedNodes.map(\.rel)
    rebuild()
    reselect(sel)
  }
  /// Close a folder's section: its files and the sections inside it go.
  public func collapse(_ rel: String) {
    guard !collapsed.contains(rel) else { return }
    collapsed.insert(rel)
    saveCollapsed()
    let sel = selectedNodes.map(\.rel).filter { !$0.hasPrefix(rel + "/") }
    rebuild()
    reselect(sel.isEmpty ? [rel] : sel)
  }
  public func toggle(_ rel: String) {
    if collapsed.contains(rel) { expand(rel) } else { collapse(rel) }
  }
  private func reselect(_ rels: [String]) {
    table.selectRowIndexes(IndexSet(rels.compactMap(row(of:))), byExtendingSelection: false)
  }

  /// ←: a section closes; on a file, up to its section.
  func collapseSelected() {
    guard let r = table.selectedRowIndexes.first, r < rows.count else { return }
    switch rows[r] {
    case let .section(n, c, _): if !c { collapse(n.rel) }
    case let .file(n):
      if let p = n.parent, !p.rel.isEmpty, let sr = row(of: p.rel) {
        table.selectRowIndexes([sr], byExtendingSelection: false)
        table.scrollRowToVisible(sr)
      }
    case .project: break
    }
  }
  /// →: a closed section opens.
  func expandSelected() {
    guard let r = table.selectedRowIndexes.first, r < rows.count, case let .section(n, c, _) = rows[r], c else { return }
    expand(n.rel)
  }

  // ---- opening ----------------------------------------------------------------------------------------------------

  @objc private func clicked() {
    let r = table.clickedRow
    guard r >= 0, renaming == nil else { return }
    activate(r)
  }

  func openSelected() {
    if let r = table.selectedRowIndexes.first { activate(r) }
  }

  /// A click or Return on a row: a section opens or closes, a file opens.
  func activate(_ r: Int) {
    guard r < rows.count else { return }
    switch rows[r] {
    case let .section(n, _, _): toggle(n.rel)
    case let .file(n): open(n)
    case .project: break
    }
  }

  func open(_ n: FileNode) {
    if n.kind == .image {
      if let onPreview { onPreview(n.url) } else { quickLook(n.url) }
    } else {
      onOpen?(n.url)
    }
  }

  private func quickLook(_ url: URL) {
    previewURL = url
    window?.makeFirstResponder(table)
    guard let p = QLPreviewPanel.shared() else { return }
    if QLPreviewPanel.sharedPreviewPanelExists() && p.isVisible { p.reloadData() } else { p.makeKeyAndOrderFront(nil) }
  }
  public func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURL == nil ? 0 : 1 }
  public func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! { previewURL as NSURL? }

  // ---- changes ----------------------------------------------------------------------------------------------------

  @objc private func moreClicked(_ sender: NSButton) {
    let r = table.row(for: sender)
    guard r >= 0 else { return }
    table.selectRowIndexes([r], byExtendingSelection: false)
    contextMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
  }

  func contextMenu() -> NSMenu {
    let m = NSMenu()
    func item(_ t: String, _ a: Selector) { let i = m.addItem(withTitle: t, action: a, keyEquivalent: ""); i.target = self }
    item("New File", #selector(newFile(_:)))
    item("New Folder", #selector(newFolder(_:)))
    if !selectedNodes.isEmpty {
      m.addItem(.separator())
      if selectedNodes.count == 1 { item("Rename", #selector(renameSelected(_:))) }
      item("Move to Trash", #selector(deleteSelected(_:)))
      m.addItem(.separator())
      item("Reveal in Finder", #selector(reveal(_:)))
    }
    return m
  }

  /// Where a new item goes: the selected section's folder, or the selected file's folder, or the root.
  private var targetFolder: FileNode? {
    guard let tree else { return nil }
    guard let s = selectedNodes.first else { return tree.root }
    return s.isDirectory ? s : (s.parent ?? tree.root)
  }

  private func freeName(_ base: String, ext: String, in dir: URL) -> String {
    let fm = FileManager.default
    var k = 1
    while true {
      let n = (k == 1 ? base : "\(base) \(k)") + (ext.isEmpty ? "" : "." + ext)
      if !fm.fileExists(atPath: dir.appendingPathComponent(n).path) { return n }
      k += 1
    }
  }

  @objc public func newFile(_ sender: Any?) { create(directory: false) }
  @objc public func newFolder(_ sender: Any?) { create(directory: true) }

  /// New File / New Folder: made at once with a free name, then renamed inline. Returns the new node.
  @discardableResult func create(directory: Bool) -> FileNode? {
    guard let dir = targetFolder else { return nil }
    let name = freeName(directory ? "untitled folder" : "untitled", ext: directory ? "" : "tex", in: dir.url)
    let url = dir.url.appendingPathComponent(name)
    do {
      if directory {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
      } else {
        try Data().write(to: url, options: .withoutOverwriting)
      }
    } catch {
      onError?("\(error.localizedDescription)")
      return nil
    }
    if !dir.rel.isEmpty, collapsed.remove(dir.rel) != nil { saveCollapsed() }
    reload()
    let rel = dir.rel.isEmpty ? name : dir.rel + "/" + name
    guard let r = row(of: rel), let n = rows[r].node else { return nil }
    table.selectRowIndexes([r], byExtendingSelection: false)
    table.scrollRowToVisible(r)
    beginRename(n)
    return n
  }

  @objc public func renameSelected(_ sender: Any?) {
    if let n = selectedNodes.first { beginRename(n) }
  }

  /// Inline rename, like Finder: the name selected up to its extension. A folder is renamed in its section header
  /// (its last path component).
  func beginRename(_ n: FileNode) {
    guard let r = row(of: n.rel) else { return }
    table.scrollRowToVisible(r)
    var tf: NSTextField?
    if let c = table.view(atColumn: 0, row: r, makeIfNecessary: true) as? FileCell {
      tf = c.name
    } else if let c = table.view(atColumn: 0, row: r, makeIfNecessary: true) as? SectionCell {
      c.title.stringValue = n.name
      tf = c.title
    }
    guard let tf else { return }
    tf.isEditable = true
    guard window?.makeFirstResponder(tf) == true else {
      // (no window, or the field refused: no rename under way, which would hold every reload)
      tf.isEditable = false
      table.reloadData(forRowIndexes: [r], columnIndexes: [0])
      return
    }
    renaming = n
    if let ed = tf.currentEditor() {
      let s = n.name as NSString
      let ext = s.pathExtension
      ed.selectedRange = NSRange(location: 0, length: n.isDirectory || ext.isEmpty ? s.length : s.length - ext.count - 1)
    }
  }

  public func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
    if sel == #selector(NSResponder.cancelOperation(_:)), renaming != nil, let tf = control as? NSTextField {
      renaming = nil
      tf.isEditable = false
      window?.makeFirstResponder(table)
      rebuild()
      return true
    }
    return false
  }

  public func controlTextDidEndEditing(_ obj: Notification) {
    guard let tf = obj.object as? NSTextField, let n = renaming else { return }
    renaming = nil
    tf.isEditable = false
    let name = tf.stringValue.trimmingCharacters(in: .whitespaces)
    if !rename(n, to: name) { rebuild() }
    window?.makeFirstResponder(table)
  }

  /// Rename on disk; false if refused (empty, a slash, the name taken) or it failed.
  @discardableResult public func rename(_ n: FileNode, to name: String) -> Bool {
    guard name != n.name else { return true }
    guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { return false }
    let to = n.url.deletingLastPathComponent().appendingPathComponent(name)
    if FileManager.default.fileExists(atPath: to.path) && to.path.lowercased() != n.url.path.lowercased() {
      onError?("“\(name)” is already taken.")
      return false
    }
    do {
      try FileManager.default.moveItem(at: n.url, to: to)
    } catch {
      onError?(error.localizedDescription)
      return false
    }
    let parentRel = n.parent?.rel ?? ""
    let newRel = parentRel.isEmpty ? name : parentRel + "/" + name
    if n.isDirectory {
      // collapsed sections inside it stay collapsed
      collapsed = Set(collapsed.map { $0 == n.rel || $0.hasPrefix(n.rel + "/") ? newRel + $0.dropFirst(n.rel.count) : $0 })
      saveCollapsed()
    }
    reload()
    select(newRel)
    return true
  }

  @objc public func deleteSelected(_ sender: Any?) {
    let ns = selectedNodes
    guard !ns.isEmpty else { return }
    let q = ns.count == 1 ? "Move “\(ns[0].name)” to the Trash?" : "Move \(ns.count) items to the Trash?"
    ask(q) { [weak self] ok in
      guard ok, let self else { return }
      for n in ns {
        do { try FileManager.default.trashItem(at: n.url, resultingItemURL: nil) } catch { self.onError?(error.localizedDescription) }
      }
      self.reload()
    }
  }

  private func ask(_ q: String, _ done: @escaping @MainActor (Bool) -> Void) {
    if let confirm { return confirm(q, done) }
    let a = NSAlert()
    a.messageText = q
    a.informativeText = "Collaborators lose it too: the project on Overleaf follows this folder."
    a.addButton(withTitle: "Move to Trash")
    a.addButton(withTitle: "Cancel")
    if let w = window {
      a.beginSheetModal(for: w) { r in MainActor.assumeIsolated { done(r == .alertFirstButtonReturn) } }
    } else {
      done(a.runModal() == .alertFirstButtonReturn)
    }
  }

  @objc public func reveal(_ sender: Any?) {
    let urls = selectedNodes.map(\.url)
    if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
  }

  // ---- following the disk -----------------------------------------------------------------------------------------

  /// Read the folder again, keeping sections, selection and scroll.
  public func reload() {
    guard let tree, renaming == nil else { return }
    let sel = selectedNodes.map(\.rel)
    let y = scroll.contentView.bounds.origin.y
    tree.invalidate()
    rebuild()
    reselect(sel)
    scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
  }

  private func watch(_ root: URL) {
    var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
    let cb: FSEventStreamCallback = { _, info, _, _, _, _ in
      guard let info else { return }
      let v = Unmanaged<FilesView>.fromOpaque(info).takeUnretainedValue()
      MainActor.assumeIsolated { v.diskChanged() }
    }
    guard let s = FSEventStreamCreate(nil, cb, &ctx, [root.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.25,
                                      FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)) else { return }
    FSEventStreamSetDispatchQueue(s, .main)
    FSEventStreamStart(s)
    stream = s
  }
  private func stopWatching() {
    guard let s = stream else { return }
    FSEventStreamStop(s)
    FSEventStreamInvalidate(s)
    FSEventStreamRelease(s)
    stream = nil
  }
  /// FSEvents (or a test): something under the folder changed.
  var onDiskChange: (() -> Void)?
  func diskChanged() {
    reload()
    onDiskChange?()
  }
}
