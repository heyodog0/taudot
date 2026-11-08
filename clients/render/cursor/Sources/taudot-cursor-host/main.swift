// taudot-cursor-host DIR/main.tex SHOTS_DIR [SCRIPT]
//
// A small off-screen host for the cursor: typesets a copy of a paper with txp-render, follows a scripted list of
// source positions, draws the cursor (a coral caret with the logo's dot at its foot) on tiles from txp-render's
// "render" verb, writes them as PNGs (SHOTS_DIR/cursor-NN.png) and measures source → dot time.
//
// SCRIPT: one position a line, `LINE:COL` (UTF-8 bytes) or `LINE:/text/[+K]` (K bytes into the first match of
// text), an optional label after a space. `#` starts a comment.
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import TaudotCursor
import UniformTypeIdentifiers
import Vision

let args = CommandLine.arguments
guard args.count >= 3 else {
  print("usage: taudot-cursor-host DIR/main.tex SHOTS_DIR [SCRIPT]")
  exit(2)
}
let texURL = URL(fileURLWithPath: args[1])
let shots = URL(fileURLWithPath: args[2])
try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
let work = FileManager.default.temporaryDirectory.appendingPathComponent("taudot-cursor-\(getpid())")
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }

// ---- txp-render ------------------------------------------------------------------------------------------------------

/// txp-render's protocol: JSON arrays in, JSON objects out, one a line.
final class Txp {
  let proc = Process()
  let inPipe = Pipe(), outPipe = Pipe()
  var buffer = Data()
  var nextID = 1
  var pages: [String: Any] = [:]

  init(binary: URL, tex: URL) throws {
    proc.executableURL = binary
    proc.arguments = [tex.path]
    proc.standardInput = inPipe
    proc.standardOutput = outPipe
    proc.standardError = FileHandle.nullDevice
    try proc.run()
  }

  func send(_ cmd: [Any]) {
    let d = try! JSONSerialization.data(withJSONObject: cmd)
    inPipe.fileHandleForWriting.write(d + Data("\n".utf8))
  }

  /// The next event, or nil after `timeout` seconds without one.
  func read(timeout: Double) -> [String: Any]? {
    let fd = outPipe.fileHandleForReading.fileDescriptor
    let end = Date().addingTimeInterval(timeout)
    while true {
      if let nl = buffer.firstIndex(of: 10) {
        let line = buffer[buffer.startIndex..<nl]
        buffer.removeSubrange(buffer.startIndex...nl)
        if let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { return o }
        continue
      }
      let left = end.timeIntervalSinceNow
      if left <= 0 { return nil }
      var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
      if poll(&p, 1, Int32(left * 1000)) <= 0 { continue }
      var chunk = [UInt8](repeating: 0, count: 65536)
      let n = Darwin.read(fd, &chunk, chunk.count)
      if n <= 0 { return nil }
      buffer.append(contentsOf: chunk[0..<n])
    }
  }

  /// Wait for the finished document, then for `quiet` s without reports (aux reruns).
  func settle(quiet: Double = 4) -> [String: Any] {
    var done = false
    while true {
      guard let ev = read(timeout: done ? quiet : 300) else {
        if done { return pages }
        fatalError("txp-render: no document")
      }
      if ev["ev"] as? String == "pages" { pages = ev; done = ev["done"] as? Bool ?? false }
    }
  }

  func call(_ verb: String, _ rest: [Any]) -> [String: Any] {
    let id = nextID
    nextID += 1
    send([verb, id] + rest)
    while let ev = read(timeout: 120) {
      if (ev["id"] as? Int) == id { return ev }
      if ev["ev"] as? String == "pages" { pages = ev }
    }
    fatalError("txp-render: no answer to \(verb)")
  }

  func close() {
    try? inPipe.fileHandleForWriting.close()
    proc.waitUntilExit()
  }
}

let pkg = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
  .deletingLastPathComponent()  // clients/render/cursor
let binary = pkg.deletingLastPathComponent().appendingPathComponent("txp-render")
let t0 = Date()
let txp = try Txp(binary: binary, tex: texURL)
let pages = txp.settle()
let pageCount = pages["n"] as? Int ?? 0
let sizes = (pages["sizes"] as? [[Double]]) ?? []
print(String(format: "typeset %d pages in %.1f s", pageCount, Date().timeIntervalSince(t0)))

