// winlist OWNER: on-screen windows of OWNER (prefix), front to back, larger than 400k pt²: "id x y w h" per line.
import CoreGraphics
let owner = CommandLine.arguments[1]
let minArea = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2]) ?? 400_000 : 400_000
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]
for w in list where (w[kCGWindowOwnerName as String] as? String ?? "").hasPrefix(owner) {
  let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
  let (x, y, ww, h) = (b["X"] ?? 0, b["Y"] ?? 0, b["Width"] ?? 0, b["Height"] ?? 0)
  if ww * h > minArea { print(w[kCGWindowNumber as String]!, Int(x), Int(y), Int(ww), Int(h)) }
}
