// LaTeX errors and warnings in the native editor (docs/agents/errors.md, "Inline in the editor"): a wavy underline under
// the spot, a dot in the left margin, and, with the caret on the line or the pointer on the mark, a small card with the
// message in plain words and "Ask Claude to fix". The shell parses TeX's output and decides when to show (not while a
// line is half typed); it hands the list to `NativeEditor.setIssues` and gets `onAskClaude` back.
import AppKit
import TaudotShared

/// One error or warning as the editor marks it. The app makes these from its `TeXIssue`s (TaudotNeovim/TeXIssues.swift,
/// `ProjectWindow.issues.shown`), with the file and the UTF-8 column resolved; see TaudotApp/NativeIssues.swift.
public struct EditorIssue: Equatable, Sendable {
  public enum Severity: Sendable { case error, warning }
  public var severity: Severity
  /// The file, relative to the project folder (as the editor's paths are).
  public var path: String
  /// 1-based line TeX reports (`l.536`, `main.tex:536:`).
  public var line: Int
  /// Where TeX stopped reading the line, in UTF-8 bytes: the break in TeX's `l.536 …` context. The mark goes on the
  /// token ending there (a control sequence, or the character). Nil: the line's text is marked.
  public var column: Int?
  /// TeX's own words ("Extra }, or forgotten \endgroup").
  public var message: String
  /// The same in plain words, when the shell knows one ("There's a } with no matching {").
  public var plain: String?

  public init(severity: Severity, path: String, line: Int, column: Int? = nil, message: String, plain: String? = nil) {
    self.severity = severity
    self.path = path
    self.line = line
    self.column = column
    self.message = message
    self.plain = plain
  }

  /// The prompt "Ask Claude to fix" prefills (not sent): the lines around it, TeX's message, keep it small. Worded as
  /// the app's `TeXIssue.claudePrompt`, with the line where the mark is now (edits since the typeset move it).
  public func claudePrompt(line now: Int? = nil) -> String {
    let l = now ?? line
    let what = severity == .error ? "error" : "warning"
    return "Fix this LaTeX \(what). @\(path)#L\(max(1, l - 6))-\(l + 4) \(what.capitalized) at line \(l): \(message). Keep the change minimal."
  }
}

/// An issue placed in the shown doc: its marked range (UTF-16), kept in place as the text is edited.
struct PlacedIssue {
  var issue: EditorIssue
  var range: NSRange
}

extension NativeEditorView {
  /// The issues of the shown doc, placed in its text. Called by NativeEditor on setIssues and on show.
  func placeIssues(_ list: [EditorIssue]) {
    let s = textView.string as NSString
    let st = starts16
    placedIssues = list.compactMap { i -> PlacedIssue? in
      guard i.line >= 1, i.line <= st.count else { return nil }
      let start = st[i.line - 1]
      let end = i.line < st.count ? st[i.line] - 1 : s.length
      let text = s.substring(with: NSRange(location: start, length: end - start))
      var r: NSRange
      if let col = i.column {
        // the token ending where TeX stopped: a control sequence (\name, or \ and one character), else the character
        let at = start + Utf.utf16(Array(text.utf8), min(col, text.utf8.count))
        guard at > start else { return PlacedIssue(issue: i, range: NSRange(location: start, length: min(1, end - start))) }
        var a = at - 1
        var k = a
        while k > start, LatexSyntax.isLetter(s.character(at: k)) { k -= 1 }
        if s.character(at: k) == 92, k < a || !LatexSyntax.isLetter(s.character(at: a)) { a = k }
        else if a > start, s.character(at: a - 1) == 92 { a -= 1 }
        r = NSRange(location: a, length: at - a)
      } else {
        // the line's text, without its indent
        let lead = text.prefix { $0 == " " || $0 == "\t" }.utf16.count
        r = NSRange(location: start + lead, length: max(0, end - start - lead))
      }
      return PlacedIssue(issue: i, range: r)
    }
    issuesOverlay.needsDisplay = true
    updateIssueCard()
  }

  /// An edit at `range` (after it) that changed the length by `delta`: issues move with the text.
  func moveIssues(_ range: NSRange, _ delta: Int) {
    guard !placedIssues.isEmpty else { return }
    let oldEnd = NSMaxRange(range) - delta
    for k in placedIssues.indices {
      var r = placedIssues[k].range
      if r.location >= oldEnd { r.location += delta }
      else if NSMaxRange(r) > range.location { r.length = max(1, NSMaxRange(r) + delta - r.location) }
      placedIssues[k].range = r
    }
  }

