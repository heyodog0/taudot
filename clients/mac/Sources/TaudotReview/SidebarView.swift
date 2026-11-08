// The window's left pane: Files | Comments, like Xcode's navigator. Comments is the review margin as before; while
// it isn't visible (Files showing, or the sidebar hidden) the thread at the cursor floats over the editor.
import AppKit

@MainActor public final class SidebarView: NSView {
  public enum Tab: String, Sendable { case files, comments, history }
  /// The Comments tab: this file's cards beside their lines, or every comment in the project.
  public enum Scope: String, Sendable { case file, all }

  public let margin: ReviewMarginView
  public let files = FilesView(frame: .zero)
  public let overview = OverviewView(frame: .zero)
  private let scopes = NSSegmentedControl(labels: ["This File", "All"], trackingMode: .selectOne, target: nil, action: nil)
  /// The header's second row on the Comments tab (This File | All).
  public static let scopeRow: CGFloat = 30
  /// Its third: Comments n | Suggestions n (either or both), and the file's ••• (accept / reject all).
  public static let kindRow: CGFloat = 28
  public let kindsControl = NSSegmentedControl(labels: ["Comments", "Suggestions"], trackingMode: .selectAny, target: nil, action: nil)
  private let fileMenuButton = NSButton(title: "", target: nil, action: nil)
  /// The new directions' one-row header: everything the two extra rows held, in one menu.
  public let filterButton = NSButton(title: "", target: nil, action: nil)
  var compactHeader: Bool { true }

  /// What the Comments tab shows, in both scopes; remembered per project.
  public var kinds: ReviewKinds = .all {
    didSet {
      if kinds.isEmpty { kinds = oldValue == .comments ? .suggestions : .comments }  // never neither
      guard kinds != oldValue else { return }
      UserDefaults.standard.set(kinds.rawValue, forKey: kindsKey)
      apply()
      onKindsChange?(kinds)
    }
  }
  /// The filter changed: Neovim's jumps follow it.
  public var onKindsChange: ((ReviewKinds) -> Void)?
  /// Beside the text or stacked; remembered per project.
  public func setLayout(_ l: ReviewMarginView.Layout) {
    margin.cardLayout = l
    UserDefaults.standard.set(l.rawValue, forKey: layoutKey)
    apply()
  }
  private var layoutKey: String { "taudot.sidebar.layout" + (folder.map { "." + $0.standardizedFileURL.path } ?? "") }
  private var kindsKey: String { "taudot.sidebar.kinds" + (folder.map { "." + $0.standardizedFileURL.path } ?? "") }
  private let header = HeaderBar()
  private let tabs = NSSegmentedControl(labels: ["Files", "Comments"], trackingMode: .selectOne, target: nil, action: nil)
  private let resolvedButton = NSButton(title: "", target: nil, action: nil)
  /// Comments in the text (tints, end-of-line notes, the floating card) shown or hidden: an eye at the left of the
  /// scopes row, as Show resolved is at its right. The window keeps the setting; this shows it and asks to flip it.
  private let inlineButton = NSButton(title: "", target: nil, action: nil)
  public var inlineHidden = false { didSet { if inlineHidden != oldValue { updateInlineButton() } } }
  public var onToggleInline: (() -> Void)?

  /// The visible tab; remembered per project (or for all when there's no folder yet).
  public var tab: Tab = .comments {
    didSet {
      guard tab != oldValue else { return }
      UserDefaults.standard.set(tab.rawValue, forKey: tabKey)
      let from = content(oldValue, scope)
      apply()
      switched(from: from, toward: Self.order(tab) > Self.order(oldValue) ? 1 : -1)
      onTabChange?(tab)
    }
  }

