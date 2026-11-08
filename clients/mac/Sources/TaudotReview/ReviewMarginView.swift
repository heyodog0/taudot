// The review margin: a card per open thread or tracked change, at the y of its line, following the text.
import AppKit
import QuartzCore
import TaudotShared

final class FlippedView: NSView {
  override var isFlipped: Bool { true }
}

/// The margin's header ("3 open", Resolved): opaque, with a hairline under it. (Translucent, the cards scrolling
/// under it showed through blurred and shimmered.)
final class HeaderBar: NSView {
  private let line = NSView()
  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    line.wantsLayer = true
    addSubview(line)
  }
  required init?(coder: NSCoder) { fatalError() }
  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }
  /// Clear (the Files tab: the sidebar's glass shows through, no hairline) instead of opaque.
  var clear = false { didSet { needsDisplay = true; line.isHidden = clear } }
  override var isOpaque: Bool { !clear }
  override func updateLayer() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.backgroundColor = clear ? NSColor.clear.cgColor : NSColor.windowBackgroundColor.cgColor
      line.layer?.backgroundColor = NSColor.separatorColor.cgColor
    }
  }
  override func layout() {
    super.layout()
    let px = 1 / (window?.backingScaleFactor ?? 2)
    line.frame = NSRect(x: 0, y: bounds.height - px, width: bounds.width, height: px)
  }
}

@MainActor public final class ReviewMarginView: NSView {
  /// Where the lines are. The margin's top is the editor view's top plus `editorOffset`.
  public var geometry: EditorGeometry? {
    didSet {
      guard geometry !== oldValue, let geometry else { return }
      geometry.onChange { [weak self, weak geometry] in
        guard let self, let geometry, geometry === self.geometry else { return }
        self.floating.geometryChanged()
        self.noteGeometry()
        self.place()
      }
      place()
    }
  }
  public var editorOffset: CGFloat = 0 { didSet { place() } }
  public var state = ReviewState() { didSet { if state != oldValue { reload(animated: true); floating.update() } } }
  public var cursor = ReviewCursor() { didSet { if cursor != oldValue { cursorChanged(oldValue) } } }
  public var showResolved = false {
    didSet { if showResolved != oldValue { reload(animated: true); onShowResolvedChange?(showResolved) } }
  }
  /// Neovim's jumps (]r) count resolved comments while they show here.
  public var onShowResolvedChange: ((Bool) -> Void)?
  public private(set) var selectedID: String?
  /// Actions for gui.lua. Deletes are confirmed first (`confirm`).
  public var onAction: ((ReviewAction) -> Void)?
  /// Ask before deleting; default an alert sheet.
  public var confirm: ((String, @escaping @MainActor (Bool) -> Void) -> Void)?
  public var animationDuration: CFTimeInterval = 0.15
  /// The animation clock (tests freeze it to compare frames at one animation time).
  var now: () -> CFTimeInterval = CACurrentMediaTime
  /// The user's own name and initials, for a new comment's card.
  public var me = ReviewUser(id: nil, name: "You", initials: "Y")

  private let background = NSVisualEffectView()
  private let content = FlippedView()
  private let connectorLayer = CALayer()
  private var overlay: ConnectorOverlay?
  private let header = HeaderBar()
  private let resolvedButton = NSButton(title: "", target: nil, action: nil)
  private let countLabel = NSTextField(labelWithString: "")
  /// The Comment pill, over the editor under the end of the selection.
  let pill = CommentPill()
  /// The cards under the cursor, floating over the editor while the margin is hidden.
  lazy var floating = FloatingCards(margin: self)
  /// View ▸ Hide Comments in Text: no floating card at the cursor (a new comment's draft still floats).
  public var inlineHidden = false { didSet { if inlineHidden != oldValue { floating.update() } } }
  /// Settings ▸ Comments ▸ Floating card at the cursor.
  public var floatingEnabled = true { didSet { if floatingEnabled != oldValue { floating.update() } } }
  /// Checks (FloatCheck): the threads floating now, and the floating stack's frame in its superview while it shows.
  public var floatingIDs: [String] { floating.shownIDs }
  public var floatingFrame: NSRect? { floating.stack.isHidden || floating.stack.superview == nil ? nil : floating.stack.frame }
  private var pillTimer: Timer?
  private var pillReady = false
  /// The pill waits this long for the selection to stop changing.
  public var pillDelay: TimeInterval = 0.15
  /// The editor view the pill floats over and focus returns to (default: `geometry` when it is a view).
  public weak var editorView: NSView?
  var editor: NSView? { editorView ?? (geometry as? NSView) }
  /// A new comment, one state (A3): its card's item, the buffer it was started in (it shows, and is sent, there
  /// only), its end on screen, what was typed while another file showed, and once sent, what and since when (the card
  /// stays where it is until the real one comes back, or `sendTimeout` passes).
  struct NewComment {
    var item: ReviewItem
    let buf: Int
    var end: SelectionEnd?
    var typed: String?
    var sending: (text: String, range: ReviewRange, since: Date)?
  }
  private var pendingDraft: NewComment? {
    didSet { if pendingDraft?.sending == nil { sendTimer?.invalidate(); sendTimer = nil } }
  }
  private var sendTimer: Timer?
  /// How long a sent comment may take to come back before its draft goes.
  var sendTimeout: TimeInterval = 8
  private var cards: [String: ReviewCardView] = [:]
  private var connectors: [String: CAShapeLayer] = [:]
  private var heights: [String: CGFloat] = [:] { didSet { docDirty = true } }
  // Document space: the stack is solved once per change of items, heights, selection or text layout, with each card
  // anchored at its line's place in the document; while scrolling the whole column is translated by
  // `columnOffset` (screen y = document y + columnOffset), so cards never move against each other.
  private var docAnchors: [CGFloat] = []
  private var docTops: [CGFloat] = []
  private var docDirty = true
  private var docLineHeight: CGFloat = 0
  private var columnOffset: CGFloat = 0
  private var ref: (line: Int, y: CGFloat)?
  private var offsetSource = ""
  /// How many times the stack was solved (tests: scrolling must not re-solve it).
  private(set) var solveCount = 0
  var order: [ReviewItem] = []
  /// The draft, when its file is the one shown.
  private var draft: ReviewItem? { pendingDraft.flatMap { $0.buf == state.buf ? $0.item : nil } }
  /// Where the last visual selection ended on screen (the floating draft sits where the pill was).
  private(set) var lastVisualEnd: SelectionEnd?
  /// The draft's end on screen, kept from when it opened.
  var draftEnd: SelectionEnd? { draft == nil ? nil : pendingDraft?.end }
  /// The buffer a new comment's action belongs to (gui.act's `buf`): the draft's, for the draft's own comment.
  public func target(of a: ReviewAction) -> Int? {
    guard case let .comment(r, _) = a, let d = pendingDraft, d.item.range == r else { return nil }
    return d.buf
  }
  private var deltas: [String: CGPoint] = [:]
  private var animStart: CFTimeInterval = 0
  private var link: CADisplayLink?
  private var fallback: Timer?
  private var animating = false
  private var clock: Timer?

  public static let headerHeight: CGFloat = 32
  /// False inside the sidebar, whose own header (the tabs) takes the band; the cards still start under it.
  public var showsHeader = true { didSet { header.isHidden = !showsHeader } }
  /// Open and resolved threads, for a header elsewhere; onCountsChange after every reload.
  public private(set) var openCount = 0
  public private(set) var resolvedCount = 0
  public var onCountsChange: (() -> Void)?
  /// The connector layers never animate on their own: they follow the text frame by frame.
  static let noActions: [String: any CAAction] = Dictionary(uniqueKeysWithValues:
    ["path", "position", "bounds", "frame", "opacity", "hidden", "strokeColor", "lineWidth", "contents", "sublayers"].map { ($0, NSNull()) })
  static let gap: CGFloat = 8
  /// The margin sits left of the editor: cards keep this far from the window's edge...
  static let outer: CGFloat = 10
  /// ...and this far from the text side, where the connectors run and the editor's gutter begins. The selected card
  /// moves `selectedShift` toward the text.
  public var textGap: CGFloat = 24 { didSet { heights = [:]; place() } }

