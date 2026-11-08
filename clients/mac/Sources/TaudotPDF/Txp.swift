// The app's side of txp-headless (clients/preview/texpresso/txp-headless.c, protocol in its header comment): start it,
// feed it edits, ask it for page rects, hear about changed pages. Restarted when it exits or shows no page in 10 s.
import Accelerate
import CoreGraphics
import Foundation
import TaudotCursor
import IOSurface
import TaudotShared

public struct PagesEvent: Sendable {
  public var gen: Int
  public var n: Int
  public var typeset: Int
  public var done: Bool
  public var sizes: [CGSize]
  public var changed: [Int]
  public var editUs: Int64
  public var stepUs: Int64
  /// Open and change commands txp-headless had read when it made this report (-1 from an older txp-headless).
  public var applied: Int
  /// Times txp-headless made its engine again after TeXpresso lost its start (txp-headless.c, recover_lost_start).
  public var lostStarts: Int

  init?(_ m: [String: Any]) {
    guard m["ev"] as? String == "pages", let n = m["n"] as? Int else { return nil }
    gen = m["gen"] as? Int ?? 0
    self.n = n
    typeset = m["typeset"] as? Int ?? n
    done = m["done"] as? Bool ?? false
    sizes = (m["sizes"] as? [[Double]] ?? []).map { CGSize(width: $0.first ?? 0, height: $0.count > 1 ? $0[1] : 0) }
    changed = m["changed"] as? [Int] ?? []
    editUs = (m["edit_us"] as? NSNumber)?.int64Value ?? -1
    stepUs = (m["step_us"] as? NSNumber)?.int64Value ?? 0
    applied = m["applied"] as? Int ?? -1
    lostStarts = m["lost_starts"] as? Int ?? 0
  }
}

/// A rendered rect, in an IOSurface: Core Animation shows it without copying it on the main thread.
public struct TileImage: @unchecked Sendable {
  public let surface: IOSurface
  public var width: Int { surface.width }
  public var height: Int { surface.height }
}

/// Packed RGB rows (3 bytes a pixel) → a BGRA IOSurface.
func makeImage(rgb: Data, w: Int, h: Int) -> TileImage? {
  let props: [IOSurfacePropertyKey: Any] = [
    .width: w, .height: h, .bytesPerElement: 4, .pixelFormat: 0x4247_5241,  // 'BGRA'
    .bytesPerRow: (w * 4 + 63) & ~63,
  ]
  guard let surf = IOSurface(properties: props) else { return nil }
  surf.lock(options: [], seed: nil)
  defer { surf.unlock(options: [], seed: nil) }
  let ok = rgb.withUnsafeBytes { (s: UnsafeRawBufferPointer) -> Bool in
    var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: s.baseAddress!), height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 3)
    var dst = vImage_Buffer(data: surf.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: surf.bytesPerRow)
    return vImageConvert_RGB888toBGRA8888(&src, nil, 255, &dst, false, vImage_Flags(kvImageNoFlags)) == kvImageNoError
  }
  return ok ? TileImage(surface: surf) : nil
}

public enum TxpError: Error { case notRunning, failed(String) }