var t = Date()
let syncURL = work.appendingPathComponent("main.synctex")
_ = txp.call("synctex", [syncURL.path])
let synctex = SyncTeX(text: try String(contentsOf: syncURL, encoding: .utf8))
let syncMs = Date().timeIntervalSince(t) * 1000
print(String(format: "synctex: written and read in %.0f ms", syncMs))

var glyphMs: [Double] = []
let map = CursorMap(synctex: synctex) { p in
  let t = Date()
  let u = work.appendingPathComponent("glyphs-\(p).json")
  guard txp.call("glyphs", [p, u.path])["ok"] as? Bool == true else { return nil }
  let g = try? PageGlyphs.load(u)
  glyphMs.append(Date().timeIntervalSince(t) * 1000)
  return g
}

// ---- --words PAGES: the page's words from glyphs against Vision's OCR of a render -------------------------------------
if let k = args.firstIndex(of: "--words"), k + 1 < args.count {
  let list = args[k + 1].split(separator: ",").compactMap { Int($0) }
  compareWords(list)
  txp.close()
  exit(0)
}

// ---- the script ------------------------------------------------------------------------------------------------------

let source = try String(contentsOf: texURL, encoding: .utf8).components(separatedBy: "\n")
let defaultScript = """
  # mid-word in body text, then along the word
  213:/substantially/+3 body text
  213:/substantially/+4
  213:/substantially/+5
  # a ligature: the cursor on the i of "fi"
  192:/file---/+1 ligature
  # a line's end, and a space
  213:/training./+9 end of line
  213:/ we aim/ space
  # maths, a command, a comment-only line (no dot)
  396:/times/ maths
  368:/citep/+2 command
  """
let scriptText = args.count > 3 && !args[3].hasPrefix("--") ? try String(contentsOfFile: args[3], encoding: .utf8) : defaultScript

struct Step { var line: Int; var col: Int; var label: String }
var steps: [Step] = []
for raw in scriptText.components(separatedBy: "\n") {
  let l = raw.trimmingCharacters(in: .whitespaces)
  if l.isEmpty || l.hasPrefix("#") { continue }
  guard let colon = l.firstIndex(of: ":"), let line = Int(l[..<colon]), line >= 1, line <= source.count else {
    print("bad script line: \(l)"); continue
  }
  var rest = l[l.index(after: colon)...]
  var col = 0
  if rest.hasPrefix("/"), let close = rest.dropFirst().firstIndex(of: "/") {
    let needle = String(rest[rest.index(after: rest.startIndex)..<close])
    rest = rest[rest.index(after: close)...]
    guard let r = source[line - 1].range(of: needle) else { print("not found on line \(line): \(needle)"); continue }
    col = source[line - 1].utf8.distance(from: source[line - 1].utf8.startIndex, to: r.lowerBound.samePosition(in: source[line - 1].utf8)!)
    if rest.hasPrefix("+"), let k = Int(rest.dropFirst().prefix { $0.isNumber }) {
      col += k
      rest = rest.dropFirst(1 + String(k).count)
    }
  } else {
    let digits = rest.prefix { $0.isNumber }
    col = Int(digits) ?? 0
    rest = rest.dropFirst(digits.count)
  }
  steps.append(Step(line: line, col: col, label: rest.trimmingCharacters(in: .whitespaces)))
}

// ---- drawing ---------------------------------------------------------------------------------------------------------

let scale = 4.0  // pixels per point: a retina tile at 200 %
let coral = CGColor(srgbRed: 1.0, green: 0.369, blue: 0.302, alpha: 1)

