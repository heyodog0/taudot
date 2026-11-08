// Signed in: the projects as a native table, like Overleaf's dashboard. Columns Name / Owner / Last Modified,
// click a header to sort; projects already on this Mac carry a small laptop mark. Recent projects (opened here)
// come first under their own heading when nothing is being searched. Over the window's glass: clear background, a
// header without its bar, a glass pill faintly tinted with the accent for the selection.
import AppKit
import TaudotShared

@MainActor protocol ProjectsViewDelegate: AnyObject {
  func open(_ p: HomeProject)
  func openOnWeb(_ p: HomeProject)
  func reveal(_ p: HomeProject)
  func removeLocal(_ p: HomeProject)
}

/// Return opens the selected project.
final class ProjectsTable: NSTableView {
  var onReturn: (() -> Void)?
  override func keyDown(with e: NSEvent) {
    if e.keyCode == 36 || e.keyCode == 76 { onReturn?() } else { super.keyDown(with: e) }
  }
}

@MainActor final class ProjectsView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
  enum Row: Equatable {
    case header(String)
    case project(HomeProject, recent: Bool)
  }

  weak var delegate: ProjectsViewDelegate?
  /// The signed-in user's ID: their own changes show without "by".
  var me: String?
  let table = ProjectsTable()
  private let scroll = NSScrollView()
  private let empty = NSTextField(labelWithString: "")
  private let spinner = NSProgressIndicator()
  private(set) var rows: [Row] = []
  var projects: [HomeProject] = [] { didSet { reload() } }
  var query = ProjectQuery() { didSet { if query != oldValue { reload() } } }
  /// Project IDs being cloned: their mark is a spinner.
  var cloning: Set<String> = [] { didSet { table.reloadData() } }
  var loading = false {
    didSet { if loading && projects.isEmpty { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }; updateEmpty() }
  }

  override init(frame: NSRect) {
    super.init(frame: frame)
    let cols: [(String, String, CGFloat, ProjectSortKey?)] = [
      ("mark", "", 18, nil), ("name", "Name", 360, .name), ("owner", "Owner", 130, .owner), ("modified", "Last Modified", 210, .lastModified),
    ]
    for (id, title, w, key) in cols {
      let c = NSTableColumn(identifier: .init(id))
      c.title = title
      c.width = w
      if let key {
        c.sortDescriptorPrototype = NSSortDescriptor(key: key.rawValue, ascending: key != .lastModified)
        c.minWidth = 90
        // Only Name grows with the window; Owner and Last Modified stay compact beside it.
        c.resizingMask = [.userResizingMask]
      } else {
        c.minWidth = w; c.maxWidth = w
      }
      c.headerCell = TaudotHeaderCell(textCell: title)
      table.addTableColumn(c)
    }
    table.style = .inset
    table.headerView = TaudotHeaderView()
    table.backgroundColor = .clear
    table.rowHeight = 28
    table.rowSizeStyle = .custom
    table.floatsGroupRows = false
    table.intercellSpacing = NSSize(width: 8, height: 2)
    table.columnAutoresizingStyle = .noColumnAutoresizing
    table.allowsMultipleSelection = false
    table.dataSource = self
    table.delegate = self
    table.target = self
    table.doubleAction = #selector(doubleClick)
    table.onReturn = { [weak self] in self?.openSelected() }
    table.sortDescriptors = [NSSortDescriptor(key: ProjectSortKey.lastModified.rawValue, ascending: false)]
    let menu = NSMenu()
    menu.delegate = self
    table.menu = menu
    scroll.documentView = table
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.drawsBackground = false
    empty.textColor = .secondaryLabelColor
    empty.alignment = .center
    spinner.style = .spinning
    spinner.isDisplayedWhenStopped = false
    for v in [scroll, empty, spinner] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
    NSLayoutConstraint.activate([
      scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
      scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
      empty.centerXAnchor.constraint(equalTo: centerXAnchor), empty.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20),
      spinner.centerXAnchor.constraint(equalTo: centerXAnchor), spinner.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20),
    ])
  }

  required init?(coder: NSCoder) { fatalError() }

  /// Name takes what Owner and Last Modified leave, so the table never runs past its card.
  override func layout() {
    super.layout()
    let cols = table.tableColumns
    guard cols.count == 4 else { return }
    let spacing = table.intercellSpacing.width * CGFloat(cols.count) + 24  // the inset style's side padding
    let fixed = cols[0].width + cols[2].width + cols[3].width
    let w = max(cols[1].minWidth, scroll.contentSize.width - fixed - spacing)
    if abs(cols[1].width - w) > 0.5 { cols[1].width = w }
  }

  /// Rows: "Recent" and its projects first (only on All, without a search), then the filtered, sorted list.
  static func rows(_ projects: [HomeProject], _ q: ProjectQuery) -> [Row] {
    let main = ProjectList.visible(projects, q)
    let recent = q.filter == .all && q.search.isEmpty ? ProjectList.recent(projects) : []
    if recent.isEmpty { return main.map { .project($0, recent: false) } }
    return [.header("Recent")] + recent.map { .project($0, recent: true) } + [.header("All Projects")] + main.map { .project($0, recent: false) }
  }

  func reload() {
    let selected = selectedProject?.id
    rows = ProjectsView.rows(projects, query)
    table.reloadData()
    if let selected, let i = rows.firstIndex(where: { if case .project(let p, _) = $0 { p.id == selected } else { false } }) {
      table.selectRowIndexes([i], byExtendingSelection: false)
    }
    updateEmpty()
  }

  private func updateEmpty() {
    let count = rows.filter { if case .project = $0 { true } else { false } }.count
    empty.isHidden = count > 0 || loading
    if !query.search.isEmpty { empty.stringValue = "No projects match “\(query.search)”." }
    else if projects.isEmpty { empty.stringValue = "No projects yet. Create one on Overleaf, then refresh (⌘R)." }
    else {
      empty.stringValue = switch query.filter {
      case .archived: "No archived projects."
      case .trashed: "The trash is empty."
      case .shared: "No projects shared with you."
      default: "No projects."
      }
    }
  }

  var selectedProject: HomeProject? { project(at: table.selectedRow) }

  /// Where a project's row is on screen: its selection pill (the row inset as `GlassRowView` draws it), in screen
  /// coordinates. The selected row if it is that project, else its row in the main list, else in Recent; nil when
  /// it isn't in the list or is scrolled out of view.
  func screenRect(ofProject id: String) -> NSRect? {
    let rowsFor = rows.indices.filter { if case .project(let p, _) = rows[$0] { p.id == id } else { false } }
    let main = rowsFor.first { if case .project(_, false) = rows[$0] { true } else { false } }
    guard let row = rowsFor.first(where: { $0 == table.selectedRow }) ?? main ?? rowsFor.first, let window else { return nil }
    let r = table.rect(ofRow: row).insetBy(dx: 2, dy: 1)
    let visible = r.intersection(table.visibleRect)
    guard visible.height >= r.height / 2 else { return nil }
    return window.convertToScreen(table.convert(r, to: nil))
  }

  func project(at i: Int) -> HomeProject? {
    guard i >= 0, i < rows.count, case .project(let p, _) = rows[i] else { return nil }
    return p
  }

  @objc private func doubleClick() {
    guard table.clickedRow >= 0, let p = project(at: table.clickedRow) else { return }
    delegate?.open(p)
  }

  func openSelected() {
    if let p = selectedProject { delegate?.open(p) }
  }

  // MARK: table

  func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

  // Section headers are plain rows: group rows get extra padding in the inset style.
  func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { GlassRowView() }

  func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { project(at: row) != nil }

  func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
    if case .header = rows[row] { return row == 0 ? 26 : 36 }
    return 28
  }

  func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
    guard let d = tableView.sortDescriptors.first, let key = d.key.flatMap(ProjectSortKey.init(rawValue:)) else { return }
    query.sort = key
    query.ascending = d.ascending
  }

  func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
    switch rows[row] {
    case .header(let title):
      // One label, in the Name column so it lines up with the names.
      guard column?.identifier.rawValue == "name" else { return nil }
      let t = NSTextField(labelWithString: title)
      t.font = .systemFont(ofSize: 13, weight: .bold)
      t.textColor = .labelColor
      let v = NSView()
      t.translatesAutoresizingMaskIntoConstraints = false
      v.addSubview(t)
      NSLayoutConstraint.activate([t.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 2), t.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -3)])
      return v
    case .project(let p, _):
      guard let id = column?.identifier.rawValue else { return nil }
      return cell(id, p)
    }
  }

  private func cell(_ id: String, _ p: HomeProject) -> NSView {
    if id == "mark" {
      if cloning.contains(p.id) {
        let s = NSProgressIndicator()
        s.style = .spinning
        s.controlSize = .small
        s.startAnimation(nil)
        return centered(s)
      }
      guard let folder = p.localFolder else { return NSView() }
      let img = NSImageView(image: NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: "On this Mac") ?? NSImage())
      img.symbolConfiguration = .init(pointSize: 11, weight: .regular)
      img.contentTintColor = Flair.accent
      img.toolTip = "On this Mac: " + ProjectList.abbreviate(folder)
      return centered(img)
    }
    let text: String
    var secondary = false
    switch id {
    case "name": text = p.name
    case "owner": text = p.ownerLabel; secondary = true
    default:
      text = ProjectList.modified(p, me: me)
      secondary = true
    }
    let t = NSTextField(labelWithString: text)
    t.lineBreakMode = .byTruncatingTail
    t.textColor = secondary ? .secondaryLabelColor : .labelColor
    if id == "name" { t.font = .systemFont(ofSize: 13, weight: .medium) }
    if id == "name" { t.toolTip = p.name + (p.archived ? " (archived)" : p.trashed ? " (in the trash)" : "") }
    let v = NSView()
    t.translatesAutoresizingMaskIntoConstraints = false
    v.addSubview(t)
    NSLayoutConstraint.activate([
      t.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 2), t.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor),
      t.centerYAnchor.constraint(equalTo: v.centerYAnchor),
    ])
    return v
  }

  private func centered(_ inner: NSView) -> NSView {
    let v = NSView()
    inner.translatesAutoresizingMaskIntoConstraints = false
    v.addSubview(inner)
    NSLayoutConstraint.activate([inner.centerXAnchor.constraint(equalTo: v.centerXAnchor), inner.centerYAnchor.constraint(equalTo: v.centerYAnchor)])
    return v
  }

  // MARK: context menu

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    guard let p = project(at: table.clickedRow) else { return }
    func add(_ title: String, _ action: Selector, enabled: Bool = true) {
      let i = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
      i.target = self
      i.representedObject = p.id
      i.isEnabled = enabled
    }
    add(p.isLocal ? "Open" : "Open (Download to This Mac)", #selector(menuOpen(_:)), enabled: !cloning.contains(p.id))
    add("Open on Overleaf", #selector(menuWeb(_:)))
    menu.addItem(.separator())
    add("Show in Finder", #selector(menuReveal(_:)), enabled: p.isLocal)
    add("Remove Local Copy…", #selector(menuRemove(_:)), enabled: p.isLocal && !cloning.contains(p.id))
  }

  private func target(_ item: NSMenuItem) -> HomeProject? {
    projects.first { $0.id == item.representedObject as? String }
  }

  @objc private func menuOpen(_ i: NSMenuItem) { if let p = target(i) { delegate?.open(p) } }
  @objc private func menuWeb(_ i: NSMenuItem) { if let p = target(i) { delegate?.openOnWeb(p) } }
  @objc private func menuReveal(_ i: NSMenuItem) { if let p = target(i) { delegate?.reveal(p) } }
  @objc private func menuRemove(_ i: NSMenuItem) { if let p = target(i) { delegate?.removeLocal(p) } }
}

/// The selection: a pill of Liquid Glass with its rim (macOS 26; before, a quiet fill with a hairline), inset from
/// the row's edges. Text keeps its normal colours.
final class GlassRowView: NSTableRowView {
  private var pill: NSView?
  var pillRect: NSRect { bounds.insetBy(dx: 2, dy: 1) }

  override var isSelected: Bool {
    didSet { if isSelected != oldValue { update() } }
  }

  private func update() {
    if isSelected, pill == nil {
      let v: NSView
      if #available(macOS 26.0, *) {
        let g = NSGlassEffectView()
        g.cornerRadius = pillRect.height / 2
        g.tintColor = Flair.on ? TaudotColor.selection : NSColor.controlAccentColor.withAlphaComponent(0.2)
        v = g
      } else {
        let f = NSView()
        f.wantsLayer = true
        f.layer?.cornerRadius = pillRect.height / 2
        f.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.07).cgColor
        f.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
        f.layer?.borderWidth = 1
        v = f
      }
      v.frame = pillRect
      v.autoresizingMask = [.width, .height]
      addSubview(v, positioned: .below, relativeTo: nil)
      pill = v
    } else if !isSelected {
      pill?.removeFromSuperview()
      pill = nil
    }
  }

  override func layout() {
    super.layout()
    pill?.frame = pillRect
    if #available(macOS 26.0, *), let g = pill as? NSGlassEffectView { g.cornerRadius = pillRect.height / 2 }
  }

  override func drawSelection(in dirtyRect: NSRect) {}
  override var isEmphasized: Bool { get { false } set {} }
}

