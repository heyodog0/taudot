// The native editor's text, drawn with Metal (TAUDOT_METALTEXT): sits under the transparent scroll view, covering
// its clip view, and draws what is visible there: the background, review tints, find marks, the selection, the text
// in its syntax colours, IME's marked text, and the caret. A key is drawn and presented at once, at the end of its
// handler, without waiting for Core Animation's commit; a scroll is presented with the commit so the margin and the
// overlays move in the same frame.
import AppKit
import CoreText
import Metal
import QuartzCore
import TaudotShared

@MainActor final class MetalTextView: NSView {
  weak var owner: NativeEditorView?
  let renderer: Renderer
  let atlas: TextAtlas
  private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
  private var colors: [ObjectIdentifier: (NSColor, SIMD4<Float>)] = [:]
  /// A frame is wanted at the end of this run-loop turn.
  private var pending = false
  private var pendingWithCommit = false
  /// For checks: frames drawn, and what the last one drew.
  private(set) var frames = 0
  private(set) var lastGlyphs = 0
  /// Line notes shaped (by note and colour), for the layout's fonts of `noteGeneration`.
  private var noteShapes: [String: TextLayout.Shaped] = [:]
  private var noteGeneration = -1
  private weak var noteFont: NSFont?
  /// For checks: the notes the last frame drew (line, where they start in the document).
  private(set) var drawnNotes: [(line: Int, at: CGPoint)] = []
  /// For measuring: the last key's highlight + sizing, and its frame (seconds).
  var lastKeyTimes: (Double, Double) = (0, 0)

  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override var isOpaque: Bool { true }

  init?(frame: NSRect, owner: NativeEditorView) {
    guard let r = Renderer() else { return nil }
    renderer = r
    atlas = TextAtlas(device: r.device, scale: 2)
    self.owner = owner
    super.init(frame: frame)
    wantsLayer = true
    layerContentsRedrawPolicy = .never
  }

  required init?(coder: NSCoder) { fatalError() }

  override func makeBackingLayer() -> CALayer {
    let l = CAMetalLayer()
    l.device = renderer.device
    l.pixelFormat = .bgra8Unorm
    l.framebufferOnly = true
    l.isOpaque = true
    l.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
    l.maximumDrawableCount = 3
    l.allowsNextDrawableTimeout = true
    return l
  }

  var scale: CGFloat { window?.backingScaleFactor ?? 2 }

  /// Only `cacheDisplay` (checks, screenshots) asks a layer-backed view like this to draw: a frame as an image.
  override func draw(_ dirtyRect: NSRect) {
    guard let img = snapshot(), let ctx = NSGraphicsContext.current?.cgContext else { return }
    ctx.saveGState()
    ctx.translateBy(x: 0, y: bounds.height)
    ctx.scaleBy(x: 1, y: -1)
    ctx.draw(img, in: CGRect(origin: .zero, size: bounds.size))
    ctx.restoreGState()
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    atlas.scale = scale
    setNeedsRender()
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    setNeedsRender(withCommit: true)
  }

