// One card in the margin: a comment thread or a tracked change.
import AppKit
import TaudotShared

/// What the margin asks for. `ReviewController` sends these to gui.lua's `act`.
public enum ReviewAction: Equatable, Sendable {
  case select(String?)
  case reply(String, text: String)
  case resolve(String), reopen(String), delete(String)
  case editMessage(String, messageID: String, text: String)
  case deleteMessage(String, messageID: String)
  case accept(String), reject(String)
  case goto(String)
  case comment(ReviewRange, text: String)
  /// A file from the sidebar's tree, edited in Neovim (its path).
  case open(String)
  /// The overview: open the file at the item (gui.lua's reveal).
  case reveal(String, path: String)
  /// Tracked changes together (a grouped card, a whole file).
  case acceptAll([String]), rejectAll([String])

  /// gui.act's kind.
  public var kind: String {
    switch self {
    case .select: "select"
    case .reply: "reply"
    case .resolve: "resolve"
    case .reopen: "reopen"
    case .delete: "delete"
    case .editMessage: "edit_message"
    case .deleteMessage: "delete_message"
    case .accept: "accept"
    case .reject: "reject"
    case .goto: "goto"
    case .comment: "comment"
    case .open: "open"
    case .reveal: "reveal"
    case .acceptAll: "accept_many"
    case .rejectAll: "reject_many"
    }
  }
  public var id: String? {
    switch self {
    case let .select(id): id
    case let .reply(id, _), let .resolve(id), let .reopen(id), let .delete(id), let .accept(id), let .reject(id), let .goto(id), let .reveal(id, _):
      id
    case let .editMessage(id, _, _), let .deleteMessage(id, _): id
    case .comment, .open, .acceptAll, .rejectAll: nil
    }
  }
}

/// A round avatar with the author's initials.
final class AvatarView: NSView {
  private let label = NSTextField(labelWithString: "")
  var color: NSColor = .systemBlue { didSet { needsDisplay = true } }
  init(initials: String, color: NSColor, size: CGFloat) {
    self.color = color
    super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
    wantsLayer = true
    label.stringValue = String(initials.prefix(2))
    label.font = .systemFont(ofSize: size * 0.42, weight: .semibold)
    label.alignment = .center
    addSubview(label)
  }
  required init?(coder: NSCoder) { fatalError() }
  override var wantsUpdateLayer: Bool { true }
  override func updateLayer() {
    layer?.cornerRadius = bounds.width / 2
    layer?.backgroundColor = color.cgColor
    let c = color.usingColorSpace(.sRGB) ?? color
    let lum = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
    label.textColor = lum > 0.6 ? .black : .white
  }
  override func layout() {
    super.layout()
    let h = label.fittingSize.height
    label.frame = NSRect(x: 0, y: (bounds.height - h) / 2, width: bounds.width, height: h)
  }
  override var isFlipped: Bool { true }
}

@MainActor final class ReviewCardView: NSView {
  private(set) var item: ReviewItem
  var expanded = false { didSet { if expanded != oldValue { rebuild() } } }
  var canReply = true { didSet { if canReply != oldValue { rebuild() } } }
  /// A new comment not yet sent (item.id is "draft").
  var isDraft = false { didSet { if isDraft != oldValue { rebuild() } } }
  var onSelect: (() -> Void)?
  var onAction: ((ReviewAction) -> Void)?
  /// The card's size changed (reply field grew).
  var onResize: (() -> Void)?
  /// Shown under the reply field after a failed action.
  var error: String? { didSet { if error != oldValue { if error != nil { sending = false }; rebuild() } } }
  /// Esc or Cancel: `typed` when the field has text (the margin asks before throwing it away). Unset: give up at once.
  var onCancel: ((_ typed: Bool) -> Void)?
  /// Sent, waiting for the engine: the field and the button are off.
  var sending = false { didSet { if sending != oldValue { updateSend() } } }
  /// 0...1 while a new card fades in; the margin multiplies it with the dimming.
  var appear: CGFloat = 1
  /// Fully opaque (a floating card over the text).
  var solid = false { didSet { if solid != oldValue { updateLayer() } } }
  /// Direction A (Quiet): initials, name and time on one line, the message; no quote; actions only on hover.
  var quiet = false { didSet { if quiet != oldValue { rebuild() } } }
  /// The pointer is over it (Quiet shows its actions; the connector modes may show its line).
  var hovered = false { didSet { if hovered != oldValue { updateHover(); onHover?(hovered) } } }
  var onHover: ((Bool) -> Void)?
  private var hoverArea: NSTrackingArea?
  private var sendButton: NSButton?
  var now = Date()

  private(set) var reply: ReplyTextView?
  private var replyBox: NSView?
  private var rows: [(NSView, CGFloat)] = []  // view, left inset
  private var buttons: [NSButton] = []

  static let pad: CGFloat = 12

  /// TAUDOT_MARGIN_MARKERS=1: a pure green 6 pt square in each card's top-left corner, so a screen capture can
  /// find exactly where each card is drawn (Tests/review_capture).
  static let markers = ProcessInfo.processInfo.environment["TAUDOT_MARGIN_MARKERS"] != nil
  private var marker: CALayer?

