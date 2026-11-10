// Universal (clients/universal, docs/universal.md): stock pdfTeX, XeTeX and LuaTeX run live by `tau-live`, which
// speaks the live pdfTeX's protocol (docs/live-protocol.md). LiveTex drives it; this file says where its pieces are,
// and which engine a project gets. tau-live converts XeTeX's XDV pages to PDF itself, with tau-pdfmx.
import Foundation

/// The three LaTeX engines Overleaf offers (its project setting "Compiler").
public enum TexEngine: String, CaseIterable, Sendable {
  case pdflatex, xelatex, lualatex

  /// Overleaf's compiler name (`pdflatex`, `xelatex`, `lualatex`); nil for `latex` (DVI mode) and unknown ones.
  public init?(compiler: String?) {
    guard let c = compiler, let e = TexEngine(rawValue: c) else { return nil }
    self = e
  }

  public var title: String { ["pdflatex": "pdfLaTeX", "xelatex": "XeLaTeX", "lualatex": "LuaLaTeX"][rawValue]! }
  /// The engine program in universal's bin folder (`pdflatex` → pdftex, as TeX Live's links).
  var program: String { rawValue }
  /// XeTeX writes XDV (`-no-pdf`): tau-live converts its changed pages with tau-pdfmx.
  var writesXDV: Bool { self == .xelatex }

  /// What the main file says it's for: a `% !TEX program` line, or fontspec/unicode-math/polyglossia (XeLaTeX).
  public static func fromSource(_ s: String) -> TexEngine {
    for line in s.split(separator: "\n", omittingEmptySubsequences: true).prefix(400) {
      let l = line.trimmingCharacters(in: .whitespaces).lowercased()
      if l.hasPrefix("% !tex"), l.contains("program") {
        return l.contains("lualatex") ? .lualatex : l.contains("xelatex") ? .xelatex : .pdflatex
      }
      if l.hasPrefix("%") { continue }
      if EngineChoice.needsUnicodeEngine(String(line)) { return .xelatex }
      if l.contains("\\begin{document}") { break }
    }
    return .pdflatex
  }
}

/// Settings ▸ PDF's universal switches, and each project's engine (Overleaf's compiler unless set here).
public enum UniversalSettings {
  /// XeLaTeX and LuaLaTeX projects on universal (default on; off: TeXpresso, as before).
  public static let unicodeKey = "taudot.universal.unicode"
  /// pdfLaTeX projects on universal too (default on since 2026-11-09; off: the patched pdfTeX).
  public static let pdflatexKey = "taudot.universal.pdflatex"
  /// Posted (by Settings) after any of these changed: an open project restarts on the engine they name now.
  public static let changed = Notification.Name("taudot.universal.changed")
  /// Per project: "pdflatex", "xelatex" or "lualatex"; absent = Overleaf's compiler.
  static func engineKey(_ folder: URL) -> String { "taudot.projectEngine." + folder.standardizedFileURL.path }

  public static func unicode(_ d: UserDefaults = .standard) -> Bool { d.object(forKey: unicodeKey) as? Bool ?? true }
  public static func pdflatex(_ d: UserDefaults = .standard) -> Bool { d.object(forKey: pdflatexKey) as? Bool ?? true }

  public static func engine(for folder: URL, _ d: UserDefaults = .standard) -> TexEngine? {
    d.string(forKey: engineKey(folder)).flatMap(TexEngine.init(rawValue:))
  }
  public static func setEngine(_ e: TexEngine?, for folder: URL, _ d: UserDefaults = .standard) {
    if let e { d.set(e.rawValue, forKey: engineKey(folder)) } else { d.removeObject(forKey: engineKey(folder)) }
  }
}

/// The project Settings ▸ PDF talks about: the last one whose PDF pane opened or came to the front, with the engine
/// Overleaf (or its main file) names. Posted as `changed` on the main actor.
@MainActor public enum CurrentProject {
  public static let changed = Notification.Name("taudot.currentProject")
  /// (Screenshots: $TAUDOT_SETTINGS_PROJECT stands in before a project opens.)
  public private(set) static var folder: URL? = ProcessInfo.processInfo.environment["TAUDOT_SETTINGS_PROJECT"].map { URL(fileURLWithPath: $0) }
  /// Overleaf's compiler, else what the main file says.
  public private(set) static var projectEngine: TexEngine?
  /// What runs it now ("pdfTeX (patched)", "XeLaTeX on universal", "TeXpresso").
  public private(set) static var running: String?