/// Where the TeXpresso driver and texpresso-xetex are: $TAUDOT_TXP / $TEXPRESSO_XETEX, else the app bundle's
/// (BundledTools), else the repo's and the usual clone's. The driver is txp-render (clients/render: txp-headless's
/// protocol plus `glyphs` and the drawing runtime); there is no fallback. clients/preview/texpresso's txp-headless
/// links MuPDF and is kept as reference only.
public enum TxpPaths {
  static var repo: URL {
    // Sources/TaudotPDF/Txp.swift → repo root
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../..").standardized
  }
  /// The repo's txp-render is older than its C sources (driver.c, the dvi frontend, ...): a merge brought driver
  /// changes and nobody ran clients/render/build.sh. It still runs, without them; says which file is newer.
  public static var staleDriver: String? {
    let fm = FileManager.default
    let bin = repo.appendingPathComponent("clients/render/txp-render")
    guard headless == bin.path, let built = (try? fm.attributesOfItem(atPath: bin.path))?[.modificationDate] as? Date else { return nil }
    let dir = repo.appendingPathComponent("clients/render")
    var sources = ["driver.c", "txp-render.c", "glyphs.c", "dlist.c"].map { dir.appendingPathComponent($0) }
    // the interpreter, the drawing runtime (no MuPDF), the font loader and the tile drawer
    for sub in ["dvi", "rt", "fonts", "swift/Sources"] {
      if let e = fm.enumerator(at: dir.appendingPathComponent(sub), includingPropertiesForKeys: nil) {
        sources += e.compactMap { $0 as? URL }.filter { ["c", "h", "swift"].contains($0.pathExtension) }
      }
    }
    for s in sources {
      if let d = (try? fm.attributesOfItem(atPath: s.path))?[.modificationDate] as? Date, d > built {
        return "txp-render is older than clients/render/\(s.path.dropFirst(dir.path.count + 1)): run clients/render/build.sh"
      }
    }
    return nil
  }
  /// txp-render: $TAUDOT_TXP (the bundle's, set by the app), else the repo's build.
  public static var headless: String {
    ProcessInfo.processInfo.environment["TAUDOT_TXP"] ?? repo.appendingPathComponent("clients/render/txp-render").path
  }
  /// Why the driver can't run, or nil.
  public static func missing(_ path: String = headless) -> String? {
    FileManager.default.isExecutableFile(atPath: path) ? nil
      : "txp-render not found at \(path): build it with clients/render/build.sh"
  }
  /// The environment for the driver. A Finder/Dock launch gets launchd's bare PATH (/usr/bin:/bin), where
  /// txp-headless can't find `tectonic` and exits: add the usual install places, and, if tectonic is still not
  /// found, the login shell's PATH (asked once).
  public static func environment(_ base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
    var env = base
    var dirs = (base["PATH"] ?? "/usr/bin:/bin").split(separator: ":").map(String.init)
    let home = NSHomeDirectory()
    // The app's own tectonic stand-in (Resources/bin) comes first: a self-contained app needs no TeX install.
    if let b = BundledTools.bin?.path { dirs.removeAll { $0 == b }; dirs.insert(b, at: 0) }
    for d in ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", home + "/.cargo/bin", "/Library/TeX/texbin"] where !dirs.contains(d) {
      dirs.append(d)
    }
    let fm = FileManager.default
    if !dirs.contains(where: { fm.isExecutableFile(atPath: $0 + "/tectonic") }) {
      for d in loginPath where !dirs.contains(d) { dirs.append(d) }
    }
    env["PATH"] = dirs.joined(separator: ":")
    env["TEXPRESSO_XETEX"] = xetex
    // TeX Live's BibTeX (bundle.sh puts it in Resources/bibtex/ with its texmf.cnf): the driver runs it for styles the
    // project ships, as Overleaf would
    if env["TAUDOT_BIBTEX"] == nil, let b = Bundle.main.resourceURL?.appendingPathComponent("bibtex/bibtex"),
      fm.isExecutableFile(atPath: b.path)
    { env["TAUDOT_BIBTEX"] = b.path }
    return env
  }

  /// The login shell's PATH (`$SHELL -l -c 'echo $PATH'`), once; empty if it can't be had.
  nonisolated(unsafe) static let loginPath: [String] = {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
    p.arguments = ["-l", "-c", "printf %s \"$PATH\""]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    p.standardInput = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return [] }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self).split(separator: ":").map(String.init)
  }()

  /// The driver answers `glyphs`.
  public static var hasGlyphs: Bool { headless.hasSuffix("/txp-render") }
  public static var xetex: String {
    ProcessInfo.processInfo.environment["TEXPRESSO_XETEX"] ?? BundledTools.xetex?.path
      ?? NSHomeDirectory() + "/code/lab/taudot-ref/texpresso/build/texpresso-xetex"
  }
}

