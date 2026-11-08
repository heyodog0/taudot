// The Claude pane floating over the editor column: a rounded Liquid Glass panel (Spotlight / quick-terminal style)
// holding the terminal view. It lives inside the editor column (an overlay view), so it never covers the sidebar or
// the PDF and stays in the window. Drag by the top strip, resize from the edges; double-click the strip to dock.
// The frame is remembered as fractions of the column.
import AppKit

@MainActor final class ClaudeFloat: NSView {
  static let strip: CGFloat = 16, inset: CGFloat = 6, edge: CGFloat = 6, radius: CGFloat = 14
  let glass: NSView
  let content = NSView()
  /// A light tint over the panel while it isn't focused (opaque: the editor never shows through the terminal).
  let dim = NSView()
  var dimmed: Bool { !dim.isHidden }
  var onDock: (() -> Void)?
  var onFrameChange: (() -> Void)?
  /// Fractions of the column: centre x, bottom gap, width, height.
  var placement = ClaudeFloat.defaultPlacement
  static let defaultPlacement = (cx: 0.5, bottom: 0.03, w: 0.7, h: 0.4)

  override init(frame: NSRect) {
    if #available(macOS 26.0, *) {
      let g = NSGlassEffectView()
      g.cornerRadius = ClaudeFloat.radius
      g.style = .regular
      glass = g
    } else {
      let v = NSVisualEffectView()
      v.material = .hudWindow
      v.blendingMode = .withinWindow
      v.state = .active
      v.wantsLayer = true
      v.layer?.cornerRadius = ClaudeFloat.radius
      v.layer?.masksToBounds = true
      glass = v
    }
    super.init(frame: frame)
    wantsLayer = true
    shadow = {
      let s = NSShadow()
      s.shadowColor = NSColor.black.withAlphaComponent(0.45)
      s.shadowBlurRadius = 24
      s.shadowOffset = NSSize(width: 0, height: -6)
      return s
    }()
    glass.frame = bounds
    glass.autoresizingMask = [.width, .height]
    addSubview(glass)
    content.wantsLayer = true
    content.layer?.cornerRadius = ClaudeFloat.radius - ClaudeFloat.inset
    content.layer?.masksToBounds = true
    content.frame = contentRect
    content.autoresizingMask = [.width, .height]
    addSubview(content)
    dim.wantsLayer = true
    dim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.18).cgColor
    dim.layer?.cornerRadius = ClaudeFloat.radius
    dim.frame = bounds
    dim.autoresizingMask = [.width, .height]
    dim.isHidden = true
    addSubview(dim)
    if let s = UserDefaults.standard.array(forKey: "taudot.claudeFloat") as? [Double], s.count == 4 {
      placement = (s[0], s[1], s[2], s[3])
    }
  }
  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  var contentRect: NSRect {
    NSRect(x: Self.inset, y: Self.strip, width: max(0, bounds.width - 2 * Self.inset), height: max(0, bounds.height - Self.strip - Self.inset))
  }

  /// The frame for `placement` in a column of this size.
  func frameFor(_ host: NSRect) -> NSRect {
    let w = (host.width * placement.w).rounded(), h = (host.height * placement.h).rounded()
    let x = (host.width * placement.cx - w / 2).rounded()
    let bottom = host.height * placement.bottom
    // The column is flipped or not: place from the bottom either way.
    let y = superview?.isFlipped == true ? host.height - bottom - h : bottom
    return clamp(NSRect(x: x, y: y, width: w, height: h), in: host)
  }

  func layoutIn(_ host: NSRect) { frame = frameFor(host) }

  func clamp(_ r: NSRect, in host: NSRect) -> NSRect {
    var r = r
    r.size.width = min(max(r.width, 240), host.width)
    r.size.height = min(max(r.height, 120), host.height)
    r.origin.x = min(max(r.minX, 0), host.width - r.width)
    r.origin.y = min(max(r.minY, 0), host.height - r.height)
    return r
  }

  /// Remember the current frame as fractions of the column.
  func remember() {
    guard let host = superview?.bounds, host.width > 0, host.height > 0 else { return }
    let bottom = superview?.isFlipped == true ? host.height - frame.maxY : frame.minY
    placement = (Double(frame.midX / host.width), Double(bottom / host.height), Double(frame.width / host.width), Double(frame.height / host.height))
    if !backgroundRun { UserDefaults.standard.set([placement.cx, placement.bottom, placement.w, placement.h], forKey: "taudot.claudeFloat") }
  }

  // MARK: drag and resize

  enum Grab { case move, left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight }
  var grab: Grab?
  var start: (mouse: NSPoint, frame: NSRect) = (.zero, .zero)

  func grabAt(_ p: NSPoint) -> Grab? {
    let e = Self.edge
    let l = p.x < e, r = p.x > bounds.width - e, t = p.y < e, b = p.y > bounds.height - e
    switch (l, r, t, b) {
    case (true, _, true, _): return .topLeft
    case (_, true, true, _): return .topRight
    case (true, _, _, true): return .bottomLeft
    case (_, true, _, true): return .bottomRight
    case (true, _, _, _): return .left
    case (_, true, _, _): return .right
    case (_, _, true, _): return .top
    case (_, _, _, true): return .bottom
    default: return p.y < Self.strip ? .move : nil
    }
  }

  override func resetCursorRects() {
    let e = Self.edge
    addCursorRect(NSRect(x: e, y: e, width: bounds.width - 2 * e, height: Self.strip - e), cursor: .openHand)
    addCursorRect(NSRect(x: 0, y: 0, width: e, height: bounds.height), cursor: .resizeLeftRight)
    addCursorRect(NSRect(x: bounds.width - e, y: 0, width: e, height: bounds.height), cursor: .resizeLeftRight)
    addCursorRect(NSRect(x: 0, y: 0, width: bounds.width, height: e), cursor: .resizeUpDown)
    addCursorRect(NSRect(x: 0, y: bounds.height - e, width: bounds.width, height: e), cursor: .resizeUpDown)
  }

  override func mouseDown(with e: NSEvent) {
    let p = convert(e.locationInWindow, from: nil)
    if e.clickCount == 2, p.y < Self.strip { onDock?(); return }
    grab = grabAt(p)
    start = (superview?.convert(e.locationInWindow, from: nil) ?? .zero, frame)
    if grab == .move { NSCursor.closedHand.push() }
  }

  override func mouseDragged(with e: NSEvent) {
    guard let g = grab, let host = superview else { return }
    let m = host.convert(e.locationInWindow, from: nil)
    let dx = m.x - start.mouse.x, dy = m.y - start.mouse.y
    var r = start.frame
    // In the column's coordinates; "top" is the panel's top on screen.
    let flipped = host.isFlipped
    func moveTop(_ d: CGFloat) { if flipped { r.origin.y += d; r.size.height -= d } else { r.size.height += d } }
    func moveBottom(_ d: CGFloat) { if flipped { r.size.height += d } else { r.origin.y += d; r.size.height -= d } }
    switch g {
    case .move: r.origin.x += dx; r.origin.y += dy
    case .left: r.origin.x += dx; r.size.width -= dx
    case .right: r.size.width += dx
    case .top: moveTop(dy)
    case .bottom: moveBottom(dy)
    case .topLeft: r.origin.x += dx; r.size.width -= dx; moveTop(dy)
    case .topRight: r.size.width += dx; moveTop(dy)
    case .bottomLeft: r.origin.x += dx; r.size.width -= dx; moveBottom(dy)
    case .bottomRight: r.size.width += dx; moveBottom(dy)
    }
    frame = clamp(r, in: host.bounds)
    onFrameChange?()
  }

  override func mouseUp(with e: NSEvent) {
    if grab == .move { NSCursor.pop() }
    if grab != nil { remember() }
    grab = nil
  }

  // MARK: motion

  /// In: from 96% and transparent to full size (~200 ms, ease out); with Reduce Motion, a fade only.
  func appear(reduce: Bool) {
    isHidden = false
    guard let l = layer else { return }
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 0; fade.toValue = 1
    var anims: [CAAnimation] = [fade]
    if !reduce {
      let s = CABasicAnimation(keyPath: "transform")
      s.fromValue = NSValue(caTransform3D: scaled(0.96)); s.toValue = NSValue(caTransform3D: CATransform3DIdentity)
      anims.append(s)
    }
    let g = CAAnimationGroup()
    g.animations = anims
    g.duration = 0.2
    g.timingFunction = CAMediaTimingFunction(name: .easeOut)
    l.add(g, forKey: "appear")
  }

  /// Out: the reverse, then hidden.
  func disappear(reduce: Bool, then done: @escaping @MainActor () -> Void) {
    guard let l = layer else { isHidden = true; done(); return }
    CATransaction.begin()
    CATransaction.setCompletionBlock { MainActor.assumeIsolated { done() } }
    let fade = CABasicAnimation(keyPath: "opacity")
    fade.fromValue = 1; fade.toValue = 0
    var anims: [CAAnimation] = [fade]
    if !reduce {
      let s = CABasicAnimation(keyPath: "transform")
      s.fromValue = NSValue(caTransform3D: CATransform3DIdentity); s.toValue = NSValue(caTransform3D: scaled(0.96))
      anims.append(s)
    }
    let g = CAAnimationGroup()
    g.animations = anims
    g.duration = 0.16
    g.timingFunction = CAMediaTimingFunction(name: .easeIn)
    g.fillMode = .forwards
    g.isRemovedOnCompletion = false
    l.add(g, forKey: "disappear")
    CATransaction.commit()
  }

  /// A scale about the panel's centre (the layer's anchor is its corner).
  func scaled(_ k: CGFloat) -> CATransform3D {
    let cx = bounds.midX, cy = bounds.midY
    var t = CATransform3DMakeTranslation(cx, cy, 0)
    t = CATransform3DScale(t, k, k, 1)
    return CATransform3DTranslate(t, -cx, -cy, 0)
  }

  /// Unfocused: a little dimmer, the editor beneath stays live.
  func setFocused(_ f: Bool) { dim.isHidden = f }

  /// Clicks go to the terminal under the tint.
  override func hitTest(_ p: NSPoint) -> NSView? {
    let v = super.hitTest(p)
    return v === dim ? content.hitTest(convert(p, from: superview)) ?? self : v
  }
}