  init(item: ReviewItem) {
    self.item = item
    super.init(frame: .zero)
    wantsLayer = true
    if Self.markers {
      let m = CALayer()
      m.backgroundColor = CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
      m.frame = CGRect(x: 2, y: 2, width: 6, height: 6)
      m.zPosition = 100
      m.actions = ReviewMarginView.noActions
      layer?.addSublayer(m)
      marker = m
    }
    layer?.cornerRadius = 10
    layer?.masksToBounds = false
    shadow = NSShadow()
    rebuild()
  }
  required init?(coder: NSCoder) { fatalError() }
  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }

  func update(_ item: ReviewItem) {
    guard item != self.item else { return }
    var moved = item
    moved.range = self.item.range
    moved.docRow = self.item.docRow
    let same = moved == self.item
    self.item = item
    // A move alone (the text was edited around it) changes nothing on the card: keep the reply field as it is.
    if !same { rebuild() }
  }

  var isSelected = false {
    didSet { if isSelected != oldValue { needsDisplay = true; updateLayer() } }
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let a = hoverArea { removeTrackingArea(a) }
    let a = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
    addTrackingArea(a)
    hoverArea = a
  }
  override func mouseEntered(with event: NSEvent) { hovered = true }
  override func mouseExited(with event: NSEvent) { hovered = false }

  /// Quiet: the header's buttons show while hovered or selected.
  private func updateHover() {
    guard quiet, compact == nil else { return }
    for b in buttons { b.isHidden = !(hovered || expanded) }
    if !solid { updateLayer() }
  }

  override func updateLayer() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      if quiet && !solid && !isDraft {
        // No frame, no shadow: a faint plate that firms up when hovered or selected.
        let a: CGFloat = isSelected ? (dark ? 0.10 : 0.92) : hovered ? (dark ? 0.07 : 0.75) : (dark ? 0.04 : 0.55)
        layer?.backgroundColor = (dark ? NSColor(white: 1, alpha: a) : NSColor(white: 1, alpha: a)).cgColor
        layer?.borderWidth = 0
        layer?.shadowOpacity = isSelected ? (dark ? 0.35 : 0.10) : 0
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        updateShadowPath()
        return
      }
      let bg = dark ? NSColor(white: 0.17, alpha: solid ? 1 : 0.96) : NSColor(white: 1, alpha: solid ? 1 : 0.97)
      layer?.backgroundColor = (item.resolved ? bg.blended(withFraction: 0.35, of: .windowBackgroundColor) ?? bg : bg).cgColor
      if isDraft {
        // A new comment is framed in my author colour, like its text in the editor.
        layer?.borderWidth = 1.5
        layer?.borderColor = item.authorColor.readable(dark: dark).cgColor
      } else {
        layer?.borderWidth = isSelected ? 0 : 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor
      }
      layer?.shadowColor = NSColor.black.cgColor
      layer?.shadowOpacity = isSelected ? (dark ? 0.55 : 0.22) : (dark ? 0.25 : 0.06)
      layer?.shadowRadius = isSelected ? 10 : 2
      layer?.shadowOffset = CGSize(width: 0, height: isSelected ? -3 : -1)
      updateShadowPath()
    }
  }

  // Without a path, Core Animation renders the shadow offscreen from the layer's alpha every time the card moves:
  // a cost on every scrolled frame. With one, moving the card is a translation.
  private func updateShadowPath() {
    guard let l = layer else { return }
    let r = l.bounds
    if l.shadowPath.map({ $0.boundingBox != r }) ?? true {
      l.shadowPath = CGPath(roundedRect: r, cornerWidth: l.cornerRadius, cornerHeight: l.cornerRadius, transform: nil)
    }
  }
  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    updateShadowPath()
    CATransaction.commit()
  }

  // ---- content --------------------------------------------------------------------------------------------------

  private func label(_ s: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = .labelColor, lines: Int = 0, italic: Bool = false) -> NSTextField {
    let l = NSTextField(wrappingLabelWithString: s)
    var font = NSFont.systemFont(ofSize: size, weight: weight)
    if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
    l.font = font
    l.textColor = color
    l.isSelectable = false
    l.maximumNumberOfLines = lines
    l.lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
    l.cell?.truncatesLastVisibleLine = true
    return l
  }

  private func button(_ symbol: String, _ tip: String, tint: NSColor? = nil, _ action: ReviewAction) -> NSButton {
    let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage(), target: nil, action: nil)
    b.isBordered = false
    b.bezelStyle = .accessoryBarAction
    // The key, for a non-Neovim user to find (the pane's, and the Review menu's from any pane).
    let key: String? = tip.hasPrefix("Accept") ? "⌘↩ · ⌥⌘↩" : tip.hasPrefix("Reject") ? "⌘⌫ · ⌥⌘⌫" : tip == "Resolve" ? "⌘R · ⌥⌘R" : tip == "Reply" ? "↩" : nil
    b.toolTip = key.map { "\(tip)  \($0)" } ?? tip
    b.setAccessibilityLabel(tip)
    b.contentTintColor = tint ?? .secondaryLabelColor
    b.symbolConfiguration = .init(pointSize: 13, weight: .medium)
    b.frame.size = NSSize(width: 24, height: 24)
    let handler = ButtonHandler { [weak self] in self?.onAction?(action) }
    b.target = handler
    b.action = #selector(ButtonHandler.fire)
    objc_setAssociatedObject(b, &ButtonHandler.key, handler, .OBJC_ASSOCIATION_RETAIN)
    return b
  }

  static func ago(_ d: Date?, now: Date) -> String {
    guard let d else { return "" }
    let s = now.timeIntervalSince(d)
    if s < 60 { return "just now" }
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .short
    if s < 7 * 86400 { return f.localizedString(for: d, relativeTo: now) }
    let df = DateFormatter()
    df.setLocalizedDateFormatFromTemplate("d MMM")
    return df.string(from: d)
  }

  private func oneLine(_ s: String) -> String {
    s.replacingOccurrences(of: "\n", with: " ↵ ")
  }

  private var header: (avatar: AvatarView, name: NSTextField, time: NSTextField)?

  /// The header's time text at `now`.
  private func timeText(_ now: Date) -> String {
    let it = item
    var when = Self.ago(it.messages.first?.ts ?? it.ts, now: now)
    if it.isAddedThenRemoved {
      let a = it.members[0].ts, d = it.members[1].ts
      return "Added \(Self.ago(a, now: now)) · removed \(Self.ago(d, now: now))"
    } else if it.isGroup || it.isReplacement {
      when = ["Suggested", when].filter { !$0.isEmpty }.joined(separator: " · ")
    } else if it.kind != .comment {
      when = [it.kind == .insert ? "Added" : "Deleted", when].filter { !$0.isEmpty }.joined(separator: " · ")
    }
    return when
  }

  /// Move the clock on. Returns true when the card was rebuilt (its height may have changed).
  func refreshTime(_ date: Date) -> Bool {
    now = date
    if expanded {
      rebuild()
      return true
    }
    let t = timeText(date)
    if let time = header?.time, time.stringValue != t { time.stringValue = t }
    return false
  }

  func rebuild() {
    let replyText = reply?.string
    let hadFocus = reply.map { window?.firstResponder === $0 } ?? false
    subviews.forEach { $0.removeFromSuperview() }
    rows = []
    buttons = []
    reply = nil
    replyBox = nil
    let it = item
    let color = it.authorColor
    compact = nil
    if !isDraft && it.kind != .comment && !expanded {
      buildCompact()
      return
    }

    // Header: avatar, name, time; buttons on the right.
    let first = it.messages.first
    let who = first?.user ?? it.author
    let q = quiet && it.kind == .comment && !isDraft
    let avatar = AvatarView(initials: who.initials, color: color, size: q ? 20 : 28)
    let name = label(it.isGroup && !it.isPair ? "\(who.name) · \(it.members.count) changes" : who.name, size: 13, weight: .semibold, lines: 1)
    if isDraft {
      let t = NSMutableAttributedString(string: who.name, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor])
      t.append(NSAttributedString(string: "   new comment", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]))
      name.attributedStringValue = t
    }
    let time = label(isDraft ? "" : timeText(now), size: 11, color: .secondaryLabelColor, lines: 1)
    if q {
      // One line: name, then the time in grey.
      let t = NSMutableAttributedString(string: who.name, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor])
      t.append(NSAttributedString(string: "  " + timeText(now), attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor]))
      name.attributedStringValue = t
      time.stringValue = ""
    }
    [avatar, name, time].forEach(addSubview)
    header = (avatar, name, time)

    if !isDraft {
      switch it.kind {
      case .comment:
        if it.resolved {
          buttons.append(button("arrow.uturn.backward.circle", "Reopen", .reopen(it.id)))
        } else if canReply {
          buttons.append(button("checkmark.circle", "Resolve", tint: .systemBlue, .resolve(it.id)))
        }
        // Deleting is for good (resolving can be undone): behind •••, and asked first.
        if canReply { buttons.append(moreButton()) }
      case .insert where it.isPair, .delete where it.isPair:
        buttons += pairButtons(it)
      case .insert where it.isGroup, .delete where it.isGroup:
        break  // Accept all / Reject all under the list
      case .insert, .delete:
        buttons.append(button("checkmark", "Accept", tint: .systemGreen, .accept(it.id)))
        buttons.append(button("xmark", "Reject", tint: .systemRed, .reject(it.id)))
      }
    }
    buttons.forEach(addSubview)

    if q {
      // A reply affordance with the hover actions.
      buttons.insert(button("arrowshape.turn.up.left", "Reply", .goto(it.id)), at: 0)
      buttons[0].target = nil
      let h = ButtonHandler { [weak self] in self?.onSelect?() }
      buttons[0].target = h
      buttons[0].action = #selector(ButtonHandler.fire)
      objc_setAssociatedObject(buttons[0], &ButtonHandler.key, h, .OBJC_ASSOCIATION_RETAIN)
      for b in buttons { b.isHidden = !(hovered || expanded) }
    }

    // The text it is about.
    switch it.kind {
    case .comment where q:
      break  // Quiet: the tint in the editor is the link, no quote
    case .comment where it.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
      break  // a new comment's draft: nothing quoted yet
    case .comment:
      // A draft quotes what it will be anchored to, up to 3 lines (then …), its line breaks as spaces.
      let text = isDraft
        ? it.quote.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
          .trimmingCharacters(in: .whitespaces)
        : oneLine(it.quote)
      // Upright: in italics a backslash leans until it reads as "|" ("\\usepackage" → "|usepackage").
      let q = label("“" + text + "”", size: 12, color: .secondaryLabelColor, lines: isDraft ? 3 : expanded ? 4 : 1)
      let bar = QuoteBar(color: color, content: q)
      rows.append((bar, 0))
    case .insert where it.isPair, .delete where it.isPair:
      let q = NSTextField(wrappingLabelWithString: "")
      q.isSelectable = false
      q.maximumNumberOfLines = 6
      q.cell?.truncatesLastVisibleLine = true
      q.attributedStringValue = Self.plain(it, size: 13)
      rows.append((q, 0))
    case .insert where it.isGroup, .delete where it.isGroup:
      let shownN = 30
      for m in it.members.prefix(shownN) {
        let l = NSTextField(labelWithAttributedString: Self.plain(m, size: 13))
        l.lineBreakMode = .byTruncatingTail
        l.maximumNumberOfLines = 1
        rows.append((l, 0))
      }
      if it.members.count > shownN {
        rows.append((label("… \(it.members.count - shownN) more", size: 11, color: .secondaryLabelColor, lines: 1), 0))
      }
      let reject = NSButton(title: "Reject all", target: nil, action: nil)
      reject.isBordered = false
      reject.font = .systemFont(ofSize: 13, weight: .medium)
      reject.contentTintColor = .systemRed
      let rh = ButtonHandler { [weak self] in self?.onAction?(.rejectAll(it.changeIDs)) }
      reject.target = rh
      reject.action = #selector(ButtonHandler.fire)
      objc_setAssociatedObject(reject, &ButtonHandler.key, rh, .OBJC_ASSOCIATION_RETAIN)
      let accept = FilledButton(title: "Accept all")
      let ah = ButtonHandler { [weak self] in self?.onAction?(.acceptAll(it.changeIDs)) }
      accept.target = ah
      accept.action = #selector(ButtonHandler.fire)
      objc_setAssociatedObject(accept, &ButtonHandler.key, ah, .OBJC_ASSOCIATION_RETAIN)
      rows.append((ButtonRow(buttons: [reject, accept]), 0))
    case .insert, .delete:
      let q = NSTextField(wrappingLabelWithString: "")
      q.isSelectable = false
      q.maximumNumberOfLines = expanded ? 6 : 2
      q.cell?.truncatesLastVisibleLine = true
      q.attributedStringValue = Self.plain(it, size: 13)
      rows.append((q, 0))
    }

    // Messages.
    if it.kind == .comment {
      if let first {
        rows.append((label(first.text, lines: expanded ? 0 : 3), 0))
      } else if !isDraft && !canReply {
        rows.append((label("This server has no comment threads", size: 12, color: .tertiaryLabelColor), 0))
      }
      if expanded {
        for m in it.messages.dropFirst() {
          rows.append((MessageRow(message: m, color: it.authorColor(for: m.user), now: now), 0))
        }
      } else if it.messages.count > 1 {
        let n = it.messages.count - 1
        rows.append((label(n == 1 ? "1 reply" : "\(n) replies", size: 11, weight: .medium, color: .secondaryLabelColor, lines: 1), 0))
      }
      if it.resolved, expanded {
        let by = it.resolvedBy.map { "Resolved by \($0.name)" } ?? "Resolved"
        rows.append((label(by, size: 11, color: .secondaryLabelColor, lines: 1), 0))
      }
      if (expanded && canReply && !it.resolved) || isDraft {
        let box = ReplyBox()
        box.wantsLayer = true
        box.layer?.cornerRadius = 7
        box.layer?.borderWidth = 1
        let tv = ReplyTextView()
        tv.font = .systemFont(ofSize: 13)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 3, height: 7)
        tv.textContainer?.widthTracksTextView = true
        // The card sizes the field (`layoutContent`); the text view must not resize itself to its text.
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        tv.centreText()
        tv.placeholder = isDraft ? "Add a comment" : "Reply"
        tv.setAccessibilityLabel(tv.placeholder)
        if let replyText { tv.string = replyText }
        tv.onSend = { [weak self] in self?.send() }
        tv.onCancel = { [weak self] in self?.cancel() }
        tv.onResize = { [weak self] in self?.updateSend(); self?.onResize?() }
        box.addSubview(tv)
        reply = tv
        replyBox = box
        rows.append((box, 0))
        let hint = label(isDraft ? "↩ send · ⇧↩ new line · esc cancel" : "↩ send · ⇧↩ new line", size: 10.5, color: .tertiaryLabelColor, lines: 1)
        rows.append((hint, 0))
        if isDraft {
          let cancel = NSButton(title: "Cancel", target: nil, action: nil)
          cancel.isBordered = false
          cancel.font = .systemFont(ofSize: 13, weight: .medium)
          cancel.contentTintColor = .labelColor
          let ch = ButtonHandler { [weak self] in self?.cancel() }
          cancel.target = ch
          cancel.action = #selector(ButtonHandler.fire)
          objc_setAssociatedObject(cancel, &ButtonHandler.key, ch, .OBJC_ASSOCIATION_RETAIN)
          let send = FilledButton(title: "Comment")
          let sh = ButtonHandler { [weak self] in self?.send() }
          send.target = sh
          send.action = #selector(ButtonHandler.fire)
          objc_setAssociatedObject(send, &ButtonHandler.key, sh, .OBJC_ASSOCIATION_RETAIN)
          sendButton = send
          rows.append((ButtonRow(buttons: [cancel, send]), 0))
        }
      }
    }
    if let error {
      rows.append((label(error, size: 11, color: .systemRed), 0))
    }
    rows.forEach { addSubview($0.0) }
    updateSend()
    if hadFocus, let reply { window?.makeFirstResponder(reply) }
    updateLayer()
    needsLayout = true
  }

  // ---- compact suggestions ----------------------------------------------------------------------------------------

  static let compactHeight: CGFloat = 30
  private var compact: (avatar: AvatarView, text: NSTextField)?
  /// One line (not selected): a suggestion's +/− text, or a group's "Name: n changes" and the start of its diff.
  var isCompact: Bool { compact != nil }

  private func buildCompact() {
    let it = item
    let avatar = AvatarView(initials: it.author.initials, color: it.authorColor, size: 18)
    let t = NSMutableAttributedString()
    if it.isGroup && !it.isPair {
      // "Linus: 6 changes"; selected, it lists them.
      t.append(NSAttributedString(string: "\(it.author.name.split(separator: " ").first.map(String.init) ?? it.author.name): \(it.members.count) changes",
                                  attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor]))
    } else {
      t.append(Self.plain(it, size: 12))
    }
    let text = NSTextField(labelWithAttributedString: t)
    text.lineBreakMode = .byTruncatingTail
    text.maximumNumberOfLines = 1
    text.toolTip = it.isGroup && !it.isPair ? "\(it.author.name): \(it.members.count) changes" : "\(it.author.name) · \(timeText(now))"
    let ids = it.changeIDs
    if it.isPair {
      buttons = pairButtons(it)
      [avatar, text].forEach(addSubview)
      buttons.forEach(addSubview)
      compact = (avatar, text)
      header = nil
      updateLayer()
      needsLayout = true
      return
    }
    buttons = [
      button("checkmark", it.isGroup ? "Accept all \(ids.count)" : "Accept", tint: .systemGreen, it.isGroup ? .acceptAll(ids) : .accept(it.id)),
      button("xmark", it.isGroup ? "Reject all \(ids.count)" : "Reject", tint: .systemRed, it.isGroup ? .rejectAll(ids) : .reject(it.id)),
    ]
    [avatar, text].forEach(addSubview)
    buttons.forEach(addSubview)
    compact = (avatar, text)
    header = nil
    updateLayer()
    needsLayout = true
  }

  /// Text that was added and then removed: green-tinted (added) and struck through (removed).
  static func addedThenRemoved(_ it: ReviewItem, size: CGFloat) -> NSAttributedString {
    let q = it.members[0].quote.replacingOccurrences(of: "\n", with: " ↵ ").trimmingCharacters(in: .whitespaces)
    return NSAttributedString(string: q, attributes: [
      .font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.secondaryLabelColor,
      .backgroundColor: NSColor.systemGreen.withAlphaComponent(0.12),
      .strikethroughStyle: NSUnderlineStyle.single.rawValue, .strikethroughColor: NSColor.systemRed,
    ])
  }

  /// Added, then removed: ✓ accepts both (the text stays out, as before it was added); ✕ rejects the removal (back
  /// to "added"). A replacement: ✓ / ✕ take both.
  private func pairButtons(_ it: ReviewItem) -> [NSButton] {
    if it.isReplacement {
      return [
        button("checkmark", "Accept the replacement", tint: .systemGreen, .acceptAll(it.changeIDs)),
        button("xmark", "Reject the replacement", tint: .systemRed, .rejectAll(it.changeIDs)),
      ]
    }
    let ins = it.members[0], del = it.members[1]
    return [
      button("checkmark", "Accept both: the text stays out", tint: .systemGreen, .acceptAll([ins.id, del.id])),
      button("xmark", "Reject the removal: back to an added suggestion", tint: .systemRed, .reject(del.id)),
    ]
  }

  /// A suggestion in words: Add “x”, Delete “x”, Replace “x” with “y”, Added, then removed: “x”. The quoted words
  /// carry a subtle tint (green added, struck red removed).
  static func plain(_ c: ReviewItem, size: CGFloat) -> NSAttributedString {
    let out = NSMutableAttributedString()
    let verb: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.secondaryLabelColor]
    func words(_ q: String, added: Bool, removed: Bool) -> NSAttributedString {
      let t = q.replacingOccurrences(of: "\n", with: " ↵ ").trimmingCharacters(in: .whitespaces)
      var a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.labelColor]
      if added { a[.backgroundColor] = NSColor.systemGreen.withAlphaComponent(0.14) }
      if removed {
        a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        a[.strikethroughColor] = NSColor.systemRed.withAlphaComponent(0.7)
        a[.foregroundColor] = NSColor.secondaryLabelColor
      }
      let m = NSMutableAttributedString(string: "“", attributes: verb)
      m.append(NSAttributedString(string: t.isEmpty ? "¶" : t, attributes: a))
      m.append(NSAttributedString(string: "”", attributes: verb))
      return m
    }
    if c.isReplacement {
      out.append(NSAttributedString(string: "Replace ", attributes: verb))
      out.append(words(c.members[0].quote, added: false, removed: true))
      out.append(NSAttributedString(string: " with ", attributes: verb))
      out.append(words(c.members[1].quote, added: true, removed: false))
    } else if c.isAddedThenRemoved {
      out.append(NSAttributedString(string: "Added, then removed: ", attributes: verb))
      out.append(words(c.members[0].quote, added: true, removed: true))
    } else if c.kind == .insert {
      out.append(NSAttributedString(string: "Add ", attributes: verb))
      out.append(words(c.quote, added: true, removed: false))
    } else {
      out.append(NSAttributedString(string: "Delete ", attributes: verb))
      out.append(words(c.quote, added: false, removed: true))
    }
    return out
  }

  /// "+added −deleted …": inserts green-tinted, deletes struck through in red.
  static func diff(_ changes: [ReviewItem], size: CGFloat) -> NSAttributedString {
    let out = NSMutableAttributedString()
    for (k, c) in changes.enumerated() {
      if k > 0 { out.append(NSAttributedString(string: "  ", attributes: [.font: NSFont.systemFont(ofSize: size)])) }
      let q = c.quote.replacingOccurrences(of: "\n", with: " ↵ ").trimmingCharacters(in: .whitespaces)
      var a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size)]
      if c.kind == .insert {
        a[.foregroundColor] = NSColor.labelColor
        a[.backgroundColor] = NSColor.systemGreen.withAlphaComponent(0.18)
        out.append(NSAttributedString(string: "+", attributes: [.font: NSFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: NSColor.systemGreen]))
      } else {
        a[.foregroundColor] = NSColor.secondaryLabelColor
        a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        a[.strikethroughColor] = NSColor.systemRed
        out.append(NSAttributedString(string: "−", attributes: [.font: NSFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: NSColor.systemRed]))
      }
      out.append(NSAttributedString(string: q.isEmpty ? "¶" : q, attributes: a))
    }
    return out
  }

  /// "•••": Delete (the margin asks first).
  private func moreButton() -> NSButton {
    let b = NSButton(image: NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "More") ?? NSImage(), target: nil, action: nil)
    b.isBordered = false
    b.toolTip = "More"
    b.setAccessibilityLabel("More")
    b.contentTintColor = .secondaryLabelColor
    b.symbolConfiguration = .init(pointSize: 13, weight: .medium)
    b.frame.size = NSSize(width: 24, height: 24)
    let id = item.id
    let handler = ButtonHandler { [weak self, weak b] in
      guard let self, let b else { return }
      self.moreMenu(id).popUp(positioning: nil, at: NSPoint(x: 0, y: b.bounds.maxY + 4), in: b)
    }
    b.target = handler
    b.action = #selector(ButtonHandler.fire)
    objc_setAssociatedObject(b, &ButtonHandler.key, handler, .OBJC_ASSOCIATION_RETAIN)
    return b
  }

  func moreMenu(_ id: String) -> NSMenu {
    let m = NSMenu()
    let del = NSMenuItem(title: "Delete Comment…", action: #selector(ButtonHandler.fire), keyEquivalent: "")
    let h = ButtonHandler { [weak self] in self?.onAction?(.delete(id)) }
    del.target = h
    objc_setAssociatedObject(del, &ButtonHandler.key, h, .OBJC_ASSOCIATION_RETAIN)
    del.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
    m.addItem(del)
    return m
  }

  func focusReply() {
    if let reply { window?.makeFirstResponder(reply) }
  }

  /// The field has something to send.
  var hasText: Bool { !(reply?.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }

  private func updateSend() {
    sendButton?.isEnabled = hasText && !sending
    reply?.isEditable = !sending
  }

  func send() {
    guard let reply, !sending else { return }
    let text = reply.string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    if isDraft { sending = true }
    if isDraft {
      onAction?(.comment(item.range, text: text))
    } else {
      onAction?(.reply(item.id, text: text))
    }
  }
  func cancel() {
    if let onCancel {
      onCancel(hasText)
      return
    }
    giveUp()
  }
  /// Throw the draft or the reply away (no questions).
  func giveUp() {
    if isDraft {
      onAction?(.select(nil))
    } else {
      reply?.string = ""
      window?.makeFirstResponder(nil)
    }
  }
  func clearReply() {
    reply?.string = ""
    reply?.needsDisplay = true
  }

  // ---- layout ---------------------------------------------------------------------------------------------------

  /// Lays the content out for this width and returns the height. Only content, not the card's own frame.
  @discardableResult func layoutContent(width: CGFloat) -> CGFloat {
    let p = Self.pad
    if let c = compact {
      // One line: the author's dot, the diff, ✓ ✕.
      let h = Self.compactHeight
      c.avatar.frame = NSRect(x: 9, y: (h - 18) / 2, width: 18, height: 18)
      var right = width - 6
      for b in buttons.reversed() {
        right -= 24
        b.frame = NSRect(x: right, y: (h - 24) / 2, width: 24, height: 24)
      }
      let x: CGFloat = 33
      c.text.frame = NSRect(x: x, y: (h - 17) / 2, width: max(10, right - x - 2), height: 17)
      return h
    }
    let inner = width - 2 * p
    var y = p
    if let (avatar, name, time) = header, avatar.frame.width == 20 || avatar.bounds.width == 20 {
      // Quiet: a 20 pt avatar and one line.
      let qp: CGFloat = 10
      avatar.frame = NSRect(x: qp, y: qp, width: 20, height: 20)
      var right = width - qp + 4
      for b in buttons.reversed() {
        right -= 22
        b.frame = NSRect(x: right, y: qp - 1, width: 22, height: 22)
      }
      name.frame = NSRect(x: qp + 28, y: qp + 2, width: max(20, right - qp - 32), height: 16)
      time.frame = .zero
      var yy = qp + 20 + 6
      for (v, inset) in rows {
        let w = width - 2 * qp - inset
        let h: CGFloat
        if let l = v as? NSTextField { l.preferredMaxLayoutWidth = w; h = l.wrappedHeight(w) }
        else if let m = v as? MessageRow { h = m.height(for: w) }
        else if v is ButtonRow { h = 28 }
        else if v === replyBox, let reply {
          reply.centreText()
          reply.frame = NSRect(x: 0, y: 0, width: w, height: ReplyTextView.minHeight)
          reply.textContainer?.containerSize = NSSize(width: w - 2 * reply.textContainerInset.width, height: .greatestFiniteMagnitude)
          h = min(120, max(ReplyTextView.minHeight, ceil(reply.contentHeight)))
          reply.frame = NSRect(x: 0, y: 0, width: w, height: h)
          effectiveAppearance.performAsCurrentDrawingAppearance {
            v.layer?.borderColor = (window?.firstResponder === reply ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
            v.layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.6).cgColor
          }
        } else { h = v.fittingSize.height }
        v.frame = NSRect(x: qp + inset, y: yy, width: w, height: h)
        yy += h + 5
      }
      return ceil(yy - 5 + qp)
    }
    if let (avatar, name, time) = header {
      avatar.frame = NSRect(x: p, y: y, width: 28, height: 28)
      var right = width - p + 4
      for b in buttons.reversed() {
        right -= 24
        b.frame = NSRect(x: right, y: y + 2, width: 24, height: 24)
      }
      let tx = p + 28 + 8
      let tw = max(20, right - tx - 4)
      // No time line (a draft): the name row centres on the avatar.
      name.frame = NSRect(x: tx, y: time.stringValue.isEmpty ? y + 6 : y - 1, width: tw, height: 16)
      time.frame = NSRect(x: tx, y: y + 15, width: tw, height: 14)
      y += 28 + 8
    }
    for (v, inset) in rows {
      let w = inner - inset
      let h: CGFloat
      if let l = v as? NSTextField {
        l.preferredMaxLayoutWidth = w
        h = l.wrappedHeight(w)
      } else if let q = v as? QuoteBar {
        h = q.height(for: w)
      } else if let m = v as? MessageRow {
        h = m.height(for: w)
      } else if v is ButtonRow {
        h = 28
      } else if v === replyBox, let reply {
        reply.centreText()
        reply.frame = NSRect(x: 0, y: 0, width: w, height: ReplyTextView.minHeight)
        reply.textContainer?.containerSize = NSSize(width: w - 2 * reply.textContainerInset.width, height: .greatestFiniteMagnitude)
        h = min(120, max(ReplyTextView.minHeight, ceil(reply.contentHeight)))
        reply.frame = NSRect(x: 0, y: 0, width: w, height: h)
        effectiveAppearance.performAsCurrentDrawingAppearance {
          v.layer?.borderColor = (window?.firstResponder === reply ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
          v.layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.6).cgColor
        }
      } else {
        h = v.fittingSize.height
      }
      v.frame = NSRect(x: p + inset, y: y, width: w, height: h)
      y += h + 6
    }
    return ceil(y - 6 + p)
  }

  func height(for width: CGFloat) -> CGFloat { layoutContent(width: width) }

  override func layout() {
    super.layout()
    layoutContent(width: bounds.width)
  }

  // Clicks on labels select the card.
  override func hitTest(_ point: NSPoint) -> NSView? {
    let v = super.hitTest(point)
    if let l = v as? NSTextField, !l.isEditable { return self }
    if v is AvatarView || v is QuoteBar || v is MessageRow || v?.superview is QuoteBar || v?.superview is MessageRow { return self }
    return v
  }
  override func mouseDown(with event: NSEvent) {
    onSelect?()  // (selects, and puts Neovim's cursor in the text)
  }
}

extension ReviewItem {
  func authorColor(for user: ReviewUser) -> NSColor {
    if user.id == author.id { return authorColor }
    var copy = self
    copy.color = nil
    copy.author = user
    return copy.authorColor
  }
}

/// The quoted text with a bar in the author's colour on its left.
final class QuoteBar: NSView {
  let bar = NSView()
  let content: NSTextField
  let color: NSColor
  init(color: NSColor, content: NSTextField) {
    self.content = content
    self.color = color
    super.init(frame: .zero)
    bar.wantsLayer = true
    bar.layer?.cornerRadius = 1.5
    addSubview(bar)
    addSubview(content)
  }
  required init?(coder: NSCoder) { fatalError() }
  override var isFlipped: Bool { true }
  // (its colour is set in layout: again in a new appearance)
  override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsLayout = true }
  func height(for w: CGFloat) -> CGFloat {
    content.preferredMaxLayoutWidth = w - 10
    return content.wrappedHeight(w - 10)
  }
  override func layout() {
    super.layout()
    bar.frame = NSRect(x: 0, y: 1, width: 3, height: bounds.height - 2)
    bar.layer?.backgroundColor = color.readable(dark: isDark).cgColor
    content.frame = NSRect(x: 10, y: 0, width: bounds.width - 10, height: bounds.height)
  }
}

