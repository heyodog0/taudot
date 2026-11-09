# Live typesetting, side by side

Taudot's live typesetting next to the other live LaTeX systems and stock `latexmk`, on the same documents, with the
same edits, on one Mac. Everything here comes from one command (`bench/README.md`); the raw rows are in
`bench/results/`.

![Edit to exact page, median ms, by document length](bench.svg)

## Verdict

(2026-11-09, M4 Pro, other agents' work on the machine: load average 2–10.)

- **Exact page after a key: Taudot is the only system under 100 ms, and it doesn't grow with the document.**
  pdfLaTeX p50 31–36 ms at 10, 100 and 300 pages (patched and unpatched engines alike), LuaLaTeX 51–75 ms, XeLaTeX
  7–13 ms (an XDV page; turning the whole XDV into a PDF with xdvipdfmx costs another 50–240 ms). Every page checked
  equals stock. The other exact routes take 0.3–9 s and grow with length: latexmk 0.4–1.2 s (LuaLaTeX 0.7–3.4 s),
  Rosina's full build 0.3–5.7 s, rtex's background layout 1.2–8.9 s.
- **Whole exact PDF**: Taudot pdfLaTeX 46–50 ms at 10 pages, 150–170 ms at 100, 440–500 ms at 300: 2.3–8× faster
  than latexmk, and faster than one bare stock run (274 ms / 468 ms / 1.04 s), because it resumes from a snapshot
  before the edit. LuaLaTeX at 300 pages: Taudot 1.7 s, rtex's export 3.1 s, latexmk 3.4 s.
- **Paragraph preview: rtex wins on LuaLaTeX, and previews more keys.** rtex's own figure is 1.2–1.5 ms, flat from
  10 to 300 pages, and it previewed all 30 keys; through `rtex serve` (display lists as inline JSON) the harness
  sees 8–10 ms. Taudot universal on LuaLaTeX: 5 ms at 10 pages but 25 ms at 300, and 20–25 of 30 keys. On pdfTeX the
  patched engine gives 3–5 ms at every length (24–25 of 30); the unpatched route grows with length (3 → 14 ms on
  pdfLaTeX, 4 → 10 ms on XeLaTeX). Taudot's misses are by design (the first key at a new spot has no warm pass; a
  paragraph across a page or column, or in a box, gets none), but rtex covers them.
- **Rosina** previews every key on pdfLaTeX and most on XeLaTeX, provisional by design. Its own figure is 22–77 ms,
  but in PDF-output mode it writes the whole document with the region replaced, so a saved key shows after 140 ms
  at 10 pages and 1.5 s at 300. (Its quick-viewer mode, used by its VS Code extension, skips that and wasn't
  measured.) On these LuaLaTeX documents it gave no preview at all ("paragraph shares a captured row").
- **TeXpresso** reaches the edited XDV page fast (p50 12–66 ms) but has long tails at 300 pages (p90 2.4 s), writes
  no PDF, and its XeTeX predates TeX Live 2025 (LaTeX 2026 logs errors on every display equation here).
- **Typst** `watch`: 125–260 ms from the save to the PDF, of which ~110 ms is its file watcher; its own compile is
  8 / 50 / 145 ms. A different typesetter, so not comparable for exactness.
- **First compile**: patched pdfTeX shows the first page in ~200–225 ms at any length (it finishes a PDF at the first
  ship). Memory: Taudot universal on LuaLaTeX peaks at 2.4 GB summed RSS at 300 pages (an upper bound: forked
  snapshots share pages).

Bugs this found, not in the bench: **tau-live runs BibTeX when the project has no `.bib`** and replaces the shipped
`.bbl` with an empty one, so citations disappear (arXiv sources ship only the `.bbl`); that is all 60 of its
mismatches against stock (1512.03385 and 2103.00020). latexmk and the patched driver don't. Rosina's full build
differed from stock once in 180 (2103.00020, edit 25).

## What is measured

