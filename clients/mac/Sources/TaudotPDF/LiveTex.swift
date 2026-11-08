// The app's side of the live pdfTeX (docs/live-protocol.md): start its driver, feed it edits, take the finished PDFs
// it announces and draw their pages with Core Graphics. Pages, words and the cursor's glyphs come from the PDF;
// SyncTeX and the log from the files beside it.
import Accelerate
import CoreGraphics
import Foundation
import IOSurface
import PDFKit
import TaudotCursor
import TaudotShared

/// Where the live pdfTeX's driver, engine, format and TeX Live tree are.
/// - driver: $TAUDOT_LIVE_DRIVER, else the app's `Resources/pdftex/<year>/pdftex-live`, else the pdftex agent's build
///   (~/code/lab/taudot-ref/pdftex-build-<year>/pdftex-live), else the repo's fake
///   (`clients/mac/Tests/live/fake-live.py`, stock pdfLaTeX from scratch: correct, not live).
/// - engine and format: $TAUDOT_LIVE_ENGINE / $TAUDOT_LIVE_FMT, else the app's `Resources/pdftex/<year>/`, else the
///   pdftex agent's builds in ~/code/lab/taudot-ref/pdftex-build-<year>/ (stock for the fake, live for the driver).
/// - TeX Live: the store's tree for the year (`tl.py store`), fetched on demand by the engine's kpathsea.
public enum LiveTexPaths {
  static var ref: String { ProcessInfo.processInfo.environment["TAUDOT_REF"] ?? NSHomeDirectory() + "/code/lab/taudot-ref" }
  /// The app's `Resources/pdftex` ($TAUDOT_PDFTEX_RESOURCES: another, for tests of a bundle's layout).
  static var resources: URL? {
    if let r = ProcessInfo.processInfo.environment["TAUDOT_PDFTEX_RESOURCES"] { return URL(fileURLWithPath: r) }
    return Bundle.main.resourceURL?.appendingPathComponent("pdftex")
  }
  /// TeX Live images in the store (tl.py's IMAGES).
  public static let images = ["2026": "2026.1@r79468", "2025": "2025.1@r74524", "2024": "2024.1@r70643"]
  public static let storeURL = "https://texlive.taudot.app"

  /// The driver's command line before its own arguments, for `year`. $TAUDOT_LIVE_DRIVER=fake forces the fake.
  public static func driver(_ year: String, env: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
    if let d = env["TAUDOT_LIVE_DRIVER"] {
      if d == "fake" { return python(fake) }
      return d.hasSuffix(".py") ? python(d) : [d]
    }
    for r in [resources?.appendingPathComponent("\(year)/pdftex-live").path, "\(build(year))/pdftex-live"].compactMap({ $0 })
    where FileManager.default.isExecutableFile(atPath: r) {
      return [r]
    }
    return python(fake)
  }
  static var fake: String {
    TxpPaths.repo.appendingPathComponent("clients/mac/Tests/live/fake-live.py").path
  }
  static func python(_ script: String) -> [String] {
    let uv = [NSHomeDirectory() + "/.local/bin/uv", "/opt/homebrew/bin/uv", "/usr/local/bin/uv"]
      .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "uv"
    return [uv, "run", "--no-project", "--quiet", "python", script]
  }
  public static func isFake(_ year: String, env: [String: String] = ProcessInfo.processInfo.environment) -> Bool { driver(year, env: env).last?.hasSuffix("fake-live.py") == true }

  static func build(_ year: String) -> String { "\(ref)/pdftex-build-\(year)" }
  public static func engine(_ year: String, env: [String: String] = ProcessInfo.processInfo.environment) -> String {
    if let e = env["TAUDOT_LIVE_ENGINE"] { return e }
    if let r = resources?.appendingPathComponent("\(year)/pdflatex"), FileManager.default.isExecutableFile(atPath: r.path) {
      return r.path
    }
    return "\(build(year))/\(isFake(year, env: env) ? "stock" : "live")/texk/web2c/pdflatex"
  }
  public static func bibtex(_ year: String) -> String? {
    let p = resources?.appendingPathComponent("\(year)/bibtex").path ?? ""
    if FileManager.default.isExecutableFile(atPath: p) { return p }
    let b = "\(build(year))/stock/texk/web2c/bibtex"
    return FileManager.default.isExecutableFile(atPath: b) ? b : nil
  }
  public static func formats(_ year: String, env: [String: String] = ProcessInfo.processInfo.environment) -> String {
    if let f = env["TAUDOT_LIVE_FMT"] { return f }
    if let r = resources?.appendingPathComponent("\(year)/fmt"), FileManager.default.fileExists(atPath: r.path) { return r.path }
    return "\(build(year))/fmt-\(isFake(year, env: env) ? "stock" : "live")"
  }
  /// The year's TeX Live tree (kpathsea's TEXMFROOT; the engine fetches into it). In the app: made at first use under
  /// ~/Library/Caches/taudot/texlive-<year> from the bundle's skeleton (`Resources/pdftex/<year>/tree`: the two
  /// ls-R files and TeX Live's own texmf.cnf). Else the pdftex agent's (`tl.py store`).
  static func storeRoot(_ year: String) -> String {
    guard let skel = resources?.appendingPathComponent("\(year)/tree"), FileManager.default.fileExists(atPath: skel.path) else {
      return "\(ref)/texlive-\(year)/store-root"
    }
    let root = cachesTree(year)
    makeTree(from: skel.path, at: root)
    return root
  }
  /// The directory of our texmf.cnf (read before TeX Live's), naming `storeRoot` as TEXMFROOT.
  static func cnfDir(_ year: String) -> String { storeRoot(year) + "-cnf" }

  static func cachesTree(_ year: String) -> String {
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!.path
    return "\(caches)/taudot/texlive-\(year)"
  }