/// One txp-headless process. Callbacks come on the main actor.
@MainActor public final class TxpProcess {
  private let proc = Process()
  private let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
  private var waiting: [Int: CheckedContinuation<JSONObject, Never>] = [:]
  private var seq = 0
  private var lastGoal = -2
  private let tmp: URL
  public private(set) var running = false
  public var onPages: ((PagesEvent) -> Void)?
  public var onExit: ((Int32) -> Void)?
  /// `! ...` lines from TeX's output (stderr JSON arrays).
  public var onError: ((String) -> Void)?
  /// Every stderr line, in order, without its newline (TeX's `append-lines` / `truncate-lines` JSON, Tectonic's
  /// summary, the driver's own notes). Called before `onError` for the same chunk.
  public var onLine: ((String) -> Void)?
  /// TeXpresso killed its TeX worker before the first snapshot and rolled back to nothing ("No fences, assuming
  /// process finished"): it then reports 0 pages and never typesets again, whatever is edited.
  public var onLostStart: (() -> Void)?

  /// The stderr line that marks that state.
  nonisolated static func lostStart(_ l: String) -> Bool { l.hasPrefix("No fences, assuming process finished") }

  /// $TAUDOT_TXP_LOG: a file that gets txp-headless's stderr and every command sent.
  nonisolated(unsafe) static let debugLog: FileHandle? = ProcessInfo.processInfo.environment["TAUDOT_TXP_LOG"].flatMap {
    FileManager.default.createFile(atPath: $0, contents: nil)
    return FileHandle(forWritingAtPath: $0)
  }

  /// A TeX error from one line of txp-headless's stderr, or nil:
  /// - `Error: main.tex:4: LaTeX Error: Missing \begin{document}.` (Tectonic's summary, plain text, file and line
  ///   kept so the app's status bar can jump there);
  /// - `["append-lines", "out", "! Undefined control sequence.", "\nl.12 \\foo", ...]` (TeX's own output, JSON): the
  ///   `!` line, plus TeX's `l.N` pointer when it is there.
  nonisolated static func texError(_ l: String) -> String? {
    if l.hasPrefix("Error: ") {
      let s = String(l.dropFirst(7)).trimmingCharacters(in: .whitespaces)
      return s.isEmpty ? nil : s
    }
    guard l.hasPrefix("["), let a = try? JSONSerialization.jsonObject(with: Data(l.utf8)) as? [Any], a.count >= 3,
      a[0] as? String == "append-lines", a[1] as? String == "out", let s = a[2] as? String, s.hasPrefix("!")
    else { return nil }
    let pointer = a.dropFirst(3).compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .first { $0.hasPrefix("l.") }
    return pointer.map { s + " " + $0 } ?? s
  }

  static let ignoreSigpipe: Void = { signal(SIGPIPE, SIG_IGN) }()

