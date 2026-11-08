# clients/pdftex: the live pdfTeX prototype

**Licence: GPL-2.0-or-later.** Everything in this folder is part of, or drives, a modified pdfTeX. Keep it apart from
the MIT code elsewhere in the repo. Phase 1 of `docs/exact-typesetting.md`.

TeXpresso's method (file-read hooks, fork snapshots, rollback on edit) on real pdfTeX, with the PDF finished in a
forked child.

## Files

| File | What |
|---|---|
| `patches/2026/`, `patches/2025/`, `patches/2024/` | On TeX Live 2026, 2025 and 2024's release sources (pdfTeX 1.40.29, 1.40.27, 1.40.26: Overleaf's engines). The same ten patches each. `0001` kpathsea fetches files on demand, from the TeX Live store (below); `0002` adds three hooks in web2c's `lib/` (open for reading, open for writing, exit); `0003` adds `lib/taudot-live.c` (the live runtime) and calls it from `input_line`, `maininit` and pdfTeX's `ship_out`; `0004` backports 1.40.29's `getc_unlocked` reads (speed only); `0005`–`0006` process cleanup and reruns; `0007` the live engine reuses compressed streams across rollbacks (`$TAUDOT_LIVE_OUT/zcache`, keyed by the SHA-256 of the uncompressed stream; `TAUDOT_ZCACHE=0` off); `0008` SyncTeX in memory; `0009` `--serve`'s finish rule; `0010` retired snapshots (thinning); `0011` the paragraph preview (below). Stock is the release plus `0001`. |
| `patches/trunk/` | Phase 1's series on texlive-source at a pinned commit (pdfTeX 1.40.29): the hooks and the runtime. |
| `apply.sh SERIES DIR` | Puts the series' source in DIR and applies it as commits on branch `taudot`; tag `stock` is the unpatched engine. |
| `build.sh [stock\|live\|driver\|all]` | `SERIES=2026`, `2025` (default), `2024` or `trunk`. Builds stock pdfTeX (a worktree at `stock`), live pdfTeX and the driver, out of tree. |
| `texlive/tl.py`, `texlive/iso.py`, `texlive/tl-fetch` | A TeX Live year on demand (below). |
| `para.c`, `paradraw.c` | `--serve`'s paragraph preview, the driver's side: paragraph snapshots, go, the `para` event; the lines' content stream read as a viewer reads it (Type 1 outlines decoded here), written as a display list (TDL) and as a one-page PDF. |
| `live.c` | The driver: runs a document, applies scripted edits, rolls the engine back, times the PDFs. `--leave` exits without cleanup (tests that the engine follows). |
| `texmf/texmf.cnf`, `texmf/fetch.py` | Phase 1's flat TeX tree filled from Tectonic's bundle (TeX Live 2023), file by file. |
| `bench.py` | The Phase 1 measurements: `fmt`, `run`, `finish`. |

## How the engine works

Off unless `TAUDOT_LIVE_FD` is set; then stock behaviour is unchanged except where files come from and go to.

- **Project files** (anything under `TAUDOT_PROJECT`) are read whole and served from memory, unbuffered, so the run
  knows each file's *extent*: bytes read, plus one if it saw the end. A resumed run swaps in the edited text at the
  same position.
- **Written files** (`.pdf`, `.log`, `.aux`, ...) stay in memory and shadow the disk for later reads in the same run.
  Forked processes never share an output file. The disk `.aux` is never rewritten (reruns are Phase 3).
- **Other read-only files** (fonts, images) are opened normally; after every fork the child gives each one its own
  file description at the same offset, so a runner can't move a paused snapshot's offsets.
- **Snapshots.** Before reading a line of a project file, at most every `TAUDOT_SNAPSHOT_MS` (default 50), the runner
  forks: the parent waits as the snapshot, the child runs on. When the driver SIGKILLs a snapshot's child, the
  snapshot forks a new runner from its own state (and stays a snapshot); the new runner reloads the project files
  and reads `TAUDOT_LIVE_OUT/ctl` (`seq byte file`: the edit).
- **Thinning** (patch `0010`, `docs/state-machines.md` C4). Every snapshot is a live process, so past
  `TAUDOT_MAX_SNAPSHOTS` (256) the driver retires every other one between the first and the last, with SIGTERM.
  The retired snapshot's parent then has no child to be killed: it waits for SIGUSR1 (which a snapshot gets for
  nothing else) and resumes like a killed child's snapshot. The engine announces this with `V 1 retire`; the driver
  never thins an engine that didn't, since an older engine takes a retired child as a crash.
- **Fork-to-finish.** After each shipped page, once the runner has read past the edited byte (or always, with
  `TAUDOT_FINISH_ALL`), it double-forks; the grandchild runs pdfTeX's `close_files_and_terminate` (font subsets, page
  tree, xref) and writes `pdf-<seq>-<pid>.pdf`. The runner carries on to the end, writes `final-<seq>.pdf` and waits,
  so the end of the run can be rolled back too.
