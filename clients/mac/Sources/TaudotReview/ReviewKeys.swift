// Review shortcuts a non-Neovim user would guess: the review pane's keys, like Mail's
// message list, and the verbs they share with the app's Review menu.
import AppKit

public enum ReviewVerb: Sendable, Equatable {
  /// Move the selection (the editor follows, as with ]r).
  case next, previous, first, last
  /// Each then selects the next item.
  case accept, reject, resolve
  /// Focus the comment's reply field.
  case reply
  /// ⌥⌘↩: reply on a comment, accept on a suggestion.
  case acceptOrReply
  /// Expand or collapse the selected card.
  case toggle
}

/// The one-time hint at the bottom of the pane the first time it gets the keys.
final class KeyHintBar: NSView {
  static let text = "↑↓ move · ⌘↩ accept · ⌘⌫ reject · ↩ reply"
  private let label = NSTextField(labelWithString: KeyHintBar.text)
  private let close = NSButton(title: "", target: nil, action: nil)
  var onClose: (() -> Void)?
  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerRadius = 8
    label.font = .systemFont(ofSize: 11)
    label.textColor = .secondaryLabelColor
    label.lineBreakMode = .byTruncatingTail
    close.isBordered = false
    close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss")
    close.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
    close.contentTintColor = .tertiaryLabelColor
    close.target = self
    close.action = #selector(closed)
    addSubview(label)
    addSubview(close)
  }
  required init?(coder: NSCoder) { fatalError() }
  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }
  @objc private func closed() { onClose?() }
  override func updateLayer() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
      layer?.borderWidth = 0.5
      layer?.borderColor = NSColor.separatorColor.cgColor
    }
  }
  override func layout() {
    super.layout()
    close.frame = NSRect(x: bounds.width - 22, y: (bounds.height - 16) / 2, width: 16, height: 16)
    let h = label.fittingSize.height
    label.frame = NSRect(x: 10, y: (bounds.height - h) / 2, width: bounds.width - 36, height: h)
  }
}

extension ReviewMarginView {
  static let keyHintKey = "taudot.margin.keyHintShown"

  /// The item the verbs act on: the selected card, else the one under the cursor.
  public var currentItem: ReviewItem? {
    let ids = order.map(\.id)
    let id = selectedID.flatMap { $0 == "draft" ? nil : $0 } ?? cardIDs(cursor.here).first(where: ids.contains)
    return id.flatMap { i in order.first { $0.id == i } }
  }

  /// A jump landed on item `id` (a raw comment or change): its card opens as a click would: selected, expanded with
  /// its reply field, given its whole height first; the others collapse. The keys stay where they were (]r again
  /// goes on). Not held back by the scroll the jump causes.
  public func land(on id: String) {
    let card = cardIDs([id]).first ?? id
    guard order.contains(where: { $0.id == card }) else { return }
    collapsedSelection = false
    if paneHidden { floating.show(card); return }  // (the floating card shows that one)
    if selectedID != card { select(card) } else { reload(animated: true) }
  }

  /// Select `id` and move the editor there (or, the pane hidden, just the editor: the card floats).
  func move(to item: ReviewItem) {
    if !paneHidden { select(item.id) }
    let target = item.members.first?.id ?? item.id
    if cardLayout == .stacked {
      // The list stays; the editor goes to the text (centred) and the PDF follows (as a jump lands).
      revealSelectedInStack()
      onAction?(.reveal(target, path: state.path ?? ""))
    } else {
      onAction?(.goto(target))
    }
  }

