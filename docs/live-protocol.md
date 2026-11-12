# The live pdfTeX's interactive protocol

Status: draft 1 (2026-11-06; `para` 2026-11-07), implemented by both sides: the pdftex agent's `pdftex-live --serve` (`f551713`) and the
app's `clients/mac/Sources/TaudotPDF/LiveTex.swift`. A fake driver (`clients/mac/Tests/live/fake-live.py`, stock
pdfTeX from scratch on every edit) speaks it too.

It is TeXpresso's protocol (`TaudotPDF/Txp.swift` ↔ `clients/render/driver.c`) with one change of kind: the
driver hands over **finished PDFs**, written by pdfTeX itself, instead of drawing pages on request. The app draws
them with PDFKit / Core Graphics. Everything the pane used to ask TeXpresso for (renders, glyphs) it now reads from
the PDF; SyncTeX, the log and BibTeX's log come as files beside each PDF.

## Starting

```
pdftex-live --serve [--engine PATH] [--snapshot-ms N] [--bibtex PATH] [--max-runs N] [--state STATE] DIR MAIN.tex OUT
```

- `DIR`: the project folder, **read only**. It is the engine's synced copy of the Overleaf project: anything
  written there (`.aux`, `.bbl`) could reach the project. The files latexmk would write live under `OUT` and shadow
  `DIR`'s for later reads. `MAIN.tex` is relative to `DIR`.
