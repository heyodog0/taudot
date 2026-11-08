// The find bar: a small glass card at the top right of the editor column. A field, "3 of 17", toggles for case,
// whole word and regex, ↑ ↓ and ✕; ⌥⌘F opens a second row to replace one or all. The bar only shows and reports;
// FindController does the searching through a FindTarget.
import AppKit
import TaudotShared

@MainActor public final class FindBar: NSView, NSTextFieldDelegate {
  public let field = FindField()
  public let replaceField = FindField()
  public let countLabel = NSTextField(labelWithString: "")
  let caseToggle = FindToggle(title: "Aa", tip: "Match case (off: smart case)  ⌥⌘C")
  let wordToggle = FindToggle(title: "ab", underline: true, tip: "Whole word  ⌥⌘W")
  let regexToggle = FindToggle(title: ".*", tip: "Regular expression  ⌥⌘X")
  let disclosure = NSButton()
  let prevButton = NSButton(), nextButton = NSButton(), closeButton = NSButton()
  let replaceOne = NSButton(title: "Replace", target: nil, action: nil)
  let replaceAll = NSButton(title: "All", target: nil, action: nil)
  let glass: NSView
  let fieldBack = NSView(), replaceBack = NSView()

  public var onChange: ((FindQuery) -> Void)?
  public var onNext: (() -> Void)?
  public var onPrevious: (() -> Void)?
  /// Enter in the find field (FindController decides: next, or back to the editor after `/`).
  public var onEnter: ((_ shift: Bool) -> Void)?
  public var onClose: (() -> Void)?
  public var onReplace: ((_ all: Bool) -> Void)?
  /// ↑ (-1) / ↓ (+1) in the find field: the search history.
  public var onHistory: ((Int) -> Void)?
  public var onReplaceShown: ((Bool) -> Void)?
  /// The find field took or left the keys.
  public var onFieldFocus: ((Bool) -> Void)?

  public private(set) var replaceShown = false
  static let rowHeight: CGFloat = 34
  static let width: CGFloat = 430
  static let radius: CGFloat = 12

  public var query: FindQuery {
    FindQuery(field.stringValue, matchCase: caseToggle.isOn, wholeWord: wordToggle.isOn, regex: regexToggle.isOn)
  }

  public override init(frame: NSRect) {
    if #available(macOS 26.0, *), !taudotSolid(NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency) {
      let g = NSGlassEffectView()
      g.cornerRadius = FindBar.radius
      g.style = .regular
      g.tintColor = TaudotColor.glassTint.withAlphaComponent(0.35)
      glass = g
    } else {
      let v = NSVisualEffectView()
      v.material = .hudWindow
      v.blendingMode = .withinWindow
      v.state = .active
      v.wantsLayer = true
      v.layer?.cornerRadius = FindBar.radius
      v.layer?.masksToBounds = true
      v.layer?.borderWidth = 0.5
      glass = v
    }
    super.init(frame: NSRect(x: 0, y: 0, width: FindBar.width, height: FindBar.rowHeight))
    wantsLayer = true
    shadow = {
      let s = NSShadow()
      s.shadowColor = NSColor.black.withAlphaComponent(0.28)
      s.shadowBlurRadius = 14
      s.shadowOffset = NSSize(width: 0, height: -3)
      return s
    }()
    glass.frame = bounds
    glass.autoresizingMask = [.width, .height]
    addSubview(glass)
    for b in [fieldBack, replaceBack] {
      b.wantsLayer = true
      b.layer?.cornerRadius = 7
      b.layer?.cornerCurve = .continuous
      addSubview(b)
    }
    for (f, ph) in [(field, "Find"), (replaceField, "Replace")] {
      f.placeholderString = ph
      f.isBordered = false
      f.drawsBackground = false
      f.focusRingType = .none
      f.font = .systemFont(ofSize: 13)
      f.lineBreakMode = .byClipping
      f.cell?.isScrollable = true
      f.cell?.wraps = false
      f.delegate = self
      f.bar = self
      addSubview(f)
    }
    field.setAccessibilityLabel("Find")
    replaceField.setAccessibilityLabel("Replace with")
    countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    countLabel.textColor = .secondaryLabelColor
    countLabel.alignment = .right
    countLabel.lineBreakMode = .byTruncatingHead
    countLabel.setAccessibilityLabel("Matches")
    addSubview(countLabel)
    for t in [caseToggle, wordToggle, regexToggle] {
      t.onToggle = { [weak self] in self?.changed() }
      addSubview(t)
    }
    func symbol(_ b: NSButton, _ name: String, _ tip: String, _ size: CGFloat = 11, _ action: Selector) {
      b.image = NSImage(systemSymbolName: name, accessibilityDescription: tip)
      b.symbolConfiguration = .init(pointSize: size, weight: .semibold)
      b.isBordered = false
      b.imagePosition = .imageOnly
      b.contentTintColor = .secondaryLabelColor
      b.toolTip = tip
      b.target = self
      b.action = action
      addSubview(b)
    }
    symbol(disclosure, "chevron.right", "Replace  ⌥⌘F", 10, #selector(toggleReplace))
    symbol(prevButton, "chevron.up", "Previous  ⇧⌘G", 11, #selector(prevClicked))
    symbol(nextButton, "chevron.down", "Next  ⌘G", 11, #selector(nextClicked))
    symbol(closeButton, "xmark", "Close  Esc", 10, #selector(closeClicked))
    for (b, all) in [(replaceOne, false), (replaceAll, true)] {
      b.bezelStyle = .accessoryBarAction
      b.controlSize = .small
      b.font = .systemFont(ofSize: 11, weight: .medium)
      b.target = self
      b.action = all ? #selector(replaceAllClicked) : #selector(replaceOneClicked)
      b.toolTip = all ? "Replace every match  ⌥↩ (one undo)" : "Replace this match, then the next  ↩"
      addSubview(b)
    }
    replaceField.isHidden = true
    replaceBack.isHidden = true
    replaceOne.isHidden = true
    replaceAll.isHidden = true
    field.nextKeyView = replaceField
    replaceField.nextKeyView = field
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel("Find")
    recolor()
    show(count: FindCount())
  }
  required init?(coder: NSCoder) { fatalError() }
  public override var isFlipped: Bool { true }

  public override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    recolor()
  }

  private var dark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

  private func recolor() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      // TaudotPalette's search well: a breath of white on dark, of ink on light.
      let well = dark ? NSColor(white: 1, alpha: 0.08) : NSColor(srgbRed: 0x0b / 255.0, green: 0x2a / 255.0, blue: 0x30 / 255.0, alpha: 0.06)
      fieldBack.layer?.backgroundColor = well.cgColor
      replaceBack.layer?.backgroundColor = well.cgColor
      glass.layer?.borderColor = NSColor.separatorColor.cgColor
      field.textColor = TaudotColor.text
      replaceField.textColor = TaudotColor.text
      for t in [caseToggle, wordToggle, regexToggle] { t.needsDisplay = true }
    }
  }