  /// Copies the skeleton's files that aren't there yet (a new app version's ls-R replaces an older one) and writes
  /// the cnf. Fetched files land beside them and stay.
  static func makeTree(from skel: String, at root: String) {
    let fm = FileManager.default
    for rel in ["texmf-dist/ls-R", "texmf-var/ls-R", "texmf-dist/web2c/texmf.cnf", "texmf-dist/web2c/cp227.tcx"] {
      let src = "\(skel)/\(rel)", dst = "\(root)/\(rel)"
      guard fm.fileExists(atPath: src) else { continue }
      let same = (try? fm.attributesOfItem(atPath: dst)[.size] as? Int) == (try? fm.attributesOfItem(atPath: src)[.size] as? Int)
        && fm.contentsEqual(atPath: src, andPath: dst)
      if same { continue }
      try? fm.createDirectory(atPath: (dst as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
      try? fm.removeItem(atPath: dst)
      try? fm.copyItem(atPath: src, toPath: dst)
    }
    let cnf = """
      % GPL-2.0-or-later. Read before TeX Live's own texmf.cnf: the TeX Live store's image as installed at ROOT.
      TEXMFROOT = \(root)
      TEXMFLOCAL = $TEXMFROOT/texmf-local
      TEXMFHOME = $TEXMFROOT/texmf-home
      TEXMFVAR = $TEXMFROOT/texmf-var
      TEXMFCONFIG = $TEXMFROOT/texmf-config
      TEXMFSYSVAR = $TEXMFROOT/texmf-var
      TEXMFSYSCONFIG = $TEXMFROOT/texmf-config

      """
    let path = root + "-cnf/texmf.cnf"
    if (try? String(contentsOfFile: path, encoding: .utf8)) != cnf {
      try? fm.createDirectory(atPath: root + "-cnf", withIntermediateDirectories: true)
      try? cnf.write(toFile: path, atomically: true, encoding: .utf8)
    }
  }

  /// Everything needed to run this year: the reason it can't, or nil.
  public static func missing(_ year: String) -> String? {
    let fm = FileManager.default
    guard images[year] != nil else { return "no TeX Live \(year) image" }
    if !fm.isExecutableFile(atPath: engine(year)) { return "no pdfTeX for TeX Live \(year) (\(engine(year)))" }
    if !fm.fileExists(atPath: storeRoot(year) + "/texmf-dist/ls-R") { return "no TeX Live \(year) tree (\(storeRoot(year)))" }
    return nil
  }

  /// The driver's environment for `year`.
  public static func environment(_ year: String, base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
    var e = TxpPaths.environment(base)
    let root = storeRoot(year)
    e["TEXMFCNF"] = "\(cnfDir(year)):\(root)/texmf-dist/web2c"
    e["TEXSTORE_URL"] = base["TEXSTORE_URL"] ?? storeURL
    e["TEXSTORE_IMAGE"] = images[year]
    e["TEXSTORE_ROOT"] = root
    e["TEXFORMATS"] = ".:" + formats(year, env: base)
    for k in ["TAUDOT_LIVE_FD", "KPATHSEA_DEBUG", "TEXINPUTS"] { e[k] = nil }
    return e
  }
}

// ---- a finished PDF ------------------------------------------------------------------------------------------------

/// One PDF the driver finished, read into memory (the driver removes its file later). Drawn from any thread.
final class LivePDF: @unchecked Sendable {
  let data: Data
  let doc: CGPDFDocument
  let sizes: [CGSize]
  /// Per page: what it draws (content streams and the XObjects they name), to tell a changed page from the same one.
  /// Made on first use (most pages of an edit's PDF are before `from_page` and never need one).
  private var digestCache: [Int: Data] = [:]
  let synctex: String?
  let log: String?
  let seq: Int, run: Int
  /// The document page of this PDF's first page: XeTeX's PDFs hold only the pages an event brought (XDV.toPDF).
  let first: Int
  /// One past the last document page it holds.
  var end: Int { first + sizes.count }
  private let lock = NSLock()
  private var figures: [Int: [CGRect]] = [:]
  private var kit: PDFDocument?

  init?(path: String, synctex: String?, log: String?, seq: Int, run: Int, first: Int = 0) {
    guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)), let provider = CGDataProvider(data: d as CFData),
      let doc = CGPDFDocument(provider)
    else { return nil }
    data = d
    self.doc = doc
    var sizes: [CGSize] = []
    for i in 0..<doc.numberOfPages {
      guard let p = doc.page(at: i + 1) else { sizes.append(.zero); continue }
      let b = p.getBoxRect(.cropBox)
      let r = p.rotationAngle % 180 != 0
      sizes.append(r ? CGSize(width: b.height, height: b.width) : b.size)
    }
    self.sizes = sizes
    self.synctex = synctex.flatMap(LivePDF.readSynctex)
    self.log = log.flatMap { try? String(contentsOf: URL(fileURLWithPath: $0), encoding: .isoLatin1) }
    (logEvents, firstError) = self.log.map(LivePDF.logEvents) ?? ([], nil)
    self.seq = seq
    self.run = run
    self.first = first
  }

  /// SyncTeX as text: `.synctex.gz` (pdfTeX's `-synctex=1`) or plain.
  static func readSynctex(_ path: String) -> String? {
    guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
    let raw = path.hasSuffix(".gz") ? Gzip.inflate(d) : d
    return raw.map { relativeInputs(String(decoding: $0, as: UTF8.self)) }
  }

  /// pdfTeX names its inputs `<working dir>/./main.tex`, the working dir being the driver's (or Overleaf's
  /// `/compile`): `Input:` lines become `./main.tex`, relative to the project, as TeXpresso's are.
  static func relativeInputs(_ s: String) -> String {
    guard let end = s.range(of: "\nContent:") else { return s }
    var head = s[..<end.lowerBound].split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    for i in head.indices where head[i].hasPrefix("Input:") {
      if let r = head[i].range(of: "/./") {
        let n = head[i].split(separator: ":", maxSplits: 2)
        if n.count == 3 { head[i] = "Input:\(n[1]):./" + head[i][r.upperBound...] }
      }
    }
    return head.joined(separator: "\n") + s[end.lowerBound...]
  }

  /// A page's content streams, its XObjects' streams (forms recursively, images by their dictionaries), its
  /// MediaBox: equal digests draw the same.
  static func digest(_ page: CGPDFPage) -> Data {
    var h = Hasher64()
    let b = page.getBoxRect(.mediaBox)
    h.add("\(b)")
    guard let dict = page.dictionary else { return h.data }
    var contents: CGPDFObjectRef?
    if CGPDFDictionaryGetObject(dict, "Contents", &contents), let contents {
      var s: CGPDFStreamRef?
      var a: CGPDFArrayRef?
      if CGPDFObjectGetValue(contents, .stream, &s), let s { h.add(stream: s) }
      else if CGPDFObjectGetValue(contents, .array, &a), let a {
        for i in 0..<CGPDFArrayGetCount(a) {
          var si: CGPDFStreamRef?
          if CGPDFArrayGetStream(a, i, &si), let si { h.add(stream: si) }
        }
      }
    }
    var res: CGPDFDictionaryRef?
    if CGPDFDictionaryGetDictionary(dict, "Resources", &res), let res { h.add(resources: res, depth: 0) }
    return h.data
  }

