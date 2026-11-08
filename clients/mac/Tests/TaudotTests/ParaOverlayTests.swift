import AppKit
import Foundation
import Testing
@testable import TaudotPDF

// The paragraph preview (ParaOverlay.swift, docs/live-protocol.md `para`): reading the driver's display list and
// drawing it, and on the real engine (patch 0011) a preview with the exact page's pixels.

/// A TDL with one square glyph (em units) at (100, 200), size 10, and a rule.
private func squareList() -> Data {
  var d = Data("TDL\0".utf8)
  func u8(_ v: UInt8) { d.append(v) }
  func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { d.append(contentsOf: $0) } }
  func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { d.append(contentsOf: $0) } }
  func f32(_ v: Double) { withUnsafeBytes(of: Float(v).bitPattern.littleEndian) { d.append(contentsOf: $0) } }
  func record(_ kind: UInt8, _ body: () -> Void) {
    u8(kind)
    let at = d.count
    u32(0)
    body()
    let n = d.count - at - 4
    d.replaceSubrange(at..<at + 4, with: withUnsafeBytes(of: UInt32(n).littleEndian) { Data($0) })
  }
  u32(2)
  record(0x01) { u32(0); f32(0); f32(0) }
  record(0x02) {
    u32(0); u8(2); u16(1); d.append(UInt8(ascii: "X")); u32(1)
    u32(7); u32(5); u32(8)
    d.append(contentsOf: "MLLLZ".utf8)
    for v in [0.0, 0, 1, 0, 1, 1, 0, 1] { f32(v) }
  }
  record(0x10) {
    for v in [100.0, 190, 110, 200] { f32(v) }
    u8(0)
    for v in [0.0, 0, 0, 1] { f32(v) }
    u32(0)
    for v in [10.0, 0, 0, -10] { f32(v) }
    u32(1); u32(7); f32(100); f32(200); f32(10); u16(0)
  }
  record(0x13) { for v in [100.0, 210, 150, 211, 0, 0, 0, 1] { f32(v) } }
  record(0x00) {}
  return d
}

@Test func paraOverlayReadsAndDrawsItsList() throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("para-\(UUID().uuidString.prefix(6))")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: dir) }
  let tdl = dir.appendingPathComponent("p.tdl")
  try squareList().write(to: tdl)
  let ev: [String: Any] = ["ev": "para", "go": 3, "applied": 7, "state": "exact", "page": 0, "path": tdl.path,
                           "erase": [[90.0, 185, 160, 215]]]
  let o = try #require(ParaOverlay(event: ev))
  #expect(o.go == 3 && o.applied == 7 && o.exact && o.page == 0)
  #expect(o.bounds.contains(CGRect(x: 100, y: 190, width: 10, height: 10)))
  // drawn at scale 2: the glyph is a black square at page (100…110, 190…200), the rule below it, paper around
  let img = try #require(ParaOverlay.render(o, scale: 2, x0: 180, y0: 370, w: 160, h: 60, style: "white"))
  #expect(pixel(img, (105 * 2 - 180), (195 * 2 - 370)) == (0, 0, 0))
  #expect(pixel(img, (130 * 2 - 180), (195 * 2 - 370)) == (255, 255, 255))
  #expect(pixel(img, (120 * 2 - 180), (210 * 2 + 1 - 370)) == (0, 0, 0))
  // none and broken lists give no preview
  #expect(ParaOverlay(event: ["ev": "para", "state": "none", "why": "far"]) == nil)
  try Data("TDL\0junk".utf8).write(to: tdl)
  #expect(ParaOverlay(event: ev) == nil)
}