/// A reply in an expanded card: small avatar, name · time, text.
final class MessageRow: NSView {
  let avatar: AvatarView
  let head: NSTextField
  let body: NSTextField
  init(message m: ReviewMessage, color: NSColor, now: Date) {
    avatar = AvatarView(initials: m.user.initials, color: color, size: 20)
    head = NSTextField(labelWithString: "")
    let s = NSMutableAttributedString(string: m.user.name, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor])
    let t = ReviewCardView.ago(m.ts, now: now)
    if !t.isEmpty {
      s.append(NSAttributedString(string: "  " + t, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
    }
    head.attributedStringValue = s
    head.lineBreakMode = .byTruncatingTail
    body = NSTextField(wrappingLabelWithString: m.text)
    body.font = .systemFont(ofSize: 13)
    body.isSelectable = false
    super.init(frame: .zero)
    [avatar, head, body].forEach(addSubview)
  }
  required init?(coder: NSCoder) { fatalError() }
  override var isFlipped: Bool { true }
  func height(for w: CGFloat) -> CGFloat {
    body.preferredMaxLayoutWidth = w - 28
    return 4 + 18 + body.wrappedHeight(w - 28)
  }
  override func layout() {
    super.layout()
    avatar.frame = NSRect(x: 0, y: 4, width: 20, height: 20)
    head.frame = NSRect(x: 28, y: 5, width: bounds.width - 28, height: 16)
    body.frame = NSRect(x: 28, y: 22, width: bounds.width - 28, height: bounds.height - 22)
  }
}

/// The blue Comment button (drawn here: a push button's bezel colour only shows in the key window).
final class FilledButton: NSButton {
  convenience init(title: String) {
    self.init(frame: .zero)
    self.title = title
    isBordered = false
    wantsLayer = true
    layer?.cornerRadius = 6
    font = .systemFont(ofSize: 13, weight: .semibold)
    setButtonType(.momentaryPushIn)
  }
  override var wantsUpdateLayer: Bool { true }
  override var isEnabled: Bool { didSet { needsDisplay = true } }
  override func updateLayer() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(isEnabled ? (isHighlighted ? 0.8 : 1) : 0.4).cgColor
    }
    attributedTitle = NSAttributedString(string: title, attributes: [
      .font: font ?? .systemFont(ofSize: 13, weight: .semibold),
      .foregroundColor: NSColor.white.withAlphaComponent(isEnabled ? 1 : 0.75),
    ])
  }
  override var intrinsicContentSize: NSSize {
    let s = (title as NSString).size(withAttributes: [.font: font ?? .systemFont(ofSize: 13)])
    return NSSize(width: ceil(s.width) + 24, height: 28)
  }
  override var fittingSize: NSSize { intrinsicContentSize }
}

