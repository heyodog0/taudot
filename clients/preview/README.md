# preview

Live PDF preview for a Rex pane (or any terminal with the Kitty graphics protocol), meant to feel like a PDF viewer.

```sh
deno run -A preview.ts --folder ~/papers/grid          # watch, compile, draw
deno task test
```

It watches the folder and recompiles with `tectonic` 400 ms after the last change. A new change kills a running
compile, unless changes have kept coming for over a second; then the compile finishes so the page still updates
while you type. A failed compile keeps the last good pages and shows the first LaTeX error in red below them.

Pages are one continuous strip, fit to the pane's width. Each page is rendered by `render/pdfrender` (a persistent CoreGraphics renderer, ~4x less CPU per tile than a
pdftoppm process; built with `render/build.sh`, else `pdftoppm` is used) and kept in memory as RGB, and sent as one Kitty image per page, zlib-compressed (level 1, in a worker so the main thread stays free) and
by file path when the terminal can read files (`t=f`, probed at start). `bench-transfer.ts` measures why: Rex takes a
zlib file of a 1653×2139 page in 2.7 ms, the raw RGB file in 7.7 ms, the PNG file in 29 ms. At rest every page is placed unscaled, cropped and positioned to the pixel, so text is sharp, and
a scroll frame is a few hundred bytes. **Scrolling** (wheel, trackpad with momentum, keys, forward search) moves a
target, and the view eases toward it at ~60 fps (exponential, time constant 30 ms, ~90 ms to settle); isolated wheel
events (mouse notches) step two lines, a stream (trackpad) about one. Drag-pan follows the pointer directly. Renders,
prefetch, crop re-renders (started before the view reaches a crop's edge) and the snapshot build all run off the
frame path.

**Zoomed in** (a page whose full render at the view's scale would pass 4 MP): pages become 512×512 **tiles** at the
view's scale, like a PDF viewer. Tiles in view and one ring around them are rendered (one pdftoppm call per page for
the box of missing tiles, cut up in memory), sent once as zlib files, cached by (page, scale, tile) and placed
unscaled, each with its own source rectangle; scrolling sends only the small tiles coming into view. Under them each
page has an underlay (the whole page at ≤ 2 MP, placed scaled, z=-1) that shows wherever a tile is still missing.

**Zoom** (Ctrl+wheel, Option+wheel, `+` `-`, pinch through `clients/rex/pinch`): when a zoom starts, the preview
composites one RGBA **snapshot** from the page bitmaps it already has (≤ 3 MP, nothing is sent while idle). Zooming in:
the view at up to 2x, from 2x bitmaps rendered in memory while idle. Zooming out: the view plus a wide margin at 0.7x,
rebuilt wider if the zoom outgrows it. Until it is in the terminal (about 30–50 ms) the screen holds still. A zoom shows only that snapshot, placed in a fixed box the size of the whole pane, and changes nothing but its
source rectangle, which is pixel-continuous: no cell snapping, no wobble. Wheel steps (6% each) and keys set a target
that the view eases toward at about 60 fps (time constant 40 ms), so steps blend; a pinch is applied as it comes.
Zooming out past the snapshot's edges shows the background there. About 150 ms after the last wheel event, or when a
pinch ends, the pages are rendered sharp at the new scale and replace the snapshot in one synchronized-output frame at
the same geometry. Pages near the view are prefetched; images far from it are freed.

## Mouse and keys

| Input | Does |
|---|---|
| wheel, trackpad scroll | scroll (shift or a horizontal wheel: sideways) |
| Ctrl+wheel or Option(Alt)+wheel, pinch (with `clients/rex/pinch`) | zoom at the pointer |
| two-finger double-tap (with `clients/rex/pinch`) | toggle fit width and the last zoom |
| drag | pan |
| double-click | Neovim jumps to that source line (SyncTeX) and gets focus |
| `j` `k` `h` `l`, arrows, Ctrl-d Ctrl-u | scroll a fifth or half of the pane |
| `J` `K` (`n` `p`, space, PgDn PgUp) | next, previous page |
| `gg` `G` | first, last page |
| `+` `-`, `0` or `w`, `f` | zoom in, out, fit width, fit page |
| `r` `q` | recompile, quit |

`mouse-probe.ts` shows which mouse events and modifiers the terminal passes through: run it in a pane and try them.

Mouse reporting is SGR with pixel coordinates (modes 1002, 1006, 1016). The status line shows page, zoom, state
(`compiling` yellow, `ok` green, `error` red), `nvim` when Neovim is linked, main file and compile time, in the 16
ANSI colours. OSC 7501: `working` while compiling, `blocked` with the error, `idle` with the page count.

## SyncTeX and Neovim

tectonic writes `.synctex.gz` with every compile; `synctex.ts` reads it (no `synctex` binary needed). With
`--listen SOCK` the preview accepts connections from the Neovim plugin (`clients/nvim/lua/taudot/preview.lua`),
which sends `{"cursor": {"path", "line"}}` when its cursor rests on a line. The preview scrolls there if the line is
out of view (not while you are scrolling the PDF) and marks it with a fading band in the terminal's cursor colour.
A double-click sends `{"jump": {"path", "line"}}` back and runs `rex focus` on `--editor-block`.

## Flags

| Flag | Meaning |
|---|---|
| `--folder DIR` | Project folder to watch |
| `--main FILE` | Main file, default `main.tex`, else the first `.tex` with `\documentclass` |
| `--out DIR` | Build folder, default `$TMPDIR/taudot-preview-<hash of folder>`. Never inside the project, so build files never reach the engine's mirror |
| `--debounce MS` | Quiet time before compiling, default 400 |
| `--listen SOCK` | (or `$TAUDOT_PREVIEW_SOCKET`) Socket for the Neovim link. Unix socket paths must stay under ~100 bytes |
| `--editor-block BLOCK` | (or `$TAUDOT_EDITOR_BLOCK`) Rex block to focus after a double-click |
| `--trace FILE` | (or `$TAUDOT_PREVIEW_TRACE`, which `taudot-layout.sh` passes on) Append JSON lines: `change`, `compile_start`, `compile_end`, `rendered`, `drawn`, `frame` (build time, bytes, time since the input), `mouse_kind` (each kind of mouse event once), `forward`, `inverse`, `size`, `caps` |
| `--tectonic PATH` | Compiler binary |
| `--engine texpresso` | Typeset with TeXpresso (incremental, ~50–100 ms from keystroke to frame) instead of tectonic; see `texpresso/README.md` |
| `--taudot-socket SOCK` | (or `$TAUDOT_SOCKET`) With `--engine texpresso`: take the engine's live edits (`doc.changed`) instead of file saves |
| `--fps N` | Animation rate, default 60; 120 on ProMotion when the terminal presents it (Ghostty; Rex when the machine is quiet) |
| `--render-while-moving` | Turn off quiet motion (by default nothing is rendered or sent while the view moves; prefetch happens while idle) |
| `--da1` | After frames and snapshots, send DA1 and trace how long the terminal took to answer (`da1` events) |

The pane size comes from `CSI 16t` (cell size in pixels) and the terminal size, asked again on `SIGWINCH`. A Rex
pane that no app is showing reports 80×24 with 8×16 cells, and gets its real size (and a `SIGWINCH`) once an app shows
it.