  /// Draw at the end of this run-loop turn (`withCommit`: presented with its Core Animation commit).
  func setNeedsRender(withCommit: Bool = false) {
    pendingWithCommit = pendingWithCommit || withCommit
    guard !pending else { return }
    pending = true
    RunLoop.main.perform(inModes: [.common]) { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.pending else { return }
        self.render(withCommit: self.pendingWithCommit)
      }
    }
  }

  func color(_ c: NSColor) -> SIMD4<Float> {
    let id = ObjectIdentifier(c)
    if let (k, v) = colors[id], k === c { return v }
    let s = c.usingColorSpace(.sRGB) ?? c
    let v = SIMD4<Float>(Float(s.redComponent), Float(s.greenComponent), Float(s.blueComponent), Float(s.alphaComponent))
    if colors.count > 512 { colors.removeAll() }
    colors[id] = (c, v)
    return v
  }

  // MARK: drawing

  /// Draw now. `key`: the keystroke this frame shows (its committed and presented probes).
  func render(withCommit: Bool = false, key: Int32 = 0) { render(withCommit: withCommit, key: key, into: nil) }

  /// For checks: draw a frame into an image (what the layer would show).
  func snapshot() -> CGImage? {
    let s = scale
    let w = Int((bounds.width * s).rounded()), h = Int((bounds.height * s).rounded())
    guard let surf = FrameSurface(device: renderer.device, width: w, height: h) else { return nil }
    render(withCommit: false, key: 0, into: surf)
    let io = surf.surface
    io.lock(options: .readOnly, seed: nil)
    defer { io.unlock(options: .readOnly, seed: nil) }
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: io.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: io.bytesPerRow, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
    return ctx.makeImage()
  }

  private func render(withCommit: Bool, key: Int32, into surface: FrameSurface?) {
    pending = false
    pendingWithCommit = false
    guard let o = owner, window != nil || surface != nil, let lay = o.textLayout else { return }
    let s = scale
    if atlas.scale != s { atlas.scale = s }
    let size = CGSize(width: (bounds.width * s).rounded(), height: (bounds.height * s).rounded())
    guard size.width >= 1, size.height >= 1 else { return }
    if surface == nil && metalLayer.drawableSize != size { metalLayer.drawableSize = size }
    if metalLayer.contentsScale != s { metalLayer.contentsScale = s }
    let t = o.style.theme
    let bg = color(t.color(\.bg))
    let clip = o.scroll.contentView.bounds  // the visible part of the document
    let sf = Float(s)
    let ox = Float(clip.minX), oy = Float(clip.minY)
    renderer.begin(viewport: Float(size.width), Float(size.height))
    func box(_ r: CGRect, _ c: SIMD4<Float>, radius: Float = 0) {
      let x = ((Float(r.minX) - ox) * sf).rounded(), y = ((Float(r.minY) - oy) * sf).rounded()
      let w = ((Float(r.maxX) - ox) * sf).rounded() - x, h = ((Float(r.maxY) - oy) * sf).rounded() - y
      guard w > 0, h > 0 else { return }
      renderer.rect(x, y, w, h, c, kind: radius > 0 ? .rounded : .solid, radius * sf)
    }

    // the visible visual lines and their character range
    let lh = lay.lineHeight
    let v0 = max(0, Int(floor((clip.minY - lay.origin.y) / lh)))
    let v1 = min(lay.totalLines - 1, Int(ceil((clip.maxY - lay.origin.y) / lh)))
    let text = lay.text
    var lo = 0, hi = 0
    var visible: [(k: Int, line: Int)] = []
    if v1 >= v0 {
      var (k, l) = lay.para(ofVisualLine: v0)
      lo = lay.starts[k]
      var v = v0
      while v <= v1 && k < lay.paras.count {
        let p = lay.ensure(k)
        if l >= p.lines { k += 1; l = 0; continue }
        visible.append((k, l))
        v += 1
        l += 1
      }
      // ensure() can change line counts above: recompute from the paragraph of the first line
      let lastK = visible.last?.k ?? k
      hi = lastK + 1 < lay.starts.count ? lay.starts[lastK + 1] : text.length
    }
    let visibleRange = NSRange(location: lo, length: hi - lo)

    // review tints
    for (r, c, a) in o.tints where NSIntersectionRange(r, visibleRange).length > 0 || (r.length == 0 && NSLocationInRange(r.location, visibleRange)) {
      let cc = color(c)
      for rr in lay.rects(NSIntersectionRange(r, NSRange(location: 0, length: text.length))) {
        box(rr, SIMD4(cc.x, cc.y, cc.z, Float(a)))
      }
    }
    // find marks
    let marks = o.findMarks
    if !marks.ranges.isEmpty {
      var i = 0, j = marks.ranges.count
      while i < j { let m = (i + j) / 2; if NSMaxRange(marks.ranges[m]) < lo { i = m + 1 } else { j = m } }
      let c = color(t.color(\.search))
      while i < marks.ranges.count, marks.ranges[i].location <= hi {
        let current = i == marks.current
        let a: Float = current ? (t.dark ? 0.55 : 0.6) : (t.dark ? 0.26 : 0.32)
        for rr in lay.rects(NSIntersectionRange(marks.ranges[i], NSRange(location: 0, length: text.length))) {
          let b = rr.insetBy(dx: -1, dy: 0)
          if current { box(b, c, radius: 3); box(b.insetBy(dx: 1.5, dy: 1.5), mix(bg, c, a), radius: 2) } else { box(b, SIMD4(c.x, c.y, c.z, a), radius: 3) }
        }
        i += 1
      }
    }
    // the selection
    let tv = o.textView
    let sel = tv.selectedRange()
    if sel.length > 0 {
      // (as NSTextView: the theme's colour while the text has the keys, the system's unemphasized grey otherwise)
      let active = tv.window?.isKeyWindow == true && tv.window?.firstResponder === tv
      let c: SIMD4<Float>
      if active {
        c = color(tv.selectedTextAttributes[.backgroundColor] as? NSColor ?? t.color(\.selection))
      } else {
        var v = SIMD4<Float>(0.5, 0.5, 0.5, 0.3)
        o.effectiveAppearance.performAsCurrentDrawingAppearance {
          if let s = NSColor.unemphasizedSelectedTextBackgroundColor.usingColorSpace(.sRGB) {
            v = SIMD4<Float>(Float(s.redComponent), Float(s.greenComponent), Float(s.blueComponent), Float(s.alphaComponent))
          }
        }
        c = v
      }
      for rr in lay.rects(sel, extendNewline: true) { box(rr, c) }
    }

    // the text
    let fg = color(t.color(\.fg))
    var glyphCount = 0
    var full = false
    let caretLoc = sel.location + sel.length
    let block = tv.caretShape != nil && tv.caretVisible
    var blockGlyphs: [(Int, Int)] = []  // (para, glyph) under a block caret
    var lastK = -1
    var runs: [(end: Int, color: SIMD4<Float>)] = []
    for (k, l) in visible {
      let p = lay.paras[k]
      let ps = lay.starts[k]
      if k != lastK {
        lastK = k
        runs = []
        if p.len > 0, text.length >= ps + p.len, let st = tv.textStorage {
          st.enumerateAttribute(.foregroundColor, in: NSRange(location: ps, length: p.len), options: []) { v, r, _ in
            runs.append((r.location + r.length - ps, (v as? NSColor).map { self.color($0) } ?? fg))
          }
        }
      }
      guard p.laid, !p.glyphs.isEmpty else { continue }
      let a = Int(p.breaks[l]), b = l + 1 < p.breaks.count ? Int(p.breaks[l + 1]) : p.len
      let x0 = p.xs[a]
      let lineTop = Float(lay.origin.y) + Float(lay.linesBefore(k) + l) * Float(lh)
      let baseY = ((lineTop + Float(lay.baseline) - oy) * sf).rounded()
      var ri = 0
      for g in 0..<p.glyphs.count {
        let gi = Int(p.gi[g])
        if gi < a || gi >= b { continue }
        while ri < runs.count - 1 && runs[ri].end <= gi { ri += 1 }
        let c = runs.isEmpty ? fg : runs[ri].color
        if block && ps + gi == caretLoc { blockGlyphs.append((k, g)) }
        let px = (Float(lay.origin.x) + p.gx[g] - x0 - ox) * sf
        let ix = px.rounded(.down)
        let sub = min(TextAtlas.subpixel - 1, Int((px - ix) * Float(TextAtlas.subpixel)))
        let e = atlas.entry(lay.fonts[Int(p.gf[g])], fontIndex: p.gf[g], glyph: p.glyphs[g], sub: sub, full: &full)
        if e.empty { continue }
        renderer.glyph(rect: SIMD4(ix + Float(e.dx), baseY + Float(e.dy), Float(e.w), Float(e.h)),
                       uv: SIMD4(Float(e.x), Float(e.y), Float(e.w), Float(e.h)), color: c, colorGlyph: e.color)
        glyphCount += 1
      }
    }
    // end-of-line comment notes, after the last visual line of their line
    let notes = o.shownNotes
    if !notes.isEmpty {
      if noteGeneration != lay.fontGeneration || noteFont !== lay.font { noteShapes.removeAll(); noteGeneration = lay.fontGeneration; noteFont = lay.font }
      let byLine = Dictionary(notes.map { ($0.line, $0) }, uniquingKeysWith: { a, _ in a })
      let comment = color(t.color(\.comment))
      drawnNotes = []
      for (k, l) in visible where l == lay.paras[k].lines - 1 {
        guard let n = byLine[k] else { continue }
        let key = n.string + "\u{0}" + (n.barColor.usingColorSpace(.sRGB).map { "\($0.redComponent),\($0.greenComponent),\($0.blueComponent)" } ?? "")
        let sh: TextLayout.Shaped
        if let c = noteShapes[key] { sh = c } else { sh = lay.shape(o.noteString(n)); noteShapes[key] = sh }
        let barLen = Int32((n.bar as NSString).length)
        let barColor = color(n.barColor)
        let x0 = Float(lay.origin.x + lay.lineEndX(k))
        let lineTop = Float(lay.origin.y) + Float(lay.linesBefore(k) + l) * Float(lh)
        let baseY = ((lineTop + Float(lay.baseline) - oy) * sf).rounded()
        drawnNotes.append((k, CGPoint(x: CGFloat(x0), y: CGFloat(lineTop))))
        for g in 0..<sh.glyphs.count {
          let px = (x0 + sh.gx[g] - ox) * sf
          if px > Float(size.width) { break }
          let ix = px.rounded(.down)
          let sub = min(TextAtlas.subpixel - 1, Int((px - ix) * Float(TextAtlas.subpixel)))
          let e = atlas.entry(lay.fonts[Int(sh.gf[g])], fontIndex: sh.gf[g], glyph: sh.glyphs[g], sub: sub, full: &full)
          if e.empty { continue }
          renderer.glyph(rect: SIMD4(ix + Float(e.dx), baseY + Float(e.dy), Float(e.w), Float(e.h)),
                         uv: SIMD4(Float(e.x), Float(e.y), Float(e.w), Float(e.h)), color: sh.gi[g] < barLen ? barColor : comment, colorGlyph: e.color)
        }
      }
    } else {
      drawnNotes = []
    }
    // IME's marked text: underlined
    let marked = tv.markedRange()
    if marked.location != NSNotFound && marked.length > 0 {
      for rr in lay.rects(marked) {
        box(CGRect(x: rr.minX, y: rr.minY + lay.baseline - lay.spacing + 2, width: rr.width, height: 1), fg)
      }
    }
    // the caret
    if tv.caretVisible {
      let cc = color(tv.cursorColor)
      let r = lay.caretRect(caretLoc)
      if let shape = tv.caretShape {
        let w = tv.blockWidth(at: caretLoc)
        let fh: CGFloat = ceil(lay.font.ascender - lay.font.descender + lay.font.leading)
        let cell = CGRect(x: r.minX, y: r.minY, width: w, height: min(r.height, fh))
        let part: CGRect
        switch shape {
        case .block, .bar: part = cell
        case .halfBlock: part = CGRect(x: cell.minX, y: cell.midY, width: cell.width, height: cell.height / 2)
        case .underline:
          let h: CGFloat = max(2, (cell.height * 0.15).rounded())
          part = CGRect(x: cell.minX, y: cell.maxY - h, width: cell.width, height: h)
        }
        box(part, cc)
        if shape == .block || shape == .bar {
          // the character under it, in the background colour
          for (k, g) in blockGlyphs {
            let p = lay.paras[k]
            let gi = Int(p.gi[g])
            var l = 0
            while l + 1 < p.breaks.count && Int(p.breaks[l + 1]) <= gi { l += 1 }
            let x0 = p.xs[Int(p.breaks[l])]
            let lineTop = Float(lay.origin.y) + Float(lay.linesBefore(k) + l) * Float(lh)
            let baseY = ((lineTop + Float(lay.baseline) - oy) * sf).rounded()
            let px = (Float(lay.origin.x) + p.gx[g] - x0 - ox) * sf
            let ix = px.rounded(.down)
            let sub = min(TextAtlas.subpixel - 1, Int((px - ix) * Float(TextAtlas.subpixel)))
            let e = atlas.entry(lay.fonts[Int(p.gf[g])], fontIndex: p.gf[g], glyph: p.glyphs[g], sub: sub, full: &full)
            if e.empty || e.color { continue }
            renderer.glyph(rect: SIMD4(ix + Float(e.dx), baseY + Float(e.dy), Float(e.w), Float(e.h)),
                           uv: SIMD4(Float(e.x), Float(e.y), Float(e.w), Float(e.h)), color: bg, colorGlyph: false)
          }
        }
      } else {
        let w = max(1, (2 / s)) // two pixels
        box(CGRect(x: r.minX - w / 2, y: r.minY, width: w, height: r.height), cc)
      }
    }
    if full {
      // the atlas started over mid-frame: what was placed before is stale; draw again
      render(withCommit: withCommit, key: key, into: surface)
      return
    }
    lastGlyphs = glyphCount
    frames += 1
    if let surface { renderer.end(surface: surface, atlas: atlas, clear: bg); return }
    metalLayer.presentsWithTransaction = withCommit
    if key != 0 {
      // committed: the frame handed to the GPU. presented: estimated as in TextKit mode (Latency.swift), the target of
      // the first display refresh after the GPU finished it (an off-screen drawable's presentedTime is only that).
      renderer.end(layer: metalLayer, atlas: atlas, clear: bg, completed: { t in
        DispatchQueue.main.async { MainActor.assumeIsolated { [weak self] in self?.awaitRefresh(key: key, done: t) } }
      })
      Latency.shared.record(.committed, key: key)
    } else {
      renderer.end(layer: metalLayer, atlas: atlas, clear: bg)
    }
  }

  // MARK: presented (estimate)

  private var awaiting: [(key: Int32, done: Double)] = []
  private var link: CADisplayLink?

  private func awaitRefresh(key: Int32, done: Double) {
    awaiting.append((key, done))
    if link == nil {
      let target = LinkTarget { [weak self] l in MainActor.assumeIsolated { self?.tick(l) } }
      let l = (window?.screen ?? NSScreen.main)?.displayLink(target: target, selector: #selector(LinkTarget.tick(_:)))
      l?.add(to: .main, forMode: .common)
      link = l
      linkTarget = target
    }
    link?.isPaused = false
  }
  private var linkTarget: LinkTarget?

  private func tick(_ l: CADisplayLink) {
    // the main thread may have been busy when the GPU finished (a page swap): the frame went up at the first refresh
    // after `done`, not at this tick's; count back whole periods (the window server doesn't wait for us)
    let period = max(0.001, l.targetTimestamp - l.timestamp)
    for a in awaiting where a.done <= l.timestamp + 0.0005 {
      let missed = max(0, ((l.timestamp + 0.0005 - a.done) / period).rounded(.down))
      Latency.shared.record(.presented, key: a.key, at: l.targetTimestamp - missed * period)
    }
    awaiting.removeAll { $0.done <= l.timestamp + 0.0005 }
    if awaiting.isEmpty { l.isPaused = true }
  }

  private func mix(_ a: SIMD4<Float>, _ b: SIMD4<Float>, _ t: Float) -> SIMD4<Float> {
    SIMD4(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t, 1)
  }
}

private final class LinkTarget: NSObject {
  let f: (CADisplayLink) -> Void
  init(_ f: @escaping (CADisplayLink) -> Void) { self.f = f }
  @objc func tick(_ l: CADisplayLink) { f(l) }
}
