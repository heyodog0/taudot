// The find bar on the native editor: matches from FindQuery over the text view's string, drawn as rendering
// attributes (the theme's search colour, the current one stronger), the caret moved as Vim's incsearch does, replace
// through the text view's own edit path (so it syncs, and replace-all is one undo step), and the Vim engine's `/`,
// `?`, n and N sharing the search.
import AppKit
import TaudotShared

@MainActor public final class NativeFindTarget: FindTarget {
  public weak var editor: NativeEditorView?
  private(set) var query: FindQuery?
  public private(set) var matches = FindMatches()
  private var origin = NSRange(location: 0, length: 0)
  private var originScroll: NSPoint?
  private var backward = false
  private var observers: [NSObjectProtocol] = []
  private var recountQueued = false
  private var history: [FindQuery] = []
  public var onFindCount: ((FindCount) -> Void)?
  public var onFindClose: (() -> Void)?
  /// The matches' lines changed (1-based, the current one's index in them, or nil): the PDF's marks.
  public var onLines: ((_ lines: [Int], _ current: Int?) -> Void)?

  public init(editor: NativeEditorView) {
    self.editor = editor
  }

  public var findResponder: NSView { editor?.textView ?? NSView() }
  private var tv: NativeTextView? { editor?.textView }
  private var text: NSString { (tv?.string ?? "") as NSString }
  private var vimOn: Bool { editor?.vim != nil }

  public func findBegin(backward: Bool) async -> [FindQuery] {
    self.backward = backward
    origin = tv?.selectedRange() ?? NSRange(location: 0, length: 0)
    originScroll = editor?.scroll.contentView.bounds.origin
    observe(true)
    return history
  }

  public func findSearch(_ q: FindQuery) async -> FindCount {
    query = q
    guard !q.text.isEmpty else {
      matches = FindMatches()
      restoreOrigin()
      mark()
      return FindCount()
    }
    switch q.matches(in: text) {
    case .failure(let e):
      return FindCount(error: e.message)
    case .success(let ranges):
      matches = FindMatches(ranges: ranges)
      // From where the bar opened, as Vim's incsearch: the next match after it (`?`: before it), wrapping.
      shareWithVim(q, from: nil)
      matches.current = matches.index(from: origin.location, forward: !backward)
      if let i = matches.current { go(to: i) } else { restoreOrigin() }
      mark()
      return matches.count
    }
  }

  public func findStep(forward: Bool) async -> FindCount {
    guard !matches.ranges.isEmpty, let tv else { return matches.count }
    let loc = tv.selectedRange().location
    matches.current = matches.index(from: loc, forward: forward)
    if let i = matches.current { go(to: i) }
    mark()
    return matches.count
  }

  public func findReplace(_ q: FindQuery, with template: String, all: Bool) async -> (FindCount, Int) {
    guard let tv else { return (FindCount(), 0) }
    if q != query { _ = await findSearch(q) }
    guard !matches.ranges.isEmpty, tv.isEditable else { return (matches.count, 0) }
    let s = text
    // An undo group of our own (inside the key event's, when there is one): never an edit outside any group.
    let um = tv.undoManager
    um?.beginUndoGrouping()
    defer { um?.endUndoGrouping() }
    if all {
      // One change of many ranges: one undo step. Applied last to first, each its own small edit for the engine.
      let reps = matches.replacements(q, in: s, with: template)
      let asc = reps.reversed()
      guard tv.shouldChangeText(inRanges: asc.map { NSValue(range: $0.0) }, replacementStrings: asc.map(\.1)) else { return (matches.count, 0) }
      for (r, str) in reps { tv.textStorage?.replaceCharacters(in: r, with: str) }
      tv.didChangeText()
      let n = reps.count
      recompute(keepCaret: true)
      return (matches.count, n)
    }
    // One: the match at the caret, then on to the next (if the caret isn't on one: first go there).
    let loc = tv.selectedRange().location
    guard let i = matches.index(at: loc) else { return (await findStep(forward: true), 0) }
    let r = matches.ranges[i]
    let str = q.replacement(for: r, in: s, with: template)
    guard tv.shouldChangeText(in: r, replacementString: str) else { return (matches.count, 0) }
    tv.textStorage?.replaceCharacters(in: r, with: str)
    tv.didChangeText()
    tv.breakUndoCoalescing()
    let after = r.location + (str as NSString).length
    recompute(keepCaret: false)
    matches.current = matches.index(from: after, forward: true, inclusive: true)
    if let j = matches.current { go(to: j) }
    mark()
    return (matches.count, 1)
  }