  var pageCount: Int { sizes.count }

  /// The log as TeXpresso's log events (the issues list's input), and its first error with TeX's `l.N` pointer.
  let logEvents: [String]
  let firstError: String?
  static func logEvents(_ log: String) -> ([String], String?) {
    let lines = log.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    var out = ["[\"truncate-lines\", \"log\", 0]"]
    if let d = try? JSONSerialization.data(withJSONObject: lines, options: [.withoutEscapingSlashes]), d.count > 2 {
      out.append("[\"append-lines\", \"log\", " + String(decoding: d.dropFirst(), as: UTF8.self))
    }
    var err: String?
    if let i = lines.firstIndex(where: { $0.hasPrefix("! ") }) {
      let pointer = lines[i...].prefix(12).first { $0.hasPrefix("l.") }.map { " " + $0.prefix(while: { $0 != " " }) } ?? ""
      err = lines[i] + pointer
    }
    return (out, err)
  }

  func digest(_ page: Int) -> Data {
    lock.lock()
    if let d = digestCache[page] { lock.unlock(); return d }
    lock.unlock()
    let d = doc.page(at: page + 1).map(LivePDF.digest) ?? Data()
    lock.lock()
    digestCache[page] = d
    lock.unlock()
    return d
  }

  /// The page's figures (raster images and form XObjects: included PDF/EPS figures), in PDF user space. The page
  /// style leaves them as they are.
  func figureRects(_ page: Int) -> [CGRect] {
    lock.lock()
    if let f = figures[page] { lock.unlock(); return f }
    lock.unlock()
    let f = doc.page(at: page + 1).map(FigureScan.rects) ?? []
    lock.lock()
    figures[page] = f
    lock.unlock()
    return f
  }

  /// PDFKit's view of the document (text and its positions), made once; PDFKit isn't thread safe, so callers hold
  /// `withKit`'s lock.
  func withKit<T>(_ f: (PDFDocument) -> T?) -> T? {
    lock.lock()
    defer { lock.unlock() }
    if kit == nil { kit = PDFDocument(data: data) }
    guard let kit else { return nil }
    return f(kit)
  }
}

/// A small 64-bit FNV-1a over everything a page draws.
struct Hasher64 {
  var v: UInt64 = 0xcbf2_9ce4_8422_2325
  mutating func add(_ bytes: UnsafeRawBufferPointer) {
    for b in bytes { v = (v ^ UInt64(b)) &* 0x100_0000_01b3 }
  }
  mutating func add(_ s: String) { var s = s; s.withUTF8 { add(UnsafeRawBufferPointer($0)) } }
  mutating func add(stream s: CGPDFStreamRef) {
    var fmt = CGPDFDataFormat.raw
    guard let d = CGPDFStreamCopyData(s, &fmt) else { return }
    (d as Data).withUnsafeBytes { add($0) }
  }
  /// XObjects by name: forms by their content (and their own resources), images by their dictionary's size fields
  /// (decoding a big image to hash it would cost more than drawing it).
  mutating func add(resources: CGPDFDictionaryRef, depth: Int) {
    var xo: CGPDFDictionaryRef?
    guard depth < 4, CGPDFDictionaryGetDictionary(resources, "XObject", &xo), let xo else { return }
    final class Names { var v: [String] = [] }
    let names = Names()
    CGPDFDictionaryApplyBlock(xo, { k, _, info in
      Unmanaged<Names>.fromOpaque(info!).takeUnretainedValue().v.append(String(cString: k))
      return true
    }, Unmanaged.passUnretained(names).toOpaque())
    for n in names.v.sorted() {
      var s: CGPDFStreamRef?
      guard CGPDFDictionaryGetStream(xo, n, &s), let s, let sd = CGPDFStreamGetDictionary(s) else { continue }
      add(n)
      var sub: UnsafePointer<CChar>?
      if CGPDFDictionaryGetName(sd, "Subtype", &sub), let sub, String(cString: sub) == "Form" {
        add(stream: s)
        var r: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(sd, "Resources", &r), let r { add(resources: r, depth: depth + 1) }
      } else {
        for k in ["Width", "Height", "Length", "BitsPerComponent"] {
          var i: CGPDFInteger = 0
          if CGPDFDictionaryGetInteger(sd, k, &i) { add("\(k)=\(i)") }
        }
        var fmt = CGPDFDataFormat.raw
        if let d = CGPDFStreamCopyData(s, &fmt) as Data?, d.count <= 1 << 16 { d.withUnsafeBytes { add($0) } }
      }
    }
  }
  var data: Data { withUnsafeBytes(of: v) { Data($0) } }
}

/// Raster images and form XObjects drawn on a page, with the transformation in force: their rects in user space.
enum FigureScan {
  final class State {
    var ctm = CGAffineTransform.identity
    var stack: [CGAffineTransform] = []
    var rects: [CGRect] = []
    var xobjects: CGPDFDictionaryRef?
  }

