// The editor column while History is open: a bar (the file, the versions, +/− counts, previous/next change, Back to
// Editing) over the file's text, read-only, with what was inserted tinted in its author's colour and what was deleted
// struck through in theirs. Hovering a change says who made it and when. The text takes a cursor (it shows, but
// nothing can be typed): on a change, the PDF goes to its mark; a double-click shows the place in the version's PDF
// (forward search). Keys: ⌥↓/⌥↑ and ]c/[c for the next/previous change (on to the next file's at the ends); in
// Neovim mode Vim's motions move the cursor (h j k l w b 0 $ gg G ^D ^U).
import AppKit
import TaudotShared

@MainActor public final class HistoryDiffView: NSView, NSTextViewDelegate {
  public let bar = Flipped()
  let title = NSTextField(labelWithString: "")
  let subtitle = NSTextField(labelWithString: "")
  let counts = NSTextField(labelWithString: "")
  let prevButton = NSButton()
  let nextButton = NSButton()
  public let backButton = NSButton(title: "Back to Editing", target: nil, action: nil)
  let barLine = NSView()
  public let scroll = NSScrollView()
  public let textView: NSTextView
  let placeholder = NSTextField(wrappingLabelWithString: "")

  public var onBack: (() -> Void)?
  public var colorFor: (HistoryUser) -> NSColor = HistoryColors.margin
  /// The editor's font when the app knows it.
  public var font: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular) { didSet { render() } }

  public private(set) var diff: HistoryDiff?
  /// The change the arrows last moved to.
  public private(set) var current: Int?
  static let barHeight: CGFloat = 44

  public override init(frame: NSRect) {
    let tv = DiffTextView(frame: NSRect(x: 0, y: 0, width: frame.width, height: frame.height))
    textView = tv
    super.init(frame: frame)
    tv.owner = self
    wantsLayer = true
    // editable for the cursor (a read-only text view shows none and its arrows scroll); every edit is refused
    tv.isEditable = true
    tv.allowsUndo = false
    tv.isContinuousSpellCheckingEnabled = false
    tv.isGrammarCheckingEnabled = false
    tv.isAutomaticSpellingCorrectionEnabled = false
    tv.isAutomaticTextReplacementEnabled = false
    tv.isAutomaticQuoteSubstitutionEnabled = false
    tv.isAutomaticDashSubstitutionEnabled = false
    tv.isAutomaticTextCompletionEnabled = false
    tv.smartInsertDeleteEnabled = false
    tv.delegate = self
    tv.isSelectable = true
    tv.isRichText = true
    tv.drawsBackground = true
    tv.textContainerInset = NSSize(width: 18, height: 14)
    tv.isVerticallyResizable = true
    tv.isHorizontallyResizable = false
    tv.autoresizingMask = [.width]
    tv.textContainer?.widthTracksTextView = true
    tv.setAccessibilityLabel("File at this version")
    scroll.documentView = tv
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.drawsBackground = true
    addSubview(scroll)
    placeholder.font = .systemFont(ofSize: 13)
    placeholder.textColor = .secondaryLabelColor
    placeholder.alignment = .center
    placeholder.isHidden = true
    addSubview(placeholder)

    bar.wantsLayer = true
    addSubview(bar)
    title.font = .systemFont(ofSize: 13, weight: .semibold)
    title.lineBreakMode = .byTruncatingMiddle
    subtitle.font = .systemFont(ofSize: 11)
    subtitle.textColor = .secondaryLabelColor
    subtitle.lineBreakMode = .byTruncatingTail
    counts.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    for (b, sym, tip, sel) in [(prevButton, "chevron.up", "Previous change (⌥↑)", #selector(prev)), (nextButton, "chevron.down", "Next change (⌥↓)", #selector(next))] {
      b.bezelStyle = .accessoryBarAction
      b.isBordered = false
      b.image = NSImage(systemSymbolName: sym, accessibilityDescription: tip)
      b.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
      b.contentTintColor = .secondaryLabelColor
      b.toolTip = tip
      b.target = self
      b.action = sel
    }
    backButton.bezelStyle = .push
    backButton.controlSize = .regular
    backButton.keyEquivalent = "\u{1b}"
    backButton.target = self
    backButton.action = #selector(back)
    backButton.toolTip = "Leave History and go back to the editor (Esc)"
    barLine.wantsLayer = true
    for v in [title, subtitle, counts, prevButton, nextButton, backButton, barLine] { bar.addSubview(v) }
  }
  required init?(coder: NSCoder) { fatalError() }
  public override var isFlipped: Bool { true }
  public override var wantsUpdateLayer: Bool { true }
  public override func updateLayer() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      bar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
      barLine.layer?.backgroundColor = NSColor.separatorColor.cgColor
      textView.backgroundColor = .textBackgroundColor
    }
  }
  public override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    render()  // tints differ between light and dark
  }

  public override func layout() {
    super.layout()
    let h = Self.barHeight
    bar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: h)
    barLine.frame = NSRect(x: 0, y: h - 1, width: bounds.width, height: 1)
    backButton.sizeToFit()
    backButton.frame.origin = NSPoint(x: bounds.width - backButton.frame.width - 12, y: ((h - backButton.frame.height) / 2).rounded())
    nextButton.frame = NSRect(x: backButton.frame.minX - 32, y: (h - 24) / 2, width: 24, height: 24)
    prevButton.frame = NSRect(x: nextButton.frame.minX - 26, y: (h - 24) / 2, width: 24, height: 24)
    counts.sizeToFit()
    counts.frame.origin = NSPoint(x: prevButton.frame.minX - counts.frame.width - 10, y: ((h - counts.frame.height) / 2).rounded())
    let tw = max(40, counts.frame.minX - 16 - 16)
    title.frame = NSRect(x: 16, y: 6, width: tw, height: 17)
    subtitle.frame = NSRect(x: 16, y: 23, width: tw, height: 15)
    scroll.frame = NSRect(x: 0, y: h, width: bounds.width, height: max(0, bounds.height - h))
    let ph = placeholder.sizeThatFits(NSSize(width: bounds.width - 80, height: 400)).height
    placeholder.frame = NSRect(x: 40, y: h + 60, width: bounds.width - 80, height: ph)
  }

  /// Show a file's changes. `subtitle` says which versions ("Changes in 3:42 PM by Bob, You").
  public func show(_ d: HistoryDiff, subtitle sub: String) {
    let same = diff.map { $0.path == d.path && $0.fromV == d.fromV && $0.toV == d.toV } ?? false
    diff = d
    current = nil
    title.stringValue = d.path
    title.toolTip = d.path
    subtitle.stringValue = sub
    subtitle.toolTip = sub
    render()
    if !same { fadeIn(scroll) }
    if !same, let first = d.changes.first {
      // Open at the first change, a few lines below the top.
      DispatchQueue.main.async { [weak self] in self?.reveal(first.range, select: false) }
    }
  }

  /// Another file or range: the text fades in (quickly; not a slide, so Reduce Motion keeps it).
  func fadeIn(_ v: NSView) {
    guard window != nil else { return }
    v.alphaValue = 0.25
    NSAnimationContext.runAnimationGroup { c in
      c.duration = 0.16
      c.timingFunction = CAMediaTimingFunction(name: .easeOut)
      v.animator().alphaValue = 1
    }
  }

  /// A message in place of the text (loading, binary file, error).
  public func showMessage(_ s: String, title t: String? = nil, subtitle sub: String = "") {
    diff = nil
    current = nil
    title.stringValue = t ?? ""
    subtitle.stringValue = sub
    textView.textStorage?.setAttributedString(NSAttributedString())
    counts.stringValue = ""
    placeholder.stringValue = s
    placeholder.isHidden = false
    prevButton.isEnabled = false
    nextButton.isEnabled = false
    needsLayout = true
  }

  /// The attributed text for a diff: the font, and each change in its author's colour.
  public static func attributed(_ d: HistoryDiff, font: NSFont, dark: Bool, colorFor: (HistoryUser) -> NSColor) -> NSAttributedString {
    let s = NSMutableAttributedString(string: d.text, attributes: [.font: font, .foregroundColor: NSColor.textColor])
    let ns = d.text as NSString
    for c in d.chunks where c.kind != .same && NSMaxRange(c.range) <= ns.length {
      let color = c.user.map(colorFor) ?? .systemGray
      let who = c.user.map { $0.mine ? "you" : $0.name } ?? "someone"
      let when = c.time.map { " · " + historyDateTime($0) } ?? ""
      if c.kind == .insert {
        s.addAttributes([
          .backgroundColor: color.withAlphaComponent(dark ? 0.30 : 0.20),
          .underlineStyle: NSUnderlineStyle.single.rawValue, .underlineColor: color.withAlphaComponent(0.8),
          .toolTip: "Added by \(who)\(when)",
        ], range: c.range)
      } else {
        s.addAttributes([
          .backgroundColor: color.withAlphaComponent(dark ? 0.16 : 0.10),
          .strikethroughStyle: NSUnderlineStyle.single.rawValue, .strikethroughColor: color,
          .foregroundColor: NSColor.secondaryLabelColor,
          .toolTip: "Deleted by \(who)\(when)",
        ], range: c.range)
      }
    }
    return s
  }

  func render() {
    guard let d = diff else { return }
    if d.binary {
      textView.textStorage?.setAttributedString(NSAttributedString())
      placeholder.stringValue = "\(d.path) isn't a text file, so there's no text to compare."
      placeholder.isHidden = false
      counts.stringValue = ""
    } else {
      placeholder.isHidden = true
      let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      textView.textStorage?.setAttributedString(Self.attributed(d, font: font, dark: dark, colorFor: colorFor))
      let n = d.changes.count
      if n == 0 {
        counts.attributedStringValue = NSAttributedString(string: "No changes", attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: counts.font!])
      } else {
        let a = NSMutableAttributedString()
        a.append(NSAttributedString(string: "+\(d.inserted)", attributes: [.foregroundColor: NSColor.systemGreen, .font: counts.font!]))
        a.append(NSAttributedString(string: "  −\(d.deleted)", attributes: [.foregroundColor: NSColor.systemRed, .font: counts.font!]))
        a.append(NSAttributedString(string: "  ·  \(n) \(n == 1 ? "change" : "changes")", attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: counts.font!]))
        counts.attributedStringValue = a
      }
    }
    prevButton.isEnabled = !(diff?.changes.isEmpty ?? true)
    nextButton.isEnabled = prevButton.isEnabled
    needsLayout = true
  }

  // ---- moving between changes -------------------------------------------------------------------------------------

  @objc public func next() { step(1) }
  @objc public func prev() { step(-1) }
  @objc func back() { onBack?() }

  /// Past the last change (or before the first): another file's (true when it took over; else the arrows wrap).
  public var onStepPast: ((Int) -> Bool)?

  /// The next (`by` 1) or previous (-1) change.
  public func step(_ by: Int) {
    guard let d = diff, !d.changes.isEmpty else {
      _ = onStepPast?(by)
      return
    }
    let changes = d.changes
    let i: Int
    if let c = current {
      if c + by < 0 || c + by >= changes.count, onStepPast?(by) == true { return }
      i = (c + by + changes.count) % changes.count
    } else {
      // From what's on screen: the first change below the top (or above it, going back).
      let top = visibleCharacter()
      i = by > 0 ? (changes.firstIndex { $0.range.location > top } ?? 0) : (changes.lastIndex { $0.range.location < top } ?? changes.count - 1)
    }
    select(i)
  }

  /// The diff's current change (next/previous, a click on a change, a mark clicked on the PDF): revealed, selected,
  /// and reported.
  public func select(_ i: Int) {
    guard let d = diff, i >= 0, i < d.changes.count else { return }
    current = i
    selecting = true
    reveal(d.changes[i].range, select: true)
    selecting = false
    onCurrent?(d, i)
  }
  /// The current change changed (the PDF outlines it).
  public var onCurrent: ((HistoryDiff, Int?) -> Void)?
  private var selecting = false

  private func visibleCharacter() -> Int {
    guard let lm = textView.layoutManager, let tc = textView.textContainer else { return 0 }
    let r = scroll.contentView.bounds
    let g = lm.glyphIndex(for: NSPoint(x: 0, y: r.minY + 4), in: tc)
    return lm.characterIndexForGlyph(at: g)
  }

  func reveal(_ r: NSRange, select: Bool) {
    guard let lm = textView.layoutManager, let tc = textView.textContainer else { return }
    lm.ensureLayout(for: tc)
    let g = lm.glyphRange(forCharacterRange: r, actualCharacterRange: nil)
    let rect = lm.boundingRect(forGlyphRange: g, in: tc)
    let y = max(0, rect.minY + textView.textContainerInset.height - scroll.contentView.bounds.height * 0.25)
    scroll.contentView.scroll(to: NSPoint(x: 0, y: min(y, max(0, textView.frame.height - scroll.contentView.bounds.height))))
    scroll.reflectScrolledClipView(scroll.contentView)
    if select { textView.setSelectedRange(r) }
  }

  // ---- keys and the PDF ---------------------------------------------------------------------------------------------

  /// Vim's motions for the cursor (the app's Neovim mode).
  public var vimKeys = false
  private var keyPrefix: String?
  /// A double-click in the text: show this place of the version (1-based line, UTF-8 byte column) in its PDF.
  public var onForward: ((_ path: String, _ line: Int, _ column: Int) -> Void)?

  /// A key in the text: true when it was History's (the rest go to the text view, which types nothing).
  func key(_ e: NSEvent) -> Bool {
    let mods = e.modifierFlags.intersection([.command, .control, .option])
    guard let ch = e.charactersIgnoringModifiers, !ch.isEmpty else { return false }
    let tv = textView
    if let p = keyPrefix, mods.isEmpty {
      keyPrefix = nil
      switch (p, ch) {
      case ("]", "c"): next(); return true
      case ("[", "c"): prev(); return true
      case ("g", "g"): tv.moveToBeginningOfDocument(nil); return true
      default: break
      }
    }
    keyPrefix = nil
    if mods.isEmpty, ch == "]" || ch == "[" || (vimKeys && ch == "g") {
      keyPrefix = ch
      return true
    }
    guard vimKeys else { return false }
    if mods == .control {
      let half = { (down: Bool) in
        let lines = max(1, Int(self.scroll.contentView.bounds.height / max(1, self.font.boundingRectForFont.height) / 2))
        for _ in 0..<lines { down ? tv.moveDown(nil) : tv.moveUp(nil) }
      }
      if ch == "d" { half(true); return true }
      if ch == "u" { half(false); return true }
      return false
    }
    guard mods.isEmpty else { return false }
    switch ch {
    case "j": tv.moveDown(nil)
    case "k": tv.moveUp(nil)
    case "h": tv.moveLeft(nil)
    case "l": tv.moveRight(nil)
    case "w": tv.moveWordForward(nil)
    case "b": tv.moveWordBackward(nil)
    case "0": tv.moveToBeginningOfLine(nil)
    case "$": tv.moveToEndOfLine(nil)
    case "G": tv.moveToEndOfDocument(nil)
    default: return false
    }
    return true
  }

  /// Forward search from the cursor.
  public func forwardSearch() {
    guard let d = diff, !d.binary else { return }
    let p = Self.versionPlace(d, at: textView.selectedRange().location)
    onForward?(d.path, p.line, p.column)
  }

  /// A place in the diff's text (UTF-16) in the version's text (deleted text isn't there: a place in it is the
  /// deletion's place): a 1-based line and a UTF-8 byte column.
  public static func versionPlace(_ d: HistoryDiff, at loc: Int) -> (line: Int, column: Int) {
    let ns = d.text as NSString
    var line = 1, col = 0
    for c in d.chunks {
      if c.range.location >= loc { break }
      if c.kind == .delete { continue }
      let end = min(NSMaxRange(c.range), loc, ns.length)
      guard end > c.range.location else { continue }
      for b in ns.substring(with: NSRange(location: c.range.location, length: end - c.range.location)).utf8 {
        if b == 0x0A { line += 1; col = 0 } else { col += 1 }
      }
    }
    return (line, col)
  }

  public func textView(_ v: NSTextView, shouldChangeTextIn r: NSRange, replacementString s: String?) -> Bool { false }

  public override func performKeyEquivalent(with e: NSEvent) -> Bool {
    if e.modifierFlags.contains(.option), window?.firstResponder === textView || window?.firstResponder === self {
      if e.keyCode == 125 { next(); return true }
      if e.keyCode == 126 { prev(); return true }
    }
    return super.performKeyEquivalent(with: e)
  }

  /// A click in the text: on a change, it becomes the current one.
  public func textViewDidChangeSelection(_ n: Notification) {
    guard !selecting, let d = diff else { return }
    let at = textView.selectedRange().location
    guard let i = d.changes.firstIndex(where: { NSLocationInRange(at, $0.range) || (at == $0.range.location) }), i != current else { return }
    current = i
    onCurrent?(d, i)
  }
}

final public class Flipped: NSView { public override var isFlipped: Bool { true } }

/// The diff's text: its keys go to History first; a double-click also asks for the place in the PDF.
final class DiffTextView: NSTextView {
  weak var owner: HistoryDiffView?
  override func keyDown(with e: NSEvent) {
    if owner?.key(e) == true { return }
    super.keyDown(with: e)
  }
  override func mouseDown(with e: NSEvent) {
    super.mouseDown(with: e)  // (tracks the mouse until it's up)
    if e.clickCount == 2 { owner?.forwardSearch() }
  }
}

/// "Today 3:42 PM", "6 Nov 2026, 3:42 PM".
public func historyDateTime(_ d: Date, now: Date = Date()) -> String {
  let f = DateFormatter()
  f.timeStyle = .short
  f.dateStyle = .medium
  f.doesRelativeDateFormatting = true
  _ = now
  return f.string(from: d)
}
