import AppKit
import SwiftUI
import XCTest
@testable import TaudotHome
@testable import TaudotShared

/// TaudotWordmark, TaudotLockup and the sign-in card (which shows the mark), in an off-screen window (never ordered
/// front).
@MainActor
final class TaudotWordmarkTests: XCTestCase {
  private func window(_ view: NSView, _ size: NSSize, _ appearance: NSAppearance.Name) -> NSBitmapImageRep {
    view.appearance = NSAppearance(named: appearance)
    view.frame = NSRect(origin: .zero, size: size)
    let w = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: size.width, height: size.height),
                     styleMask: .borderless, backing: .buffered, defer: false)
    w.contentView = view
    view.layoutSubtreeIfNeeded()
    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: rep)
    return rep
  }

  private func render<V: View>(_ v: V, height: CGFloat, art: TaudotArt,
                               appearance: NSAppearance.Name = .aqua) -> NSBitmapImageRep {
    let size = NSSize(width: (height * art.box.width / art.box.height).rounded(), height: height)
    let back = appearance == .aqua ? Color.white : Color.black
    return window(NSHostingView(rootView: v.frame(width: size.width, height: size.height).background(back)),
                  size, appearance)
  }

  /// Grey level at a point of the art's own coordinates.
  private func grey(_ rep: NSBitmapImageRep, _ art: TaudotArt, _ x: CGFloat, _ y: CGFloat) -> CGFloat {
    let s = CGFloat(rep.pixelsHigh) / art.box.height
    let c = rep.colorAt(x: Int((x - art.box.minX) * s), y: Int((y - art.box.minY) * s))!.usingColorSpace(.deviceRGB)!
    return (c.redComponent + c.greenComponent + c.blueComponent) / 3
  }

  private func colour(_ rep: NSBitmapImageRep, _ art: TaudotArt, _ p: CGPoint) -> NSColor {
    let s = CGFloat(rep.pixelsHigh) / art.box.height
    return rep.colorAt(x: Int((p.x - art.box.minX) * s), y: Int((p.y - art.box.minY) * s))!.usingColorSpace(.deviceRGB)!
  }

  /// The d's stem (the tallest stroke) in the word's coordinates: after the T, a, u.
  private var dStem: CGPoint {
    let (_, tRight) = Hand.tau()
    let gap = 0.11 * Hand.xh, adv = Hand.letter("a").1
    let x = tRight + gap - 0.02 * Hand.xh + 3 * (adv + gap) - gap - Hand.w / 2
    return CGPoint(x: x, y: -600)
  }

  func testWordmarkDrawsInPrimaryLightAndDark() {
    let art = TaudotArt.wordmark
    let light = render(TaudotWordmark().foregroundStyle(.primary), height: 120, art: art)
    XCTAssertLessThan(grey(light, art, dStem.x, dStem.y), 0.3, "the d is missing in light")
    let dark = render(TaudotWordmark().foregroundStyle(.primary), height: 120, art: art, appearance: .darkAqua)
    XCTAssertGreaterThan(grey(dark, art, dStem.x, dStem.y), 0.8, "the d is missing in dark")
  }

  func testPeriodIsCoralUnlessOneColour() {
    let art = TaudotArt.wordmark
    let centre = CGPoint(x: art.dot.boundingRect.midX, y: art.dot.boundingRect.midY)
    let c = colour(render(TaudotWordmark().foregroundStyle(.black), height: 120, art: art), art, centre)
    XCTAssertGreaterThan(c.redComponent, 0.9)
    XCTAssertLessThan(c.greenComponent, 0.5)
    let mono = colour(render(TaudotWordmark(dot: nil).foregroundStyle(.black), height: 120, art: art), art, centre)
    XCTAssertLessThan(mono.redComponent, 0.2)
    XCTAssertTrue(TaudotArt.word.dot.isEmpty, "period: false has no period")
    XCTAssertLessThan(TaudotArt.word.box.width, art.box.width)
  }

  func testTranslucentInkIsEven() {
    // The T's bar meets its stem, and the a's stem meets its bowl: both should be as light as a plain stroke.
    let art = TaudotArt.word
    let rep = render(TaudotWordmark(period: false).foregroundStyle(Color.black.opacity(0.5)), height: 200, art: art)
    let plain = grey(rep, art, dStem.x, dStem.y)
    XCTAssertEqual(plain, 0.55, accuracy: 0.08, "a single layer of half ink")
    let (_, tRight) = Hand.tau()
    let aStem = tRight + 0.11 * Hand.xh - 0.02 * Hand.xh + Hand.letter("a").1 - Hand.w / 2
    XCTAssertEqual(grey(rep, art, aStem, -Hand.xh / 2), plain, accuracy: 0.03, "ink doubles at the a's join")
  }

  func testLockupHasTheMarksCoralDotAndTheWord() {
    let art = TaudotArt.lockup
    let rep = render(TaudotLockup().foregroundStyle(.black), height: 120, art: art)
    let dot = colour(rep, art, CGPoint(x: art.dot.boundingRect.midX, y: art.dot.boundingRect.midY))
    XCTAssertGreaterThan(dot.redComponent, 0.9)
    XCTAssertLessThan(dot.greenComponent, 0.5)
    XCTAssertLessThan(grey(rep, art, dStem.x, dStem.y), 0.2, "the word is missing")
    XCTAssertGreaterThan(art.box.width / art.box.height, 3)
  }

  func testSignInCardShowsTheMark() throws {
    for a in [NSAppearance.Name.aqua, .darkAqua] {
      let rep = window(SignInView(frame: .zero), NSSize(width: 560, height: 620), a)
      // Some coral (the mark's dot) is on the card.
      var coral = 0
      for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
        for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
          let c = rep.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
          if c.redComponent > 0.9 && c.greenComponent > 0.25 && c.greenComponent < 0.5 && c.blueComponent < 0.45 {
            coral += 1
          }
        }
      }
      XCTAssertGreaterThan(coral, 50, "no coral dot on the sign-in card (\(a.rawValue))")
      if let dir = ProcessInfo.processInfo.environment["TAUDOT_SHOT_DIR"] {
        try rep.representation(using: .png, properties: [:])!
          .write(to: URL(fileURLWithPath: dir).appendingPathComponent("signin-\(a == .aqua ? "light" : "dark").png"))
      }
    }
  }
}
