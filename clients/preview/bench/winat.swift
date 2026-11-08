// winat OWNER X Y: the id of the frontmost on-screen window of OWNER containing global point (X, Y), in points.
import CoreGraphics
let a = CommandLine.arguments
let owner = a[1], x = Double(a[2])!, y = Double(a[3])!
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]
for w in list where (w[kCGWindowOwnerName as String] as? String ?? "").hasPrefix(owner) {
  let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
  let (bx, by, bw, bh) = (b["X"] ?? 0, b["Y"] ?? 0, b["Width"] ?? 0, b["Height"] ?? 0)
  if x >= bx && x < bx + bw && y >= by && y < by + bh && bw * bh > 400_000 { print(w[kCGWindowNumber as String]!); break }
}