  /// The height for the rows shown.
  public var wantedHeight: CGFloat { replaceShown ? 2 * FindBar.rowHeight - 4 : FindBar.rowHeight }

  public override func layout() {
    super.layout()
    let h = FindBar.rowHeight
    let w = bounds.width
    var x: CGFloat = 6
    disclosure.frame = NSRect(x: x, y: (h - 20) / 2, width: 18, height: 20)
    x += 20
    // right to left: ✕ ↓ ↑ | toggles | count
    var r = w - 6
    for b in [closeButton, nextButton, prevButton] {
      r -= 22
      b.frame = NSRect(x: r, y: (h - 22) / 2, width: 22, height: 22)
    }
    r -= 4
    for t in [regexToggle, wordToggle, caseToggle] {
      r -= 24
      t.frame = NSRect(x: r, y: (h - 20) / 2, width: 22, height: 20)
    }
    r -= 4
    let cw: CGFloat = 78
    countLabel.frame = NSRect(x: r - cw, y: (h - 15) / 2, width: cw - 4, height: 15)
    r -= cw
    fieldBack.frame = NSRect(x: x, y: 5, width: max(40, r - x), height: h - 10)
    let fh = field.intrinsicContentSize.height
    field.frame = NSRect(x: x + 7, y: (h - fh) / 2, width: max(30, r - x - 14), height: fh)
    // the replace row
    let y2 = h - 4
    replaceBack.frame = NSRect(x: x, y: y2 + 5, width: max(40, r - x), height: h - 10)
    replaceField.frame = NSRect(x: x + 7, y: y2 + (h - fh) / 2, width: max(30, r - x - 14), height: fh)
    let bw1: CGFloat = 64, bw2: CGFloat = 40
    replaceOne.frame = NSRect(x: r + 4, y: y2 + (h - 22) / 2, width: bw1, height: 22)
    replaceAll.frame = NSRect(x: r + 8 + bw1, y: y2 + (h - 22) / 2, width: bw2, height: 22)
  }

  // MARK: showing

  /// The count ("3 of 17", "No matches" quietly, a regex's error in its own words).
  public func show(count c: FindCount) {
    let empty = field.stringValue.isEmpty
    countLabel.stringValue = empty ? "" : c.label
    countLabel.textColor = c.error != nil ? .systemOrange : .secondaryLabelColor
    countLabel.toolTip = c.error
    let any = c.total > 0 && c.error == nil
    prevButton.isEnabled = any
    nextButton.isEnabled = any
    replaceOne.isEnabled = any
    replaceAll.isEnabled = any
    setAccessibilityValue(countLabel.stringValue)
  }

  public func setReplaceShown(_ on: Bool) {
    guard on != replaceShown else { return }
    replaceShown = on
    disclosure.image = NSImage(systemSymbolName: on ? "chevron.down" : "chevron.right", accessibilityDescription: "Replace")
    for v in [replaceField, replaceBack, replaceOne, replaceAll] as [NSView] { v.isHidden = !on }
    onReplaceShown?(on)
  }

