// The app's settings (the Settings window, ⌘,): kept in UserDefaults, applied live to open windows on
// `TaudotSettings.changed`. The Neovim side (theme, font, line height, the plugin's comment options) goes through `neovimLua`.
import Foundation
import TaudotShared

@MainActor public final class TaudotSettings {
  public static let shared = TaudotSettings(.standard)
  public static let changed = Notification.Name("taudot.settingsChanged")
  public let defaults: UserDefaults
  public init(_ d: UserDefaults) { defaults = d }

  private func string(_ k: String, _ def: String) -> String { defaults.string(forKey: k) ?? def }
  private func bool(_ k: String, _ def: Bool) -> Bool { defaults.object(forKey: k) as? Bool ?? def }
  private func set(_ k: String, _ v: Any) {
    defaults.set(v, forKey: k)
    NotificationCenter.default.post(name: Self.changed, object: self, userInfo: ["key": k])
  }

  // MARK: appearance

  /// "system", "light" or "dark".
  public var appearance: String { get { string("taudot.appearance", "system") } set { set("taudot.appearance", newValue) } }
  /// "system" or "#rrggbb" (one of `accents`). Never coral: it means "you".
  public var accent: String { get { string("taudot.accent", "system") } set { set("taudot.accent", newValue) } }
  public static let accents: [(name: String, hex: String)] = [
    ("Blue", "#3b82f6"), ("Purple", "#8b5cf6"), ("Teal", "#14b8a6"), ("Green", "#22c55e"), ("Amber", "#f59e0b"), ("Graphite", "#8e8e93"),
  ]

  // MARK: editor

  /// "neovim" (the embedded Neovim with the user's config, the default) or "native" (TaudotEditor). Read when a
  /// project window opens.
  public var editorMode: String { get { string("taudot.editorMode", "neovim") } set { set("taudot.editorMode", newValue) } }
  /// Vim keys in the native editor (normal, insert, visual modes).
  public var vimKeys: Bool { get { bool("taudot.vimKeys", false) } set { set("taudot.vimKeys", newValue) } }
  /// A built-in Theme's id, or `Theme.neovimID` (the user's own colours, the default).
  public var editorTheme: String { get { string("taudot.editorTheme", Theme.neovimID) } set { set("taudot.editorTheme", newValue) } }
  /// "" and 0: as the user's config has them (guifont).
  public var fontFamily: String { get { string("taudot.fontFamily", "") } set { set("taudot.fontFamily", newValue) } }
  public var fontSize: Double { get { defaults.double(forKey: "taudot.fontSize") } set { set("taudot.fontSize", newValue) } }
  /// Sizes ⌘+ / ⌘− step through (Settings' arrows too), points.
  public static let fontSizes: ClosedRange<Double> = 9...28
  /// ⌘+ (`by` 1) / ⌘− (-1): one point from `current` (what the editor shows now; the Settings value when set), kept
  /// in `fontSizes`, persisted like the Settings value.
  public func stepFontSize(by d: Double, current: Double) {
    let from = fontSize > 0 ? fontSize : (current > 0 ? current : 13)
    fontSize = min(Self.fontSizes.upperBound, max(Self.fontSizes.lowerBound, from.rounded() + d))
  }
  /// ⌘0: back to the default (Neovim: the config's guifont; native: 13 pt).
  public func resetFontSize() { if fontSize != 0 { fontSize = 0 } }
  /// Extra pixels between rows (Neovim's 'linespace'); -1: the config's.
  public var lineSpace: Int { get { defaults.object(forKey: "taudot.lineSpace") as? Int ?? -1 } set { set("taudot.lineSpace", newValue) } }
  /// Soft-wrap column: the editor's grid is at most this many columns wide (0: the window's width).
  public var maxTextWidth: Int { get { defaults.integer(forKey: "taudot.maxTextWidth") } set { set("taudot.maxTextWidth", newValue) } }

  // MARK: Claude

  /// The Claude pane's claude runs in the project's Rex session when a Rex server answers (ClaudeSession); off, or
  /// without Rex, Taudot runs it itself. Either way it outlives Taudot.
  public var claudeInRex: Bool { get { bool("taudot.claude.inRex", true) } set { set("taudot.claude.inRex", newValue) } }