  static func rects(_ page: CGPDFPage) -> [CGRect] {
    let st = State()
    if let d = page.dictionary {
      var res: CGPDFDictionaryRef?
      if CGPDFDictionaryGetDictionary(d, "Resources", &res), let res {
        var xo: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(res, "XObject", &xo) { st.xobjects = xo }
      }
    }
    guard st.xobjects != nil, let table = CGPDFOperatorTableCreate() else { return [] }
    CGPDFOperatorTableSetCallback(table, "q") { _, info in
      let s = Unmanaged<State>.fromOpaque(info!).takeUnretainedValue()
      s.stack.append(s.ctm)
    }
    CGPDFOperatorTableSetCallback(table, "Q") { _, info in
      let s = Unmanaged<State>.fromOpaque(info!).takeUnretainedValue()
      if let t = s.stack.popLast() { s.ctm = t }
    }
    CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
      let s = Unmanaged<State>.fromOpaque(info!).takeUnretainedValue()
      var v = [CGPDFReal](repeating: 0, count: 6)
      for i in (0..<6).reversed() { guard CGPDFScannerPopNumber(scanner, &v[i]) else { return } }
      s.ctm = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]).concatenating(s.ctm)
    }
    CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
      let s = Unmanaged<State>.fromOpaque(info!).takeUnretainedValue()
      var name: UnsafePointer<CChar>?
      guard CGPDFScannerPopName(scanner, &name), let name, let xo = s.xobjects else { return }
      var stream: CGPDFStreamRef?
      guard CGPDFDictionaryGetStream(xo, name, &stream), let stream, let d = CGPDFStreamGetDictionary(stream) else { return }
      var sub: UnsafePointer<CChar>?
      guard CGPDFDictionaryGetName(d, "Subtype", &sub), let sub else { return }
      switch String(cString: sub) {
      case "Image":
        s.rects.append(CGRect(x: 0, y: 0, width: 1, height: 1).applying(s.ctm))
      case "Form":
        var bbox: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(d, "BBox", &bbox), let bbox, CGPDFArrayGetCount(bbox) == 4 else { return }
        var b = [CGPDFReal](repeating: 0, count: 4)
        for i in 0..<4 { _ = CGPDFArrayGetNumber(bbox, i, &b[i]) }
        var m = CGAffineTransform.identity
        var ma: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(d, "Matrix", &ma), let ma, CGPDFArrayGetCount(ma) == 6 {
          var v = [CGPDFReal](repeating: 0, count: 6)
          for i in 0..<6 { _ = CGPDFArrayGetNumber(ma, i, &v[i]) }
          m = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
        }
        let r = CGRect(x: min(b[0], b[2]), y: min(b[1], b[3]), width: abs(b[2] - b[0]), height: abs(b[3] - b[1]))
        s.rects.append(r.applying(m.concatenating(s.ctm)))
      default: break
      }
    }
    let content = CGPDFContentStreamCreateWithPage(page)
    let scanner = CGPDFScannerCreate(content, table, Unmanaged.passUnretained(st).toOpaque())
    CGPDFScannerScan(scanner)
    CGPDFScannerRelease(scanner)
    CGPDFContentStreamRelease(content)
    CGPDFOperatorTableRelease(table)
    return st.rects.filter { $0.width > 2 && $0.height > 2 }
  }
}

/// gzip → bytes, with the Compression framework's raw deflate (no zlib link).
enum Gzip {
  static func inflate(_ d: Data) -> Data? {
    let b = [UInt8](d)
    guard b.count > 18, b[0] == 0x1f, b[1] == 0x8b, b[2] == 8 else { return nil }
    let flg = b[3]
    var i = 10
    if flg & 4 != 0 { guard i + 2 <= b.count else { return nil }; i += 2 + Int(b[i]) | Int(b[i + 1]) << 8 }
    if flg & 8 != 0 { while i < b.count && b[i] != 0 { i += 1 }; i += 1 }
    if flg & 16 != 0 { while i < b.count && b[i] != 0 { i += 1 }; i += 1 }
    if flg & 2 != 0 { i += 2 }
    guard i < b.count - 8 else { return nil }
    let size = Int(b[b.count - 4]) | Int(b[b.count - 3]) << 8 | Int(b[b.count - 2]) << 16 | Int(b[b.count - 1]) << 24
    return Data(b[i..<(b.count - 8)]).inflated(expected: size)
  }
}

import Compression
extension Data {
  func inflated(expected: Int) -> Data? {
    var cap = Swift.max(expected, count * 4, 4096)
    // the gzip size field is mod 2^32; grow if it's short
    for _ in 0..<4 {
      var out = Data(count: cap)
      let n = out.withUnsafeMutableBytes { o in
        withUnsafeBytes { i in
          compression_decode_buffer(o.bindMemory(to: UInt8.self).baseAddress!, cap, i.bindMemory(to: UInt8.self).baseAddress!,
                                    count, nil, COMPRESSION_ZLIB)
        }
      }
      if n == 0 { return nil }
      if n < cap { return out.prefix(n) }
      cap *= 4
    }
    return nil
  }
}

// ---- drawing -------------------------------------------------------------------------------------------------------

enum LiveDraw {
  /// A w×h pixel rect at (x, y) of `page` at `scale` pixels a point (y down from the page's top), as TeXpresso's
  /// renders were: white paper, recoloured for the page style outside figures.
  static func render(_ pdf: LivePDF, page: Int, scale: Double, x: Int, y: Int, w: Int, h: Int, style: String) -> TileImage? {
    guard w > 0, h > 0, let p = pdf.doc.page(at: page + 1) else { return nil }
    let props: [IOSurfacePropertyKey: Any] = [
      .width: w, .height: h, .bytesPerElement: 4, .pixelFormat: 0x4247_5241,  // 'BGRA'
      .bytesPerRow: (w * 4 + 63) & ~63,
    ]
    guard let surf = IOSurface(properties: props) else { return nil }
    surf.lock(options: [], seed: nil)
    defer { surf.unlock(options: [], seed: nil) }
    guard let ctx = CGContext(data: surf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: surf.bytesPerRow,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return nil }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    let m = pageToPixels(p, scale: scale, x: x, y: y, h: h)
    ctx.concatenate(m)
    ctx.interpolationQuality = .high
    ctx.setShouldSubpixelPositionFonts(true)
    ctx.drawPDFPage(p)
    if style != "white" {
      let keep = pdf.figureRects(page).map { r -> CGRect in
        // device space y up → rows from the top
        let d = r.applying(m)
        return CGRect(x: d.minX, y: Double(h) - d.maxY, width: d.width, height: d.height).integral
      }
      restyle(surf, w: w, h: h, style: style, keep: keep)
    }
    return TileImage(surface: surf)
  }

