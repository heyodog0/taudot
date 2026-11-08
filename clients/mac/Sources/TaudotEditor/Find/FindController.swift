// The find experience, the same in both editor modes: FindController owns the bar, places and animates it at the top
// right of the editor column, and drives a FindTarget (NativeFindTarget: the native editor; NeovimFindTarget: Neovim's
// own search through clients/nvim/lua/taudot/find.lua). Typing never waits: one search runs at a time and the
// newest query replaces any waiting one.
import AppKit
import TaudotShared

/// Where a search runs: the editor.
@MainActor public protocol FindTarget: AnyObject {
  /// The bar opened (`backward`: with `?`). Returns the search history, newest first, as queries the bar can show.
  func findBegin(backward: Bool) async -> [FindQuery]
  /// Search as typed, from where the bar opened.
  func findSearch(_ q: FindQuery) async -> FindCount
  /// The next or previous match (document order) from the cursor.
  func findStep(forward: Bool) async -> FindCount
  /// Replace the current match (then go on to the next) or every match (one undo step). Returns how many.
  func findReplace(_ q: FindQuery, with template: String, all: Bool) async -> (FindCount, Int)
  /// The editor has the keys while the bar stays up: keep the count current as the cursor moves.
  func findPassive(_ on: Bool) async
  /// The bar closed. `keep`: the cursor stays on the match; else back where it was.
  func findEnd(keep: Bool) async
  /// The view that gets the keys back.
  var findResponder: NSView { get }
  /// The count changed by itself (n / N in the editor while the bar is up).
  var onFindCount: ((FindCount) -> Void)? { get set }
  /// The editor asks the bar to close (Esc in normal mode while it is passive, insert mode began).
  var onFindClose: (() -> Void)? { get set }
}

@MainActor public final class FindController {
  public let bar = FindBar()
  public let target: FindTarget
  public weak var host: NSView?
  public private(set) var isOpen = false
  /// Opened with `/` or `?`: Enter goes back to the editor (as Vim), the bar stays up and follows n / N.
  public private(set) var vimOpened = false
  private var backward = false
  private var running = false
  private var pending: FindQuery?
  private var lastSearched: FindQuery?
  private var history: [FindQuery] = []
  private var historyIndex = -1
  private var typedBeforeHistory: FindQuery?
  /// The last count shown (checks).
  public private(set) var count = FindCount()
  /// Searches finished (checks: wait for this to grow).
  public private(set) var searches = 0
  /// What the next search was asked with, for checks of the coalescing.
  public private(set) var lastQuery: FindQuery?
  /// The margin from the column's top-right corner (the native editor's scroller is under the right edge).
  public var inset = NSSize(width: 14, height: 10)
  /// Called whenever the bar shows a new count (the app: the PDF's marks).
  public var onCount: ((FindCount) -> Void)?
  public var onClosed: (() -> Void)?

  public init(target: FindTarget) {
    self.target = target
    bar.isHidden = true
    bar.onChange = { [weak self] q in self?.queryChanged(q) }
    bar.onEnter = { [weak self] shift in self?.enter(shift: shift) }
    bar.onNext = { [weak self] in self?.step(forward: true) }
    bar.onPrevious = { [weak self] in self?.step(forward: false) }
    bar.onClose = { [weak self] in self?.close() }
    bar.onReplace = { [weak self] all in self?.replace(all: all) }
    bar.onHistory = { [weak self] d in self?.browseHistory(d) }
    bar.onReplaceShown = { [weak self] _ in self?.place(animated: true) }
    bar.onFieldFocus = { [weak self] on in
      guard let self, self.isOpen else { return }
      Task { await self.target.findPassive(!on) }
    }
    target.onFindCount = { [weak self] c in self?.show(c) }
    target.onFindClose = { [weak self] in self?.close(focusEditor: false) }
  }

