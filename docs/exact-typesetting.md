# Exact typesetting: the live PDF identical to Overleaf's

Status: planned (2026-11-04). Not started.

## The problem

Overleaf compiles most papers with pdfLaTeX. Our live PDF comes from TeXpresso, which only runs XeTeX. The two
engines typeset the same source differently:

- **Fonts.** pdfLaTeX documents ask for Times, Helvetica, Palatino and the like through font families XeTeX doesn't
  have, so XeTeX fell back to Latin Modern. Fixed for the common families on 2026-11-04 (`28fca91`): the typesetter
  maps them to TeX Gyre, which has the same widths. Still open: CM Bright, Concrete, URW Garamond, and rare
  kerning differences between TeX Gyre and the originals.
- **microtype.** pdfTeX stretches and shrinks letters slightly (font expansion) to make better line breaks. XeTeX
  can't. Most conference templates load microtype (PaperA's does), so some lines break differently. That can move a
  figure or change the page count, which matters under a page limit.
- **Errors and warnings.** They differ wherever the typesetting differs (box warnings, font warnings). The issues
  list now hides box warnings for this reason (`2ab8f3b`).

The fonts fix narrows the gap. Only running pdfTeX itself closes it.

## The goal

For a pdfLaTeX project, the live PDF is the PDF Overleaf would produce: same line breaks, same page breaks, same
errors and warnings. Not "close": identical, checked by a test.

## Why identical is achievable

TeX is deterministic. Its output depends only on:

1. the engine and its version: pdfTeX from the project's TeX Live year;
2. the input files: the project, plus every package, class and font file the run reads from that TeX Live year;
3. how it is run: Overleaf runs latexmk (which repeats LaTeX and BibTeX until references settle) with its own flags;
4. the date and time (`\today`, PDF timestamps).

The engine can read 1 from the project (compiler and TeX Live image are project settings). We control 2, 3 and 4.
Match all four and the output matches byte for byte, except timestamps we pin.

## The design

### 1. A live pdfTeX: TeXpresso's method on pdfTeX

TeXpresso is a technique more than an engine. It needs three hooks inside a TeX engine:

- **file reads**: record which bytes of which file the run has read, so an edit can be located in the run;
- **snapshots**: `fork()` at intervals while typesetting; on an edit, go back to the last snapshot taken before the
  first changed byte was read, and continue from there;
- **page output**: pages leave the engine one at a time, so a rollback can drop the pages after the snapshot.

pdfTeX and XeTeX are both generated from Knuth's `tex.web` through web2c, so the same places exist in pdfTeX. We fork
pdfTeX from TeX Live's source and add the hooks. TeXpresso's code is MIT; the idea and its structure can be reused.

Resuming from a snapshot continues the same process state, so a live run's output equals a run from scratch. That's
true by construction, and the test suite checks it (see Checks).

### 2. Real PDF output, no DVI

pdfTeX in PDF mode writes one file whose shared parts (fonts, cross-reference table) come at the end, so it can't be
rolled back page by page the way TeXpresso rolls back XDV. Rather than switch pdfTeX to DVI mode (which changes how
graphicx and hyperref behave, so it wouldn't be identical), we finish the PDF in a copy:

- to show the current pages, fork the running engine; the child ends the document (writes the fonts and the
  cross-reference table) and exits, giving a complete PDF of the pages so far, written by pdfTeX itself;
- the parent carries on typesetting.

The pane draws that PDF. The cost is finishing: mostly embedding font subsets, expected to be tens of milliseconds.
Phase 1 measures it.

### 3. TeX Live files on demand, per year

Overleaf keeps one full TeX Live image per year on its compile servers, shared by all users. We can't ship 5 GB per
year, and don't need to: a paper reads a few hundred of TeX Live's ~200,000 files.

- For each TeX Live year Overleaf offers, build an index (path, size, checksum) and a bundle from the official
  historic TeX Live archive for that year. Host them ourselves (GitHub releases or a CDN).
- The file-read hook already sees every file the engine opens. A file not in the local cache is fetched from the
  bundle once and cached under `~/Library/Caches/<bundle id>/texlive/<year>/`.
- Tectonic's bundles work this way; ours are pinned to Overleaf's exact years so the bytes match.
- First compile of a paper: tens of MB. After that: offline. An option downloads a whole year for full offline use.

### 4. Overleaf's run, reproduced

- Passes: reproduce latexmk's decisions (rerun LaTeX after a changed `.aux`/`.toc`, run BibTeX/Biber when citations
  change) inside the live engine's loop, or run latexmk's own rules alongside it.
