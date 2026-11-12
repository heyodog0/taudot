# pdfsource: PDF → source, proven by re-typesetting

pdfsource recovers a paper's LaTeX source from its PDF. Each paragraph it recovers is either **proven** or reported
approximate with a reason. Code: `clients/pdfsource/` (Rust, standalone crate).

## The claim

A paragraph's source is proven when re-typesetting the recovered text with the recovered parameters gives the same
glyphs (font, code) on the same lines at the same x as the PDF, to pdfTeX's printed precision (0.001 bp). In
practice the reproduced content stream has the same TJ numbers. There is no LLM: pdfLaTeX itself checks every
claim.

## Commands

    pdfsource prove FILE.pdf [--json]      per-paragraph verdicts, reasons, kind, timings per phase (ms)
    pdfsource tex FILE.pdf                 the recovered LaTeX, each paragraph marked proven or approximate
    pdfsource lines FILE.pdf [PAGE]        lines, columns, paragraphs found
    pdfsource dump FILE.pdf [PAGE]         glyphs (debug)

Build with `cargo build --release` in `clients/pdfsource/`. `kind` is one of main, block, item, foot, small.

## Pipeline

1. **Read.** Glyphs with their fonts (encodings, built-in Type 1 encodings, ToUnicode), colour operators, and
   pdfTeX's position chain in sp.
2. **Layout.** Lines → columns (modes of long lines' edges, ties broken by edge position) → paragraphs (indent,
   short last line), joined across columns and pages. Displays are found separately (below).
3. **Fonts.** PS name → `pdftex.map` line with a matching encoding → raw TFM → VF candidates covering every used
   code. Ligatures are decomposed from the TFM so TeX rebuilds them and hyphenates as the original did. TFM kern
   programs are parsed: a kern the PDF doesn't show (`BERT{}:` from a macro) is typed as `{}` between the letters.
4. **Guess.** Text under private catcodes, font switches, italic corrections, inferred space factors, rigid gaps
   (`\quad`, `\enspace`, `\,`), colour literals. Column geometry is calibrated to the sp; per-line placement
   reproduces the Td chain's residual.
5. **Prove.** All paragraphs are typeset in batches with stock pdfLaTeX (TeX Live 2026), read back and compared.
   Failures are repaired and retried: hyphen readings, forbidding breaks the original didn't take (ties,
   no-hyphenation, `\sloppy` first in bibliographies), parameter sets, the one-TJ-unit residual search (also for
   11–12 pt fonts, where a unit is 0.0109 bp), then a per-paragraph hsize/left search (16 sp steps over ±640 sp,
   then 1 sp) and the residuals again. A spacing guess that gets less far than the previous one is taken back.
   Some paragraphs are proven under a second LaTeX setup (without `bm`, which moves scripts); the report and the
   LaTeX output say which.
6. **Recheck.** Every paragraph proven on the parked engine is typeset again by a plain pdfLaTeX process at the end
   and must match, or it is reported unproven.

The proof is strict: a paragraph with glyphs inside its region that aren't in its lines can't be proven, and a
single line can't be proven alone.

### Parked-engine tries

Each LaTeX setup gets one parked engine (`src/park.rs`, libtau from `clients/universal`, stock pdfLaTeX). The main
file is the preamble, `\@@input pbody`, `\PSend`. libtau forks once as TeX reads the input line (`TAU_MARK`), and
each batch resumes that snapshot in a fresh child, up to 4 at once (`PDFSOURCE_JOBS`). A try costs its own page,
not a pdfLaTeX start and format load. `PDFSOURCE_PARK=0` runs stock processes instead. Most of the remaining time
is pdfTeX typesetting the batches (about 11 ms per paragraph).

## What is handled

- **Paragraphs** in one or two columns, joined across columns and pages, at every text size: body, captions,
  footnotes, references. Lists, hanging indents and indented blocks (their geometry derived, not calibrated).
  Microtype expansion and protrusion (`\leftprotrusion` on items only when observed).
- **Inline math:** fonts, sub/superscripts, accents, operator names (`\log`, `\max`). `\%` is cmr `%`; a cmr comma,
  period or hyphen next to math is text. Right after a formula, a gap narrower than the tightest interword space
  (space − shrink) is no space: TeX ends a formula with its last letter's italic correction (`$T$.`).
- **Text in math:** text-font glyphs inside a formula (`BERT$_{\textsc{base}}$`, `\text`) become `\mbox{...\/}`,
  since the text commands end with an italic correction.
- **Footnote marks and citations.** Spaces after `,`/`;` inside citation brackets are control spaces (natbib,
  `\cite`).
- **Headings.** LaTeX sets a heading's number and its `\quad`/`\enspace` in the heading's font, in a box that
  starts with glue (`\@hangfrom{\hskip<indent>\@svsec}`), so microtype doesn't protrude the number. Reproduced that
  way, and the quad is not taken for a space when solving the line's glue ratio.
- **Accents.** A base glyph that moves back under its accent stays in the line. A text accent raised a little over
  its base (`\'a` in Times) is not a superscript.
- **Small caps** through a scaled virtual font (`ptmrc7t`: lowercase drawn from the base font at 0.8, letterspaced
  by moves in each VF packet). Offered as a candidate for the smaller size and tried when a paragraph's positions
  fail at such a glyph.