Every system gets the same **edit script**: at five spots in the document (the middle of the prose paragraphs at
50, 10, 90, 30 and 70 % of the way through, in that order) the six keys `quick ` are typed one at a time: 30 edits.
Each edit is a one-byte insert. After an edit the harness waits until the system has settled (its whole PDF, or
its last event for that edit), rests 300 ms, and sends the next one. So these are **isolated keys**, not a burst:
each number is one key's latency with the machine otherwise idle (apart from other work on the Mac; the load
average is recorded).

Times are wall clock in the harness, from the moment the edit leaves it (written to the system's stdin, or written
to the file for systems that watch the disk) to the moment the line announcing the result is read back. They
include the system's own process hand-offs, not drawing.

| Measure | Definition |
|---|---|
| **edit → paragraph preview** | The edited paragraph alone, typeset by the real engine and placed on the old page. Taudot: the `para` event (`docs/live-protocol.md`); rtex: `ParagraphUpdate`; Rosina: its `preview` event (a whole PDF with the region replaced). The cell's footnote counts how many of the 30 edits got one, and how many the system itself marks exact (same lines, same heights: the page around it is unchanged) or provisional. |
| **edit → exact page** | The page holding the edit, as the stock engine would set it. Taudot: the first `pdf` event after the edit that contains that page (the page index comes from latexmk's SyncTeX); its new pages are compared with latexmk's PDF. rtex: the `LayoutUpdate` after the edit (a background LuaLaTeX pass; pages as display lists). TeXpresso: the first `pages` event past the edited page (an XDV page in memory). Rosina, latexmk, Typst: the whole PDF (they write nothing earlier). |
| **edit → whole exact PDF** | The whole document's PDF, checked byte for byte against latexmk's (PDF `/ID` masked, since LuaTeX hashes the output path into it; XeTeX's XDV compared page by page). rtex: `export_pdf` (its clean LuaLaTeX build), sent with the edit. TeXpresso: its `done` (no file). |
| **first compile** | Start → first page available, and start → settled, from a project whose `.aux` is already settled (a reopened project). |
| **memory** | Peak resident size summed over the system's process tree, sampled every 50 ms with `ps` (latexmk: the peak of its child processes). Forked snapshots share copy-on-write pages, which this sum counts once per process: for Taudot, TeXpresso and Rosina it's an upper bound. |

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
`~/code/lab/taudot-ref/bench/`, outside the repo. TeX Live 2026 throughout: Overleaf's image of it from Taudot's
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
Machine: Apple M4 Pro, 24 GB, macOS 26.5; load average during runs 2.3–10.3 (other agents' work shared the machine). Dates: 2026-11-09. Cells: **p50 / p90 ms** over the 30 edits. Blank: the system doesn't support that engine.

Versions: latexmk `Latexmk, John Collins, 15 June 2025. Version 4.87`; rosina `liveTeX-Rosina dff263fc21`; rtex `rtex 0.0.7 fcff7a5c7f`; stock-run `TeX Live 2026 static engines`; taudot-pdftex `pdftex-live 7f784f29c2`; taudot-pdftex `pdftex-live c4a8222e59`; taudot-universal `tau-live 7f784f29c2`; taudot-universal `tau-live c4a8222e59`; texpresso `texpresso e8df770907 via txp-headless 7f784f29c2`; texpresso `texpresso e8df770907 via txp-headless c4a8222e59`; typst `typst 0.15.1 (9dfd3a08)`.

### Edit → paragraph preview

|  | 10 pp | 100 pp | 300 pp |
|---|---|---|---|
| **Taudot**, patched pdfTeX | 3.2 / 4.0<br><sub>25 exact, 0 prov. of 30</sub><br><sub>own p50 3.1</sub> | 3.6 / 5.3<br><sub>24 exact, 0 prov. of 30</sub><br><sub>own p50 3.5</sub> | 4.6 / 7.4<br><sub>24 exact, 0 prov. of 30</sub><br><sub>own p50 4.6</sub> |
| **Taudot** universal, pdfLaTeX | 3.1 / 3.5<br><sub>20 exact, 0 prov. of 30</sub><br><sub>own p50 2.5</sub> | 6.0 / 7.0<br><sub>20 exact, 0 prov. of 30</sub><br><sub>own p50 5.3</sub> | 13.9 / 15.2<br><sub>25 exact, 0 prov. of 30</sub><br><sub>own p50 12.9</sub> |
| **Taudot** universal, XeLaTeX | 3.6 / 6.3<br><sub>20 exact, 0 prov. of 30</sub><br><sub>own p50 2.9</sub> | 5.0 / 5.6<br><sub>19 exact, 0 prov. of 30</sub><br><sub>own p50 4.4</sub> | 9.9 / 12.5<br><sub>14 exact, 0 prov. of 30</sub><br><sub>own p50 8.8</sub> |
| **Taudot** universal, LuaLaTeX | 5.2 / 6.1<br><sub>20 exact, 0 prov. of 30</sub><br><sub>own p50 4.6</sub> | 9.4 / 12.3<br><sub>20 exact, 0 prov. of 30</sub><br><sub>own p50 8.8</sub> | 24.5 / 39.5<br><sub>25 exact, 0 prov. of 30</sub><br><sub>own p50 23.4</sub> |
| rtex, LuaLaTeX | 7.7 / 14.5<br><sub>30 exact, 0 prov. of 30</sub><br><sub>own p50 1.2</sub> | 9.1 / 18.1<br><sub>30 exact, 0 prov. of 30</sub><br><sub>own p50 1.3</sub> | 9.7 / 13.8<br><sub>30 exact, 0 prov. of 30</sub><br><sub>own p50 1.5</sub> |
| liveTeX-Rosina, pdfLaTeX | 140 / 151<br><sub>30 prov. of 30</sub><br><sub>own p50 22.0</sub> | 516 / 531<br><sub>30 prov. of 30</sub><br><sub>own p50 26.5</sub> | 1514 / 1601<br><sub>30 prov. of 30</sub><br><sub>own p50 41.0</sub> |
| liveTeX-Rosina, XeLaTeX | 106 / 111<br><sub>24 prov. of 30</sub><br><sub>own p50 54.0</sub> | 426 / 443<br><sub>24 prov. of 30</sub><br><sub>own p50 56.0</sub> | 1521 / 1589<br><sub>24 prov. of 30</sub><br><sub>own p50 77.0</sub> |
| liveTeX-Rosina, LuaLaTeX | – | – | – |

### Edit → exact page

|  | 10 pp | 100 pp | 300 pp |
|---|---|---|---|
| **Taudot**, patched pdfTeX | 31.5 / 64.5 | 33.0 / 44.3 | 36.2 / 45.3 |
| **Taudot** universal, pdfLaTeX | 31.9 / 129 | 31.7 / 42.4 | 30.6 / 38.1 |
| **Taudot** universal, XeLaTeX | 7.0 / 11.7 | 8.2 / 15.9 | 13.0 / 25.5 |
| **Taudot** universal, LuaLaTeX | 51.0 / 78.6 | 59.6 / 74.6 | 74.8 / 97.6 |
| rtex, LuaLaTeX | 1202 / 1303 | 3584 / 3764 | 9037 / 9283 |
| liveTeX-Rosina, pdfLaTeX | 304 / 326 | 1494 / 1514 | 4772 / 5044 |
| liveTeX-Rosina, XeLaTeX | 243 / 261 | 1218 / 1238 | 4358 / 4559 |
| liveTeX-Rosina, LuaLaTeX | 270 / 286 | 1840 / 1900 | 5746 / 5947 |
| TeXpresso, XeLaTeX | 12.5 / 29.3<br><sub>own p50 12.3</sub> | 35.9 / 123<br><sub>own p50 35.3</sub> | 65.6 / 2396<br><sub>own p50 63.9</sub> |
| Typst `watch` (not LaTeX) | 125 / 128<br><sub>own p50 8.2</sub> | 164 / 169<br><sub>own p50 50.0</sub> | 260 / 298<br><sub>own p50 145</sub> |
| latexmk, pdfLaTeX | 392 / 400 | 618 / 643 | 1175 / 1219 |
| latexmk, XeLaTeX | 411 / 432 | 655 / 675 | 1280 / 1349 |
| latexmk, LuaLaTeX | 656 / 672 | 1447 / 1513 | 3378 / 3497 |
| one stock run, pdfLaTeX | 274 / 297 | 468 / 484 | 1039 / 1142 |
| one stock run, XeLaTeX | 235 / 239 | 365 / 373 | 678 / 694 |
| one stock run, LuaLaTeX | 504 / 518 | 1335 / 1377 | 3002 / 3080 |

### Edit → whole exact PDF

|  | 10 pp | 100 pp | 300 pp |
|---|---|---|---|
| **Taudot**, patched pdfTeX | 50.2 / 89.2 | 169 / 291 | 504 / 873 |
| **Taudot** universal, pdfLaTeX | 45.6 / 151 | 154 / 257 | 444 / 763 |
| **Taudot** universal, XeLaTeX | 21.5 / 29.0 | 95.4 / 167 | 304 / 512 |
| **Taudot** universal, LuaLaTeX | 90.9 / 160 | 540 / 945 | 1727 / 2662 |
| rtex, LuaLaTeX | 554 / 637 | 1358 / 1430 | 3170 / 3313 |
| liveTeX-Rosina, pdfLaTeX | 304 / 326 | 1494 / 1514 | 4772 / 5044 |
| liveTeX-Rosina, XeLaTeX | 243 / 261 | 1218 / 1238 | 4358 / 4559 |
| liveTeX-Rosina, LuaLaTeX | 270 / 286 | 1840 / 1900 | 5746 / 5947 |
| TeXpresso, XeLaTeX | 63.1 / 75.0 | 538 / 689 | 1385 / 2441 |
| Typst `watch` (not LaTeX) | 125 / 128 | 164 / 169 | 260 / 298 |
| latexmk, pdfLaTeX | 392 / 400 | 618 / 643 | 1175 / 1219 |
| latexmk, XeLaTeX | 411 / 432 | 655 / 675 | 1280 / 1349 |
| latexmk, LuaLaTeX | 656 / 672 | 1447 / 1513 | 3378 / 3497 |
| one stock run, pdfLaTeX | 274 / 297 | 468 / 484 | 1039 / 1142 |
| one stock run, XeLaTeX | 235 / 239 | 365 / 373 | 678 / 694 |
| one stock run, LuaLaTeX | 504 / 518 | 1335 / 1377 | 3002 / 3080 |

### Real papers (pdfLaTeX): edit → preview, exact page, whole PDF

| preview | 1512.03385 | 1706.03762 | 2103.00020 |
|---|---|---|---|
| **Taudot**, patched pdfTeX | 3.1 / 4.2<br><sub>23 exact, 0 prov. of 30</sub><br><sub>own p50 3.0</sub> | 2.6 / 3.6<br><sub>15 exact, 0 prov. of 30</sub><br><sub>own p50 2.5</sub> | 5.0 / 6.2<br><sub>14 exact, 0 prov. of 30</sub><br><sub>own p50 5.0</sub> |
| **Taudot** universal, pdfLaTeX | 3.0 / 4.1<br><sub>5 exact, 0 prov. of 30</sub><br><sub>own p50 2.4</sub> | 4.2 / 6.4<br><sub>17 exact, 0 prov. of 30</sub><br><sub>own p50 3.5</sub> | 6.7 / 7.7<br><sub>16 exact, 0 prov. of 30</sub><br><sub>own p50 6.1</sub> |
| liveTeX-Rosina, pdfLaTeX | – | – | – |

| exact page | 1512.03385 | 1706.03762 | 2103.00020 |
|---|---|---|---|
| **Taudot**, patched pdfTeX | 37.4 / 50.8 | 53.8 / 74.8 | 50.3 / 61.7 |
| **Taudot** universal, pdfLaTeX | 35.9 / 46.2 | 61.1 / 78.6 | 57.9 / 107 |
| liveTeX-Rosina, pdfLaTeX | 629 / 657 | 2903 / 2988 | 4722 / 4824 |
| latexmk, pdfLaTeX | 694 / 1004 | 893 / 913 | 1093 / 1230 |
| one stock run, pdfLaTeX | 480 / 522 | 726 / 750 | 847 / 913 |

| whole PDF | 1512.03385 | 1706.03762 | 2103.00020 |
|---|---|---|---|
| **Taudot**, patched pdfTeX | 124 / 160 | 142 / 195 | 452 / 627 |
| **Taudot** universal, pdfLaTeX | 105 / 150 | 138 / 185 | 308 / 475 |
| liveTeX-Rosina, pdfLaTeX | 629 / 657 | 2903 / 2988 | 4722 / 4824 |
| latexmk, pdfLaTeX | 694 / 1004 | 893 / 913 | 1093 / 1230 |
| one stock run, pdfLaTeX | 480 / 522 | 726 / 750 | 847 / 913 |

### Checked against stock (all documents)

| | exact page = stock | whole PDF = stock |
|---|---|---|
| **Taudot**, patched pdfTeX | 180 / 180 | 180 / 180 |
| **Taudot** universal, pdfLaTeX | 120 / 180 (60 differ) | 120 / 180 (60 differ) |
| **Taudot** universal, XeLaTeX | 90 / 90 | 90 / 90 |
| **Taudot** universal, LuaLaTeX | 90 / 90 | 90 / 90 |
| rtex, LuaLaTeX | claimed (display lists) | 90 / 90 |
| liveTeX-Rosina, pdfLaTeX | 179 / 180 (1 differ) | 179 / 180 (1 differ) |
| liveTeX-Rosina, XeLaTeX | 90 / 90 | 90 / 90 |
| liveTeX-Rosina, LuaLaTeX | 90 / 90 | 90 / 90 |
| TeXpresso, XeLaTeX | not checkable | not checkable |
| Typst `watch` (not LaTeX) | not checkable | not checkable |

### First compile and memory

| | 10 pp: first page / settled / peak RSS | 100 pp: first page / settled / peak RSS | 300 pp: first page / settled / peak RSS |
|---|---|---|---|
| **Taudot**, patched pdfTeX | 203 / 228 ms / 129 MB | 201 / 487 ms / 239 MB | 225 / 1168 ms / 501 MB |
| **Taudot** universal, pdfLaTeX | 321 / 321 ms / 174 MB | 568 / 570 ms / 338 MB | 1232 / 1239 ms / 479 MB |
| **Taudot** universal, XeLaTeX | 257 / 257 ms / 333 MB | 430 / 431 ms / 471 MB | 811 / 814 ms / 610 MB |
| **Taudot** universal, LuaLaTeX | 558 / 558 ms / 464 MB | 1605 / 1609 ms / 1118 MB | 4193 / 4204 ms / 2364 MB |
| rtex, LuaLaTeX | 1814 / 1814 ms / 456 MB | 8274 / 8274 ms / 763 MB | 24167 / 24167 ms / 1381 MB |
| liveTeX-Rosina, pdfLaTeX | 1625 / 1625 ms / 137 MB | 2822 / 2822 ms / 202 MB | 6218 / 6218 ms / 300 MB |
| liveTeX-Rosina, XeLaTeX | 2078 / 2078 ms / 444 MB | 3031 / 3031 ms / 479 MB | 5716 / 5716 ms / 497 MB |
| liveTeX-Rosina, LuaLaTeX | 4824 / 4824 ms / 562 MB | 8873 / 8873 ms / 680 MB | 17629 / 17629 ms / 753 MB |
| TeXpresso, XeLaTeX | 436 / 436 ms / 446 MB | 1047 / 1047 ms / 330 MB | 3144 / 3144 ms / 612 MB |
| Typst `watch` (not LaTeX) | 947 / 947 ms / 168 MB | 489 / 489 ms / 1359 MB | 1073 / 1073 ms / 4004 MB |
| latexmk, pdfLaTeX | 412 / 412 ms / 50 MB | 640 / 640 ms / 50 MB | 1206 / 1206 ms / 50 MB |
| latexmk, XeLaTeX | 431 / 431 ms / 185 MB | 734 / 734 ms / 186 MB | 1303 / 1303 ms / 188 MB |
| latexmk, LuaLaTeX | 658 / 658 ms / 152 MB | 1455 / 1455 ms / 170 MB | 3341 / 3341 ms / 188 MB |
<!-- bench:end -->

## Reproduce

See `bench/README.md`.