  // ---- the direction (margin-redesign.md) -------------------------------------------------------------------------

  /// nil: the design's own.
  public var connectorMode: ConnectorMode? { didSet { place() } }
  /// Settings ▸ Comments ▸ Lines to the text (default: all).
  public var connectorStyle: ConnectorMode { connectorMode ?? ConnectorMode.saved }
  public private(set) var hoveredID: String? { didSet { if hoveredID != oldValue { place() } } }
  /// Items whose text is on screen (visible-only designs): the ones with cards.
  private var onScreen: Set<String> = []
  /// Cards that didn't fit under the last one on screen: counted below.
  private var overflow: Set<String> = []
  let abovePill = JumpPill(up: true), belowPill = JumpPill(up: false)
  private var prewarming = false

  // ---- stacked layout ---------------------------------------------------------------------------------------------

  /// Beside the text (cards at their lines) or stacked (a compact list in document order from the panel's top, that
  /// scrolls on its own: for working through many comments).
  public enum Layout: String, Sendable { case beside, stacked }
  public var cardLayout: Layout = .beside {
    didSet { if cardLayout != oldValue { stackOffset = 0; docDirty = true; reload(animated: true); onLayoutChange?(cardLayout) } }
  }
  public var onLayoutChange: ((Layout) -> Void)?
  /// Only this author's items (their user id, else name); nil: everyone's.
  public var authorFilter: String? { didSet { if authorFilter != oldValue { stackOffset = 0; reload(animated: true) } } }
  /// How far the stacked list is scrolled (points).
  public private(set) var stackOffset: CGFloat = 0
  private var stackHeight: CGFloat = 0

  /// Stacked: frames down from the top, scrolled by `stackOffset`.
  private func stackedFrames() -> [String: CGRect] {
    var out: [String: CGRect] = [:]
    let x = Self.outer
    let w = bounds.width - Self.outer - textGap
    var y = cardsTop + 6 - stackOffset
    for it in order {
      let h = heights[it.id] ?? height(it)
      out[it.id] = CGRect(x: x, y: y, width: w, height: h)
      y += h + Self.gap
    }
    stackHeight = y + stackOffset - (cardsTop + 6)
    onScreen = Set(order.map(\.id))
    overflow = []
    return out
  }

  func scrollStack(by d: CGFloat) {
    let room = cardsBottom - cardsTop - 12
    let lim = max(0, stackHeight - room)
    let next = min(max(0, stackOffset + d), lim)
    guard next != stackOffset else { return }
    stackOffset = next
    place()
  }

  /// Keep the selected card in view (the list moves only as far as that needs).
  func revealSelectedInStack() {
    guard cardLayout == .stacked, let id = selectedID, let f = stackedFrames()[id] else { return }
    let top = cardsTop + 6, bottom = cardsBottom - 6
    if f.minY < top { scrollStack(by: f.minY - top) } else if f.maxY > bottom { scrollStack(by: min(f.maxY - bottom, f.minY - top)) }
  }
  private var lastTop: (Int, CGFloat?)?
  private var lastTextMove: CFTimeInterval = -1
  private var heldCursorFrom: ReviewCursor?
  private var selectionSettle: Timer?
  /// Space collapsed the selected card (it stays selected).
  var collapsedSelection = false
  /// ⌘F in the pane: the All list's search.
  public var onFind: (() -> Void)?
  let keyHint = KeyHintBar()
  /// The item the review bar talks about may have changed (cursor, selection, state).
  public var onCurrentChange: (() -> Void)?
  /// Neovim shows a preview ("accepted" / "rejected"): no cards (they'd point at text that isn't there), a notice.
  public var previewMode: String? {
    didSet {
      guard previewMode != oldValue else { return }
      previewLabel.stringValue = previewMode.map { "Previewing every suggestion \($0).\nThe text is read-only; Esc goes back." } ?? ""
      previewLabel.isHidden = previewMode == nil
      needsLayout = true
      place()
    }
  }
  let previewLabel = NSTextField(wrappingLabelWithString: "")
  /// The cards' clip: between the pill strips (its bounds start where its frame does, so a card's frame is in the
  /// margin's coordinates all the same).
  func layoutContentClip() {
    let f = NSRect(x: 0, y: cardsTop, width: bounds.width, height: cardsBottom - cardsTop)
    if content.frame != f { content.frame = f; content.setBoundsOrigin(NSPoint(x: 0, y: cardsTop)) }
  }
  /// Where the cards may start (under whatever covers the top) and end (above the ↓ pill).
  private var topClear: CGFloat { max(coveredTop, showsHeader ? Self.headerHeight : 0) + 6 }
  /// The strips the ↑ / ↓ pills live in: cards are clipped above and below them, never drawn under a pill.
  static let pillStrip: CGFloat = 30
  /// Where the cards' area starts and ends (in the margin's coordinates).
  var cardsTop: CGFloat { max(coveredTop, showsHeader ? Self.headerHeight : 0) + Self.pillStrip }
  var cardsBottom: CGFloat { max(cardsTop, bounds.height - Self.pillStrip) }

  private func onScreenIDs() -> Set<String> {
    guard let g = geometry else { return Set(order.map(\.id)) }
    let v = g.visibleLines
    return Set(order.filter { $0.id == "draft" || ($0.range.line <= v.upperBound && $0.range.endLine >= v.lowerBound) }.map(\.id))
  }

  /// The nearest item above (dir -1) or below (+1) the screen.
  func nearestOff(_ dir: Int) -> ReviewItem? {
    guard let g = geometry else { return nil }
    let v = g.visibleLines
    if dir < 0 { return order.last { $0.range.endLine < v.lowerBound } }
    return order.first { $0.range.line > v.upperBound || overflow.contains($0.id) }
  }
  /// The selected card slides this far toward its text (no line needed), its neighbours making room.
  static let selectedShift: CGFloat = 8

  public override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    background.material = .sidebar
    // steady: not tied to the window's focus or to whatever is behind the window (both made it flash)
    background.blendingMode = .withinWindow
    background.state = .active
    background.autoresizingMask = [.width, .height]
    background.frame = bounds
    addSubview(background)
    content.wantsLayer = true
    content.layer?.masksToBounds = true
    // The cards' area starts under the header and clips there (no card shows through or under it). Its bounds
    // start at the header's height, so a card's frame is in the margin's coordinates all the same.
    content.frame = NSRect(x: 0, y: Self.headerHeight, width: bounds.width, height: max(0, bounds.height - Self.headerHeight))
    content.setBoundsOrigin(NSPoint(x: 0, y: Self.headerHeight))
    addSubview(content)
    connectorLayer.zPosition = -1
    connectorLayer.actions = Self.noActions
    content.layer?.addSublayer(connectorLayer)
    for pill in [abovePill, belowPill] {
      pill.isHidden = true
      addSubview(pill)
    }
    abovePill.onClick = { [weak self] in if let it = self?.nearestOff(-1) { self?.onAction?(.goto(it.members.first?.id ?? it.id)) } }
    belowPill.onClick = { [weak self] in if let it = self?.nearestOff(1) { self?.onAction?(.goto(it.members.first?.id ?? it.id)) } }
    keyHint.isHidden = true
    addSubview(keyHint)
    previewLabel.isHidden = true
    previewLabel.alignment = .center
    previewLabel.font = .systemFont(ofSize: 12)
    previewLabel.textColor = .secondaryLabelColor
    addSubview(previewLabel)

    addSubview(header)
    countLabel.font = .systemFont(ofSize: 12, weight: .semibold)
    countLabel.textColor = .secondaryLabelColor
    header.addSubview(countLabel)
    resolvedButton.bezelStyle = .accessoryBarAction
    resolvedButton.setButtonType(.pushOnPushOff)
    resolvedButton.font = .systemFont(ofSize: 11)
    resolvedButton.target = self
    resolvedButton.action = #selector(toggleResolved)
    header.addSubview(resolvedButton)