/// Column titles without the header bar: small semibold secondary text, the sort arrow beside it.
final class TaudotHeaderCell: NSTableHeaderCell {
  override func draw(withFrame r: NSRect, in v: NSView) {
    let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
    let a = NSAttributedString(string: stringValue, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
    let size = a.size()
    a.draw(at: NSPoint(x: r.minX + 6, y: r.midY - size.height / 2))
    guard let table = (v as? NSTableHeaderView)?.tableView, let d = table.sortDescriptors.first,
          let col = table.tableColumns.first(where: { $0.headerCell === self }), col.sortDescriptorPrototype?.key == d.key else { return }
    let arrow = NSImage(systemSymbolName: d.ascending ? "chevron.up" : "chevron.down", accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
    if let arrow {
      let tinted = NSImage(size: arrow.size, flipped: false) { b in
        arrow.draw(in: b); NSColor.secondaryLabelColor.set(); b.fill(using: .sourceAtop); return true
      }
      tinted.draw(in: NSRect(x: r.minX + 10 + size.width, y: r.midY - arrow.size.height / 2, width: arrow.size.width, height: arrow.size.height))
    }
  }
}

/// The header: its cells and a hairline, no bar.
final class TaudotHeaderView: NSTableHeaderView {
  override func draw(_ dirty: NSRect) {
    guard let t = tableView else { return }
    for (i, c) in t.tableColumns.enumerated() { c.headerCell.draw(withFrame: headerRect(ofColumn: i), in: self) }
    NSColor.separatorColor.setFill()
    NSRect(x: 12, y: bounds.maxY - 1, width: bounds.width - 24, height: 1).fill()
  }
}
