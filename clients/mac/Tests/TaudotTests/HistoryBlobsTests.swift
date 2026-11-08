// Figures at a version: VersionFolder gets each binary file as it was, from history's blobs (or the version's zip).
import AppKit
import Foundation
import PDFKit
@testable import TaudotPDF
import Testing
@testable import TaudotHistory

/// A history with blobs: `files` at each version, blobs by hash, zips by version; it counts what's asked.
@MainActor final class FakeBlobHistory: HistorySource, HistoryBlobSource {
  let inner = FakeHistorySource()
  var at: [Int: [VersionBlob]] = [:]
  var blobs: [String: Data] = [:]
  var zips: [Int: [String: Data]] = [:]
  var calls: [String] = []
  let dir: URL
  init(dir: URL) { self.dir = dir }

  func updates(before: Int?) async throws -> UpdatesPage { try await inner.updates(before: before) }
  func labels() async throws -> [HistoryLabel] { [] }
  func tree(_ r: HistoryRange) async throws -> [HistoryFile] { try await inner.tree(r) }
  func diff(path: String, _ r: HistoryRange) async throws -> HistoryDiff { try await inner.diff(path: path, r) }
  func file(path: String, version: Int) async throws -> String? { try await inner.file(path: path, version: version) }

  func filesAt(version: Int) async throws -> [VersionBlob] {
    calls.append("files_at \(version)")
    guard let a = at[version] else { throw HistoryError(description: "no version") }
    return a
  }
  func blob(hash: String) async throws -> URL {
    calls.append("blob \(hash.prefix(6))")
    guard let d = blobs[hash] else { throw HistoryError(description: "404") }
    return try save(d)
  }
  func zipFiles(version: Int, paths: [String]) async throws -> [String: URL] {
    calls.append("zip \(version) \(paths.joined(separator: ","))")
    guard let z = zips[version] else { throw HistoryError(description: "429") }
    var out: [String: URL] = [:]
    for p in paths { if let d = z[p] { out[p] = try save(d) } }
    return out
  }
  private func save(_ d: Data) throws -> URL {
    let u = dir.appendingPathComponent(blobHash(d))
    try d.write(to: u)
    return u
  }
}

@Test func blobHashIsGits() {
  #expect(blobHash(Data("hello\n".utf8)) == "ce013625030ba8dba906f756967f9e9ca394464a")
  #expect(blobHash(Data()) == "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391")
}

private let red = Data("red figure".utf8), blue = Data("blue figure".utf8), logo = Data("logo".utf8)

/// Version 2 had fig.png red; today it's blue. logo.png hasn't changed. old.pdf was removed since.
@MainActor private func setUp() throws -> (URL, URL, FakeBlobHistory, [HistoryFile]) {
  let fm = FileManager.default
  let tmp = fm.temporaryDirectory.appendingPathComponent("vblob-\(UUID().uuidString.prefix(6))")
  let project = tmp.appendingPathComponent("project")
  try fm.createDirectory(at: project.appendingPathComponent("figs"), withIntermediateDirectories: true)
  try fm.createDirectory(at: tmp.appendingPathComponent("store"), withIntermediateDirectories: true)
  // Tests run at once and `base` is global: set it once (a project's folders are under its own hash anyway).
  if VersionFolder.base == nil { VersionFolder.base = fm.temporaryDirectory.appendingPathComponent("taudot-versions-tests") }
  try Data("\\documentclass{article}\n".utf8).write(to: project.appendingPathComponent("main.tex"))
  try blue.write(to: project.appendingPathComponent("figs/fig.png"))
  try logo.write(to: project.appendingPathComponent("logo.png"))
  let f = FakeBlobHistory(dir: tmp.appendingPathComponent("store"))
  let files = [HistoryFile(path: "main.tex"), HistoryFile(path: "figs/fig.png", editable: false),
               HistoryFile(path: "logo.png", editable: false), HistoryFile(path: "old.pdf", editable: false)]
  f.inner.trees[HistoryRange(fromV: 2, toV: 5)] = [
    HistoryFile(path: "main.tex"), HistoryFile(path: "figs/fig.png", op: .edited, editable: false),
    HistoryFile(path: "logo.png", editable: false), HistoryFile(path: "old.pdf", op: .removed, deletedAtV: 4, editable: false),
  ]
  f.at[2] = [VersionBlob(path: "main.tex", hash: blobHash(Data("\\documentclass{article}\n".utf8)), kind: "text"),
             VersionBlob(path: "figs/fig.png", hash: blobHash(red), kind: "binary"),
             VersionBlob(path: "logo.png", hash: blobHash(logo), kind: "binary"),
             VersionBlob(path: "old.pdf", hash: blobHash(Data("old pdf".utf8)), kind: "binary")]
  return (tmp, project, f, files)
}