  public func findPassive(_ on: Bool) async {}

  public func findEnd(keep: Bool) async {
    observe(false)
    if let q = query, !q.text.isEmpty, keep {
      history.removeAll { $0 == q }
      history.insert(q, at: 0)
      if history.count > 50 { history.removeLast() }
      shareWithVim(q, from: origin.location)
    }
    if !keep { restoreOrigin() }
    matches = FindMatches()
    query = nil
    mark()
  }

  // MARK: helpers

  /// n and N in the Vim engine continue the bar's search (while it is up, too); `from`: the jump mark.
  private func shareWithVim(_ q: FindQuery, from: Int?) {
    guard case .success(let re) = q.compiled() else { return }
    editor?.vim?.setSearch(pattern: (re.options.contains(.caseInsensitive) ? "(?i)" : "(?-i)") + re.pattern, forward: !backward, from: from)
  }

  private func restoreOrigin() {
    guard let tv else { return }
    tv.setSelectedRange(origin)
    if let p = originScroll, let e = editor {
      e.scroll.contentView.setBoundsOrigin(p)
      e.scroll.reflectScrolledClipView(e.scroll.contentView)
    }
  }

  /// The caret on match i (Vim: at its start; else the match selected, as Mac editors do), scrolled into view.
  private func go(to i: Int) {
    guard let tv, let e = editor else { return }
    let r = matches.ranges[i]
    tv.setSelectedRange(vimOn ? NSRange(location: r.location, length: 0) : r)
    reveal(r, in: e)
  }

  /// Scroll so the range shows: not at all if it does; else with its line a third down the view (eased, ~150 ms).
  private func reveal(_ r: NSRange, in e: NativeEditorView) {
    let line = e.lineCol(r.location).0
    let vis = e.visibleLines
    if line > vis.lowerBound && line < vis.upperBound { return }
    guard let y = e.y(ofLine: line) else { e.textView.scrollRangeToVisible(r); return }
    let clip = e.scroll.contentView
    let maxY = max(0, e.documentHeight - clip.bounds.height)
    let target = max(0, min(maxY, clip.bounds.minY + y - clip.bounds.height / 3))
    let to = NSPoint(x: clip.bounds.minX, y: target)
    if FindController.reduceMotion || abs(target - clip.bounds.minY) > clip.bounds.height * 3 {
      clip.setBoundsOrigin(to)
      e.scroll.reflectScrolledClipView(clip)
      return
    }
    NSAnimationContext.runAnimationGroup { c in
      c.duration = FindController.motion
      c.timingFunction = CAMediaTimingFunction(name: .easeOut)
      clip.animator().setBoundsOrigin(to)
    }
    e.scroll.reflectScrolledClipView(clip)
  }

  private func mark() {
    editor?.setFindMarks(matches.ranges, current: matches.current)
    guard let e = editor, let onLines else { return }
    var lines: [Int] = []
    var cur: Int?
    for (i, r) in matches.ranges.enumerated() {
      let l = e.lineCol(r.location).0 + 1
      if lines.last != l { lines.append(l) }
      if i == matches.current { cur = lines.count - 1 }
      if lines.count >= 2000 { break }
    }
    onLines(lines, cur)
  }

  /// The text changed while the bar is up: find again; the current match is the one at or before the caret.
  private func recompute(keepCaret: Bool) {
    guard let q = query, case .success(let ranges) = q.matches(in: text) else { return }
    matches.ranges = ranges
    matches.current = currentByCaret()
    mark()
  }

  /// As Neovim's searchcount: the match at the caret, or the last one before it.
  private func currentByCaret() -> Int? {
    guard let tv, !matches.ranges.isEmpty else { return nil }
    let loc = tv.selectedRange().location
    if let i = matches.index(at: loc) { return i }
    let i = matches.index(from: loc, forward: false)
    return i.flatMap { matches.ranges[$0].location <= loc ? $0 : nil }
  }

