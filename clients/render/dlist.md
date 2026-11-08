# Taudot display list (TDL), version 2

A page as vector drawing ops, made by `txp-render`'s `["dlist", id, page, path]` (`dlist.c`) and drawn by the Swift
package `TaudotRender` (`swift/`). The format names no MuPDF type: Phase A records MuPDF's device calls into it,
Phase B makes it straight from the DVI interpreter, and the reader doesn't change.

## The verb

    ["dlist", id, page, path]
    → {"id":ID,"ok":true,"bytes":N,"ops":K,"fonts":F,"us":T}
    → {"id":ID,"ok":false,"error":"..."}

`path` gets the list. `T` is µs to make and write it, including typesetting the page if it wasn't cached. Font files
the list references (below) are written once per process to `$TMPDIR/taudot-fonts/<hash>.<ext>` (by content, so
they survive across runs) and never deleted by txp-render.

## Frame

PDF points, origin at the page's top-left corner, **y down**: the frame of `render` at scale 1 and of the `glyphs`
verb. A drawer flips for Core Graphics (`translate(0, h·s)`, `scale(s, −s)`).

Matrices are 6 floats `a b c d e f`, mapping `(x, y)` to `(a·x + c·y + e, b·x + d·y + f)` (PDF and Core Graphics
order).

## Encoding

Little-endian, packed, no padding. `u8 u16 u32 f32` as usual; `str` is `u16 length` + UTF-8 bytes.

The file is a magic and a stream of records:

    "TDL\0"  u32 version (= 2)
    record*  u8 kind, u32 length, payload[length]

Every record carries its payload length, so a reader skips kinds it doesn't know. The last record is `END`.
Records that define things (`PAGE`, `FONT`, `IMAGE`) come before the ops that use them.

Common op prefix, written `bbox` below: `f32 x0 y0 x1 y1`, the op's ink bounds in page space (clipped content
included; a clip's bbox is its clip area). `rgba` is 4 × `f32` in sRGB, 0–1, alpha not premultiplied: the producer
converts every colour space (Gray, CMYK, ICC, Separation...) to sRGB as the oracle does.

### Paths

    path := u32 ncmd, u32 ncoord, u8 cmd[ncmd], f32 coord[ncoord]

`cmd` is `M` (2 coords), `L` (2), `Q` (4), `C` (6) or `Z` (0). Rectangles arrive as `M L L L Z`. Coordinates are in
the path's own space; the op's matrix maps them to the page.

### Stroke state

    stroke := f32 width, u8 cap, u8 join, f32 miter, f32 dash_phase, u16 ndash, f32 dash[ndash]

`cap`: 0 butt, 1 round, 2 square, 3 triangle (drawn as round). `join`: 0 miter, 1 round, 2 bevel. The width is in
path space: the matrix scales it.

Version 2 (2026-11-03) adds SHADE (0x16). Readers of version 1 lists skip nothing: the version only says SHADE may occur.

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
| 0x13 | RULE | `bbox, rgba`: fill the bbox (a TeX rule, or any axis-aligned filled rectangle) |
| 0x14 | DRAW_IMAGE | `bbox, f32 alpha, f32 m[6], u32 image`: `m` maps the unit square to the page, (0, 0) the image's top-left |
| 0x16 | SHADE | `bbox, u8 type (2 axial, 3 radial), u8 extend0, u8 extend1, f32 coords[6] (x0 y0 r0 x1 y1 r1), f32 m[6] (shading space → page), f32 sbox[4] (shading space; empty: none), f32 alpha, u16 n, u8 rgba[n][4]`: the colour at t = i/(n−1), sRGB, not premultiplied. Painted under the current clip. Function-based and mesh shadings stay UNSUPPORTED |
| 0x17 | FIGURE | `bbox, f32 m[6] (the figure's PDF space → page), f32 box[4] (its crop box, PDF space), u32 page (1-based), str path`: a page of an included PDF file, drawn whole (Core Graphics) clipped to `box`. Since 2026-11-06 (no PDF interpreter in txp-render); readers that don't know it skip it |
| 0x15 | IMAGE_MASK | `bbox, rgba, f32 m[6], u32 image`: fill with `rgba` through the image's alpha (a stencil) |
| 0x20 | CLIP_PATH | `bbox, u8 even_odd, f32 m[6], path` |
| 0x21 | CLIP_STROKE | `bbox, f32 m[6], stroke, path` |
| 0x22 | CLIP_IMAGE_MASK | `bbox, f32 m[6], u32 image` |
| 0x2f | POP_CLIP | `bbox` (empty): ends the innermost clip, text clip or mask |
| 0x30 | BEGIN_GROUP | `bbox, u8 isolated, u8 knockout, u8 blend, f32 alpha` |
| 0x31 | END_GROUP | `bbox` |
| 0x32 | BEGIN_MASK | `bbox, u8 luminosity, f32 backdrop[3]`: ops up to END_MASK draw the soft mask |
| 0x33 | END_MASK | `bbox`: what follows, up to the matching POP_CLIP, is drawn through the mask |
| 0x34 | BEGIN_TILE | `bbox, f32 area[4], f32 view[4], f32 xstep, f32 ystep, f32 m[6]` |
| 0x35 | END_TILE | `bbox` |
| 0x36 | BEGIN_TAG | `bbox, str what`: what follows, up to END_TAG, is one thing, e.g. `figure:fig.pdf` (reserved: not emitted yet) |
| 0x37 | END_TAG | `bbox` |
| 0x3f | UNSUPPORTED | `bbox, str what`: a drawer paints the bbox magenta, so it shows in the diff |

