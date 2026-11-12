# Universal live typesetting

Live, exact typesetting on unmodified TeX engines: pdfTeX, XeTeX and LuaHBTeX built from TeX Live 2026's release
source, no patches. One layer sits below the engine (an interposer over the C library) and one above it (a few TeX
tokens on the command line). Together they give what the patched pdfTeX gets from its hooks: snapshots mid-document,
rollback on edit, early pages, a paragraph preview. Code: `clients/universal/`.

## Pieces

| | What | Where |
|---|---|---|
| `libtau.dylib` | the interposer, loaded with `DYLD_INSERT_LIBRARIES` | `interpose/tau.c`, `zcache.c`, `store.c` |
| `tau-live` | the driver: spawns the engine under libtau, speaks `docs/live-protocol.md` on stdin/stdout | `driver/` |
| `tau-tdl` | the reader: turns a pass's or a page's output into the app's TDL display list | `readers/` |
| `tau-pdfmx` | xdvipdfmx kept resident, converts XeTeX's changed pages | `pdfmx/` |
| engines | stock pdfTeX, XeTeX, LuaHBTeX (tag `release`), zlib linked as a dylib | `build-engines.sh` |
| tests | exactness and timing against stock runs and patched pdfTeX | `tests/uni.py` and helpers |

Licence: MIT for everything in `clients/universal/`. The engines and tau-pdfmx (it links dvipdfm-x's objects) stay
separate, unmodified GPL programs.

## Build and run

```console
$ sh clients/universal/build-engines.sh   # stock engines from TeX Live 2026's source
$ sh clients/universal/build-formats.sh
$ sh clients/universal/build.sh           # libtau, tau-live, tau-tdl, tau-pdfmx
$ tau-live --serve --engine BIN/xelatex --state STATE DIR main.tex OUT
```

`tau-live` takes the command line and protocol of `pdftex-live --serve`, so the app can use either:

    tau-live [--serve] --engine PATH [options] DIR MAIN OUT
    tau-live [options] DIR MAIN OUT -- ENGINE ARGS...      (tests)

With `--engine` it runs `ENGINE [-no-pdf for XeTeX] -interaction=batchmode -synctex=-1 MAIN` with the ship hook and
the paragraph pass on. libtau, tau-tdl and tau-pdfmx are found beside the `tau-live` binary. Options not covered in
the sections below:

| Option | Default | |
|---|---|---|
| `--bibtex`, `--biber`, `--makeindex PATH` | BibTeX beside the engine | latexmk's tools |
| `--max-runs N` | 5 | reruns per edit |
| `--state DIR` | none | `.aux/.bbl/.blg/.toc/.out` kept across sessions |
| `--finish every\|rule` | rule | when finishers fork |
| `--no-para`, `--no-display-pages`, `--no-first-finish`, `--no-pdfmx`, `--no-presize`, `--no-scout` | | turn a feature off |

## Below the engine: libtau

**Project files from memory.** The driver works on an APFS clone of the project; the project directory is never
written. libtau reads each project file whole on first open and serves it from memory, one line per `read()`. So each
refill of the engine's stdio buffer happens at a line start with the buffer empty: the read log (bytes read per file,
+1 once the end was seen) is exact, and a fork there is a clean snapshot. `stat` and `access` on project paths are
answered from memory; misses are logged as "seen empty", so creating the file later invalidates later snapshots.

**Written files stay in memory**, copy-on-write across forks, and shadow the disk for later reads. They go to
`TAU_OUT/<tag>-<seq>-<pid>/` at exit. The PDF lives in a 1 GiB VM reservation and grows without copying. Other files
(fonts, images, TeX Live) get a fresh file description at the same offset in every forked child, so a runner never
moves a parked snapshot's offsets.