  /// Put the query in the bar (history, a reopened bar).
  public func set(_ q: FindQuery) {
    field.stringValue = q.text
    caseToggle.isOn = q.matchCase
    wordToggle.isOn = q.wholeWord
    regexToggle.isOn = q.regex
  }

  public func focusField(selectAll: Bool = true) {
    window?.makeFirstResponder(field)
    if selectAll { field.currentEditor()?.selectAll(nil) }
  }

  public var fieldHasFocus: Bool {
    guard let fr = window?.firstResponder as? NSTextView, fr.isFieldEditor else { return false }
    return (fr.delegate as? NSTextField) === field
  }

  // MARK: actions

  func changed() { onChange?(query) }

  @objc func toggleReplace() { setReplaceShown(!replaceShown); if replaceShown { window?.makeFirstResponder(replaceField) } }
  @objc func prevClicked() { onPrevious?() }
  @objc func nextClicked() { onNext?() }
  @objc func closeClicked() { onClose?() }
  @objc func replaceOneClicked() { onReplace?(false) }
  @objc func replaceAllClicked() { onReplace?(true) }

  public func toggle(_ which: String) {
    switch which {
    case "case": caseToggle.isOn.toggle()
    case "word": wordToggle.isOn.toggle()
    case "regex": regexToggle.isOn.toggle()
    default: return
    }
    changed()
  }

  public func controlTextDidChange(_ n: Notification) {
    if (n.object as? NSTextField) === field { changed() }
  }

  public func controlTextDidBeginEditing(_ n: Notification) {
    if (n.object as? NSTextField) === field { onFieldFocus?(true) }
  }

  public func controlTextDidEndEditing(_ n: Notification) {
    if (n.object as? NSTextField) === field { onFieldFocus?(false) }
  }

  public func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
    let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
    let inReplace = control === replaceField
    switch sel {
    case #selector(NSResponder.insertNewline(_:)):
      if inReplace { onReplace?(false) } else { onEnter?(shift) }
      return true
    case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
      if inReplace { onReplace?(true) } else { onEnter?(shift) }
      return true
    case #selector(NSResponder.cancelOperation(_:)):
      onClose?()
      return true
    case #selector(NSResponder.moveUp(_:)) where !inReplace:
      onHistory?(-1)
      return true
    case #selector(NSResponder.moveDown(_:)) where !inReplace:
      onHistory?(1)
      return true
    default:
      return false
    }
  }

  /// ⌥⌘C / ⌥⌘W / ⌥⌘X toggle the options while the bar has the keys; ⌘G / ⇧⌘G go on.
  public override func performKeyEquivalent(with e: NSEvent) -> Bool {
    guard let fr = window?.firstResponder as? NSTextView, fr.isFieldEditor,
          let owner = fr.delegate as? FindField, owner.bar === self else { return super.performKeyEquivalent(with: e) }
    let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let c = e.charactersIgnoringModifiers?.lowercased() ?? ""
    if f == [.command, .option] {
      switch c {
      case "c": toggle("case"); return true
      case "w": toggle("word"); return true
      case "x": toggle("regex"); return true
      default: break
      }
    }
    return super.performKeyEquivalent(with: e)
  }
}

/// The bar's text fields.
public final class FindField: NSTextField {
  weak var bar: FindBar?
}

/// A small on/off option: its label, on a teal capsule when on (no coral: that means "you").
final class FindToggle: NSView {
  let title: String
  let underline: Bool
  var onToggle: (() -> Void)?
  var isOn = false { didSet { if isOn != oldValue { needsDisplay = true; setAccessibilityValue(isOn ? 1 : 0) } } }

  init(title: String, underline: Bool = false, tip: String) {
    self.title = title
    self.underline = underline
    super.init(frame: .zero)
    toolTip = tip
    setAccessibilityElement(true)
    setAccessibilityRole(.checkBox)
    setAccessibilityLabel(String(tip.split(separator: " ").prefix { !$0.hasPrefix("⌥") && !$0.hasPrefix("(") }.joined(separator: " ")))
    setAccessibilityValue(0)
  }
  required init?(coder: NSCoder) { fatalError() }
  override var isFlipped: Bool { true }

  override func mouseDown(with event: NSEvent) {
    isOn.toggle()
    onToggle?()
  }

  override func accessibilityPerformPress() -> Bool { isOn.toggle(); onToggle?(); return true }

  override func draw(_ dirtyRect: NSRect) {
    let b = bounds
    if isOn {
      TaudotColor.selection.setFill()
      NSBezierPath(roundedRect: b, xRadius: 5, yRadius: 5).fill()
    }
    let font: NSFont = title == ".*" ? .monospacedSystemFont(ofSize: 11, weight: .bold) : .systemFont(ofSize: 11, weight: .semibold)
    var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: isOn ? TaudotColor.text : NSColor.secondaryLabelColor]
    if underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
    let s = title as NSString
    let sz = s.size(withAttributes: attrs)
    s.draw(at: NSPoint(x: (b.width - sz.width) / 2, y: (b.height - sz.height) / 2), withAttributes: attrs)
  }
}