  /// The issue whose line the caret is on, or the one under the pointer.
  func issueHere() -> PlacedIssue? {
    if let h = hoveredIssue { return h }
    let (l, _) = lineCol(caret)
    return placedIssues.first { lineCol($0.range.location).0 == l }
  }

  /// 1-based line an issue is on now (it moves with edits).
  func currentLine(_ p: PlacedIssue) -> Int { lineCol(p.range.location).0 + 1 }

  func updateIssueCard() {
    issuesOverlay.frame = canvas.bounds
    guard let p = issueHere(), let rect = issueRects(p.range).first else {
      issueCard.isHidden = true
      return
    }
    issueCard.show(p, style: style, onAsk: { [weak self] in
      guard let self else { return }
      self.onAskClaude?(p.issue, p.issue.claudePrompt(line: self.currentLine(p)))
    })
    // below the marked line, inside the text column
    let below = canvas.convert(NSPoint(x: rect.minX, y: rect.maxY + 4), to: self)
    let size = issueCard.fittingSize
    let x = min(max(8, below.x - 12), bounds.width - size.width - 12)
    var y = below.y
    if y + size.height > bounds.height - 8 { y = canvas.convert(NSPoint(x: 0, y: rect.minY), to: self).y - size.height - 4 }
    issueCard.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
    issueCard.isHidden = false
  }

  /// The marked range's frames, one per line fragment, in the text view.
  func issueRects(_ r: NSRange) -> [NSRect] {
    if let lay = textLayout { return r.length > 0 ? lay.rects(r) : [] }
    guard r.length > 0, let tlm = textView.textLayoutManager, let tr = textRange(r) else { return [] }
    var out: [NSRect] = []
    tlm.enumerateTextSegments(in: tr, type: .standard, options: []) { _, frame, _, _ in
      let o = textView.textContainerOrigin
      out.append(NSRect(x: frame.minX + o.x, y: frame.minY + o.y, width: frame.width, height: frame.height))
      return true
    }
    return out
  }

  // MARK: hover

  func trackIssues() {
    if isMetal { return }  // (the document view passes mouse moves on)
    for t in textView.trackingAreas where t.owner === self { textView.removeTrackingArea(t) }
    textView.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
  }

  public override func mouseMoved(with e: NSEvent) {
    let p = canvas.convert(e.locationInWindow, from: nil)
    let hit = placedIssues.first { i in
      let rects = issueRects(i.range)
      if rects.contains(where: { $0.insetBy(dx: -2, dy: -3).contains(p) }) { return true }
      guard let first = rects.first else { return false }
      return issuesOverlay.dotRect(first).insetBy(dx: -4, dy: -4).contains(p)
    }
    if hit?.range != hoveredIssue?.range {
      hoveredIssue = hit
      updateIssueCard()
    }
  }
}

/// The wavy underlines and margin dots.
final class IssuesOverlay: NSView {
  weak var owner: NativeEditorView?
  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  func dotRect(_ line: NSRect) -> NSRect {
    let x = max(3, (owner?.textView.textContainerOrigin.x ?? 16) / 2 - 3)
    return NSRect(x: x, y: line.midY - 3, width: 6, height: 6)
  }

  /// Only the marks in `dirtyRect` are measured (an issue's rects lay its paragraph out: a long log's hundreds of
  /// issues cost ~50 ms a frame drawn one by one), and they're drawn as one path per colour: errors, then warnings
  /// over them, as the list orders them.
  override func draw(_ dirtyRect: NSRect) {
    MainActor.assumeIsolated {
      guard let o = owner, !o.placedIssues.isEmpty else { return }
      let lay = o.textLayout
      let fh = o.font.ascender - o.font.descender
      var dots: [EditorIssue.Severity: NSBezierPath] = [:], waves: [EditorIssue.Severity: NSBezierPath] = [:]
      var order: [EditorIssue.Severity] = []
      for p in o.placedIssues {
        if let lay {  // the paragraph's span, without laying it out (y(ofPara:) is the same before and after)
          let k = lay.paraIndex(p.range.location)
          let top = lay.y(ofPara: k), bottom = k + 1 < lay.paras.count ? lay.y(ofPara: k + 1) : lay.height + lay.origin.y
          if bottom < dirtyRect.minY - 8 || top > dirtyRect.maxY + 8 { continue }
        }
        let rects = o.issueRects(p.range)
        guard let first = rects.first else { continue }
        let s = p.issue.severity
        if dots[s] == nil { dots[s] = NSBezierPath(); waves[s] = NSBezierPath(); order.append(s) }
        dots[s]!.appendOval(in: dotRect(first))
        for r in rects {
          // a wave under the glyphs (the fragment's text height, not the line spacing below it)
          let y = r.minY + min(r.height, fh) + 1.5
          let path = waves[s]!
          var x = r.minX
          path.move(to: NSPoint(x: x, y: y))
          var up = true
          while x < r.maxX {
            let nx = min(r.maxX, x + 2)
            path.line(to: NSPoint(x: nx, y: up ? y - 1.5 : y))
            up.toggle()
            x = nx
          }
        }
      }
      for s in order {
        let color = s == .error ? NSColor.systemRed : NSColor.systemOrange
        color.setFill()
        dots[s]!.fill()
        color.setStroke()
        waves[s]!.lineWidth = 1.2
        waves[s]!.stroke()
      }
    }
  }
}

