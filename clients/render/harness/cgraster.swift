// cgraster PDF OUTDIR SCALE [PAGES...]: draws PDF pages with Core Graphics (CGPDFDocument) into white RGB bitmaps,
// written as OUTDIR/p<N>.png (N 0-based). The floor's Core Graphics side: what CG's antialiasing does to the same page.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let a = CommandLine.arguments
guard a.count >= 4, let doc = CGPDFDocument(URL(fileURLWithPath: a[1]) as CFURL), let scale = Double(a[3]) else {
  FileHandle.standardError.write("usage: cgraster PDF OUTDIR SCALE [PAGES...]\n".data(using: .utf8)!)
  exit(2)
}
let out = URL(fileURLWithPath: a[2])
let pages = a.count > 4 ? a[4...].compactMap { Int($0) } : Array(0..<doc.numberOfPages)
let space = CGColorSpace(name: ProcessInfo.processInfo.environment["CG_SPACE"].map { $0 as CFString } ?? CGColorSpace.sRGB)!
for p in pages {
  guard let page = doc.page(at: p + 1) else { continue }
  let box = page.getBoxRect(.cropBox)
  let w = Int((box.width * scale).rounded()), h = Int((box.height * scale).rounded())
  let cx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                     bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
  cx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
  cx.fill(CGRect(x: 0, y: 0, width: w, height: h))
  // MuPDF-like text: no font smoothing (it emboldens glyphs), antialiased, subpixel positions
  let env = ProcessInfo.processInfo.environment
  cx.setAllowsFontSmoothing(env["CG_SMOOTH"] != nil)
  cx.setShouldSmoothFonts(env["CG_SMOOTH"] != nil)
  cx.setAllowsFontSubpixelPositioning(env["CG_NOSUBPIX"] == nil)
  cx.setShouldSubpixelPositionFonts(env["CG_NOSUBPIX"] == nil)
  cx.setAllowsFontSubpixelQuantization(env["CG_QUANT"] != nil)
  cx.setShouldSubpixelQuantizeFonts(env["CG_QUANT"] != nil)
  cx.interpolationQuality = env["CG_INTERP_NONE"] != nil ? .none : .default
  cx.scaleBy(x: scale, y: scale)
  cx.translateBy(x: -box.minX, y: -box.minY)
  cx.drawPDFPage(page)
  let img = cx.makeImage()!
  let url = out.appendingPathComponent("p\(p).png")
  let dst = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(dst, img, nil)
  CGImageDestinationFinalize(dst)
}