  static func set(folder: URL?, engine: TexEngine?, running: String?) {
    self.folder = folder
    self.projectEngine = engine
    self.running = running
    NotificationCenter.default.post(name: changed, object: nil)
  }
}

/// Where universal's pieces are: $TAUDOT_UNIVERSAL (a bin folder), else the app's `Resources/universal/bin`, else the
/// universal agent's build (~/code/lab/taudot-ref/universal/bin, `clients/universal/build.sh`). Formats beside it
/// (`fmt`, or the build's `fmt-2026`). Universal's engines are TeX Live 2026's, whatever the project's image.
public enum UniversalPaths {
  public static let year = "2026"

  static func bin(_ env: [String: String]) -> URL {
    if let d = env["TAUDOT_UNIVERSAL"] { return URL(fileURLWithPath: d) }
    if let r = LiveTexPaths.resources?.deletingLastPathComponent().appendingPathComponent("universal/bin"),
      FileManager.default.isExecutableFile(atPath: r.appendingPathComponent("tau-live").path) {
      return r
    }
    return URL(fileURLWithPath: LiveTexPaths.ref + "/universal/bin")
  }
  public static func driver(_ env: [String: String] = ProcessInfo.processInfo.environment) -> String {
    bin(env).appendingPathComponent("tau-live").path
  }
  public static func engine(_ e: TexEngine, env: [String: String] = ProcessInfo.processInfo.environment) -> String {
    bin(env).appendingPathComponent(e.program).path
  }
  static func tool(_ name: String, _ env: [String: String]) -> String? {
    let p = bin(env).appendingPathComponent(name).path
    return FileManager.default.isExecutableFile(atPath: p) ? p : nil
  }
  public static func bibtex(_ env: [String: String] = ProcessInfo.processInfo.environment) -> String? { tool("bibtex", env) }
  /// xdvipdfmx kept resident; tau-live runs it beside itself to convert XeTeX's changed pages.
  public static func tauPdfmx(_ env: [String: String] = ProcessInfo.processInfo.environment) -> String? { tool("tau-pdfmx", env) }
  public static func tauTdl(_ env: [String: String] = ProcessInfo.processInfo.environment) -> String? { tool("tau-tdl", env) }
  public static func formats(_ env: [String: String] = ProcessInfo.processInfo.environment) -> String {
    if let f = env["TAUDOT_UNIVERSAL_FMT"] { return f }
    let b = bin(env).deletingLastPathComponent()
    let bundled = b.appendingPathComponent("fmt").path
    return FileManager.default.fileExists(atPath: bundled) ? bundled : b.appendingPathComponent("fmt-\(year)").path
  }
  /// TeX Live files missing from the tree: libtau fetches them itself from the store named by TEXSTORE_URL,
  /// TEXSTORE_IMAGE and TEXSTORE_ROOT (the live pdfTeX's environment), only paths the tree's ls-R lists. $TAU_FETCH
  /// (a command, e.g. `clients/universal/tools/tl-fetch`) replaces that client; tests only. Measured on paper-b's
  /// first compile on a complete tree: 0 fetches, the same time as with fetching off (XeLaTeX 2.1–3.1 s, LuaLaTeX
  /// 5.7–6.1 s to `done`).
  static func fetcher(_ env: [String: String]) -> String? { env["TAU_FETCH"].flatMap { $0.isEmpty ? nil : $0 } }

  /// Why `e` can't run on universal, or nil.
  public static func missing(_ e: TexEngine, env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
    let fm = FileManager.default
    if !fm.isExecutableFile(atPath: driver(env)) { return "no tau-live (\(driver(env)))" }
    if !fm.isExecutableFile(atPath: engine(e, env: env)) { return "no \(e.program) for universal" }
    let fmt = formats(env) + "/\(e.rawValue).fmt"
    if !fm.fileExists(atPath: fmt) { return "no \(e.rawValue).fmt (\(fmt))" }
    if e.writesXDV, tauPdfmx(env) == nil { return "no tau-pdfmx for universal" }
    if !fm.fileExists(atPath: LiveTexPaths.storeRoot(year) + "/texmf-dist/ls-R") { return "no TeX Live \(year) tree" }
    return nil
  }

  /// tau-live's environment: the live pdfTeX's (TeX Live 2026's tree), universal's formats, libtau's fetcher.
  public static func environment(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
    var e = LiveTexPaths.environment(year, base: base)
    e["TEXFORMATS"] = ".:" + formats(base)
    e["TAU_TLROOT"] = LiveTexPaths.storeRoot(year)
    e["TAU_FETCH"] = fetcher(base)
    e["SOURCE_DATE_EPOCH"] = base["SOURCE_DATE_EPOCH"] ?? e["SOURCE_DATE_EPOCH"]
    return e
  }
}