/// Buttons right-aligned in a row (Cancel, Comment).
final class ButtonRow: NSView {
  let buttons: [NSButton]
  init(buttons: [NSButton]) {
    self.buttons = buttons
    super.init(frame: .zero)
    buttons.forEach(addSubview)
  }
  required init?(coder: NSCoder) { fatalError() }
  override var isFlipped: Bool { true }
  override func layout() {
    super.layout()
    var x = bounds.width
    for b in buttons.reversed() {
      let w = max(b.fittingSize.width, 44)
      let h = b is FilledButton ? 28 : b.fittingSize.height
      x -= w
      b.frame = NSRect(x: x, y: (bounds.height - h) / 2, width: w, height: h)
      x -= 8
    }
  }
}

final class ButtonHandler: NSObject {
  nonisolated(unsafe) static var key: UInt8 = 0
  let f: () -> Void
  init(_ f: @escaping () -> Void) { self.f = f }
  @objc func fire() { f() }
}

extension NSTextField {
  /// Height of the wrapped text at this width, at most maximumNumberOfLines lines.
  func wrappedHeight(_ width: CGFloat) -> CGFloat {
    let s = attributedStringValue
    guard s.length > 0 else { return 0 }
    // The cell draws with a 2 pt inset on each side.
    let w = max(1, width - 4)
    let r = s.boundingRect(with: NSSize(width: w, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
    var h = ceil(r.height)
    if maximumNumberOfLines > 0 {
      let font = (s.attribute(.font, at: 0, effectiveRange: nil) as? NSFont) ?? self.font ?? .systemFont(ofSize: 13)
      let line = ceil(font.ascender - font.descender + font.leading)
      h = min(h, line * CGFloat(maximumNumberOfLines))
    }
    return h + 2
  }
}
