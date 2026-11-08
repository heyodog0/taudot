# Client design: Neovim with Rex flair

The owner is a heavy Neovim user and likes the look of Rex and Superlogical. The editor is the user's own Neovim with
their own config. Taudot adds to it and never replaces their keymaps, colourscheme or plugins.

## Neovim side (`clients/nvim`, Lua)

- Feels native: `:Taudot open`, `:Taudot comments`, `:Taudot status`, completion of subcommands, `<Plug>` mappings
  plus suggested defaults under `<leader>t`, `:checkhealth taudot`, a `doc/taudot.txt` help file.
- Buffers are normal buffers on the mirrored files, so LSP (texlab), treesitter, telescope and the user's motions work
  unchanged.
- Colours come from the user's colourscheme and terminal palette. Highlight groups link to existing groups
  (`DiagnosticInfo`, `DiffAdd`, `Comment`, …) and collaborator colours are picked from the terminal's ANSI palette, so
  everything matches the active Rex theme. No hard-coded hex values.
- Live edits: remote text appears in place, with an author colour that fades over about 3 s. Your own unconfirmed text
  gets a subtle underline until Overleaf confirms it.
- Collaborator cursors as virtual text with initials. Comments as highlights plus a sign; `K` on a comment opens the
  thread.
- Statusline component: connection state, unconfirmed edit count, who is online.

## Rex side

- `taudot open <project>` builds a Rex session: Neovim in the main pane, the PDF preview on the right, an activity
  float hidden until needed.
- **Program Status Protocol (OSC 7501).** The engine's panes report state with
  `ESC ] 7501 ; state=…:app=taudot:msg=<base64> ESC \`. Working while edits are unconfirmed, blocked when offline or
  read-only after a protocol mismatch, idle when in sync. Rex then shows a spinner or a blocked mark on the tab and in
  the session picker. Spec: https://www.superlogical.com/rex/docs/build/program-status.md
- **Floating layers** (`session.new_layer`) for the activity feed and comment threads, raised and lowered with Rex key
  bindings defined as custom actions in `~/.config/rex/init.lua`.
- **Preview pane** draws pages with the Kitty graphics protocol, updated in place by image ID.
- Rex's built-in themes live in `/Applications/Rex Beta.app/Contents/Resources/SuperUI_SuperDesignTokens.bundle/
  Contents/Resources/themes.json` (background, foreground, cursor, 16 ANSI colours each). Terminal programs like the
  activity float use the 16 ANSI colours only, so they follow the theme.
- Visual tone: quiet, dense, keyboard first. Thin borders, no boxes inside boxes, one accent colour (the theme's cursor
  colour) for "needs you".