- Flags and environment: copy the CLSI's (`-synctex=1`, `-interaction=batchmode`, the `latexmkrc` it uses), and pin
  `SOURCE_DATE_EPOCH` / `FORCE_SOURCE_DATE` so `\today` and timestamps are reproducible. Read Overleaf's source
  to learn these. It's AGPL: learn, don't copy.
- Engine choice per project: pdfLaTeX → live pdfTeX; XeLaTeX → TeXpresso (XeTeX) as today; LuaLaTeX → open question
  (see Later).

## Phases

Each phase ends with a measurement, logged in the renderer project's logs.

1. **Prototype (go/no-go).** Build pdfTeX from TeX Live source with the three hooks and fork-to-finish.
   - Measure: rollback correctness on the PaperA copy and the corpus (live output = from-scratch output, byte for
     byte after pinning time), keystroke-to-PDF latency, finish time per update, memory with snapshots.
   - Go if: correct on the corpus, finish ≤ 50 ms on a 40-page paper, typing latency within 1.5× today's.
2. **TeX Live on demand.** Indexes and bundles for the years Overleaf offers (start with the current default),
   the fetch-and-cache path in the file hook, and a year read from the project's settings.
3. **Overleaf's run.** Passes, BibTeX/Biber, flags, pinned dates.
4. **The pane on real PDFs.** Draw the finished PDF; port what's built on TeXpresso's output: word-level cursor
   sync (from SyncTeX plus the PDF's text positions), PDF comments and their anchors, the issues list (now from
   pdfTeX's log, which is Overleaf's log).
5. **Switch over.** pdfLaTeX projects use the live pdfTeX by default, with a setting to fall back to XeTeX.

## Checks

- **Live equals full.** After each scripted edit in a test, the live PDF equals a from-scratch run's PDF (same
  bytes after pinning dates; else same text, positions and page count).
- **Ours equals Overleaf's.** The renderer harness's arXiv corpus (`clients/render/harness`), compiled on our
  local Overleaf CE with the matching TeX Live year (and spot-checked on overleaf.com with the user's throwaway
  project), against the live pdfTeX. Compare page count, every line's text and position, and the log's errors and
  warnings. The target is 100%; every mismatch is a bug in reproducing Overleaf's setup, and is listed until fixed.
- **No regressions** for XeLaTeX projects, which stay on TeXpresso.

## Costs and risks

- **Licence.** pdfTeX is GPL. Our fork stays GPL and ships as a separate executable beside the app, with its
  source published. The app itself is unaffected (separate process, like `texpresso-xetex` today). Record this in
  `docs/release.md` before release.
- **Snapshots while writing a PDF.** pdfTeX holds an open output file and font state; a forked child finishing the
  document must not disturb the parent's file. Likely approach: the engine writes to memory, and each child writes
  its own copy. Phase 1 decides.
- **Finish time on long documents.** If finishing grows with document length, finish only the pages on screen
  (pdfTeX can't drop earlier pages, but the child can skip font embedding we already have: an open question).
- **Effort.** Weeks. Phase 1 is the risk; the rest is engineering.
- **Hosting.** Bundles for several TeX Live years. A few GB each on a CDN, fetched per file.

## Later

- LuaLaTeX projects: the same method on LuaTeX (also web2c-derived), after pdfTeX works.
- A from-scratch check on every compile: run a full pdfLaTeX in the background now and then and compare, as a
  safety net while the live engine matures.

## Until then

- The TeX Gyre stand-ins (`28fca91`) make most pdfLaTeX papers typeset in the right fonts.
- If a quick win is wanted before Phase 1: a background pdfLaTeX check after you pause (a saved preamble makes it
  about a second), used for the issues list and a page-count warning, not shown as the PDF.