  /// PDF user space → the rect's pixels (CG's y up, origin at the rect's bottom left).
  static func pageToPixels(_ p: CGPDFPage, scale: Double, x: Int, y: Int, h: Int) -> CGAffineTransform {
    let crop = p.getBoxRect(.cropBox)
    // the page as drawn, y up, rotation applied, at 1 pt a pixel, origin at its bottom left
    let t = p.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: rotated(crop.size, p.rotationAngle)), rotate: 0,
                                  preserveAspectRatio: true)
    let H = rotated(crop.size, p.rotationAngle).height
    // pixel (X, Y up) = (u·s − x, v·s − (H·s − h − y))
    return t.concatenating(CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: Double(-x), ty: Double(h + y) - H * scale))
  }

  static func rotated(_ s: CGSize, _ angle: Int32) -> CGSize { angle % 180 != 0 ? CGSize(width: s.height, height: s.width) : s }

  /// driver.c's page styles: sepia multiplies by the paper colour; dark inverts lightness keeping hue onto a dark
  /// page. `keep`: figure pixels left alone (rows from the top).
  static func restyle(_ surf: IOSurface, w: Int, h: Int, style: String, keep: [CGRect]) {
    let base = surf.baseAddress.assumingMemoryBound(to: UInt8.self)
    let stride = surf.bytesPerRow
    let dark = style == "dark"
    let bg: [Int] = [0x1d, 0x1f, 0x21], fg: [Int] = [0xd6, 0xd8, 0xda], sepia: [Int] = [0xf4, 0xec, 0xd8]  // r, g, b
    for yy in 0..<h {
      let row = base + yy * stride
      // the figure spans on this row
      let spans = keep.filter { Double(yy) >= $0.minY && Double(yy) < $0.maxY }.map { (max(0, Int($0.minX)), min(w, Int($0.maxX))) }
      var xx = 0
      while xx < w {
        if let s = spans.first(where: { xx >= $0.0 && xx < $0.1 }) { xx = s.1; continue }
        let p = row + xx * 4  // B G R X
        let b = Int(p[0]), g = Int(p[1]), r = Int(p[2])
        if dark {
          let mx = max(r, g, b), mn = min(r, g, b), d = 255 - mx - mn
          let v = [r + d, g + d, b + d]
          p[2] = UInt8(bg[0] + (v[0] * (fg[0] - bg[0]) + 127) / 255)
          p[1] = UInt8(bg[1] + (v[1] * (fg[1] - bg[1]) + 127) / 255)
          p[0] = UInt8(bg[2] + (v[2] * (fg[2] - bg[2]) + 127) / 255)
        } else {
          p[2] = UInt8((r * sepia[0] + 127) / 255)
          p[1] = UInt8((g * sepia[1] + 127) / 255)
          p[0] = UInt8((b * sepia[2] + 127) / 255)
        }
        xx += 1
      }
    }
  }

  /// The page's glyphs from PDFKit's text: every character with its box (points, y down from the page's top), typeset
  /// lines as PDFKit's `selectionsByLine` finds them, words split at the spaces PDFKit puts in its text. As
  /// TeXpresso's txp-render `glyphs` gave them, from the finished PDF.
  static func glyphs(_ pdf: LivePDF, page: Int) -> PageGlyphs? {
    pdf.withKit { kit -> PageGlyphs? in
      guard let p = kit.page(at: page), let text = p.string else { return nil }
      let crop = p.bounds(for: .cropBox)
      let ns = text as NSString
      // each character's typeset line
      var lineOf = [Int](repeating: -1, count: ns.length)
      for (k, sel) in (p.selection(for: p.bounds(for: .mediaBox))?.selectionsByLine() ?? []).enumerated() {
        for r in 0..<sel.numberOfTextRanges(on: p) {
          let rg = sel.range(at: r, on: p)
          guard rg.location != NSNotFound else { continue }
          for c in rg.location..<min(rg.location + rg.length, ns.length) where lineOf[c] < 0 { lineOf[c] = k }
        }
      }
      var out: [PageGlyphs.Glyph] = []
      var word = 0, lastLine = -2
      var gap = true
      var i = 0
      while i < ns.length {
        let r = ns.rangeOfComposedCharacterSequence(at: i)
        let ch = ns.substring(with: r)
        i = r.location + r.length
        if ch.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) {
          gap = true
          continue
        }
        // a selection's bounds, not characterBounds(at:): that one drifts from the text's indexing on some pages
        // (ligatures, citations), giving letters the boxes of others
        let b = p.selection(for: r)?.bounds(for: p) ?? .zero
        guard b.width > 0 || b.height > 0 else { continue }
        let line = lineOf[r.location] >= 0 ? lineOf[r.location] : max(lastLine, 0)
        if gap || line != lastLine { word += 1 }
        gap = false
        lastLine = line
        let x0 = b.minX - crop.minX, x1 = b.maxX - crop.minX
        let y0 = crop.maxY - b.maxY, y1 = crop.maxY - b.minY
        let hgt = max(y1 - y0, 1)
        out.append(PageGlyphs.Glyph(t: ch, b: [x0, y0, x1, y1], o: [x0, y1 - 0.22 * hgt], s: hgt / 0.95, l: line, w: word))
      }
      // one baseline a line: the most common one among its glyphs (a superscript or an accent doesn't move it)
      var bases: [Int: [Double: Int]] = [:]
      for g in out { bases[g.l, default: [:]][(g.o[1] * 4).rounded() / 4, default: 0] += 1 }
      let base = bases.mapValues { $0.max { $0.value < $1.value }!.key }
      for k in out.indices { out[k].o[1] = base[out[k].l] ?? out[k].o[1] }
      // PageGlyphs groups lines by consecutive glyphs: keep them in reading order by line
      out.sort { ($0.l, $0.b[0]) < ($1.l, $1.b[0]) }
      return PageGlyphs(page: page, w: crop.width, h: crop.height, glyphs: out)
    } ?? nil
  }
}

// ---- the driver ----------------------------------------------------------------------------------------------------

/// PDFs a swap stops showing, freed on a background queue: the last release of a `LivePDF` (its CGPDFDocument, its
/// bytes, its PDFKit copy) took milliseconds on the main thread, in the turn that swapped the page (pdfpipe, step 3).
final class Trash: @unchecked Sendable {
  private var items: [AnyObject]
  init(_ items: [AnyObject]) { self.items = items }
  /// Drops them on `q`: whatever is still shown keeps its own reference, the rest is freed there.
  func empty(on q: DispatchQueue) { q.async { self.items = [] } }
}

