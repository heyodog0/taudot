// The Comments tab's "All": every comment and tracked change in the project, by file in the sidebar's order, with
// filters and a search (gui.lua's act overview). Clicking one opens its file at it, as ]r lands.
import AppKit
import TaudotShared

public struct OverviewItem: Sendable, Equatable, Identifiable {
  public var id: String
  public var kind: ReviewKind
  public var threadID: String?
  public var path: String
  /// 0-based line, when its file is open in Neovim.
  public var line: Int?
  public var quote: String
  public var author: ReviewUser
  public var color: String?
  /// The first message (comments).
  public var text: String
  public var replies: Int
  /// The last activity.
  public var ts: Date?
  public var resolved: Bool
  public var mine: Bool
  public init(id: String, kind: ReviewKind = .comment, threadID: String? = nil, path: String, line: Int? = nil, quote: String = "",
              author: ReviewUser = ReviewUser(id: nil, name: "?", initials: "?"), color: String? = nil, text: String = "",
              replies: Int = 0, ts: Date? = nil, resolved: Bool = false, mine: Bool = false) {
    self.id = id; self.kind = kind; self.threadID = threadID; self.path = path; self.line = line; self.quote = quote
    self.author = author; self.color = color; self.text = text; self.replies = replies; self.ts = ts
    self.resolved = resolved; self.mine = mine
  }

  init?(_ v: Value) {
    guard let id = v["id"].string, let kind = ReviewKind(rawValue: v["kind"].string ?? ""), let path = v["path"].string else { return nil }
    self.init(id: id, kind: kind, threadID: v["thread_id"].string, path: path, line: v["line"].int, quote: v["quote"].string ?? "",
              author: ReviewUser(v["author"]), color: v["color"].string, text: v["text"].string ?? "", replies: v["replies"].int ?? 0,
              ts: v["ts"].double.map { Date(timeIntervalSince1970: $0 / 1000) }, resolved: v["resolved"].bool, mine: v["mine"].bool)
  }

  public var authorColor: NSColor {
    ReviewItem(id: id, kind: kind, author: author, color: color, quote: "", range: ReviewRange(line: 0, col: 0, endLine: 0, endCol: 0)).authorColor
  }
}

public enum OverviewFilter: Int, Sendable, CaseIterable {
  case open, resolved, mine
  public var title: String { ["Open", "Resolved", "Mine"][rawValue] }
}

public struct OverviewSection: Sendable, Equatable {
  public var path: String
  public var items: [OverviewItem]
}

public enum Overview {
  /// gui.lua's {files = [{path, items}]} as one list.
  public static func items(_ v: Value) -> [OverviewItem] {
    v["files"].array.flatMap { f in f["items"].array.compactMap(OverviewItem.init) }
  }

  public static func passes(_ it: OverviewItem, _ filter: OverviewFilter) -> Bool {
    switch filter {
    case .open: return !it.resolved
    case .resolved: return it.kind == .comment && it.resolved
    case .mine: return it.mine && !it.resolved
    }
  }

  /// Every word of the query in the quote, the message, the author or the path (case and accents aside).
  public static func matches(_ it: OverviewItem, _ query: String) -> Bool {
    let hay = [it.quote, it.text, it.author.name, it.path].joined(separator: "\n")
    return query.split(whereSeparator: \.isWhitespace).allSatisfy { hay.localizedStandardContains($0) }
  }

  /// The items that pass, grouped by file in the sidebar's order; within a file in text order (as given when lines
  /// are unknown).
  public static func sections(_ items: [OverviewItem], filter: OverviewFilter, kinds: ReviewKinds = .all, query: String = "") -> [OverviewSection] {
    var by: [String: [(Int, OverviewItem)]] = [:]
    for (i, it) in items.enumerated() where passes(it, filter) && kinds.shows(it.kind) && matches(it, query) { by[it.path, default: []].append((i, it)) }
    return by.keys.sorted(by: sidebarOrder).map { path in
      let l = by[path]!.sorted { a, b in
        if let la = a.1.line, let lb = b.1.line, la != lb { return la < lb }
        return a.0 < b.0
      }
      return OverviewSection(path: path, items: l.map(\.1))
    }
  }
}

