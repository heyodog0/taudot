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

### 7. Broken kerns, paragraph geometry, bibliographies (2026-11-09)

| all sizes | proven | of | % |
|---|---|---|---|
| paragraphs | 2 839 | 7 437 | 38.2 |
| paragraphs of 2+ lines | 1 932 | 4 118 | 46.9 |
| lines | 13 132 | 25 347 | 51.8 |
| words | 132 881 | 253 380 | 52.4 |

The largest unproven block was multi-line paragraphs off by one TJ unit (551 paragraphs, 3 405 lines), mostly
on the first line. Fixes:

- **Kerns the source broke.** A TFM kern that the PDF doesn't show (`BERT{}:` from a macro) is typed as `{}`
  between the letters (TFM kern programs are now parsed).
- **Per-paragraph geometry.** A paragraph still one unit off after the residual search gets its own hsize/left
  search (hsize alone and the ridge, 16 sp steps over ±640 sp, then 1 sp), then the residuals are searched again.
  Indented blocks get their geometry derived, not calibrated, and are off by a few hundred sp.
- **Bibliographies.** The smaller-size pass now groups hanging-indent entries (it split each entry into lines).
  A hanging line's shift is put back when shipping (`\lastbox` drops it: no hanging paragraph could be proven
  before). `\newblock` glue (`\hskip .11em plus .33em`, after a factor-1000 space since bibliographies set
  `\sfcode`\.=1000`) is inferred in bibliography paragraphs, and a line set mostly in italics takes its glue
  ratio from the italic spaces.

Paragraph counts fall (8 871 → 7 437) because bibliography lines are grouped into entries. A single line can no
longer be "proven" alone, so a few papers lose lines. 1.76 s per page. `kind` (main, block, item, foot, small)
is now reported per paragraph.

### 8. Section headings, deterministic layout (2026-11-10)

| all sizes | proven | of | % |
|---|---|---|---|
| paragraphs | 2 912 | 7 411 | 39.3 |
| paragraphs of 2+ lines | 1 934 | 4 118 | 47.0 |
| lines | 13 225 | 25 330 | 52.2 |
| words | 133 314 | 253 375 | 52.6 |

A numbered heading ("3.1 Pre-training") has a `\quad` after the number, in the heading's font (not the body's),
and that quad was taken for an ordinary space when solving the line's glue ratio; both fixed. Column detection
broke ties by hash order, so one paper's layout changed between runs (2103.00020: 799 or 773 paragraphs); ties
now go by edge position. 2.0 s per page (machine under load).

### 9. Display math, bibliography break order (2026-11-10)

| all sizes, text | proven | of | % |
|---|---|---|---|
| paragraphs | 2 936 | 7 437 | 39.5 |
| paragraphs of 2+ lines | 1 942 | 4 118 | 47.2 |
| lines | 13 280 | 25 347 | 52.4 |
| words | 133 915 | 253 380 | 52.9 |
| **displays** | **42** | **252** | **16.7** |

Displays are reported on their own (text totals leave them out). A display is the body-size lines with math
between two paragraphs, inside a column and off its edges, grown from one line by vertical proximity, with an
equation number "(n)" at the right edge and the rules inside it. Its source is rebuilt from the glyphs in PDF order:
fractions, `\sqrt`, `\overline`, big operators with limits, `\left`/`\right` delimiters, `\quad` gaps, operator
names (`\log`, `\max`: this also helps inline math). It is typeset as `$$ … \eqno\hbox{(n)}$$`, put where TeX
would (`\lastbox` loses the display's shift, so it is recomputed from TeX's centring rule), and proven on every
glyph, each line's baseline offset and each rule. Why the other 210 fail: positions 87 (mostly spacing the source
wrote by hand), text inside math 32 (`\text`, `\mbox`), glyphs off the main baseline 23 (multi-row displays:
`align`, `eqnarray`), stray glyphs 18, breaks 17, extensible delimiters 14.

Break repairs in bibliography entries (hanging or `[n]`-labelled) now try `\sloppy` before forbidding breaks.
Text lines +55, words +601 over section 8; no paper loses a proven paragraph. 2.0 s per page.

### Baselines (prior art, not run here)

- **go-pdfkit/latex** (BSD-3, Go, 2026): heuristic PDF → LaTeX for TeX PDFs, 275 arXiv papers: 99.6 % compile,
  word F1 median 0.67, math token F1 0.61, page-one ink F1 0.40; no proof by reproduction. Its list of traps
  (columns before lines, pdfTeX fills fraction rules while xdvipdfmx strokes them, `\footnoterule` looks like a
  fraction bar, theorem italics vs `\emph`, accents as two glyphs, text-matrix scaling) matches what we meet.
- ML: Nougat, MinerU, Mathpix, TexOCR (arXiv 2604.22880): image → markup, approximate by construction.
- Our difference: each element is either proven (identical re-typeset) or reported approximate with a reason.