private func cleanUp(_ tmp: URL, _ project: URL) {
  try? FileManager.default.removeItem(at: VersionFolder.root(project))
  try? FileManager.default.removeItem(at: tmp)
}

@MainActor @Test func versionFolderHasFiguresAsTheyWere() async throws {
  let (tmp, project, f, files) = try setUp()
  defer { cleanUp(tmp, project) }
  f.blobs[blobHash(red)] = red
  f.blobs[blobHash(Data("old pdf".utf8))] = Data("old pdf".utf8)
  let made = try await VersionFolder.make(source: f, project: project, version: 2, files: files, head: 5)
  let read = { (p: String) in try Data(contentsOf: made.folder.appendingPathComponent(p)) }
  #expect(try read("figs/fig.png") == red)  // the old figure, not today's
  #expect(try read("logo.png") == logo)  // unchanged: today's copy, no request
  #expect(try read("old.pdf") == Data("old pdf".utf8))  // removed since: its blob
  #expect(made.binaryToday.isEmpty)
  #expect(f.calls == ["files_at 2", "blob \(blobHash(red).prefix(6))", "blob \(blobHash(Data("old pdf".utf8)).prefix(6))"])

  // Exact: the next visit is the folder as it is, no requests.
  f.calls = []
  let again = try await VersionFolder.make(source: f, project: project, version: 2, files: files, head: 5)
  #expect(again.binaryToday.isEmpty && f.calls.isEmpty)
  #expect(again.folder.path == made.folder.path, "\(again.folder) \(made.folder)")
}

@MainActor @Test func todaysCopyKeptWhenItsHashMatches() async throws {
  let (tmp, project, f, files) = try setUp()
  defer { cleanUp(tmp, project) }
  // fig.png was changed and changed back: today's copy is the version's
  f.at[2]![1].hash = blobHash(blue)
  f.at[2]!.removeLast()  // and old.pdf's blob is unknown: zip
  f.zips[2] = ["old.pdf": Data("old pdf".utf8)]
  let made = try await VersionFolder.make(source: f, project: project, version: 2, files: files, head: 5)
  #expect(try Data(contentsOf: made.folder.appendingPathComponent("figs/fig.png")) == blue)
  #expect(try Data(contentsOf: made.folder.appendingPathComponent("old.pdf")) == Data("old pdf".utf8))
  #expect(made.binaryToday.isEmpty)
  #expect(f.calls == ["files_at 2", "zip 2 old.pdf"])
}

@MainActor @Test func blobFailsZipFallbackThenTodays() async throws {
  let (tmp, project, f, files) = try setUp()
  defer { cleanUp(tmp, project) }
  // No blobs: the zip has the figure.
  f.zips[2] = ["figs/fig.png": red]
  var made = try await VersionFolder.make(source: f, project: project, version: 2, files: files, head: 5)
  #expect(try Data(contentsOf: made.folder.appendingPathComponent("figs/fig.png")) == red)
  #expect(made.binaryToday == ["old.pdf"])  // in neither, and not in the project: left out, and said
  #expect(!FileManager.default.fileExists(atPath: made.folder.appendingPathComponent("old.pdf").path))
  #expect(f.calls.last == "zip 2 figs/fig.png,old.pdf")

  // Nothing works: today's figure, said; and the folder is made again next time.
  f.zips = [:]
  f.at = [:]
  try? FileManager.default.removeItem(at: made.folder)
  made = try await VersionFolder.make(source: f, project: project, version: 2, files: files, head: 5)
  #expect(try Data(contentsOf: made.folder.appendingPathComponent("figs/fig.png")) == blue)
  #expect(Set(made.binaryToday) == ["figs/fig.png", "old.pdf"])
  f.calls = []
  _ = try await VersionFolder.make(source: f, project: project, version: 2, files: files, head: 5)
  #expect(f.calls.contains("files_at 2"))
}

