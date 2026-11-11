# Taudot for Mac

A native Mac app: Neovim (embedded, the user's own config), the PDF beside it, and Overleaf's comments as cards in a
margin, all drawn by the app so everything moves by pixels at 120 Hz. The engine and the Neovim plugin stay as they
are; this replaces the Rex layout as the client, not the sync.

Why: the terminal draws text on a grid, so Neovim scrolls by whole lines and any panel is made of characters. The
user wants smooth scrolling and a clean, GUI-like review margin.

## Shape

```
┌──────────────────────── taudot ─────────────────────────┐
│ margin │ editor (Neovim grids)        │ PDF               │
│ cards  │ smooth scroll, cursor anim   │ tiles, pinch zoom │
└──────────────────────────────────────────────────────────┘
        │ msgpack-RPC (stdio)            │ txp-headless (stdin/stdout JSON)
   nvim --embed + taudot plugin         │ engine socket: doc.changed (live edits)
        │ JSON-RPC
   taudot engine (~/.taudot/engine.sock) ── Overleaf
```

- **Swift 6, AppKit, Core Animation / Metal, Core Text, no third-party packages.** SwiftPM package in `clients/mac`.
  `swift build` builds everything; `clients/mac/bundle.sh` makes `taudot.app`.
- **Neovim** runs as `nvim --embed`, attached with `ext_linegrid` and `ext_multigrid` (one grid per window, plus
  `win_viewport` with `scroll_delta`, which is what makes pixel-smooth scrolling possible, as Neovide does). The
  user's config loads as usual; the app adds `clients/nvim` to `runtimepath` and runs `:Taudot open <folder>`.
- **Review data comes through Neovim**, not straight from the engine: the plugin already holds threads, ranges and
  their buffer positions. `clients/nvim/lua/taudot/gui.lua` sends them to the app with `vim.rpcnotify` and takes
  actions back (reply, resolve, accept...) through `nvim_exec_lua`. One source of truth, no second connection.
- **The PDF** comes from TeXpresso (`clients/preview/texpresso/txp-headless`, protocol in its header comment), fed
  live edits from the engine (`doc.changed`, as `clients/preview/preview.ts` `feedFromEngine` does). Pages are drawn
  as tiles into layers; macOS gives real pinch and smooth trackpad scroll.

## Package layout and owners (round 4)

| Target | Folder | Owner | What |
|---|---|---|---|
| `TaudotNeovim` | `Sources/TaudotNeovim` | shell | msgpack, `nvim --embed`, the UI protocol, grids, the editor view |
| `TaudotPDF` | `Sources/TaudotPDF` | pdf | txp-headless client, engine feed, `PDFPaneView`, SyncTeX |
| `TaudotReview` | `Sources/TaudotReview` | margin | `ReviewMarginView`, cards, inline reply; `clients/nvim/lua/taudot/gui.lua` |
| `TaudotApp` | `Sources/TaudotApp` | shell | the window, wiring the three together, menus, `bundle.sh` |
| `PDFHost`, `ReviewHost` | `Sources/PDFHost`, `Sources/ReviewHost` | pdf, margin | small apps to build and test a pane alone |

`Package.swift` belongs to the coordinator; ask in your log under **Requests** for changes.

## Interfaces between the parts

Keep these in `Sources/TaudotShared/Contracts.swift` (coordinator owns it; propose changes as Requests). The
skeleton has the first version:

- `EditorGeometry` (shell implements, margin reads): for the current buffer, the y (in the editor view's points,
  fractional, following smooth scroll) of a buffer line's top, the line height, the visible line range, and a
  callback when any of it changes (every animation frame while scrolling).
- `ReviewModel` (margin): decoded from `gui.lua`'s notification `taudot_review`: per buffer, threads and tracked
  changes with `{id, kind, author, color, ts, quote, messages, line, col, end_line, end_col, resolved}`.
- `NeovimBridge` (shell implements, margin and pdf use): `notify(name, handler)` for `rpcnotify` events,
  `execLua(code, args) async -> Value`, `command(String)`.
- `PDFPane` (pdf): `jump(path, line)` (forward search: scroll to and flash the line), `onInverseSearch: (path, line)
  -> Void` (double-click on the PDF; the app calls `:Taudot` to open the file at that line).
- Outside edits (editfix item 9): both editors send `taudot_app_outside path edits author origin source` after a
  remote change is applied (Neovim's `taudot.app.outside`, called by the plugin; the native editor's NativeDoc), the
  edits in the buffer's byte offsets and after its `taudot_app_text`. `source` is the engine's (`"disk"`: the file
  was edited outside Taudot). The window keeps them in `OutsideEdits` (TaudotEditor): the sidebar's Changes tab, View ▸
  Follow Edits (waits 2 s after a key), the pill for an edit out of view, Undo through `taudot.app.replace`, and the
  PDF's fading marks (`TaudotPDFPane.markEdit`). A disk edit is "Claude" while the Claude pane's terminal wrote
  output in the last 20 s. The editors tint the text themselves (Neovim: the plugin's fade, disk edits in
  `disk_group`; native: `NativeEditorView.flash`). Check: `Tests/outside_check.sh FILE.tex neovim|native`.

## Bar

- Scrolling in the editor and the PDF: pixel-smooth, eased, 120 Hz on ProMotion, no dropped frames while typing.
- Typing: a key to glyph on screen within one frame of Neovim's `flush`.
- Margin cards line up with their text and move with it while scrolling, the same frame.
- Looks like a Mac app: system font for chrome, the user's colourscheme for the editor, light and dark.