**Snapshots and rollback.** At a line read of a project text file, libtau may fork; the parent parks in kqueue
(SIGUSR1 resumes it, the driver's lifeline pipe closing ends it) and the child runs on. On an edit the driver picks
the newest snapshot whose read log stops at or before the first changed byte of every changed file. It stops
everything newer (SIGSTOP at once, SIGKILL once the preview is out or after 50 ms), writes the new text into the
clone, writes `ctl-<pid>` and sends SIGUSR1. The snapshot reads its orders once, then forks a runner that reloads the
changed files and carries on. Orders carry a stamp (`go N`), so a second wake for the same orders forks nothing. Any
snapshot can be resumed alone.

**Fork inside `getc`.** The fork happens inside `read()`, under the stream's lock, which the child's thread (a new id)
could never release. libtau tracks the `FILE` of each fd, counts how deep the parent holds the lock, and gives the
child a fresh recursive lock held as deeply. This relies on `struct __sFILEX` starting with `up` then `fl_mutex`, the
one private-layout dependency.

**Unlocked `getc`.** Stock pdfTeX reads font maps, TFMs and every input line through `getc`/`fgetc`, which lock the
FILE per character. libtau interposes both with `getc_unlocked` (the engines are single-threaded), as patched pdfTeX
does with pdfTeX 1.40.29's change. A stock run with only this: 303 → 224 ms on a 10-page document, PDF identical.
`open()` makes no locale-sensitive calls, since LuaTeX's `setlocale` opens files under libc's locale lock.

**zcache.** The engines link TeX Live's own zlib as a dylib (same source, same bytes), so libtau can interpose
`deflate`. A stream's input is held until `Z_FINISH`, keyed by SHA-256 with level and window, and the output comes
from `OUT/zcache` or from zlib. zlib's output doesn't depend on how the input was split across `Z_NO_FLUSH` calls.

**TeX Live on demand.** With `TEXSTORE_URL` set, libtau fetches a missing TeX Live file itself (`store.c`, written
from `docs/texstore.md`): index, the owner's `F` row, the package manifest, then the object from the shared cache
(`TEXSTORE_CACHE/objects/xx/<sha512>`) or the store, SHA-512 checked and written atomically. libcurl and zlib are the
system's, loaded with `dlopen`.

- Only paths in the tree's `ls-R` files are fetched (209k 64-bit hashes, read at the first miss), plus the boot files,
  so kpathsea's probes for files TeX Live lacks cost nothing.
- A listed path the store doesn't give goes into `TREE/.taudot-fetch-misses` and isn't asked for again.
- Errors: `{"ev":"error","what":"offline",...}` once per file when the store can't be reached, and
  `{"ev":"error","what":"format",...}` with TeX's own line when the engine can't read its format.
- A missing `.sty`: the compile takes 1.7 s with a cold cache, 0.8 s warm, 0.6 s with the file present.

## Above the engine: injected tokens

**Ship hook.** The command line becomes
`\def\taudotsig#1{SIG}\AddToHook{shipout/after}{\taudotsig{ship/\the\ReadonlyShipoutCounter}}\csname @@input\endcsname main.tex`,
where SIG is `\pdffilesize{/.taudot/#1}` (pdfTeX), `\filesize{...}` (XeTeX) or
`\directlua{lfs.attributes("/.taudot/#1")}` (LuaTeX): a file lookup that expands to nothing and writes nothing to the
log. libtau sees the lookup of `/.taudot/ship/N`. The paragraph pass's macros are defined on the same line. The job
name stays `main` and the PDF is byte-identical to a plain stock run; only the `.log`'s first lines differ.

**Finishing early.** At a ship (the first past the edit, then at most every 150 ms) the runner double-forks a
finisher. The finisher's next read of each open project file returns
`\output={\setbox0\box255 \deadcycles=0\relax}\csname @@end\endcsname`, then end of file. The page in progress is
dropped and TeX's own `\end` closes the document. (Ending the input alone is a fatal "no legal \end found", after
which pdfTeX deletes the PDF.) The finisher exits as soon as TeX closes its log, skipping the engine's teardown. A
finisher's output that arrives after its run's final output isn't sent.

**First-page finish.** A fresh engine forks one finisher at the goal page (else the first) as soon as it ships, so the
first PDF doesn't wait for the document's end.

**LuaTeX's node properties.** With luaotfload, freeing a node sets its properties entry to nil, and Lua rehashes the
nearly empty table again and again (~18% of a stock LuaLaTeX run). tau-live's LuaTeX command line starts with
`\directlua{local t=node.direct.get_properties_table() for i=1,1048576 do t[i]=false end for i=1,1048576 do t[i]=nil end}`,
which gives the table an array part, emptied again. Stock run of paper-b 1.42 → 1.15 s, PDF byte-identical;
snapshots grow ~8 MiB.