  /// `bibCache`: where the driver keeps the last .bbl it made (default: the project's page cache folder).
  public init(main: URL, tmp: URL, executable: String? = nil, bibCache: URL? = nil) throws {
    self.tmp = tmp
    proc.executableURL = URL(fileURLWithPath: executable ?? TxpPaths.headless)
    proc.arguments = ["-tectonic", main.path]
    var env = TxpPaths.environment()
    // the last .bbl the driver's BibTeX made for this document, next to the page cache (no BibTeX run at open)
    if let d = bibCache ?? (PageCache.off ? nil : PageCache.dir(main.deletingLastPathComponent())) {
      try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
      env["TAUDOT_BIB_CACHE"] = d.path
    }
    proc.environment = env
    // A dead driver must never take the app with it: writing to its closed stdin gives EPIPE, not SIGPIPE (the
    // pipe's own flag), and SIGPIPE is ignored app-wide (other children's pipes too).
    Self.ignoreSigpipe
    _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    proc.standardInput = stdin
    proc.standardOutput = stdout
    proc.standardError = stderr
    let outBuf = LineBuffer(), errBuf = LineBuffer()
    stdout.fileHandleForReading.readabilityHandler = { [weak self] h in
      let d = h.availableData
      if d.isEmpty { h.readabilityHandler = nil; return }
      let lines = outBuf.take(d).map { String(decoding: $0, as: UTF8.self) }
      if let log = TxpProcess.debugLog {
        let t = String(format: "%.3f ", CFAbsoluteTimeGetCurrent())
        for l in lines where !l.contains("\"sizes\"") || true { log.write(Data((t + "< " + l.replacingOccurrences(of: #"\"sizes\":\[[^\]]*(\],\[[^\]]*)*\]\]"#, with: "\"sizes\":[...]", options: .regularExpression) + "\n").utf8)) }
      }
      guard !lines.isEmpty else { return }
      DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(lines) } }
    }
    stderr.fileHandleForReading.readabilityHandler = { [weak self] h in
      let d = h.availableData
      if d.isEmpty { h.readabilityHandler = nil; return }
      if let log = TxpProcess.debugLog { log.write(d) }
      let lines = errBuf.take(d).map { String(decoding: $0, as: UTF8.self) }
      guard !lines.isEmpty else { return }
      let errs = lines.compactMap(TxpProcess.texError)
      let lost = lines.contains(where: TxpProcess.lostStart)
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          if let f = self?.onLine { for l in lines { f(l) } }
          for e in errs { self?.onError?(e) }
          if lost { self?.onLostStart?() }
        }
      }
    }
    proc.terminationHandler = { [weak self] p in
      let code = p.terminationStatus
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          guard let self else { return }
          self.running = false
          for (_, c) in self.waiting { c.resume(returning: JSONObject(["ok": false, "error": "exited"])) }
          self.waiting = [:]
          self.onExit?(code)
        }
      }
    }
    try proc.run()
    running = true
  }

  private func handle(_ lines: [String]) {
    for line in lines where line.hasPrefix("{") {
      guard let m = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
      if let id = m["id"] as? Int {
        waiting.removeValue(forKey: id)?.resume(returning: JSONObject(m))
      } else if let e = PagesEvent(m) {
        Latency.shared.record(.pdfReady, key: Latency.shared.lastKey, value: Int64(e.applied))
        Latency.shared.section("pdf event") { onPages?(e) }
      }
    }
  }

  public func send(_ a: [Any]) {
    guard running, let d = try? JSONSerialization.data(withJSONObject: a, options: [.withoutEscapingSlashes]) else { return }
    var line = d
    line.append(0x0A)
    if let log = Self.debugLog { log.write(Data(String(format: "%.3f > ", CFAbsoluteTimeGetCurrent()).utf8) + line) }
    try? stdin.fileHandleForWriting.write(contentsOf: line)
  }

  /// The whole text of a file; TeXpresso diffs it against what it has and rolls back from the first changed byte.
  public func open(_ path: String, _ text: String) { send(["open", path, text]) }
  /// A UTF-8 byte-offset edit, as the engine API gives them.
  public func change(_ path: String, _ pos: Int, _ del: Int, _ ins: String) { send(["change", path, pos, del, ins]) }
  /// How renders are coloured from now on: "white", "sepia" or "dark" (driver.c, `restyle`).
  public func pageStyle(_ s: String) { send(["page-style", s]) }
  /// Files changed on disk (a saved .bib): TeXpresso rereads what changed and the driver checks the bibliography.
  public func rescan() { send(["rescan"]) }
  /// The last page in view (0-based): TeXpresso reports as soon as it has typeset this far. -1: everything.
  public func goal(_ page: Int) {
    if page == lastGoal { return }
    lastGoal = page
    send(["goal", page])
  }

  private func request(_ a: [Any]) async -> [String: Any] {
    seq += 1
    let id = seq
    return await withCheckedContinuation { c in
      waiting[id] = c
      var a = a
      a.insert(id, at: 1)
      send(a)
      if !running { waiting.removeValue(forKey: id)?.resume(returning: JSONObject(["ok": false])) }
    }.v
  }

  /// The SyncTeX data so far, as text.
  public func synctex() async -> String? {
    let path = tmp.appendingPathComponent("synctex-\(seq + 1).txt")
    let r = await request(["synctex", path.path])
    defer { try? FileManager.default.removeItem(at: path) }
    guard r["ok"] as? Bool == true else { return nil }
    return try? String(contentsOf: path, encoding: .utf8)
  }

  /// A page's glyphs (txp-render's `glyphs`: every glyph with its box, text, typeset line and word), read off the
  /// main thread. nil from txp-headless, or when the page isn't there.
  public func glyphs(page: Int) async -> PageGlyphs? {
    guard TxpPaths.hasGlyphs else { return nil }
    let path = tmp.appendingPathComponent("g\(seq + 1)-\(page).json")
    let r = await request(["glyphs", page, path.path])
    guard r["ok"] as? Bool == true else { try? FileManager.default.removeItem(at: path); return nil }
    return await Task.detached(priority: .userInitiated) { () -> PageGlyphs? in
      defer { try? FileManager.default.removeItem(at: path) }
      return try? PageGlyphs.load(path)
    }.value
  }

  /// Draw a w×h pixel rect at (x, y) of `page` (0-based) at `scale` pixels per PDF point. The file is read and turned
  /// into a BGRX image off the main thread.
  public func render(page: Int, scale: Double, x: Int, y: Int, w: Int, h: Int) async -> TileImage? {
    let path = tmp.appendingPathComponent("r\(seq + 1).rgb")
    let r = await request(["render", page, scale, x, y, w, h, path.path, ""])
    guard r["ok"] as? Bool == true, let rw = r["w"] as? Int, let rh = r["h"] as? Int else {
      try? FileManager.default.removeItem(at: path)
      return nil
    }
    return await Task.detached(priority: .userInitiated) { () -> TileImage? in
      defer { try? FileManager.default.removeItem(at: path) }
      guard let d = try? Data(contentsOf: path), d.count >= rw * rh * 3 else { return nil }
      return makeImage(rgb: d, w: rw, h: rh)
    }.value
  }

  public func kill() {
    guard running else { return }
    running = false
    proc.terminate()  // SIGTERM: txp-headless kills its snapshot processes too
  }
}