/// The cursor: a caret from the x-height's top to the baseline, the logo's dot at its foot. Approximate positions
/// get a hollow dot.
func drawCursor(_ g: CGContext, _ c: Caret, toPixels: (Double, Double) -> CGPoint) {
  let em = max(c.bottom - c.top, 6) / 1.2  // the box is ascender to descender: ~1.2 em
  let foot = toPixels(c.x, c.baseline)
  let head = toPixels(c.x, c.baseline - 0.72 * em)
  let px = scale
  g.setStrokeColor(coral)
  g.setLineWidth(0.9 * px)
  g.setLineCap(.round)
  g.move(to: head)
  g.addLine(to: CGPoint(x: foot.x, y: foot.y))
  g.strokePath()
  let r = 0.17 * em * px
  let dot = CGRect(x: foot.x - r, y: foot.y + 0.25 * r, width: 2 * r, height: 2 * r)
  if c.approximate {
    g.setLineWidth(0.6 * px)
    g.strokeEllipse(in: dot.insetBy(dx: 0.3 * px, dy: 0.3 * px))
    return
  }
  // the logo's dot: a warm radial gradient and a small highlight
  let space = CGColorSpace(name: CGColorSpace.sRGB)!
  let grad = CGGradient(colorsSpace: space, colors: [
    CGColor(srgbRed: 1, green: 0.643, blue: 0.541, alpha: 1), coral, CGColor(srgbRed: 0.886, green: 0.235, blue: 0.188, alpha: 1),
  ] as CFArray, locations: [0, 0.55, 1])!
  g.saveGState()
  g.addEllipse(in: dot)
  g.clip()
  // y is down in our pixel frame (flipped context), so the light comes from the top-left
  g.drawRadialGradient(grad, startCenter: CGPoint(x: dot.minX + 0.36 * dot.width, y: dot.minY + 0.3 * dot.height),
                       startRadius: 0, endCenter: CGPoint(x: dot.midX, y: dot.midY), endRadius: 0.8 * dot.width,
                       options: [.drawsAfterEndLocation])
  g.restoreGState()
}

func writePNG(_ img: CGImage, _ url: URL) {
  let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(d, img, nil)
  CGImageDestinationFinalize(d)
}

/// A tile of `page` around the caret, rendered by txp-render, with the cursor drawn on it.
func shot(_ c: Caret, _ i: Int, _ label: String) -> (tileMs: Double, drawMs: Double) {
  let w = 260.0, h = 70.0  // points
  let size = c.page < sizes.count ? sizes[c.page] : [612, 792]
  let x0 = max(0, min(size[0] - w, c.x - w / 2)), y0 = max(0, min(size[1] - h, c.baseline - h / 2))
  let pw = Int(w * scale), ph = Int(h * scale), px0 = Int(x0 * scale), py0 = Int(y0 * scale)
  let rgb = work.appendingPathComponent("tile.rgb")
  var t = Date()
  _ = txp.call("render", [c.page, scale, px0, py0, pw, ph, rgb.path, ""])
  let tileMs = Date().timeIntervalSince(t) * 1000
  t = Date()
  let data = try! Data(contentsOf: rgb)
  let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: pw * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
  // RGB → RGBX
  let dst = ctx.data!.assumingMemoryBound(to: UInt8.self)
  data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
    for k in 0..<(pw * ph) { dst[4 * k] = src[3 * k]; dst[4 * k + 1] = src[3 * k + 1]; dst[4 * k + 2] = src[3 * k + 2] }
  }
  // draw in a top-left pixel frame
  ctx.translateBy(x: 0, y: CGFloat(ph))
  ctx.scaleBy(x: 1, y: -1)
  drawCursor(ctx, c) { x, y in CGPoint(x: (x - x0) * scale, y: (y - y0) * scale) }
  let img = ctx.makeImage()!
  let drawMs = Date().timeIntervalSince(t) * 1000
  writePNG(img, shots.appendingPathComponent(String(format: "cursor-%02d.png", i)))
  return (tileMs, drawMs)
}

// ---- follow the script -----------------------------------------------------------------------------------------------

