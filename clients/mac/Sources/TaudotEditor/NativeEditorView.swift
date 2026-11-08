// The native editor's view: a TextKit 2 text view in a scroll view, LaTeX colours from a Theme, review tints and
// collaborators' cursors, the comforts, and EditorGeometry so the margin and its floating cards place themselves
// next to the text exactly as they do next to Neovim.
import AppKit
import TaudotShared

/// How the text looks. The shell fills it from its settings.
public struct EditorStyle: Equatable {
  public var theme: Theme
  public var fontFamily: String
  public var fontSize: CGFloat
  /// Extra points between lines.
  public var lineSpacing: CGFloat
  /// The text column's width in characters (0: the view's width).
  public var maxColumns: Int
  public init(theme: Theme = Theme.named("dusk")!, fontFamily: String = "", fontSize: CGFloat = 13, lineSpacing: CGFloat = 3, maxColumns: Int = 0) {
    self.theme = theme
    self.fontFamily = fontFamily
    self.fontSize = fontSize
    self.lineSpacing = lineSpacing
    self.maxColumns = maxColumns
  }
}

extension NSColor {
  convenience init(rgb: UInt32, alpha: CGFloat = 1) {
    self.init(srgbRed: CGFloat((rgb >> 16) & 0xff) / 255, green: CGFloat((rgb >> 8) & 0xff) / 255, blue: CGFloat(rgb & 0xff) / 255, alpha: alpha)
  }
}

@MainActor public final class NativeEditorView: NSView, EditorGeometry, @preconcurrency NSTextStorageDelegate, NSTextViewDelegate {
  public override var isFlipped: Bool { true }
  public let scroll = NSScrollView()
  public let textView: NativeTextView
  public private(set) var doc: NativeDoc?
  public private(set) var style = EditorStyle()
  /// The doc's buffer number for the margin (one per doc path).
  public private(set) var buffer = 0
  /// Collaborators: (name, initials, colour, local byte offset).
  public var others: [(name: String, initials: String, color: NSColor, pos: Int)] = [] { didSet { overlay.needsDisplay = true } }
  /// The caret moved to another line (1-based) or column (bytes); `true` when forced (⌘⌥J).
  public var onCursor: ((_ line: Int, _ col: Int) -> Void)?
  /// Any selection change (for the margin's cursor payload).
  public var onSelection: (() -> Void)?
  /// Every caret move and every edit, at once (the PDF's cursor dot): (1-based line, byte column, the line's text).
  public var onCaret: ((_ line: Int, _ col: Int, _ text: String) -> Void)?
  /// Completion from the engine: (byte pos, line text before the caret) → result.
  public var completer: ((_ pos: Int, _ before: String) async -> CompletionResult?)?
  /// Every review tint, comments marked (setTints).
  private var allTints: [(range: NSRange, color: NSColor, strength: CGFloat, comment: Bool)] = []
  /// The tints drawn: all of them, less comments while `commentsHidden`.
  var tints: [(NSRange, NSColor, CGFloat)] { allTints.filter { !(commentsHidden && $0.comment) }.map { ($0.range, $0.color, $0.strength) } }
  /// Comment highlights hidden in the text (tracked changes still shown). Both editors (TextKit and Metal).
  public var commentsHidden = false { didSet { if commentsHidden != oldValue { retint(); lineNotesChanged() } } }
  /// End-of-line comment notes (LineNotes.swift; LineNotesView.swift draws them), redrawn at once when set.
  public var lineNotes: [LineNote] = [] { didSet { if lineNotes != oldValue { lineNotesChanged() } } }
  /// Find matches (Find/NativeFind.swift), drawn over the tints.
  var findMarks: (ranges: [NSRange], current: Int?) = ([], nil)
  /// Esc where it means nothing else (normal mode, no popup): the find bar closes if it is up (returns true).
  public var onFindEscape: (() -> Bool)?
  /// For checks: what is tinted, and what the completion list shows.
  private var lastCaret: (Int, Int, String)?
  public var tintRanges: [NSRange] { tints.map(\.0) }
  public var popupLabels: [String] { popup.isVisible ? popup.labels : [] }
  private var applying = false
  /// Between a text change and its textDidChange (selection changes then belong to the edit).
  private var editing = false
  private var lineStarts16: [Int]?
  /// The text an edit in progress removes (from shouldChangeTextIn), nil when the edit didn't come through it.
  private var deleted: String?
  private var handlers: [@MainActor () -> Void] = []
  private let overlay = OthersOverlay()
  /// LaTeX errors and warnings of the shown doc (Issues.swift).
  var placedIssues: [PlacedIssue] = [] { didSet { issuesOverlay.needsDisplay = true } }
  var hoveredIssue: PlacedIssue?
  let issuesOverlay = IssuesOverlay()
  let issueCard = IssueCard(frame: .zero)
  /// "Ask Claude to fix": the issue and the prompt to prefill.
  public var onAskClaude: ((EditorIssue, String) -> Void)?
  /// For checks: the issue card's message ("" when hidden), and pressing its button.
  public var issueCardText: String { issueCard.isHidden ? "" : issueCard.titleText }
  public func pressAskClaude() { issueCard.pressAsk() }
  public var issueMarks: [NSRange] { placedIssues.map(\.range) }
  /// Vim keys (NativeVim.swift), when on.
  var vim: VimEngine?
  /// The app's normal-mode commands (]r [r ga gx gC), given to the Vim engine whenever it exists.
  public var vimCommands: [String: (Int) -> Void] = [:] { didSet { vim?.commands = vimCommands } }
  /// `/` or `?` in Vim's normal mode: the find bar (returns true when it takes the search).
  public var onVimSearchKey: ((Character) -> Bool)? { didSet { vim?.onSearchKey = onVimSearchKey } }
  var vimBuffer: TextViewVimBuffer?
  /// The Vim mode or command line, shown at the bottom left; also sent here for a status bar.
  public var onVimStatus: ((String) -> Void)?
  let vimLabel = NSTextField(labelWithString: "")
  /// The Vim engine, for checks.
  public var vimEngine: VimEngine? { vim }
  let popup = CompletionPopup()
  /// The `\begin` whose name the caret is in: its name range and the matching `\end`'s name range.
  private var renamePair: (begin: NSRange, end: NSRange)?
  private var lastCursor: (Int, Int)?
  private var cursorTimer: Timer?
  /// The whole doc laid out ahead (layoutAhead): the next line to lay out, and the width it was done for.
  var aheadLine = 0
  var aheadTimer: Timer?
  private var laidOutWidth: CGFloat = 0
  /// For checks: laying out ahead is done.
  public var laidOutAhead: Bool { aheadTimer == nil && aheadLine > 0 }
  /// Metal mode (MetalEditor.swift): our layout, the view drawing it, the scroll view's document.
  var textLayout: TextLayout?
  var metalView: MetalTextView?
  let docView = MetalDocView()
  /// Metal: the range an edit wants recoloured before the next frame.
  var pendingHighlight: NSRange?