  // MARK: PDF (read by the PDF pane)

  public var pdfMarkColor: String { get { string("taudot.pdfMarkColor", "accent") } set { set("taudot.pdfMarkColor", newValue) } }
  public var pdfComments: Bool { get { bool("taudot.pdfComments", true) } set { set("taudot.pdfComments", newValue) } }
  /// The word box and line band follow the cursor everywhere (off: only the coral dot follows it; the highlight shows
  /// on deliberate jumps, ⌘⌥J, ]r, a cross-reference, until the cursor changes line; a click in the PDF fades by itself).
  public var pdfHighlightFollows: Bool { get { bool("taudot.pdfHighlightFollows", false) } set { set("taudot.pdfHighlightFollows", newValue) } }
  /// "white", "sepia" or "dark".
  public var pdfPage: String { get { string("taudot.pdfPage", "white") } set { set("taudot.pdfPage", newValue) } }

  // MARK: comments

  /// The plugin's `comment_style`: "tint", "tint+underline", "underline" or "bar".
  public var commentStyle: String { get { string("taudot.commentStyle", "tint") } set { set("taudot.commentStyle", newValue) } }
  public var showResolved: Bool { get { bool("taudot.showResolved", false) } set { set("taudot.showResolved", newValue) } }
  public var floatingCards: Bool { get { bool("taudot.floatingCards", true) } set { set("taudot.floatingCards", newValue) } }
  /// Lines from cards to their text: "none" (the tint is the link), "selected" (the selected or hovered card), "all".
  public var connectorLines: String { get { string("taudot.comments.connectors", "all") } set { set("taudot.comments.connectors", newValue) } }

  // MARK: Neovim

  /// Lua applying the Neovim-side settings to the app's Neovim: the theme (or the user's colours back), font and line
  /// height (the user's own kept in g:taudot_user_guifont / _linespace and put back when the settings are cleared),
  /// and the plugin's comment options, redrawn.
  public func neovimLua() -> String {
    let theme = ThemeLua.apply(Theme.named(editorTheme))
    let fam = fontFamily.replacingOccurrences(of: "'", with: ""), size = fontSize, ls = lineSpace
    // Each part in its own function: a `return` in one (the theme's, when it puts the user's colours back) or an
    // error (a ColorScheme autocmd of the user's config) must not skip the others. Returns the errors, if any.
    return """
    local errs = {}
    local function part(f) local ok, e = pcall(f) if not ok then errs[#errs + 1] = tostring(e) end end
    part(function()
    \(theme)
    end)
    part(function()
      if vim.g.taudot_user_guifont == nil then
        vim.g.taudot_user_guifont = vim.o.guifont
        vim.g.taudot_user_linespace = vim.o.linespace
      end
      local ug = vim.g.taudot_user_guifont or ''
      local ufam, usize = ug:match('^([^:]*)'), ug:match(':h([%d.]+)')
      local fam, size = '\(fam)', \(size)
      if fam == '' and size <= 0 then
        if vim.o.guifont ~= ug then vim.o.guifont = ug end
      else
        local f = fam ~= '' and fam or (ufam ~= '' and ufam or 'Menlo')
        local s = size > 0 and size or tonumber(usize)
        local g = f .. (s and (':h' .. s) or '')
        if vim.o.guifont ~= g then vim.o.guifont = g end
      end
      local ls = \(ls) >= 0 and \(ls) or (vim.g.taudot_user_linespace or 0)
      if vim.o.linespace ~= ls then vim.o.linespace = ls end
    end)
    part(function()
      local c = require('taudot.config').options
      local style, resolved = '\(commentStyle)', \(showResolved)
      if c.comment_style == style and c.show_resolved == resolved then return end
      c.comment_style, c.show_resolved = style, resolved
      local ui, Buffer = require('taudot.ui'), require('taudot.buffer')
      ui.define_highlights()
      for _, b in pairs(Buffer.by_buf) do
        if b.ranges then b.comments = ui.draw_ranges(b.buf, b.ranges, b:pos_mapper()) end
      end
      require('taudot.review').redraw()
    end)
    return errs
    """
  }
}
