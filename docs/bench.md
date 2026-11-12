# Live typesetting, side by side

Taudot's live typesetting next to the other live LaTeX systems and stock `latexmk`: same documents, same edits, one
Mac (M4 Pro, 14 cores, 24 GB, macOS 26.5, TeX Live 2026). To rerun: `bench/README.md`; raw rows: `bench/results/`.

![Edit to exact page, median ms, by document length](bench.svg)

In short: only Taudot shows the exact edited page in under 100 ms on all three engines, and that time barely grows
with the document. Every page and PDF it sent matched stock. Universal (unpatched engines under libtau) is on par
with the patched pdfTeX on speed, shows its first exact pixels sooner, and uses 30–63 % less memory.

Cells are **p50 / p90 ms** over a document's 30 edits (Taudot pdfLaTeX: two rounds, 60). Universal is `tau-live`,
patched is `pdftex-live`.

<!-- bench:begin -->
## Edit → exact page

The page holding the edit, as stock sets it. Display page: universal's copy of it sent before the run finishes (in
brackets, keys that got one).

| system | 10 pp | 100 pp | 300 pp |
|---|---|---|---|
| **Taudot** patched, pdfLaTeX | 46.6 / 84.7 | 43.5 / 58.8 | 45.6 / 60.6 |
| **Taudot** universal, pdfLaTeX | 41.5 / 147 | 42.0 / 61.5 | 43.7 / 58.6 |
| ↳ display page | 10.4 / 27.5 (48) | 13.2 / 30.7 (60) | 11.6 / 26.8 (60) |
| **Taudot** universal, XeLaTeX | 18.5 / 33.1 | 23.3 / 45.4 | 34.7 / 53.4 |
| **Taudot** universal, LuaLaTeX | 39.1 / 65.4 | 42.6 / 59.0 | 68.5 / 78.4 |
| ↳ display page | 12.6 / 15.0 (24) | 27.1 / 31.1 (30) | 75.0 (1) |
| TeXpresso, XeLaTeX (XDV page) | 16.8 / 34.6 | 34.6 / 152 | 64.5 / 2460 |
| Typst `watch` (not LaTeX) | 120 / 123 | 166 / 171 | 296 / 315 |
| Rosina quick mode, pdfLaTeX (whole PDF) | 239 / 259 | 1276 / 1306 | 3957 / 4032 |
| rtex, LuaLaTeX (background layout) | 1254 / 1278 | 3618 / 3665 | 8871 / 9023 |
| latexmk, pdfLaTeX | 413 / 425 | 661 / 674 | 1174 / 1225 |
| latexmk, XeLaTeX | 426 / 430 | 683 / 696 | 1266 / 1336 |
| latexmk, LuaLaTeX | 678 / 696 | 1515 / 1541 | 3305 / 3329 |
| one stock run, pdfLaTeX | 286 / 298 | 543 / 571 | 987 / 1002 |
| one stock run, XeLaTeX | 255 / 260 | 400 / 465 | 707 / 728 |
| one stock run, LuaLaTeX | 558 / 564 | 1357 / 1371 | 3068 / 3086 |

Typst's own compile is 6.2 / 49.7 / 176 ms; the rest of its wall time is the file watcher.

## Edit → whole exact PDF

| system | 10 pp | 100 pp | 300 pp |
|---|---|---|---|
| **Taudot** patched, pdfLaTeX | 61.1 / 115 | 197 / 327 | 508 / 879 |
| **Taudot** universal, pdfLaTeX | 60.5 / 175 | 175 / 302 | 460 / 779 |
| **Taudot** universal, XeLaTeX | 27.9 / 44.7 | 134 / 195 | 322 / 556 |
| **Taudot** universal, LuaLaTeX | 89.5 / 145 | 488 / 817 | 1320 / 2316 |
| TeXpresso, XeLaTeX (its `done`, no file) | 69.8 / 95.6 | 584 / 739 | 1310 / 2475 |
| Rosina, pdfLaTeX, quick / PDF mode (p50) | 239 / 302 | 1276 / 1414 | 3957 / 4188 |
| rtex, LuaLaTeX (`export_pdf`) | 580 / 600 | 1372 / 1396 | 3124 / 3147 |

latexmk and one stock run: as in the table above (they write nothing before the whole PDF).

