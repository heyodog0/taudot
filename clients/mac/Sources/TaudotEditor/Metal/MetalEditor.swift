// The native editor on Metal (TAUDOT_METALTEXT): the document view under the scroll view (the document's full size;
// mouse, cursor, the overlays), and NativeEditorView's side of it: laying the doc out, scrolling, drawing a key.
import AppKit
import TaudotShared

/// The scroll view's document in Metal mode: as tall as the laid-out text, transparent (MetalTextView draws under
/// it). Holds the text view (0×0 at its origin, so their coordinates are the same) and the overlays.
@MainActor final class MetalDocView: NSView {
  weak var owner: NativeEditorView?
  override var isFlipped: Bool { true }
  override var isOpaque: Bool { false }
  override var acceptsFirstResponder: Bool { false }
  /// Scrolling redraws the text under it (MetalTextView) in the same turn; AppKit's responsive scrolling would move
  /// a cached copy of this (empty) view ahead of that.
  override class var isCompatibleWithResponsiveScrolling: Bool { false }

  override func mouseDown(with e: NSEvent) { owner?.textView.metalMouseDown(e) }
  override func rightMouseDown(with e: NSEvent) {
    guard let tv = owner?.textView else { return }
    window?.makeFirstResponder(tv)
    if let m = tv.menu(for: e) { NSMenu.popUpContextMenu(m, with: e, for: self) }
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    for t in trackingAreas where t.owner === self { removeTrackingArea(t) }
    addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
  }

  /// Not under the pointer (a divider's grip overlaps the text's edge): leave the cursor alone.
  private func covered(_ e: NSEvent) -> Bool {
    guard let c = window?.contentView, let top = c.hitTest(c.convert(e.locationInWindow, from: nil)) else { return false }
    return !top.isDescendant(of: self)
  }
  override func cursorUpdate(with e: NSEvent) { if !covered(e) { NSCursor.iBeam.set() } }
  override func mouseMoved(with e: NSEvent) {
    if !covered(e) { NSCursor.iBeam.set() }
    owner?.mouseMoved(with: e)
  }

  // VoiceOver: the text view is the text area; this is only its frame.
  override func isAccessibilityElement() -> Bool { false }
}

extension NativeEditorView {
  /// Metal mode is on for this view.
  public var isMetal: Bool { textLayout != nil }

  /// Where overlays and geometry live: the document view (Metal) or the text view (TextKit).
  var canvas: NSView { isMetal ? docView : textView }

  /// The document's height (the scroll view's document).
  var documentHeight: CGFloat { isMetal ? docView.frame.height : textView.frame.height }

  /// Metal: set the text view up as the model and input only (never laid out by TextKit, never drawn).
  func setUpMetal() {
    guard let mv = MetalTextView(frame: bounds, owner: self) else { return }
    metalView = mv
    let tv = textView
    tv.isVerticallyResizable = false
    tv.isHorizontallyResizable = false
    tv.autoresizingMask = []
    tv.textContainer?.widthTracksTextView = false
    tv.textContainer?.size = NSSize(width: 1e6, height: 1e7)
    tv.isAutomaticTextCompletionEnabled = false
    tv.isAutomaticLinkDetectionEnabled = false
    tv.isAutomaticDataDetectionEnabled = false
    tv.isGrammarCheckingEnabled = false
    tv.inlinePredictionType = .no
    tv.frame = .zero
    docView.owner = self
    docView.frame = NSRect(origin: .zero, size: scroll.contentSize)
    docView.addSubview(tv)
    scroll.documentView = docView
    scroll.drawsBackground = false
    scroll.contentView.drawsBackground = false
    addSubview(mv, positioned: .below, relativeTo: scroll)
    textLayout = TextLayout(text: tv.textStorage!.mutableString, font: font, lineSpacing: style.lineSpacing,
                        origin: CGPoint(x: 21, y: 12), width: max(10, scroll.contentSize.width - 42))
  }

  /// Metal: the layout's width, insets and font from the view and style; the document's size; a frame.
  func metalLayoutChanged() {
    guard let lay = textLayout, let mv = metalView else { return }
    let side = textView.textContainerInset.width
    let pad = textView.textContainer?.lineFragmentPadding ?? 5
    let origin = CGPoint(x: side + pad, y: textView.textContainerInset.height)
    let width = max(10, scroll.contentSize.width - 2 * (side + pad))
    let changed = origin != lay.origin || width != lay.width || mv.frame != scroll.frame
    if origin != lay.origin || width != lay.width {
      // rewrapped: the line at the top of the view stays there
      keepingMetalTop {
        lay.origin = origin
        lay.width = width
      }
    }
    resizeDocument()
    if mv.frame != scroll.frame { mv.frame = scroll.frame }
    if changed { mv.setNeedsRender(withCommit: true) }
  }