- **Reruns** (patch `0006`): a failed open is recorded as a project file seen empty; at the end, written project
  files go to `w-<seq>/` and a `T` message lists the final extents. The driver applies latexmk's rule (below).
- Orphans (a runner whose snapshot was killed) exit at their next line read. Paused snapshots and finished runners exit when the driver does (kqueue, patch `0005`).

### Messages (engine to driver, one datagram each, times in CLOCK_MONOTONIC µs)

| | |
|---|---|
| `S snap runner t n` + n × `extent file` | a snapshot was taken; `runner` is the new runner |
| `R snap runner seq t` | snapshot `snap` resumed for edit `seq` |
| `p runner pages t` | a page was shipped |
| `P pid seq pages t_fork t_start t_finished t_written name` | a finished PDF |
| `E runner seq pages code t` | the run ended; `final-<seq>.pdf` written |
| `T runner seq n` + n × `extent opened file` | the run's final extents (sent just before `E`) |
| `X snap child status` | a runner died other than by SIGKILL (or SIGTERM, with `0010`) |
| `V 1 retire` | at start, from an engine with patch `0010`: it understands retired snapshots |

### The paragraph preview (patch `0011`, `para.c`; `docs/live-protocol.md`, `para`)

- **Paragraph snapshots.** ctl's 6th and 7th fields: a window `pwin` (from the line after the last blank line
  before the edit) and the offset of the paragraph snapshot the driver already has (`phave`). A runner reading a
  line of the edited file on the main vertical list, at or after `pwin`, after `phave` and before the edit, forks
  one there (double fork: it outlives the runner): `Q pid seq off rel`. It preloads what a first ship-out would load
  (the font map, virtual fonts), finds the fonts' files, and keeps a **warm child** parked (`W snap pid`), which has
  touched every readable page and TeX's arrays for writing (fork leaves page tables empty: ~100-300 faults
  otherwise; `TAUDOT_PARA_NOPREFAULT`, `TAUDOT_PARA_TOUCHW=1` to write every page).
- **Go.** For an edit after a valid paragraph snapshot (no edit before it, nor in another file, since its run
  began) the driver writes the file's new text and `OUT/pgo-<snap>` (`go seq edit textfile [x y w h]`: the old
  first line's left and baseline and the page's size, in sp) and sends SIGUSR1 to the warm child. It swaps in the
  text, tells its snapshot (SIGUSR2: the next warm child is forked at once), and typesets. The first paragraph
  broken on the main vertical list after the input passed the edit is the one: before the page builder sees it,
  its lines are shipped alone (`\pdfcompresslevel` 0) at that place on a page of that size, so the content stream
  has the page's own coordinates; then `OUT/para-<go>.out` (flags, line metrics, fonts with pdfTeX's `/Widths`,
  the content stream) and `H pid go seq name ok t_go t_lb t_ship t_done` (or `H pid go seq - why t`).
- **Where the old lines are.** The runner selects the same paragraph and marks its line boxes in their SyncTeX
  line field (the output routine copies boxes; the field is copied with them); before each page ships it walks
  the page box (vlist_out/hlist_out's arithmetic) and gives the marks back: `A runner seq off page n pw ph seg` +
  n × `page x y w h d` (sp; y the baseline, from the page's top-left).
- **Debug:** `TAUDOT_PARA_DEBUG=1` in the driver's environment prints Q/W/A/H/D to stderr (D: the engine's).

## TeX Live on demand (`texlive/`)

A year's tree looks like a full install to kpathsea, but holds only the files used so far.

- **Source: the TeX Live store** (`docs/texstore.md`, `https://texlive.taudot.app`), one image per Overleaf TeX Live
  image: `2026.1@r79468`, `2025.1@r74524`, `2024.1@r70643` (`tl.py` `IMAGES`).
  - **`tl.py store YEAR`** writes `~/code/lab/taudot-ref/texlive-YEAR/store-root` with only `texmf.cnf` and the two
    `ls-R` files (which list every file of a full install, generated ones included), and a `texmf.cnf` that sets
    `TEXMFROOT` ahead of TeX Live's own.
  - **Fetching, in process** (patch `0001`, `texk/kpathsea/taudot-store.c`): when an `ls-R` hit isn't on disk and
    `TEXSTORE_URL` is set, kpathsea itself finds the file's package in the image index (binary search in the
    mapped index), reads the package's manifest, and gets `files/<sha512>` (gzip, checked by SHA-512, cached by
    hash in `~/Library/Caches/taudot/texstore`, hard-linked into the tree). If the store fails: `svn cat` at the
    image's revision, checked by the same hash. A name that isn't in TeX Live never reaches the network.
  - **Parallel:** the requested file comes first, on the calling thread. A pool of 32 threads fetches what will
    probably be asked for next: the packages a fetched `.sty`/`.cls` (and, once, the project's own files) names in
    `\RequirePackage`/`\usepackage`/`\LoadClass`, first; the `.tfm`/`.vf` beside a fetched font and its `.pfb`;
    the rest of a package's TeX inputs (≤ 1 MB each, ≤ 4 MB a package). A forked process (the live engine's
    snapshots) starts its own pool and HTTP handle. `TEXSTORE_PREFETCH=0` turns it off, `TEXSTORE_THREADS` sizes it.
  - libcurl and zlib come from the system by `dlopen`, so no link line changes; SHA-512 is CommonCrypto's. macOS
    only for now.
  - The format, `pdftex.map` and the installer's configs are in the store (`_generated`), made by texstore's
    `gen.py` with the year's stock engine.