  /// Returns false when there was nothing to do it to (a beep, from the keys).
  @discardableResult public func verb(_ v: ReviewVerb) -> Bool {
    let items = order.filter { $0.id != "draft" }
    let cur = currentItem
    let i = cur.flatMap { c in items.firstIndex { $0.id == c.id } }
    // The one after (or before, at the end) once `cur` is gone.
    func neighbour() -> ReviewItem? {
      guard let i else { return nil }
      if i + 1 < items.count { return items[i + 1] }
      return i > 0 ? items[i - 1] : nil
    }
    switch v {
    case .next, .previous:
      guard !items.isEmpty else { return false }
      let j = i.map { min(max(0, $0 + (v == .next ? 1 : -1)), items.count - 1) } ?? (v == .next ? 0 : items.count - 1)
      if let i, j == i { return false }
      move(to: items[j])
    case .first, .last:
      guard let it = v == .first ? items.first : items.last else { return false }
      move(to: it)
    case .accept, .reject:
      guard let c = cur, c.kind != .comment else { return false }
      let a: ReviewAction
      if c.isAddedThenRemoved {
        a = v == .accept ? .acceptAll(c.changeIDs) : .reject(c.members[1].id)
      } else if c.isReplacement {
        a = v == .accept ? .acceptAll(c.changeIDs) : .rejectAll(c.changeIDs)
      } else if c.isGroup {
        a = v == .accept ? .acceptAll(c.changeIDs) : .rejectAll(c.changeIDs)
      } else {
        a = v == .accept ? .accept(c.id) : .reject(c.id)
      }
      let n = neighbour()
      perform(a)
      if let n { move(to: n) }
    case .resolve:
      guard let c = cur, c.kind == .comment, !c.resolved else { return false }
      let n = neighbour()
      perform(.resolve(c.id))
      if let n { move(to: n) }
    case .reply:
      guard let c = cur, c.kind == .comment else { return false }
      select(c.id, focus: true)
    case .acceptOrReply:
      guard let c = cur else { return false }
      return verb(c.kind == .comment ? .reply : .accept)
    case .toggle:
      guard let c = cur else { return false }
      if selectedID != c.id { select(c.id); collapsedSelection = false } else { collapsedSelection.toggle() }
      reload(animated: true)
    }
    return true
  }

  // ---- the pane's keys --------------------------------------------------------------------------------------------

  public override var acceptsFirstResponder: Bool { true }

  public override func becomeFirstResponder() -> Bool {
    if !UserDefaults.standard.bool(forKey: Self.keyHintKey) {
      UserDefaults.standard.set(true, forKey: Self.keyHintKey)
      showKeyHint()
    }
    if selectedID == nil, let f = order.first(where: { $0.id != "draft" && onScreenOrAny($0) }) { select(f.id) }
    return true
  }

  private func onScreenOrAny(_ it: ReviewItem) -> Bool {
    guard let v = geometry?.visibleLines else { return true }
    return it.range.line >= v.lowerBound
  }

  func showKeyHint() {
    keyHint.isHidden = false
    keyHint.onClose = { [weak self] in self?.keyHint.isHidden = true }
    needsLayout = true
  }
  public var keyHintVisible: Bool { !keyHint.isHidden }

  /// ⌘-keys reach the menus first; while the pane has the keys, these are its own.
  public override func performKeyEquivalent(with e: NSEvent) -> Bool {
    guard window?.firstResponder === self, e.type == .keyDown else { return super.performKeyEquivalent(with: e) }
    if handleKey(e) { return true }
    return super.performKeyEquivalent(with: e)
  }

  public override func keyDown(with e: NSEvent) {
    if !handleKey(e) { super.keyDown(with: e) }
  }

  /// The pane's keys. Returns whether it was one.
  @discardableResult public func handleKey(_ e: NSEvent) -> Bool {
    let f = e.modifierFlags.intersection([.command, .option, .shift, .control])
    let ch = e.charactersIgnoringModifiers?.lowercased() ?? ""
    func did(_ ok: Bool) -> Bool { if !ok { NSSound.beep() }; return true }
    switch (e.keyCode, f) {
    case (125, []): return did(verb(.next))
    case (126, []): return did(verb(.previous))
    case (115, []), (126, [.command]): return did(verb(.first))
    case (119, []), (125, [.command]): return did(verb(.last))
    case (36, [.command]), (76, [.command]): return did(verb(.accept))
    case (51, [.command]): return did(verb(.reject))
    case (36, []), (76, []):
      // Return: reply on a comment; open (or close) a suggestion.
      guard let c = currentItem else { return did(false) }
      return did(verb(c.kind == .comment ? .reply : .toggle))
    case (49, []): return did(verb(.toggle))
    case (53, []):
      focusEditor()
      return true
    default:
      if f == [.command] && ch == "r" { return did(verb(.resolve)) }
      if f == [.command] && ch == "f" { onFind?(); return true }
      return false
    }
  }
}
