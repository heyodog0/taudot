// Collaborators' cursors in the native editor (both TextKit and Metal): a bar in their colour at their place, with
// their initials above it, following scrolls.
import AppKit
import Foundation
import Testing
@testable import TaudotEditor
@testable import TaudotShared

@MainActor @Test func othersCursorsDrawnAtTheirPlace() async throws {
  for metal in [false, true] {
    let w = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 420, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
    let v = NativeEditorView(frame: w.contentView!.bounds, metal: metal)
    v.autoresizingMask = [.width, .height]
    w.contentView!.addSubview(v)
    var text = ""
    for i in 0..<60 { text += "line \(i) of the paper\n" }
    v.show(NativeDoc(docID: "d", path: "main.tex", text: text, seq: 0, conn: nil), buffer: 1)
    v.layoutSubtreeIfNeeded()
    let mode = metal ? "metal" : "textkit"
    let green = NSColor(srgbRed: 0.1, green: 0.9, blue: 0.1, alpha: 1)
    // on line 3, after "line 3 of" (Character offset = UTF-16 here)
    let pos = (text as NSString).range(of: "line 3 of").upperBound
    v.others = [(name: "Ann", initials: "AN", color: green, pos: pos)]
    w.displayIfNeeded()
    func greens() -> (n: Int, minX: CGFloat, minY: CGFloat) {
      let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(v.bounds.width * 2), pixelsHigh: Int(v.bounds.height * 2),
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 32)!
      rep.size = v.bounds.size
      v.cacheDisplay(in: v.bounds, to: rep)
      let data = rep.bitmapData!, row = rep.bytesPerRow
      var n = 0, mx = CGFloat.infinity, my = CGFloat.infinity
      for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide {
        let p = data + y * row + x * 4
        let r = Int(p[0]), g = Int(p[1]), b = Int(p[2])
        if g > 150, g - r > 75, g - b > 75 { n += 1; mx = min(mx, CGFloat(x) / 2); my = min(my, CGFloat(y) / 2) }
      } }
      return (n, mx, my)
    }
    let g = greens()
    let cw = ("M" as NSString).size(withAttributes: [.font: v.font]).width
    let wantX = v.textView.textContainerOrigin.x + 5 + 9 * cw
    let y3 = try #require(v.y(ofLine: 3))
    #expect(g.n > 20, "\(mode): the cursor drawn (\(g.n) px)")
    #expect(abs(g.minX - wantX) < 3, "\(mode): at its column (\(g.minX), want \(wantX))")
    #expect(g.minY < y3 && g.minY > y3 - 2 * v.lineHeight, "\(mode): its label above line 3 (\(g.minY), line at \(y3))")
    // scrolled: it moves with the text
    let clip = v.scroll.contentView
    clip.scroll(to: NSPoint(x: 0, y: v.lineHeight * 2))
    v.scroll.reflectScrolledClipView(clip)
    w.displayIfNeeded()
    let g2 = greens()
    #expect(abs((g.minY - g2.minY) - v.lineHeight * 2) < 1.5, "\(mode): follows the scroll (\(g.minY) → \(g2.minY))")
    v.others = []
    w.displayIfNeeded()
    #expect(greens().n == 0, "\(mode): gone")
  }
}