  public var scope: Scope = .file {
    didSet {
      guard scope != oldValue else { return }
      UserDefaults.standard.set(scope.rawValue, forKey: scopeKey)
      let from = content(tab, oldValue)
      apply()
      if tab == .comments { switched(from: from, toward: scope == .all ? 1 : -1) }
      onScopeChange?(scope)
    }
  }
  /// The overview came on screen (fetch it) or went.
  public var onScopeChange: ((Scope) -> Void)?
  /// The overview is what the sidebar shows.
  public var overviewVisible: Bool { tab == .comments && scope == .all && !isHiddenOrHasHiddenAncestor }

  private func content(_ t: Tab, _ s: Scope) -> NSView { t == .files ? files : t == .history ? (history ?? files) : (s == .all ? overview : margin) }
  public var onTabChange: ((Tab) -> Void)?
  private static func order(_ t: Tab) -> Int { t == .files ? 0 : t == .comments ? 1 : 2 }

  /// The History tab's pane (TaudotHistory, set by the app): a third tab appears when it is set.
  public var history: NSView? {
    didSet {
      oldValue?.removeFromSuperview()
      guard let h = history else { tabs.segmentCount = 2; apply(); return }
      h.frame = bounds
      addSubview(h, positioned: .below, relativeTo: header)
      tabs.segmentCount = 3
      tabLabels[2] = "History"
      tabs.setImage(NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: "History"), forSegment: 2)
      tabs.setImageScaling(.scaleProportionallyDown, forSegment: 2)
      tabs.setToolTip("Version history", forSegment: 2)
      apply()
    }
  }

  /// The project folder: the Files tab's root, and the key the tab is remembered under.
  public var folder: URL? {
    didSet {
      files.folder = folder
      if let s = UserDefaults.standard.string(forKey: tabKey), let t = Tab(rawValue: s), t != tab {
        tab = t
      }
      // (a project with nothing saved starts on This File)
      let saved = UserDefaults.standard.string(forKey: scopeKey).flatMap(Scope.init(rawValue:)) ?? .file
      if saved != scope { scope = saved }
      margin.cardLayout = UserDefaults.standard.string(forKey: layoutKey).flatMap(ReviewMarginView.Layout.init(rawValue:)) ?? .beside
      let k = UserDefaults.standard.integer(forKey: kindsKey)
      kinds = k == 0 ? .all : ReviewKinds(rawValue: k)
    }
  }
  private var tabKey: String { "taudot.sidebar.tab" + (folder.map { "." + $0.standardizedFileURL.path } ?? "") }
  private var scopeKey: String { "taudot.sidebar.scope" + (folder.map { "." + $0.standardizedFileURL.path } ?? "") }

  public init(frame: NSRect, margin: ReviewMarginView? = nil) {
    self.margin = margin ?? ReviewMarginView(frame: frame)
    super.init(frame: frame)
    if let s = UserDefaults.standard.string(forKey: tabKey), let t = Tab(rawValue: s) { tab = t }
    if let s = UserDefaults.standard.string(forKey: scopeKey), let t = Scope(rawValue: s) { scope = t }
    wantsLayer = true
    self.margin.showsHeader = false
    self.margin.frame = bounds
    self.margin.autoresizingMask = [.width, .height]
    addSubview(self.margin)
    addSubview(files)
    addSubview(overview)
    addSubview(header)
    scopes.controlSize = .small
    scopes.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    scopes.target = self
    scopes.action = #selector(scopeClicked)
    scopes.setToolTip("This file's comments beside their lines", forSegment: 0)
    scopes.setToolTip("Every comment and change in the project", forSegment: 1)
    header.addSubview(scopes)
    kindsControl.controlSize = .small
    kindsControl.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    kindsControl.target = self
    kindsControl.action = #selector(kindsClicked)
    kindsControl.setToolTip("Show comments", forSegment: 0)
    kindsControl.setToolTip("Show suggestions (tracked changes)", forSegment: 1)
    header.addSubview(kindsControl)
    fileMenuButton.isBordered = false
    fileMenuButton.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Suggestions in this file")
    fileMenuButton.symbolConfiguration = .init(pointSize: 13, weight: .regular)
    fileMenuButton.contentTintColor = .secondaryLabelColor
    fileMenuButton.toolTip = "Accept or reject every suggestion in this file"
    fileMenuButton.target = self
    fileMenuButton.action = #selector(fileMenu)
    header.addSubview(fileMenuButton)
    filterButton.isBordered = false
    filterButton.symbolConfiguration = .init(pointSize: 14, weight: .regular)
    filterButton.toolTip = "Show: this file or all, comments, suggestions, resolved"
    filterButton.target = self
    filterButton.action = #selector(filterMenu)
    header.addSubview(filterButton)
    // (the Files tab's glass runs under the clear header too)
    tabs.segmentStyle = .automatic
    tabs.controlSize = .small
    tabs.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    tabs.target = self
    tabs.action = #selector(tabClicked)
    // Centred, each with its symbol.
    tabs.setImage(NSImage(systemSymbolName: "folder", accessibilityDescription: "Files"), forSegment: 0)
    tabs.setImage(NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "Comments"), forSegment: 1)
    tabs.setImageScaling(.scaleProportionallyDown, forSegment: 0)
    tabs.setImageScaling(.scaleProportionallyDown, forSegment: 1)
    tabs.setToolTip("Files (⇧⌘E)", forSegment: 0)
    tabs.setToolTip("Comments (⇧⌘M)", forSegment: 1)
    header.addSubview(tabs)
    // Show resolved: an icon at the right edge (the centred tabs leave no room for words).
    resolvedButton.isBordered = false
    resolvedButton.setButtonType(.toggle)
    resolvedButton.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: "Show resolved")
    resolvedButton.alternateImage = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Hide resolved")
    resolvedButton.symbolConfiguration = .init(pointSize: 13, weight: .regular)
    resolvedButton.contentTintColor = .secondaryLabelColor
    resolvedButton.target = self
    resolvedButton.action = #selector(toggleResolved)
    header.addSubview(resolvedButton)
    inlineButton.isBordered = false
    inlineButton.symbolConfiguration = .init(pointSize: 13, weight: .regular)
    inlineButton.contentTintColor = .secondaryLabelColor
    inlineButton.target = self
    inlineButton.action = #selector(toggleInline)
    inlineButton.setAccessibilityIdentifier("taudot-comments-in-text")
    updateInlineButton()
    header.addSubview(inlineButton)
    self.margin.onCountsChange = { [weak self] in self?.updateCounts() }
    self.margin.onFind = { [weak self] in
      guard let self else { return }
      self.scope = .all
      self.window?.makeFirstResponder(self.overview.search)
    }
    overview.onItemsChange = { [weak self] in self?.updateCounts() }
    updateCounts()
    apply()
  }
  required init?(coder: NSCoder) { fatalError() }
  public override var isFlipped: Bool { true }

  public override func layout() {
    super.layout()
    let h = ReviewMarginView.headerHeight
    let hh = tab == .comments && !compactHeader ? h + Self.scopeRow + Self.kindRow : h
    header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: hh)
    margin.frame = bounds
    files.frame = bounds
    overview.frame = bounds
    history?.frame = bounds
    overview.topInset = hh
    margin.coveredTop = hh
    scopes.sizeToFit()
    scopes.frame.origin = NSPoint(x: ((bounds.width - scopes.frame.width) / 2).rounded(), y: h + ((Self.scopeRow - scopes.frame.height) / 2).rounded() - 4)
    scopes.isHidden = tab != .comments
    kindsControl.sizeToFit()
    let ky = h + Self.scopeRow + ((Self.kindRow - kindsControl.frame.height) / 2).rounded() - 4
    kindsControl.frame.origin = NSPoint(x: ((bounds.width - kindsControl.frame.width) / 2).rounded(), y: ky)
    kindsControl.isHidden = tab != .comments
    fileMenuButton.frame = NSRect(x: bounds.width - 30, y: kindsControl.frame.midY.rounded() - 11, width: 22, height: 22)
    fileMenuButton.isHidden = tab != .comments || scope != .file || margin.changeIDs.isEmpty || fileMenuButton.frame.minX < kindsControl.frame.maxX + 2
    filterButton.frame = NSRect(x: bounds.width - 32, y: ((h - 24) / 2).rounded(), width: 24, height: 24)
    filterButton.isHidden = !(tab == .comments && compactHeader)
    // the eye: left of the filter button in the compact header, else at the left of the scopes row
    if compactHeader {
      inlineButton.frame = NSRect(x: filterButton.frame.minX - 24, y: ((h - 22) / 2).rounded(), width: 22, height: 22)
    } else {
      inlineButton.frame = NSRect(x: 8, y: h + ((Self.scopeRow - 22) / 2).rounded() - 4, width: 22, height: 22)
    }
    inlineButton.isHidden = tab != .comments
    if compactHeader {
      scopes.isHidden = true
      kindsControl.isHidden = true
      fileMenuButton.isHidden = true
      resolvedButton.isHidden = true
    }
    files.scroll.contentInsets = NSEdgeInsets(top: h, left: 0, bottom: 0, right: 0)
    layoutTabs(h)
    resolvedButton.frame = NSRect(x: bounds.width - 30, y: scopes.frame.midY.rounded() - 11, width: 22, height: 22)
    resolvedButton.isHidden = compactHeader || tab != .comments || scope != .file || resolvedButton.frame.minX < scopes.frame.maxX + 2
  }

  private func updateInlineButton() {
    let name = inlineHidden ? "eye.slash" : "eye"
    inlineButton.image = NSImage(systemSymbolName: name, accessibilityDescription: inlineHidden ? "Show comments in the text" : "Hide comments in the text")
    inlineButton.toolTip = inlineHidden ? "Show comments in the text (⌥⌘K)" : "Hide comments in the text (⌥⌘K)"
    inlineButton.contentTintColor = inlineHidden ? .controlAccentColor : .secondaryLabelColor
  }
  @objc private func toggleInline() { onToggleInline?() }
  /// Checks: the eye's state as shown (nil while it is hidden).
  public var inlineButtonShowsHidden: Bool? { inlineButton.isHidden ? nil : inlineButton.image?.accessibilityDescription == "Show comments in the text" }

  /// The tabs' words ("Files", "Comments 3", "History"): shown when they fit, else icons only (the tooltips stay).
  private var tabLabels = ["Files", "Comments", "History"] { didSet { needsLayout = true } }
  /// Clear space between the tabs and the filter button, and at the edges.
  public static let tabGap: CGFloat = 12, tabEdge: CGFloat = 8

  /// Centred, or left of centre so they keep `tabGap` from the filter button (its place is kept on every tab, so the
  /// tabs don't move when the tab changes); icons only when even that doesn't fit.
  private func layoutTabs(_ h: CGFloat) {
    let right = compactHeader ? inlineButton.frame.minX - Self.tabGap : bounds.width - Self.tabEdge
    func place(words: Bool) -> Bool {
      for i in 0..<tabs.segmentCount {
        tabs.setLabel(words ? tabLabels[i] : "", forSegment: i)
        tabs.setWidth(0, forSegment: i)
      }
      tabs.sizeToFit()
      var x = ((bounds.width - tabs.frame.width) / 2).rounded()
      if x + tabs.frame.width > right { x = (right - tabs.frame.width).rounded() }
      tabs.frame.origin = NSPoint(x: max(Self.tabEdge, x), y: ((h - tabs.frame.height) / 2).rounded())
      return x >= Self.tabEdge
    }
    if !place(words: true) {
      _ = place(words: false)
      // icons only: equal widths, as wide as the room allows (at most 44)
      let n = CGFloat(tabs.segmentCount)
      let w = min(44, ((right - Self.tabEdge) / n).rounded(.down) - 2)
      for i in 0..<tabs.segmentCount { tabs.setWidth(w, forSegment: i) }
      tabs.sizeToFit()
      tabs.frame.origin = NSPoint(x: max(Self.tabEdge, min(((bounds.width - tabs.frame.width) / 2).rounded(), right - tabs.frame.width)), y: ((h - tabs.frame.height) / 2).rounded())
    }
    tabsShowWords = tabs.label(forSegment: 0) != ""
  }
  /// For tests: whether the tabs show their words (else icons only).
  public private(set) var tabsShowWords = true
  /// For tests: the tabs' and the filter button's frames.
  public var tabsFrame: NSRect { tabs.frame }
  public var filterFrame: NSRect { filterButton.frame }
  /// For tests: the eye's frame (Comments in the Text).
  public var inlineFrame: NSRect { inlineButton.frame }

  private func apply() {
    tabs.selectedSegment = min(Self.order(tab), tabs.segmentCount - 1)
    history?.isHidden = tab != .history
    scopes.selectedSegment = scope == .file ? 0 : 1
    // Hiding the margin is what makes its thread float (and its inline notes come back).
    margin.isHidden = !(tab == .comments && scope == .file)
    overview.isHidden = !(tab == .comments && scope == .all)
    kindsControl.setSelected(kinds.contains(.comments), forSegment: 0)
    kindsControl.setSelected(kinds.contains(.suggestions), forSegment: 1)
    margin.kinds = kinds
    overview.kinds = kinds
    // The menu's icon fills when it hides something.
    let filtered = kinds != .all || scope == .all || margin.showResolved || margin.authorFilter != nil
    filterButton.image = NSImage(systemSymbolName: filtered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle", accessibilityDescription: "Filter")
    filterButton.contentTintColor = filtered ? .controlAccentColor : .secondaryLabelColor
    updateCounts()
    files.isHidden = tab != .files
    header.clear = tab != .comments
    needsLayout = true
  }

  // ---- the switch's motion ----------------------------------------------------------------------------------------
  // The tabs swap at once (what's hidden, what floats, focus); only the picture moves: a snapshot of the old tab fades
  // out while the new one fades in, both sliding 8 pt toward the chosen tab (right for Comments, left for Files).
  // Reduce Motion: the crossfade alone.

  public static let switchDuration: CFTimeInterval = 0.2
  public static let switchSlide: CGFloat = 8
  /// Read when a switch starts (overridable in tests).
  public var reduceMotion: () -> Bool = {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || ProcessInfo.processInfo.environment["TAUDOT_PANE_INSTANT"] != nil
  }
  /// The old tab's picture while it leaves.
  public private(set) var leaving: NSView?

  private func switched(from old: NSView, toward side: CGFloat) {
    leaving?.removeFromSuperview()
    leaving = nil
    let new = content(tab, scope)
    guard window != nil, bounds.width > 0, bounds.height > 0, let ghost = snapshot(old) else { return }
    if ProcessInfo.processInfo.environment["TAUDOT_PANE_INSTANT"] != nil { return }
    addSubview(ghost, positioned: .below, relativeTo: header)
    leaving = ghost
    let reduce = reduceMotion()
    let dx = reduce ? 0 : side * Self.switchSlide
    new.layer?.removeAnimation(forKey: "tabSwitch")
    animate(new.layer, opacity: (0, 1), x: (-dx, 0))
    animate(ghost.layer, opacity: (1, 0), x: (0, dx))
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.switchDuration) { [weak self, weak ghost] in
      ghost?.removeFromSuperview()
      if let self, self.leaving === ghost { self.leaving = nil }
    }
  }

  private func snapshot(_ v: NSView) -> NSView? {
    guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
    v.cacheDisplay(in: v.bounds, to: rep)
    let g = NSView(frame: v.frame)
    g.wantsLayer = true
    g.layer?.contents = rep.cgImage
    g.layer?.contentsGravity = .resize
    return g
  }

  private func animate(_ l: CALayer?, opacity: (Float, Float), x: (CGFloat, CGFloat)) {
    guard let l else { return }
    let ease = CAMediaTimingFunction(name: .easeOut)
    let o = CABasicAnimation(keyPath: "opacity")
    o.fromValue = opacity.0
    o.toValue = opacity.1
    var anims: [CAAnimation] = [o]
    if x.0 != x.1 {
      let t = CABasicAnimation(keyPath: "transform.translation.x")
      t.fromValue = x.0
      t.toValue = x.1
      anims.append(t)
    }
    let g = CAAnimationGroup()
    g.animations = anims
    g.duration = Self.switchDuration
    g.timingFunction = ease
    l.opacity = opacity.1
    l.setAffineTransform(CGAffineTransform(translationX: x.1, y: 0))
    l.add(g, forKey: "tabSwitch")
  }

  private func updateCounts() {
    // "Comments 5 · Suggestions 97": the file's (This File) or the project's (All) open ones.
    let (c, sg) = scope == .all
      ? (overview.items.filter { !$0.resolved && $0.kind == .comment }.count, overview.items.filter { !$0.resolved && $0.kind != .comment }.count)
      : ReviewGrouping.counts(margin.state.items)
    kindsControl.setLabel(c == 1 ? "1 comment" : "\(c) comments", forSegment: 0)
    kindsControl.setLabel(sg == 1 ? "1 suggestion" : "\(sg) suggestions", forSegment: 1)
    let open = margin.openCount
    _ = open
    // The badge counts open comments only; suggestions are counted on the filter row under it.
    tabLabels[1] = c > 0 ? "Comments \(c)" : "Comments"
    tabs.setToolTip("\(c == 1 ? "1 open comment" : "\(c) open comments") · \(sg == 1 ? "1 suggestion" : "\(sg) suggestions") (⇧⌘M)", forSegment: 1)
    let r = margin.resolvedCount
    resolvedButton.toolTip = margin.showResolved ? "Hide resolved" : (r == 0 ? "No resolved comments" : "Show resolved (\(r))")
    resolvedButton.state = margin.showResolved ? .on : .off
    resolvedButton.isEnabled = r > 0 || margin.showResolved
    needsLayout = true
  }

  /// The single menu: scope, kinds (with counts), resolved, and the file's accept / reject all.
  @objc private func filterMenu() {
    let m = NSMenu()
    func add(_ title: String, on: Bool = false, enabled: Bool = true, _ f: @escaping () -> Void) {
      let i = NSMenuItem(title: title, action: #selector(ButtonHandler.fire), keyEquivalent: "")
      let h = ButtonHandler(f)
      i.target = h
      i.state = on ? .on : .off
      i.isEnabled = enabled
      objc_setAssociatedObject(i, &ButtonHandler.key, h, .OBJC_ASSOCIATION_RETAIN)
      m.addItem(i)
    }
    let (c, sg) = ReviewGrouping.counts(margin.state.items)
    add("This File", on: scope == .file) { [weak self] in self?.scope = .file }
    add("All Files", on: scope == .all) { [weak self] in self?.scope = .all }
    m.addItem(.separator())
    add("Comments (\(c))", on: kinds.contains(.comments)) { [weak self] in self?.kinds.formSymmetricDifference(.comments) }
    add("Suggestions (\(sg))", on: kinds.contains(.suggestions)) { [weak self] in self?.kinds.formSymmetricDifference(.suggestions) }
    add("Resolved (\(margin.resolvedCount))", on: margin.showResolved) { [weak self] in self?.margin.showResolved.toggle(); self?.updateCounts() }
    add("Comments in the Text", on: !inlineHidden) { [weak self] in self?.onToggleInline?() }
    // Layout, and one author's items (an advisor's 40 comments, one after another).
    m.addItem(.separator())
    add("Beside the Text", on: margin.cardLayout == .beside) { [weak self] in self?.setLayout(.beside) }
    add("Stacked", on: margin.cardLayout == .stacked) { [weak self] in self?.setLayout(.stacked) }
    var authors: [(key: String, name: String)] = []
    for it in margin.state.items where !authors.contains(where: { $0.key == (it.author.id ?? it.author.name) }) {
      authors.append((it.author.id ?? it.author.name, it.author.name))
    }
    if authors.count > 1 || margin.authorFilter != nil {
      m.addItem(.separator())
      add("Everyone", on: margin.authorFilter == nil) { [weak self] in self?.margin.authorFilter = nil; self?.apply() }
      for a in authors {
        add("Only \(a.name)", on: margin.authorFilter == a.key) { [weak self] in self?.margin.authorFilter = a.key; self?.apply() }
      }
    }
    let n = margin.changeIDs.count
    if n > 0 && scope == .file {
      m.addItem(.separator())
      add("Accept All \(n) Suggestions…") { [weak self] in self?.allInFile(accept: true) }
      add("Reject All \(n) Suggestions…") { [weak self] in self?.allInFile(accept: false) }
    }
    m.popUp(positioning: nil, at: NSPoint(x: 0, y: filterButton.bounds.maxY + 4), in: filterButton)
  }

  @objc private func kindsClicked() {
    var k: ReviewKinds = []
    if kindsControl.isSelected(forSegment: 0) { k.insert(.comments) }
    if kindsControl.isSelected(forSegment: 1) { k.insert(.suggestions) }
    kinds = k
    apply()  // (an empty choice snapped back)
  }

  /// The file's suggestions at once, asked first.
  @objc private func fileMenu() {
    let n = margin.changeIDs.count
    let m = NSMenu()
    for (title, accept) in [("Accept All \(n) Suggestions…", true), ("Reject All \(n) Suggestions…", false)] {
      let item = NSMenuItem(title: title, action: #selector(ButtonHandler.fire), keyEquivalent: "")
      let h = ButtonHandler { [weak self] in self?.allInFile(accept: accept) }
      item.target = h
      objc_setAssociatedObject(item, &ButtonHandler.key, h, .OBJC_ASSOCIATION_RETAIN)
      m.addItem(item)
    }
    m.popUp(positioning: nil, at: NSPoint(x: 0, y: fileMenuButton.bounds.maxY + 4), in: fileMenuButton)
  }

  public func allInFile(accept: Bool) {
    let ids = margin.changeIDs
    guard !ids.isEmpty else { return }
    let name = margin.state.path ?? "this file"
    margin.ask("\(accept ? "Accept" : "Reject") all \(ids.count) suggestions in \(name)?",
               info: accept ? "Their text stays in the document as it is now." : "Their insertions are removed and their deletions put back.",
               button: accept ? "Accept All" : "Reject All") { [weak self] ok in
      if ok { self?.margin.perform(accept ? .acceptAll(ids) : .rejectAll(ids)) }
    }
  }

  @objc private func scopeClicked() { scope = scopes.selectedSegment == 0 ? .file : .all }
  @objc private func tabClicked() { tab = [.files, .comments, .history][min(2, max(0, tabs.selectedSegment))] }
  @objc private func toggleResolved() {
    margin.showResolved.toggle()
    updateCounts()
  }

  /// Keyboard focus into the visible tab: the tree, or the selected card's reply field.
  public func focus() {
    switch tab {
    case .files: files.focus()
    case .history: if let h = history { window?.makeFirstResponder(h) }
    case .comments where scope == .all: overview.focus()
    case .comments:
      // The pane takes the keys (↑↓ move, ↩ reply, ⌘↩ accept…), not a reply field.
      window?.makeFirstResponder(margin)
    }
  }

  /// The comment threads under the cursor are floating (the Comments tab isn't on screen).
  public var commentsVisible: Bool { !margin.paneHidden }
}