## Edit → paragraph preview

The edited paragraph alone, set by the real engine on the old page; in brackets, keys that got one and [the system's own
figure]. Taudot's previews are exact (same lines and heights) except the few marked prov.; Rosina's are provisional by
design.

| system | 10 pp | 100 pp | 300 pp |
|---|---|---|---|
| **Taudot** patched, pdfLaTeX | 4.5 / 12.8 (48 of 60) | 6.2 / 14.7 (48, +2 prov.) | 9.8 / 19.7 (48, +2 prov.) |
| **Taudot** universal, pdfLaTeX | 3.9 / 9.8 (41 of 60) | 4.4 / 11.4 (41) | 5.3 / 12.9 (53, +2 prov.) |
| **Taudot** universal, XeLaTeX | 3.9 / 10.9 (20 of 30) | 5.5 / 14.6 (19, +1 prov.) | 10.4 / 17.3 (14, +1 prov.) |
| **Taudot** universal, LuaLaTeX | 3.7 / 4.6 (20 of 30) | 4.2 / 5.3 (19, +1 prov.) | 11.9 / 19.6 (26, +1 prov.) |
| rtex, LuaLaTeX | 10.4 / 15.1 [1.6] (30 of 30) | 15.5 / 29.5 [2.3] (30) | 19.3 / 34.5 [4.5] (30) |
| Rosina quick, pdfLaTeX | 71.3 / 86.6 [31.0] (60 of 60) | 252 / 264 [27.0] (60) | 760 / 784 [37.0] (60) |
| Rosina quick, XeLaTeX | 83.0 / 101 [65.5] (24 of 30) | 260 / 279 [72.0] (24) | 729 / 756 [82.0] (24) |
| Rosina PDF mode, pdfLaTeX | 143 / 159 [34.5] (30 of 30) | 473 / 490 [41.5] (30) | 1267 / 1285 [52.0] (30) |

Taudot has none for the first key at a new spot, or a paragraph across a page or column or in a box.

## Real papers (pdfLaTeX)

1512.03385 (12 pp., one column), 1706.03762 (15 pp., `\input` sections), 2103.00020 (48 pp., two columns, many figures).

| measure, system | 1512.03385 | 1706.03762 | 2103.00020 |
|---|---|---|---|
| preview, patched | 7.1 / 15.8 (46 of 60, +4 prov.) | 4.2 / 12.4 (30) | 7.1 / 24.5 (28) |
| preview, universal | 5.9 / 12.5 (40 of 60, +2 prov.) | 5.9 / 14.7 (34) | 8.1 / 15.0 (23) |
| display page, universal | 16.5 / 32.4 (60) | 31.7 / 49.9 (48) | 25.7 / 40.7 (60) |
| exact page, patched | 50.5 / 64.0 | 73.6 / 94.2 | 61.5 / 76.4 |
| exact page, universal | 47.3 / 69.4 | 74.3 / 97.2 | 64.2 / 78.3 |
| whole PDF, patched | 139 / 179 | 149 / 208 | 431 / 631 |
| whole PDF, universal | 136 / 165 | 148 / 205 | 423 / 646 |
| whole PDF, Rosina quick (no previews) | 645 / 664 | 2846 / 2901 | 4804 / 4955 |
| latexmk | 645 / 687 | 916 / 936 | 1087 / 1138 |
| one stock run | 481 / 510 | 748 / 774 | 902 / 933 |

Rosina previews none of the keys on the papers: each falls back to a whole build.

## Burst typing, 8 keys a second

Each spot's six keys sent 125 ms apart without waiting, two runs per row (60 keys); times from each key to the first
output containing it (first pixels: preview, display page or page). Skipped: keys whose own state never reached an exact
page.

| document | first pixels: patched | universal | exact page: patched | universal | skipped (universal) |
|---|---|---|---|---|---|
| 10 pp | 3.3 / 34.9 | 2.8 / 410 | 35.9 / 68.0 | 6.3 / 410 | 10 |
| 100 pp | 3.2 / 35.5 | 2.9 / 22.8 | 34.2 / 41.8 | 6.9 / 22.8 | 0 |
| 300 pp | 3.5 / 40.0 | 2.6 / 15.2 | 41.4 / 52.0 | 6.4 / 15.2 | 0 |
| 1512.03385 | 3.1 / 39.0 | 3.2 / 18.3 | 37.1 / 50.2 | 10.5 / 20.0 | 0 |
| 1706.03762 | 29.6 / 73.4 | 6.8 / 77.1 | 60.6 / 87.9 | 28.8 / 77.1 | 0 |
| 2103.00020 | 41.3 / 65.1 | 10.2 / 22.1 | 52.7 / 65.6 | 17.2 / 25.7 | 0 |