  private func observe(_ on: Bool) {
    for o in observers { NotificationCenter.default.removeObserver(o) }
    observers = []
    guard on, let tv else { return }
    observers.append(NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: tv, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.queueRecount() }
    })
    observers.append(NotificationCenter.default.addObserver(forName: NSTextView.didChangeSelectionNotification, object: tv, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.query != nil, self.tv?.window?.firstResponder === self.tv else { return }
        let c = self.currentByCaret()
        if c != self.matches.current {
          self.matches.current = c
          self.mark()
          self.onFindCount?(self.matches.count)
        }
      }
    })
  }

  private func queueRecount() {
    guard !recountQueued else { return }
    recountQueued = true
    RunLoop.main.perform(inModes: [.common]) { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.recountQueued = false
        self.recompute(keepCaret: true)
        self.onFindCount?(self.matches.count)
      }
    }
  }
}

extension NativeEditorView {
  /// Find matches to draw (UTF-16 ranges, sorted) and the current one.
  public func setFindMarks(_ ranges: [NSRange], current: Int?) {
    findMarks = (ranges, current)
    if isMetal { metalView?.setNeedsRender(); return }  // drawn by MetalTextView
    let o = FindMarksOverlay.of(self)
    o.frame = textView.bounds
    o.needsDisplay = true
  }

  /// For checks: the find marks drawn (ranges, current).
  public var findMarkRanges: (ranges: [NSRange], current: Int?) { findMarks }
}

/// The find marks, over the text: the theme's search colour, light on every match on screen and strong, with a rim,
/// on the current one. (TextKit 2's rendering attributes didn't redraw already laid-out lines.) Only the visible
/// matches are drawn, so a short query with thousands of matches costs what the screen shows.
final class FindMarksOverlay: NSView {
  weak var owner: NativeEditorView?
  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  @MainActor static func of(_ e: NativeEditorView) -> FindMarksOverlay {
    if let o = e.textView.subviews.lazy.compactMap({ $0 as? FindMarksOverlay }).first { return o }
    let o = FindMarksOverlay(frame: e.textView.bounds)
    o.owner = e
    o.autoresizingMask = [.width, .height]
    // under the collaborators' cursors and the issue marks
    e.textView.addSubview(o, positioned: .below, relativeTo: e.textView.subviews.first)
    e.onChange { [weak o, weak e] in
      guard let o, let e, !e.findMarks.ranges.isEmpty else { return }
      if o.frame != e.textView.bounds { o.frame = e.textView.bounds }
      o.needsDisplay = true
    }
    return o
  }

  override func draw(_ dirtyRect: NSRect) {
    MainActor.assumeIsolated {
      guard let e = owner, !e.findMarks.ranges.isEmpty, let tlm = e.textView.textLayoutManager else { return }
      let marks = e.findMarks
      let st = e.starts16
      let vis = e.visibleLines
      let n = (e.textView.string as NSString).length
      let lo = st[min(vis.lowerBound, st.count - 1)]
      let hi = vis.upperBound + 1 < st.count ? st[vis.upperBound + 1] : n
      // the first match on screen (binary search), then on until past the screen
      var i = 0, j = marks.ranges.count
      while i < j { let m = (i + j) / 2; if NSMaxRange(marks.ranges[m]) < lo { i = m + 1 } else { j = m } }
      let c = e.style.theme.color(\.search)
      let dark = e.style.theme.dark
      let o = e.textView.textContainerOrigin
      while i < marks.ranges.count, marks.ranges[i].location <= hi {
        let r = NSIntersectionRange(marks.ranges[i], NSRange(location: 0, length: n))
        let current = i == marks.current
        if r.length > 0, let tr = e.textRange(r) {
          tlm.enumerateTextSegments(in: tr, type: .highlight, options: []) { _, f, _, _ in
            let box = NSRect(x: f.minX + o.x - 1, y: f.minY + o.y, width: f.width + 2, height: f.height).integral
            guard box.intersects(dirtyRect) else { return true }
            let p = NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3)
            c.withAlphaComponent(current ? (dark ? 0.55 : 0.6) : (dark ? 0.26 : 0.32)).setFill()
            p.fill()
            if current {
              c.setStroke()
              p.lineWidth = 1.5
              p.stroke()
            }
            return true
          }
        }
        i += 1
      }
    }
  }
}
