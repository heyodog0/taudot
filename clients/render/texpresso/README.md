# clients/render/texpresso: our patches to TeXpresso

Taudot builds upstream TeXpresso (`github.com/let-def/texpresso`, MIT, © 2023 Frédéric Bour) at a pinned commit,
`e8df770`, plus the patch series here.

    sh clients/render/texpresso/apply.sh DIR     # clone if missing, check out the pin, apply the series
    make -C DIR -j8 all                          # build/texpresso-xetex and the frontend objects
    TEXPRESSO_DIR=DIR sh clients/render/build.sh # txp-render against it

`apply.sh` rebuilds branch `taudot` in DIR from the pin each run (it refuses if DIR has uncommitted changes), and
`git am`s every `patches/*.patch` in order with fixed identity and dates, so the resulting commit is the same on
every machine. `TEXPRESSO_URL` overrides the clone source. When the resulting commit differs from the one recorded in `DIR/build/.taudot-head`
(the last run), `apply.sh` removes `DIR/build`: TeXpresso's Makefiles don't track headers, so an incremental
`make` after a header change leaves stale objects (a segfaulting txp-render). The next `make all` rebuilds from
scratch.

| patch | what |
|---|---|
| `0001` | `engine_tex.c`: the snapshot interval as the macro `TXP_SNAPSHOT_MS` (default 500), so the drivers' `build.sh` can set it. Replaces the `sed` in `install.sh`. |
| `0002` | `dvi_special`: handle `x:gsave`, `x:grestore` and plain `pdf:literal`, which graphicx's `xetex.def` uses to clip a PDF figure (`trim=`/`viewport=` with `clip`). TeXpresso dropped them, so the whole figure was drawn over the text around it. Written outside the re2c rules, so it is the same edit in `dvi_special.re2c.c` and the generated `dvi_special.c` (no re2c needed). Test: `tests/clip/`. |
| `0003` | `main.c`: the standalone engine's `ttstub_input_seek` returns the new offset (Tectonic's contract), not `fseek`'s 0. Without it every PDF failed to load when `texpresso-xetex` ran on its own ("Error while parsing PDF file"); under the driver it already worked. Needed to test the engine without a driver. |
| `0004` | **dvipdfmx out of `texpresso-xetex`.** New `src/engine/engine/taudot-pic.{c,h}` (ours, MIT) answers what `xetex-pic.c` asked dvipdfmx (GPL): PDF page count and page boxes (box fallback, clamp to the MediaBox, `/Rotate`) through Core Graphics, and JPEG/PNG/BMP pixel size and resolution from their headers. `xetex-ini.c` loses `pdf_files_init/close`; the Makefile drops `dpx/` and libpng. Core Graphics aborts in a forked process (the engine forks at every snapshot), so PDFs are read by the engine re-run as `texpresso-xetex -taudot-pdfinfo` (one process per new figure/page/box; the driver caches the answer). macOS only: other platforms fail to compile with a message. Tests: `tests/pics/`, `tests/xdv/`. |
| `0005` | **Fonts of the TeX bundle by name** (`\setmainfont{Latin Modern Roman}`). On macOS XeTeX looks names up through Core Text, which only knows installed fonts, so fontspec found nothing and pages came out in nullfont (also true of plain Tectonic). New `src/engine/layout/taudot-fonts.{h,cpp}` (ours, MIT) and the generated `taudot-fontindex.c` (names, OS/2, head, post and GPOS `size` data of all 2,211 faces of the bundle with digest `6ffe0558…`): `XeTeXFontMgr::findFont` first adds them to its caches with the attributes XeTeX would read (no font is opened), so XeTeX's own rules choose (family, Regular, /B /I, optical size) and the bundle wins over an installed font of the same name, as on Overleaf; the chosen font is loaded as `[file:index]`. If the bundle's `SHA256SUM` isn't the indexed one, nothing changes. Regenerate the index with `fonts/make_index.py` when the bundle changes. Test: `tests/fonts/`. |
| `0006` | `build/taudot-pdfinfo`: the Core Graphics half of `taudot-pic.c` built as a 35 KB program (links only CoreGraphics/CoreFoundation). The engine runs it for PDF boxes when it's next to `texpresso-xetex`, else runs itself as before. Starting the engine binary cost ~35 ms of each ~38 ms lookup; the small helper takes ~18 ms. **Ship it beside `texpresso-xetex`.** |
| `0101` | (interp agent) `dvi_special`: allocate the stroke state with room for the dash array. MuPDF 1.28's `fz_stroke_state` ends in a flexible array, so the old stack copy overflowed on any dash and the fortify check killed txp-render with SIGTRAP (arXiv 1312.6114). Also: `B*` stroked in the fill colour, and the miter limit was cut to an integer. Same edit in `.re2c.c` and `.c`. Test: `tests/dash/`. |
| `0102` | (interp agent) Opacity. `pdf:put` dictionaries that set `/ca`/`/CA` are remembered by name (all pages); the `gs` operator sets fill and stroke alpha, falling back to the value in PGF's own names (`pgf@ca0.5`) for a page drawn before the one that put them. Fills, strokes, rules, text and images use them; `B`/`B*`/`b`/`b*` with transparency paint as a knockout pair, as in PDF. Form XObjects (`pdf:bxobj`/`exobj`/`uxobj`, PGF's transparency groups) are recorded as display lists and replayed at `uxobj` inside a group with the current alpha. **Changes `mydvi.h`**: TeXpresso's Makefile doesn't track headers, so delete `build/frontend` before `make` (or the objects disagree on `dvi_context` and txp-render crashes). Test: `tests/opacity/`. |
| `0103` | (interp agent) CMYK colours (color specials, `pdf:code k`/`K`, xcolor's named CMYK colours) go through MuPDF's colour management, as mutool draws them, instead of `1 - c - k`: xcolor's `yellow` is 255 241 0, not 255 255 0. Adds `ctx` to the colour parsers. Test: `tests/cmyk/`. |
| `0104` | (interp agent) The page's graphics state starts at PDF's line width 1 and miter limit 10. It started zeroed, so every mitered corner (TikZ rectangles, arrows) was drawn as a bevel. Test: `tests/cmyk/` (its stroked squares). |
| `0105` | (interp agent) Tiling patterns (`\usetikzlibrary{patterns}`). `pdf:stream @obj (content) << /PatternType 1 … >>` and `pdf:put @pgfpatterns << /pgfpat3 @obj >>` are kept for the document; `sc`/`scn` with a pattern name set a pattern fill (with the colour of an uncoloured pattern), `cs`/`CS`/`SC`/`SCN` are handled, and `g`/`rg`/`k` end it. A pattern fill clips to the path and repeats the cell's content over it in the page's default space (`pdf:pagesize` gives its height). TeXpresso filled them solid black. A page drawn before the one that defines its pattern gets a 25 % tint instead. Test: `tests/pattern/`. |
| `0106` | (interp agent) Shadings (`\shade`, `top color`/`left color`/`ball color`, shaded nodes). `pdf:put` dictionaries with `/ShadingType 2` (axial) or `3` (radial) are read with a small PDF object reader; their function (type 2, or type 3 stitching type 2s, or one per component) is sampled into MuPDF's 256-entry table, and `sh` fills the shade. PGF wraps each shading in a form drawn with a `cm` that stretches or turns it, so forms (0102) are now replayed under inverse(CTM at `bxobj`) × CTM at `uxobj`, not just shifted. Test: `tests/shading/`. |
| `0107` | (interp agent) `x:scale SX SY`, graphicx's `\scalebox{sx}[sy]` and `\resizebox` under xetex.def. TeXpresso's rule takes one factor, so it scaled both axes by the first and dropped the rest. Handled before the re2c rules (no re2c needed). Test: `tests/scale/`. |
| `0108` | (interp agent) `pdf:literal direct`: PDF code relative to the DVI origin (dvipdfmx starts each page with `1 0 0 1 72 720 cm`), under any `btrans` transforms; it was dropped. `pdf:content`: at the current point inside `q`/`Q`; it was dropped. `pdf:direct`, `pdf:page` and `pdf:literal page` stay undrawn, as in Tectonic's dvipdfmx. Test: `tests/literal/`. |

Tests: `tests/<name>/`, each saying what to compare. `tests/compare.py tests/<name>` draws it with txp-render and
with `mutool` from Tectonic's PDF at the same scale and counts pixels off; `tests/same.py OLD NEW DIR MAIN` checks two
txp-render builds draw a document identically.

- `tests/clip/`: clipped figures (0002).
- `tests/dash/`: dashed strokes (0101).
- `tests/opacity/`: fill, draw and text opacity, a knockout fill+stroke, scopes and a transparency group (0102).
- `tests/cmyk/`: CMYK text, boxes, fills and strokes (0103), and mitered corners (0104).
- `tests/pattern/`: TikZ patterns, uncoloured and default, over fills and text (0105).
- `tests/shading/`: axial, rotated axial, radial, ball, a shaded node and `\shadedraw` (0106).
- `tests/scale/`: `\scalebox` with two factors, mirroring, `\resizebox`, `\rotatebox`, and both (0107).
- `tests/literal/`: `pdf:literal` at the point and `direct` (also scaled), `pdf:content`, and the forms Tectonic doesn't draw (0108).
- `tests/xdv/`: `compare.py A B WORK` typesets every corpus paper (`harness/corpus.toml`) standalone with two
  `texpresso-xetex` builds and compares the XDVs byte for byte; `render_compare.py TXP_A TXP_B WORK` does the same
  under the driver (two `txp-render` builds), comparing every page rendered at scale 2.
- `tests/fonts/`: `compare.py ORACLE FONTDIR NEW WORK`: fontspec by name (Latin Modern Roman, TeX Gyre Pagella,
  Libertinus Serif, STIX Two Text; regular/bold/italic/bold italic at three sizes) against an oracle engine built
  with XeTeX's fontconfig manager (as on Overleaf: `make all CSYSFLAGS=... PKGSYS=icu-uc OBJSYS=`, i.e. without
  `XETEX_MAC`, on a series without 0005), compared op for op.