var caretMs: [Double] = [], tileMs: [Double] = [], drawMs: [Double] = []
for (i, s) in steps.enumerated() {
  let text = source[s.line - 1]
  let g0 = glyphMs.count
  let t = Date()
  let c = map.caret(file: texURL.lastPathComponent, line: s.line, text: text, column: s.col)
  let ms = Date().timeIntervalSince(t) * 1000
  let fetched = glyphMs.count > g0 ? String(format: " (incl. glyphs of the page %.1f ms)", glyphMs.last!) : ""
  let at = text.utf8.dropFirst(s.col).prefix(12)
  let snippet = String(decoding: at, as: UTF8.self)
  guard let c else {
    print(String(format: "%02d %d:%d «%@» %@: no dot (%.2f ms)", i, s.line, s.col, snippet, s.label, ms))
    continue
  }
  caretMs.append(ms)
  let glyph = map.page(c.page)!.glyphs[c.glyph].t
  let (tm, dm) = shot(c, i, s.label)
  tileMs.append(tm)
  drawMs.append(dm)
  print(String(format: "%02d %d:%d «%@» %@ → p%d '%@'%@%@ caret %.2f ms%@, tile %.1f ms, dot %.2f ms", i, s.line, s.col,
               snippet, s.label, c.page + 1, glyph, c.after ? " after" : "", c.approximate ? " ~" : "", ms, fetched, tm, dm))
}
func median(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.sorted()[a.count / 2] }
print(String(format: "source → dot: caret median %.2f ms (max %.2f), drawing the dot %.2f ms; a tile from txp-render %.1f ms",
             median(caretMs), caretMs.max() ?? 0, median(drawMs), median(tileMs)))

// ---- typing: the dot follows at once, and lands exactly once TeX has typeset the page --------------------------------
//
// Types `typed` into the paper copy's line 213 after "substantially ", one key every `gap` s, as the pane would feed
// txp-render. Each key: the caret on the pages already drawn (the new letter isn't typeset yet: the dot stays after
// the last letter found, marked approximate). Each "pages" event: new SyncTeX, glyphs of the changed pages, the caret
// again, now exact; timed from the key to that dot.
let typed = "very ", gap = 0.15
var lines = source
let typeLine = 213
guard let r = lines[typeLine - 1].range(of: "substantially ") else { fatalError("no typing spot") }
var col = lines[typeLine - 1].utf8.distance(from: lines[typeLine - 1].utf8.startIndex,
                                            to: r.upperBound.samePosition(in: lines[typeLine - 1].utf8)!)
func fileOffset(_ line: Int, _ col: Int) -> Int { lines[..<(line - 1)].reduce(0) { $0 + $1.utf8.count + 1 } + col }
let name = texURL.lastPathComponent
txp.send(["open", name, lines.joined(separator: "\n")])
let viewPage = map.caret(file: name, line: typeLine, text: lines[typeLine - 1], column: col)?.page ?? 0
txp.send(["goal", viewPage])
var keyAt: [Date] = []
var immediateMs: [Double] = [], exactMs: [Double] = [], ourMs: [Double] = []
var applied = 0, shownApplied = 1  // the open counts as one applied edit
func onPages(_ ev: [String: Any]) {
  let a = ev["applied"] as? Int ?? 0
  guard a > shownApplied else { return }
  let t = Date()
  let u = work.appendingPathComponent("synctex-\(a).txt")
  _ = txp.call("synctex", [u.path])
  let t1 = Date()
  let sync = SyncTeX(text: (try? String(contentsOf: u, encoding: .utf8)) ?? "")
  let t2 = Date()
  map.update(synctex: sync, changed: ev["changed"] as? [Int] ?? [], count: ev["n"] as? Int)
  let g0 = glyphMs.count
  let c = map.caret(file: name, line: typeLine, text: lines[typeLine - 1], column: col)
  print(String(format: "  report %d: synctex verb %.1f ms, parse %.1f ms, glyphs %@, caret total %.1f ms, changed %@", a,
               t1.timeIntervalSince(t) * 1000, t2.timeIntervalSince(t1) * 1000,
               glyphMs[g0...].map { String(format: "%.1f", $0) }.joined(separator: "+"), Date().timeIntervalSince(t2) * 1000,
               ((ev["changed"] as? [Int]) ?? []).map(String.init).joined(separator: ",")))
  let now = Date()
  ourMs.append(now.timeIntervalSince(t) * 1000)
  // keys up to `a - 1` (minus the open) are in this report
  let key = min(a - 2, keyAt.count - 1)
  if key >= 0, let c, !c.approximate { exactMs.append(now.timeIntervalSince(keyAt[key]) * 1000) }
  shownApplied = a
}
for ch in typed {
  let off = fileOffset(typeLine, col)
  var l = lines[typeLine - 1]
  l.insert(ch, at: l.utf8.index(l.utf8.startIndex, offsetBy: col))
  lines[typeLine - 1] = l
  keyAt.append(Date())
  txp.send(["change", name, off, 0, String(ch)])
  applied += 1
  col += String(ch).utf8.count
  let t = Date()
  let c = map.caret(file: name, line: typeLine, text: lines[typeLine - 1], column: col)
  immediateMs.append(Date().timeIntervalSince(t) * 1000)
  _ = c
  let until = Date().addingTimeInterval(gap)
  while let ev = txp.read(timeout: max(0, until.timeIntervalSinceNow)) {
    if ev["ev"] as? String == "pages" { onPages(ev) }
  }
}
// the last keys: wait for their report
let deadline = Date().addingTimeInterval(10)
while shownApplied < applied + 1, let ev = txp.read(timeout: max(0, deadline.timeIntervalSinceNow)) {
  if ev["ev"] as? String == "pages" { onPages(ev) }
}
if let c = map.caret(file: name, line: typeLine, text: lines[typeLine - 1], column: col) {
  _ = shot(c, steps.count, "after typing")
  print(String(format: "typed «%@»: dot after the last key on p%d '%@'%@, shot cursor-%02d.png", typed, c.page + 1,
               map.page(c.page)!.glyphs[c.glyph].t, c.approximate ? " ~" : "", steps.count))
}
print(String(format: "typing: caret on the drawn page per key median %.2f ms (max %.2f); key → exact dot median %.0f ms over %d reports (max %.0f), of which ours (synctex, glyphs, caret) median %.1f ms",
             median(immediateMs), immediateMs.max() ?? 0, median(exactMs), exactMs.count, exactMs.max() ?? 0, median(ourMs)))