- **The release ISO** (`TAUDOT_TL_SOURCE=iso`, 2025 only): read by HTTP byte ranges (`iso.py` indexes
  `archive/*.tar.xz` once, from ~20 range reads).
  - **`tl.py setup YEAR`** writes `~/code/lab/taudot-ref/texlive-YEAR/root`: the package database, the `ls-R`
    files, and the installer's generated files by TeX Live's own `TLUtils.pm`; **`tl.py updmap YEAR
    KPSEWHICH_DIR`** runs `updmap.pl` for `pdftex.map`.
  - Fetching: kpathsea runs `$TAUDOT_TL_FETCH PATH` (`tl-fetch`), which range-reads the package's archive, checks
    the database's sha512 and unpacks it.
- Engines run as `pdflatex` (a symlink), so kpathsea uses `TEXINPUTS.pdflatex`. The format is built with
  `fmtutil.cnf`'s command line.

## latexmk's rule (driver)

After every run: written files that differ from the disk are written to the project. BibTeX runs, if a `.bib`
exists, when the bib lines of the main `.aux` or of an `.aux` it `\@input`s (`\include`) changed, or a `\bibdata`
`.bib` changed since the last BibTeX run. An edit to a `.bib` (a file the engine never reads) goes straight to
BibTeX, with a rerun only if the `.bbl` changed. With `--biber`, a `.bcf` means biber instead of BibTeX (when the
`.bcf` or a datasource changed). `--makeindex` (`.idx` → `.ind`) and `--makeglossaries` (each `\@newglossary` in
the `.aux`, as Overleaf's latexmkrc) run when their input changed since their last run. Then, if a changed file was read (or the log says `No file`), the
engine rolls back to the latest snapshot before the first changed byte and runs again, up to 5 runs. `bench.py`'s
reference does the same with stock pdfLaTeX from latexmk's own method (`-recorder`, md5s), chained edit to edit.

## `--serve`: the app's mode (`serve.c`)

`pdftex-live --serve [...] [--state STATE] DIR MAIN.tex OUT` speaks livepane's protocol (`docs/live-protocol.md`):
JSON commands on stdin (`open`, `change`, `goal`, `finish`, `rescan`), JSON events on stdout (`hello`, `fetch`,
`run`, `pdf`, `bibtex`, `done`, `error`).

- **DIR is never written.** The engine runs on `OUT/work`, an APFS clone of DIR (`cp -c`); edits, latexmk's
  written files and BibTeX's go there. `--state` fills in missing `.aux`/`.bbl`/`.blg` at start and keeps them
  whenever a compile settles and at exit, with `STATE/rule` (the `.bib` hash the `.bbl` was made from, so a `.bib`
  changed between sessions reruns BibTeX).
- **When PDFs come** (patch `0009`, through `ctl`'s goal and period fields): once the run is past the edit, at the
  goal page, then at most every 150 ms; `finish` is SIGUSR1 to the runner, `goal` rewrites `ctl` and sends SIGUSR2.
  Each PDF has its `.log` and a plain `.synctex` beside it (`-synctex=-1` by default, so no PDF waits for a gzip).
- **latexmk's rule** is the batch driver's (`rule_step`), one step per finished run; an edit during a compile starts
  a new one from the snapshot before the first changed byte.
- `fetch` events come from the store client's log (`TEXSTORE_LOG`, set to `OUT/fetch.log`).

## Running it

```sh
sh clients/pdftex/build.sh all                     # ~/code/lab/taudot-ref/{texlive-2025/src,pdftex-build-2025}
uv run --no-project --with pycdlib python clients/pdftex/texlive/tl.py setup 2025
uv run --no-project python clients/pdftex/texlive/tl.py updmap 2025 ~/code/lab/taudot-ref/pdftex-build-2025/stock/texk/kpathsea
export WORK=<scratch dir> TEXLIVE=2025             # unset TEXLIVE (and SERIES=trunk) for Phase 1's setup
uv run clients/pdftex/bench.py fmt
uv run clients/pdftex/bench.py run paper <a long paper's folder> main.tex
uv run clients/pdftex/bench.py finish paper main.tex
```

`bench.py run` copies the project into `WORK`; the edits are generated from the copy and stay there.
