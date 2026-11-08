import AppKit
import Foundation
import Testing
@testable import TaudotShared

private let ghosttySample = """
# a comment
palette = 0=#1e1e2e
palette = 1=#f38ba8
palette = 2=#a6e3a1
palette = 3=#f9e2af
palette = 4=#89b4fa
palette = 5=#f5c2e7
palette = 6=#94e2d5
palette = 7=#bac2de
palette = 8=#585b70
palette = 9=#f38ba8
palette = 10=#a6e3a1
palette = 11=#f9e2af
palette = 12=#89b4fa
palette = 13=#f5c2e7
palette = 14=#94e2d5
palette = 15=#a6adc8
background = 1e1e2e
foreground = cdd6f4
cursor-color = f5e0dc
selection-background = 353749
"""

@Test func ghosttyMapsToTokens() throws {
  let p = try #require(ThemeFiles.ghostty(ghosttySample))
  #expect(p.background == 0x1e1e2e && p.ansi[4] == 0x89b4fa && p.isDark)
  let t = Theme.from(p, id: "x", name: "X")
  #expect(t.command == 0x89b4fa && t.env == 0xf5c2e7 && t.math == 0xf9e2af && t.comment == 0x585b70)
  #expect(t.bracket == 0x94e2d5 && t.error == 0xf38ba8 && t.cursor == 0xf5e0dc && t.selection == 0x353749)
  #expect(t.dark && t.lineNr != t.bg && t.cursorLine != t.bg)
  #expect(ThemeFiles.ghostty("background = 000000") == nil)
}

@Test func itermPlistParses() throws {
  func comp(_ v: UInt32) -> [String: Any] {
    ["Red Component": Double(v >> 16 & 0xff) / 255, "Green Component": Double(v >> 8 & 0xff) / 255, "Blue Component": Double(v & 0xff) / 255]
  }
  let p = try #require(ThemeFiles.ghostty(ghosttySample))
  var d: [String: Any] = ["Background Color": comp(p.background), "Foreground Color": comp(p.foreground)]
  for (i, c) in p.ansi.enumerated() { d["Ansi \(i) Color"] = comp(c) }
  let data = try PropertyListSerialization.data(fromPropertyList: d, format: .xml, options: 0)
  let q = try #require(ThemeFiles.parse(data))
  #expect(q.ansi == p.ansi && q.background == p.background)
}

@Test func shippedThemesAllParse() {
  #expect(ShippedThemes.all.count == ShippedThemes.list.count && ShippedThemes.all.count >= 12)
  #expect(Set(ShippedThemes.all.map(\.id)).count == ShippedThemes.all.count)
  let latte = Theme.named("catppuccin-latte")
  #expect(latte?.dark == false && latte?.bg == 0xeff1f5 && latte?.command == 0x1e66f5)
  #expect(Theme.named("nord")?.dark == true)
}

@Test func rexThemesFromTheirFile() throws {
  let json = """
  [{"id": "sample", "name": "Sample", "appearance": "light",
    "source": {"background": "#fafafa", "foreground": "#202020", "cursor": "#ff0000", "selectionBackground": "#dddddd",
      "ansi": ["#000000","#aa0000","#00aa00","#aaaa00","#0000aa","#aa00aa","#00aaaa","#aaaaaa",
               "#555555","#ff5555","#55ff55","#ffff55","#5555ff","#ff55ff","#55ffff","#ffffff"]},
    "displayP3": {"background": "color(display-p3 0.98 0.98 0.98)", "foreground": "color(display-p3 0.1 0.1 0.1)",
      "ansi": {"0":"color(display-p3 0 0 0)","1":"color(display-p3 0.6 0 0)","2":"color(display-p3 0 0.6 0)",
        "3":"color(display-p3 0.6 0.6 0)","4":"color(display-p3 0 0 0.7)","5":"color(display-p3 0.6 0 0.6)",
        "6":"color(display-p3 0 0.6 0.6)","7":"color(display-p3 0.6 0.6 0.6)","8":"color(display-p3 0.3 0.3 0.3)",
        "9":"color(display-p3 1 0.3 0.3)","10":"color(display-p3 0.3 1 0.3)","11":"color(display-p3 1 1 0.3)",
        "12":"color(display-p3 0.3 0.3 1)","13":"color(display-p3 1 0.3 1)","14":"color(display-p3 0.3 1 1)",
        "15":"color(display-p3 1 1 1)"}}}]
  """
  let ts = RexThemes.parse(Data(json.utf8))
  #expect(ts.count == 1)
  let t = try #require(ts.first)
  #expect(t.id == "rex-sample" && !t.dark && t.command == 0x0000aa && t.cursor == 0xff0000)
  #expect(t.p3 != nil)
  let c = t.color(\.command)
  #expect(c.colorSpace == .displayP3)
  #expect(abs(c.blueComponent - 0.7) < 0.01)
  // Rex itself, when installed here: every theme maps.
  if let f = RexThemes.file(), let d = try? Data(contentsOf: f) {
    let raw = try JSONSerialization.jsonObject(with: d) as? [Any]
    #expect(RexThemes.parse(d).count == raw?.count)
  }
}

@Test func importAndRemove() throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("themes-\(UUID().uuidString)")
  setenv("TAUDOT_THEMES_DIR", dir.path, 1)
  defer { unsetenv("TAUDOT_THEMES_DIR"); try? FileManager.default.removeItem(at: dir) }
  let src = FileManager.default.temporaryDirectory.appendingPathComponent("My Theme")
  try ghosttySample.write(to: src, atomically: true, encoding: .utf8)
  let t = try ThemeCatalog.importTheme(from: src)
  #expect(t.id == "imported-my-theme")
  #expect(Theme.named("imported-my-theme")?.command == 0x89b4fa)
  #expect(ThemeCatalog.groups.contains { $0.name == "Imported" && $0.themes.count == 1 })
  ThemeCatalog.remove(t.id)
  #expect(Theme.named("imported-my-theme") == nil)
  let bad = FileManager.default.temporaryDirectory.appendingPathComponent("bad.itermcolors")
  try "nope".write(to: bad, atomically: true, encoding: .utf8)
  #expect(throws: ThemeCatalog.ImportError.self) { try ThemeCatalog.importTheme(from: bad) }
}
