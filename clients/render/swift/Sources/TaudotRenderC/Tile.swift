// C entry points for txp-render (driver.c's `render` verb): a page's display list, drawn into raw RGB tiles by
// TaudotRender, in the process that made the list. Copyright (c) 2026 the Taudot authors. MIT License.
import CoreGraphics
import Foundation
import TaudotRender

/// Parsed lists by the caller's key (a hash of the page's drawing): a scroll asks for many tiles of a few pages.
private var lists: [(key: UInt64, list: PageList)] = []
private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

/// Draws the w×h pixel rect at (x, y) of the page (y down from its top, at `scale` pixels per point) into `rgb`
/// (w*h*3 bytes, rows packed), white below. Returns 0, or -1 if the list can't be read.
@_cdecl("taudot_draw_tile")
public func taudot_draw_tile(_ bytes: UnsafePointer<UInt8>, _ len: Int, _ key: UInt64, _ scale: Double,
                             _ x: Int32, _ y: Int32, _ w: Int32, _ h: Int32, _ rgb: UnsafeMutablePointer<UInt8>) -> Int32 {
  let list: PageList
  if let i = lists.firstIndex(where: { $0.key == key }) {
    list = lists[i].list
    if i != lists.count - 1 { lists.append(lists.remove(at: i)) }
  } else {
    guard let l = try? PageList(bytes: Array(UnsafeBufferPointer(start: bytes, count: len))) else { return -1 }
    list = l
    lists.append((key, l))
    if lists.count > 12 { lists.removeFirst() }
  }
  let w = Int(w), h = Int(h)
  guard w > 0, h > 0, let cx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                         space: srgb, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
        let d = cx.data else { return -1 }
  memset(d, 255, w * h * 4)
  cx.setAllowsFontSmoothing(false)
  cx.setShouldSmoothFonts(false)
  cx.setAllowsFontSubpixelPositioning(true)
  cx.setShouldSubpixelPositionFonts(true)
  cx.setAllowsFontSubpixelQuantization(false)
  cx.setShouldSubpixelQuantizeFonts(false)
  cx.interpolationQuality = .medium
  // the tile's bottom edge is y + h pixels below the page's top: drawing with that as the height puts whole page
  // pixels on whole bitmap pixels
  cx.translateBy(x: CGFloat(-Int(x)), y: 0)
  let s = CGFloat(scale), m = 2 / s  // what the tile shows, in points, with a margin for antialiasing
  let vis = CGRect(x: CGFloat(x) / s - m, y: CGFloat(y) / s - m, width: CGFloat(w) / s + 2 * m, height: CGFloat(h) / s + 2 * m)
  Drawer.draw(list, in: cx, scale: s, height: CGFloat(Int(y) + h), visible: vis)
  let src = d.assumingMemoryBound(to: UInt8.self)
  for i in 0..<(w * h) {
    rgb[i * 3] = src[i * 4]
    rgb[i * 3 + 1] = src[i * 4 + 1]
    rgb[i * 3 + 2] = src[i * 4 + 2]
  }
  return 0
}

/// Forgets parsed lists (the document was reset).
@_cdecl("taudot_draw_reset")
public func taudot_draw_reset() { lists.removeAll() }
