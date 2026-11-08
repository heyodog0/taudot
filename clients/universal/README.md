# Universal live TeX

Live, exact typesetting on **unmodified** TeX engines: pdfTeX, XeTeX and LuaTeX, straight from TeX Live's release
source. No engine patches. Instead, a small library sits below the engine and a few TeX tokens sit above it.

- **libtau** (`interpose/`) is loaded with `DYLD_INSERT_LIBRARIES`. It serves the project from memory one line at a
  time, forks snapshots, rolls back on edit and keeps the output in memory.
- **tau-live** (`driver/`) is a drop-in for the live pdfTeX's `--serve`. It runs latexmk's rule (BibTeX, biber,
  makeindex) and emits the same events, including the paragraph preview.
- **tau-tdl** (`readers/`) reads the paragraph preview's output (PDF or XDV) into a display list for the app.

Paragraph preview: under 1.5 ms of TeX time for pdfTeX and XeTeX, about 2 ms for LuaTeX.

## Build

```console
$ sh clients/universal/build-engines.sh   # stock engines from TeX Live 2026's source
$ sh clients/universal/build-formats.sh
$ sh clients/universal/build.sh           # libtau, tau-live, tau-tdl
$ tau-live --serve --engine BIN/xelatex --state STATE DIR main.tex OUT
```

## Docs

- [docs/universal.md](../../docs/universal.md): how it works, measurements, what's left.

Licence: MIT (`LICENSE`), so other editors can embed libtau. The engines stay separate GPL programs.