Universal XeLaTeX, p50 at 10 / 100 / 300 pp: first pixels 2.8 / 4.7 / 8.9, exact page 14.0 / 19.5 / 28.3; LuaLaTeX 4.0 /
5.1 / 4.8 and 11.7 / 12.3 / 14.3; none skipped. All 3,008 outputs sent during bursts matched latexmk after the same
keys, as did all 180 settled PDFs.
Universal's one stall: an edit on page 1 of the 10-page document has no snapshot before it, so each key restarts a run
that needs ~140 ms to ship a page, longer than the gap between keys; nothing shows until 130–160 ms after the last key
(patched: 61–88 ms per key).

## First output on open

A reopened project (`.aux` settled). ms, first page / settled; Taudot pdfLaTeX: median of six opens.

| system | 10 pp | 100 pp | 300 pp | papers (first page) |
|---|---|---|---|---|
| **Taudot** patched, pdfLaTeX | 225 / 258 | 225 / 555 | 231 / 1225 | 359 / 387 / 398 |
| **Taudot** universal, pdfLaTeX | 221 / 253 | 234 / 585 | 245 / 1281 | 334 / 352 / 370 |
| **Taudot** universal, XeLaTeX | 260 / 281 | 254 / 466 | 269 / 885 | |
| **Taudot** universal, LuaLaTeX | 617 / 618 | 1764 / 1768 | 3343 / 3353 | |
| TeXpresso, XeLaTeX | 401 | 1122 | 3029 | |
| Typst `watch` | 111 | 377 | 1087 | |
| Rosina quick, pdfLaTeX | 1643 | 2816 | 5597 | 2715 / 3788 / 6558 |
| Rosina quick, XeLaTeX | 2494 | 2802 | 5080 | |
| rtex, LuaLaTeX | 1705 | 8386 | 24643 | |
| latexmk, pdfLaTeX / XeLaTeX / LuaLaTeX | 407 / 507 / 664 | 704 / 686 / 1534 | 1207 / 1271 / 3294 | |

Settled on the papers: patched 514 / 844 / 1146, universal 479 / 782 / 1068.

## Memory, pdfLaTeX

phys_footprint, MB: idle after open, peak while typing, 10–15 s after the last key. Two runs each (range when they
differ by over 10 MB); Rosina in quick mode.

| document | system | idle | typing peak | after |
|---|---|---|---|---|
| 10 pp | patched / universal / Rosina | 111 / 73 / 103 | 365 / 143 / 123 | 344 / 84 / 104 |
| 100 pp | patched / universal / Rosina | 211 / 147 / 137 | 471–485 / 247–279 / 182 | 448–471 / 125 / 133 |
| 300 pp | patched / universal / Rosina | 395 / 244 / 160 | 708–722 / 451 / 238 | 682–694 / 229 / 176 |
| 1512.03385 | patched / universal / Rosina | 176 / 119 / 112 | 434–602 / 222 / 143 | 419 / 120 / 107 |
| 1706.03762 | patched / universal / Rosina | 216 / 147 / 121 | 476–496 / 239–258 / 125 | 465 / 142 / 118 |
| 2103.00020 | patched / universal / Rosina | 422–472 / 262 / 131 | 706–780 / 486–497 / 190 | 679–691 / 215 / 116–135 |

Universal reaps kept processes after 2.5 s idle and falls back to its idle level or below; patched holds its typing
level until it exits. Processes: patched 13–56, universal 16–53, Rosina 4–6. Summed RSS gives the same order: universal
156–542 MB, patched 752–1211 MB.

## Checked against stock