txp.close()

// ---- words against OCR ------------------------------------------------------------------------------------------------

/// Vision's words on a render of the whole page at `scale`, split into runs of letters and digits like
/// `PageGlyphs.words` (and the pane's PageText): (text, box in points).
func ocrWords(_ img: CGImage, scale: Double) -> [(String, CGRect)] {
  let req = VNRecognizeTextRequest()
  req.recognitionLevel = .accurate
  req.usesLanguageCorrection = false
  try? VNImageRequestHandler(cgImage: img).perform([req])
  let w = Double(img.width) / scale, h = Double(img.height) / scale
  var out: [(String, CGRect)] = []
  for obs in req.results ?? [] {
    guard let c = obs.topCandidates(1).first else { continue }
    let s = c.string
    for tok in s.split(whereSeparator: \.isWhitespace) {
      var start: String.Index?
      var runs: [Range<String.Index>] = []
      var i = tok.startIndex
      while i < tok.endIndex {
        let ch = tok[i]
        if ch.isLetter || ch.isNumber || ((ch == "'" || ch == "\u{2019}") && start != nil) { if start == nil { start = i } }
        else if let s0 = start { runs.append(s0..<i); start = nil }
        i = tok.index(after: i)
      }
      if let s0 = start { runs.append(s0..<tok.endIndex) }
      for r in runs {
        guard let b = try? c.boundingBox(for: r)?.boundingBox else { continue }
        var t = String(tok[r])
        while t.hasSuffix("'") || t.hasSuffix("\u{2019}") { t.removeLast() }
        out.append((t, CGRect(x: b.minX * w, y: (1 - b.maxY) * h, width: b.width * w, height: b.height * h)))
      }
    }
  }
  return out
}