- `fonts/make_index.py BUNDLE.index DIGEST OUT.c`: rebuilds `taudot-fontindex.c` from the bundle tar with HTTP Range
  requests (the table directory and the few tables XeTeX reads; ~17.5 MB, ~7,300 requests, 5 min, 4 at a time).
- `tests/pics/`: what the engine answers about figures (`\XeTeXpicfile`, `\XeTeXpdffile` with every page and box,
  `\XeTeXpdfpagecount`), for the dvipdfmx replacement. `synthetic.py OUT` makes edge-case PDFs and images;
  `probe.py ENGINE WORK OUT.tsv NAME=DIR...` asks a built `texpresso-xetex` about every figure in the DIRs.
  `golden/dpx.tsv` is today's answers (dvipdfmx), on the synthetic set plus `~/code/lab/taudot-ref/corpus/`:

      uv run --with pillow==11.3.0 --with pikepdf==9.11.0 tests/pics/synthetic.py /tmp/syn
      uv run --with pikepdf==9.11.0 tests/pics/probe.py DIR/build/texpresso-xetex /tmp/work out.tsv \
        syn=/tmp/syn corpus=~/code/lab/taudot-ref/corpus

Numbering: `00NN` are the engine agent's (`src/engine`, plus `0002` in `src/dvi`), `01NN` the interp agent's
(`src/dvi`, TeXpresso's drawing gaps). `apply.sh` applies them in name order, so every `01NN` sits on top of all
`00NN`; after adding a `00NN`, check the `01NN` still apply.

To change your own range: on branch `taudot` in a clone with the whole series applied, rewrite your commits, then
replace only your files, e.g. `rm patches/00*.patch && git format-patch -o patches --start-number 1 e8df770..<your
last commit>`. Never regenerate the other range.
