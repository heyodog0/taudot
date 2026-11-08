// What the pane needs from a typesetter: TeXpresso (`Txp`, XeTeX, pages drawn by its driver) or the live pdfTeX
// (`LiveTex`, finished PDFs drawn here). Which one a project gets: `EngineChoice`.
import CoreGraphics
import Foundation
import TaudotCursor

@MainActor public protocol Typesetter: AnyObject {
  var onPages: ((PagesEvent) -> Void)? { get set }
  var onError: ((String) -> Void)? { get set }
  /// The typesetter's output lines, in TeXpresso's form (`["append-lines", "log", …]`, `["bib-log", text]`): the
  /// issues list and BibTeX's list read them whichever engine runs.
  var onLine: ((String) -> Void)? { get set }
  var onNote: ((String) -> Void)? { get set }
  var onRestart: (() -> Void)? { get set }
  var pageStyle: String { get set }
  var restartCount: Int { get }
  /// Open and change commands sent (compare with `PagesEvent.applied`).
  var sent: Int { get }
  /// `glyphs(page:)` answers (exact word boxes, the cursor dot).
  var hasGlyphs: Bool { get }
  /// A short name for the status line and logs.
  var engineName: String { get }
  func start()
  func stop()
  func killForTest()
  func open(_ path: String, _ text: String)
  func change(_ path: String, _ pos: Int, _ del: Int, _ ins: String)
  func rescan()
  func goal(_ page: Int)
  func synctex() async -> String?
  func glyphs(page: Int) async -> PageGlyphs?
  func render(page: Int, scale: Double, x: Int, y: Int, w: Int, h: Int) async -> TileImage?
}

extension Txp: Typesetter {
  public var hasGlyphs: Bool { TxpPaths.hasGlyphs }
  public var engineName: String { "texpresso" }
}

/// Which typesetter a project gets.
public enum EngineChoice: Equatable, Sendable {
  case texpresso
  /// The live pdfTeX for this TeX Live year ("2026").
  case live(year: String)
  /// Universal: a stock engine run live by tau-live (docs/universal.md), TeX Live 2026.
  case universal(TexEngine)

  /// Settings ▸ PDF: "auto" (pdfLaTeX projects on the live pdfTeX) or "texpresso" (everything on TeXpresso).
  public static let defaultsKey = "taudot.pdfEngine"

  /// The years the live pdfTeX has (an Overleaf image each, docs/texstore.md).
  public static let years = ["2026", "2025", "2024"]

  /// `compiler` and `image` as the engine's project.open gives them (`pdflatex`, `texlive-full:2026.1`); nil
  /// compiler: not known (a folder without the engine), then the source decides. `engine`: the project's own choice
  /// (Settings ▸ PDF), over Overleaf's. `universal`: Settings' switches (XeLaTeX/LuaLaTeX on universal, pdfLaTeX too).
  public static func choose(compiler: String?, image: String?, mainText: String?, engine: TexEngine? = nil,
                            setting: String? = UserDefaults.standard.string(forKey: defaultsKey),
                            universal: (unicode: Bool, pdflatex: Bool) = (UniversalSettings.unicode(), UniversalSettings.pdflatex()),
                            env: [String: String] = ProcessInfo.processInfo.environment) -> EngineChoice {
    if let e = env["TAUDOT_ENGINE"] {
      if e == "texpresso" { return .texpresso }
      if e.hasPrefix("live") { return .live(year: year(image) ?? (e.count > 5 ? String(e.dropFirst(5)) : years[0])) }
      // universal, universal-xelatex, ...: that engine, or the project's
      if e.hasPrefix("universal") {
        let named = TexEngine(rawValue: String(e.dropFirst("universal-".count)))
        return .universal(named ?? engine ?? TexEngine(compiler: compiler) ?? TexEngine.fromSource(mainText ?? ""))
      }
    }
    if setting == "texpresso" { return .texpresso }
    if engine == nil, compiler == "latex" { return .texpresso }  // DVI mode: not the live engines' (yet)
    let e = engine ?? TexEngine(compiler: compiler) ?? TexEngine.fromSource(mainText ?? "")
    switch e {
    case .pdflatex: return universal.pdflatex ? .universal(.pdflatex) : .live(year: year(image) ?? years[0])
    case .xelatex, .lualatex: return universal.unicode ? .universal(e) : .texpresso
    }
  }

  /// `texlive-full:2025.1` → "2025", the nearest year we have for older ones (Overleaf still offers 2020–2023), nil
  /// when there's no year in it.
  public static func year(_ image: String?) -> String? {
    guard let image, let r = image.range(of: #"20\d\d"#, options: .regularExpression) else { return nil }
    let y = String(image[r])
    if years.contains(y) { return y }
    return y > years[0] ? years[0] : years.last
  }

  /// A main file that says it's for XeLaTeX/LuaLaTeX: a `% !TEX program` line, or fontspec/unicode-math.
  public static func needsUnicodeEngine(_ s: String) -> Bool {
    for line in s.split(separator: "\n", omittingEmptySubsequences: true).prefix(400) {
      let l = line.trimmingCharacters(in: .whitespaces)
      if l.lowercased().hasPrefix("% !tex"), l.lowercased().contains("program") {
        return l.lowercased().contains("xelatex") || l.lowercased().contains("lualatex")
      }
      if l.hasPrefix("%") { continue }
      if l.contains("\\usepackage"), l.contains("{fontspec}") || l.contains("unicode-math") || l.contains("{polyglossia}") {
        return true
      }
      if l.contains("\\begin{document}") { break }
    }
    return false
  }
}
