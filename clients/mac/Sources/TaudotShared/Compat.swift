// The names from before the rename to Taudot (2026-11-04), kept working for one release. The old names live here.
//
// - TEXSYNC_* environment variables count as TAUDOT_* ones when those are unset.
// - The engine socket: ~/.taudot/engine.sock, or ~/.texsync/engine.sock while only the old engine home exists (the
//   engine moves it to ~/.taudot, leaving a symlink, when it next starts).
// - UserDefaults: the old app's settings (keys texsync.*) are copied once: dev.texsync.app into the bundled app,
//   texsync-app into an unbundled build.
// - The PDF page cache moves from ~/Library/Caches/dev.texsync.app.
import Foundation

public enum Compat {
  public static let bundleID = "app.taudot.Taudot"
  public static let oldDomains = ["dev.texsync.app", "texsync-app"]

  /// The old domains a build copies from: the installed app's (dev.texsync.app) only into the installed app. An
  /// unbundled build (`swift build`, tests) has no bundle ID and copies only its own old domain (texsync-app), so it
  /// never picks up the user's real settings.
  public static func oldDomains(bundleID: String?) -> [String] { bundleID == nil ? ["texsync-app"] : oldDomains }
  static let migratedKey = "taudot.migratedFromTexsync"

  /// Sets each unset TAUDOT_X from TEXSYNC_X. Call first thing in an executable's main.
  public static func envFallback() {
    for (k, v) in ProcessInfo.processInfo.environment where k.hasPrefix("TEXSYNC_") {
      let new = "TAUDOT_" + k.dropFirst("TEXSYNC_".count)
      if getenv(new) == nil { setenv(new, v, 0) }
    }
  }

  /// The engine's socket unless TAUDOT_SOCKET says otherwise.
  public static func engineSocket() -> String {
    if let s = ProcessInfo.processInfo.environment["TAUDOT_SOCKET"] { return s }
    let home = NSHomeDirectory() as NSString
    let new = home.appendingPathComponent(".taudot/engine.sock")
    let old = home.appendingPathComponent(".texsync/engine.sock")
    let fm = FileManager.default
    return fm.fileExists(atPath: new) || !fm.fileExists(atPath: old) ? new : old
  }

  /// A UserDefaults key's new name: texsync → taudot inside it (`texsync.appearance`, `NSWindow Frame texsync.settings`).
  static func newKey(_ k: String) -> String { k.replacingOccurrences(of: "texsync", with: "taudot") }

  /// Copies the old app's settings into `d` once; keys already set there win. The old domains stay as they are.
  public static func migrateDefaults(_ d: UserDefaults = .standard, from domains: [String] = oldDomains(bundleID: Bundle.main.bundleIdentifier)) {
    if d.bool(forKey: migratedKey) { return }
    for name in domains {
      for (k, v) in UserDefaults.standard.persistentDomain(forName: name) ?? [:] {
        let n = newKey(k)
        if d.object(forKey: n) == nil { d.set(v, forKey: n) }
      }
    }
    // Keys under the old prefix in the current domain (an unbundled build kept its own).
    for (k, v) in d.dictionaryRepresentation() where k.contains("texsync") {
      if d.object(forKey: newKey(k)) == nil { d.set(v, forKey: newKey(k)) }
    }
    d.set(true, forKey: migratedKey)
  }

  /// The app's cache folder, after moving the old one there if only it exists.
  public static func cachesFolder() -> URL {
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    let new = caches.appendingPathComponent(bundleID)
    let old = caches.appendingPathComponent("dev.texsync.app")
    let fm = FileManager.default
    if !fm.fileExists(atPath: new.path) && fm.fileExists(atPath: old.path) { try? fm.moveItem(at: old, to: new) }
    return new
  }

  /// Names in a project folder that belong to Taudot (hidden from the file tree), the old ones included.
  public static func isOwnFile(_ name: String) -> Bool { name.hasPrefix(".taudot") || name.hasPrefix(".texsync") }
}