/// The live pdfTeX for one project: its driver kept alive (restarted with backoff when it exits), its PDFs turned into
/// TeXpresso-style page reports. Callbacks on the main actor.
@MainActor public final class LiveTex: Typesetter {
  public let main: URL
  public let year: String
  let out: URL
  /// Where `.aux`/`.bbl` are kept between sessions (the page cache folder), passed as `--state`.
  let state: URL?
  private var proc: Process?
  /// The driver that just exited: the lines it wrote before exiting still count until another one starts (P5).
  private var exitedProc: Process?
  private var stdinPipe: Pipe?
  private var restarts = 0
  /// Restarts since a driver last settled a compile: the restart delay's exponent, so it comes back down (P5).
  private var backoff = 0
  /// Every restart's delay, in order (tests).
  private(set) var restartDelays: [Double] = []
  private var stopped = false
  public var onPages: ((PagesEvent) -> Void)?
  public var onError: ((String) -> Void)?
  public var onLine: ((String) -> Void)?
  public var onNote: ((String) -> Void)?
  public var onRestart: (() -> Void)?
  public var pageStyle = "white"
  public var restartCount: Int { restarts }
  public private(set) var sent = 0
  public var hasGlyphs: Bool { true }
  public private(set) var engineName = "pdfTeX"
  /// The goal page, kept for a restarted driver.
  public private(set) var goalPage: Int?
  /// The driver said `hello`.
  public private(set) var ready = false

  /// Each shown page: the PDF it's drawn from and its index there. A PDF of the first k pages replaces the first k.
  private(set) var pages: [(pdf: LivePDF, index: Int)] = []
  /// The newest final PDF (SyncTeX, the issues list).
  private(set) var final: LivePDF?
  private var gen = 0
  private let loadQ = DispatchQueue(label: "taudot.livetex.load", qos: .userInitiated)
  private var fetchNote = CFAbsoluteTime(0)
  /// This driver sent a BibTeX log (its own run's or the kept one).
  private var bibSent = false
  /// The .blg --state keeps: MAIN.blg in STATE.
  private nonisolated var keptBlg: URL? {
    state.map { $0.appendingPathComponent(main.deletingPathExtension().lastPathComponent + ".blg") }
  }
  /// $TAUDOT_TXP_LOG: the driver's stdout/stderr and every command, as for TeXpresso.
  private var debugLog: FileHandle? { TxpProcess.debugLog }

  /// The environment the driver is set up from (the process's by default): tests pass theirs here rather than
  /// through `setenv`, which every test running in parallel would see.
  let env: [String: String]

  /// Universal's engine (tau-live, stock engines, docs/universal.md); nil: the patched pdfTeX (`pdftex-live`).
  public let universal: TexEngine?
  /// What the status line calls it.
  nonisolated var label: String { universal.map { "\($0.title) (universal)" } ?? "pdfTeX" }
  /// Pages the shown list has, read when converting XeTeX's pages off the main actor.
  private nonisolated let shownCount = LockedInt()
  /// XeTeX on universal: xdvipdfmx and its environment.
  private nonisolated let xdv: (tool: String, env: [String: String])?
  /// The last XDV → PDF conversion's time (ms; tests and the latency notes).
  nonisolated let xdvMs = LockedInt()

  public init(main: URL, year: String, state: URL? = nil, env: [String: String] = ProcessInfo.processInfo.environment,
              universal: TexEngine? = nil) {
    self.main = main
    self.env = env
    self.year = universal == nil ? year : UniversalPaths.year
    self.state = state
    self.universal = universal
    if let universal { engineName = universal.title }
    xdv = universal?.writesXDV == true ? UniversalPaths.xdvipdfmx(env).map { ($0, UniversalPaths.environment(base: env)) } : nil
    out = FileManager.default.temporaryDirectory.appendingPathComponent("taudot-live-\(getpid())-\(UUID().uuidString.prefix(6))")
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
  }