// ---- the view ---------------------------------------------------------------------------------------------------

final class OverviewRowView: NSTableRowView {
  var isGroup = false
  override func drawSelection(in dirtyRect: NSRect) {
    guard !isGroup else { return }
    let r = bounds.insetBy(dx: 8, dy: 2)
    let p = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
    (isEmphasized ? NSColor.controlAccentColor.withAlphaComponent(0.22) : NSColor.labelColor.withAlphaComponent(0.08)).setFill()
    p.fill()
  }
  override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}

/// One comment or change: author dot, quote (one line), first message, replies · time.
public final class OverviewCell: NSView {
  let dot = NSView()
  public let more = NSButton(title: "", target: nil, action: nil)
  var onMore: ((NSButton) -> Void)?
  public let quote = NSTextField(labelWithString: "")
  public let message = NSTextField(labelWithString: "")
  public let meta = NSTextField(labelWithString: "")
  override init(frame: NSRect) {
    super.init(frame: frame)
    dot.wantsLayer = true
    dot.layer?.cornerRadius = 4
    for (f, size, color) in [(quote, 11.0, NSColor.secondaryLabelColor), (message, 13.0, NSColor.labelColor), (meta, 11.0, NSColor.tertiaryLabelColor)] {
      f.font = .systemFont(ofSize: size)
      f.textColor = color
      f.lineBreakMode = .byTruncatingTail
      f.maximumNumberOfLines = 1
      f.cell?.truncatesLastVisibleLine = true
      addSubview(f)
    }
    addSubview(dot)
    more.isBordered = false
    more.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "More")
    more.symbolConfiguration = .init(pointSize: 12, weight: .medium)
    more.contentTintColor = .tertiaryLabelColor
    more.toolTip = "More"
    more.target = self
    more.action = #selector(moreClicked)
    addSubview(more)
  }
  @objc private func moreClicked() { onMore?(more) }
  required init?(coder: NSCoder) { fatalError() }
  public override var isFlipped: Bool { true }

  func show(_ it: OverviewItem, now: Date) {
    dot.layer?.backgroundColor = it.authorColor.cgColor
    let q = it.quote.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    switch it.kind {
    case .comment:
      quote.stringValue = "“\(q)”"
      message.stringValue = it.text.isEmpty ? "(no message)" : it.text.replacingOccurrences(of: "\n", with: " ")
    case .insert:
      quote.stringValue = "Added"
      message.stringValue = q
    case .delete:
      quote.stringValue = "Deleted"
      message.stringValue = q
    }
    var m = [it.author.name]
    if it.replies > 0 { m.append(it.replies == 1 ? "1 reply" : "\(it.replies) replies") }
    let ago = ReviewCardView.ago(it.ts, now: now)
    if !ago.isEmpty { m.append(ago) }
    if it.resolved { m.append("resolved") }
    meta.stringValue = m.joined(separator: " · ")
    toolTip = it.kind == .comment ? "“\(q)”\n\(it.text)" : nil
  }

  public override func layout() {
    super.layout()
    let x: CGFloat = 30, w = bounds.width - x - 14 - 22
    more.frame = NSRect(x: bounds.width - 32, y: 4, width: 24, height: 20)
    dot.frame = NSRect(x: 14, y: 11, width: 8, height: 8)
    quote.frame = NSRect(x: x, y: 6, width: w, height: 15)
    message.frame = NSRect(x: x, y: 22, width: w, height: 17)
    meta.frame = NSRect(x: x, y: 40, width: w, height: 15)
  }
}

public final class OverviewTable: NSTableView {
  var onActivate: (() -> Void)?
  public override func keyDown(with e: NSEvent) {
    if e.keyCode == 36 || e.keyCode == 76 { onActivate?(); return }  // Return, Enter
    super.keyDown(with: e)
  }
}