/// The real driver and engine with the paragraph pass (built by the parapreview agent; skipped otherwise): typing in a
/// paragraph gets exact previews, each with the exact page's pixels where it paints.
@MainActor @Test func paraPreviewMatchesTheExactPage() async throws {
  let ref = (ProcessInfo.processInfo.environment["TAUDOT_REF"] ?? NSHomeDirectory() + "/code/lab/taudot-ref")
  var env = ProcessInfo.processInfo.environment
  let own = "\(ref)/parapreview/build-2026"
  if env["TAUDOT_LIVE_DRIVER"] == nil, FileManager.default.isExecutableFile(atPath: "\(own)/pdftex-live") {
    env["TAUDOT_LIVE_DRIVER"] = "\(own)/pdftex-live"
    env["TAUDOT_LIVE_ENGINE"] = "\(own)/live/texk/web2c/pdflatex"
  }
  guard LiveTexPaths.missing("2026") == nil, !LiveTexPaths.isFake("2026", env: env) else { return }
  let para = (1...14).map { "Paragraph \($0). " + String(repeating: "Some words to fill the line. ", count: 12) }
  let text = "\\documentclass{article}\n\\begin{document}\n" + para.joined(separator: "\n\n") + "\n\\end{document}\n"
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("para-live-\(UUID().uuidString.prefix(6))")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: dir) }
  try text.write(to: dir.appendingPathComponent("main.tex"), atomically: true, encoding: .utf8)
  let t = LiveTex(main: dir.appendingPathComponent("main.tex"), year: "2026", env: env)
  var events: [PagesEvent] = []
  var previews: [ParaOverlay] = []
  t.onPages = { events.append($0) }
  t.onPara = { previews.append($0) }
  t.start()
  defer { t.stop() }
  let end0 = Date().addingTimeInterval(60)
  while !events.contains(where: { $0.done }) && Date() < end0 { try await Task.sleep(for: .milliseconds(20)) }
  t.open("main.tex", text)
  var at = text.utf8.count - (text.components(separatedBy: "Paragraph 9. ").last ?? "").utf8.count + 4
  var checked = 0
  for i in 0..<4 {
    t.change("main.tex", at, 0, "x")
    at += 1
    let applied = 2 + i
    let end = Date().addingTimeInterval(20)
    while !events.contains(where: { $0.done && $0.applied >= applied }) && Date() < end {
      try await Task.sleep(for: .milliseconds(20))
    }
    guard let o = previews.last(where: { $0.applied == applied }) else { continue }  // the first edit leaves the snapshot
    #expect(o.exact)
    // the preview over the page it was drawn on, against the exact page (both at scale 2, the preview's box)
    let b = o.bounds.insetBy(dx: -2, dy: -2)
    let x0 = Int(b.minX * 2), y0 = Int(b.minY * 2), w = Int(b.width * 2), h = Int(b.height * 2)
    let mine = try #require(ParaOverlay.render(o, scale: 2, x0: x0, y0: y0, w: w, h: h, style: "white"))
    let exact = try #require(await t.render(page: o.page, scale: 2, x: x0, y: y0, w: w, h: h))
    var diff = 0
    for y in stride(from: 4, to: h - 4, by: 1) {
      for x in stride(from: 4, to: w - 4, by: 1) where o.erase.contains(where: {
        $0.contains(CGPoint(x: Double(x0 + x) / 2, y: Double(y0 + y) / 2))
      }) && pixel(mine, x, y) != pixel(exact, x, y) { diff += 1 }
    }
    #expect(diff == 0, "preview \(o.go): \(diff) pixels differ")
    checked += 1
  }
  print("paraPreviewMatchesTheExactPage: \(checked) previews checked, \(previews.count) in all")
  #expect(checked >= 2)
}