func renderPage(_ p: Int, scale: Double) -> CGImage {
  let size = p < sizes.count ? sizes[p] : [612, 792]
  let pw = Int(size[0] * scale), ph = Int(size[1] * scale)
  let rgb = work.appendingPathComponent("page.rgb")
  _ = txp.call("render", [p, scale, 0, 0, pw, ph, rgb.path, ""])
  let data = try! Data(contentsOf: rgb)
  let provider = CGDataProvider(data: data as CFData)!
  return CGImage(width: pw, height: ph, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: pw * 3,
                 space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                 decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

func compareWords(_ pages: [Int]) {
  func norm(_ s: String) -> String { s.replacingOccurrences(of: "\u{2019}", with: "'").lowercased() }
  func iou(_ a: CGRect, _ b: CGRect) -> Double {
    let i = a.intersection(b)
    if i.isNull { return 0 }
    let ia = Double(i.width * i.height)
    return ia / (Double(a.width * a.height) + Double(b.width * b.height) - ia)
  }
  var unread = 0, inFigures = 0
  var totOCR = 0, totGlyph = 0, same = 0, misread = 0, ocrOnly = 0, glyphOnly = 0
  var dx: [Double] = [], dy: [Double] = [], ocrMs: [Double] = [], glyphMs: [Double] = []
  var samples: [String] = []
  for p in pages {
    var t = Date()
    let img = renderPage(p, scale: 4)
    let ocr = ocrWords(img, scale: 4)
    ocrMs.append(Date().timeIntervalSince(t) * 1000)
    t = Date()
    guard let pg = map.page(p) else { continue }
    let gw = pg.words().map { w -> PageGlyphs.Word in var w = w; if w.raw.hasSuffix("-") { w.raw.removeLast() }; return w }
    glyphMs.append(Date().timeIntervalSince(t) * 1000)
    totOCR += ocr.count
    totGlyph += gw.count
    var used = Set<Int>()
    for (text, box) in ocr {
      // the glyph word overlapping it most
      // the glyph word overlapping it with the same text, else the one overlapping it most (Vision gives each part of
      // a hyphenated token the token's whole box)
      var best = -1, bestI = 0.0, sameText = false
      for (k, w) in gw.enumerated() where !used.contains(k) {
        let v = iou(box, w.rect)
        guard v > 0.1 else { continue }
        let st = norm(w.raw) == norm(text)
        if (st && !sameText) || (st == sameText && v > bestI) { bestI = v; best = k; sameText = st }
      }
      guard best >= 0, sameText || bestI > 0.2 else {
        ocrOnly += 1
        if samples.count < 60 { samples.append("p\(p + 1) OCR only: \(text)") }
        continue
      }
      used.insert(best)
      if norm(text) == norm(gw[best].raw) {
        same += 1
        if bestI > 0.5 {  // edges only where OCR's box is the word's own
          dx.append(abs(Double(box.minX - gw[best].rect.minX)))
          dx.append(abs(Double(box.maxX - gw[best].rect.maxX)))
        }
        dy.append(abs(Double(box.midY - gw[best].rect.midY)))
      } else {
        misread += 1
        if samples.count < 60 { samples.append("p\(p + 1) OCR «\(text)» glyphs «\(gw[best].raw)»") }
      }
    }
    glyphOnly += gw.count - used.count
    for (k, w) in gw.enumerated() where !used.contains(k) {
      if !ocr.contains(where: { !$0.1.intersection(w.rect.insetBy(dx: -1, dy: -1)).isNull }) { unread += 1 }
      if pg.glyphs[w.glyphs.lowerBound].c > 0 { inFigures += 1 }
    }
    for (k, w) in gw.enumerated() where !used.contains(k) && samples.count < 60 { samples.append("p\(p + 1) glyphs only: \(w.raw)") }
  }
  func med(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.sorted()[a.count / 2] }
  func p90(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.sorted()[a.count * 9 / 10] }
  print("pages \(pages.map { $0 + 1 }): OCR \(totOCR) words, glyphs \(totGlyph) words")
  print(String(format: "same word, same place: %d (%.1f%% of OCR's); OCR reads differently: %d; OCR only: %d; glyphs only: %d",
               same, 100.0 * Double(same) / Double(max(totOCR, 1)), misread, ocrOnly, glyphOnly))
  print("  glyphs only: \(unread) where OCR read nothing at all (a skipped block), \(inFigures) in figures")
  print(String(format: "box edges, OCR vs glyphs: x median %.2f pt (p90 %.2f), y centre median %.2f pt (p90 %.2f)",
               med(dx), p90(dx), med(dy), p90(dy)))
  print(String(format: "time a page: OCR of a 4x render %.0f ms (render included), words from glyphs %.2f ms (file already read)",
               med(ocrMs), med(glyphMs)))
  samples.forEach { print("  " + $0) }
}