  /// The native editor draws with Metal unless `TAUDOT_METALTEXT=0` or the setting `taudot.editor.textKit` says
  /// TextKit (`TAUDOT_METALTEXT=1` forces Metal).
  public static var metalDefault: Bool {
    switch ProcessInfo.processInfo.environment["TAUDOT_METALTEXT"] {
    case "0": return false
    case "1": return true
    default: return !UserDefaults.standard.bool(forKey: NativeEditorView.textKitKey)
    }
  }
  /// The setting that keeps the TextKit editor (until it is retired): read when an editor is made.
  public static let textKitKey = "taudot.editor.textKit"

  public convenience override init(frame: NSRect) { self.init(frame: frame, metal: NativeEditorView.metalDefault) }

  public init(frame: NSRect, metal: Bool) {
    textView = NativeTextView(usingTextLayoutManager: true)
    super.init(frame: frame)
    scroll.frame = bounds
    scroll.autoresizingMask = [.width, .height]
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = true
    scroll.borderType = .noBorder
    textView.isRichText = false
    textView.allowsUndo = true
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.isAutomaticSpellingCorrectionEnabled = false
    textView.isContinuousSpellCheckingEnabled = false
    textView.smartInsertDeleteEnabled = false
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.textContainer?.widthTracksTextView = true
    textView.minSize = NSSize(width: 0, height: 0)
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.frame = NSRect(origin: .zero, size: scroll.contentSize)
    textView.delegate = self
    textView.textStorage?.delegate = self
    textView.owner = self
    scroll.documentView = textView
    addSubview(scroll)
    if metal { setUpMetal() }
    overlay.owner = self
    canvas.addSubview(overlay)
    issuesOverlay.owner = self
    canvas.addSubview(issuesOverlay)
    addSubview(issueCard)
    trackIssues()
    vimLabel.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
    vimLabel.textColor = .secondaryLabelColor
    vimLabel.isHidden = true
    addSubview(vimLabel)
    scroll.contentView.postsBoundsChangedNotifications = true
    NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.changed() }
    }
    apply(style: style)
  }

  required init?(coder: NSCoder) { fatalError() }

  public override func layout() {
    super.layout()
    updateInsets()
    if isMetal {
      metalLayoutChanged()
    } else if let w = textView.textContainer?.size.width, abs(w - laidOutWidth) > 0.5 { layoutAhead() }
    overlay.frame = canvas.bounds
    issuesOverlay.frame = canvas.bounds
    changed()
  }

  // MARK: style

  public var font: NSFont {
    let size = style.fontSize > 0 ? style.fontSize : 13
    if !style.fontFamily.isEmpty, let f = NSFont(name: style.fontFamily, size: size) { return f }
    return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
  }

  public func apply(style s: EditorStyle) {
    style = s
    let t = s.theme
    let para = NSMutableParagraphStyle()
    para.lineSpacing = s.lineSpacing
    textView.backgroundColor = t.color(\.bg)
    scroll.backgroundColor = t.color(\.bg)
    textView.cursorColor = t.color(\.cursor)
    textView.selectedTextAttributes = [.backgroundColor: t.color(\.selection)]
    textView.typingAttributes = [.font: font, .foregroundColor: t.color(\.fg), .paragraphStyle: para]
    textView.defaultParagraphStyle = para
    appearance = NSAppearance(named: t.dark ? .darkAqua : .aqua)
    if let st = textView.textStorage, st.length > 0 {
      st.beginEditing()
      st.addAttributes([.font: font, .paragraphStyle: para], range: NSRange(location: 0, length: st.length))
      st.endEditing()
      highlight(NSRange(location: 0, length: st.length))
    }
    if let lay = textLayout {
      // the line at the top of the view stays there (TextKit mode: the shell's keepingTop, which measures TextKit)
      let restore = keepingMetalTop {
        lay.setFont(font, lineSpacing: s.lineSpacing)
        metalView?.atlas.reset()
        metalLayoutChanged()
      }
      // again after a caller's own restore (the shell's keepingTop, one turn later), which can't measure this layout
      DispatchQueue.main.async { DispatchQueue.main.async { MainActor.assumeIsolated { restore() } } }
    }
    popup.style = s
    updateInsets()
    changed()
    layoutAhead()
  }

  // MARK: layout ahead

  /// TextKit 2 lays out only what is on screen and guesses the height of the rest. Scrolling into text it hasn't laid
  /// out (up from a jump, a search, a PDF click) then corrects those guesses mid-scroll: the text jumps and frames run
  /// long. So the whole doc is laid out ahead, in slices of 150 lines (~4 ms) one run-loop turn apart, after a doc is
  /// shown, the style changes or the width does; each slice keeps the line at the top of the view where it is.
  func layoutAhead() {
    if isMetal { metalLayoutAhead(); return }
    aheadLine = 0
    laidOutWidth = textView.textContainer?.size.width ?? 0
    aheadTimer?.invalidate()
    aheadTimer = nil
    scheduleAhead()
  }

  private func scheduleAhead() {
    let t = Timer(timeInterval: 0.001, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.aheadStep() } }
    RunLoop.main.add(t, forMode: .common)
    aheadTimer = t
  }

  private func aheadStep() {
    aheadTimer = nil
    guard let tlm = textView.textLayoutManager else { return }
    let st = starts16
    let n = st.count
    guard aheadLine < n else { return }
    let end = min(n, aheadLine + 150)
    let a = st[aheadLine], b = end < n ? st[end] : (textView.string as NSString).length
    let top = visibleLines.lowerBound
    let y0 = y(ofLine: top)
    if b > a, let r = textRange(NSRange(location: a, length: b - a)) { tlm.ensureLayout(for: r) }
    tlm.textViewportLayoutController.layoutViewport()
    // lines above the view changed height: scroll by as much, so what is on screen stays put
    if let y0, let y1 = y(ofLine: top), abs(y1 - y0) > 0.25 {
      let clip = scroll.contentView
      clip.scroll(to: NSPoint(x: clip.bounds.minX, y: max(0, clip.bounds.minY + (y1 - y0))))
      scroll.reflectScrolledClipView(clip)
    }
    aheadLine = end
    if aheadLine < n { scheduleAhead() }
  }

  private var charWidth: CGFloat { ("M" as NSString).size(withAttributes: [.font: font]).width }

  private func updateInsets() {
    let w = scroll.contentSize.width
    var side: CGFloat = 16
    if style.maxColumns > 0 {
      let col = CGFloat(style.maxColumns) * charWidth + 10
      side = max(16, (w - col) / 2)
    }
    if textView.textContainerInset.width != side {
      textView.textContainerInset = NSSize(width: side, height: 12)
    }
  }

  // MARK: docs

  /// Show a doc (its text replaces the view's).
  public func show(_ d: NativeDoc, buffer b: Int) {
    doc?.onRemote = nil
    // the same file with the same text (the engine's doc after the copy from disk): keep the caret and scroll
    let same = b == buffer && doc?.path == d.path && textView.string == d.string
    doc = d
    buffer = b
    renamePair = nil
    d.onRemote = { [weak self] edits, old in self?.remote(edits, old: old) }
    if same { changed(); return }
    lineStarts16 = nil
    // the last file's issue marks hold its offsets: never read them against this text (the caller places this
    // file's own after; an offset past the end raised NSRangeException in a Task, and the app crashed later)
    placedIssues = []
    applying = true
    textView.string = d.string
    applying = false
    if let lay = textLayout {
      lay.text = textView.textStorage!.mutableString
      lay.reset()
      resizeDocument()
    }
    vim?.textReplaced()  // (A9)
    textView.undoManager?.removeAllActions()
    apply(style: style)
    textView.setSelectedRange(NSRange(location: 0, length: 0))
    changed()
    layoutAhead()
  }

  /// Remote edits (already transformed), applied in order to `old`, the doc's text before them.
  private func remote(_ edits: [Edit], old: [UInt8]) {
    guard let st = textView.textStorage, let d = doc else { return }
    var bytes = old
    applying = true
    for e in edits {
      let loc = Utf.utf16(bytes, e.pos)
      let len = Utf.utf16(bytes, e.pos + e.del) - loc
      st.replaceCharacters(in: NSRange(location: loc, length: len), with: e.ins)
      vim?.textEdited(at: loc, deleted: len, inserted: (e.ins as NSString).length)  // (A9)
      bytes = bytes.applying([e])
    }
    applying = false
    lineStarts16 = nil
    if textView.string.utf8.count != d.text.count { d.onResync?() }
    retint()
    changed()
    reportCaret()
  }

  // MARK: storage

  public func textStorage(_ st: NSTextStorage, didProcessEditing mask: NSTextStorageEditActions, range: NSRange, changeInLength delta: Int) {
    guard mask.contains(.editedCharacters) else { metalView?.setNeedsRender(); return }
    if !applying { Latency.shared.record(.model, key: Latency.shared.lastKey) }
    let s = st.mutableString as NSString
    if let lay = textLayout {
      lay.edited(range, delta: delta)
      metalView?.setNeedsRender()
    }
    updateLineStarts(s, range, delta)
    moveIssues(range, delta)
    if !applying { editing = true }
    let para = s.paragraphRange(for: range)
    let edited = s.substring(with: range)
    // Math can open or close: then everything after needs new colours.
    // (the inserted text with what's around it, so typing the `[` of `\[` counts; the removed text, likewise)
    let around = NSRange(location: max(0, range.location - 6), length: min(s.length, NSMaxRange(range) + 1) - max(0, range.location - 6))
    let inserted = s.substring(with: around)
    let removed = deleted ?? (delta < 0 ? "$" : "")
    deleted = nil
    let markers = ["\\begin", "\\end", "\\[", "\\]", "$"]
    let structural = markers.contains { inserted.contains($0) || removed.contains($0) }
    let r = structural ? NSRange(location: para.location, length: min(s.length - para.location, 60_000)) : para
    let fixRange = r
    if isMetal {
      // coloured before the frame (renderKey), or at the end of the turn
      pendingHighlight = pendingHighlight.map { NSUnionRange($0, fixRange) } ?? fixRange
      RunLoop.main.perform(inModes: [.common]) { [weak self] in MainActor.assumeIsolated { self?.flushHighlight() } }
    } else {
      RunLoop.main.perform(inModes: [.common]) { [weak self] in MainActor.assumeIsolated { Latency.shared.section("highlight") { self?.highlight(fixRange) } } }
    }
    guard !applying, let d = doc else { return }
    // The text before this edit is the doc's: convert from it.
    let old = d.text
    let pos = Utf.utf8(old, range.location)
    let oldLen16 = range.length - delta
    let end = Utf.utf8(old, range.location + oldLen16)
    d.local(Edit(pos: pos, del: end - pos, ins: edited))
  }

  /// Overleaf stores an emoji (any character outside the BMP) as two U+FFFD, and its browser editor replaces them as
  /// they are typed (docs/protocol.md, Astral characters). Do the same, or our copy drifts from the server's.
  public func textView(_ tv: NSTextView, shouldChangeTextIn r: NSRange, replacementString s: String?) -> Bool {
    // What the edit removes (does it open or close math?), with the backslash before it for `\[`, `\begin`…
    if r.length > 0, let m = tv.textStorage?.mutableString {
      let from = max(0, r.location - 6)
      deleted = m.substring(with: NSRange(location: from, length: min(NSMaxRange(r) + 6, m.length) - from))
    } else {
      deleted = ""
    }
    guard let s, s.unicodeScalars.contains(where: { $0.value > 0xFFFF }) else { return true }
    let fixed = NativeEditorView.bmp(s)
    if tv.shouldChangeText(in: r, replacementString: fixed) {
      tv.textStorage?.replaceCharacters(in: r, with: fixed)
      tv.didChangeText()
      tv.setSelectedRange(NSRange(location: r.location + (fixed as NSString).length, length: 0))
    }
    return false
  }

  /// Each character outside the BMP as two U+FFFD.
  public static func bmp(_ s: String) -> String {
    var out = String.UnicodeScalarView()
    for u in s.unicodeScalars {
      if u.value > 0xFFFF { out.append("\u{FFFD}"); out.append("\u{FFFD}") } else { out.append(u) }
    }
    return String(out)
  }

  public func textDidChange(_ notification: Notification) {
    editing = false
    followRename()
    retint()
    changed()
  }

  public func textViewDidChangeSelection(_ notification: Notification) {
    textView.updateCaret()
    hoveredIssue = nil
    // the card shows when the caret comes to a marked line, not while typing on it
    if editing || applying { issueCard.isHidden = true } else { updateIssueCard() }
    trackRename()
    onSelection?()
    reportCaret()
    scheduleCursor()
    overlay.needsDisplay = true
  }

  // MARK: highlighting

  func highlight(_ r: NSRange) {
    guard let st = textView.textStorage else { return }
    let r = NSIntersectionRange(r, NSRange(location: 0, length: st.length))
    guard r.length > 0 else { return }
    let t = style.theme
    let colors: [LatexToken: NSColor] = [
      .comment: t.color(\.comment), .command: t.color(\.command), .env: t.color(\.env),
      .math: t.color(\.math), .bracket: t.color(\.bracket),
    ]
    let toks = LatexSyntax.tokens(st.mutableString, in: r)
    // The colour each character should have; then set only the runs that differ (each change re-lays the text out).
    let palette: [NSColor] = [t.color(\.fg), colors[.comment]!, colors[.command]!, colors[.env]!, colors[.math]!, colors[.bracket]!]
    let index: [LatexToken: UInt8] = [.comment: 1, .command: 2, .env: 3, .math: 4, .bracket: 5]
    var want = [UInt8](repeating: 0, count: r.length)
    for (range, tok) in toks {
      let a = max(range.location, r.location) - r.location, b = min(NSMaxRange(range), NSMaxRange(r)) - r.location
      let v = index[tok]!
      if a < b { for i in a..<b { want[i] = v } }
    }
    var began = false
    var i = 0
    while i < want.count {
      var j = i + 1
      while j < want.count && want[j] == want[i] { j += 1 }
      let run = NSRange(location: r.location + i, length: j - i)
      var eff = NSRange()
      let have = st.attribute(.foregroundColor, at: run.location, longestEffectiveRange: &eff, in: run) as? NSColor
      let color = palette[Int(want[i])]
      if eff.length < run.length || have != color {
        if !began { st.beginEditing(); began = true }
        st.addAttribute(.foregroundColor, value: color, range: run)
      }
      i = j
    }
    if began { st.endEditing() }
  }

  // MARK: review tints

  /// Review ranges to tint: (UTF-16 range, colour, strength 0…1, is a comment).
  func setTints(_ list: [(NSRange, NSColor, CGFloat, Bool)]) {
    allTints = list.map { (range: $0.0, color: $0.1, strength: $0.2, comment: $0.3) }
    retint()
  }

  func retint() {
    if isMetal { metalView?.setNeedsRender(); return }
    guard let tlm = textView.textLayoutManager, let tcs = tlm.textContentManager as? NSTextContentStorage else { return }
    tlm.removeRenderingAttribute(.backgroundColor, for: tcs.documentRange)
    tlm.removeRenderingAttribute(.underlineStyle, for: tcs.documentRange)
    let n = textView.textStorage?.length ?? 0
    for (r, c, a) in tints {
      let r = NSIntersectionRange(r, NSRange(location: 0, length: n))
      guard r.length > 0, let tr = textRange(r) else { continue }
      tlm.addRenderingAttribute(.backgroundColor, value: c.withAlphaComponent(a), for: tr)
    }
  }

  func textRange(_ r: NSRange) -> NSTextRange? {
    guard let tcs = textView.textLayoutManager?.textContentManager as? NSTextContentStorage,
          let a = tcs.location(tcs.documentRange.location, offsetBy: r.location),
          let b = tcs.location(a, offsetBy: r.length) else { return nil }
    return NSTextRange(location: a, end: b)
  }

  // MARK: positions

  /// Keep the line index through an edit: shift the lines after it, rescan only the edited text.
  private func updateLineStarts(_ s: NSString, _ range: NSRange, _ delta: Int) {
    guard var st = lineStarts16 else { return }
    let oldEnd = NSMaxRange(range) - delta  // the edited range's end before the edit
    // lines starting inside the replaced text go; those after it move by delta
    var lo = 0, hi = st.count
    while lo < hi { let m = (lo + hi) / 2; if st[m] <= range.location { lo = m + 1 } else { hi = m } }
    var k = lo
    while k < st.count && st[k] <= oldEnd { k += 1 }
    var fresh: [Int] = []
    var i = range.location
    let end = NSMaxRange(range)
    while i < end {
      let r = s.range(of: "\n", options: .literal, range: NSRange(location: i, length: end - i))
      if r.location == NSNotFound { break }
      fresh.append(r.location + 1)
      i = r.location + 1
    }
    let tail = st[k...].map { $0 + delta }
    st.replaceSubrange(lo..., with: fresh + tail)
    lineStarts16 = st
  }

  /// UTF-16 offset of each line's start.
  var starts16: [Int] {
    if let l = lineStarts16 { return l }
    let s = textView.string as NSString
    var out = [0]
    var i = 0
    let n = s.length
    while i < n {
      let r = s.range(of: "\n", options: .literal, range: NSRange(location: i, length: n - i))
      if r.location == NSNotFound { break }
      out.append(r.location + 1)
      i = r.location + 1
    }
    lineStarts16 = out
    return out
  }

  /// (0-based line, byte column) of a UTF-16 offset.
  public func lineCol(_ loc: Int) -> (Int, Int) {
    let st = starts16
    let loc = max(0, min(loc, (textView.string as NSString).length))  // an offset from older text stays in range
    var lo = 0, hi = st.count - 1
    while lo < hi { let m = (lo + hi + 1) / 2; if st[m] <= loc { lo = m } else { hi = m - 1 } }
    let s = textView.string as NSString
    let col = s.substring(with: NSRange(location: st[lo], length: max(0, loc - st[lo]))).utf8.count
    return (lo, col)
  }

  /// UTF-16 offset of (0-based line, byte column).
  public func location(line: Int, col: Int) -> Int {
    let st = starts16
    let l = max(0, min(line, st.count - 1))
    let s = textView.string as NSString
    let lineEnd = l + 1 < st.count ? st[l + 1] - 1 : s.length
    let text = s.substring(with: NSRange(location: st[l], length: lineEnd - st[l]))
    return st[l] + Utf.utf16(Array(text.utf8), col)
  }

  public var caret: Int { textView.selectedRange().location }

  /// Put the caret on a 1-based line (and byte column), scrolled into the middle third.
  public func jump(line: Int, col: Int?) {
    let loc = location(line: line - 1, col: col ?? 0)
    textView.setSelectedRange(NSRange(location: loc, length: 0))
    textView.scrollRangeToVisible(NSRange(location: loc, length: 0))
    if let y = y(ofLine: line - 1) {
      let clip = scroll.contentView
      let target = clip.bounds.minY + y - clip.bounds.height / 3
      clip.scroll(to: NSPoint(x: 0, y: max(0, target)))
      scroll.reflectScrolledClipView(clip)
    }
    window?.makeFirstResponder(textView)
  }

  /// The caret and its line for `onCaret`; a key that moves and edits reports once.
  private func reportCaret() {
    guard let f = onCaret else { return }
    let (l, c) = lineCol(caret)
    let st = starts16, s = textView.string as NSString
    let end = l + 1 < st.count ? st[l + 1] - 1 : s.length
    let text = s.substring(with: NSRange(location: st[l], length: max(0, end - st[l])))
    if let last = lastCaret, last.0 == l, last.1 == c, last.2 == text { return }
    lastCaret = (l, c, text)
    f(l + 1, c, text)
  }

  private func scheduleCursor() {
    cursorTimer?.invalidate()
    let t = Timer(timeInterval: 0.15, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.reportCursor(force: false) } }
    RunLoop.main.add(t, forMode: .common)
    cursorTimer = t
  }

  public func reportCursor(force: Bool) {
    let (l, c) = lineCol(caret)
    if !force, let last = lastCursor, last.0 == l { lastCursor = (l, c); return }
    lastCursor = (l, c)
    onCursor?(l + 1, c)
  }

  // MARK: EditorGeometry

  public var lineHeight: CGFloat {
    let f = font
    return ceil(f.ascender - f.descender + f.leading) + style.lineSpacing
  }

  public func y(ofLine line: Int) -> CGFloat? {
    if let lay = textLayout {
      guard line >= 0, line < lay.paras.count else { return nil }
      return convert(NSPoint(x: 0, y: lay.y(ofPara: line)), from: docView).y
    }
    let st = starts16
    guard line >= 0, line < st.count, let tlm = textView.textLayoutManager,
          let tcs = tlm.textContentManager as? NSTextContentStorage,
          let loc = tcs.location(tcs.documentRange.location, offsetBy: st[line]),
          let frag = tlm.textLayoutFragment(for: loc) else { return nil }
    let y = frag.layoutFragmentFrame.minY + textView.textContainerOrigin.y
    return convert(NSPoint(x: 0, y: y), from: textView).y
  }

  public var visibleLines: ClosedRange<Int> {
    let r = scroll.contentView.bounds
    if let lay = textLayout {
      let top = lay.para(ofVisualLine: Int(floor((r.minY - lay.origin.y) / lay.lineHeight))).0
      let bot = lay.para(ofVisualLine: Int(floor((r.maxY - 1 - lay.origin.y) / lay.lineHeight))).0
      return top...max(top, bot)
    }
    let top = r.minY - textView.textContainerOrigin.y, bottom = r.maxY - textView.textContainerOrigin.y
    guard let tlm = textView.textLayoutManager, let tcs = tlm.textContentManager as? NSTextContentStorage else { return 0...0 }
    var first: Int?, last: Int?
    let topFrag = tlm.textLayoutFragment(for: CGPoint(x: 0, y: max(0, top)))
    let botFrag = tlm.textLayoutFragment(for: CGPoint(x: 0, y: max(0, bottom - 1)))
    if let f = topFrag { first = tcs.offset(from: tcs.documentRange.location, to: f.rangeInElement.location) }
    if let f = botFrag { last = tcs.offset(from: tcs.documentRange.location, to: f.rangeInElement.location) }
    let a = lineCol(first ?? 0).0
    let b = last.map { lineCol($0).0 } ?? max(a, starts16.count - 1)
    return a...max(a, b)
  }

  public func onChange(_ handler: @escaping @MainActor () -> Void) { handlers.append(handler) }

  func changed() {
    metalView?.setNeedsRender(withCommit: true)
    overlay.needsDisplay = true
    issuesOverlay.needsDisplay = true
    if !issueCard.isHidden { updateIssueCard() }
    textView.updateCaret()
    for h in handlers { h() }
  }

  // MARK: \begin rename

  /// The caret inside the name of a `\begin{name}` whose `\end` exists: remember both.
  private func trackRename() {
    guard !applying, !editing else { return }
    let s = textView.string as NSString
    let loc = caret
    let line = s.lineRange(for: NSRange(location: loc, length: 0))
    let text = s.substring(with: line) as NSString
    var search = NSRange(location: 0, length: text.length)
    renamePair = nil
    while true {
      let b = text.range(of: "\\begin{", options: [], range: search)
      if b.location == NSNotFound { return }
      let nameStart = b.location + b.length
      let close = text.range(of: "}", options: [], range: NSRange(location: nameStart, length: text.length - nameStart))
      if close.location == NSNotFound { return }
      let abs = NSRange(location: line.location + nameStart, length: close.location - nameStart)
      if loc >= abs.location && loc <= NSMaxRange(abs) {
        let env = s.substring(with: abs)
        if let e = Comforts.matchingEnd(s, from: NSMaxRange(abs) + 1, env: env) { renamePair = (abs, e) }
        return
      }
      search = NSRange(location: close.location, length: text.length - close.location)
    }
  }

  /// After an edit inside the tracked begin's name: rename the end to match.
  private func followRename() {
    guard let p = renamePair, !applying else { return }
    let s = textView.string as NSString
    // The begin's name now: from its start to the next `}` on the line.
    let lineEnd = NSMaxRange(s.lineRange(for: NSRange(location: p.begin.location, length: 0)))
    let close = s.range(of: "}", options: [], range: NSRange(location: p.begin.location, length: lineEnd - p.begin.location))
    let open = p.begin.location >= 7 ? s.substring(with: NSRange(location: p.begin.location - 7, length: 7)) : ""
    guard open == "\\begin{", close.location != NSNotFound else { renamePair = nil; return }
    let newName = s.substring(with: NSRange(location: p.begin.location, length: close.location - p.begin.location))
    let delta = (newName as NSString).length - p.begin.length
    let end = NSRange(location: p.end.location + delta, length: p.end.length)
    guard NSMaxRange(end) <= s.length, s.substring(with: NSRange(location: end.location - 5, length: 5)) == "\\end{" else { renamePair = nil; return }
    let oldName = s.substring(with: end)
    if oldName == newName { renamePair = (NSRange(location: p.begin.location, length: (newName as NSString).length), end); return }
    let sel = textView.selectedRanges
    renamePair = nil
    if textView.shouldChangeText(in: end, replacementString: newName) {
      textView.textStorage?.replaceCharacters(in: end, with: newName)
      textView.didChangeText()
    }
    textView.selectedRanges = sel
    renamePair = (NSRange(location: p.begin.location, length: (newName as NSString).length), NSRange(location: end.location, length: (newName as NSString).length))
  }
}

/// Collaborators' cursors: a thin bar in their colour with their initials above it.
final class OthersOverlay: NSView {
  weak var owner: NativeEditorView?
  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override func draw(_ dirtyRect: NSRect) {
    MainActor.assumeIsolated {
      guard let o = owner, let d = o.doc else { return }
      for u in o.others {
        let loc = Utf.utf16(d.text, min(u.pos, d.text.count))
        var actual = NSRange()
        let screen = o.textView.firstRect(forCharacterRange: NSRange(location: loc, length: 0), actualRange: &actual)
        guard let win = o.window, screen != .zero else { continue }
        let r = convert(win.convertFromScreen(screen), from: nil)
        u.color.setFill()
        NSRect(x: r.minX - 1, y: r.minY, width: 2, height: max(r.height, o.lineHeight - 2)).fill()
        let label = u.initials as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9, weight: .semibold), .foregroundColor: NSColor.white]
        let sz = label.size(withAttributes: attrs)
        let box = NSRect(x: r.minX - 1, y: r.minY - sz.height - 1, width: sz.width + 6, height: sz.height + 1)
        NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).fill()
        label.draw(at: NSPoint(x: box.minX + 3, y: box.minY), withAttributes: attrs)
      }
    }
  }
}
