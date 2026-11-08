// The last run's pages on disk, so a project opens with its PDF at once: TeXpresso's first run takes 1.8–6 s (more
// with a cold format cache), and its pages replace these as they come.
//
// ~/Library/Caches/app.taudot.Taudot/pdf/<hash of the folder>/
//   index.json   the main file, page sizes, the scale each page is stored at, where the view was, when
//   pN.png       page N: 2 px/pt near the view (sharp at the usual zoom), 0.8 px/pt elsewhere
//   synctex.txt  the last SyncTeX, so clicks and forward search work before the new run has one
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import TaudotShared

public enum PageCache {
  public struct Index: Codable, Sendable {
    public var main: String
    public var sizes: [[Double]]
    public var scales: [Double]
    public var topPage: Int
    public var topY: Double
    public var saved: Date
    /// The page style the images were rendered in (nil: white, caches from before styles).
    public var style: String? = nil
  }

  /// $TAUDOT_PAGE_CACHE (a folder, for benches and tests), else ~/Library/Caches/app.taudot.Taudot/pdf (moved from the old app's cache).
  public static var root: URL {
    if let p = ProcessInfo.processInfo.environment["TAUDOT_PAGE_CACHE"] { return URL(fileURLWithPath: p) }
    return Compat.cachesFolder().appendingPathComponent("pdf")
  }

  /// A folder's cache under `root` (a pane's own root: tests and benches pass one instead of the process-wide env var).
  public static func dir(_ folder: URL, root: URL? = nil) -> URL {
    let h = SHA256.hash(data: Data(folder.standardizedFileURL.path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    return (root ?? Self.root).appendingPathComponent(h)
  }

  /// $TAUDOT_PAGE_CACHE=off: no page cache (the "before" of benches).
  public static var off: Bool { ProcessInfo.processInfo.environment["TAUDOT_PAGE_CACHE"] == "off" }

  /// The index of a folder's cache, if there is one for this main file.
  public static func load(_ folder: URL, main: String, root: URL? = nil) -> Index? {
    guard root != nil || !off, let d = try? Data(contentsOf: dir(folder, root: root).appendingPathComponent("index.json")),
      let i = try? JSONDecoder().decode(Index.self, from: d), i.main == main, !i.sizes.isEmpty
    else { return nil }
    return i
  }

  public static func image(_ folder: URL, page: Int, root: URL? = nil) -> CGImage? {
    let url = dir(folder, root: root).appendingPathComponent("p\(page).png") as CFURL
    guard let src = CGImageSourceCreateWithURL(url, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
  }

  public static func synctex(_ folder: URL, root: URL? = nil) -> String? {
    try? String(contentsOf: dir(folder, root: root).appendingPathComponent("synctex.txt"), encoding: .utf8)
  }

  static func write(_ folder: URL, index: Index, root: URL? = nil) {
    let d = dir(folder, root: root)
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    if let data = try? JSONEncoder().encode(index) { try? data.write(to: d.appendingPathComponent("index.json"), options: .atomic) }
  }

  static func write(_ folder: URL, page: Int, image: CGImage, root: URL? = nil) {
    let d = dir(folder, root: root)
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    let tmp = d.appendingPathComponent("p\(page).tmp.png")
    guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, image, nil)
    if CGImageDestinationFinalize(dest) {
      _ = try? FileManager.default.replaceItemAt(d.appendingPathComponent("p\(page).png"), withItemAt: tmp)
    }
  }

  static func write(_ folder: URL, synctex: String, root: URL? = nil) {
    let d = dir(folder, root: root)
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    try? synctex.write(to: d.appendingPathComponent("synctex.txt"), atomically: true, encoding: .utf8)
  }

  /// A BGRX surface (a render) as an image.
  static func cgImage(_ t: TileImage) -> CGImage? {
    let s = t.surface
    s.lock(options: .readOnly, seed: nil)
    defer { s.unlock(options: .readOnly, seed: nil) }
    guard let ctx = CGContext(data: s.baseAddress, width: s.width, height: s.height, bitsPerComponent: 8, bytesPerRow: s.bytesPerRow,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return nil }
    return ctx.makeImage()
  }
}