## Snapshot spacing

| Where | Spacing |
|---|---|
| a normal run (open with an `.aux`, reruns) | every 20 ms of engine time (`--snapshot-ms`) |
| a first run with no `.aux` | every 200 ms (`--first-snapshot-ms`) |
| near an edit | every line from 300 bytes before the edit (or the edited line's start, if earlier) to the edit (`--dense`) |
| a run after a key | every 20 ms from 16 KB before the key to 150 ms past it, every 100 ms elsewhere (`--snap-near-ms`, `--snap-far-ms`; far 0 turns it off) |
| over 256 kept | every other one killed (`--max-snapshots`) |
| after a reap | thinned to the memory budget (see Memory) |

Dense line snapshots exist because typing is local and a paragraph is often one long line. Snapshots cost ~10% of a
first run (XeLaTeX 826 ms against 748 without them; LuaLaTeX 1685 against 1517).

## The paragraph pass

On an edit whose resume snapshot lies in the edited file within 4 KB before the edit, the snapshot forks a pass
before the exact runner. The pass sees:

1. at the resume point, one inserted line: an `\output` that hands LaTeX's float penalties to LaTeX's own routine,
   ships the page so far through LaTeX's `\shipout` at a break inside the paragraph, and at the pass's own break takes
   the last `\prevgraf` lines off with `\lastbox` and ships just them through the primitive `\shipout`;
2. the new text up to the end of the edited paragraph (the next blank or structural line);
3. `\par\edef\taudotpg{\the\prevgraf}\penalty-10000 \taudotsig{stop/\taudotpg}`. XeTeX also ships a 17 KB `\special`
   so its 16 KB DVI buffer reaches the file.

Other project files read as empty, and `alarm(2)` stops a runaway pass. At the stop signal libtau writes what the
engine appended since the pass began (`para-<seq>-<pid>.bin`: the lines' content stream, or their XDV page) and
exits. The same tokens work on all three engines.

**Geometry.** `\taudotgrab` puts the first line's height, baseline and the lines' span in the stop signal
(`-gBASExSPANxHT`, sp). The driver reads the old lines' first baseline and left edge from SyncTeX and passes them as
`\taudotyb` and `\taudotxb`, so the pass ships its lines exactly there and the engine rounds positions as on the real
page. This covers list items, whose indent is a shift of each line box that `\lastbox` drops. Old lines without one
shared left edge (a hanging indent) get no preview.

**The warm pass.** The line snapshot at the edit keeps one pass child forked, files reopened, parked in kqueue. The
driver writes `ctl-warm-<pid>` with the paragraph's new text and signals it; the snapshot parks a new one when it
exits. tau-live keeps a single warm child and lets the others go. While parked, the warm child writes the pages the
previous pass copied (from `mincore`, kept in `OUT/hot`), so the copy-on-write faults come before the key: faults
after the wake 920 → 187, edit → lines 3.7–4.0 → 2.9 ms on pdfTeX. On pdfTeX it also looks up every loaded font's map
entry, so a first-page pass doesn't read `pdftex.map` at its ship. Exact runners don't, so their output can't change.

**Locating the old lines.** SyncTeX records every line box of a paragraph with the source line its `\par` was read
on. The driver maps that line back to each recent output's text and looks in its SyncTeX (`driver/synctex.c`: 2.7 MB
in ~3 ms) for hbox records directly inside one vbox, which give the old lines, their page, x and width.

**The `para` event** is the one in `docs/live-protocol.md`. Its states:

| state | when |
|---|---|
| `exact` | line count, first line's height and span agree with the old lines (64 sp) |
| `provisional` | they don't (`why`: `lines`, `heights`) |
| `none` | `insert` (something follows the lines, or the paragraph is in a box), `split` (crosses a page or column), `segment`, `noanchor` (an edit in a comment), `shape`, `glyph`/`resource`, `end`, `reader` |

`erase` holds the old and new lines' boxes (3 pt either side for protruded punctuation), each padded by half the gap
between the first two lines.

### Readers

`tau-tdl serve` runs inside tau-live, one request per line on stdin; the `para` event goes out with its answer.

- **XeTeX** (`xdv`): the pass's XDV page is appended to the last exact XDV (which defines the fonts) and run through
  TeXpresso's DVI interpreter into the renderer's TDL device (`clients/render/{glyphs,dlist}.c`, unmodified).
  tau-live sends `warm DOC.xdv` with the first XDV output so fonts load before the first key.
- **pdfTeX, LuaTeX** (`pdf`): no PDF interpreter. The overlay is a one-page PDF, an APFS clone of the last exact PDF
  plus an incremental update whose page draws only the pass's content stream. The TDL is one `FIGURE` op drawing it.
  `pdfmini.c` reads xref tables, xref streams and object streams, and keeps each exact PDF's cross-references and
  per-page resources; tau-live sends `warmpdf PDF` while the reader is idle. Reader time 0.7 ms.
- The reader refuses an overlay unless every (font, code) the pass draws is drawn somewhere in the exact PDF under
  that name and every resource exists. pdfTeX names a font resource after the first font of its name the run uses,
  so a pass before the first page can name another subset. On pdfLaTeX, title-page documents get no first-page
  preview for this reason. Characters the subsets lack are refused too.

## Display pages

After a key, the run's first shipped page that differs from the last finished PDF goes out at once as a `pdf` event
with `display: true`, before the finisher's PDF. libtau writes the engine's output for that page
(`TAU_PAGE_PREVIEW`); `tau-tdl page` makes the last finished PDF with that page replaced (an incremental update).
pdfTeX and LuaTeX only.

- `page` answers `same` for a page whose content stream is unchanged, and tau-live tries the next shipped page (up to
  64). Shipped pages queue in order, so no changed page is skipped.
- A page goes out only if every (font, code) it draws is in the finished PDF's subsets, every resource exists, and it
  has no inline image. Otherwise the user waits for the finisher.
- Each page's (font, code)s are cached by a hash of its content stream: `page` takes 0.5–1 ms at 300 pages.
- Display-page requests wait while the edit's paragraph pass runs (at most 50 ms), keeping the reader off its cores.

## XeTeX's pages: tau-pdfmx

A fresh `xdvipdfmx -s FIRST-LAST` spends ~80% of a one-page conversion building kpathsea's `ls-R` hash. `tau-pdfmx
serve` reads `texmf.cnf` and every `ls-R` once, then forks a child per request (`DIR<TAB>ARG...`, answered `done CODE
US`) that runs xdvipdfmx's own `main`; the next child is forked while the client reads the PDF. Every request starts
from the same state, so the output is a fresh `xdvipdfmx`'s byte for byte (font subset tags hash the output's name).
It also reads and writes without stream locks and skips kpathsea's case-insensitive retry on case-insensitive volumes.

tau-live converts only changed pages. A page is converted again when its XDV bytes differ, page 1 or the units differ
(xdvipdfmx reads page 1's specials for every page), or a font number is defined differently (XeTeX numbers fonts as
it defines them). The `pdf` event carries `pdf_path`, `pdf_first`, `pdf_last` (0-based, inclusive; `pdf_last <
pdf_first` means none changed) and `pdfmx_us`, or `pdf_error`. Later events wait behind it; `para` events don't.

| paper-b, XeLaTeX | xdvipdfmx per event | tau-pdfmx in tau-live |
|---|---|---|
| one page → PDF | p50 41, p90 45 ms | p50 5.2, p90 5.9 ms |
| pages from the edit to the end | p50 99, p90 196 ms | only changed pages (p50 0 per final) |
| typing: edit → PDF of the edited page | ≥ 65 ms | p50 24.5, p90 26.1 ms |

## latexmk's rule, state, commands

After each run the files it wrote (except the document, logs and SyncTeX) go into the clone when they differ.
BibTeX runs when the `.aux` files' bib lines or a `.bib` changed, and only if the `.bib` files exist (latexmk's
`-bibtex-cond`; arXiv sources ship only their `.bbl`). biber runs instead when there is a `.bcf`; makeindex when the
`.idx` changed. If the run read a changed file, the engine resumes from the newest snapshot before the first changed
byte (`run` event, `why` `aux` or `bibtex`), up to `--max-runs`; else `done`.

`--state`: missing `.aux/.bbl/.blg/.toc/.out` come from STATE at start and go back when a compile settles, with
`STATE/rule` (the `.bib` files' hash). A reopened project settles in one run without BibTeX.

Commands beyond edits: `goal` (finish at once when that page ships), `finish` (a PDF of the pages so far), `rescan`
(files changed in DIR that no editor holds), `cursor`, `stats` (each process's role, pid and phys_footprint), `reap`.
Events: `hello`, `fetch`, `run`, `pdf` (with `synctex`, `log`, `finish_us`, `from_page`), `bibtex`, `done`, `para`,
`error`.

## Parked engine

`tau-live --park SOCKET --serve --engine PATH` starts an engine with the session's command line, except that it reads
the main file's name with `\openin` from `/.taudot/main.tex` (an `\openin` doesn't fix the job name). libtau parks at
that lookup, with the format loaded, and listens on SOCKET. A session started with `--parked SOCKET` sends its
environment, working directory, pipes and log, and gets a forked child as its engine; a session whose engine, command
line or relevant environment differs spawns as usual. The parked engine is renewed every 5 minutes (`TAU_PARK_RENEW`)
because `\time` and `\today` are set at engine start. A session's processes exit when its lifeline closes.

## Memory

A parked snapshot (300 pages) holds ~7.3 MB of its own: TeX's node memory 2.6 MB, other arrays 1.1, small
allocations 1.6, per-process pages ~1.5. It is the same at 20 and 50 ms apart, because between any two snapshots the
run rewrites the same hot pages. So memory depends on how many snapshots are kept, not on their spacing. The base is
the engine's image (the first snapshot, 38 MB on pdfLaTeX), the snapshot holding the first page's fonts (21 MB), the
driver and the reader. The driver keeps SyncTeX data in its own mappings and unmaps them whole (4.2 MB resident).

**Reaping.** When no edit has come for `--reap-ms` (2500) and the run has settled, or as soon as an open settles
(`--reap-open-ms`, 0), tau-live reaps. It keeps the first snapshot, the next key's resume point with its warm child,
the cursor's, and others spaced by engine time along the run. It kills the rest of the snapshots and stopped runners,
drops all but the newest output's SyncTeX, and returns free malloc memory in tau-live and tau-tdl. The base spacing is
`--reap-snapshot-ms` (50), not 20: a resumed run takes copy-on-write faults and covers less than half the text per ms.
A killed snapshot's kept descendants are reparented but stay in the session's process group, so measure by process
group.

**The budget.** `--mem-budget-mb`, or by default the base as the first reap finds it plus `--mem-extra-mb` (64): about
150 MB on pdfLaTeX at any length. Snapshots are spaced `--reap-snapshot-ms` + slope × the engine-time distance to the
nearest focus (the last 8 edits, the cursor, the pages in view from `goal`), with the smallest slope that fits. The
reap measures again 400 ms later, since a kept snapshot takes over pages it shared with the ones let go.

**The scout.** The app sends `["cursor", path, line, column]` when the cursor rests for 300 ms. If a key there would
resume more than 2 KB before it, tau-live wakes that snapshot with no edit. The run typesets quietly to the cursor,
writes nothing, leaves line snapshots and a warm pass there, and exits. Any edit stops it; what it left stays valid.
A scout costs 17–61 ms of engine time on 300 pages and 2103.00020.

## Results

TeX Live 2026, M-series Mac. Documents: paper-a (32 pages, one column, line numbers), paper-b (arXiv 2103.00020, 48
pages, two columns), arXiv 1512.03385 and 1706.03762, and synthetic documents of 10, 100 and 300 pages (synth-N).
"Stock" is TeX Live's own static build. Machine load varied between runs; numbers within a table were taken together.

### Byte identity

| Check | Test | Result |
|---|---|---|
| a run under libtau = a stock run | | PDF, `.aux`, `.out`, `.log` identical, paper-a and paper-b, 3 engines\*; no measurable overhead (1615 vs 1661 ms) |
| final output after random edits = stock run of the edited copy | `uni.py edits` | pdfTeX 20/20 per paper, XeTeX and LuaTeX 12/12, 64/64 with the rule |
| settled output with latexmk's rule = stock + BibTeX | `uni.py rule`, `bblonly` | identical, 3 engines |
| early outputs = the full run's pages | `uni.py finish` | 32/32 paper-a, 48/48 and 51/51 paper-b; 10/10 × 3 engines |
| command-line macros don't change output | `uni.py prelude` | 3 engines × 2 papers |
| parked, reaped and scouted sessions = stock | `uni.py parked`, `reap`, `cursor` | every settled output; no process left after the session |
| tau-pdfmx = fresh `xdvipdfmx` | `uni.py xpdf`, `tests/pdfmx.py` | 50/50 PDFs; pages drawn identically 41/41 × 8; 30/30 and 20/20 random ranges |
| display pages = finished page at 288 dpi | `uni.py display` | 0 px: 44/44 LuaLaTeX, 42/42 pdfLaTeX (paper-b), 40/40 on 1512.03385, 29/40 shown on synth-300 |

\* LuaTeX's `/ID` is an MD5 that includes the output's absolute path, so live runs are compared with `/ID` masked.
Matching Overleaf byte for byte would need the clone at CLSI's path (`/compile/...`); unverified.

### Paragraph preview exactness

Exact previews drawn as the app draws them, every pixel at 288 dpi. XeTeX has no overlay PDF, so its check is the
list's glyph baselines against the exact XDV's.

| | exact previews | placed at 0 px |
|---|---|---|
| pdfTeX, paper-a | 8 of 20 edits | 8/8 |
| pdfTeX, paper-b | 11 of 20 | 11/11 |
| LuaTeX, paper-a | 8 of 20 | 8/8 |
| LuaTeX, paper-b | 7 | 7/7 |
| XeTeX, paper-a / paper-b | 7 / 5 | on the exact baselines (≤ 0.0005 pt) |
| pdfTeX, 1512.03385 | 8 | 8/8 |
| list-heavy document (24 edits), pdfTeX / LuaTeX / XeTeX | 17 / 7 / 7 | all |
| synth-10 first page, pdfTeX | 19 of 19 | 19/19 |

The other edits get `none` (in a box, crossing a page or column, followed by an insert) or `provisional`. Two-column
papers cross columns often.

### Paragraph preview latency

TeX time is warm pass ready → lines written; a key every 120 ms, 100 keys, p50 / p90.

| | pdfTeX | XeTeX | LuaTeX |
|---|---|---|---|
| TeX time, paper-a | 1.28 / 1.77 ms | 1.43 / 1.77 ms | 2.02 / 2.53 ms |
| TeX time, paper-b | 2.91 / 4.92 ms | 2.06 / 3.65 ms | 8.14 / 9.70 ms\* |
| edit → `para` event p50, paper-b | 4.2–5.8 ms | 4.6–5.8 ms | 7–10 ms |
| edit → `para` event p50, synth-300 | 3.3 ms | | 6.3 ms |

\* Bimodal: the slow keys are one paragraph that crosses a column, whose pass ships the first column through LaTeX's
`\shipout`. LuaTeX passes that give an overlay take 2.7–2.9 ms.

A pdfTeX event: edit → pass signalled 0.2 ms, wake 0.2, pass setup ~0.7, TeX ~2.9, reader 0.7. On paper-b, line
breaking is 1.33 ms of the TeX time, the same work the exact run does. LuaTeX is ≈1.4× pdfTeX in every phase. Pass
time doesn't grow with the document. Typing a burst (8 keys a second) on synth-10's first page, the six keys at one
spot show in 62, 3, 3, 3, 3, 3 ms; the first key has no snapshot near the edit yet.

### Typing: display page and exact page

pdfLaTeX, bench's memory session (`docs/bench.md`), p50 over 30 isolated keys.

| document | key → display page | key → exact page |
|---|---|---|
| synth-10 | 17 ms | 44 ms |
| synth-100 | 16 ms | 39 ms |
| synth-300 | 18 ms | 45 ms |
| 1512.03385 | 27 ms | 55 ms |
| 1706.03762 | 38 ms | 60 ms |
| 2103.00020 (paper-b) | 37 ms | 64 ms |

LuaLaTeX on paper-b: display page 27–32 ms, ~25 of it TeX up to the page's ship. XeLaTeX on paper-b: edit → PDF of
the edited page 24.5 ms.

A key far from recent edits after a reap resumes further back. With the app's `cursor`, the scout brings a first key
at a bench spot after a 3 s rest to 42–53 ms (synth-300) and 58–74 ms (2103.00020). Without a cursor, as bench drives
it, such keys take 40–142 ms (107–139 on synth-300).

### Open → first PDF and done

pdfLaTeX with a settled `.aux`, p50 / p90 over 6 runs, patched pdfTeX interleaved:

| document | tau-live | patched pdfTeX |
|---|---|---|
| synth-10 | 238 / 278 ms | 223–230 ms |
| synth-300 | 216 / 216 ms | 227–230 ms |
| 1706.03762 | 352 / 362 ms | 370–372 ms |
| 2103.00020 | 362 / 366 ms | 376–378 ms |

With no `.aux`, the first-page finish gives XeLaTeX 0.29–0.31 s and LuaLaTeX 0.61 s on paper-b.

First compile to `done`, paper-b with its `.bbl` and no `.aux`, p50 of 3. pdfLaTeX's numbers predate the unlocked
`getc`, which took 2103.00020's settled `done` from 1152 to 1028 ms.

| | runs | default | parked engine |
|---|---|---|---|
| pdfLaTeX | 2 | 2.64 s | 2.58 s |
| XeLaTeX | 3 | 1.90 s | 1.82 s |
| LuaLaTeX | 3 | 4.02 s | 3.72 s |

The reruns are latexmk's (hyperref's `.out`, BibTeX's `.bbl`, then the `\bibcite`s). Format loading is 0.07 s
(pdfTeX), 0.09 (XeTeX), 0.24 (LuaTeX) of a run. A reopened project with `--state` settles in one run.

### Memory

pdfLaTeX, bench's memory session (open, 5 s, 30 isolated keys, bursts, 15 s), phys_footprint summed over the process
group, two sessions each. MB; idle is the mean of the idle phases, typing columns are peaks. Rosina's numbers are from
`docs/bench.md` (quick mode).

| document | idle after open | isolated keys | bursts | 10–15 s after | processes typing | Rosina idle / peak / after |
|---|---|---|---|---|---|---|
| synth-10 | 62 | 136 | 135–142 | 82 | 16 | 103 / 121–125 / 104–105 |
| synth-100 | 95–101 | 237 | 213–224 | 105–113 | 31 | 137 / 157–182 / 133–139 |
| synth-300 | 144 | 312–325 | 308–337 | 137 | 36 | 160 / 202–243 / 176–177 |
| 1512.03385 | 89 | 211 | 194–216 | 118–124 | 21 | 112 / 127–149 / 107–115 |
| 1706.03762 | 129 | 239–251 | 215–241 | 123 | 24 | 121–126 / 118–127 / 118–121 |
| 2103.00020 | 172 | 405 | 377 | 163–182 | 36 | 131–134 / 129–191 / 118–135 |

At rest after typing, universal is below Rosina on 10, 100 and 300 pages, within 5 MB on 1706.03762, and above it on
1512.03385 (+10–15) and 2103.00020 (+30–45). Typing peaks are 1.1–1.9× Rosina's: universal keeps the warm pass,
finishers and the run's snapshots, while Rosina shows its preview and its whole PDF 0.24–4.8 s later. XeLaTeX and
LuaLaTeX hold more (synth-10 after typing and a reap, before the budget: 266 and 288 MB, against 86 for pdfLaTeX).

## Open

- Snapshots cost ~10% of a first run.
- The native fetcher has no prefetch of a package's other files and no fallback during a store outage.
- A provisional pass could stop at its first break inside the paragraph instead of shipping a column.
- Far keys without a cursor are slower on long documents (the budget keeps ~9 snapshots for a 1.1 s run on 300 pages).
- On 1512.03385 the rest after bursts is 118–124 MB against 99–110 before the budget.
- On a page with PNG figures every finisher decodes them again at `\end` (pdfTeX writes `\pdfximage`s when it
  closes); zcache saves the deflate, not the inflate.
- No cap on finishers or passes while typing.