- **Last lines** are set at natural width (glue ratio 0), even with no ordinary space to solve it from.
- **Bibliographies**, hanging or `[n]`-labelled:
  - Hanging entries at any indent (natbib's `\bibhang`, not only `\parindent`) are joined into one paragraph. The
    indent is measured to ~30 sp; a line slightly off gets a per-paragraph indent search (±64 sp). A hanging line's
    shift is put back when shipping (`\lastbox` drops it).
  - `[n]` labels sit in a box as wide as the hanging indent (`\hbox to<hang>{[n]\hss}`), so the text starts at the
    indent.
  - `\newblock` glue (`\hskip .11em plus .33em`, after a factor-1000 space) is inferred, a variant with negative
    shrink is tried before `\frenchspacing`, and a line set mostly in italics takes its glue ratio from the italic
    spaces.
  - **As lists:** natbib can set each entry as a list item (every line at `\bibhang` by `\parshape`, line 0 opening
    with an empty label box of width −`\bibhang`, then `\penalty0`). Tried for a failing hanging paragraph, kept
    when it gets further.
- **Displays**, single-row: body-size lines with math between two paragraphs, inside a column and off its edges,
  grown from one line by vertical proximity, with an equation number "(n)" at the right edge. The source is rebuilt
  from the glyphs in PDF order: fractions, `\sqrt`, `\overline`, big operators with limits, `\left`/`\right`,
  `\quad` gaps, operator names. It is typeset as `$$ … \eqno\hbox{(n)}$$`, its shift recomputed from TeX's centring
  rule, and proven on every glyph, each line's baseline offset and each rule. Displays are counted apart from text.

## Tests

The corpus is arXiv papers with sources under `$TAUDOT_REF/corpus/`, typeset by us with stock pdfLaTeX; the
converter never sees the source. Sources and PDFs stay outside the repo.

    uv run tests/corpus.py build [paper...]     ground-truth PDFs → $PDFSOURCE_CACHE/build/
    uv run tests/measure.py [paper...]          prove --json on each, results and a summary
    uv run tests/regress.py [--bin PATH]        a few papers; exit 1 if any proves fewer paragraphs
    uv run tests/diffbuilds.py OLD NEW FILE.pdf paragraphs one build proves and the other doesn't

Run from `clients/pdfsource/`. 33 papers plus 2 synthetic ones build; 1412.6980 and 1707.06347 are excluded (their
main file only includes a prebuilt PDF), leaving 32 papers, 580 pages.

## Results

2026-11-11, all text sizes, 32 papers, 580 pages:

| | proven | of | % |
|---|---|---|---|
| paragraphs | 3 187 | 6 845 | 46.6 |
| paragraphs of 2+ lines | 2 272 | 4 235 | 53.6 |
| lines | 14 468 | 25 461 | 56.8 |
| words | 146 509 | 255 521 | 57.3 |
| displays | 42 | 245 | 17.1 |

19 ms per paragraph on a shared machine. Stock recheck: 3 229/3 229 agree. On 1512.03385, verdicts on the parked
engine and on stock processes are identical paragraph by paragraph.

Why the rest fail (first reason per paragraph): positions 3 032, stray glyphs 503, math 119, glyphs 98, breaks 58,
font not found 41, accent or overlap 10.

"Positions" means the glyphs are right but an x is off. Known causes:

- Microtype expansion off on a line (~570). In 1910.10683 a corpus-build artifact (the build lacks `T1lmr.fd`, so
  LaTeX substitutes `T1/cmr`). In 2006.11239, lines with math: some width, likely in the math, differs.
- One-TJ-unit misses that the residual, geometry and indent searches don't fix (~330).
- Bibliography entries in natbib's list form under microtype: the empty label box at the line start stops
  protrusion, which `\hangindent` doesn't reproduce.
- Parameters not recovered yet: `\parfillskip`/`\rightskip` variants, `\emergencystretch`, hand-written kerns and
  `\hspace`, `\looseness`, float-adjacent geometry.
- Single-line table cells and headings that layout takes for paragraphs.

## Open

1. Paragraph parameters beyond the column: search `\emergencystretch`, `\looseness`, `\rightskip` per paragraph.
2. Multi-row displays (`align`, `eqnarray`, `gather`): one baseline per row, alignment points at "=", a number per
   row.
3. `\text`/`\mbox` inside displays, and extensible delimiters (`\left` built from pieces).
4. Stray glyphs: page furniture, line numbers and float text that layout lets into paragraphs.
5. Tables (not started), then whole-document source and a pages-identical measure.
6. Fonts outside `pdftex.map` (Type 3, renamed subsets): 41 paragraphs.
7. Verdicts move by a few paragraphs between runs of one build (hash order in the prover).
8. Equation numbers in 2006.11239 end 0.67 bp past the column edge; detection tolerates it, the cause is unknown.

## Prior art (not run here)

- **go-pdfkit/latex** (BSD-3, Go, 2026): heuristic PDF → LaTeX for TeX PDFs. On 275 arXiv papers: 99.6 % compile,
  word F1 median 0.67, math token F1 0.61, page-one ink F1 0.40; no proof by reproduction.
- ML: Nougat, MinerU, Mathpix, TexOCR (arXiv 2604.22880): image → markup, approximate by construction.