| system | display page = stock | exact page = stock | whole PDF = stock |
|---|---|---|---|
| **Taudot** patched, pdfLaTeX | | 360 / 360 | 360 / 360 |
| **Taudot** universal, pdfLaTeX | 336 / 336 | 360 / 360 | 360 / 360 |
| **Taudot** universal, XeLaTeX | | 90 / 90 | 90 / 90 |
| **Taudot** universal, LuaLaTeX | 55 / 55 | 90 / 90 | 90 / 90 |
| rtex, LuaLaTeX | | claimed (display lists) | 90 / 90 |
| Rosina quick / PDF mode | | | 448 / 450, 179 / 180 |
| TeXpresso, Typst | | not checkable | not checkable |

Rosina's misses are one edit (2103.00020, edit 25): a page stays as before the key; stock's changes.
<!-- bench:end -->

## Method

Each system gets the same script: at five spots (prose paragraphs 50, 10, 90, 30 and 70 % through) the keys
`quick ` go in one at a time, 30 one-byte inserts, each sent once the last has settled plus 300 ms, so every number
is one isolated key (`run.py burst` sends them 125 ms apart instead). Times are wall clock from the edit leaving the
harness to reading back the line that announces the result, drawing excluded. Outputs are checked against latexmk's
after the same keys: pages by content stream and fonts, whole PDFs byte for byte (`/ID` masked), display pages also
pixel for pixel at 288 dpi, XeLaTeX pages against stock `xdvipdfmx` of latexmk's XDV. Memory samples
phys_footprint every 200 ms over the driver's tree and every process group it has had, since both drivers leave
processes outside the tree. Documents: synthetic A4 articles from `bench/gen.py` sized to 10, 100 and 300 pdfLaTeX
pages (plus a Typst twin), and three arXiv papers (pdfLaTeX, not redistributed). Other work shared the machine: a
run with over 3 cores busy elsewhere is repeated up to three times and the quietest kept, and pairs (patched and
universal, Rosina and universal) ran interleaved ABBA. Runs: 2026-11-09 to 11, Taudot at 7d514c0 (memory d27b64d,
Rosina pair e390e34).

| system | what runs | driven as |
|---|---|---|
| **Taudot** patched | `pdftex-live --serve`, pdfTeX with `clients/pdftex/patches/2026` | the app's protocol, `goal` = the edited page |
| **Taudot** universal | `tau-live --serve`: libtau under unmodified pdfTeX, XeTeX, LuaTeX | same |
| [rtex](https://github.com/HenryXiaoYang/realtime-tex) 0.0.7 | `rtex serve`, LuaLaTeX only | `request_layout` (skips its debounce), `export_pdf` |
| [liveTeX-Rosina](https://github.com/PetalAdrift/liveTeX-Rosina) | `livetex-rosina --editor --debounce-ms 0 --quick-viewer --source-buffer`; PDF mode without `--quick-viewer` | keys written atomically to its buffer file |
| [TeXpresso](https://github.com/let-def/texpresso) | its XeTeX and frontend, unmodified, headless (`clients/preview/texpresso/txp-headless.c`) | `open`, `change`, `goal` |
| [Typst](https://github.com/typst/typst) 0.15.1 | `typst watch` | the file saved |
| latexmk 4.87 | stock engines | one run per saved edit |

## Fairness

Every system is built from source on the same Mac and the same TeX Live 2026 tree, at its fastest documented
settings. Rosina runs unmodified (its licence allows building and running it for one's own work and is silent on
publishing measurements), driven as its VS Code extension drives it: a buffer file it polls every 1 ms is its only
editor channel, `--debounce-ms 0` is its minimum, it has no worker or snapshot options, and full correction stays
on. Our wall time includes noticing and reading its region file (40 ms over its own figure at 10 pages, more on
longer documents), so both are given. Against universal it previews every synthetic pdfLaTeX key but none on the
papers, takes 0.24–4.8 s to a whole PDF (universal 58–461 ms) and 1.6–6.6 s to its first output (universal
203–357 ms), and uses less memory while typing; 627 of its 630 whole PDFs match stock. Its LuaLaTeX mode was not
rerun (an earlier run had no previews there). rtex's own preview figure (1.6–4.5 ms) beats Taudot's and it previews
every key; our wall time adds its JSON display lists. TeXpresso's XeTeX predates TeX Live 2025, so its display
equations error under LaTeX 2026 and its pages differ from stock. texlode (closed, browser-only) is not run; its
published LuaLaTeX figures (i7 laptop) are 0.17–1.99 ms line breaking, 0.79–6.11 ms round trip.
