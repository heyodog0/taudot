// taudot-raster LIST --scale S --out page.png [--groups built|all|paths,rules,...] [--stats]
// taudot-raster LIST --dump        the list as JSON, one op per line
// Draws a Taudot display list (../../dlist.md) into a white sRGB bitmap on the CPU, as the harness measures it.
import CoreGraphics
import Foundation
import ImageIO
import TaudotRender
import UniformTypeIdentifiers

func fail(_ s: String) -> Never {
  FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
  exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
var list: String?, out: String?, scale: CGFloat = 1, groups = Groups.built, dump = false, stats = false, repeats = 1, bench = false, benchLists: [String] = []
while !args.isEmpty {
  let a = args.removeFirst()
  switch a {
  case "--scale": scale = CGFloat(Double(args.isEmpty ? "" : args.removeFirst()) ?? 0)
  case "--out": out = args.isEmpty ? nil : args.removeFirst()
  case "--groups":
    guard let g = Groups(names: args.isEmpty ? "" : args.removeFirst()) else { fail("unknown group") }
    groups = g
  case "--dump": dump = true
  case "--bench": bench = true
  case "--stats": stats = true
  case "--repeat": repeats = Int(args.isEmpty ? "" : args.removeFirst()) ?? 1
  default: if bench { benchLists.append(a) }; list = a
  }
}
// --bench LIST...: draw every list in order in one process (caches warm as in an app), then again; per page µs as JSON
if bench {
  let pages = benchLists.map { try! PageList(contentsOf: URL(fileURLWithPath: $0)) }
  var first: [UInt64] = [], again: [UInt64] = []
  for pass in 0..<2 {
    for p in pages {
      let t = DispatchTime.now()
      _ = Drawer.raster(p, scale: scale, groups: groups)
      let us = (DispatchTime.now().uptimeNanoseconds - t.uptimeNanoseconds) / 1000
      if pass == 0 { first.append(us) } else { again.append(us) }
    }
  }
  print("{\"first_us\":\(first),\"again_us\":\(again)}")
  exit(0)
}
guard let list, scale > 0, dump || out != nil else {
  fail("usage: taudot-raster LIST --scale S --out page.png [--groups built|all|paths,rules,fonts,images,transparency] [--stats]\n       taudot-raster LIST --dump")
}

let t0 = DispatchTime.now()
let page: PageList
do { page = try PageList(contentsOf: URL(fileURLWithPath: list)) } catch { fail("\(list): \(error)") }
let t1 = DispatchTime.now()

if dump {
  print(Dump.json(page))
  exit(0)
}

var (img, st) = Drawer.raster(page, scale: scale, groups: groups)
var t1r = t1
for _ in 1..<max(1, repeats) { t1r = DispatchTime.now(); (img, st) = Drawer.raster(page, scale: scale, groups: groups) }
let t2 = DispatchTime.now()
let url = URL(fileURLWithPath: out!)
guard let dst = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
  fail("cannot write \(out!)")
}
CGImageDestinationAddImage(dst, img, nil)
guard CGImageDestinationFinalize(dst) else { fail("cannot write \(out!)") }
if stats {
  let us = { (a: DispatchTime, b: DispatchTime) in (b.uptimeNanoseconds - a.uptimeNanoseconds) / 1000 }
  let u = st.unsupported.map { "\"\($0.key)\":\($0.value)" }.joined(separator: ",")
  print("{\"ok\":true,\"w\":\(img.width),\"h\":\(img.height),\"ops\":\(st.ops),\"magenta\":\(st.magenta),\"read_us\":\(us(t0, t1)),\"draw_us\":\(us(t1r, t2)),\"unsupported\":{\(u)}}")
}
