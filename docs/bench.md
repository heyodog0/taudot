# Live typesetting, side by side

Taudot's live typesetting next to the other live LaTeX systems and stock `latexmk`, on the same documents, with the
same edits, on one Mac. Everything here comes from one command (`bench/README.md`); the raw rows are in
`bench/results/`.

![Edit to exact page, median ms, by document length](bench.svg)

## Verdict

(Rerun 2026-11-09/10 on main 57c3ad7, M4 Pro, 14 cores. Other agents' work kept 3–5 cores busy throughout; each run
is the quietest of up to three, and its figure is in the first-compile table.)

### pdfLaTeX: universal (unpatched pdfTeX under libtau) against the patched engine

Universal's rows are from main c6881dd (2026-11-10, with uspeed's fixes for first pages, display pages and the
preview reader); the patched engine's and everyone else's from the run above.

- **Exact on every key.** tau-live's finished pages and whole PDFs equal stock pdfLaTeX's for all 180 keys (6
  documents × 30), and all 168 display pages it sent have stock's content stream byte for byte and draw the same
  pixels at 288 dpi. The patched engine: 180/180.
- **First exact pixels after a key: universal is now ahead.** A display page comes on 168 of 180 keys (all 30 at 100
  and 300 pages, on 1512.03385 and 2103.00020; 24 on synth-10 and 1706.03762), p50 17–38 ms; the patched engine's first exact page is 33–62 ms. Universal's finished
  page follows at 49–78 ms; whole PDF 66–483 ms against 61–515 ms.
- **First page on open**: 308–468 ms against the patched engine's 220–440 ms (was up to 1.3 s at 300 pages).
- **Paragraph preview**: p50 4.4–15.4 ms against 3.2–8.8 ms; exact previews on 12–25 of 30 keys against 14–25
  (1512.03385 now 20, was 1).
- **Behind, still**: since display pages come on every key, tau-live's own preview time and its finished page went up
  (preview own p50 e.g. 3.6 → 6.1 ms at 10 pages; finished page +3 to +16 ms at the same load), so per key the
  preview is now about 2–8 ms behind the patched engine. Memory 165–560 MB against 130–515 MB (summed RSS, an upper
  bound).

### All engines

- **Exact page after a key: only Taudot is under 100 ms, on all three engines**, and it barely grows with the
  document: pdfLaTeX 33–62 ms (patched) and 17–38 ms (universal's display page), XeLaTeX 18–35 ms (now a PDF, tau-pdfmx
  included), LuaLaTeX 39–69 ms (display pages 13–27 ms where sent). Every finished page equals stock. The other exact routes take 0.3–9 s and grow with
  length: latexmk 0.4–1.2 s (LuaLaTeX 0.7–3.3 s), Rosina's full build 0.3–5.7 s, rtex's background layout 1.3–8.9 s.
- **Whole exact PDF**: Taudot pdfLaTeX (universal) 66 ms / 171 ms / 483 ms at 10 / 100 / 300 pages against latexmk's 413 /
  661 / 1174 ms and a bare stock run's 286 / 543 / 987 ms. LuaLaTeX at 300 pages: Taudot 1.3 s, rtex's export
  3.1 s, latexmk 3.3 s.
- **Paragraph preview on LuaLaTeX: rtex covers every key, Taudot more often has nothing.** rtex's own figure is
  1.6–4.5 ms and it previewed 30/30 keys (wall through `rtex serve`, display lists as inline JSON: 10–19 ms).
  Taudot universal: 3.7 / 4.2 / 11.9 ms wall at 10 / 100 / 300 pages, on 19–26 of 30 keys (the first key at a new
  spot never gets one; a paragraph across a page or column, or in a box, gets none).
- **Rosina** previews every key on pdfLaTeX and most on XeLaTeX (provisional by design); its own figure is
  24–80 ms, but in PDF-output mode the composite PDF makes a saved key show after 0.12–1.5 s. No previews on these
  LuaLaTeX documents ("paragraph shares a captured row"). One full build in 180 differed from stock (2103.00020).
- **TeXpresso** reaches the edited XDV page in 17–65 ms (p90 2.5 s at 300 pages), writes no PDF, and its XeTeX
  predates TeX Live 2025 (errors on every display equation with LaTeX 2026).