  /// Put the bar in a view (the editor column) and keep it at its top-right corner.
  public func install(in v: NSView) {
    host = v
    bar.removeFromSuperview()
    v.addSubview(bar, positioned: .above, relativeTo: nil)
    bar.autoresizingMask = v.isFlipped ? [.minXMargin, .maxYMargin] : [.minXMargin, .minYMargin]
    place(animated: false)
    NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: v, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.place(animated: false) }
    }
    v.postsFrameChangedNotifications = true
  }

  static var reduceMotion: Bool {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || ProcessInfo.processInfo.environment["TAUDOT_REDUCE_MOTION"] == "1"
  }
  static let motion: TimeInterval = 0.15

  /// The bar's frame in the host for its rows.
  public func frame(in v: NSView) -> NSRect {
    let w = min(FindBar.width, max(260, v.bounds.width - 2 * inset.width))
    let h = bar.wantedHeight
    let y = v.isFlipped ? inset.height : v.bounds.height - inset.height - h
    return NSRect(x: v.bounds.width - inset.width - w, y: y, width: w, height: h)
  }

  func place(animated: Bool) {
    guard let v = host else { return }
    let f = frame(in: v)
    if animated && !Self.reduceMotion && !bar.isHidden {
      NSAnimationContext.runAnimationGroup { c in
        c.duration = Self.motion
        c.timingFunction = CAMediaTimingFunction(name: .easeOut)
        bar.animator().frame = f
      }
    } else {
      bar.frame = f
    }
  }

  // MARK: open and close

  /// ⌘F (or ⌥⌘F with `replace`), `/` or `?` (`vim`, `backward`). Open again: the field takes the keys, all selected.
  public func open(replace: Bool = false, backward: Bool = false, vim: Bool = false, prefill: String? = nil) {
    if replace { bar.setReplaceShown(true) }
    if isOpen {
      // ⌘F again while open: back into the field (from the editor), or over to it.
      vimOpened = vim || (vimOpened && !replace)
      if vim { bar.set(FindQuery()); bar.show(count: FindCount()) }
      bar.focusField()
      if replace { bar.window?.makeFirstResponder(bar.replaceField) }
      if vim { queryChanged(bar.query) }
      return
    }
    isOpen = true
    vimOpened = vim
    self.backward = backward
    historyIndex = -1
    typedBeforeHistory = nil
    if !replace && !bar.replaceShown { bar.setReplaceShown(false) }
    // `/` starts empty, as Vim's; ⌘F shows the last search (all selected: typing replaces it).
    if vim { bar.set(FindQuery(matchCase: bar.query.matchCase, wholeWord: bar.query.wholeWord, regex: bar.query.regex)) }
    if let p = prefill, !p.isEmpty, !p.contains("\n") { bar.set(FindQuery(p, matchCase: bar.query.matchCase, wholeWord: bar.query.wholeWord, regex: false)) }
    bar.show(count: FindCount())
    place(animated: false)
    appear()
    bar.focusField()
    if replace { bar.window?.makeFirstResponder(bar.replaceField) }
    let q = bar.query
    Task {
      history = await target.findBegin(backward: backward)
      if !q.text.isEmpty { queryChanged(bar.query) }
    }
  }

  /// Esc, ✕, or the editor asked. The cursor stays on the match (as Vim's Esc after incsearch does here); with no
  /// match it goes back to where it was. The editor gets the keys back.
  public func close(focusEditor: Bool = true) {
    guard isOpen else { return }
    isOpen = false
    let keep = count.total > 0 && count.error == nil
    let wasFocused = bar.fieldHasFocus || (bar.window?.firstResponder as? NSTextView)?.delegate as? FindField != nil
    pending = nil
    disappear()
    if focusEditor || wasFocused { bar.window?.makeFirstResponder(target.findResponder) }
    Task {
      // a search still running finishes first: its cursor move must not land after the close
      while running { try? await Task.sleep(for: .milliseconds(5)) }
      await target.findEnd(keep: keep)
      onClosed?()
    }
  }

  private func appear() {
    bar.isHidden = false
    guard !Self.reduceMotion, let l = bar.layer else { bar.alphaValue = 1; return }
    bar.alphaValue = 1
    let g = CAAnimationGroup()
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 0
    fade.toValue = 1
    let slide = CABasicAnimation(keyPath: "transform.translation.y")
    slide.fromValue = bar.isFlipped ? 6 : -6
    slide.toValue = 0
    g.animations = [fade, slide]
    g.duration = Self.motion
    g.timingFunction = CAMediaTimingFunction(name: .easeOut)
    l.add(g, forKey: "appear")
  }

  private func disappear() {
    guard !Self.reduceMotion else { bar.isHidden = true; return }
    NSAnimationContext.runAnimationGroup({ c in
      c.duration = Self.motion
      c.timingFunction = CAMediaTimingFunction(name: .easeOut)
      bar.animator().alphaValue = 0
    }, completionHandler: { [weak self] in
      MainActor.assumeIsolated {
        guard let self, !self.isOpen else { return }
        self.bar.isHidden = true
        self.bar.alphaValue = 1
      }
    })
  }

  // MARK: searching

  func queryChanged(_ q: FindQuery) {
    guard isOpen else { return }
    if historyIndex >= 0 && bar.fieldHasFocus && q.text != history[safe: historyIndex]?.text { historyIndex = -1 }
    pending = q
    pump()
  }

  /// One search at a time; the newest waiting query goes next (older ones are dropped).
  private func pump() {
    guard !running, let q = pending else { return }
    pending = nil
    running = true
    lastQuery = q
    Task {
      let c = await target.findSearch(q)
      running = false
      lastSearched = q
      if isOpen { show(c) }
      searches += 1
      pump()
    }
  }

  func show(_ c: FindCount) {
    count = c
    bar.show(count: c)
    onCount?(c)
  }

  /// Enter in the field: next (⇧: previous). After `/` or `?`: back to the editor, the bar staying up for n / N.
  func enter(shift: Bool) {
    if vimOpened {
      bar.window?.makeFirstResponder(target.findResponder)
      if count.total == 0 { close() }
      return
    }
    step(forward: !shift)
  }

  /// ⌘G / ⇧⌘G, ↑ ↓, Enter.
  public func step(forward: Bool) {
    guard isOpen else { open(); return }
    Task {
      while running || pending != nil { try? await Task.sleep(for: .milliseconds(2)); pump() }
      running = true
      let c = await target.findStep(forward: forward)
      running = false
      show(c)
      searches += 1
    }
  }

  /// Replace one (then on to the next) or all.
  public func replace(all: Bool) {
    guard isOpen else { return }
    let q = bar.query
    let with = bar.replaceField.stringValue
    Task {
      while running || pending != nil { try? await Task.sleep(for: .milliseconds(2)); pump() }
      running = true
      let (c, _) = await target.findReplace(q, with: with, all: all)
      running = false
      show(c)
      searches += 1
    }
  }

  /// ↑ / ↓ in the field: older / newer searches (the editor's history, Neovim's `/` one in Neovim mode).
  func browseHistory(_ d: Int) {
    guard !history.isEmpty else { return }
    if historyIndex == -1 { typedBeforeHistory = bar.query }
    let i = historyIndex - d  // ↑ (-1) goes older: a higher index
    if i < 0 {
      historyIndex = -1
      if let t = typedBeforeHistory { bar.set(t) }
    } else {
      historyIndex = min(i, history.count - 1)
      bar.set(history[historyIndex])
    }
    bar.field.currentEditor()?.selectedRange = NSRange(location: (bar.field.stringValue as NSString).length, length: 0)
    queryChanged(bar.query)
  }

  /// Search again for what the bar shows (the text changed under it).
  public func refresh() { queryChanged(bar.query) }

  /// Wait until no search is running or waiting (checks).
  public func settle() async {
    while running || pending != nil { try? await Task.sleep(for: .milliseconds(2)) }
  }
}

extension Array {
  subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