  /// The document view as tall as the text (and at least the view).
  func resizeDocument() {
    guard let lay = textLayout else { return }
    let h = max(scroll.contentSize.height, lay.origin.y * 2 + lay.height)
    let size = NSSize(width: scroll.contentSize.width, height: h.rounded(.up))
    if docView.frame.size != size { docView.setFrameSize(size) }
  }

  /// Metal: keeps the line at the top of the view where it is across a change of the layout (font, width, insets).
  /// Returns the restore, for doing again later.
  @discardableResult func keepingMetalTop(_ change: () -> Void) -> () -> Void {
    guard let lay = textLayout else { change(); return {} }
    let clip = scroll.contentView
    guard clip.bounds.minY > 0 else { change(); return {} }
    // (the line most on screen: a line mostly scrolled off would leave a rewrapped one above the anchor)
    let top = lay.offset(at: CGPoint(x: lay.origin.x, y: clip.bounds.minY + lay.lineHeight / 2))
    let into = (clip.bounds.minY - (lay.caretRect(top).minY - lay.spacing)) / lay.lineHeight
    change()
    let restore = { [weak self] in
      guard let self, let lay = self.textLayout, top <= lay.text.length else { return }
      self.resizeDocument()
      let y = lay.caretRect(top).minY - lay.spacing + into * lay.lineHeight
      if abs(clip.bounds.minY - y) > 0.25 {
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: max(0, y)))
        self.scroll.reflectScrolledClipView(clip)
      }
    }
    restore()
    return restore
  }

  /// Metal: a key was handled: colour what it changed, size the document, draw and present now.
  func renderKey(_ key: Int32) {
    let t0 = CACurrentMediaTime()
    flushHighlight()
    resizeDocument()
    let t1 = CACurrentMediaTime()
    metalView?.render(withCommit: false, key: key)
    metalView?.lastKeyTimes = (t1 - t0, CACurrentMediaTime() - t1)
  }

  /// Metal: the highlight an edit asked for, now (before the frame), instead of at the end of the turn.
  func flushHighlight() {
    guard let r = pendingHighlight else { return }
    pendingHighlight = nil
    Latency.shared.section("highlight") { highlight(r) }
  }

  /// Metal: scroll the least so `r`'s end shows, with a line's margin (NSTextView's scrollRangeToVisible).
  func metalScrollToVisible(_ r: NSRange) {
    guard let lay = textLayout else { return }
    resizeDocument()
    let c = lay.caretRect(NSMaxRange(r))
    let clip = scroll.contentView
    let b = clip.bounds
    var y = b.minY
    if c.minY < b.minY { y = c.minY - lay.lineHeight * 0 }
    else if c.maxY > b.maxY { y = c.maxY - b.height }
    y = max(0, min(y, docView.frame.height - b.height))
    if y != b.minY {
      clip.setBoundsOrigin(NSPoint(x: b.minX, y: y))
      scroll.reflectScrolledClipView(clip)
    }
  }

  /// Metal: lay out the whole doc ahead, a slice per run-loop turn (~4 ms), keeping the line at the top of the view
  /// where it is when the paragraphs above it change height.
  func metalLayoutAhead() {
    guard textLayout != nil else { return }
    aheadLine = 0
    aheadTimer?.invalidate()
    aheadTimer = nil
    scheduleMetalAhead()
  }

  private func scheduleMetalAhead() {
    let t = Timer(timeInterval: 0.001, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.metalAheadStep() } }
    RunLoop.main.add(t, forMode: .common)
    aheadTimer = t
  }

  private func metalAheadStep() {
    aheadTimer = nil
    guard let lay = textLayout else { return }
    let clip = scroll.contentView
    // the paragraph at the top of the view, and where it is
    let topV = max(0, Int((clip.bounds.minY - lay.origin.y) / lay.lineHeight))
    let (topK, topL) = lay.para(ofVisualLine: topV)
    let y0 = lay.y(ofPara: topK)
    aheadLine = lay.layOut(from: aheadLine, budget: 0.004)
    let y1 = lay.y(ofPara: topK)
    resizeDocument()
    if abs(y1 - y0) > 0.25 && clip.bounds.minY > 0 {
      _ = topL
      clip.setBoundsOrigin(NSPoint(x: clip.bounds.minX, y: max(0, clip.bounds.minY + (y1 - y0))))
      scroll.reflectScrolledClipView(clip)
    }
    metalView?.setNeedsRender(withCommit: true)
    if aheadLine < lay.paras.count { scheduleMetalAhead() }
  }
}