`blend` is the PDF blend mode number (0 Normal, 1 Multiply, 2 Screen, 3 Overlay, 4 Darken, 5 Lighten, 6 ColorDodge,
7 ColorBurn, 8 HardLight, 9 SoftLight, 10 Difference, 11 Exclusion, 12 Hue, 13 Saturation, 14 Color, 15 Luminosity).

### TEXT: a glyph run

`mode`: 0 fill, 1 stroke, 2 fill and stroke, 3 clip (the glyphs become a clip, popped by POP_CLIP), 4 invisible
(drawn nowhere; kept for text, selection and search). `m` is the 2×2 part of glyph space → page: a glyph's outline
in em units (FONT below) maps to the page by `[m0 m1 m2 m3 x y]`.

    glyph := u32 gid, f32 x, f32 y, f32 adv, str text

`x y` is the glyph's origin on the page (exact, not accumulated from advances). `adv` is its advance in page points
along the baseline. `text` is its Unicode text, from the glyph name (ligatures carry their letters, "ffi"); "" for a
glyph that continues the previous one's text, "�" when unknown. The origin is what SyncTeX takes for a page
position.

### FONT

    type 1, sfnt:      str path, u32 index
    type 2, outlines:  u32 n, (u32 gid, path)[n]
    type 3, missing:   (none)

- **sfnt**: an OpenType (CFF or TrueType) or TrueType collection file Core Text loads (`CGFont`), face `index`. Glyph
  ids are the file's. Units per em are the font's own; the drawer scales by 1/unitsPerEm to em units.
- **outlines**: everything Core Text can't load (Type 1, bare CFF from PDF figures): the outlines, in em units, of
  the glyphs this page uses. A drawer fills them with the run's matrix.
- **missing**: no outlines (Type 3). The producer writes each Type 3 run as an invisible TEXT run (its text, for
  selection and search) followed by the ops the glyphs draw (FILL, STROKE...), uncoloured (`d1`) glyphs in the
  run's colour.

Each page's list carries every font it uses, so a list stands alone.

### IMAGE

`format`: 1 PNG, 2 JPEG (the file's own bytes, passed through), 3 raw RGBA8 (`w·h·4` bytes, not premultiplied).
An image used twice on a page is defined once.

## Debugging

`taudot-raster LIST --dump` prints the list as JSON, one op per line.

## Not yet (version 1 leaves out)

- Function-based and mesh shadings (types 1, 4–7): UNSUPPORTED.
- PDF figures as a reference (file, page, matrix) for `CGPDFDocument`: in Phase A an included PDF arrives as the
  ops MuPDF ran for it. Phase B, which owns the `\includegraphics` special, can emit a FIGURE op instead.
- Fonts sent once per session rather than once per page. On the PaperA copy fonts are 16 % of the lists (1.37 of
  8.49 MB over 32 pages, 43 KB a page), so this can wait.
- Stable op ids across edits, so an old and a new list can be matched for animated reflow and redrawing only what
  changed.
- BEGIN_TAG/END_TAG around included figures (needs the `\includegraphics` special: Phase B).
