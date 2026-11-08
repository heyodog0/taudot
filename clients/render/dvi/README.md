# clients/render/dvi: TeXpresso's DVI interpreter, in our tree

Phase B moves the interpreter out of the TeXpresso clone so it can be taken off
MuPDF. These files are TeXpresso's (MIT, © 2023 Frédéric Bour; `LICENSE` here), with our changes in their own
commits; our changes are MIT as well and say so where they start.

Copied from (step 1, verbatim):

- TeXpresso: upstream `let-def/texpresso` at `e8df770` plus our patch series (`clients/render/texpresso/patches`,
  0001–0005 and 0101–0108), applied by `apply.sh` to HEAD **`89a323c`**.
  - `src/dvi/*` (all 24 files) → `dvi/`
  - `src/frontend/{sprotocol,state,fs,incdvi,myabort,engine_dvi,engine_tex,synctex,prot_parser,sexp_parser,
    json_parser,editor}.c` and the headers they include → `dvi/frontend/`
  - `src/include/*.h` → `dvi/include/`
  - `engine_pdf.c` isn't copied: the driver doesn't use it.
- The driver: `clients/preview/texpresso/txp-headless.c` at commit **`c58b62f`** → `clients/render/driver.c`.
  Port later changes with `git log c58b62f..main -- clients/preview/texpresso/txp-headless.c`.

Still taken from the clone: `build/common/libcommon.a` (Tectonic/TeX Live file providers) and
`build/texpresso-xetex` (the engine, a separate process).

Include paths: the frontend's `#include "../dvi/x.h"` resolves through `-I clients/render/dvi` (that folder's
`../dvi` is itself), so the copied files needed no edits.

Changes since the copy: `git log -- clients/render/dvi`. After the copy, interpreter fixes go here, not into
`clients/render/texpresso/patches`.

**No MuPDF (2026-11-06, nomupdf):** the interpreter builds against Taudot's runtime (`../rt/`, its header at
`rt/mupdf/fitz.h`), not MuPDF. The only edit it needed is `embed_pdf` in `dvi_special.c` and `dvi_special.re2c.c`:
an included PDF page is one `fz_fill_figure` call (a FIGURE op) instead of running the page through a PDF
interpreter.
