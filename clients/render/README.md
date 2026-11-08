# clients/render: Taudot's own drawing layer

The renderer project: a vector display list from TeXpresso's DVI interpreter, drawn
with Core Graphics, measured against today's MuPDF raster on a corpus of real papers.

| path | what | owner |
|---|---|---|
| `txp-render.c` | txp-headless plus our verbs (includes `../preview/texpresso/txp-headless.c` whole) | coordinator |
| `build.sh` | builds `txp-render` like the preview's `build.sh` | coordinator |
| `glyphs.c` | `["glyphs", id, page, path]`: a page's glyphs with boxes, text and source lines | cursor |
| `cursor/` | Swift package `TaudotCursor`: source position → caret rect on the page | cursor |
| `dlist.c`, `dlist.md` | `["dlist", id, page, path]`: a page's vector display list, and its format | backend |
| `swift/` | Swift package `TaudotRender` (reads and draws a list) and `taudot-raster` (list → PNG) | backend |
| `rt/` | Taudot's drawing runtime under the interpreter (no MuPDF): errors, geometry, paths, text, devices, display lists; images, figures and CMYK in `rt/apple.c` | nomupdf |
| `fonts/` | the FreeType font loader the runtime uses | nomupdf (was engine) |
| `harness/` | corpus, oracle renders, diffs, scores, `harness/run` | harness |

`txp-render` speaks the whole txp-headless protocol (`clients/preview/texpresso/txp-headless.c`, its header), so a
client can switch binaries without other changes. Verbs answer on stdout as one JSON object per line.