/// An Int read and written from any thread.
final class LockedInt: @unchecked Sendable {
  private let lock = NSLock()
  private var v = 0
  var value: Int { lock.lock(); defer { lock.unlock() }; return v }
  func set(_ n: Int) { lock.lock(); v = n; lock.unlock() }
}

/// uspeed's parked engines (docs/universal.md, "Parked engine"): one `tau-live --park SOCKET` per engine, started at
/// app launch, keeps an engine just past its format load; a session started with `--parked SOCKET` forks its engine
/// from it instead of starting one (first page on open: pdfLaTeX 0.97 → 0.89 s, LuaLaTeX 1.44 → 1.17 s on paper-b). A
/// session whose engine, command line or environment differ from the parked one's (tau-live's signature), or that
/// comes before the parked engine is ready, starts its own as before. tau-live renews the parked engine every 5 min
/// (TeX's \time and \today) and exits when its stdin closes: with the app, also when the app dies.
/// $TAUDOT_PARK=0 turns it off.
@MainActor public final class ParkedEngines {
  public static let shared = ParkedEngines()
  /// Sessions may start parked engines (`ensure`): set at app launch; off in tests unless they turn it on.
  public var enabled = false
  private var procs: [TexEngine: Process] = [:]
  /// Each engine's parked-engine readiness count (`parked` events), for tests and the log.
  public private(set) var parkedEvents: [TexEngine: Int] = [:]

  /// The socket for `e` (≤ 103 bytes: /tmp, not $TMPDIR; per app process, so test copies don't share one).
  nonisolated static func socket(_ e: TexEngine) -> String { "/tmp/taudot-park-\(getuid())-\(getpid())-\(e.rawValue).sock" }

  /// At app launch: a parked engine for every engine the settings put on universal.
  public func startAtLaunch(env: [String: String] = ProcessInfo.processInfo.environment, d: UserDefaults = .standard) {
    guard env["TAUDOT_PARK"] != "0" else { return }
    enabled = true
    guard d.string(forKey: EngineChoice.defaultsKey) != "texpresso" else { return }
    var engines: [TexEngine] = []
    if UniversalSettings.pdflatex(d) { engines.append(.pdflatex) }
    if UniversalSettings.unicode(d) { engines += [.xelatex, .lualatex] }
    for e in engines { _ = ensure(e, env: env) }
  }

  /// The parked engine's socket for `e`, started if it isn't running (nil: off, or universal can't run `e`).
  public func ensure(_ e: TexEngine, env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
    guard enabled, env["TAUDOT_PARK"] != "0" else { return nil }
    if let p = procs[e], p.isRunning { return Self.socket(e) }
    guard UniversalPaths.missing(e, env: env) == nil else { return nil }
    let sock = Self.socket(e)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: UniversalPaths.driver(env))
    p.arguments = ["--park", sock, "--serve", "--engine", UniversalPaths.engine(e, env: env)]
    p.environment = UniversalPaths.environment(base: env)
    let i = Pipe(), o = Pipe()
    TxpProcess.ignoreSigpipe
    p.standardInput = i  // (kept open: tau-live --park exits when it closes)
    p.standardOutput = o
    p.standardError = FileHandle.nullDevice
    let buf = LineBuffer()
    o.fileHandleForReading.readabilityHandler = { [weak self] h in
      let d = h.availableData
      if d.isEmpty { h.readabilityHandler = nil; return }
      let n = buf.take(d).filter { String(decoding: $0, as: UTF8.self).contains("\"ev\":\"parked\"") }.count
      guard n > 0 else { return }
      DispatchQueue.main.async { MainActor.assumeIsolated { self?.parkedEvents[e, default: 0] += n } }
    }
    p.terminationHandler = { [weak self] q in
      DispatchQueue.main.async { MainActor.assumeIsolated { if self?.procs[e] === q { self?.procs[e] = nil } } }
    }
    do { try p.run() } catch { return nil }
    procs[e] = p
    pipes[e] = i
    return sock
  }
  private var pipes: [TexEngine: Pipe] = [:]

  /// Stops them all (tests).
  public func stopAll() {
    for (e, p) in procs {
      try? pipes[e]?.fileHandleForWriting.close()
      let pid = p.processIdentifier
      DispatchQueue.global().asyncAfter(deadline: .now() + 1) { if p.isRunning { kill(pid, SIGTERM) } }
    }
    procs = [:]
    pipes = [:]
  }
}