/// Keeps one txp-headless alive: restarts it (with backoff) when it exits or shows no page within 10 s, then calls
/// `onRestart` so the caller can send its open buffers again.
@MainActor public final class Txp {
  public let main: URL
  private let tmp: URL
  public private(set) var proc: TxpProcess?
  private var restarts = 0
  /// Restarts since a driver last reported a finished document: the restart delay's exponent (P5: it decays).
  private var backoff = 0
  private var started = Date()
  public var onPages: ((PagesEvent) -> Void)?
  public var onError: ((String) -> Void)?
  public var onRestart: (() -> Void)?
  /// Every stderr line of the current txp-headless (see `TxpProcess.onLine`). A restart starts a new process, whose
  /// stream starts over (its first `append-lines` rebuilds the log from nothing).
  public var onLine: ((String) -> Void)?
  public var onNote: ((String) -> Void)?
  public var noPageTimeout: TimeInterval = 10

  /// Where BibTeX's results are kept between opens (nil: the page cache's folder for the project).
  private let bibCache: URL?

  /// The driver's binary (nil: `TxpPaths.headless`); tests pass a stand-in here rather than through the environment.
  private let executable: String?

  public init(main: URL, bibCache: URL? = nil, executable: String? = nil) {
    self.main = main
    self.bibCache = bibCache
    self.executable = executable
    tmp = FileManager.default.temporaryDirectory.appendingPathComponent("taudot-pdf-\(getpid())-\(UUID().uuidString.prefix(6))")
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
  }

