// The paragraph preview on screen (ParaOverlay.swift reads and draws it): a layer over the page's tiles, drawn off
// the main thread as tiles are, until the exact page with its edits is up.
import AppKit
import CoreGraphics
import Foundation
import IOSurface
import QuartzCore

extension ParaOverlay {
  /// The preview as a tile: pixels (x0, y0)…(x0 + w, y0 + h) of its page at `scale`, white paper, restyled as
  /// LiveDraw restyles tiles.
  static func render(_ o: ParaOverlay, scale: Double, x0: Int, y0: Int, w: Int, h: Int, style: String) -> TileImage? {
    guard w > 0, h > 0 else { return nil }
    let props: [IOSurfacePropertyKey: Any] = [
      .width: w, .height: h, .bytesPerElement: 4, .pixelFormat: 0x4247_5241,  // 'BGRA'
      .bytesPerRow: (w * 4 + 63) & ~63,
    ]
    guard let surf = IOSurface(properties: props) else { return nil }
    surf.lock(options: [], seed: nil)
    defer { surf.unlock(options: [], seed: nil) }
    guard let ctx = CGContext(data: surf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: surf.bytesPerRow,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return nil }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    o.draw(in: ctx, scale: scale, x0: x0, y0: y0, h: h)
    if style != "white" { LiveDraw.restyle(surf, w: w, h: h, style: style, keep: []) }
    return TileImage(surface: surf)
  }
}

/// The pane's preview: one layer over the page's tiles, until the exact page with its edits is on screen.
@MainActor final class ParaLayer {
  nonisolated static let queue = DispatchQueue(label: "taudot.para", qos: .userInteractive)
  let layer = CALayer()
  private(set) var overlay: ParaOverlay?
  var retireOnSwap = false
  var gen = 0
  /// The most edits a PDF has brought: a preview rendered meanwhile that it covers is not put up.
  var covered = Int.min
  /// For tests and benches: previews put on screen, and the last one's edit time to on screen (ms).
  var shows = 0
  var onShown: ((ParaOverlay) -> Void)?

  init() {
    layer.anchorPoint = .zero
    layer.contentsGravity = .resize
    layer.isOpaque = true
    layer.zPosition = 5  // over tiles that land later
  }

  func set(_ o: ParaOverlay?) {
    overlay = o
    retireOnSwap = false
  }
}

extension PDFPaneView {
  /// Paint a paragraph preview over its page (drawn off the main thread at the page's tile scale).
  public func showPara(_ o: ParaOverlay) {
    guard o.page < pages.count else { return }
    let p = pages[o.page]
    let backing = Double(window?.backingScaleFactor ?? 2)
    let s = p.shown?.scale ?? Double(scroll.magnification) * backing
    let b = o.bounds.insetBy(dx: -1, dy: -1)
    let x0 = Int((b.minX * s).rounded(.down)), y0 = Int((b.minY * s).rounded(.down))
    let w = Int((b.maxX * s).rounded(.up)) - x0, h = Int((b.maxY * s).rounded(.up)) - y0
    para.gen += 1
    let g = para.gen, style = pageStyle.rawValue
    let box = UncheckedBox(o)
    ParaLayer.queue.async { [weak self] in
      let img = ParaOverlay.render(box.v, scale: s, x0: x0, y0: y0, w: w, h: h, style: style).map(UncheckedBox.init)
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          guard let self, g == self.para.gen, let img, box.v.page < self.pages.count, box.v.applied > self.para.covered else { return }
          let p = self.pages[box.v.page]
          CATransaction.begin()
          CATransaction.setDisableActions(true)
          let l = self.para.layer
          l.contents = img.v.surface
          l.contentsScale = CGFloat(backing)
          var r = CGRect(x: Double(x0) / s, y: Double(y0) / s, width: Double(w) / s, height: Double(h) / s)
          let px = p.origin.x * s, py = p.origin.y * s
          r.origin.x += (px.rounded() - px) / s
          r.origin.y += (py.rounded() - py) / s
          l.frame = r
          if l.superlayer !== p.layer { l.removeFromSuperlayer(); p.layer.addSublayer(l) }
          CATransaction.commit()
          self.para.set(box.v)
          self.para.shows += 1
          trace("para go \(box.v.go) \(box.v.state) on p\(box.v.page)")
          self.para.onShown?(box.v)
        }
      }
    }
  }

  /// A PDF with `applied` edits came: a preview it covers goes once its page's new tiles are up (now, if that page
  /// didn't change and none of its new tiles are still on the way). Item 8: tau-live sends a display page and then,
  /// within a few ms, that edit's other PDFs, which leave the page as it is (`changed` []); the preview went on the
  /// second, before the display page's tiles were up, and the old text showed for a frame or two at every key.
  public func retirePara(applied: Int, changed: [Int], pages n: Int) {
    para.covered = max(para.covered, applied)
    guard let o = para.overlay, applied >= o.applied, o.page < n else { return }
    // (a page out of view draws nothing new until it's scrolled to: the preview goes now)
    let swapping = o.page < pages.count && pages[o.page].lastShownVer != pages[o.page].ver && pagesInView.contains(o.page)
    if changed.contains(o.page) || swapping { para.retireOnSwap = true } else { removePara() }
  }

  /// Page i's new content is on screen (swapIfComplete).
  func paraPageSwapped(_ i: Int) {
    if para.retireOnSwap, para.overlay?.page == i { removePara() }
  }

  public func removePara() {
    para.gen += 1
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    para.layer.removeFromSuperlayer()
    para.layer.contents = nil
    CATransaction.commit()
    para.set(nil)
  }

  /// The preview on screen (tests).
  public var paraShown: ParaOverlay? { para.layer.superlayer == nil ? nil : para.overlay }
  public var paraShows: Int { para.shows }
}