/// The card under a marked line: the message in plain words, TeX's own below in small type, and "Ask Claude to fix".
final class IssueCard: NSView {
  private let title = NSTextField(wrappingLabelWithString: "")
  private let detail = NSTextField(wrappingLabelWithString: "")
  private let ask = NSButton(title: "Ask Claude to fix", target: nil, action: nil)
  private let dot = NSView()
  private var onAsk: (() -> Void)?
  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerRadius = 8
    layer?.borderWidth = 1
    shadow = NSShadow()
    layer?.shadowOpacity = 0.25
    layer?.shadowRadius = 8
    layer?.shadowOffset = NSSize(width: 0, height: -2)
    title.font = .systemFont(ofSize: 12, weight: .semibold)
    detail.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
    for f in [title, detail] {
      f.maximumNumberOfLines = 3
      f.preferredMaxLayoutWidth = 340
      f.isSelectable = true
    }
    ask.bezelStyle = .rounded
    ask.controlSize = .small
    ask.font = .systemFont(ofSize: 11, weight: .medium)
    ask.target = self
    ask.action = #selector(askClicked)
    ask.setAccessibilityLabel("Ask Claude to fix")
    dot.wantsLayer = true
    dot.layer?.cornerRadius = 4
    for v in [dot, title, detail, ask] { addSubview(v) }
    isHidden = true
  }

  required init?(coder: NSCoder) { fatalError() }

  /// For checks.
  var titleText: String { title.stringValue }
  func pressAsk() { askClicked() }

  @objc private func askClicked() { onAsk?() }

  func show(_ p: PlacedIssue, style: EditorStyle, onAsk: @escaping () -> Void) {
    self.onAsk = onAsk
    let t = style.theme
    let i = p.issue
    let color = i.severity == .error ? NSColor.systemRed : NSColor.systemOrange
    title.stringValue = i.plain ?? i.message
    detail.stringValue = i.plain == nil ? "" : i.message
    detail.isHidden = i.plain == nil
    title.textColor = t.color(\.fg)
    detail.textColor = t.color(\.comment)
    dot.layer?.backgroundColor = color.cgColor
    layer?.backgroundColor = t.color(\.bg).blended(withFraction: t.dark ? 0.08 : 0.04, of: t.dark ? .white : .black)?.cgColor
    layer?.borderColor = color.withAlphaComponent(0.45).cgColor
    appearance = NSAppearance(named: t.dark ? .darkAqua : .aqua)
    layoutCard()
  }

  private func layoutCard() {
    let pad: CGFloat = 10, w: CGFloat = 340
    dot.frame = NSRect(x: pad, y: pad + 4, width: 8, height: 8)
    let tx = pad + 16
    let ts = title.sizeThatFits(NSSize(width: w, height: 200))
    title.frame = NSRect(x: tx, y: pad, width: w, height: ts.height)
    var y = title.frame.maxY + 3
    if !detail.isHidden {
      let ds = detail.sizeThatFits(NSSize(width: w, height: 200))
      detail.frame = NSRect(x: tx, y: y, width: w, height: ds.height)
      y = detail.frame.maxY + 6
    } else {
      y += 3
    }
    ask.sizeToFit()
    ask.frame.origin = NSPoint(x: tx - 6, y: y)
    setFrameSize(NSSize(width: tx + w + pad, height: ask.frame.maxY + pad))
  }

  override var fittingSize: NSSize { frame.size }
}
