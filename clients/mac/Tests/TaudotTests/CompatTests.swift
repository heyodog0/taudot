import Foundation
import Testing
@testable import TaudotShared

// The names from before the rename to Taudot still work (Compat.swift).

@Test func oldEnvironmentVariablesCount() {
  setenv("TEXSYNC_COMPAT_PROBE", "x", 1)
  unsetenv("TAUDOT_COMPAT_PROBE")
  Compat.envFallback()
  #expect(ProcessInfo.processInfo.environment["TAUDOT_COMPAT_PROBE"] == "x")
  setenv("TAUDOT_COMPAT_PROBE", "new", 1)
  Compat.envFallback()
  #expect(ProcessInfo.processInfo.environment["TAUDOT_COMPAT_PROBE"] == "new", "the new name wins")
}

@Test func oldSettingsAreCopiedOnce() {
  let old = "taudot-compat-test-old-\(getpid())", now = "taudot-compat-test-new-\(getpid())"
  UserDefaults.standard.setPersistentDomain(["texsync.appearance": "dark", "NSWindow Frame texsync.settings": "1 2 3 4", "plain": 7], forName: old)
  let d = UserDefaults(suiteName: now)!
  d.set("light", forKey: "taudot.keep")
  Compat.migrateDefaults(d, from: [old])
  #expect(d.string(forKey: "taudot.appearance") == "dark")
  #expect(d.string(forKey: "NSWindow Frame taudot.settings") == "1 2 3 4")
  #expect(d.integer(forKey: "plain") == 7)
  #expect(d.string(forKey: "taudot.keep") == "light")
  // Once only: later changes to the old domain aren't copied again.
  UserDefaults.standard.setPersistentDomain(["texsync.appearance": "system"], forName: old)
  d.set("dark", forKey: "taudot.appearance")
  Compat.migrateDefaults(d, from: [old])
  #expect(d.string(forKey: "taudot.appearance") == "dark")
  UserDefaults.standard.removePersistentDomain(forName: old)
  UserDefaults.standard.removePersistentDomain(forName: now)
}

@Test func ownFilesOldAndNew() {
  #expect(Compat.isOwnFile(".taudot.json") && Compat.isOwnFile(".texsync.json") && Compat.isOwnFile(".texsyncignore"))
  #expect(!Compat.isOwnFile("main.tex"))
}

@Test func unbundledBuildsNeverCopyTheInstalledApp() {
  // swift build / tests have no bundle ID: only their own old domain, never the user's dev.texsync.app.
  #expect(Compat.oldDomains(bundleID: nil) == ["texsync-app"])
  #expect(Compat.oldDomains(bundleID: Compat.bundleID) == ["dev.texsync.app", "texsync-app"])
}
