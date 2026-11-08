import AppKit
import SwiftUI
import XCTest
@testable import TaudotShared

/// TaudotMark drawn the way the app hosts it: an NSHostingView in an off-screen window (never ordered front).
@MainActor
final class TaudotMarkTests: XCTestCase {
  /// Renders the view at 1 pt = 1 px on white and returns its RGBA pixels.
  private func render<V: View>(_ view: V, width: Int = 247, height: Int = 201,
                               appearance: NSAppearance.Name = .aqua) -> NSBitmapImageRep {
    let back = appearance == .aqua ? Color.white : Color.black
    let host = NSHostingView(rootView: view.frame(width: CGFloat(width), height: CGFloat(height)).background(back))
    host.appearance = NSAppearance(named: appearance)
    host.frame = NSRect(x: 0, y: 0, width: width, height: height)
    let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: height),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    host.cacheDisplay(in: host.bounds, to: rep)
    return rep
  }

  /// A point inside the tau's stem in the 1024 grid, mapped into a render of `size` (the mark fills it exactly
  /// when the size has the mark's aspect ratio).
  private func point(_ x: CGFloat, _ y: CGFloat, in rep: NSBitmapImageRep) -> (Int, Int) {
    let s = CGFloat(rep.pixelsWide) / TaudotMark.box.width
    return (Int((x - TaudotMark.box.minX) * s), Int((y - TaudotMark.box.minY) * s))
  }

  private func grey(_ rep: NSBitmapImageRep, _ p: (Int, Int)) -> CGFloat {
    let c = rep.colorAt(x: p.0, y: p.1)!.usingColorSpace(.deviceRGB)!
    return (c.redComponent + c.greenComponent + c.blueComponent) / 3
  }

  /// The grid points used below, after the lean: the stem's middle, and the bar/stem join.
  private static let lean = CGAffineTransform(translationX: -520, y: -760)
    .concatenating(CGAffineTransform(rotationAngle: 12 * .pi / 180))
    .concatenating(CGAffineTransform(translationX: 410, y: 750))
  private static let stem = CGPoint(x: 556, y: 520).applying(lean)
  private static let join = CGPoint(x: 560, y: 310).applying(lean)
  private static let bar = CGPoint(x: 700, y: 300).applying(lean)

  func testPrimaryForegroundDrawsTheTau() {
    let light = render(TaudotMark(dot: TaudotMark.coral).foregroundStyle(.primary))
    XCTAssertLessThan(grey(light, point(Self.stem.x, Self.stem.y, in: light)), 0.2, "the tau is missing in light")
    let dark = render(TaudotMark(dot: TaudotMark.coral).foregroundStyle(.primary), appearance: .darkAqua)
    XCTAssertGreaterThan(grey(dark, point(Self.stem.x, Self.stem.y, in: dark)), 0.8, "the tau is missing in dark")
  }

  func testSecondaryAndLabelColorDrawTheTau() {
    for ink in [AnyShapeStyle(.secondary), AnyShapeStyle(Color(nsColor: .labelColor))] {
      let rep = render(TaudotMark(dot: TaudotMark.coral).foregroundStyle(ink))
      XCTAssertLessThan(grey(rep, point(Self.stem.x, Self.stem.y, in: rep)), 0.7, "the tau is missing")
    }
  }

  func testTranslucentInkIsEvenWhereStrokesCross() {
    let rep = render(TaudotMark().foregroundStyle(Color.black.opacity(0.5)))
    let join = grey(rep, point(Self.join.x, Self.join.y, in: rep))
    let bar = grey(rep, point(Self.bar.x, Self.bar.y, in: rep))
    XCTAssertLessThan(bar, 0.8, "the bar is missing")
    XCTAssertEqual(join, bar, accuracy: 0.03, "ink doubles where the bar and stem overlap")
  }
}
