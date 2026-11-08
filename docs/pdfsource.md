# pdfsource: PDF → source, proven by re-typesetting

Status: stage 1 (body paragraphs) working, 2026-11-07. Code: `clients/pdfsource/` (Rust, standalone crate).
Log: `docs/agents/pdfsource.log.md`. Brief: `docs/agents/pdfsource.md`.

## The claim

A paragraph's source is **proven** when re-typesetting the recovered text with the recovered parameters gives the
same glyphs (font, code) on the same lines at the same x as the PDF, to pdfTeX's printed precision (0.001 bp;
in practice the reproduced content stream has the same TJ numbers). No LLM; every claim is checked by
pdfLaTeX itself.

    pdfsource prove FILE.pdf [--json]      per-paragraph verdicts, reasons, timings
    pdfsource lines FILE.pdf [PAGE]        lines, columns, paragraphs found
    pdfsource dump FILE.pdf [PAGE]         glyphs

## How (summary; details in the log)

1. Read: glyphs with fonts (encodings, built-in Type 1 encodings, ToUnicode), colour operators, pdfTeX's PDF
   position chain in sp.
2. Layout: lines → columns (modes of long lines' edges) → paragraphs (indent, short last line), joined across
   columns and pages.
3. Fonts: PS name → `pdftex.map` line with a matching encoding → raw TFM → VF candidates covering every used code;
   ligatures decomposed from the TFM so TeX rebuilds them (and hyphenates as the original did).
4. Hypothesis: text under private catcodes, font switches, italic corrections, inferred space factors, colour
   literals; column geometry calibrated to the sp; per-line placement that reproduces the Td chain's residual.
5. Typeset all paragraphs in one pdfLaTeX run (stock TeX Live 2026), read back, compare; repair and retry:
   hyphen readings, forbid breaks the original didn't take (ties, no-hyphenation), parameter sets, residual ±sp.

## Measurements

Corpus: `$TAUDOT_REF/corpus/` (arXiv papers with sources), typeset by us with stock pdfLaTeX (TeX Live 2026, `tests/corpus.py`):
33 papers + 2 synthetic build (others: no main file, XeLaTeX/fontspec, or broken). The converter never sees the
source. Machine shared with other agents (load 4–9).

### 1. First measurement (2026-11-07, commit with Td residuals and colour literals; before tie repairs)

34 PDFs, 607 pages, 53 244 text lines, of which 19 673 in body paragraphs found (6 469 paragraphs).

| | proven | of | % |
|---|---|---|---|
| paragraphs | 1 300 | 6 469 | 20.1 |
| lines | 3 582 | 19 673 | 18.2 |
| words | 33 333 | 204 722 | 16.3 |

Why the rest fail (paragraphs):

| reason | n | what |
|---|---|---|
| font not found | 1 924 | a font the map lookup misses (CM-Super/LM T1 fonts, others): next fix |
| math | 1 609 | math fonts or glyphs off the baseline in the paragraph (stage 4; not attempted) |
| positions | 1 546 | same lines, a glyph off by ≥ 0.0015 bp (mostly one TJ unit: residual/geometry; also run-in headings, bibliography entries taken as paragraphs, space fonts) |
| breaks | 89 | different line breaks (ties, `\hyphenation` exceptions: fixed after this run) |
| accent | 1 | accents (two glyphs) |

Time: 86 ms per paragraph, 0.92 s per page (most of it the calibration scans: ~150 candidates × paragraphs per
scan, as pages of one pdfLaTeX run; then a few repair rounds). Per paper 7–32 s.

Best papers: 1506.02640 71 %, 1512.03385 51 % (60 % after the tie repairs; 51 of its 55 non-math paragraphs).

### 2. Stage 2 (2026-11-08): inline math, microtype, footnote marks, headings, hanging indents

32 PDFs (1412.6980 and 1707.06347 excluded: their main file only includes a prebuilt PDF), 580 pages,
20 818 body lines found in 5 161 paragraphs (layout now separates abstracts and narrow blocks).

| | proven | of | % | stage 1 |
|---|---|---|---|---|
| paragraphs | 2 122 | 5 161 | 41.1 | 20.1 |
| paragraphs of 2+ lines | 1 329 | 3 100 | 42.9 | |
| lines | 9 180 | 20 818 | 44.1 | 18.2 |
| words | 95 485 | 214 618 | 44.5 | 16.3 |

Why the rest fail: positions 2 678 (mostly lists/bullets, author blocks, captions and tables caught as
paragraphs, run-in heads, space fonts at font changes, `\boldsymbol` vs `\bm`; some one-unit kerns), math 217
(cmex: big operators and delimiters, fractions), accents 81 (raised accents on capitals), breaks 29, other 34.
Per paper: 1512.03385 96.5 %, 1506.02640 83.9 %, 1804.02767 83.8 %, 1611.07004 78 %, 1409.1556 69.7 %;
lowest 1910.10683 15.4 % (lists and itemized text), math_0211159 25.6 % (displays, theorem-style text).
Time: 0.84 s per page (calibration ~40 % cheaper than stage 1), 7–74 s per paper.

Output: `pdfsource tex FILE.pdf` writes the recovered LaTeX (fonts defined, each paragraph marked proven or
approximate with its reason); the 1512.03385 output compiles without errors.

### 3. Stage 3 (2026-11-08): lists, indented blocks, a stricter proof

| | proven | of | % | stage 2 |
|---|---|---|---|---|
| paragraphs | 2 076 | 5 743 | 36.1 | 41.1 |
| paragraphs of 2+ lines | 1 388 | 3 371 | 41.2 | 42.9 |
| lines | 9 281 | 21 767 | 42.6 | 44.1 |
| words | 97 544 | 225 601 | 43.2 | 44.5 |

The percentages dip although more lines are proven (9 281 vs 9 180): the proof got stricter (a paragraph with
glyphs inside its region that aren't in its lines can't be proven any more: 525 rejected, among them split-off math
accents that both sides used to lack, and table rows or author blocks caught as one-line paragraphs), and list
items now count as whole paragraphs instead of loose trivially-proven fragments. Reasons: positions 2 829, stray
glyphs 525, math 179, glyphs 85, breaks 31, fonts 14. 1.07 s per page.

Some paragraphs are proven under a second LaTeX setup (without `bm`, which moves scripts): the report and the
emitted LaTeX say which.

### 4. Citations and 11–12 pt units (2026-11-08)

| | proven | of | % |
|---|---|---|---|
| paragraphs | 2 266 | 5 743 | 39.5 |
| paragraphs of 2+ lines | 1 553 | 3 371 | 46.1 |
| lines | 10 701 | 21 767 | 49.2 |
| words | 109 835 | 225 601 | 48.7 |

Two fixes: spaces after `,`/`;` inside citation brackets are control spaces (natbib, `\cite`), and the
one-TJ-unit residual search now also fires for 11–12 pt fonts (a unit is 0.0109 bp there; the threshold was
0.0105). 1810.04805 went from 40 to 70 proven paragraphs, 2302.13971 from 144 to 172. Also `\frenchspacing` as a
hypothesis (bibliographies). 1.19 s per page.

### 5. Body text after rigid gaps and item fixes (2026-11-08)

| body text | proven | of | % |
|---|---|---|---|
| paragraphs | 2 379 | 5 732 | 41.5 |
| paragraphs of 2+ lines | 1 671 | 3 371 | 49.6 |
| lines | 11 470 | 21 765 | 52.7 |
| words | 118 320 | 225 618 | 52.4 |

Rigid gaps anywhere (`\quad` after run-in heads, `\enspace`, `\,` in numbers), `\leftprotrusion` on items only
when observed. 1.22 s per page. Next measurement adds the other text sizes (captions, references, footnotes).

### 6. All text sizes (2026-11-08): captions, references, footnotes

| all sizes | proven | of | % |
|---|---|---|---|
| paragraphs | 2 878 | 8 845 | 32.5 |
| paragraphs of 2+ lines | 1 701 | 3 523 | 48.3 |
| lines | 12 047 | 25 330 | 47.6 |
| words | 121 514 | 253 375 | 48.0 |

The text analysed grows from 21 765 to 25 330 of the corpus's 47 635 text lines; proven lines +577, words
+3 194. Most new one-line "paragraphs" are table cells and figure labels in small type (they fail, as they
should). 1.56 s per page.

### Baselines (prior art, not run here)

- **go-pdfkit/latex** (BSD-3, Go, 2026): heuristic PDF → LaTeX for TeX PDFs, 275 arXiv papers: 99.6 % compile,
  word F1 median 0.67, math token F1 0.61, page-one ink F1 0.40; no proof by reproduction. Its list of traps
  (columns before lines, pdfTeX fills fraction rules while xdvipdfmx strokes them, `\footnoterule` looks like a
  fraction bar, theorem italics vs `\emph`, accents as two glyphs, text-matrix scaling) matches what we meet.
- ML: Nougat, MinerU, Mathpix, TexOCR (arXiv 2604.22880): image → markup, approximate by construction.
- Our difference: each element is either proven (identical re-typeset) or reported approximate with a reason.