@MainActor @Test func sourceWithoutBlobsKeepsTodaysFigures() async throws {
  let (tmp, project, f, files) = try setUp()
  defer { cleanUp(tmp, project) }
  let made = try await VersionFolder.make(source: f.inner, project: project, version: 2, files: files, head: 5)
  #expect(try Data(contentsOf: made.folder.appendingPathComponent("figs/fig.png")) == blue)
  #expect(Set(made.binaryToday) == ["figs/fig.png", "old.pdf"])
}

// ---- on CE (clients/mac/Tests/histblobs_ce.sh sets TAUDOT_CE_HISTBLOBS="socket|folder|red.png") -----------------------

/// The share of the page's pixels that are mostly red and mostly blue.
@MainActor private func redAndBlue(_ pdf: URL) -> (red: Double, blue: Double) {
  guard let doc = PDFDocument(url: pdf), let page = doc.page(at: 0) else { return (0, 0) }
  let box = page.bounds(for: .mediaBox)
  let w = Int(box.width), h = Int(box.height)
  guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return (0, 0) }
  ctx.cgContext.setFillColor(.white)
  ctx.cgContext.fill(CGRect(x: 0, y: 0, width: w, height: h))
  page.draw(with: .mediaBox, to: ctx.cgContext)
  var r = 0, b = 0
  for y in stride(from: 0, to: h, by: 2) {
    for x in stride(from: 0, to: w, by: 2) {
      guard let c = rep.colorAt(x: x, y: y) else { continue }
      if c.redComponent > 0.7 && c.blueComponent < 0.3 && c.greenComponent < 0.3 { r += 1 }
      if c.blueComponent > 0.7 && c.redComponent < 0.3 && c.greenComponent < 0.3 { b += 1 }
    }
  }
  let n = Double((w / 2) * (h / 2))
  return (Double(r) / n, Double(b) / n)
}

@MainActor @Test func ceVersionPDFHasTheOldFigure() async throws {
  guard let spec = ProcessInfo.processInfo.environment["TAUDOT_CE_HISTBLOBS"] else { return }
  let parts = spec.split(separator: "|").map(String.init)
  let (socket, project, redFile) = (URL(fileURLWithPath: parts[0]), URL(fileURLWithPath: parts[1]), URL(fileURLWithPath: parts[2]))
  try #require(LiveTexPaths.missing("2026") == nil, "the live pdfTeX isn't built")
  let source = EngineHistorySource(socket: socket, folder: project)
  defer { source.close() }
  let page = try await source.updates(before: nil)
  let first = try #require(page.groups.last), head = try #require(page.head)
  #expect(head > first.toV, "the figure was replaced after the first version")
  let r = HistoryRange(fromV: first.toV, toV: first.toV)
  let files = try await source.tree(r)

  let p = HistoryPDFController(source: source, project: project, mainFile: "main.tex", cacheRoot: project.appendingPathExtension("cache"))
  let win = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 640, height: 860), styleMask: [.borderless], backing: .buffered, defer: false)
  win.contentView = p.view
  p.show(r, files: files, head: head)
  defer { p.close() }
  let folder = VersionFolder.folder(project, version: first.toV)
  let saved = folder.appendingPathComponent(".taudot/version.pdf")
  let end = Date().addingTimeInterval(120)
  while !FileManager.default.fileExists(atPath: saved.path) && Date() < end { try await Task.sleep(for: .milliseconds(100)) }

  #expect(FileManager.default.contentsEqual(atPath: folder.appendingPathComponent("fig.png").path, andPath: redFile.path))
  #expect(p.binaryToday.isEmpty)
  #expect(!p.view.status.contains("today"), "\(p.view.status)")
  let c = redAndBlue(saved)
  print("version \(first.toV) of \(head): page red \(c.red), blue \(c.blue)")
  #expect(c.red > 0.1 && c.blue < 0.01, "red \(c.red) blue \(c.blue)")
}
