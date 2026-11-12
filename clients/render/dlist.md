# Taudot display list (TDL), version 2

A page as vector drawing ops, made by `txp-render`'s `["dlist", id, page, path]` (`dlist.c`, a recording device
over the interpreter's page list in `rt/`) and drawn by the Swift package `TaudotRender` (`swift/`).

## The verb

    ["dlist", id, page, path]
    → {"id":ID,"ok":true,"bytes":N,"ops":K,"fonts":F,"us":T}
    → {"id":ID,"ok":false,"error":"..."}

`T`: µs to make and write the list, typesetting included. Font files go to `$TMPDIR/taudot-fonts/<hash>.<ext>`,
once per process, named by content and never deleted by txp-render.

## Frame

PDF points, origin top-left, **y down** (as `render` at scale 1 and `glyphs`); Core Graphics flips with
`translate(0, h·s)`, `scale(s, −s)`. Matrices are `a b c d e f`: `(x, y)` → `(a·x + c·y + e, b·x + d·y + f)`.

## Encoding

Little-endian, packed, no padding. `u8 u16 u32 f32` as usual; `str` is `u16 length` + UTF-8.

    "TDL\0"  u32 version (= 2)
    record*  u8 kind, u32 length, payload[length]

Readers skip unknown kinds. `END` is last; `PAGE`, `FONT` and `IMAGE` precede the ops using them. Version 2 adds
SHADE (0x16) to version 1.

`bbox` is `f32 x0 y0 x1 y1`, ink bounds in page space (a clip's: its area). `rgba` is 4 × `f32` sRGB, 0–1, not
premultiplied; every colour space is converted to sRGB.

### Paths

    path := u32 ncmd, u32 ncoord, u8 cmd[ncmd], f32 coord[ncoord]

`cmd` is `M` (2 coords), `L` (2), `Q` (4), `C` (6) or `Z` (0); rectangles are `M L L L Z`. The op's matrix maps
path space to the page.

### Stroke state

    stroke := f32 width, u8 cap, u8 join, f32 miter, f32 dash_phase, u16 ndash, f32 dash[ndash]

`cap`: 0 butt, 1 round, 2 square, 3 triangle (drawn as round). `join`: 0 miter, 1 round, 2 bevel. Width is in path
space.

## Records

| kind | name | payload |
|---|---|---|
| 0x00 | END | (none) |
| 0x01 | PAGE | `u32 page, f32 w, f32 h` |
| 0x02 | FONT | `u32 id, u8 type, str name, ...` (below) |
| 0x03 | IMAGE | `u32 id, u32 w, u32 h, u8 format, u32 n, u8 bytes[n]` (below) |
| 0x10 | TEXT | `bbox, u8 mode, rgba, [stroke if mode = 1], u32 font, f32 m[4], u32 n, glyph[n]` |
| 0x11 | FILL | `bbox, u8 even_odd, rgba, f32 m[6], path` |
| 0x12 | STROKE | `bbox, rgba, f32 m[6], stroke, path` |
| 0x13 | RULE | `bbox, rgba`: fill the bbox (a TeX rule or axis-aligned rectangle) |
| 0x14 | DRAW_IMAGE | `bbox, f32 alpha, f32 m[6], u32 image`: `m` maps the unit square (origin: the image's top-left) to the page |
| 0x15 | IMAGE_MASK | `bbox, rgba, f32 m[6], u32 image`: fill with `rgba` through the image's alpha (a stencil) |
| 0x16 | SHADE | `bbox, u8 type (2 axial, 3 radial), u8 extend0, u8 extend1, f32 coords[6] (x0 y0 r0 x1 y1 r1), f32 m[6] (shading space → page), f32 sbox[4] (shading space; empty: none), f32 alpha, u16 n, u8 rgba[n][4]`: colour at t = i/(n−1). Under the current clip |
| 0x17 | FIGURE | `bbox, f32 m[6] (the figure's PDF space → page), f32 box[4] (its crop box, PDF space), u32 page (1-based), str path`: an included PDF page, drawn by Core Graphics, clipped to `box` |
| 0x20 | CLIP_PATH | `bbox, u8 even_odd, f32 m[6], path` |
| 0x21 | CLIP_STROKE | `bbox, f32 m[6], stroke, path` |
| 0x22 | CLIP_IMAGE_MASK | `bbox, f32 m[6], u32 image` |
| 0x2f | POP_CLIP | `bbox` (empty): ends the innermost clip, text clip or mask |
| 0x30 | BEGIN_GROUP | `bbox, u8 isolated, u8 knockout, u8 blend, f32 alpha` |
| 0x31 | END_GROUP | `bbox` |
| 0x32 | BEGIN_MASK | `bbox, u8 luminosity, f32 backdrop[3]`: ops up to END_MASK draw the soft mask |
| 0x33 | END_MASK | `bbox`: up to the matching POP_CLIP is drawn through the mask |
| 0x34 | BEGIN_TILE | `bbox, f32 area[4], f32 view[4], f32 xstep, f32 ystep, f32 m[6]` |
| 0x35 | END_TILE | `bbox` |
| 0x36 | BEGIN_TAG | `bbox, str what`: up to END_TAG is one thing, e.g. `figure:fig.pdf` (reserved) |
| 0x37 | END_TAG | `bbox` |
| 0x3f | UNSUPPORTED | `bbox, str what`: drawn as a magenta bbox |

`blend` is the PDF blend mode number (0 Normal, 1 Multiply, 2 Screen, 3 Overlay, 4 Darken, 5 Lighten, 6 ColorDodge,
7 ColorBurn, 8 HardLight, 9 SoftLight, 10 Difference, 11 Exclusion, 12 Hue, 13 Saturation, 14 Color, 15 Luminosity).

### TEXT

`mode`: 0 fill, 1 stroke, 2 both, 3 clip (popped by POP_CLIP), 4 invisible (selection and search). Em-unit outlines
map to the page by `[m0 m1 m2 m3 x y]`.

    glyph := u32 gid, f32 x, f32 y, f32 adv, str text

`x y`: the glyph's exact origin on the page (SyncTeX's page position). `adv`: advance in page points. `text`: Unicode
from the glyph name (ligatures carry their letters, "ffi"); "" continues the previous glyph, "�" is unknown.

### FONT

    type 1, sfnt:      str path, u32 index
    type 2, outlines:  u32 n, (u32 gid, path)[n]
    type 3, missing:   (none)

- **sfnt**: a file Core Text loads (`CGFont`), face `index`, the file's glyph ids; scale by 1/unitsPerEm.
- **outlines**: what Core Text can't load (Type 1, bare CFF): the page's glyphs, in em units.
- **missing**: Type 3. An invisible TEXT run (for selection and search), then the ops its glyphs draw (`d1` glyphs
  in the run's colour).

Each list carries every font it uses.

### IMAGE

`format`: 1 PNG, 2 JPEG (the file's own bytes), 3 raw RGBA8 (`w·h·4` bytes, not premultiplied). An image used twice
on a page is defined once.

## Debugging

`taudot-raster LIST --dump` prints the list as JSON, one op per line.

## Not yet

- Function-based and mesh shadings (types 1, 4–7): UNSUPPORTED.
- Fonts once per session, not per page (16 % of the lists on a 32-page paper, 43 KB a page).
- Stable op ids across edits, for animated reflow and redrawing only what changed.
- BEGIN_TAG/END_TAG around included figures.
