// paracheck: is a paragraph preview the exact page? Renders the page the preview was drawn on with the preview over it,
// and the exact pass's page, as LiveDraw does (white paper, CGPDF), and compares the pixels.
//   swiftc -O -o paracheck Sources/TaudotPDF/ParaOverlay.swift Tests/parapreview/main.swift
//   paracheck SCALE < lines of {"event": <para event>, "exact": "<pdf>"}  →  one JSON line each
import CoreGraphics
import Foundation
import ImageIO

func png(_ ctx: CGContext, _ crop: CGRect, _ path: String) {
  guard let img = ctx.makeImage()?.cropping(to: crop), let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) else { return }
  CGImageDestinationAddImage(d, img, nil)
  CGImageDestinationFinalize(d)
}

func render(_ pdf: CGPDFDocument, page: Int, scale: Double, overlay: ParaOverlay?) -> (CGContext, Int, Int)? {
  guard let p = pdf.page(at: page + 1) else { return nil }
  let crop = p.getBoxRect(.cropBox)
  let w = Int((crop.width * scale).rounded(.up)), h = Int((crop.height * scale).rounded(.up))
  guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
  else { return nil }
  ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
  ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
  ctx.saveGState()
  let t = p.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: crop.size), rotate: 0, preserveAspectRatio: true)
  ctx.concatenate(t.concatenating(CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: 0, ty: Double(h) - crop.height * scale)))
  ctx.interpolationQuality = .high
  ctx.setShouldSubpixelPositionFonts(true)
  ctx.drawPDFPage(p)
  ctx.restoreGState()
  overlay?.draw(in: ctx, scale: scale, x0: 0, y0: 0, h: h)
  return (ctx, w, h)
}

let scale = Double(CommandLine.arguments.dropFirst().first ?? "2") ?? 2
while let line = readLine() {
  guard let j = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
    let ev = j["event"] as? [String: Any], let exactPath = j["exact"] as? String,
    let ov = ParaOverlay(event: ev), let basePath = ev["pdf"] as? String,
    let base = CGPDFDocument(URL(fileURLWithPath: basePath) as CFURL),
    let exact = CGPDFDocument(URL(fileURLWithPath: exactPath) as CFURL)
  else { print("{\"error\":\"input\"}"); continue }
  guard let (a, w, h) = render(base, page: ov.page, scale: scale, overlay: ov),
    let (b, w2, h2) = render(exact, page: ov.page, scale: scale, overlay: nil), w == w2, h == h2,
    let pa = a.data, let pb = b.data
  else { print("{\"error\":\"render\"}"); continue }
  let A = pa.assumingMemoryBound(to: UInt8.self), B = pb.assumingMemoryBound(to: UInt8.self)
  var diff = 0, maxd = 0, inBox = 0
  let bb = ov.bounds
  var minx = w, miny = h, maxx = -1, maxy = -1
  for y in 0..<h {
    for x in 0..<w {
      let o = (y * w + x) * 4
      var d = 0
      for c in 0..<3 { d = max(d, abs(Int(A[o + c]) - Int(B[o + c]))) }
      if d > 0 {
        diff += 1
        maxd = max(maxd, d)
        let px = Double(x) / scale, py = Double(y) / scale
        if bb.insetBy(dx: -2, dy: -2).contains(CGPoint(x: px, y: py)) { inBox += 1 }
        minx = min(minx, x); maxx = max(maxx, x); miny = min(miny, y); maxy = max(maxy, y)
      }
    }
  }
  if let dir = ProcessInfo.processInfo.environment["PARACHECK_PNG"] {
    let c = CGRect(x: bb.minX * scale - 20, y: bb.minY * scale - 20, width: bb.width * scale + 40, height: bb.height * scale + 40)
    png(a, c, "\(dir)/\(ov.go)-preview.png")
    png(b, c, "\(dir)/\(ov.go)-exact.png")
  }
  let r: [String: Any] = ["go": ov.go, "state": ov.state, "page": ov.page, "diff_px": diff, "max": maxd, "in_overlay": inBox,
                          "diff_box": diff > 0 ? [Double(minx) / scale, Double(miny) / scale, Double(maxx) / scale, Double(maxy) / scale] : []]
  print(String(decoding: try! JSONSerialization.data(withJSONObject: r), as: UTF8.self))
  fflush(stdout)
}