    pill.isHidden = true
    pill.alphaValue = 0
    pill.onClick = { [weak self] in self?.newComment() }

    let clock = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tickClock() }
    }
    RunLoop.main.add(clock, forMode: .common)
    self.clock = clock
    reload(animated: false)
  }
  required init?(coder: NSCoder) { fatalError() }
  isolated deinit {
    clock?.invalidate()
    link?.invalidate()
    fallback?.invalidate()
  }

  public override var isFlipped: Bool { true }

  public override func layout() {
    super.layout()
    header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: Self.headerHeight)
    layoutContentClip()
    countLabel.sizeToFit()
    countLabel.frame.origin = NSPoint(x: 14, y: (Self.headerHeight - countLabel.frame.height) / 2)
    resolvedButton.sizeToFit()
    resolvedButton.frame.origin = NSPoint(x: bounds.width - resolvedButton.frame.width - 8, y: (Self.headerHeight - resolvedButton.frame.height) / 2)
    if heights.isEmpty == false, let w = heights["__width"], w != cardWidth { heights = [:] }
    keyHint.frame = NSRect(x: 10, y: bounds.height - 64, width: bounds.width - 20, height: 26)
    previewLabel.frame = NSRect(x: 16, y: max(coveredTop, 0) + 40, width: bounds.width - 32, height: 40)
    place()
  }

  /// The margin became visible (true) or hidden (false) on screen: the controller turns Neovim's inline notes off
  /// while it shows (they'd duplicate the cards).
  public var onVisibilityChange: ((Bool) -> Void)?
  public var isShowing: Bool { window != nil && !isHiddenOrHasHiddenAncestor }
  private var lastShowing: Bool?
  /// The margin's pane is hidden (the floating cards take over). Not in a window counts as shown.
  public var paneHidden: Bool { isHiddenOrHasHiddenAncestor }
  private var lastHidden = false
  private func visibilityMaybeChanged() {
    let v = isShowing
    if v != lastShowing {
      lastShowing = v
      onVisibilityChange?(v)
    }
    if paneHidden != lastHidden {
      lastHidden = paneHidden
      if !paneHidden {
        // Back: today's margin (the card under the cursor selected), no floats.
        floating.dismiss()
        if let hit = preferredHere(Set(order.map(\.id))), hit != selectedID { select(hit) }
      } else {
        // Hidden: nothing selected (its highlight would hide the comment's own), the cursor's threads float.
        if let s = selectedID, s != "draft" { select(nil) }
        floating.update()
      }
    }
  }
  public override func viewDidHide() { super.viewDidHide(); visibilityMaybeChanged() }
  public override func viewDidUnhide() { super.viewDidUnhide(); visibilityMaybeChanged() }
  public override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); visibilityMaybeChanged() }

  public override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    place()
  }

  // ---- what is shown ----------------------------------------------------------------------------------------------

  /// Items with a card, in text order (the draft among them).
  public var shown: [ReviewItem] { order }

  private func visibleItems() -> [ReviewItem] {
    let who = authorFilter
    var out = state.items.filter { it in
      (showResolved || !it.resolved) && kinds.shows(it.kind) && (who.map { (it.author.id ?? it.author.name) == $0 } ?? true)
    }
    if let draft { out.append(draft) }
    out.sort { ($0.range.line, $0.range.col, $0.id == "draft" ? 1 : 0) < ($1.range.line, $1.range.col, $1.id == "draft" ? 1 : 0) }
    let grouped = ReviewGrouping.group(out)
    cardOf = [:]
    for g in grouped where g.isGroup { for m in g.members { cardOf[m.id] = g.id } }
    return grouped
  }

  /// Comments and/or suggestions (the sidebar's filter).
  public var kinds: ReviewKinds = .all { didSet { if kinds != oldValue { reload(animated: true) } } }
  /// A tracked change's card: its group's, when it is in one.
  private var cardOf: [String: String] = [:]
  func cardIDs(_ ids: [String]) -> [String] { ids.map { cardOf[$0] ?? $0 } }
  /// Every open tracked change in the buffer (the file's Accept all / Reject all).
  public var changeIDs: [String] { state.items.filter { $0.kind != .comment }.map(\.id) }

  func reload(animated: Bool) {
    docDirty = true
    var before = displayedFrames()
    // A sent draft whose comment came back: the new card takes the draft's place (no jump).
    var takeOver: [String: CGRect] = [:]
    if let d = pendingDraft, let s = d.sending {
      // (only its own file's items: a look-alike comment elsewhere isn't it)
      let back = d.buf != state.buf ? nil : state.items.first { it in
        it.kind == .comment && it.range.line == s.range.line && it.range.col == s.range.col && it.messages.first?.text == s.text
      }
      if let back {
        // It is the selected card now, as the draft was: it keeps the draft's place and the others stay put.
        takeOver[back.id] = before["draft"] ?? .zero
        pendingDraft = nil
        if paneHidden {
          // Floating: the new comment's card takes the draft's place there; nothing is selected.
          floating.pinned = back.id
        } else {
          selectedID = back.id
          DispatchQueue.main.async { [weak self] in self?.onAction?(.select(back.id)) }
        }
      } else if Date().timeIntervalSince(s.since) >= sendTimeout {
        pendingDraft = nil
        if selectedID == "draft" { selectedID = nil }
      }
    }
    order = visibleItems()
    if let s = selectedID, !order.contains(where: { $0.id == s }) {
      selectedID = nil
    }
    // Back in the draft's file: it is the selected card again.
    if draft != nil, selectedID == nil { selectedID = "draft" }
    let ids = Set(order.map(\.id))
    for (id, card) in cards where !ids.contains(id) {
      // The draft's card goes while another file shows: what was typed stays with the draft.
      if id == "draft", pendingDraft != nil { pendingDraft?.typed = card.reply?.string }
      card.removeFromSuperview()
      cards[id] = nil
      connectors[id]?.removeFromSuperlayer()
      connectors[id] = nil
      heights[id] = nil
    }
    for item in order {
      let card: ReviewCardView
      if let c = cards[item.id] {
        card = c
        let old = c.item
        c.update(item)
        if old != item { heights[item.id] = nil }
      } else {
        card = ReviewCardView(item: item)
        card.isDraft = item.id == "draft"
        if card.isDraft, let t = pendingDraft?.typed, let r = card.reply {
          r.string = t
          r.didChangeText()
          pendingDraft?.typed = nil
        }
        let id = item.id
        // A click selects the card and puts Neovim's cursor in its text (clicking the text selects the card).
        card.onSelect = { [weak self] in
          guard let self else { return }
          let target = self.order.first { $0.id == id }
          self.select(id, focus: true)
          guard id != "draft", let t = target else { return }
          if self.cardLayout == .stacked {
            // Stacked: the list stays; the editor goes to the text, centred, and the PDF follows.
            self.revealSelectedInStack()
            self.onAction?(.reveal(t.members.first?.id ?? t.id, path: self.state.path ?? ""))
          } else {
            self.onAction?(.goto(t.members.first?.id ?? t.id))
          }
        }
        card.onAction = { [weak self] in self?.perform($0) }
        card.onResize = { [weak self] in
          self?.heights[id] = nil
          self?.place()
        }
        card.onCancel = { [weak self, weak card] typed in
          guard let self, let card else { return }
          let done = { [weak self, weak card] in
            card?.giveUp()
            self?.focusEditor()
          }
          if typed {
            self.ask(card.isDraft ? "Discard this comment?" : "Discard this reply?", info: "What you typed is lost.", button: "Discard") { ok in
              if ok { done() }
            }
          } else {
            done()
          }
        }
        content.addSubview(card)
        cards[item.id] = card
        let line = CAShapeLayer()
        line.actions = Self.noActions
        line.fillColor = nil
        line.lineCap = .round
        connectorLayer.addSublayer(line)
        connectors[item.id] = line
        if let f = takeOver[item.id] {
          // The draft that became this card: it starts where the draft was, fully shown.
          before[item.id] = f
        } else if animated {
          card.appear = 0
          card.alphaValue = 0
        }
      }
      card.canReply = state.supported
      card.quiet = true
      let hid = item.id
      card.onHover = { [weak self] on in
        guard let self else { return }
        if on { self.hoveredID = hid } else if self.hoveredID == hid { self.hoveredID = nil }
      }
      let expanded = item.id == selectedID && !collapsedSelection
      if card.expanded != expanded {
        card.expanded = expanded
        heights[item.id] = nil
      }
      card.isSelected = expanded
    }
    let resolved = state.items.filter(\.resolved).count
    let open = state.items.count - resolved
    countLabel.stringValue = open == 0 ? "No comments" : (open == 1 ? "1 open" : "\(open) open")
    if (open, resolved) != (openCount, resolvedCount) {
      openCount = open
      resolvedCount = resolved
    }
    defer { onCountsChange?(); onCurrentChange?(); prewarmHeights() }
    resolvedButton.title = resolved == 0 ? "Resolved" : "Resolved (\(resolved))"
    resolvedButton.state = showResolved ? .on : .off
    resolvedButton.isEnabled = resolved > 0 || showResolved
    needsLayout = true
    if animated { animate(from: before) } else { place() }
    floating.update()
  }

  // ---- selection ----------------------------------------------------------------------------------------------

  /// Select a card (expand it, highlight its text in the editor). nil deselects.
  public func select(_ id: String?, focus: Bool = false) {
    // Another card, or none, chosen while the draft shows: it goes (one waiting in another file stays).
    if id != "draft", draft != nil { pendingDraft = nil }
    let changed = id != selectedID
    if changed { collapsedSelection = false }
    selectedID = id
    if changed {
      reload(animated: true)
      revealSelectedInStack()
      // (a group highlights its first change)
      if id != "draft" { onAction?(.select(id.map { i in order.first { $0.id == i }?.members.first?.id ?? i })) }
    }
    onCurrentChange?()
    if focus, let id, let card = paneHidden ? floating.card(id) : cards[id] {
      card.focusReply()
    }
  }

  private func cursorChanged(_ old: ReviewCursor) {
    if let e = cursor.visualEnd { lastVisualEnd = e }
    // The comment just sent from a floating draft floats until the cursor goes somewhere else.
    if let p = floating.pinned, (cursor.line, cursor.col) != (old.line, old.col), !cursor.here.contains(p) { floating.pinned = nil }
    floating.update()
    guard cursor.buf == state.buf else { return }
    // Neovim drags the cursor along while the text scrolls (scrolloff): selecting the cards it passes would open them
    // and re-flow the stack mid-scroll (the jitter). The selection follows once the scroll has settled.
    if scrollingNow {
      if heldCursorFrom == nil { heldCursorFrom = old }
      scheduleSelectionSettle()
    } else {
      applyCursorSelection(old)
    }
    onCurrentChange?()
    if cursor.visual != old.visual || cursor.visualEnd != old.visualEnd {
      // The selection changed (or ended): hide, and show again once it has been still for `pillDelay`.
      hidePill()
      if cursor.visual != nil { schedulePill() }
    }
  }

  // ---- the selection while scrolling --------------------------------------------------------------------------

  /// The text moved within the last quarter second.
  var scrollingNow: Bool { lastTextMove >= 0 && CACurrentMediaTime() - lastTextMove < 0.25 }
  private func noteGeometry() {
    guard let g = geometry else { return }
    let l = g.visibleLines.lowerBound
    let y = g.y(ofLine: l)
    defer { lastTop = (l, y) }
    if let t = lastTop, t.0 != l || t.1 != y { lastTextMove = CACurrentMediaTime(); if heldCursorFrom != nil { scheduleSelectionSettle() } }
  }
  private func scheduleSelectionSettle() {
    selectionSettle?.invalidate()
    let t = Timer(timeInterval: 0.27, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        if self.scrollingNow { self.scheduleSelectionSettle(); return }
        if let old = self.heldCursorFrom { self.heldCursorFrom = nil; self.applyCursorSelection(old) }
      }
    }
    RunLoop.main.add(t, forMode: .common)
    selectionSettle = t
  }

  /// Of the cards whose ranges hold the cursor: the selected one while the cursor stays in it (a card chosen by a
  /// click, ]r or ⌥⌘↓ isn't taken away by another range that also holds the cursor), else the innermost: the one
  /// starting last, then ending first.
  func preferredHere(_ ids: Set<String>) -> String? {
    let here = Set(cardIDs(cursor.here)).filter(ids.contains)
    if let s = selectedID, here.contains(s) { return s }
    let items = order.filter { here.contains($0.id) }
    return items.max { a, b in
      let sa = (a.range.line, a.range.col), sb = (b.range.line, b.range.col)
      if sa != sb { return sa < sb }
      return (a.range.endLine, a.range.endCol) > (b.range.endLine, b.range.endCol)
    }?.id
  }

  private func applyCursorSelection(_ old: ReviewCursor) {
    guard cursor.buf == state.buf else { return }
    let ids = Set(order.map(\.id))
    if paneHidden {
      // Hidden: the floating cards show the threads here; nothing is selected.
    } else if selectedID == "draft" {
      // Writing a new comment: the cursor passing over other items doesn't take the card away.
    } else if let hit = preferredHere(ids) {
      if hit != selectedID { select(hit) }
    } else if let s = selectedID, s != "draft", cardIDs(old.here).contains(s) {
      // Left the selected range: let go, unless a reply is being written.
      if let card = cards[s], let r = card.reply, !r.string.isEmpty || window?.firstResponder === r {
      } else {
        select(nil)
      }
    }
  }

  // ---- the Comment pill -----------------------------------------------------------------------------------------

  private func schedulePill() {
    pillTimer?.invalidate()
    let t = Timer(timeInterval: pillDelay, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.cursor.visual != nil, self.draft == nil else { return }
        self.pillReady = true
        self.placePill()
        if !self.pill.isHidden {
          NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.12
            self.pill.animator().alphaValue = 1
          }
        }
      }
    }
    RunLoop.main.add(t, forMode: .common)
    pillTimer = t
  }

  private func hidePill() {
    pillTimer?.invalidate()
    pillReady = false
    pill.alphaValue = 0
    pill.isHidden = true
  }

  /// Where the pill goes, in the editor view's coordinates: just below the end of the selection, starting near its
  /// last character, kept inside the editor (above the end when there's no room below). nil: not on screen.
  func pillFrame() -> NSRect? {
    guard let ed = editor, let g = geometry, let v = cursor.visual, let e = cursor.visualEnd, e.columns > 0,
          let top = g.y(ofLine: v.endLine) else { return nil }
    let size = pill.intrinsicSize
    let lh = g.lineHeight
    let rowTop = top + CGFloat(e.wrap) * lh
    var y = rowTop + lh + 4
    if y + size.height > ed.bounds.height - 4 { y = rowTop - size.height - 4 }
    guard y >= 0, rowTop < ed.bounds.height else { return nil }
    let cell = ed.bounds.width / CGFloat(e.columns)
    let x = min(max(8, CGFloat(e.screenCol) * cell - 12), ed.bounds.width - size.width - 8)
    // The editor's coordinates are flipped (y down), like the margin's.
    return NSRect(x: x, y: ed.isFlipped ? y : ed.bounds.height - y - size.height, width: size.width, height: size.height)
  }

  private func placePill() {
    guard pillReady, draft == nil, let ed = editor, let host = ed.superview, let f = pillFrame() else {
      if !pill.isHidden { pill.isHidden = true }
      return
    }
    if pill.superview !== host { host.addSubview(pill, positioned: .above, relativeTo: ed) }
    let r = host.convert(f, from: ed)
    if pill.frame != r { pill.frame = r }
    if pill.isHidden { pill.isHidden = false }
  }

  /// Set by the window: it decides who takes the keys when the margin gives them back (History may cover the editor).
  public var onFocusEditor: (() -> Void)?

  /// Give the keyboard back to the editor (after sending or giving up a comment).
  func focusEditor() {
    if let onFocusEditor { return onFocusEditor() }
    if let ed = editor, ed.window === window { window?.makeFirstResponder(ed) }
  }

  /// Ask a yes/no question (`confirm` when set, else a sheet).
  func ask(_ q: String, info: String, button: String, _ done: @escaping @MainActor (Bool) -> Void) {
    if let confirm { return confirm(q, done) }
    let alert = NSAlert()
    alert.messageText = q
    alert.informativeText = info
    alert.addButton(withTitle: button)
    alert.addButton(withTitle: "Cancel")
    alert.buttons.first?.hasDestructiveAction = true
    if let w = window {
      alert.beginSheetModal(for: w) { done($0 == .alertFirstButtonReturn) }
    } else {
      done(alert.runModal() == .alertFirstButtonReturn)
    }
  }

  /// Asks for the range a new comment is about (ReviewController sets it: gui.lua's start_comment, which also
  /// finds a selection Neovim has just left). Unset: the last visual selection the cursor payload carried.
  public var onStartComment: (() -> Void)?

  /// The + button and ⌘⌥M: start a new comment on the selection.
  public func newComment() {
    if let onStartComment { onStartComment() } else { beginNewComment() }
  }

  /// A new card on `range` (the visual selection when nil), quoting `quote`. With no range: no card, a notice.
  public func beginNewComment(on range: ReviewRange? = nil, quote: String = "") {
    guard let r = range ?? cursor.visual, (r.endLine, r.endCol) > (r.line, r.col) else {
      notice("Select text to comment")
      return
    }
    pendingDraft = NewComment(
      item: ReviewItem(id: "draft", kind: .comment, author: state.meUser ?? me, color: state.meColor, quote: quote, range: r),
      buf: state.buf, end: lastVisualEnd)
    hidePill()
    selectedID = nil
    select("draft", focus: true)
  }

  /// The draft card's item (nil when no new comment is open).
  public var draftItem: ReviewItem? { draft }
  /// The card showing `id` ("draft" for a new comment), for tests.
  func card(_ id: String) -> ReviewCardView? { cards[id] }
  /// The selected card is open: expanded (not one line), with its reply field when it's a comment (for checks).
  public var selectedCardIsOpen: Bool {
    guard let id = selectedID, let c = cards[id] else { return false }
    return !c.isCompact && (c.item.kind != .comment || c.reply != nil || !state.supported)
  }
  func connectorLine(_ id: String) -> CAShapeLayer? { connectors[id] }

  /// A short message under the header that fades (no selection to comment on, and the like).
  public private(set) var noticeText: String?
  private let noticeLabel = NSTextField(labelWithString: "")
  private var noticeTimer: Timer?
  public func notice(_ text: String) {
    NSSound.beep()
    noticeText = text
    noticeLabel.stringValue = text
    noticeLabel.font = .systemFont(ofSize: 12, weight: .medium)
    noticeLabel.textColor = .secondaryLabelColor
    noticeLabel.alignment = .center
    if noticeLabel.superview == nil { addSubview(noticeLabel) }
    let h = noticeLabel.fittingSize.height
    noticeLabel.frame = NSRect(x: 0, y: Self.headerHeight + 10, width: bounds.width, height: h)
    noticeLabel.alphaValue = 1
    noticeLabel.isHidden = false
    noticeTimer?.invalidate()
    let t = Timer(timeInterval: 2.5, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; self.noticeLabel.animator().alphaValue = 0 }) {
          MainActor.assumeIsolated { self.noticeLabel.isHidden = true; self.noticeText = nil }
        }
      }
    }
    RunLoop.main.add(t, forMode: .common)
    noticeTimer = t
  }

  /// Focus the selected card's reply field and type `text` into it (ReviewHost's --type, for screenshots).
  public func typeInSelectedReply(_ text: String) {
    guard let id = selectedID, let card = cards[id], let r = card.reply else { return }
    guard let w = window else { return }
    w.makeFirstResponder(r)
    // Key events through the window, as typing does (the text view's own resizing included).
    for ch in text.map(String.init) {
      for type in [NSEvent.EventType.keyDown, .keyUp] {
        if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: w.windowNumber, context: nil, characters: ch, charactersIgnoringModifiers: ch,
                                    isARepeat: false, keyCode: 0) {
          w.sendEvent(e)
        }
      }
    }
  }

  @objc private func toggleResolved() { showResolved.toggle() }

  func perform(_ a: ReviewAction) {
    switch a {
    case let .select(id):
      select(id)
    case .delete:
      ask("Delete this comment?", info: "This deletes the comment and its replies from Overleaf for everyone. This can't be undone.", button: "Delete") { [weak self] ok in
        if ok { self?.onAction?(a) }
      }
    default:
      onAction?(a)
    }
  }

  // ---- feedback from the controller -----------------------------------------------------------------------------

  /// The action on `id` went through: clear its reply field (or the draft).
  public func actionSucceeded(_ a: ReviewAction) {
    switch a {
    case let .comment(range, text):
      // The draft stays (sending) until the comment comes back in a payload; then the new card takes its place.
      if pendingDraft != nil {
        pendingDraft?.sending = (text, range, Date())
        // It ends by itself: no payload is needed to notice it never came back.
        sendTimer?.invalidate()
        let t = Timer(timeInterval: sendTimeout + 0.01, repeats: false) { [weak self] _ in
          MainActor.assumeIsolated { self?.reload(animated: true) }
        }
        RunLoop.main.add(t, forMode: .common)
        sendTimer = t
      }
      onAction?(.select(nil))  // the draft's range stops being highlighted
      focusEditor()
      reload(animated: true)
    case let .reply(id, _):
      cards[id]?.clearReply()
      cards[id]?.error = nil
      floating.replied(id)
    default:
      if let id = a.id { cards[id]?.error = nil }
    }
  }

  /// The action failed: say so on its card.
  public func actionFailed(_ a: ReviewAction, _ message: String) {
    let id = a.id ?? (a.kind == "comment" ? "draft" : nil)
    if let id, paneHidden, floating.failed(id, message) {
    } else if let id, let card = cards[id] {
      card.error = message
      heights[id] = nil
      place()
    } else {
      NSSound.beep()
    }
  }

  /// "N min ago" moves on. Collapsed cards change one label (same height); only an expanded card, whose replies show
  /// times too, is rebuilt and measured again. Never a re-measure of every card in a scrolling frame.
  private func tickClock() {
    var changed = false
    for (id, card) in cards where card.reply.map({ window?.firstResponder !== $0 && $0.string.isEmpty }) ?? true {
      if card.refreshTime(Date()) {
        heights[id] = nil
        changed = true
      }
    }
    if changed { place() }
  }

  // ---- placement ------------------------------------------------------------------------------------------------

  var cardWidth: CGFloat { max(120, bounds.width - Self.outer - textGap) }

  /// The y (margin coordinates) of a buffer line's top.
  func lineY(_ line: Int) -> CGFloat {
    guard let g = geometry else { return Self.headerHeight + CGFloat(line) * 18 }
    if let y = g.y(ofLine: line) { return y + editorOffset }
    let v = g.visibleLines
    let base = g.y(ofLine: v.lowerBound) ?? 0
    return base + CGFloat(line - v.lowerBound) * g.lineHeight + editorOffset
  }

  private func height(_ item: ReviewItem) -> CGFloat {
    if let h = heights[item.id] { return h }
    let h = cards[item.id]?.height(for: cardWidth) ?? 60
    heights[item.id] = h
    heights["__width"] = cardWidth
    return h
  }

  /// The column's translation now. Exact from any card whose line is on screen and whose document row is known;
  /// else carried frame to frame by a reference line in the middle of the screen (its movement is the scroll).
  private func updateOffset() {
    guard let g = geometry else { return }
    let lh = g.lineHeight
    if lh != docLineHeight { docDirty = true }
    let v = g.visibleLines
    let whole = v
    var exact: CGFloat?
    for item in order {
      if let r = item.docRow, whole.contains(item.range.line), let y = g.y(ofLine: item.range.line) {
        exact = y + editorOffset - CGFloat(r) * lh
        break
      }
    }
    offsetSource = exact != nil ? "exact" : "ref"
    if let exact {
      columnOffset = exact
    } else if let r = ref, whole.contains(r.line), let y = g.y(ofLine: r.line) {
      columnOffset += y + editorOffset - r.y
    }
    let mid = (v.lowerBound + v.upperBound) / 2
    if let y = g.y(ofLine: mid) {
      ref = (mid, y + editorOffset)
    } else if let y = g.y(ofLine: v.lowerBound) {
      ref = (v.lowerBound, y + editorOffset)
    }
  }

  /// Measure cards not measured yet, a few per run-loop turn while idle, so a card coming on screen during a scroll
  /// has its height already (measuring text is the costly part of a frame).
  private func prewarmHeights() {
    guard !prewarming else { return }
    prewarming = true
    DispatchQueue.main.async { [weak self] in self?.prewarmStep() }
  }
  private func prewarmStep() {
    var n = 0
    for it in order where heights[it.id] == nil {
      _ = height(it)
      n += 1
      if n == 4 { break }
    }
    if order.contains(where: { heights[$0.id] == nil }) {
      DispatchQueue.main.async { [weak self] in self?.prewarmStep() }
    } else {
      prewarming = false
    }
  }

  /// Solve the stack in document space (only when something but the scroll changed).
  private func solveDoc() {
    let lh = geometry?.lineHeight ?? 18
    docLineHeight = lh
    // A card without a document row (the draft, a geometry without rows) is measured where its line is now.
    docAnchors = order.map { it in it.docRow.map { CGFloat($0) * lh } ?? (lineY(it.range.line) - columnOffset) }
    do {
      // Only the cards on screen stack (the others are in the pills): none is pushed by ones far away, and only
      // their heights are measured (measuring is the costly part).
      let idx = order.indices.filter { onScreen.contains(order[$0].id) }
      let sel = selectedID.flatMap { s in idx.firstIndex { order[$0].id == s } }
      let tops = ReviewLayout.stack(anchors: idx.map { docAnchors[$0] }, heights: idx.map { height(order[$0]) }, selected: sel, gap: Self.gap)
      docTops = Array(repeating: -1e7, count: order.count)
      for (k, i) in idx.enumerated() { docTops[i] = tops[k] }
      docDirty = false
      solveCount += 1
    }
  }

  /// Where each card should be now, with no animation.
  public func targetFrames() -> [String: CGRect] {
    if cardLayout == .stacked { return stackedFrames() }
    updateOffset()
    do {
      let now = onScreenIDs()
      if now != onScreen { onScreen = now; docDirty = true }
    }
    if docDirty || docTops.count != order.count { solveDoc() }
    var out: [String: CGRect] = [:]
    for (i, item) in order.enumerated() {
      if !onScreen.contains(item.id) { continue }
      // Right-aligned, toward the text.
      let x = bounds.width - textGap - cardWidth + (item.id == selectedID ? Self.selectedShift : 0)
      out[item.id] = CGRect(x: x, y: docTops[i] + columnOffset - overscroll, width: cardWidth, height: heights[item.id] ?? height(item))
    }
    do {
      // Adaptive: no card above the cards' area (a card whose line is too high sits at its top and the ones below
      // shift down); the draft or the selected card gets its whole height first, the ones before it moving up; what
      // doesn't fit at the bottom is counted in the ↓ pill. The line still goes from the card to its range.
      let top = cardsTop + 4, bottom = cardsBottom - 4
      let ids = order.map(\.id).filter { out[$0] != nil }
      var y = top
      for id in ids {
        var f = out[id]!
        if f.minY < y { f.origin.y = y }
        y = f.maxY + Self.gap
        out[id] = f
      }
      var over: Set<String> = []
      let prio = ids.first { $0 == "draft" } ?? ids.first { $0 == selectedID }
      if let p = prio, let i = ids.firstIndex(of: p), var f = out[p], f.maxY > bottom {
        f.origin.y = max(top, bottom - f.height)
        out[p] = f
        // The ones before it make room upwards (those pushed out of the top are left to the ↑ side)…
        var lim = f.minY - Self.gap
        for id in ids[..<i].reversed() {
          var g = out[id]!
          if g.maxY > lim { g.origin.y = lim - g.height }
          lim = g.minY - Self.gap
          out[id] = g
          if g.minY < top { over.insert(id) }
        }
        // …and the ones after it go under it.
        var yy = f.maxY + Self.gap
        for id in ids[(i + 1)...] {
          var g = out[id]!
          if g.minY < yy { g.origin.y = yy }
          yy = g.maxY + Self.gap
          out[id] = g
        }
      }
      for id in ids where id != prio {
        if let f = out[id], f.maxY > bottom { over.insert(id) }
      }
      overflow = over
      for id in over { out[id] = nil }
    }
    return out
  }

  /// A card's line on screen (its document anchor, translated): what the connector points at.
  private func anchorY(_ i: Int) -> CGFloat {
    i < docAnchors.count ? docAnchors[i] + columnOffset : lineY(order[i].range.line)
  }

  /// Frames as drawn (mid-animation included).
  public func displayedFrames() -> [String: CGRect] {
    var out: [String: CGRect] = [:]
    for (id, c) in cards { out[id] = c.frame }
    return out
  }

  private func progress() -> CGFloat {
    guard animating, animationDuration > 0 else { return 1 }
    let t = min(1, (now() - animStart) / animationDuration)
    return 1 - pow(1 - t, 3)
  }

  private func animate(from before: [String: CGRect]) {
    let targets = targetFrames()
    let e = progress()
    var next: [String: CGPoint] = [:]
    for (id, t) in targets {
      if let b = before[id], b != .zero {
        next[id] = CGPoint(x: b.minX - t.minX, y: b.minY - t.minY)
      } else if let d = deltas[id] {
        next[id] = CGPoint(x: d.x * (1 - e), y: d.y * (1 - e))
      }
    }
    deltas = next
    animStart = now()
    if animationDuration > 0, window != nil {
      animating = true
      if window?.screen == nil {
        // No display to sync to (an off-screen window): tick at 60 Hz instead.
        if fallback == nil {
          let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.step() } }
          RunLoop.main.add(t, forMode: .common)
          fallback = t
        }
      } else if link == nil {
        let l = displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
      }
    } else {
      deltas = [:]
      for c in cards.values { c.alphaValue = 1 }
    }
    place()
  }

  @objc private func tick(_ l: CADisplayLink) { step() }

  private func step() {
    place()
    if progress() >= 1 {
      animating = false
      link?.invalidate()
      link = nil
      fallback?.invalidate()
      fallback = nil
      deltas = [:]
      place()
    }
  }

  /// TAUDOT_MARGIN_TRACE=<file>: one line per place(): time, its cost, and for each card on screen that sits at its
  /// anchor (not pushed, not animating) card y − line y, which must stay constant while scrolling.
  static func traceLine(_ s: String) {
    guard let f = traceFile else { return }
    f.write(String(format: "%.4f %@\n", CACurrentMediaTime(), s).data(using: .utf8)!)
  }
  private static let traceFile: FileHandle? = {
    guard let p = ProcessInfo.processInfo.environment["TAUDOT_MARGIN_TRACE"] else { return nil }
    FileManager.default.createFile(atPath: p, contents: nil)
    return FileHandle(forWritingAtPath: p)
  }()

  /// Put every card where it belongs this frame. Called on every geometry change (each frame of a smooth scroll), in
  /// the editor's display-link tick, so it must stay cheap: frames only, no layout, no implicit animation.
  public func place() {
    // No explicit CATransaction: in a display-link tick with no implicit one open yet, committing our own would send
    // the whole tree to the render server right here, every frame. Card views (layer-backed NSViews) don't animate
    // frame changes, and the connector layers have no actions, so the run loop's implicit commit draws this frame.
    let t0 = Self.traceFile != nil ? CACurrentMediaTime() : 0
    defer { if let f = Self.traceFile { trace(f, t0) } }
    let targets = targetFrames()
    let e = progress()
    let lh = geometry?.lineHeight ?? 18
    let lines = connectorStyle
    // The lines are drawn in the margin's coordinates: the layer covers the cards' clip and its own coordinates start
    // where the clip's bounds do (they start at cardsTop, not 0).
    if connectorLayer.frame != content.bounds { connectorLayer.frame = content.bounds }
    if connectorLayer.bounds.origin != content.bounds.origin { connectorLayer.bounds.origin = content.bounds.origin }
    for (index, item) in order.enumerated() {
      guard let card = cards[item.id] else { continue }
      guard previewMode == nil, var f = targets[item.id] else {
        // Off screen (visible-only designs): no card, no line.
        if !card.isHidden { card.isHidden = true }
        connectors[item.id]?.isHidden = true
        continue
      }
      if let d = deltas[item.id] {
        f.origin.x += d.x * (1 - e)
        f.origin.y += d.y * (1 - e)
      }
      if card.appear < 1 { card.appear = !animating ? 1 : max(card.appear, e) }
      // While a new comment is written the other cards step back.
      let alpha = card.appear * (draft != nil && item.id != "draft" ? 0.5 : 1)
      if card.alphaValue != alpha { card.alphaValue = alpha }
      if card.frame != f { card.frame = f }
      let onScreen = f.maxY > -200 && f.minY < bounds.height + 200
      if card.isHidden == onScreen { shownThisFrame += onScreen ? 1 : 0; card.isHidden = !onScreen }
      // Connector: from the line, at mid-height, to the card's header.
      let line = connectors[item.id]!
      let ay = anchorY(index) + lh / 2
      let sel = item.id == selectedID
      let active = sel || item.id == hoveredID || hereIDs.contains(item.id)
      let textShown = geometry.map { $0.visibleLines.contains(item.range.line) } ?? true
      let wantsLine = cardLayout == .stacked ? (sel && textShown) : (lines == .all || (lines == .selected && active))
      if onScreen && wantsLine {
        // From the card's edge to a small dot at the panel/editor seam, at its text's row; never over the gutter or
        // the text (the range's own tint, brighter when active, does the rest).
        let host = connectorHost
        let start = host.from(CGPoint(x: f.maxX, y: min(f.minY + 26, f.midY)))
        let end = textStart(item, index: index) ?? host.from(CGPoint(x: bounds.width - Self.dotRadius - 1, y: ay))
        let span = end.x - start.x
        let p = CGMutablePath()
        p.move(to: start)
        p.addCurve(to: end, control1: CGPoint(x: start.x + span * 0.55, y: start.y), control2: CGPoint(x: end.x - span * 0.45, y: end.y))
        let r = Self.dotRadius
        p.addEllipse(in: CGRect(x: end.x - r, y: end.y - r, width: 2 * r, height: 2 * r))
        line.path = p
        if line.isHidden { line.isHidden = false }
        // The active one (selected, hovered, the cursor in it) bold in full colour; the rest thin and muted.
        let style = "\(active)\(isDark)"
        let alpha = Float(card.alphaValue) * (active ? 1 : 0.35)
        if line.name != style {
          let animate = line.name != nil
          line.name = style
          effectiveAppearance.performAsCurrentDrawingAppearance {
            line.strokeColor = item.authorColor.readable(dark: isDark).cgColor
          }
          let width: CGFloat = active ? 2 : 1
          if animate {
            for (key, from, to) in [("lineWidth", line.lineWidth as Any, width as Any), ("opacity", line.opacity as Any, alpha as Any)] {
              let a = CABasicAnimation(keyPath: key)
              a.fromValue = from
              a.toValue = to
              a.duration = 0.12
              a.timingFunction = CAMediaTimingFunction(name: .easeOut)
              line.add(a, forKey: key)
            }
          }
          line.lineWidth = width
        }
        if line.opacity != alpha { line.opacity = alpha }
      } else {
        line.isHidden = true
      }
    }
    placePill()
    floating.place()
    placeDesignChrome()
    placeOverlayMask()
  }

  // ---- the lines over both panes ----------------------------------------------------------------------------------

  /// Ids under the cursor (their lines are emphasised too).
  private var hereIDs: Set<String> { Set(cardIDs(cursor.here)) }

  /// Where the lines are drawn: an overlay over the window's content when the editor is in this window (so a line
  /// reaches into the text), else the cards' own layer. `from` maps a point in the margin's coordinates there.
  private var connectorHost: (layer: CALayer, from: (CGPoint) -> CGPoint) {
    if let o = attachOverlay() {
      return (o.layer!, { [unowned self] p in o.convert(p, from: self) })
    }
    // (back from the overlay: the pane hidden, the editor elsewhere)
    for l in connectors.values where l.superlayer !== connectorLayer { connectorLayer.addSublayer(l) }
    return (connectorLayer, { $0 })
  }

  private func attachOverlay() -> ConnectorOverlay? {
    guard let w = window, let cv = w.contentView, let ed = editor, ed.window === w, !paneHidden else {
      overlay?.isHidden = true
      return nil
    }
    let o: ConnectorOverlay
    if let x = overlay, x.superview === cv { o = x } else {
      overlay?.removeFromSuperview()
      o = ConnectorOverlay(frame: cv.bounds)
      o.autoresizingMask = [.width, .height]
      cv.addSubview(o, positioned: .above, relativeTo: nil)
      overlay = o
    }
    if o.isHidden { o.isHidden = false }
    if o.frame != cv.bounds { o.frame = cv.bounds }
    // The lines move into it (they were in the cards' layer before it existed).
    for l in connectors.values where l.superlayer !== o.layer { o.layer?.addSublayer(l) }
    return o
  }

  static let dotRadius: CGFloat = 2.5

  /// Where an item's line ends, in the host's coordinates: at the seam between the panel and the editor (the dot
  /// just inside the panel), at the vertical middle of the screen row its text starts on.
  private func textStart(_ item: ReviewItem, index: Int) -> CGPoint? {
    // (a group, or a group of pairs: its first raw change)
    var it = item
    while let m = it.members.first { it = m }
    guard let o = overlay, !o.isHidden, let ed = editor, let g = geometry,
          let y = g.y(ofLine: it.startLine ?? it.range.line) else { return nil }
    let lh = g.lineHeight
    let p = o.convert(CGPoint(x: ed.bounds.minX, y: y + CGFloat(it.startWrap ?? 0) * lh + lh / 2), from: ed)
    let seam = o.convert(CGPoint(x: bounds.maxX, y: 0), from: self).x
    return CGPoint(x: min(p.x, seam) - Self.dotRadius - 1, y: p.y)
  }

  /// Lines show only over the cards' area and the editor's text (not over headers, pills, the status bar).
  private func placeOverlayMask() {
    guard let o = overlay, !o.isHidden, let ed = editor else { return }
    let a = o.convert(content.frame, from: self), b = o.convert(ed.bounds, from: ed)
    // (the cards' area only: the lines end at the seam, never over the gutter or the text)
    _ = b
    let path = CGMutablePath()
    path.addRect(a)
    if o.mask.frame != o.bounds { o.mask.frame = o.bounds }
    o.mask.path = path
  }

  /// The pills and the rail, for the visible-only designs.
  private func placeDesignChrome() {
    guard let g = geometry, cardLayout == .beside else {
      if !abovePill.isHidden { abovePill.isHidden = true }
      if !belowPill.isHidden { belowPill.isHidden = true }
      return
    }
    let v = g.visibleLines
    abovePill.count = order.filter { $0.id != "draft" && $0.range.endLine < v.lowerBound }.count
    belowPill.count = order.filter { $0.id != "draft" && ($0.range.line > v.upperBound || overflow.contains($0.id)) }.count
    let cx = bounds.width - textGap - cardWidth / 2
    layoutContentClip()
    for (pill, y) in [(abovePill, cardsTop - Self.pillStrip + 4), (belowPill, cardsBottom + 4)] {
      let w = pill.fitWidth
      let f = NSRect(x: (cx - w / 2).rounded(), y: y, width: w, height: 22)
      if pill.frame != f { pill.frame = f }
    }
  }

  // ---- scrolling over the margin -----------------------------------------------------------------------------------
  // A scroll over the margin scrolls the editor (the same event, moved onto the editor's text: its pixel-smooth path,
  // momentum and all), so cards and text move together. At the buffer's end (start), cards stacked past the margin's
  // bottom (top) can be pulled into view by pushing on; they settle back when the fingers lift.

  /// How far the cards are lifted (positive: up, showing ones below) past where their lines put them.
  public private(set) var overscroll: CGFloat = 0
  /// The margin's top this much is under something (the sidebar's header): cards there aren't visible.
  public var coveredTop: CGFloat = 0
  /// Off in the Quiet design (the pills take what doesn't fit).
  public var overscrollEnabled = false
  /// Settling back, in seconds.
  public var overscrollSettle: CFTimeInterval = 0.3
  private var settleFrom: CGFloat = 0, settleStart: CFTimeInterval = 0
  private var settleTimer: Timer?

  /// How far the cards could be lifted now: (up to show the top ones ≤ 0, down to show the bottom ones ≥ 0), each
  /// only at that end of the buffer.
  public func overscrollRange() -> (lo: CGFloat, hi: CGFloat) {
    // Quiet: cards are only for text on screen and what doesn't fit is in the ↓ pill, so there is nothing to pull
    // into view; the gesture just scrolls the editor.
    if !overscrollEnabled { return (0, 0) }
    guard let g = geometry, !order.isEmpty else { return (0, 0) }
    let o = overscroll
    overscroll = 0
    let fs = targetFrames().values
    overscroll = o
    let pad: CGFloat = 12
    let v = g.visibleLines
    let atEnd = state.lineCount.map { v.upperBound >= $0 - 1 } ?? false
    let atStart = v.lowerBound == 0
    let hi = atEnd ? max(0, (fs.map(\.maxY).max() ?? 0) + pad - bounds.height) : 0
    let lo = atStart ? min(0, (fs.map(\.minY).min() ?? 0) - pad - coveredTop) : 0
    return (lo, hi)
  }

  func setOverscroll(_ v: CGFloat) {
    guard v != overscroll else { return }
    overscroll = v
    place()
  }

  public override func scrollWheel(with e: NSEvent) {
    if cardLayout == .stacked {
      // The list scrolls on its own (the editor stays).
      scrollStack(by: -e.scrollingDeltaY * (e.hasPreciseScrollingDeltas ? 1 : (geometry?.lineHeight ?? 18) * 3))
      return
    }
    let fingers = e.momentumPhase == [] && (e.phase == .began || e.phase == .changed)
    if fingers {
      settleTimer?.invalidate()
      settleTimer = nil
      // Points the content moves up (natural scrolling applied): a mouse wheel's lines as text lines.
      let push = -e.scrollingDeltaY * (e.hasPreciseScrollingDeltas ? 1 : (geometry?.lineHeight ?? 18) * 3)
      var o = overscroll
      if o != 0 && (o > 0) != (push > 0) {
        // Back toward where the lines put them first; the editor stays.
        o = o > 0 ? max(0, o + push) : min(0, o + push)
        setOverscroll(o)
        return
      }
      let (lo, hi) = overscrollRange()
      if (push > 0 && hi > 0) || (push < 0 && lo < 0) {
        // At this end of the buffer the editor can't go on: lift the cards, 1:1 up to the hidden ones, then harder.
        let lim = push > 0 ? hi : lo
        let next = o + push
        let over = abs(next) - abs(lim)
        o = over > 0 ? (lim + (push > 0 ? 1 : -1) * min(40, over * 0.25)) : next
        setOverscroll(o)
        return
      }
    }
    if e.phase == .ended || e.phase == .cancelled || (e.momentumPhase == .began && overscroll != 0) { settleOverscroll() }
    if overscroll != 0 && e.momentumPhase != [] { return }  // the lift's own momentum: ignored, it settles
    forwardScroll(e)
  }

  /// Back to 0, eased out.
  public func settleOverscroll() {
    guard overscroll != 0 else { return }
    settleTimer?.invalidate()
    if overscrollSettle <= 0 { setOverscroll(0); return }
    settleFrom = overscroll
    settleStart = CACurrentMediaTime()
    let t = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        let k = min(1, (CACurrentMediaTime() - self.settleStart) / self.overscrollSettle)
        self.setOverscroll(k >= 1 ? 0 : self.settleFrom * CGFloat(pow(1 - k, 3)))
        if k >= 1 { self.settleTimer?.invalidate(); self.settleTimer = nil }
      }
    }
    RunLoop.main.add(t, forMode: .common)
    settleTimer = t
  }

  /// The event as if it happened over the editor's text, at the same height: the editor scrolls as under the finger.
  /// (Its scroll path finds Neovim's window under the event's location.)
  func forwardScroll(_ e: NSEvent) {
    guard let ed = editor, let w = ed.window ?? window, let src = e.cgEvent,
          let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: 0, wheel3: 0) else { return }
    // A fresh event, not a copy: a real event's copy keeps its window, and AppKit then takes its locationInWindow
    // from the original (window-local) point over the panel, whatever location is set, so the editor found no text
    // under it and dropped the scroll. Without a window, the location set here (screen coordinates) is what counts.
    for f: CGEventField in [.scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2, .scrollWheelEventPointDeltaAxis1,
                            .scrollWheelEventPointDeltaAxis2, .scrollWheelEventIsContinuous, .scrollWheelEventScrollPhase,
                            .scrollWheelEventMomentumPhase, .scrollWheelEventScrollCount] {
      cg.setIntegerValueField(f, value: src.getIntegerValueField(f))
    }
    for f: CGEventField in [.scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2] {
      cg.setDoubleValueField(f, value: src.getDoubleValueField(f))
    }
    cg.flags = src.flags
    cg.timestamp = src.timestamp
    // (an event without a window, a synthetic one, carries screen coordinates)
    let local = ed.convert(e.window == nil ? w.convertPoint(fromScreen: e.locationInWindow) : e.locationInWindow, from: nil)
    let pt = NSPoint(x: ed.bounds.midX, y: min(max(local.y, ed.bounds.minY + 1), ed.bounds.maxY - 1))
    let screen = w.convertPoint(toScreen: ed.convert(pt, to: nil))
    let top = NSScreen.screens.first?.frame.maxY ?? 0
    cg.location = CGPoint(x: screen.x, y: top - screen.y)
    guard let moved = NSEvent(cgEvent: cg) else { return }
    ScrollEventTrace.note("forwarded to the editor at \(NSStringFromPoint(pt)), window \(moved.window == nil ? "none" : "set")")
    ed.scrollWheel(with: moved)
  }

  private var shownThisFrame = 0
  private func trace(_ f: FileHandle, _ t0: CFTimeInterval) {
    defer { shownThisFrame = 0 }
    let dt = (CACurrentMediaTime() - t0) * 1000
    var parts: [String] = []
    if !animating, let g = geometry {
      for item in order {
        // (only lines on screen: elsewhere y(ofLine:) is the editor's estimate, not where the line is)
        guard let c = cards[item.id], !c.isHidden, g.visibleLines.contains(item.range.line), let y = g.y(ofLine: item.range.line) else { continue }
        let off = c.frame.minY - (y + editorOffset)
        if abs(off) < 0.01 || parts.count < 6 { parts.append(String(format: "%@=%.2f", String(item.id.suffix(8)), off)) }
      }
    }
    var geo = ""
    if let g = geometry {
      let v = g.visibleLines
      geo = String(format: " | off %.2f %@ vis %d-%d", columnOffset, offsetSource, v.lowerBound, v.upperBound)
      for item in order {
        geo += " L\(item.range.line):" + (g.y(ofLine: item.range.line).map { String(format: "%.1f", $0) } ?? "-") + "/\(item.docRow ?? -1)"
      }
    }
    let line = String(format: "%.4f place %.3f ms top %.2f shown %d %@%@\n", t0, dt, geometry?.y(ofLine: geometry?.visibleLines.lowerBound ?? 0) ?? 0,
                      shownThisFrame, parts.joined(separator: " "), geo)
    f.write(line.data(using: .utf8)!)
  }
}