  public func start() {
    started = Date()
    let p: TxpProcess
    do { p = try TxpProcess(main: main, tmp: tmp, executable: executable, bibCache: bibCache) } catch {
      let path = executable ?? TxpPaths.headless
      onNote?("texpresso: " + (TxpPaths.missing(path) ?? "can't start \(path): \(error)"))
      scheduleStart(backoff: true)  // tried again, as after an exit (P5)
      return
    }
    proc = p
    sent = 0
    if let s = TxpPaths.staleDriver { onNote?(s) }
    if pageStyle != "white" { p.pageStyle(pageStyle) }
    if let goalPage { p.goal(goalPage) }
    var gotPages = false
    var lost = false
    var lastApplied = -1  // the open/change commands its last report covered
    // The watchdog below counts silence, not time: a first run on a new Mac fetches the TeX bundle's files for longer
    // than noPageTimeout, printing a line for each.
    var lastLine = Date()
    // A lost start shows as two things on two streams: the "No fences" line (stderr) and an empty done report
    // (stdout). They can come in either order (P6): restart once both are in.
    var emptyDone = false
    func restartIfLost(_ p: TxpProcess) {
      guard lost, emptyDone, proc === p else { return }
      lost = false
      emptyDone = false
      restart(p, "lost its pages (an edit during a fresh run)", backoff: false)
    }
    p.onLostStart = { [weak p] in
      lost = true
      if let p { restartIfLost(p) }
    }
    p.onPages = { [weak self, weak p] e in
      gotPages = true
      lastLine = Date()
      lastApplied = e.applied
      guard let self, let p, self.proc === p else { return }
      if e.done { self.backoff = 0 }
      // stuck with no pages after TeXpresso rolled back to nothing: only a fresh process typesets again
      if e.done && e.n == 0 {
        emptyDone = true
        if lost { restartIfLost(p); return }
      }
      if e.n > 0 { lost = false; emptyDone = false }
      self.onPages?(e)
    }
    p.onError = { [weak self] s in self?.onError?(s) }
    p.onLine = { [weak self, weak p] l in
      lastLine = Date()
      guard let self, let p, self.proc === p else { return }
      self.onLine?(l)
    }
    p.onExit = { [weak self, weak p] code in
      guard let self, let p, self.proc === p else { return }
      self.restart(p, "exited (\(code))")
    }
    // Waiting = no page yet, or edits sent that no report has covered (P5: a driver that hangs later, not only at
    // the start). Silent for noPageTimeout while waiting: restarted.
    func watch(after t: TimeInterval) {
      DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self, weak p] in
        MainActor.assumeIsolated {
          guard let self, let p, self.proc === p else { return }
          let waiting = !gotPages || (lastApplied >= 0 && self.sent > lastApplied)
          let quiet = Date().timeIntervalSince(lastLine)
          if !waiting || quiet < self.noPageTimeout { return watch(after: max(self.noPageTimeout - quiet, self.noPageTimeout / 2)) }
          self.restart(p, gotPages ? "no report and no output for \(Int(self.noPageTimeout)) s after an edit"
            : "no page and no output for \(Int(self.noPageTimeout)) s")
        }
      }
    }
    watch(after: noPageTimeout)
  }

  private func restart(_ p: TxpProcess, _ why: String, backoff: Bool = true) {
    guard proc === p else { return }
    proc = nil
    p.kill()
    restarts += 1
    onNote?("texpresso: \(why), restarting")
    scheduleStart(backoff: backoff)
  }

  private func scheduleStart(backoff useBackoff: Bool) {
    backoff += 1
    let delay = useBackoff ? min(0.5 * pow(2, Double(min(backoff - 1, 4))), 8) : 0.05
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.proc == nil, !self.stopped else { return }
        self.start()
        self.onRestart?()
      }
    }
  }

  private var stopped = false
  public func stop() {
    stopped = true
    proc?.kill()
    proc = nil
    try? FileManager.default.removeItem(at: tmp)
  }

  /// For tests: kill this pane's own txp-headless, as if it had crashed.
  public func killForTest() { proc?.kill() }
  public var restartCount: Int { restarts }
  /// Open and change commands sent to the current txp-headless (compare with `PagesEvent.applied`).
  public private(set) var sent = 0
  public func open(_ path: String, _ text: String) { sent += 1; proc?.open(path, text) }
  public func change(_ path: String, _ pos: Int, _ del: Int, _ ins: String) { sent += 1; proc?.change(path, pos, del, ins) }
  public func rescan() { proc?.rescan() }
  /// The page style, kept so a restarted driver gets it too.
  public var pageStyle = "white" {
    didSet { if pageStyle != oldValue { proc?.pageStyle(pageStyle) } }
  }
  /// The last page in view; kept so a restarted txp-headless gets it too (without a goal it only reports once the
  /// whole document is typeset, seconds on a long paper).
  public private(set) var goalPage: Int?
  public func goal(_ page: Int) {
    goalPage = page
    proc?.goal(page)
  }
  public func synctex() async -> String? { await proc?.synctex() }
  public func glyphs(page: Int) async -> PageGlyphs? { await proc?.glyphs(page: page) }
  public func render(page: Int, scale: Double, x: Int, y: Int, w: Int, h: Int) async -> TileImage? {
    await proc?.render(page: page, scale: scale, x: x, y: y, w: w, h: h)
  }
}
