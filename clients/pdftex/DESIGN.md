# Live pdfTeX: design

**Licence: GPL-2.0-or-later.** Everything here is part of, or drives, a modified pdfTeX; keep it apart from the MIT
code elsewhere.

The fallback for pdfLaTeX projects: the app runs stock engines live (`docs/universal.md`) unless Settings ▸ "pdfLaTeX
on universal too" is off, and then runs this patched pdfTeX. It is TeXpresso's method (file-read hooks, fork
snapshots, rollback on edit) on real pdfTeX, with each PDF finished in a forked child. The app finds it in
`Resources/pdftex/<year>/` (`clients/mac/bundle.sh`), else `$TAUDOT_REF/pdftex-build-<year>/` (`LiveTex.swift`).

## Build

```sh
SERIES=2026 sh clients/pdftex/build.sh all            # stock, live and the driver, in $TAUDOT_REF/pdftex-build-2026
uv run clients/pdftex/texlive/tl.py store 2026        # the year's TeX Live tree, files fetched on demand
```

`SERIES` is `2026`, `2025` (default) or `2024`: TeX Live's release source, pdfTeX 1.40.29, 1.40.27, 1.40.26 as on
Overleaf (`trunk`: an older series, hooks and runtime only). `apply.sh SERIES DIR` applies it on branch `taudot`;
tag `stock` is the unpatched release, and the stock build is the release plus `0001`.

Patches, the same for each year: `0001` kpathsea fetches from the TeX Live store; `0002` open/write/exit hooks in
web2c's `lib/`; `0003` the live runtime `lib/taudot-live.c`, called from `input_line`, `maininit` and `ship_out`;
`0004` `getc_unlocked` reads (speed); `0005` paused processes exit with the driver; `0006` reruns; `0007` compressed
streams reused across rollbacks (`TAUDOT_ZCACHE=0` off); `0008` SyncTeX in memory; `0009` `--serve`'s finish rule;
`0010` snapshot thinning; `0011` the paragraph preview.

## How the engine works

Off unless `TAUDOT_LIVE_FD` is set; then only where files come from and go to changes.

- **Project files** (under `TAUDOT_PROJECT`) are read whole and served from memory, so the run knows each file's
  extent (bytes read, plus one if it saw the end). A resumed run swaps in the edited text.
- **Written files** (`.pdf`, `.log`, `.aux`, ...) stay in memory and shadow the disk for later reads. Other files
  open normally; after a fork the child reopens each at the same offset.
- **Snapshots.** Before reading a line of a project file, at most every `TAUDOT_SNAPSHOT_MS` (default 50), the runner
  forks: the parent waits as the snapshot, the child runs on. To apply an edit the driver SIGKILLs the child of the
  last snapshot before the changed byte; the snapshot forks a new runner, which reloads the project files and reads
  the edit from `TAUDOT_LIVE_OUT/ctl` (`seq byte file`).
- **Thinning** (`0010`). Past `TAUDOT_MAX_SNAPSHOTS` (256) the driver retires every other snapshot between the first
  and the last.
- **Fork-to-finish.** After each shipped page past the edit, the runner double-forks; the grandchild runs pdfTeX's
  `close_files_and_terminate` and writes `pdf-<seq>-<pid>.pdf`. The runner goes on to `final-<seq>.pdf` and waits,
  so the end can be rolled back too.
- **Messages** to the driver are datagrams on `TAUDOT_LIVE_FD` (snapshot, resume, page, PDF, end; `live.c` reads them).
- **Paragraph preview** (`0011`, `para.c`, `paradraw.c`). A snapshot at the edited paragraph's start keeps a warm
  child; on the next edit it sets that paragraph alone, and the driver writes it as a display list (TDL) and a
  one-page PDF: the `para` event of `docs/live-protocol.md`.

## TeX Live on demand (`texlive/`)

`tl.py store YEAR` writes `$TAUDOT_REF/texlive-YEAR/store-root`: `texmf.cnf` and the `ls-R` files of a full install.
Images: `2026.1@r79468`, `2025.1@r74524`, `2024.1@r70643` (`docs/texstore.md`).

When an `ls-R` hit isn't on disk, kpathsea (`0001`, `taudot-store.c`) finds the file's package in the image index,
fetches it from the store by SHA-512, checks it, caches it in `~/Library/Caches/taudot/texstore` and hard-links it
into the tree; `svn cat` at the image's revision if the store fails. A name not in TeX Live never reaches the
network. 32 threads prefetch what is likely next (`TEXSTORE_PREFETCH=0` off). The format and `pdftex.map` come from
the store. `TAUDOT_TL_SOURCE=iso` (2025 only) reads the release ISO by HTTP ranges instead.

## latexmk's rule

After every run, written files that differ from the disk go to the project. BibTeX runs when an `.aux`'s bib lines or
a `\bibdata` `.bib` changed; `--biber` runs biber when a `.bcf` or a datasource changed; `--makeindex` and
`--makeglossaries` run when their input changed. Then, if a changed file was read (or the log says `No file`), the
engine rolls back to the snapshot before the first changed byte, up to 5 runs.

## `--serve` (`serve.c`)

`pdftex-live --serve [--state STATE] DIR MAIN.tex OUT` speaks `docs/live-protocol.md`: commands `open`, `change`,
`goal`, `finish`, `rescan`; events `hello`, `fetch`, `run`, `pdf`, `bibtex`, `done`, `error`.

DIR is never written: the engine runs on `OUT/work`, an APFS clone. `--state` keeps `.aux`/`.bbl`/`.blg` across
sessions. PDFs come once past the edit, at the goal page, then at most every 150 ms, each with its `.log` and an
uncompressed `.synctex`.

## Limits

- pdfLaTeX only, TeX Live 2024–2026, macOS only (the store client uses CommonCrypto and the system's libcurl).
- Every snapshot is a live process: 256 before thinning.

## Other files

`live.c`: the batch driver (scripted edits, timings). `bench.py`: measurements against stock pdfLaTeX. `texmf/`: the
`trunk` series' tree. `tests/`: pytest.
