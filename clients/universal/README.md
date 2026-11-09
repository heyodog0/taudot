# Universal live TeX

Live, exact typesetting on **unmodified** TeX engines: pdfTeX, XeTeX and LuaTeX, straight from TeX Live's release
source. No engine patches. Instead, a small library sits below the engine and a few TeX tokens sit above it.

- **libtau** (`interpose/`) is loaded with `DYLD_INSERT_LIBRARIES`. It serves the project from memory one line at a
  time, forks snapshots, rolls back on edit and keeps the output in memory. It fetches missing TeX Live files from the
  store on demand (only paths in the tree's `ls-R`; misses are remembered), with no Python.
- **tau-live** (`driver/`) is a drop-in for the live pdfTeX's `--serve`. It runs latexmk's rule (BibTeX, biber,
  makeindex) and emits the same events, including the paragraph preview.
- **tau-pdfmx** (`pdfmx/`) is xdvipdfmx kept resident (stock dvipdfm-x objects, so GPL as a program): tau-live converts
  only XeTeX's changed pages with it, ~5 ms a page, byte for byte what `xdvipdfmx` gives.
- **tau-tdl** (`readers/`) reads the paragraph preview's output (PDF or XDV) into a display list for the app. tau-live keeps
  one running.

Paragraph preview: under 1.5 ms of TeX time for pdfTeX and XeTeX, about 2 ms for LuaTeX. From edit to the placed
`para` event: about 5 ms on pdfTeX and XeTeX, 7–10 ms on LuaTeX.

## Build

```console
$ sh clients/universal/build-engines.sh   # stock engines from TeX Live 2026's source
$ sh clients/universal/build-formats.sh
$ sh clients/universal/build.sh           # libtau, tau-live, tau-tdl, tau-pdfmx
$ tau-live --serve --engine BIN/xelatex --state STATE DIR main.tex OUT
```

## Docs

- [docs/universal.md](../../docs/universal.md): how it works, measurements, what's left.

Licence: MIT (`LICENSE`), so other editors can embed libtau. The engines and tau-pdfmx (it links dvipdfm-x) are
separate GPL programs.
