// What a self-contained Taudot.app carries (clients/mac/bundle.sh, docs/release.md), found from the running bundle.
// Each lookup returns nil outside a bundle (swift build, the test hosts), and callers fall back to the developer's
// places (the repo's builds, ~/code/lab/taudot-ref, Homebrew).
//
//   Contents/MacOS/taudot                          the engine (`taudot serve`, run by the launch agent)
//   Contents/Resources/neovim/bin/nvim             Neovim (the official release build: system libraries only)
//   Contents/Resources/texpresso/texpresso-xetex   TeXpresso's XeTeX, with taudot-pdfinfo beside it
//   Contents/Resources/bin/tectonic                the stand-in for Tectonic that TeXpresso's file provider calls
//   Contents/Resources/{txp-render,bibtex,pdftex}  the TeXpresso driver, BibTeX, the live pdfTeX per year
import Foundation

public enum BundledTools {
  /// The bundle's Contents folder, when the app runs from one (Contents/MacOS/<executable>).
  public static var contents: URL? {
    guard let exe = Bundle.main.executableURL else { return nil }
    let macos = exe.deletingLastPathComponent()
    guard macos.lastPathComponent == "MacOS" else { return nil }
    return macos.deletingLastPathComponent()
  }

  static func executable(_ rel: String) -> URL? {
    guard let u = contents?.appendingPathComponent(rel), FileManager.default.isExecutableFile(atPath: u.path) else { return nil }
    return u
  }

  public static var engine: URL? { executable("MacOS/taudot") }
  public static var nvim: URL? { executable("Resources/neovim/bin/nvim") }
  public static var xetex: URL? { executable("Resources/texpresso/texpresso-xetex") }
  /// The folder put first on the TeXpresso driver's PATH (the tectonic stand-in).
  public static var bin: URL? { executable("Resources/bin/tectonic")?.deletingLastPathComponent() }

  /// The app runs from a place that goes away: the disk image, or macOS's App Translocation (a quarantined app
  /// opened where it was downloaded runs from a random read-only copy). A launch agent must not point there; the
  /// engine then starts on demand from this copy, and the next launch from /Applications installs the agent.
  public static var transient: Bool {
    guard let p = contents?.path else { return false }
    return p.hasPrefix("/Volumes/") || p.contains("/AppTranslocation/")
  }

  /// Starts `taudot service ensure` once per launch, off the main thread, for the bundle's engine: installs the launch
  /// agent, repoints it at this bundle (moved or updated app, a repo build's agent), restarts an engine older than
  /// its binary. Await `ensured` before connecting the first time. Nothing outside a bundle, or with
  /// $TAUDOT_NO_SERVICE (the engine then starts on demand, as before).
  public static let ensured: Task<String?, Never> = Task.detached {
    guard let bin = engine, ProcessInfo.processInfo.environment["TAUDOT_NO_SERVICE"] == nil, !transient else { return nil }
    let p = Process()
    p.executableURL = bin
    var args = ["service", "ensure", "--json"]
    // A socket somewhere else ($TAUDOT_SOCKET, tests): that engine home, which gets its own agent label.
    if let s = ProcessInfo.processInfo.environment["TAUDOT_SOCKET"] {
      args += ["--home", (s as NSString).deletingLastPathComponent]
    }
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = out
    p.standardInput = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let s = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    FileHandle.standardError.write(Data("taudot service ensure: \(s)\n".utf8))
    return s
  }
}