  public func start() {
    guard !stopped else { return }
    ready = false
    bibSent = false
    let p = Process()
    let cmd: [String]
    var args: [String]
    if let universal {
      cmd = [UniversalPaths.driver(env)]
      args = ["--serve", "--engine", UniversalPaths.engine(universal, env: env)]
      if let b = UniversalPaths.bibtex(env) { args += ["--bibtex", b] }
    } else {
      cmd = LiveTexPaths.driver(year, env: env)
      args = Array(cmd.dropFirst()) + ["--serve", "--engine", LiveTexPaths.engine(year, env: env)]
      if let b = LiveTexPaths.bibtex(year) { args += ["--bibtex", b] }
    }
    p.executableURL = URL(fileURLWithPath: cmd[0])
    if let state, universal != nil || !LiveTexPaths.isFake(year, env: env) {
      try? FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
      args += ["--state", state.path]
    }
    args += [main.deletingLastPathComponent().path, main.lastPathComponent, out.appendingPathComponent("run\(restarts)").path]
    p.arguments = args
    p.environment = universal == nil ? LiveTexPaths.environment(year, base: env) : UniversalPaths.environment(base: env)
    p.currentDirectoryURL = out
    let i = Pipe(), o = Pipe(), e = Pipe()
    TxpProcess.ignoreSigpipe
    _ = fcntl(i.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    p.standardInput = i
    p.standardOutput = o
    p.standardError = e
    let outBuf = LineBuffer(), errBuf = LineBuffer()
    let log = debugLog
    o.fileHandleForReading.readabilityHandler = { [weak self, weak p] h in
      let d = h.availableData
      if d.isEmpty { h.readabilityHandler = nil; return }
      log?.write(d)
      let lines = outBuf.take(d)
      guard !lines.isEmpty, let p else { return }
      self?.received(lines, from: p)
    }
    e.fileHandleForReading.readabilityHandler = { [weak self] h in
      let d = h.availableData
      if d.isEmpty { h.readabilityHandler = nil; return }
      log?.write(d)
      let lines = errBuf.take(d).map { String(decoding: $0, as: UTF8.self) }
      guard !lines.isEmpty else { return }
      DispatchQueue.main.async { MainActor.assumeIsolated { for l in lines { self?.onNote?("\(self?.label ?? "pdfTeX"): \(l)") } } }
    }
    p.terminationHandler = { [weak self, weak p] q in
      let code = q.terminationStatus
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          guard let self, let p, self.proc === p else { return }
          self.exitedProc = p
          self.exited(code)
        }
      }
    }
    do { try p.run() } catch {
      onNote?("\(label): can't start \(cmd[0]): \(error)")
      exited(-1)  // tried again with backoff, as when it exits (P5)
      return
    }
    exitedProc = nil
    proc = p
    stdinPipe = i
    sent = 0
    if let goalPage { send(["goal", goalPage]) }
  }

  private func exited(_ code: Int32) {
    proc = nil
    stdinPipe = nil
    guard !stopped else { return }
    restarts += 1
    backoff += 1
    onNote?(code < 0 ? "\(label): restarting" : "\(label): driver exited (\(code)), restarting")
    let delay = min(0.5 * pow(2, Double(min(backoff - 1, 4))), 8)
    restartDelays.append(delay)
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.proc == nil, !self.stopped else { return }
        self.start()
        self.onRestart?()
      }
    }
  }

  public func stop() {
    stopped = true
    if let p = proc, p.isRunning {
      try? stdinPipe?.fileHandleForWriting.close()  // the driver exits when its stdin closes
      let pid = p.processIdentifier
      DispatchQueue.global().asyncAfter(deadline: .now() + 1) { if p.isRunning { kill(pid, SIGTERM) } }
    }
    proc = nil
    let out = self.out
    DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { try? FileManager.default.removeItem(at: out) }
  }

  public func killForTest() { proc?.terminate() }

  private func send(_ a: [Any]) {
    guard let w = stdinPipe?.fileHandleForWriting,
      var d = try? JSONSerialization.data(withJSONObject: a, options: [.withoutEscapingSlashes])
    else { return }
    d.append(0x0A)
    debugLog?.write(Data(String(format: "%.3f > ", CFAbsoluteTimeGetCurrent()).utf8) + d)
    try? w.write(contentsOf: d)
  }

  public func open(_ path: String, _ text: String) { sent += 1; send(["open", path, text]) }
  public func change(_ path: String, _ pos: Int, _ del: Int, _ ins: String) { sent += 1; send(["change", path, pos, del, ins]) }
  public func rescan() { send(["rescan"]) }
  public func finish() { send(["finish"]) }
  public func goal(_ page: Int) {
    if page == goalPage { return }
    goalPage = page
    send(["goal", page])
  }

  // ---- events

  /// Lines from the driver's stdout, in order: PDFs are read on `loadQ`, then handled on the main actor, in order.
  private nonisolated func received(_ lines: [Data], from p: Process) {
    for l in lines {
      guard let m = try? JSONSerialization.jsonObject(with: l) as? [String: Any], let ev = m["ev"] as? String else { continue }
      if ev == "para" {  // the paragraph preview: read on its own queue, not behind the PDFs being loaded
        ParaLayer.queue.async { [weak self] in
          let o = ParaOverlay(event: m).map(UncheckedBox.init)
          DispatchQueue.main.async {
            MainActor.assumeIsolated {
              guard let self, self.proc === p, let o else { return }
              self.onPara?(o.v)
            }
          }
        }
        continue
      }
      let box = JSONObject(m)
      let kept = ev == "done" && m["blg"] == nil ? keptBlg : nil
      loadQ.async { [weak self] in
        var pdf: LivePDF?
        if ev == "pdf", var path = m["path"] as? String {
          var first = 0
          let n = m["pages"] as? Int ?? 0
          if path.hasSuffix(".xdv"), let self {
            // XeTeX: only the pages this event brought (from `from_page`, never past what is shown: no gap)
            first = max(0, min(m["from_page"] as? Int ?? 0, self.shownCount.value, n - 1))
            let t0 = CFAbsoluteTimeGetCurrent()
            guard let tool = self.xdv?.tool,
              let made = XDV.toPDF(path, first: first, last: n - 1, out: self.out.appendingPathComponent("xdv-\(UUID().uuidString.prefix(8)).pdf").path,
                                   tool: tool, env: self.xdv?.env ?? [:], cwd: self.main.deletingLastPathComponent())
            else {
              DispatchQueue.main.async { MainActor.assumeIsolated { self.onNote?("\(self.label): xdvipdfmx failed on \(path)") } }
              return
            }
            self.xdvMs.set(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))
            path = made
          }
          pdf = LivePDF(path: path, synctex: m["synctex"] as? String, log: m["log"] as? String,
                        seq: m["seq"] as? Int ?? 0, run: m["run"] as? Int ?? 0, first: first)
          if path != m["path"] as? String { try? FileManager.default.removeItem(atPath: path) }  // read into memory
          if let pdf { for i in max(0, min((m["from_page"] as? Int ?? 0) - first, pdf.pageCount))..<pdf.pageCount { _ = pdf.digest(i) } }
        }
        var blg: String?
        if let b = m["blg"] as? String { blg = try? String(contentsOf: URL(fileURLWithPath: b), encoding: .isoLatin1) }
        // a reopened project: the driver took the .bbl and .blg from --state and BibTeX didn't run, so `done` names
        // no .blg; the kept one (only a driver's exit rewrites it) is this session's BibTeX log until BibTeX runs
        else if let kept { blg = try? String(contentsOf: kept, encoding: .isoLatin1) }
        // `done`'s log: the last run's, also when it wrote no PDF (P1)
        var log: String?
        if ev == "done", let l = m["log"] as? String { log = try? String(contentsOf: URL(fileURLWithPath: l), encoding: .isoLatin1) }
        let loaded = UncheckedBox((pdf, blg, log))
        DispatchQueue.main.async {
          MainActor.assumeIsolated {
            guard let self, self.proc === p || (self.proc == nil && self.exitedProc === p) else { return }
            Latency.shared.section("pdf event") { self.handle(box.v, pdf: loaded.v.0, blg: loaded.v.1, log: loaded.v.2) }
          }
        }
      }
    }
  }

  /// A paragraph preview (docs/live-protocol.md, `para`): the edited paragraph's new lines, to paint over its page.
  public var onPara: ((ParaOverlay) -> Void)?

  private func handle(_ m: [String: Any], pdf: LivePDF?, blg: String?, log: String? = nil) {
    switch m["ev"] as? String {
    case "hello":
      ready = true
      if let e = m["engine"] as? String { engineName = e }
    case "fetch":
      let now = CFAbsoluteTimeGetCurrent()
      if now - fetchNote > 0.1 {
        fetchNote = now
        let n = m["files"] as? Int ?? 0, mb = Double((m["bytes"] as? NSNumber)?.int64Value ?? 0) / 1e6
        onNote?(String(format: "TeX Live %@: fetching %@ (%d files, %.1f MB)", year, (m["file"] as? String ?? "").components(separatedBy: "/").last ?? "", n, mb))
      }
    case "run":
      Latency.shared.record(.typesetRun, key: Latency.shared.lastKey, value: Int64(m["applied"] as? Int ?? -1))
    case "pdf":
      Latency.shared.record(.pdfReady, key: Latency.shared.lastKey, value: Int64(m["applied"] as? Int ?? -1))
      guard let pdf else {
        onNote?("\(label): can't read \(m["path"] as? String ?? "?")")
        return
      }
      shown(pdf, final: m["final"] as? Bool ?? false, m)
    case "bibtex", "done":
      // the kept .blg only stands in until this driver has sent one
      if let blg, m["blg"] != nil || !bibSent, let d = try? JSONSerialization.data(withJSONObject: ["bib-log", blg]) {
        bibSent = true
        onLine?(String(decoding: d, as: UTF8.self))
      }
      if m["ev"] as? String == "done" {
        backoff = 0  // a driver that settles a compile is healthy
        settled(m, log: log)
      }
    case "error":
      let what = m["what"] as? String ?? "error"
      let msg = m["message"] as? String ?? ""
      onNote?(what == "offline" ? "offline: \(msg)" : "\(label): \(msg)")
    default: break
    }
  }

  /// A finished PDF: its pages replace the shown ones they cover; the changed ones are reported.
  private func shown(_ pdf: LivePDF, final isFinal: Bool, _ m: [String: Any]) {
    gen += 1
    var changed: [Int] = []
    let fromPage = m["from_page"] as? Int ?? 0
    var next = pages
    for k in 0..<pdf.pageCount {
      let i = pdf.first + k  // the document's page (XeTeX's PDFs start at their event's `from_page`)
      if i < next.count {
        let old = next[i]
        // before `from_page` the page was shipped before the snapshot the run resumed from: the same page
        if i >= fromPage, old.pdf.digest(old.index) != pdf.digest(k) || old.pdf.sizes[old.index] != pdf.sizes[k] { changed.append(i) }
        next[i] = (pdf, k)
      } else {
        changed.append(i)
        next.append((pdf, k))
      }
    }
    shownCount.set(next.count)
    let trash = Trash(pages.map(\.pdf) + (isFinal ? [final].compactMap { $0 } : []))
    pages = next
    if isFinal { final = pdf }
    trash.empty(on: loadQ)
    // "done" only once the compile settles (`done`): a run's end may be followed by latexmk's reruns, which move
    // pages; SyncTeX, comment anchors and the issues list wait for the settled document
    let ev: [String: Any] = [
      "ev": "pages", "gen": gen, "n": pdf.end, "typeset": pdf.end, "done": false,
      "sizes": pages.map { [Double($0.pdf.sizes[$0.index].width), Double($0.pdf.sizes[$0.index].height)] },
      "changed": changed, "edit_us": m["edit_us"] as? Int ?? -1, "applied": m["applied"] as? Int ?? -1,
    ]
    lastEditUs = m["edit_us"] as? Int ?? -1
    lastApplied = m["applied"] as? Int ?? -1
    if let e = PagesEvent(ev) { onPages?(e) }
  }
  private var lastEditUs = -1, lastApplied = -1

  /// The compile settled: pages past the last run's end go, the log goes to the issues list, and the pane hears
  /// "done" (SyncTeX, comments, the page cache). When the last run wrote no PDF (a fatal error before its first page:
  /// `done` has a `log` and no `path`), the pages shown stay (none on a first run) and its log is shown (P1).
  private func settled(_ m: [String: Any], log: String?) {
    let madePDF = m["path"] != nil
    if madePDF, let pdf = final, pages.count > pdf.end {
      let trash = Trash(pages.map(\.pdf))
      pages.removeLast(pages.count - pdf.end)
      shownCount.set(pages.count)
      trash.empty(on: loadQ)
    }
    if let log {
      let (events, err) = LivePDF.logEvents(log)
      for l in events { onLine?(l) }
      if let err { onError?(err) }
    } else if madePDF, let pdf = final {
      sendLog(pdf)
    } else if final == nil {
      return  // an older driver: no log, no PDF to settle on
    }
    gen += 1
    let ev: [String: Any] = [
      "ev": "pages", "gen": gen, "n": pages.count, "typeset": pages.count, "done": true,
      "sizes"
: pages.map { [Double($0.pdf.sizes[$0.index].width), Double($0.pdf.sizes[$0.index].height)] },
      "changed": [Int](), "edit_us": lastEditUs, "applied": m["applied"] as? Int ?? lastApplied,
    ]
    if let e = PagesEvent(ev) { onPages?(e) }
  }

  /// The run's log, as TeXpresso's log events (the issues list's input), and its first error for the status line.
  private func sendLog(_ pdf: LivePDF) {
    for l in pdf.logEvents { onLine?(l) }
    if let e = pdf.firstError { onError?(e) }
  }

  // ---- what the pane asks for

  public func synctex() async -> String? { final?.synctex ?? pages.last?.pdf.synctex }

  public func glyphs(page: Int) async -> PageGlyphs? {
    guard page >= 0, page < pages.count else { return nil }
    let (pdf, i) = pages[page]
    let g = await Task.detached(priority: .userInitiated) { LiveDraw.glyphs(pdf, page: i).map(UncheckedBox.init) }.value?.v
    guard var g else { return nil }
    g.page = page
    return g
  }

  public func render(page: Int, scale: Double, x: Int, y: Int, w: Int, h: Int) async -> TileImage? {
    guard page >= 0, page < pages.count else { return nil }
    let (pdf, i) = pages[page]
    let style = pageStyle
    return await Task.detached(priority: .userInitiated) {
      LiveDraw.render(pdf, page: i, scale: scale, x: x, y: y, w: w, h: h, style: style).map(UncheckedBox.init)
    }.value?.v
  }

  /// The PDF bytes of the newest final PDF (for tests and the "ours equals Overleaf's" checks).
  public var finalPDF: Data? { final?.data }
  /// The shown pages' text (PDFKit), for tests.
  public func pageText(_ page: Int) -> String? {
    guard page >= 0, page < pages.count else { return nil }
    let (pdf, i) = pages[page]
    return pdf.withKit { $0.page(at: i)?.string } ?? nil
  }
}

struct UncheckedBox<T>: @unchecked Sendable {
  let v: T
  init(_ v: T) { self.v = v }
}
