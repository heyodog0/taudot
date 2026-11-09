# Live typesetting, side by side

Taudot's live typesetting next to the other live LaTeX systems and stock `latexmk`, on the same documents, with the
same edits, on one Mac. Everything here comes from one command (`bench/README.md`); the raw rows are in
`bench/results/`.

![Edit to exact page, median ms, by document length](bench.svg)

## Verdict

VERDICT

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
<!-- bench:end -->

## Reproduce

See `bench/README.md`.