- `STATE` (optional): a folder the driver keeps between sessions (the app gives the page cache's). Whenever a
  compile settles, and at exit, the driver leaves the run's `.aux` files, `.bbl` and `.blg` there, with `rule`
  (what the `.bbl` was made from); at start they stand in for missing ones, so the first run of a reopened project
  needs no BibTeX run and no rerun for references (as TeXpresso's `TAUDOT_BIB_CACHE`). A `.bib` changed since
  then (or a kept `.bbl` with no `rule`) reruns BibTeX.
- `OUT`: a scratch folder the app made and removes; every file the driver announces lives under it.
- Environment, set by the app: `TEXMFCNF`, `TEXSTORE_URL`, `TEXSTORE_IMAGE` (e.g. `2026.1@r79468`),
  `TEXSTORE_ROOT`, `TEXFORMATS`, `SOURCE_DATE_EPOCH` / `FORCE_SOURCE_DATE` (as the driver's own checks pin them).
  The app picks the year from the project's TeX Live image; the driver doesn't guess.
- Flags as Overleaf's CLSI: `-synctex=1`, `-interaction=batchmode`, latexmk's rerun and BibTeX rules (the driver's
  existing `live.c` rules, unchanged).
- The driver exits when its stdin closes, killing every engine process (as `--leave`'s opposite already does).

## Commands: app → driver (stdin)

One JSON array per line, UTF-8. Paths are relative to `DIR`. Offsets are UTF-8 byte offsets.

| command | meaning |
|---|---|
| `["open", path, text]` | The whole text of a project file. The driver diffs it against its copy (or the disk's) and rolls back from the first changed byte. Sent for each open editor buffer at start and after a restart; also for a file saved on disk that no editor holds. |
| `["change", path, pos, del, ins]` | Replace `del` bytes at `pos` with `ins`. Many may come in a burst (typing); the driver may coalesce them before resuming. |
| `["goal", page]` | The last page in view, 0-based; `-1` means the whole document. See *When a PDF comes*. |
| `["finish"]` | Finish a PDF of the pages shipped so far now, even if the goal isn't reached (the app asks when a run has been quiet for a while, e.g. a long figure page). |
| `["cursor", path, line, column]` or `["cursor", path, pos]` | Optional (tau-live only; others ignore or reject it). The editor's cursor came to rest: `line` 1-based, `column` in UTF-8 bytes, or a byte offset `pos`. The driver keeps snapshots near it when it gives memory back, and may typeset quietly up to it (no events) so a first key there is as quick as the next ones (`docs/universal.md`, the scout). The app sends it 300 ms after the cursor stops, once per place. |
| `["rescan"]` | Files changed on disk that the engine doesn't get as text (`.bib`, `.bst`, images, `.sty` in the project): reread them and apply latexmk's rule (a `.bib` change → BibTeX, rerun if the `.bbl` changed). |

Every `open` and `change` counts as one *applied* command, in order. Events carry `applied`, the count the driver
had read when it started the run that made them, so the app can tell which edits a PDF contains.

## Events: driver → app (stdout)

One JSON object per line, field `ev`. Times are microseconds. Files named in an event stay until the driver has
announced **three newer** files of the same kind; the app reads (or copies) them in its handler.

### `hello` (once, first line)

```json
{"ev":"hello","protocol":1,"engine":"pdfTeX 3.141592653-2.6-1.40.29 (TeX Live 2026)","image":"2026.1@r79468"}
```

### `fetch` (while TeX Live files are fetched; mostly the first open)

```json
{"ev":"fetch","file":"tex/latex/hyperref/hyperref.sty","files":41,"bytes":3145728,"waiting":true}
```

At most every 100 ms. `files`/`bytes`: totals fetched in this session so far; `waiting`: the run is blocked on
this file (not a prefetch). Shown as progress in the pane's status line.

### `run` (a run starts or resumes)

```json
{"ev":"run","seq":7,"run":1,"applied":12,"why":"edit","from_page":3}
```

- `seq`: compile number, one per batch of edits (latexmk's reruns keep the `seq`, bump `run`).
- `why`: `"open"`, `"edit"`, `"aux"` (latexmk's rerun after a changed `.aux`/`.toc`/…), `"bibtex"` (after BibTeX
  changed the `.bbl`), `"rescan"`.
- `from_page`: pages before it (0-based) were shipped before the snapshot the run resumed from, so they are the
  same as in the previous PDF.

### `pdf` (a finished PDF)

```json
{"ev":"pdf","seq":7,"run":1,"applied":12,"pages":5,"final":false,"from_page":3,
 "path":"OUT/pdf-7-1234.pdf","synctex":"OUT/pdf-7-1234.synctex.gz","log":"OUT/pdf-7-1234.log",
 "edit_us":41000,"finish_us":19000}
```

- A complete PDF of the run's pages so far, finished by pdfTeX in a forked child (or the run's end).
- `final`: the run ended (`\end{document}` or a fatal error); its page count is the document's.
  Not final: more pages may follow; pages at or past `pages` are still the old ones.
- `from_page`: as in `run`.
- `synctex`: the SyncTeX of exactly this PDF (`.synctex.gz` or plain `.synctex`; the app reads both).
- `log`: the run's `.log` so far (Overleaf's log; on a final PDF, the whole of it).
- `edit_us`: from reading the first edit of `applied` to this PDF written; `finish_us`: the finish alone.

**Display pages on tau-live** (pdfTeX, LuaTeX; verified in `clients/universal/driver/tau-live.c`): a `pdf` event with
`"display":true` comes before the run's first finished output: `path` is the last finished PDF with page `pages` - 1
drawing the new run's page (an incremental update), every other page as it was. That page is the first the run
ships that differs from the old one: `from_page`, or a later page when TeX had set those before it read the edited
line or the run resumed pages before the edit (pages from `from_page` to it are unchanged; pages after it in the file are old ones, as for any early
output). No `synctex` or `log`. It draws exactly what the finished page will (checked in `uni.py display`); the finished output
follows in a normal `pdf` event.

**XeTeX on tau-live** (verified in `clients/universal/driver/tau-live.c`): `path` is the run's `.xdv`. With
`tau-pdfmx` beside tau-live (and no `--no-pdfmx`), tau-live converts the pages that changed and the event carries:

```json
{"ev":"pdf", ..., "path":"OUT/t/run-7-1234/main.xdv", "pdf_path":"OUT/t/run-7-1234/main-3-3.pdf",
 "pdf_first":3, "pdf_last":3, "pdfmx_us":5200}
```

- `pdf_path`: a PDF of pages `pdf_first`..`pdf_last` (0-based, inclusive), byte for byte what
  `xdvipdfmx -q -z 1 -s FIRST+1-LAST+1 -o PDF_PATH XDV` makes in the project's working directory.
- Every other page below `pages` is unchanged: keep the one shown. `pdf_last < pdf_first`: no page changed (no
  `pdf_path`), only the page count may have.
- On a `final` event the document has `pages` pages: drop shown pages past it. On an early one the client keeps the
  pages after it, as for pdfTeX.
- A page counts as changed when its XDV bytes, page 1 (its specials, e.g. the paper size, apply to every page), the
  units or the definition of a font number it may use differ from what earlier events delivered; the pages the
  client would show then draw identically to a whole-document `xdvipdfmx` of the final XDV (checked in
  `uni.py xpdf`).
- `pdf_error` (the converter's exit status) instead: the conversion failed; convert `path` yourself. The next event
  converts every page.
- `pdfmx_us`: from the request to the converter to its answer. Events after a pending conversion wait behind it, so
  the order is kept; `para` events don't wait.

### `done` (the compile settled: latexmk's rule has nothing left to do)

```json
{"ev":"done","seq":7,"runs":2,"pages":36,"code":0,"path":"OUT/final-9.pdf","log":"OUT/final-9.log","blg":"OUT/main-7.blg"}
```

- `path`: the last run's `final` PDF (already announced). The app treats this as the settled document: page cache,
  comment anchors, the issues list. **Absent when the last run wrote no PDF** (a fatal error before the first page
  ships): the app keeps the pages it shows (none on a first run) and settles anyway.
- `log`: the last run's log, whether or not it wrote a PDF (2026-11-06, sm-tex: P1). The issues list and the status
  line's first error come from it, so a fatal error's log is always shown.
- `blg`: BibTeX's log if BibTeX ran in this compile (else absent; the last one stays valid). On a reopen with
  `--state` BibTeX may not run at all: the app then shows `STATE/MAIN.blg` (the kept log) until a `blg` comes.
- `code`: pdfTeX's exit status of the last run (1 when TeX reported errors, as in batch mode; 3 when the engine
  died, after an `error` with `what` `engine`: the next command starts a new one).

### `bibtex`

```json
{"ev":"bibtex","seq":7,"code":0,"tool":"bibtex","blg":"OUT/main-7.blg","bbl_changed":true}
```

One latexmk step's programs. `tool`: those that ran, comma-separated (`bibtex`, `biber`, `makeindex`,
`makeglossaries`). `blg` only when BibTeX or biber ran in this step (a makeindex-only step leaves the last one valid).

### `error` (the driver can't typeset at all)

```json
{"ev":"error","what":"offline","message":"can't fetch tex/latex/base/article.cls: no network"}
```

`what`: `"offline"` (a TeX Live file couldn't be fetched and isn't cached), `"format"` (no format for this image),
`"engine"` (an engine process died unexpectedly), `"bibtex"` (BibTeX, biber or makeindex timed out,
`TAUDOT_TOOL_TIMEOUT_S`, 120 s, and was stopped), `"protocol"` (a command it couldn't read). The driver keeps
running if it can (an edit may remove the missing package); the app shows it and keeps the last PDF.

### `para` (a paragraph preview, 2026-11-07, parapreview)

The edited paragraph alone, typeset by the engine (patch 0011) from a process parked at the paragraph's start, as a
display list placed over its old lines on the page on screen. It comes a few ms after the `change`, long before the
PDF with the edit. Drivers and engines without it never send it; `TAUDOT_PARA=0` in the driver's environment turns
it off.

```json
{"ev":"para","go":12,"applied":40,"file":"main.tex","state":"exact",
 "pdf":"OUT/pdf-31-5120.pdf","page":9,"path":"OUT/para-0.tdl","overlay":"OUT/para-0.pdf","origin":[0,0],
 "erase":[[133.1,534.2,478.5,543.8],…],"lines":8,"old_lines":8,
 "faults":[30,13],"engine_cpu_us":640,"ship_cpu_us":300,"break_cpu_us":110,
 "engine_us":660,"ship_us":310,"write_us":120,"wake_us":50,"draw_us":700,"us":2400}
```

- `applied`: the edits it shows (as `pdf`'s `applied`). A PDF with at least these replaces it: the app removes the
  preview once that PDF's page is on screen. An older preview finishing later is never sent.
- `state`: `exact` (the same number of lines, the same heights, depths, widths and spacing as the old ones, and
  nothing in the paragraph that can move other things: the page around it is unchanged, so the preview is the
  page), `provisional` (shown; `why` says what differs: `lines`, `heights`, `spacing`, `indent`, `mark`,
  `vadjust`, `write`, `savepos`, `glue`; the exact pass reflows what follows), or `none` (no preview; `why`):

  | `why` | when |
  |---|---|
  | `insert` | footnotes, floats, `\marginpar` in the paragraph |
  | `parshape` | `\parshape` of more than one line or `\hangindent`: wrapfig, lettrine, section headings |
  | `shape` | (tau-live) the old lines start at different x (a hanging indent, a shaped paragraph): the pass ships its lines at one left edge, the old lines' |
  | `display` | the edit is inside a display (`\[…\]`, `equation`, …) |
  | `segment` | the old lines on screen are another part of the paragraph (a display between) |
  | `split` | the old lines run across pages or columns |
  | `image` | an image or form in the paragraph |
  | `noanchor` | no run has said where this paragraph is on the page on screen yet |
  | `far`, `end` | the paragraph doesn't end within 400 lines or 200 ms, or the document ends |
  | `operator X`, `font`, `glyph`, `nofont` | the lines' content uses something the display list doesn't draw (paths, non-Type 1 fonts) |

- `pdf`, `page`: the PDF (already announced) and page (0-based) the preview goes on: the newest PDF that shows that
  page, whose run said where the paragraph's lines are.
- `overlay`: the lines as a one-page PDF, the fonts' programs embedded whole, the content stream as pdfTeX wrote it
  for them at the old lines' place on a page of the page's size. Drawn with Core Graphics like the page, its glyphs
  have the exact page's pixels. `origin`: where that page's top-left goes on the page on screen (points; `[0,0]`
  when the place was known at the go).
- `path`: the same lines as a Taudot display list (TDL 2, `clients/render/dlist.md`: PAGE, FONT outlines, TEXT,
  RULE, END), in page points from the page's top-left. TEXT bboxes are the glyphs' ink.
- `erase`: page points (top-left origin, y down): paper over these first (the old lines and the new, padded to half
  the gap to the next line), and under the TEXT bboxes.
- Times (µs): `engine_us` from the wake to the lines broken (`break_cpu_us` of it in line_break), `ship_us` to the
  content stream, `write_us` to the file, `draw_us` the driver's display list and PDF, `wake_us` signal to wake,
  `us` from reading the `change` to this line. `faults`: page faults in the pass (before, after the lines).

Files named in `para` events are reused after four more previews.

## When a PDF comes

The app needs the page in view soon, and the rest when it's cheap. The driver's rule:

1. After an edit, the runner resumes at the snapshot before the first changed byte.
2. Once it ships the **goal page** (or any page, if the goal is behind the edit), finish a PDF at once. Also once
   an edit's run ships its **first page** (the snapshot is taken just before the edit, so that's the edited page,
   mostly), when the goal is further on: the edited page doesn't wait for the rest of the view to be typeset
   (2026-11-07, pdfpipe: PaperA, edit on page 1, goal page 2: 103 → 77 ms; goal page 3: 208 → 69 ms).
3. While the run goes on, finish again at most every 150 ms (fewer is fine; the app shows the newest).
   Also (2026-11-07, parapreview) once the page holding the edited paragraph ships, if no PDF of this run has it
   yet: the first PDF can stop a page short of it (the run resumes before a page break), and under typing no other
   came before the next key, so the edited page stayed old for as long as the typing lasted.
4. At the run's end, a `final` PDF; after the compile settles, `done`.

On tau-live (verified in `clients/universal/interpose/tau.c`), a fresh engine (the first compile, or a restart) also
finishes once as soon as it ships the goal page (page 1 when no goal is set): an early `pdf` (`final:false`) before the
rest of the document is typeset (paper-b, pdfLaTeX: open → first PDF 1.02 → 0.44 s).
5. A `finish` command finishes one now from the pages shipped so far (after an edit, only once the runner has
   passed the edited byte).
6. A new edit during a run kills that run's pending finishes; PDFs already announced stay valid.
7. **Except when edits keep coming** (2026-11-07, pdfpipe): rule 6 alone gave no PDF at all under a held key (an
   edit every 33 ms, a run ~100 ms to its PDF). The driver holds new edits (in memory: the engine's copy of the
   project doesn't see them yet) while the run in flight is the quickest way to show the oldest edit not yet in a
   PDF, i.e. when restarting would show it more than 150 ms after it came (the run's time to a PDF is learnt from
   recent ones). They are applied, all at once, as soon as that run announces a PDF or ends, or after
   max(300 ms, 3 × that time). Typing slower than a run never holds. `applied` stays exact: a PDF has exactly the
   edits counted in it. Measured in the app (PaperA, native): a new PDF every ~100 ms under a held key, the longest
   gap 98–232 ms (was none for 2–4 s).

## What the app does with it (for reference)

- Draws pages from the newest PDF with Core Graphics into IOSurfaces (as TeXpresso's renders were). Pages before
  `from_page`, and pages whose content stream is byte-identical to the shown one, aren't swapped.
- Takes page sizes from the PDF, the cursor dot's glyphs from PDFKit's character boxes, words for comments and
  double-click from the same, links from the PDF's `/Link` annotations, forward/inverse search from `synctex`.
- Shows `log`'s errors and warnings (the issues list) and `blg`'s BibTeX warnings.
- Keeps the last PDF on screen through `error`, a run with no pages, and a driver restart.

## Open questions

- ~~Coalescing: should the driver wait a few ms after a `change` for more before resuming?~~ No fixed wait; edits
  coalesce only under rule 7.
- ~~Does `-synctex=1` change the PDF?~~ No: byte-identical with `-synctex` 0, 1 and -1 (pdftex, 2026-11-06). The
  driver writes plain SyncTeX (`-synctex=-1`) by default, so no PDF waits on gzip; `--synctex 1` gives `.gz`.
