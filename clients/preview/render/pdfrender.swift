// pdfrender: a persistent PDF renderer for the preview (CoreGraphics). One process, the document kept open.
//
// Reads one JSON request per line on stdin, answers one JSON line per request on stdout:
//   {"id":1,"op":"open","path":"/x/good-3.pdf"}                       -> {"id":1,"ok":true,"pages":12}
//   {"id":2,"op":"render","page":1,"scale":2.7,"x":0,"y":512,"w":512,"h":512,
//    "rgb":"/tmp/a.rgb","z":"/tmp/a.z"}                                 -> {"id":2,"ok":true,"w":512,"h":512,"cpu_us":...}
// render: page is 1-based; scale in pixels per point; (x, y, w, h) a pixel rectangle of the page at that scale,
// from its top-left. Writes raw RGB (w*h*3) to "rgb" and, if given, zlib (RFC 1950, for Kitty's o=z) to "z".
// "cpu_us" is this process's CPU time spent on the request. Requests are handled in order.
import Compression
import CoreGraphics
import Foundation

var doc: CGPDFDocument?
let out = FileHandle.standardOutput

func reply(_ o: [String: Any]) {
  var d = (try? JSONSerialization.data(withJSONObject: o)) ?? Data("{}".utf8)
  d.append(0x0a)
  out.write(d)
}

func cpuMicros() -> Int {
  var u = rusage()
  getrusage(RUSAGE_SELF, &u)
  return Int(u.ru_utime.tv_sec + u.ru_stime.tv_sec) * 1_000_000 + Int(u.ru_utime.tv_usec + u.ru_stime.tv_usec)
}

func adler32(_ p: UnsafeRawBufferPointer) -> UInt32 {
  var a: UInt32 = 1, b: UInt32 = 0
  var i = 0
  let n = p.count
  while i < n {
    let end = min(i + 5552, n)
    while i < end { a += UInt32(p[i]); b += a; i += 1 }
    a %= 65521; b %= 65521
  }
  return (b << 16) | a
}

/// zlib stream: 2-byte header, raw deflate (Compression's ZLIB is raw deflate), Adler-32 trailer.
func zlib(_ data: Data) -> Data {
  let cap = data.count + data.count / 10 + 1024
  var dst = Data(count: cap)
  let n = dst.withUnsafeMutableBytes { d in
    data.withUnsafeBytes { s in
      compression_encode_buffer(d.bindMemory(to: UInt8.self).baseAddress!, cap,
        s.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
    }
  }
  var z = Data([0x78, 0x01])
  z.append(dst.prefix(n))
  var ad = data.withUnsafeBytes { adler32($0) }.bigEndian
  withUnsafeBytes(of: &ad) { z.append(contentsOf: $0) }
  return z
}

func render(_ r: [String: Any]) -> [String: Any] {
  guard let doc = doc, let pn = r["page"] as? Int, let page = doc.page(at: pn),
    let scale = r["scale"] as? Double, let x = r["x"] as? Double, let y = r["y"] as? Double,
    let w = r["w"] as? Int, let h = r["h"] as? Int, w > 0, h > 0, let rgbPath = r["rgb"] as? String
  else { return ["ok": false, "error": "bad render request"] }
  let box = page.getBoxRect(.cropBox)
  let pageH = box.height * scale
  // RGBX: CoreGraphics wants 32-bit pixels; packed to RGB below
  guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
  else { return ["ok": false, "error": "no context"] }
  ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
  ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
  ctx.interpolationQuality = .high
  // page pixel (x, y) from the top-left -> context origin; PDF space is points from the box's bottom-left
  ctx.translateBy(x: -x, y: -(pageH - y - Double(h)))
  ctx.scaleBy(x: scale, y: scale)
  ctx.translateBy(x: -box.minX, y: -box.minY)
  ctx.drawPDFPage(page)
  guard let base = ctx.data else { return ["ok": false, "error": "no data"] }
  var rgb = Data(count: w * h * 3)
  rgb.withUnsafeMutableBytes { dst in
    let d = dst.bindMemory(to: UInt8.self).baseAddress!
    let s = base.assumingMemoryBound(to: UInt8.self)
    for i in 0..<(w * h) {
      d[i * 3] = s[i * 4]; d[i * 3 + 1] = s[i * 4 + 1]; d[i * 3 + 2] = s[i * 4 + 2]
    }
  }
  do {
    try rgb.write(to: URL(fileURLWithPath: rgbPath))
    if let zp = r["z"] as? String { try zlib(rgb).write(to: URL(fileURLWithPath: zp)) }
  } catch { return ["ok": false, "error": "\(error)"] }
  return ["ok": true, "w": w, "h": h]
}

while let line = readLine() {
  guard let r = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
  let id = r["id"] ?? 0
  let c0 = cpuMicros()
  var res: [String: Any]
  switch r["op"] as? String {
  case "open":
    if let p = r["path"] as? String, let d = CGPDFDocument(URL(fileURLWithPath: p) as CFURL) {
      doc = d
      res = ["ok": true, "pages": d.numberOfPages]
    } else { res = ["ok": false, "error": "cannot open"] }
  case "render": res = render(r)
  default: res = ["ok": false, "error": "unknown op"]
  }
  res["id"] = id
  res["cpu_us"] = cpuMicros() - c0
  reply(res)
}