/// Bench (TAUDOT_PARA_BENCH=<a project folder copy>, main.tex): typing 8 keys a second into body paragraphs through
/// LiveTex; for each preview, the change sent → the `para` event on the main actor, and the overlay's tile render
/// (what the pane does off the main thread before the layer goes up).
@MainActor @Test func paraPreviewBench() async throws {
  guard let folder = ProcessInfo.processInfo.environment["TAUDOT_PARA_BENCH"] else { return }
  let ref = (ProcessInfo.processInfo.environment["TAUDOT_REF"] ?? NSHomeDirectory() + "/code/lab/taudot-ref")
  var env = ProcessInfo.processInfo.environment
  env["TAUDOT_LIVE_DRIVER"] = env["TAUDOT_LIVE_DRIVER"] ?? "\(ref)/parapreview/build-2026/pdftex-live"
  env["TAUDOT_LIVE_ENGINE"] = env["TAUDOT_LIVE_ENGINE"] ?? "\(ref)/parapreview/build-2026/live/texk/web2c/pdflatex"
  let main = URL(fileURLWithPath: folder).appendingPathComponent("main.tex")
  let text = try String(contentsOf: main, encoding: .utf8)
  let t = LiveTex(main: main, year: "2026", env: env)
  var events: [PagesEvent] = []
  var arrived: [Int: Double] = [:], sent: [Int: Double] = [:]
  var previews: [ParaOverlay] = []
  t.onPages = { events.append($0) }
  t.onPara = { o in arrived[o.applied] = CACurrentMediaTime(); previews.append(o) }
  t.start()
  defer { t.stop() }
  let end0 = Date().addingTimeInterval(120)
  while !events.contains(where: { $0.done }) && Date() < end0 { try await Task.sleep(for: .milliseconds(20)) }
  t.open("main.tex", text)
  var applied = 1
  let body = text.utf8.count / 3
  var starts: [Int] = []
  let u = Array(text.utf8)
  var i = body
  while starts.count < 6 && i < u.count - 400 {  // line starts of long text lines after the first third
    if u[i] == 10, let j = u[(i + 1)...].firstIndex(of: 10), j - i > 300, u[i + 1] >= 65, u[i + 1] <= 90 { starts.append(i + 41); i = j }
    i += 1
  }
  var shift = 0
  for s in starts {
    for k in 0..<8 {
      applied += 1
      sent[applied] = CACurrentMediaTime()
      t.change("main.tex", s + shift + k, 0, "x")
      try await Task.sleep(for: .milliseconds(125))
    }
    shift += 8
    try await Task.sleep(for: .milliseconds(400))
  }
  try await Task.sleep(for: .milliseconds(1000))
  var event: [Double] = [], render: [Double] = [], perKey: [Double] = []
  // each key: to the first preview that has it (keys typed while a pass runs are shown by a later one)
  for a in sent.keys.sorted() {
    guard let o = previews.first(where: { $0.applied >= a }), let t = arrived[o.applied], let s0 = sent[a], t > s0 else { continue }
    if t - s0 < 0.5 { perKey.append((t - s0) * 1000) }
  }
  for o in previews {
    guard let a = arrived[o.applied], let s0 = sent[o.applied] else { continue }
    event.append((a - s0) * 1000)
    let b = o.bounds.insetBy(dx: -1, dy: -1)
    let r0 = CACurrentMediaTime()
    _ = ParaOverlay.render(o, scale: 2, x0: Int(b.minX * 2), y0: Int(b.minY * 2), w: Int(b.width * 2), h: Int(b.height * 2), style: "white")
    render.append((CACurrentMediaTime() - r0) * 1000)
  }
  let drv = previews.map { Double($0.driverUs) / 1000 }
  func q(_ v: [Double], _ p: Double) -> Double { v.isEmpty ? -1 : v.sorted()[min(v.count - 1, Int(p * Double(v.count)))] }
  print(String(format: "paraPreviewBench: driver read→event p50 %.1f p95 %.1f ms", q(drv, 0.5), q(drv, 0.95)))
  print(String(format: "paraPreviewBench: %d previews of %d keys; change→event p50 %.1f p95 %.1f ms; key→its first preview p50 %.1f p95 %.1f ms (n %d); render p50 %.1f p95 %.1f ms; exact %d",
               event.count, applied - 1, q(event, 0.5), q(event, 0.95), q(perKey, 0.5), q(perKey, 0.95), perKey.count,
               q(render, 0.5), q(render, 0.95), previews.filter(\.exact).count))
}