- **Typst** `watch`: 120–296 ms from the save to the PDF, ~110 ms of it the file watcher; its own compile 6 /
  50 / 176 ms. It missed one save in about 270 (a repeat attempt, discarded).

## What is measured

Every system gets the same **edit script**: at five spots in the document (the middle of the prose paragraphs at
50, 10, 90, 30 and 70 % of the way through, in that order) the six keys `quick ` are typed one at a time: 30 edits.
Each edit is a one-byte insert. After an edit the harness waits until the system has settled (its whole PDF, or
its last event for that edit), rests 300 ms, and sends the next one. So these are **isolated keys**, not a burst:
each number is one key's latency, not queued behind the previous one.

**Other work on the machine.** Other agents build and test on this Mac while the bench runs. Every second of a run
the harness sums the CPU of every process outside its own process tree (`ps`'s `%cpu`); the mean is the run's noise,
in cores busy elsewhere (of 14). A run above 3 cores is run again, up to three times, and the quietest is kept. The
figure is shown under each first-compile cell.

Times are wall clock in the harness, from the moment the edit leaves it (written to the system's stdin, or written
to the file for systems that watch the disk) to the moment the line announcing the result is read back. They
include the system's own process hand-offs, not drawing.

| Measure | Definition |
|---|---|
| **edit → paragraph preview** | The edited paragraph alone, typeset by the real engine and placed on the old page. Taudot: the `para` event (`docs/live-protocol.md`); rtex: `ParagraphUpdate`; Rosina: its `preview` event (a whole PDF with the region replaced). The cell's footnote counts how many of the 30 edits got one, and how many the system itself marks exact (same lines, same heights: the page around it is unchanged) or provisional. |
| **edit → display page** | tau-live only (pdfLaTeX, LuaLaTeX): a `pdf` event with `display: true`, the last finished PDF with the run's first page after the edit drawn anew, sent before the finish (`docs/live-protocol.md`). Checked against stock's page twice: the content stream byte for byte, and both pages drawn with Core Graphics at 288 dpi, every channel of every pixel. The footnote counts the keys that got one and how many of those showed the edited page itself (the run's first page can be the one before it). |
| **edit → exact page** | The page holding the edit, as the stock engine would set it. Taudot: the first `pdf` event after the edit that contains that page (the page index comes from latexmk's SyncTeX); its new pages are compared with latexmk's PDF (content stream and fonts; subset tags aside). XeLaTeX on tau-live: the event's `pdf_path` (tau-pdfmx's PDF of the changed pages), compared byte for byte with stock `xdvipdfmx -z 1 -s F-L` of latexmk's XDV written under the same XDV and PDF names, since xdvipdfmx's output depends on both. rtex: the `LayoutUpdate` after the edit (a background LuaLaTeX pass; pages as display lists). TeXpresso: the first `pages` event past the edited page (an XDV page in memory). Rosina, latexmk, Typst: the whole PDF (they write nothing earlier). |
| **edit → whole exact PDF** | The whole document's PDF, checked byte for byte against latexmk's (PDF `/ID` masked, since LuaTeX hashes the output path into it; XeTeX's XDV compared page by page). rtex: `export_pdf` (its clean LuaLaTeX build), sent with the edit. TeXpresso: its `done` (no file). |
| **first compile** | Start → first page available, and start → settled, from a project whose `.aux` is already settled (a reopened project). |
| **memory** | Peak resident size summed over the system's process tree, sampled every 200 ms with `ps` (latexmk: the peak of its child processes). Forked snapshots share copy-on-write pages, which this sum counts once per process: for Taudot, TeXpresso and Rosina it's an upper bound. |

p50 and p90 are over the 30 edits of one document.

## Documents

- **Synthetic articles** (`bench/gen.py`): 11 pt `article`, A4, amsmath, microtype, Latin Modern (`lmodern` with T1
  for pdfLaTeX, `fontspec` for XeLaTeX and LuaLaTeX); sections, paragraphs of 2–9 sentences with inline math,
  numbered display equations, lists. Plain words from a fixed vocabulary, generated from a fixed seed. The number
  of blocks is chosen by bisection so pdfLaTeX gives exactly **10, 100 and 300 pages** (XeLaTeX and LuaLaTeX
  give 10/102/303 and 10/101/301 with the same text). The **Typst** variant has the same text, page size, margins,
  font size and numbering in Typst markup.
- **Real papers** from the pdfsource corpus (arXiv sources, used outside the repo, not redistributed):
  1512.03385 (12 pp., one column), 1706.03762 (15 pp., `\input` sections: edits go in
  `model_architecture.tex`), 2103.00020 (48 pp., two columns, many figures). pdfLaTeX only, as they were written.
  Edit spots: the middle of five long prose lines (outside math) at the same fractions as above.

Every document's `.aux` is settled by stock runs before a system opens it.

## Systems

All built from source on this Mac (nothing prebuilt downloaded), the other systems into
`~/code/lab/taudot-ref/bench/`, outside the repo. Taudot's drivers are built from this repository at the commit in the tables' version line. TeX Live 2026 throughout: Overleaf's image of it from Taudot's
TeX Live store, files fetched on demand; the stock engines are TeX Live 2026's release source built as TeX Live
builds them.

| System | What runs | Driven as |
|---|---|---|
| **Taudot, patched pdfTeX** | `pdftex-live --serve` and pdfTeX with `clients/pdftex/patches/2026`, built from this commit | the app's protocol, `goal` = the edited page |
| **Taudot universal** | `tau-live --serve` (libtau under the **unmodified** engines) on pdfTeX, XeTeX, LuaTeX | same |
| [rtex](https://github.com/HenryXiaoYang/realtime-tex) (MIT) | `rtex serve`, LuaLaTeX only | after each edit, `request_layout` (skips its 300 ms debounce) and `export_pdf` |
| [liveTeX-Rosina](https://github.com/PetalAdrift/liveTeX-Rosina) (own licence) | `livetex-rosina --editor --debounce-ms 0`, PDF-output mode, fork-snapshot workers | the file saved on disk (it polls every 1 ms) |
| [TeXpresso](https://github.com/let-def/texpresso) (MIT) | its XeTeX engine and incremental frontend objects, unmodified, without its SDL window (`clients/preview/texpresso/txp-headless.c`) | its editor protocol: `open`, `change`, `goal` |
| [Typst](https://github.com/typst/typst) 0.15.1 (Apache-2.0) | `typst watch main.typ out.pdf` | the file saved on disk |
| latexmk | TeX Live 2026's `latexmk.pl` with the stock engines | one `latexmk` run per saved edit (its `-pvc` polling delay left out) |
| one stock run | the stock engine once, `.aux` already settled | the floor of any full recompile |

- **Rosina's licence** (LicenseRef-liveTeX-Rosina-1.0) allows obtaining, building and running it for one's own
  work (§2); it restricts hosted services (§4) and distributing modified copies, and says nothing against
  publishing measurements. It is run unmodified.
- **texlode** (closed, browser) isn't run. Its published numbers, **theirs**: line breaking 0.17–1.99 ms, round trip
  0.79–6.11 ms (Lode, TUG 2026 preprint, i7-1355U laptop), LuaLaTeX.

### What each needed to run here

- rtex, Rosina and TeXpresso look up TeX Live from `PATH`: they get a directory in TeX Live's layout
  (`bin/aarch64-darwin/`, `texmf-dist`, `texmf.cnf`) over the same store tree and stock engines. Rosina's resident
  workers locate the tree three levels above the engine binary, so the engines there are real files, not links.
- The store tree is filled on demand; the Latin Modern OpenType family (rtex's warm-up loads small caps) and
  Rosina's `currfile`/`preview` packages were fetched whole before the runs.
- TeXpresso's DVI reader insists on `kanjix.map` and `ckx.map`, which Overleaf's TeX Live image doesn't have: it
  gets empty ones in an extra tree.
- **TeXpresso's XeTeX predates TeX Live 2025**: LaTeX 2026 with microtype calls `\partokencontext`, which it doesn't
  have, so every display equation logs errors (TeX carries on). Its pages on these documents are therefore not
  what stock XeLaTeX 2026 makes; its times are still measured.

## Results

<!-- bench:begin -->
Machine: Apple M4 Pro, 24 GB, macOS 26.5; load average during runs 10.2–33.7 (other agents' work shared the machine). Dates: 2026-11-09, 2026-11-10. Cells: **p50 / p90 ms** over the 30 edits. Blank: the system doesn't support that engine.

Versions: latexmk `Latexmk, John Collins, 15 June 2025. Version 4.87`; rosina `liveTeX-Rosina dff263fc21`; rtex `rtex 0.0.7 fcff7a5c7f`; stock-run `TeX Live 2026 static engines`; taudot-pdftex `pdftex-live ad58f81329`; taudot-universal `tau-live ad58f81329`; taudot-universal `tau-live c6881dd60e`; texpresso `texpresso e8df770907 via txp-headless ad58f81329`; typst `typst 0.15.1 (9dfd3a08)`.

### Edit → paragraph preview

|  | 10 pp | 100 pp | 300 pp |
|---|---|---|---|
| **Taudot**, patched pdfTeX | 4.0 / 9.1<br><sub>25 exact, 0 prov. of 30</sub><br><sub>own p50 4.0</sub> | 3.4 / 5.1<br><sub>24 exact, 0 prov. of 30</sub><br><sub>own p50 3.3</sub> | 8.8 / 19.1<br><sub>24 exact, 0 prov. of 30</sub><br><sub>own p50 8.7</sub> |
| **Taudot** universal, pdfLaTeX | 6.9 / 10.0<br><sub>20 exact, 0 prov. of 30</sub><br><sub>own p50 6.1</sub> | 7.5 / 10.0<br><sub>20 exact, 0 prov. of 30</sub><br><sub>own p50 6.5</sub> | 7.7 / 11.1<br><sub>25 exact, 0 prov. of 30</sub><br><sub>own p50 6.9</sub> |
| **Taudot** universal, XeLaTeX | 3.9 / 10.9<br><sub>20 exact, 0 prov. of 30</sub><br><sub>own p50 3.6</sub> | 5.5 / 14.6<br><sub>19 exact, 0 prov. of 30</sub><br><sub>own p50 5.0</sub> | 10.4 / 17.3<br><sub>14 exact, 0 prov. of 30</sub><br><sub>own p50 10.0</sub> |
| **Taudot** universal, LuaLaTeX | 3.7 / 4.6<br><sub>20 exact, 0 prov. of 30</sub><br><sub>own p50 3.5</sub> | 4.2 / 5.3<br><sub>19 exact, 0 prov. of 30</sub><br><sub>own p50 3.9</sub> | 11.9 / 19.6<br><sub>26 exact, 0 prov. of 30</sub><br><sub>own p50 10.9</sub> |
| rtex, LuaLaTeX | 10.4 / 15.1<br><sub>30 exact, 0 prov. of 30</sub><br><sub>own p50 1.6</sub> | 15.5 / 29.5<br><sub>30 exact, 0 prov. of 30</sub><br><sub>own p50 2.3</sub> | 19.3 / 34.5<br><sub>30 exact, 0 prov. of 30</sub><br><sub>own p50 4.5</sub> |
| liveTeX-Rosina, pdfLaTeX | 137 / 147<br><sub>30 prov. of 30</sub><br><sub>own p50 24.0</sub> | 497 / 512<br><sub>30 prov. of 30</sub><br><sub>own p50 36.0</sub> | 1498 / 1515<br><sub>30 prov. of 30</sub><br><sub>own p50 49.0</sub> |
| liveTeX-Rosina, XeLaTeX | 120 / 134<br><sub>24 prov. of 30</sub><br><sub>own p50 66.0</sub> | 469 / 483<br><sub>24 prov. of 30</sub><br><sub>own p50 67.5</sub> | 1436 / 1488<br><sub>24 prov. of 30</sub><br><sub>own p50 79.5</sub> |
| liveTeX-Rosina, LuaLaTeX | – | – | – |

### Edit → exact page

|  | 10 pp | 100 pp | 300 pp |
|---|---|---|---|
| **Taudot**, patched pdfTeX | 41.9 / 81.4 | 32.6 / 48.2 | 44.0 / 59.4 |
| **Taudot** universal, pdfLaTeX | 49.2 / 154 | 49.8 / 62.7 | 49.2 / 57.8 |
| ↳ its display page | 16.8 / 22.5<br><sub>24 of 30, 24 the edited page</sub> | 20.4 / 27.9<br><sub>30 of 30, 30 the edited page</sub> | 18.1 / 26.7<br><sub>30 of 30, 30 the edited page</sub> |
| **Taudot** universal, XeLaTeX | 18.5 / 33.1 | 23.3 / 45.4 | 34.7 / 53.4 |
| **Taudot** universal, LuaLaTeX | 39.1 / 65.4 | 42.6 / 59.0 | 68.5 / 78.4 |
| ↳ its display page | 12.6 / 15.0<br><sub>24 of 30, 20 the edited page</sub> | 27.1 / 31.1<br><sub>30 of 30, 20 the edited page</sub> | 75.0 / 75.0<br><sub>1 of 30, 0 the edited page</sub> |
| rtex, LuaLaTeX | 1254 / 1278 | 3618 / 3665 | 8871 / 9023 |
| liveTeX-Rosina, pdfLaTeX | 305 / 327 | 1457 / 1475 | 4663 / 4686 |
| liveTeX-Rosina, XeLaTeX | 265 / 285 | 1320 / 1342 | 4256 / 4306 |
| liveTeX-Rosina, LuaLaTeX | 294 / 300 | 1855 / 1883 | 5685 / 5709 |
| TeXpresso, XeLaTeX | 16.8 / 34.6<br><sub>own p50 16.6</sub> | 34.6 / 152<br><sub>own p50 34.0</sub> | 64.5 / 2460<br><sub>own p50 63.1</sub> |
| Typst `watch` (not LaTeX) | 120 / 123<br><sub>own p50 6.2</sub> | 166 / 171<br><sub>own p50 49.7</sub> | 296 / 315<br><sub>own p50 176</sub> |
| latexmk, pdfLaTeX | 413 / 425 | 661 / 674 | 1174 / 1225 |
| latexmk, XeLaTeX | 426 / 430 | 683 / 696 | 1266 / 1336 |
| latexmk, LuaLaTeX | 678 / 696 | 1515 / 1541 | 3305 / 3329 |
| one stock run, pdfLaTeX | 286 / 298 | 543 / 571 | 987 / 1002 |
| one stock run, XeLaTeX | 255 / 260 | 400 / 465 | 707 / 728 |
| one stock run, LuaLaTeX | 558 / 564 | 1357 / 1371 | 3068 / 3086 |

### Edit → whole exact PDF

|  | 10 pp | 100 pp | 300 pp |
|---|---|---|---|
| **Taudot**, patched pdfTeX | 60.5 / 114 | 207 / 335 | 515 / 881 |
| **Taudot** universal, pdfLaTeX | 65.5 / 181 | 171 / 283 | 483 / 765 |
| **Taudot** universal, XeLaTeX | 27.9 / 44.7 | 134 / 195 | 322 / 556 |
| **Taudot** universal, LuaLaTeX | 89.5 / 145 | 488 / 817 | 1320 / 2316 |
| rtex, LuaLaTeX | 580 / 600 | 1372 / 1396 | 3124 / 3147 |
| liveTeX-Rosina, pdfLaTeX | 305 / 327 | 1457 / 1475 | 4663 / 4686 |
| liveTeX-Rosina, XeLaTeX | 265 / 285 | 1320 / 1342 | 4256 / 4306 |
| liveTeX-Rosina, LuaLaTeX | 294 / 300 | 1855 / 1883 | 5685 / 5709 |
| TeXpresso, XeLaTeX | 69.8 / 95.6 | 584 / 739 | 1310 / 2475 |
| Typst `watch` (not LaTeX) | 120 / 123 | 166 / 171 | 296 / 315 |
| latexmk, pdfLaTeX | 413 / 425 | 661 / 674 | 1174 / 1225 |
| latexmk, XeLaTeX | 426 / 430 | 683 / 696 | 1266 / 1336 |
| latexmk, LuaLaTeX | 678 / 696 | 1515 / 1541 | 3305 / 3329 |
| one stock run, pdfLaTeX | 286 / 298 | 543 / 571 | 987 / 1002 |
| one stock run, XeLaTeX | 255 / 260 | 400 / 465 | 707 / 728 |
| one stock run, LuaLaTeX | 558 / 564 | 1357 / 1371 | 3068 / 3086 |

### Real papers (pdfLaTeX): edit → preview, exact page, whole PDF

| preview | 1512.03385 | 1706.03762 | 2103.00020 |
|---|---|---|---|
| **Taudot**, patched pdfTeX | 3.2 / 4.1<br><sub>23 exact, 0 prov. of 30</sub><br><sub>own p50 3.1</sub> | 3.4 / 5.1<br><sub>15 exact, 0 prov. of 30</sub><br><sub>own p50 3.3</sub> | 7.0 / 11.3<br><sub>14 exact, 0 prov. of 30</sub><br><sub>own p50 6.9</sub> |
| **Taudot** universal, pdfLaTeX | 4.4 / 11.2<br><sub>20 exact, 0 prov. of 30</sub><br><sub>own p50 3.9</sub> | 8.0 / 11.9<br><sub>17 exact, 0 prov. of 30</sub><br><sub>own p50 7.2</sub> | 15.4 / 20.0<br><sub>12 exact, 0 prov. of 30</sub><br><sub>own p50 11.1</sub> |
| liveTeX-Rosina, pdfLaTeX | – | – | – |

| exact page | 1512.03385 | 1706.03762 | 2103.00020 |
|---|---|---|---|
| **Taudot**, patched pdfTeX | 39.1 / 49.6 | 58.8 / 87.2 | 62.0 / 76.3 |
| **Taudot** universal, pdfLaTeX | 50.0 / 70.7 | 78.4 / 97.4 | 70.8 / 88.3 |
| ↳ its display page | 17.8 / 34.4<br><sub>30 of 30, 30 the edited page</sub> | 38.5 / 56.4<br><sub>24 of 30, 24 the edited page</sub> | 28.5 / 52.0<br><sub>30 of 30, 18 the edited page</sub> |
| liveTeX-Rosina, pdfLaTeX | 632 / 650 | 2999 / 3175 | 4736 / 4845 |
| latexmk, pdfLaTeX | 645 / 687 | 916 / 936 | 1087 / 1138 |
| one stock run, pdfLaTeX | 481 / 510 | 748 / 774 | 902 / 933 |

| whole PDF | 1512.03385 | 1706.03762 | 2103.00020 |
|---|---|---|---|
| **Taudot**, patched pdfTeX | 136 / 171 | 149 / 214 | 437 / 644 |
| **Taudot** universal, pdfLaTeX | 126 / 172 | 154 / 207 | 419 / 615 |
| liveTeX-Rosina, pdfLaTeX | 632 / 650 | 2999 / 3175 | 4736 / 4845 |
| latexmk, pdfLaTeX | 645 / 687 | 916 / 936 | 1087 / 1138 |
| one stock run, pdfLaTeX | 481 / 510 | 748 / 774 | 902 / 933 |

### Checked against stock (all documents)

| | display page = stock | exact page = stock | whole PDF = stock |
|---|---|---|---|
| **Taudot**, patched pdfTeX |  | 180 / 180 | 180 / 180 |
| **Taudot** universal, pdfLaTeX | 168 / 168 | 180 / 180 | 180 / 180 |
| **Taudot** universal, XeLaTeX |  | 90 / 90 | 90 / 90 |
| **Taudot** universal, LuaLaTeX | 55 / 55 | 90 / 90 | 90 / 90 |
| rtex, LuaLaTeX |  | claimed (display lists) | 90 / 90 |
| liveTeX-Rosina, pdfLaTeX |  | 179 / 180 (1 differ) | 179 / 180 (1 differ) |
| liveTeX-Rosina, XeLaTeX |  | 90 / 90 | 90 / 90 |
| liveTeX-Rosina, LuaLaTeX |  | 90 / 90 | 90 / 90 |
| TeXpresso, XeLaTeX |  | not checkable | not checkable |
| Typst `watch` (not LaTeX) |  | not checkable | not checkable |

### First compile and memory

| | 10 pp: first page / settled / peak RSS | 100 pp: first page / settled / peak RSS | 300 pp: first page / settled / peak RSS |
|---|---|---|---|
| **Taudot**, patched pdfTeX | 220 / 251 ms / 130 MB<br><sub>3.69 cores busy elsewhere</sub> | 235 / 560 ms / 252 MB<br><sub>3.51 cores busy elsewhere</sub> | 234 / 1156 ms / 514 MB<br><sub>3.96 cores busy elsewhere</sub> |
| **Taudot** universal, pdfLaTeX | 355 / 391 ms / 165 MB<br><sub>3.12 cores busy elsewhere</sub> | 308 / 598 ms / 354 MB<br><sub>3.95 cores busy elsewhere</sub> | 362 / 1285 ms / 497 MB<br><sub>3.96 cores busy elsewhere</sub> |
| **Taudot** universal, XeLaTeX | 291 / 292 ms / 370 MB<br><sub>3.59 cores busy elsewhere</sub> | 485 / 486 ms / 527 MB<br><sub>3.86 cores busy elsewhere</sub> | 952 / 952 ms / 711 MB<br><sub>3.18 cores busy elsewhere</sub> |
| **Taudot** universal, LuaLaTeX | 617 / 618 ms / 483 MB<br><sub>4.16 cores busy elsewhere</sub> | 1764 / 1768 ms / 1184 MB<br><sub>4.30 cores busy elsewhere</sub> | 3343 / 3353 ms / 2641 MB<br><sub>3.83 cores busy elsewhere</sub> |
| rtex, LuaLaTeX | 1705 / 1705 ms / 478 MB<br><sub>4.39 cores busy elsewhere</sub> | 8386 / 8386 ms / 768 MB<br><sub>3.92 cores busy elsewhere</sub> | 24643 / 24643 ms / 1361 MB<br><sub>3.39 cores busy elsewhere</sub> |
| liveTeX-Rosina, pdfLaTeX | 1628 / 1628 ms / 135 MB<br><sub>2.67 cores busy elsewhere</sub> | 2757 / 2757 ms / 197 MB<br><sub>3.88 cores busy elsewhere</sub> | 5537 / 5537 ms / 290 MB<br><sub>3.87 cores busy elsewhere</sub> |
| liveTeX-Rosina, XeLaTeX | 2178 / 2178 ms / 443 MB<br><sub>4.00 cores busy elsewhere</sub> | 3093 / 3093 ms / 477 MB<br><sub>4.35 cores busy elsewhere</sub> | 5362 / 5362 ms / 548 MB<br><sub>4.83 cores busy elsewhere</sub> |
| liveTeX-Rosina, LuaLaTeX | 5033 / 5033 ms / 574 MB<br><sub>4.67 cores busy elsewhere</sub> | 8893 / 8893 ms / 678 MB<br><sub>4.01 cores busy elsewhere</sub> | 18091 / 18091 ms / 831 MB<br><sub>3.81 cores busy elsewhere</sub> |
| TeXpresso, XeLaTeX | 401 / 401 ms / 451 MB<br><sub>3.74 cores busy elsewhere</sub> | 1122 / 1122 ms / 331 MB<br><sub>3.84 cores busy elsewhere</sub> | 3029 / 3029 ms / 646 MB<br><sub>4.01 cores busy elsewhere</sub> |
| Typst `watch` (not LaTeX) | 111 / 111 ms / 168 MB<br><sub>4.53 cores busy elsewhere</sub> | 377 / 377 ms / 1362 MB<br><sub>6.42 cores busy elsewhere</sub> | 1087 / 1087 ms / 3741 MB<br><sub>3.86 cores busy elsewhere</sub> |
| latexmk, pdfLaTeX | 407 / 407 ms / 50 MB<br><sub>4.11 cores busy elsewhere</sub> | 704 / 704 ms / 50 MB<br><sub>2.61 cores busy elsewhere</sub> | 1207 / 1207 ms / 50 MB<br><sub>3.94 cores busy elsewhere</sub> |
| latexmk, XeLaTeX | 507 / 507 ms / 185 MB<br><sub>3.69 cores busy elsewhere</sub> | 686 / 686 ms / 186 MB<br><sub>4.43 cores busy elsewhere</sub> | 1271 / 1271 ms / 189 MB<br><sub>4.97 cores busy elsewhere</sub> |
| latexmk, LuaLaTeX | 664 / 664 ms / 151 MB<br><sub>3.90 cores busy elsewhere</sub> | 1534 / 1534 ms / 170 MB<br><sub>4.34 cores busy elsewhere</sub> | 3294 / 3294 ms / 181 MB<br><sub>4.05 cores busy elsewhere</sub> |
<!-- bench:end -->

## Reproduce

See `bench/README.md`.