@MainActor public final class OverviewView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
  public let filters = NSSegmentedControl(labels: OverviewFilter.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
  public let search = NSSearchField()
  public let table = OverviewTable()
  let scroll = NSScrollView()
  let empty = NSTextField(labelWithString: "")
  static let barHeight: CGFloat = 64

  /// Every item in the project (gui.lua's overview), as last fetched.
  public var items: [OverviewItem] = [] { didSet { if items != oldValue { rebuild(); onItemsChange?() } } }
  public var onItemsChange: (() -> Void)?
  /// From a row's •••: resolve, reopen, delete (asked first by whoever runs it), accept, reject.
  public var onAction: ((ReviewAction, OverviewItem) -> Void)?
  public var filter: OverviewFilter = .open { didSet { filters.selectedSegment = filter.rawValue; rebuild() } }
  public var query = "" { didSet { if query != oldValue { rebuild() } } }
  /// Comments and/or suggestions (the sidebar's filter, shared with This File).
  public var kinds: ReviewKinds = .all { didSet { if kinds != oldValue { rebuild() } } }
  /// Clicked, or Return on the selection.
  public var onReveal: ((OverviewItem) -> Void)?
  var now: () -> Date = Date.init

  /// What the table shows: a file's header, then its items.
  enum Row: Equatable { case file(String, Int), item(OverviewItem) }
  private(set) var rows: [Row] = []
  public var sections: [OverviewSection] { Overview.sections(items, filter: filter, kinds: kinds, query: query) }

  public override init(frame: NSRect) {
    super.init(frame: frame)
    filters.target = self
    filters.action = #selector(filterClicked)
    filters.selectedSegment = 0
    filters.controlSize = .small
    filters.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    search.placeholderString = "Search comments"
    search.controlSize = .small
    search.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    search.delegate = self
    search.sendsSearchStringImmediately = true
    search.target = self
    search.action = #selector(searched)
    let col = NSTableColumn(identifier: .init("c"))
    table.addTableColumn(col)
    table.headerView = nil
    table.backgroundColor = .clear
    table.intercellSpacing = .zero
    table.style = .plain
    table.selectionHighlightStyle = .regular
    table.dataSource = self
    table.delegate = self
    table.target = self
    table.action = #selector(clicked)
    table.onActivate = { [weak self] in self?.activateSelected() }
    scroll.documentView = table
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    scroll.autohidesScrollers = true
    empty.font = .systemFont(ofSize: 12)
    empty.textColor = .tertiaryLabelColor
    empty.alignment = .center
    addSubview(scroll)
    addSubview(filters)
    addSubview(search)
    addSubview(empty)
    rebuild()
  }
  required init?(coder: NSCoder) { fatalError() }
  public override var isFlipped: Bool { true }

  /// Space at the top left for the sidebar's header.
  public var topInset: CGFloat = 0 { didSet { needsLayout = true } }

  public override func layout() {
    super.layout()
    let top = topInset + 8
    filters.sizeToFit()
    filters.frame.origin = NSPoint(x: ((bounds.width - filters.frame.width) / 2).rounded(), y: top)
    search.frame = NSRect(x: 12, y: top + filters.frame.height + 8, width: bounds.width - 24, height: 22)
    let y = search.frame.maxY + 6
    scroll.frame = NSRect(x: 0, y: y, width: bounds.width, height: max(0, bounds.height - y))
    table.tableColumns.first?.width = scroll.contentSize.width
    empty.frame = NSRect(x: 12, y: y + 30, width: bounds.width - 24, height: 18)
  }

  func rebuild() {
    let keep = selectedItem?.id
    rows = sections.flatMap { s in [Row.file(s.path, s.items.count)] + s.items.map(Row.item) }
    table.reloadData()
    if let keep, let i = rows.firstIndex(where: { if case let .item(it) = $0 { it.id == keep } else { false } }) {
      table.selectRowIndexes([i], byExtendingSelection: false)
    }
    empty.isHidden = !rows.isEmpty
    empty.stringValue = !query.isEmpty ? "Nothing matches" : ["No open comments", "No resolved comments", "Nothing of yours"][filter.rawValue]
  }

  public var selectedItem: OverviewItem? {
    let r = table.selectedRow
    guard r >= 0, r < rows.count, case let .item(it) = rows[r] else { return nil }
    return it
  }
  /// The items in table order, for tests.
  public var shownIDs: [String] { rows.compactMap { if case let .item(it) = $0 { it.id } else { nil } } }
  public var shownFiles: [String] { rows.compactMap { if case let .file(p, _) = $0 { p } else { nil } } }

  public func focus() { window?.makeFirstResponder(table); if table.selectedRow < 0, let i = rows.firstIndex(where: { if case .item = $0 { true } else { false } }) { table.selectRowIndexes([i], byExtendingSelection: false) } }

  @objc private func filterClicked() { filter = OverviewFilter(rawValue: filters.selectedSegment) ?? .open }
  @objc private func searched() { query = search.stringValue }
  public func controlTextDidChange(_ n: Notification) { query = search.stringValue }
  public func control(_ c: NSControl, textView: NSTextView, doCommandBy s: Selector) -> Bool {
    // ↓ from the search field into the list; Return opens the first match.
    if s == #selector(NSResponder.moveDown(_:)) { focus(); return true }
    if s == #selector(NSResponder.insertNewline(_:)) { focus(); activateSelected(); return true }
    return false
  }
  @objc private func clicked() { if table.clickedRow >= 0 { activateSelected() } }
  public func activateSelected() { if let it = selectedItem { onReveal?(it) } }

  /// A row's •••: open it; resolve or reopen; delete (asked first) — or accept / reject a suggestion.
  public func menu(for it: OverviewItem) -> NSMenu {
    let m = NSMenu()
    func add(_ title: String, _ symbol: String?, _ f: @escaping () -> Void) {
      let i = NSMenuItem(title: title, action: #selector(ButtonHandler.fire), keyEquivalent: "")
      let h = ButtonHandler(f)
      i.target = h
      objc_setAssociatedObject(i, &ButtonHandler.key, h, .OBJC_ASSOCIATION_RETAIN)
      if let symbol { i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
      m.addItem(i)
    }
    add("Show in \((it.path as NSString).lastPathComponent)", "arrow.right.circle") { [weak self] in self?.onReveal?(it) }
    m.addItem(.separator())
    if it.kind == .comment {
      if it.resolved {
        add("Reopen", "arrow.uturn.backward.circle") { [weak self] in self?.onAction?(.reopen(it.id), it) }
      } else {
        add("Resolve", "checkmark.circle") { [weak self] in self?.onAction?(.resolve(it.id), it) }
      }
      m.addItem(.separator())
      add("Delete Comment…", "trash") { [weak self] in self?.onAction?(.delete(it.id), it) }
    } else {
      add("Accept", "checkmark") { [weak self] in self?.onAction?(.accept(it.id), it) }
      add("Reject", "xmark") { [weak self] in self?.onAction?(.reject(it.id), it) }
    }
    return m
  }

  // MARK: table

  public func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
  public func tableView(_ t: NSTableView, isGroupRow row: Int) -> Bool { if case .file = rows[row] { true } else { false } }
  public func tableView(_ t: NSTableView, shouldSelectRow row: Int) -> Bool { if case .item = rows[row] { true } else { false } }
  public func tableView(_ t: NSTableView, heightOfRow row: Int) -> CGFloat { if case .file = rows[row] { 28 } else { 60 } }
  public func tableView(_ t: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
    let v = OverviewRowView()
    if case .file = rows[row] { v.isGroup = true }
    return v
  }
  public func tableView(_ t: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
    switch rows[row] {
    case let .file(path, n):
      let f = NSTextField(labelWithString: "\(path)  \(n)")
      f.font = .systemFont(ofSize: 11, weight: .medium)
      f.textColor = .tertiaryLabelColor
      f.lineBreakMode = .byTruncatingHead
      let box = NSView()
      box.addSubview(f)
      f.frame = NSRect(x: 14, y: 8, width: max(0, t.bounds.width - 28), height: 15)
      f.autoresizingMask = [.width]
      return box
    case let .item(it):
      let c = OverviewCell(frame: NSRect(x: 0, y: 0, width: t.bounds.width, height: 60))
      c.show(it, now: now())
      c.onMore = { [weak self] b in self?.menu(for: it).popUp(positioning: nil, at: NSPoint(x: 0, y: b.bounds.maxY + 2), in: b) }
      return c
    }
  }
}
