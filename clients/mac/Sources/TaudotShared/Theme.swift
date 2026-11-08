// Editor themes as tokens, defined once: the Neovim mode turns them into highlight groups (TaudotNeovim/ThemeLua),
// the native editor reads the same tokens. "Your Neovim colours" (id `neovim`) is not a theme: it leaves the user's
// colourscheme alone.
import Foundation

public struct Theme: Sendable, Identifiable, Equatable {
  public let id: String
  public let name: String
  public let dark: Bool
  /// 0xRRGGBB.
  public let bg: UInt32, fg: UInt32
  public let comment: UInt32
  /// LaTeX commands (\section, \cite…), math, environment names, brackets and delimiters.
  public let command: UInt32, math: UInt32, env: UInt32, bracket: UInt32
  public let selection: UInt32, cursor: UInt32, cursorLine: UInt32
  public let lineNr: UInt32, lineNrCurrent: UInt32
  public let search: UInt32
  /// Floats, popup menus and status lines.
  public let panel: UInt32
  /// Review tints come from these (the plugin blends authors' colours from Diagnostic*): info, warn, ok, hint, error.
  public let info: UInt32, warn: UInt32, ok: UInt32, hint: UInt32, error: UInt32
  /// The same tokens in Display P3 (`tokenPaths` order), when the source has them (Rex's themes). Read through
  /// `color(_:)`; Neovim gets the sRGB values above.
  public var p3: [UInt32]? = nil

  public static let neovimID = "neovim"

  /// A built-in theme, or a shipped, Rex or imported one (ThemeCatalog).
  public static func named(_ id: String) -> Theme? { builtIn.first { $0.id == id } ?? ThemeCatalog.find(id) }

  public static let builtIn: [Theme] = [
    // Today's look: near-black, blue commands, soft green environments.
    Theme(id: "dusk", name: "Taudot Dusk", dark: true, bg: 0x08080c, fg: 0xd0d0d6, comment: 0x7c7f93, command: 0x74b2ff,
          math: 0xe196c4, env: 0x8cc85f, bracket: 0xc0c4d6, selection: 0x24305a, cursor: 0xd0d0d6, cursorLine: 0x0d0d2a,
          lineNr: 0x44465a, lineNrCurrent: 0x80a0ff, search: 0xe3c78a, panel: 0x14141c,
          info: 0x74b2ff, warn: 0xe3c78a, ok: 0x8cc85f, hint: 0x79dac8, error: 0xff5d7a),
    Theme(id: "paper", name: "Paper", dark: false, bg: 0xfbfaf6, fg: 0x2b2a27, comment: 0x8a877e, command: 0x2457a6,
          math: 0x8f3aa8, env: 0x2f7d32, bracket: 0x5c5a55, selection: 0xd8e2f3, cursor: 0x2b2a27, cursorLine: 0xf1efe8,
          lineNr: 0xbdb9ae, lineNrCurrent: 0x6b685f, search: 0xf3d66b, panel: 0xefece4,
          info: 0x2457a6, warn: 0xb07d00, ok: 0x2f7d32, hint: 0x00838f, error: 0xc62828),
    Theme(id: "solarized-light", name: "Solarized Light", dark: false, bg: 0xfdf6e3, fg: 0x586e75, comment: 0x93a1a1,
          command: 0x268bd2, math: 0xd33682, env: 0x859900, bracket: 0x657b83, selection: 0xeee8d5, cursor: 0x586e75,
          cursorLine: 0xeee8d5, lineNr: 0x93a1a1, lineNrCurrent: 0x586e75, search: 0xb58900, panel: 0xeee8d5,
          info: 0x268bd2, warn: 0xb58900, ok: 0x859900, hint: 0x2aa198, error: 0xdc322f),
    Theme(id: "solarized-dark", name: "Solarized Dark", dark: true, bg: 0x002b36, fg: 0x93a1a1, comment: 0x586e75,
          command: 0x268bd2, math: 0xd33682, env: 0x859900, bracket: 0x839496, selection: 0x073642, cursor: 0x93a1a1,
          cursorLine: 0x073642, lineNr: 0x586e75, lineNrCurrent: 0x93a1a1, search: 0xb58900, panel: 0x073642,
          info: 0x268bd2, warn: 0xb58900, ok: 0x859900, hint: 0x2aa198, error: 0xdc322f),
    Theme(id: "tomorrow-night", name: "Tomorrow Night", dark: true, bg: 0x1d1f21, fg: 0xc5c8c6, comment: 0x969896,
          command: 0x81a2be, math: 0xb294bb, env: 0xb5bd68, bracket: 0x8abeb7, selection: 0x373b41, cursor: 0xc5c8c6,
          cursorLine: 0x282a2e, lineNr: 0x4d5057, lineNrCurrent: 0xc5c8c6, search: 0xf0c674, panel: 0x282a2e,
          info: 0x81a2be, warn: 0xf0c674, ok: 0xb5bd68, hint: 0x8abeb7, error: 0xcc6666),
    // Overleaf's default editor look: white, blue commands, green comments.
    Theme(id: "overleaf", name: "Overleaf", dark: false, bg: 0xffffff, fg: 0x000000, comment: 0x236e24, command: 0x0000ff,
          math: 0x8e24aa, env: 0xa31515, bracket: 0x444444, selection: 0xb5d5ff, cursor: 0x000000, cursorLine: 0xf4f6f8,
          lineNr: 0x9aa0a6, lineNrCurrent: 0x3c4043, search: 0xfff59d, panel: 0xf1f3f4,
          info: 0x1a73e8, warn: 0xb06000, ok: 0x188038, hint: 0x00838f, error: 0xd93025),
  ]
}
