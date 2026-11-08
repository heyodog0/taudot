// Universal (clients/universal, docs/universal.md): stock pdfTeX, XeTeX and LuaTeX run live by `tau-live`, which
// speaks the live pdfTeX's protocol (docs/live-protocol.md). LiveTex drives it; this file says where its pieces are,
// which engine a project gets, and turns XeTeX's XDV pages into PDF pages for the pane.
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
  /// XeTeX writes XDV (`-no-pdf`): its pages go through xdvipdfmx.
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
  /// pdfLaTeX projects on universal too (default off: the patched pdfTeX).
  public static let pdflatexKey = "taudot.universal.pdflatex"
  /// Posted (by Settings) after any of these changed: an open project restarts on the engine they name now.
  public static let changed = Notification.Name("taudot.universal.changed")
  /// Per project: "pdflatex", "xelatex" or "lualatex"; absent = Overleaf's compiler.
  static func engineKey(_ folder: URL) -> String { "taudot.projectEngine." + folder.standardizedFileURL.path }

  public static func unicode(_ d: UserDefaults = .standard) -> Bool { d.object(forKey: unicodeKey) as? Bool ?? true }
  public static func pdflatex(_ d: UserDefaults = .standard) -> Bool { d.bool(forKey: pdflatexKey) }

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
  public private(set) static var folder: URL?
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
  public static func xdvipdfmx(_ env: [String: String] = ProcessInfo.processInfo.environment) -> String? { tool("xdvipdfmx", env) }
  public static func tauTdl(_ env: [String: String] = ProcessInfo.processInfo.environment) -> String? { tool("tau-tdl", env) }
  public static func formats(_ env: [String: String] = ProcessInfo.processInfo.environment) -> String {
    if let f = env["TAUDOT_UNIVERSAL_FMT"] { return f }
    let b = bin(env).deletingLastPathComponent()
    let bundled = b.appendingPathComponent("fmt").path
    return FileManager.default.fileExists(atPath: bundled) ? bundled : b.appendingPathComponent("fmt-\(year)").path
  }
  /// libtau's fetcher for TeX Live files missing from the tree (`TAU_FETCH`): $TAU_FETCH, else the repo's
  /// `clients/universal/tools/tl-fetch` (the store's Python client; a development build only).
  static func fetcher(_ env: [String: String]) -> String? {
    if let f = env["TAU_FETCH"] { return f }
    let p = TxpPaths.repo.appendingPathComponent("clients/universal/tools/tl-fetch").path
    return FileManager.default.isExecutableFile(atPath: p) ? p : nil
  }

  /// Why `e` can't run on universal, or nil.
  public static func missing(_ e: TexEngine, env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
    let fm = FileManager.default
    if !fm.isExecutableFile(atPath: driver(env)) { return "no tau-live (\(driver(env)))" }
    if !fm.isExecutableFile(atPath: engine(e, env: env)) { return "no \(e.program) for universal" }
    let fmt = formats(env) + "/\(e.rawValue).fmt"
    if !fm.fileExists(atPath: fmt) { return "no \(e.rawValue).fmt (\(fmt))" }
    if e.writesXDV, xdvipdfmx(env) == nil { return "no xdvipdfmx for universal" }
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

/// XeTeX's pages as PDF pages: xdvipdfmx over the pages a `pdf` event brought (`-s FIRST-LAST`), so an edit costs one
/// page's conversion (~40 ms on a 48-page paper; the whole document is ~110 ms) rather than the document's.
enum XDV {
  /// Converts pages `first...last` (0-based) of `xdv` into `out`; nil if xdvipdfmx failed.
  static func toPDF(_ xdv: String, first: Int, last: Int, out: String, tool: String, env: [String: String], cwd: URL?) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = ["-q", "-z", "1", "-s", "\(first + 1)-\(last + 1)", "-o", out, xdv]
    p.environment = env
    if let cwd { p.currentDirectoryURL = cwd }  // figures by relative path, as the engine found them
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    p.waitUntilExit()
    return p.terminationStatus == 0 && FileManager.default.fileExists(atPath: out) ? out : nil
  }
}

/// An Int read and written from any thread.
final class LockedInt: @unchecked Sendable {
  private let lock = NSLock()
  private var v = 0
  var value: Int { lock.lock(); defer { lock.unlock() }; return v }
  func set(_ n: Int) { lock.lock(); v = n; lock.unlock() }
}
