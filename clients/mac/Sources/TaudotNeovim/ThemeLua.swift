// Themes in the Neovim mode: a Theme's tokens become highlight groups in the app's own Neovim (never the user's other
// Neovims): editor UI, legacy and treesitter LaTeX groups, diagnostics (which the plugin's review tints derive from on
// ColorScheme). "Your Neovim colours" restores the colourscheme the user's config set.
import Foundation
import TaudotShared

public enum ThemeLua {
  static func hex(_ c: UInt32) -> String { String(format: "#%06x", c & 0xffffff) }

  /// The groups for a theme: name → attributes, as Lua table constructors.
  public static func groups(_ t: Theme) -> [(String, String)] {
    func g(_ fg: UInt32? = nil, bg: UInt32? = nil, sp: UInt32? = nil, _ extra: String = "") -> String {
      var parts: [String] = []
      if let fg { parts.append("fg = '\(hex(fg))'") }
      if let bg { parts.append("bg = '\(hex(bg))'") }
      if let sp { parts.append("sp = '\(hex(sp))'") }
      if !extra.isEmpty { parts.append(extra) }
      return "{ " + parts.joined(separator: ", ") + " }"
    }
    var out: [(String, String)] = [
      ("Normal", g(t.fg, bg: t.bg)), ("NormalNC", g(t.fg, bg: t.bg)), ("NormalFloat", g(t.fg, bg: t.panel)),
      ("FloatBorder", g(t.lineNr, bg: t.panel)), ("FloatTitle", g(t.fg, bg: t.panel, "bold = true")),
      ("Pmenu", g(t.fg, bg: t.panel)), ("PmenuSel", g(t.fg, bg: t.selection, "bold = true")),
      ("PmenuSbar", g(bg: t.panel)), ("PmenuThumb", g(bg: t.lineNr)),
      ("Visual", g(bg: t.selection)), ("Cursor", g(t.bg, bg: t.cursor)), ("CursorLine", g(bg: t.cursorLine)),
      ("CursorColumn", g(bg: t.cursorLine)), ("ColorColumn", g(bg: t.cursorLine)),
      ("LineNr", g(t.lineNr)), ("CursorLineNr", g(t.lineNrCurrent, "bold = true")), ("SignColumn", g(bg: t.bg)),
      ("FoldColumn", g(t.lineNr, bg: t.bg)), ("Folded", g(t.comment, bg: t.cursorLine)),
      ("Search", g(t.bg, bg: t.search)), ("IncSearch", g(t.bg, bg: t.search, "bold = true")), ("CurSearch", g(t.bg, bg: t.search, "bold = true")),
      ("MatchParen", g(t.bracket, bg: t.selection, "bold = true")),
      ("NonText", g(t.lineNr)), ("EndOfBuffer", g(t.lineNr)), ("Whitespace", g(t.lineNr)), ("SpecialKey", g(t.lineNr)),
      ("StatusLine", g(t.fg, bg: t.panel)), ("StatusLineNC", g(t.comment, bg: t.panel)), ("WinSeparator", g(t.lineNr)),
      ("TabLine", g(t.comment, bg: t.panel)), ("TabLineSel", g(t.fg, bg: t.bg, "bold = true")), ("TabLineFill", g(bg: t.panel)),
      ("Title", g(t.env, "bold = true")), ("Directory", g(t.command)), ("Question", g(t.ok)), ("MoreMsg", g(t.ok)),
      ("ErrorMsg", g(t.error)), ("WarningMsg", g(t.warn)), ("ModeMsg", g(t.fg, "bold = true")),
      ("Comment", g(t.comment, "italic = true")), ("Constant", g(t.math)), ("String", g(t.env)), ("Number", g(t.math)),
      ("Identifier", g(t.fg)), ("Function", g(t.command)), ("Statement", g(t.command)), ("Keyword", g(t.command)),
      ("PreProc", g(t.command)), ("Type", g(t.env)), ("Special", g(t.bracket)), ("Delimiter", g(t.bracket)),
      ("Underlined", g(t.command, "underline = true")), ("Todo", g(t.warn, "bold = true")), ("Error", g(t.error)),
      ("SpellBad", g(sp: t.error, "undercurl = true")), ("SpellCap", g(sp: t.warn, "undercurl = true")),
      ("SpellRare", g(sp: t.hint, "undercurl = true")), ("SpellLocal", g(sp: t.info, "undercurl = true")),
      ("DiffAdd", g(bg: blend(t.ok, t.bg, 0.18))), ("DiffDelete", g(bg: blend(t.error, t.bg, 0.18))),
      ("DiffChange", g(bg: blend(t.warn, t.bg, 0.14))), ("DiffText", g(bg: blend(t.warn, t.bg, 0.28))),
    ]
    for (name, c) in [("Info", t.info), ("Warn", t.warn), ("Ok", t.ok), ("Hint", t.hint), ("Error", t.error)] {
      out.append(("Diagnostic\(name)", g(c)))
      out.append(("DiagnosticSign\(name)", g(c, bg: t.bg)))
      out.append(("DiagnosticVirtualText\(name)", g(c, bg: blend(c, t.bg, 0.1))))
      out.append(("DiagnosticUnderline\(name)", g(sp: c, "undercurl = true")))
    }
    // LaTeX: vimtex / legacy syntax, then treesitter (generic captures and their .latex forms).
    let latex: [(String, UInt32, String)] = [
      ("texCmd", t.command, ""), ("texCmdPart", t.command, ""), ("texCmdEnv", t.command, ""), ("texCmdRef", t.command, ""),
      ("texStatement", t.command, ""), ("texSection", t.env, "bold = true"), ("texTitleArg", t.env, "bold = true"),
      ("texEnvArgName", t.env, ""), ("texBeginEndName", t.env, ""), ("texMathZone", t.math, ""), ("texMathZoneX", t.math, ""),
      ("texMathZoneTI", t.math, ""), ("texMathZoneTD", t.math, ""), ("texMathCmd", t.math, ""), ("texMathDelim", t.bracket, ""),
      ("texDelim", t.bracket, ""), ("texDelimiter", t.bracket, ""), ("texComment", t.comment, "italic = true"),
      ("texRefArg", t.env, ""), ("texFileArg", t.env, ""),
      ("@function.latex", t.command, ""), ("@function.macro.latex", t.command, ""), ("@function.builtin.latex", t.command, ""),
      ("@keyword.latex", t.command, ""), ("@keyword.import.latex", t.command, ""), ("@keyword.conditional.latex", t.command, ""),
      ("@markup.math", t.math, ""), ("@markup.math.latex", t.math, ""),
      ("@module.latex", t.env, ""), ("@label.latex", t.env, ""), ("@markup.environment.latex", t.env, ""),
      ("@markup.environment.name.latex", t.env, ""), ("@markup.link.latex", t.env, "underline = true"),
      ("@markup.link.label.latex", t.env, ""), ("@markup.heading.latex", t.env, "bold = true"),
      ("@markup.heading.1.latex", t.env, "bold = true"), ("@markup.heading.2.latex", t.env, "bold = true"),
      ("@markup.italic.latex", t.fg, "italic = true"), ("@markup.strong.latex", t.fg, "bold = true"),
      ("@punctuation.bracket", t.bracket, ""), ("@punctuation.delimiter", t.bracket, ""), ("@punctuation.special", t.bracket, ""),
      ("@punctuation.bracket.latex", t.bracket, ""), ("@punctuation.delimiter.latex", t.bracket, ""),
      ("@comment", t.comment, "italic = true"), ("@comment.latex", t.comment, "italic = true"),
      ("@string.latex", t.fg, ""), ("@variable.latex", t.fg, ""), ("@variable.parameter.latex", t.env, ""),
      ("@operator.latex", t.bracket, ""), ("@number.latex", t.math, ""),
    ]
    for (n, c, e) in latex { out.append((n, g(c, e))) }
    return out
  }

