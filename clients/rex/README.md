# Taudot in Rex

```sh
clients/rex/taudot-layout.sh ~/papers/grid          # build the session and show it
clients/rex/taudot-layout.sh --toggle-activity      # show or hide the activity float
clients/rex/taudot-layout.sh --close                # close the session and its mock engine
```

What it builds, in a new session `taudot-<folder>`:

- Tab **editor**: Neovim on `main.tex` with the plugin from `clients/nvim` loaded after your own config, and on the
  right the PDF preview (`clients/preview`): it recompiles with tectonic on every change the engine writes to the
  folder and draws the pages with Kitty graphics. Wheel scrolls, Ctrl+wheel zooms (a pinch is Rex's pane zoom), double-click jumps Neovim to the
  line (SyncTeX), and moving in Neovim scrolls the preview. Keys too: `J`/`K`, `+`/`-`, `gg`/`G`.
- A floating **activity** feed, created with `session.new_layer` and then detached, so it starts hidden but keeps
  running. Showing it puts the block back beside the editor and floats it (`move_block`, `float_block`); hiding it
  detaches it again. Rex has no call to hide a layer, so this is how "hidden" works.
- Tab **engine**: when no engine is running, the mock engine with its bot on a private socket. Its log shows every
  applied edit, yours as `ME`.

The activity pane reports the sync state with OSC 7501: `idle` "in sync, with AL", `working` while edits are
unconfirmed, `blocked` when the engine is offline, unreachable or read-only. The preview pane reports the compile:
`working` while compiling, `blocked` with the first LaTeX error, `idle` otherwise. Rex shows it on the tab and in the
session picker. Read it back with `rex block call -b <block> program_status`.

`activity.ts` uses only the 16 ANSI colours, so it follows the Rex theme. IDs of the session's panes are kept in
`~/.taudot/rex/<session>.json`.

## A key for the activity float

In `~/.config/rex/init.lua` (then `rex config reload`):

```lua
rex.action{
  name  = "taudot_activity",
  title = "Taudot: Toggle Activity",
  run   = function(ctx)
    local r, err = rex.exec({ os.getenv("HOME") .. "/code/lab/taudot/clients/rex/taudot-layout.sh",
                              "--toggle-activity", ctx.session_id })
    if not r then error(err, 0) end
  end,
}
rex.bind("cmd+shift+a", "taudot_activity")
```
