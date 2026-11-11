# Live typesetting, side by side

Taudot's live typesetting next to the other live LaTeX systems and stock `latexmk`, on the same documents, with the
same edits, on one Mac. Everything here comes from one command (`bench/README.md`); the raw rows are in
`bench/results/`.

![Edit to exact page, median ms, by document length](bench.svg)

## Verdict

(Rerun 2026-11-09/10 on main 57c3ad7, M4 Pro, 14 cores. Other agents' work kept 3–5 cores busy throughout; each run
is the quietest of up to three, and its figure is in the first-compile table.)

### pdfLaTeX: universal (unpatched pdfTeX under libtau) against the patched engine

From main 7d514c0 (2026-11-10, uspeed's eb93a57: display pages wait for the paragraph pass), the two run
**interleaved** per document (patched, universal, universal, patched), so they shared the same load: 3–4 cores busy
elsewhere, load average 8–19. 6 documents × 2 rounds × 30 keys each; per-run rows in the interleaved table below.

- **Exact on every key.** Universal: finished pages and whole PDFs equal stock pdfLaTeX's for all 360 keys, and all
  336 display pages it sent have stock's content stream byte for byte and draw the same pixels at 288 dpi. Patched:
  360/360.
- **First exact pixels: universal ahead.** A display page comes on 168 of 180 keys per round (all 30 at 100 and 300
  pages, on 1512.03385 and 2103.00020; 24 on synth-10 and 1706.03762), p50 9–34 ms; the patched engine's first exact
  page is 42–75 ms.
- **Paragraph preview: now on par or ahead.** p50 3.3–9.1 ms against 3.8–11.4 ms in the same rounds (the slowdown
  measured on c6881dd is gone). Exact previews on 11–27 of 30 keys against 14–25.
- **Finished page and whole PDF: on par.** Finished page 41–77 ms against 42–75 ms; whole PDF 131–470 ms against
  139–513 ms.
- **First page on open: now on par** (main 9fea6c4, uspeed's 21545b8: libtau reads characters without a lock).
  Six opens per driver and document, interleaved (ABBA), after one untimed open of each rebuilt binary; 1.8–7.5
  cores busy elsewhere. Median first page: universal 221 / 234 / 245 ms at 10 / 100 / 300 pages against patched
  225 / 225 / 231, and 334–370 ms against 359–398 ms on the three papers. Settled: 7 % faster than patched on
  the papers, 2 % faster at 10 pages, 5 % slower at 100 and 300 pages. The first-page table below has every document. Two documents
  were rerun because a burst of other work (10–12 cores) hit both drivers' runs.
- **Memory: less when idle, more while typing** (main 0318961; phys_footprint summed over the driver's processes,
  which counts a page shared copy-on-write with a fork once; two runs per driver in ABBA order, 3.2–5.3 cores busy
  elsewhere; table below). Idle after opening, universal uses 5–15 % less than patched (96 against 110 MB at
  10 pages, 168–426 against 183–440 MB on the papers; on par at 300 pages). While typing it keeps more: +50–135 MB at
  10 pages and on the papers (e.g. 252–263 against 202 MB on 1512.03385), and it stays there when typing stops
  (idle afterwards 185 against 113–133 MB at 10 pages). At 100 pages it is lower (311–354 against 368–529 MB). At
  300 pages the two runs disagree (universal's burst peak 504 and 947 MB, patched's 462 and 660 MB): there, both
  fork up to 99–125 processes. Universal always runs more processes (21–125 against 13–99).

### Burst typing: 8 keys a second (2026-11-10, main fcb58ce)

The same 30 keys typed as a burst, at 8 keys a second, with no waiting for output, so each key lands while the last
one is still being typed (method below). pdfLaTeX patched and universal interleaved (ABBA); universal XeLaTeX and
LuaLaTeX twice each. Load average 10–33, 3.9–6.6 cores busy elsewhere, recorded per run in the burst table.

- **Every output was exact.** 3,008 early, display and tau-pdfmx outputs sent during bursts were each checked
  against latexmk after the number of keys the output contains, and every one matched. All 180 settled PDFs also
  match stock.
- **Almost no keys are skipped.** Neither driver merges a burst into one output. Every key's own state reached an
  exact page, except for one case in universal pdfLaTeX (10 of 60 keys on synth-10, below).
- **Key → first pixels** (preview, display page or page, whichever comes first), p50: patched 3.1–3.5 ms (29.6 and
  41.3 ms on 1706.03762 and 2103.00020, where previews are rare), universal 2.6–10.2 ms. XeLaTeX 2.8–8.9 ms,
  LuaLaTeX 4.0–5.1 ms.
- **Key → exact page**, p50 / p90: universal pdfLaTeX 6.3–28.8 / 15–77 ms (its display page) against patched
  34–61 / 42–88 ms. XeLaTeX 14–28 / 26–54 ms, LuaLaTeX 12–14 / 23–68 ms.
- **One stall in universal pdfLaTeX.** When the edit is on page 1 of synth-10, every key restarts the run from
  page 0 (no snapshot before it). That run needs ~140 ms to ship its first page, longer than the 125 ms between
  keys, so nothing appears (no preview either) until 130–160 ms after the last key: up to 0.8 s for the word's
  first key. Patched shows each of these keys in 61–88 ms.

### All engines

- **Exact page after a key: only Taudot is under 100 ms, on all three engines**, and it barely grows with the
  document: pdfLaTeX 42–75 ms (patched) and 9–34 ms (universal's display page), XeLaTeX 18–35 ms (now a PDF, tau-pdfmx
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
| **memory (phys_footprint)** | `bench/run.py memory`: one session per run (open, 5 s idle, the 30 isolated keys, the same spots again as bursts at 8 keys a second, 5 s idle). Every 200 ms, each process in the driver's tree is sampled with `proc_pid_rusage` (`ri_phys_footprint`, the memory macOS charges it: anonymous and compressed pages it dirtied, so a page shared copy-on-write with a fork counts once), and the sum is kept per phase with the summed RSS and the process count. |

p50 and p90 are over the 30 edits of one document.

**Burst typing** (`bench/run.py burst`). The same spots and keys, but at each spot the six keys go out 125 ms apart
(8 a second), whatever the system is doing; after the last key the harness waits for the compile to settle, rests
300 ms and moves to the next spot. Every output is kept with its `applied` count and timed against each key it
contains: **key → first pixels** is the first preview, display page or page holding the edit; **key → exact page**
is the first display page or page holding the edit. A key is **skipped** when no exact output contains exactly its
state (a later one covers it). Each output is checked against latexmk's after that many keys (references exist
for every key): new pages for early PDFs, the display check for display pages, tau-pdfmx pages as above.

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
Machine: Apple M4 Pro, 24 GB, macOS 26.5; load average during runs 11.6–33.7 (other agents' work shared the machine). Dates: 2026-11-09, 2026-11-10. Cells: **p50 / p90 ms** over the 30 edits. Blank: the system doesn't support that engine.

Versions: latexmk `Latexmk, John Collins, 15 June 2025. Version 4.87`; rosina `liveTeX-Rosina dff263fc21`; rtex `rtex 0.0.7 fcff7a5c7f`; stock-run `TeX Live 2026 static engines`; taudot-pdftex `pdftex-live 7d514c03af`; taudot-universal `tau-live 7d514c03af`; taudot-universal `tau-live ad58f81329`; texpresso `texpresso e8df770907 via txp-headless ad58f81329`; typst `typst 0.15.1 (9dfd3a08)`.

### pdfLaTeX, patched and universal interleaved

Per document: patched, universal, universal, patched (ABBA), back to back; one row per run of 30 keys. The tables below pool both rounds (60 keys per document for these two).

| document | run | cores busy elsewhere (load) | preview p50 (exact) | display page p50 (sent, = stock) | finished page p50 | whole PDF p50 | first page on open |
|---|---|---|---|---|---|---|---|
| 10 pp | patched 1 | 3.38 (7.9) | 4.3 (23) | – | 47.0 | 60.9 | 246 |
| 10 pp | universal 1 | 2.98 (9.1) | 4.0 (20) | 9.3 (24, 24) | 41.0 | 57.8 | 978 |
| 10 pp | universal 2 | 3.02 (8.9) | 3.9 (21) | 11.5 (24, 24) | 43.7 | 62.5 | 294 |
| 10 pp | patched 2 | 3.33 (10.1) | 4.6 (25) | – | 45.9 | 63.0 | 232 |
| 100 pp | patched 1 | 4.13 (12.3) | 8.1 (24) | – | 48.0 | 206 | 238 |
| 100 pp | universal 1 | 3.74 (14.2) | 4.4 (20) | 14.0 (30, 30) | 43.0 | 174 | 305 |
| 100 pp | universal 2 | 4.39 (14.9) | 3.3 (21) | 12.0 (30, 30) | 41.8 | 176 | 311 |
| 100 pp | patched 2 | 3.99 (15.1) | 5.8 (24) | – | 42.3 | 192 | 239 |
| 300 pp | patched 1 | 4.21 (17.0) | 11.4 (24) | – | 46.1 | 513 | 227 |
| 300 pp | universal 1 | 3.63 (19.2) | 5.3 (26) | 11.4 (30, 30) | 46.0 | 470 | 333 |
| 300 pp | universal 2 | 3.64 (17.5) | 5.4 (27) | 11.8 (30, 30) | 40.6 | 458 | 380 |
| 300 pp | patched 2 | 3.84 (15.3) | 8.9 (24) | – | 45.5 | 497 | 230 |
| 1512.03385 | patched 1 | 3.62 (16.6) | 11.2 (23) | – | 51.5 | 139 | 372 |
| 1512.03385 | universal 1 | 3.75 (16.7) | 8.3 (20) | 23.2 (30, 30) | 47.8 | 138 | 396 |
| 1512.03385 | universal 2 | 3.78 (17.2) | 4.3 (20) | 16.3 (30, 30) | 46.9 | 131 | 413 |
| 1512.03385 | patched 2 | 3.79 (18.6) | 6.0 (23) | – | 49.9 | 141 | 339 |
| 1706.03762 | patched 1 | 3.39 (19.0) | 7.5 (15) | – | 74.6 | 150 | 353 |
| 1706.03762 | universal 1 | 3.48 (18.1) | 7.1 (17) | 33.7 (24, 24) | 76.7 | 151 | 440 |
| 1706.03762 | universal 2 | 3.31 (17.1) | 4.4 (17) | 31.6 (24, 24) | 73.5 | 147 | 481 |
| 1706.03762 | patched 2 | 3.09 (16.5) | 3.8 (15) | – | 71.0 | 149 | 351 |
| 2103.00020 | patched 1 | 3.78 (16.9) | 7.7 (14) | – | 63.1 | 417 | 371 |
| 2103.00020 | universal 1 | 3.98 (16.8) | 7.6 (12) | 24.5 (30, 30) | 61.6 | 420 | 431 |
| 2103.00020 | universal 2 | 3.90 (16.6) | 9.1 (11) | 27.5 (30, 30) | 69.3 | 428 | 481 |
| 2103.00020 | patched 2 | 4.14 (16.7) | 6.8 (14) | – | 58.4 | 442 | 412 |

### Memory, pdfLaTeX (phys_footprint)

One session per run: open, 5 s idle, the 30 isolated keys, the same spots again as bursts at 8 keys a second, 5 s idle. phys_footprint (`proc_pid_rusage`) summed over the driver's process tree, MB: mean over the idle phases, peak over the typing ones. Two runs per driver in ABBA order; each cell their range (one figure when within 10 MB).

| document | driver | cores busy elsewhere | idle | isolated keys | bursts | idle after | summed RSS, peak | processes, most |
|---|---|---|---|---|---|---|---|---|
| 10 pp | patched | 3.20, 3.69 | 110 | 113 | 120–146 | 113–133 | 118–149 | 13 |
| 10 pp | universal | 3.61, 3.98 | 96 | 193 | 185 | 185 | 149–189 | 21 |
| 100 pp | patched | 4.30, 5.30 | 230 | 439–529 | 368–424 | 262–312 | 371–520 | 77 |
| 100 pp | universal | 4.26, 4.61 | 202 | 312–354 | 311–330 | 307–320 | 275–278 | 45 |
| 300 pp | patched | 4.73, 5.27 | 427–491 | 505–701 | 462–660 | 446–611 | 491–610 | 99 |
| 300 pp | universal | 4.77, 4.79 | 481–491 | 607–663 | 504–947 | 470–686 | 661–1022 | 125 |
| 1512.03385 | patched | 4.06, 4.36 | 183–193 | 202 | 197 | 187 | 209–222 | 16 |
| 1512.03385 | universal | 4.41, 4.48 | 168 | 252–263 | 258–269 | 257 | 227–250 | 28 |
| 1706.03762 | patched | 3.43, 3.46 | 207–223 | 225 | 219 | 216 | 232–240 | 17 |
| 1706.03762 | universal | 3.72, 4.12 | 184 | 329–358 | 328–344 | 307–322 | 302–358 | 36 |
| 2103.00020 | patched | 4.49, 4.61 | 440 | 472–527 | 454–507 | 454 | 481–517 | 45 |
| 2103.00020 | universal | 4.95, 5.19 | 414–426 | 564–622 | 564–600 | 547 | 536–550 | 57 |

### First page on open, pdfLaTeX

Six opens per driver and document in three ABBA blocks, after one untimed open of each rebuilt binary. Median [min–max] ms; open → first PDF, and open → settled.

| document | cores busy elsewhere (load) | first page on open: patched | universal | settled: patched | universal |
|---|---|---|---|---|---|
| 10 pp | 1.8–2.9 (9–9) | 225 [219–244] | 221 [213–229] | 258 [251–276] | 253 [245–277] |
| 100 pp | 3.0–6.2 (8–9) | 225 [220–252] | 234 [211–244] | 555 [542–620] | 585 [541–613] |
| 300 pp | 3.0–6.6 (9–10) | 231 [223–239] | 245 [216–265] | 1225 [1179–1271] | 1281 [1212–1309] |
| 1512.03385 | 2.3–5.2 (9–9) | 359 [337–401] | 334 [311–360] | 514 [486–569] | 479 [451–511] |
| 1706.03762 | 3.4–7.5 (11–11) | 387 [360–410] | 352 [325–390] | 844 [798–867] | 782 [747–1051] |
| 2103.00020 | 3.8–6.5 (10–11) | 398 [393–416] | 370 [359–384] | 1146 [1106–1186] | 1068 [1022–1087] |

### Burst typing (8 keys a second)

Each spot's word typed at 8 keys a second without waiting, then the compile settles and the next spot follows; two runs per row (pdfLaTeX: ABBA, as above), 60 keys. Times from each key to the first output that contains it. Outputs = stock: every early, display and tau-pdfmx page sent, checked against latexmk after as many keys as the output contains.

| document | system | cores busy elsewhere (load), per run | key → first pixels p50 / p90 | key → exact page p50 / p90 | keys never shown exact (preview) | outputs = stock | settled PDFs = stock |
|---|---|---|---|---|---|---|---|
| 10 pp | patched | 6.39 (10.3), 4.11 (12.5) | 3.3 / 34.9 | 35.9 / 68.0 | 0/60 (10) | 209/209 | 10/10 |
| 10 pp | universal | 3.90 (12.8), 3.88 (12.3) | 2.8 / 410 | 6.3 / 410 | 10/60 (19) | 144/144 | 10/10 |
| 100 pp | patched | 4.37 (13.4), 5.30 (15.7) | 3.2 / 35.5 | 34.2 / 41.8 | 0/60 (10) | 208/208 | 10/10 |
| 100 pp | universal | 4.94 (15.6), 5.10 (15.5) | 2.9 / 22.8 | 6.9 / 22.8 | 0/60 (20) | 165/165 | 10/10 |
| 300 pp | patched | 6.09 (16.3), 4.97 (17.0) | 3.5 / 40.0 | 41.4 / 52.0 | 0/60 (10) | 205/205 | 10/10 |
| 300 pp | universal | 4.78 (16.7), 4.63 (16.3) | 2.6 / 15.2 | 6.4 / 15.2 | 0/60 (8) | 155/155 | 10/10 |
| 1512.03385 | patched | 4.86 (16.8), 4.95 (19.1) | 3.1 / 39.0 | 37.1 / 50.2 | 0/60 (10) | 166/166 | 10/10 |
| 1512.03385 | universal | 5.18 (17.1), 4.66 (18.2) | 3.2 / 18.3 | 10.5 / 20.0 | 0/60 (17) | 153/153 | 10/10 |
| 1706.03762 | patched | 5.01 (19.6), 4.86 (18.9) | 29.6 / 73.4 | 60.6 / 87.9 | 0/60 (30) | 165/165 | 10/10 |
| 1706.03762 | universal | 4.58 (19.3), 4.82 (19.0) | 6.8 / 77.1 | 28.8 / 77.1 | 0/60 (26) | 155/155 | 10/10 |
| 2103.00020 | patched | 4.69 (27.0), 5.96 (27.7) | 41.3 / 65.1 | 52.7 / 65.6 | 0/60 (30) | 194/194 | 10/10 |
| 2103.00020 | universal | 5.24 (33.2), 5.65 (28.9) | 10.2 / 22.1 | 17.2 / 25.7 | 0/60 (37) | 186/186 | 10/10 |
| 10 pp | universal XeLaTeX | 4.94 (26.6), 5.03 (25.8) | 2.8 / 22.6 | 14.0 / 26.1 | 0/60 (20) | 120/120 | 10/10 |
| 100 pp | universal XeLaTeX | 5.02 (23.9), 5.59 (22.4) | 4.7 / 30.9 | 19.5 / 33.7 | 0/60 (20) | 111/111 | 10/10 |
| 300 pp | universal XeLaTeX | 4.64 (21.2), 4.63 (19.0) | 8.9 / 53.8 | 28.3 / 53.8 | 0/60 (29) | 121/121 | 10/10 |
| 10 pp | universal LuaLaTeX | 4.04 (17.1), 4.34 (16.0) | 4.0 / 67.5 | 11.7 / 67.5 | 0/60 (18) | 158/158 | 10/10 |
| 100 pp | universal LuaLaTeX | 5.13 (15.2), 6.03 (17.1) | 5.1 / 20.9 | 12.3 / 23.0 | 0/60 (16) | 167/167 | 10/10 |
| 300 pp | universal LuaLaTeX | 6.57 (17.9), 5.41 (16.3) | 4.8 / 33.4 | 14.3 / 42.1 | 0/60 (8) | 226/226 | 10/10 |

### Edit → paragraph preview

|  | 10 pp | 100 pp | 300 pp |
|---|---|---|---|
| **Taudot**, patched pdfTeX | 4.5 / 12.8<br><sub>48 exact, 0 prov. of 60</sub><br><sub>own p50 4.4</sub> | 6.2 / 14.7<br><sub>48 exact, 0 prov. of 60</sub><br><sub>own p50 6.1</sub> | 9.8 / 19.7<br><sub>48 exact, 0 prov. of 60</sub><br><sub>own p50 9.7</sub> |
| **Taudot** universal, pdfLaTeX | 3.9 / 9.8<br><sub>41 exact, 0 prov. of 60</sub><br><sub>own p50 3.4</sub> | 4.4 / 11.4<br><sub>41 exact, 0 prov. of 60</sub><br><sub>own p50 3.9</sub> | 5.3 / 12.9<br><sub>53 exact, 0 prov. of 60</sub><br><sub>own p50 4.7</sub> |
| **Taudot** universal, XeLaTeX | 3.9 / 10.9<br><sub>20 exact, 0 prov. of 30</sub><br><sub>own p50 3.6</sub> | 5.5 / 14.6<br><sub>19 exact, 0 prov. of 30</sub><br><sub>own p50 5.0</sub> | 10.4 / 17.3<br><sub>14 exact, 0 prov. of 30</sub><br><sub>own p50 10.0</sub> |
| **Taudot** universal, LuaLaTeX | 3.7 / 4.6<br><sub>20 exact, 0 prov. of 30</sub><br><sub>own p50 3.5</sub> | 4.2 / 5.3<br><sub>19 exact, 0 prov. of 30</sub><br><sub>own p50 3.9</sub> | 11.9 / 19.6<br><sub>26 exact, 0 prov. of 30</sub><br><sub>own p50 10.9</sub> |
| rtex, LuaLaTeX | 10.4 / 15.1<br><sub>30 exact, 0 prov. of 30</sub><br><sub>own p50 1.6</sub> | 15.5 / 29.5<br><sub>30 exact, 0 prov. of 30</sub><br><sub>own p50 2.3</sub> | 19.3 / 34.5<br><sub>30 exact, 0 prov. of 30</sub><br><sub>own p50 4.5</sub> |
| liveTeX-Rosina, pdfLaTeX | 137 / 147<br><sub>30 prov. of 30</sub><br><sub>own p50 24.0</sub> | 497 / 512<br><sub>30 prov. of 30</sub><br><sub>own p50 36.0</sub> | 1498 / 1515<br><sub>30 prov. of 30</sub><br><sub>own p50 49.0</sub> |
| liveTeX-Rosina, XeLaTeX | 120 / 134<br><sub>24 prov. of 30</sub><br><sub>own p50 66.0</sub> | 469 / 483<br><sub>24 prov. of 30</sub><br><sub>own p50 67.5</sub> | 1436 / 1488<br><sub>24 prov. of 30</sub><br><sub>own p50 79.5</sub> |
| liveTeX-Rosina, LuaLaTeX | – | – | – |

### Edit → exact page

|  | 10 pp | 100 pp | 300 pp |
|---|---|---|---|
| **Taudot**, patched pdfTeX | 46.6 / 84.7 | 43.5 / 58.8 | 45.6 / 60.6 |
| **Taudot** universal, pdfLaTeX | 41.5 / 147 | 42.0 / 61.5 | 43.7 / 58.6 |
| ↳ its display page | 10.4 / 27.5<br><sub>48 of 60, 48 the edited page</sub> | 13.2 / 30.7<br><sub>60 of 60, 60 the edited page</sub> | 11.6 / 26.8<br><sub>60 of 60, 60 the edited page</sub> |
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
| **Taudot**, patched pdfTeX | 61.1 / 115 | 197 / 327 | 508 / 879 |
| **Taudot** universal, pdfLaTeX | 60.5 / 175 | 175 / 302 | 460 / 779 |
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
| **Taudot**, patched pdfTeX | 7.1 / 15.8<br><sub>46 exact, 0 prov. of 60</sub><br><sub>own p50 7.0</sub> | 4.2 / 12.4<br><sub>30 exact, 0 prov. of 60</sub><br><sub>own p50 4.2</sub> | 7.1 / 24.5<br><sub>28 exact, 0 prov. of 60</sub><br><sub>own p50 7.0</sub> |
| **Taudot** universal, pdfLaTeX | 5.9 / 12.5<br><sub>40 exact, 0 prov. of 60</sub><br><sub>own p50 5.2</sub> | 5.9 / 14.7<br><sub>34 exact, 0 prov. of 60</sub><br><sub>own p50 5.4</sub> | 8.1 / 15.0<br><sub>23 exact, 0 prov. of 60</sub><br><sub>own p50 6.8</sub> |
| liveTeX-Rosina, pdfLaTeX | – | – | – |

| exact page | 1512.03385 | 1706.03762 | 2103.00020 |
|---|---|---|---|
| **Taudot**, patched pdfTeX | 50.5 / 64.0 | 73.6 / 94.2 | 61.5 / 76.4 |
| **Taudot** universal, pdfLaTeX | 47.3 / 69.4 | 74.3 / 97.2 | 64.2 / 78.3 |
| ↳ its display page | 16.5 / 32.4<br><sub>60 of 60, 60 the edited page</sub> | 31.7 / 49.9<br><sub>48 of 60, 48 the edited page</sub> | 25.7 / 40.7<br><sub>60 of 60, 36 the edited page</sub> |
| liveTeX-Rosina, pdfLaTeX | 632 / 650 | 2999 / 3175 | 4736 / 4845 |
| latexmk, pdfLaTeX | 645 / 687 | 916 / 936 | 1087 / 1138 |
| one stock run, pdfLaTeX | 481 / 510 | 748 / 774 | 902 / 933 |

| whole PDF | 1512.03385 | 1706.03762 | 2103.00020 |
|---|---|---|---|
| **Taudot**, patched pdfTeX | 139 / 179 | 149 / 208 | 431 / 631 |
| **Taudot** universal, pdfLaTeX | 136 / 165 | 148 / 205 | 423 / 646 |
| liveTeX-Rosina, pdfLaTeX | 632 / 650 | 2999 / 3175 | 4736 / 4845 |
| latexmk, pdfLaTeX | 645 / 687 | 916 / 936 | 1087 / 1138 |
| one stock run, pdfLaTeX | 481 / 510 | 748 / 774 | 902 / 933 |

### Checked against stock (all documents)

| | display page = stock | exact page = stock | whole PDF = stock |
|---|---|---|---|
| **Taudot**, patched pdfTeX |  | 360 / 360 | 360 / 360 |
| **Taudot** universal, pdfLaTeX | 336 / 336 | 360 / 360 | 360 / 360 |
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
| **Taudot**, patched pdfTeX | 239 / 267 ms / 120 MB<br><sub> cores busy elsewhere</sub> | 239 / 539 ms / 249 MB<br><sub> cores busy elsewhere</sub> | 229 / 1166 ms / 461 MB<br><sub> cores busy elsewhere</sub> |
| **Taudot** universal, pdfLaTeX | 636 / 668 ms / 190 MB<br><sub> cores busy elsewhere</sub> | 308 / 606 ms / 305 MB<br><sub> cores busy elsewhere</sub> | 357 / 1252 ms / 486 MB<br><sub> cores busy elsewhere</sub> |
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