  static func blend(_ a: UInt32, _ b: UInt32, _ k: Double) -> UInt32 {
    func ch(_ c: UInt32, _ s: UInt32) -> Double { Double((c >> s) & 0xff) }
    func mix(_ s: UInt32) -> UInt32 { UInt32((ch(a, s) * k + ch(b, s) * (1 - k)).rounded()) << s }
    return mix(16) | mix(8) | mix(0)
  }

  /// Lua that applies `t` (or, for nil, restores the user's colourscheme). The user's scheme name is kept in
  /// `g:taudot_user_colors` the first time a theme replaces it.
  public static func apply(_ t: Theme?) -> String {
    let remember = """
    if vim.g.taudot_user_colors == nil and not tostring(vim.g.colors_name or ''):match('^taudot%-') then
      vim.g.taudot_user_colors = vim.g.colors_name or ''
      vim.g.taudot_user_background = vim.o.background
    end
    """
    guard let t else {
      return """
      local name = vim.g.taudot_user_colors
      if name == nil then return end
      vim.g.taudot_user_colors = nil
      if vim.g.taudot_user_background then vim.o.background = vim.g.taudot_user_background end
      if name ~= '' and pcall(vim.cmd.colorscheme, name) then return end
      vim.cmd('highlight clear'); vim.cmd('syntax reset'); vim.g.colors_name = nil
      vim.api.nvim_exec_autocmds('ColorScheme', { modeline = false })
      """
    }
    let sets = groups(t).map { "  set('\($0.0)', \($0.1))" }.joined(separator: "\n")
    return remember + """

    vim.o.background = '\(t.dark ? "dark" : "light")'
    vim.cmd('highlight clear')
    local function set(n, a) vim.api.nvim_set_hl(0, n, a) end
    \(sets)
    vim.g.colors_name = 'taudot-\(t.id)'
    vim.api.nvim_exec_autocmds('ColorScheme', { pattern = 'taudot-\(t.id)', modeline = false })
    """
  }
}
