# The live pdfTeX's interactive protocol

Drivers: `pdftex-live --serve` (`clients/pdftex/serve.c`), tau-live (`clients/universal/driver/tau-live.c`) and
`clients/mac/Tests/live/fake-live.py` (stock pdfTeX, from scratch per edit). App side:
`clients/mac/Sources/TaudotPDF/LiveTex.swift`.

It is TeXpresso's protocol (`TaudotPDF/Txp.swift` ↔ `clients/render/driver.c`), except that the driver hands over
**finished PDFs** written by pdfTeX instead of drawing pages on request, with SyncTeX, the log and BibTeX's log beside
each.

## Starting

```
pdftex-live --serve [--engine PATH] [--fmt NAME] [--snapshot-ms N] [--bibtex PATH] [--max-runs N] [--synctex N]
                    [--state STATE] DIR MAIN.tex OUT
```

- `DIR`: the project folder (the engine's synced copy), **never written**. TeX runs on `OUT/work`, an APFS clone of
  it, where edits and latexmk's files go. `MAIN.tex` is relative to `DIR`.
- `STATE` (optional, the app gives the page cache's): when a compile settles and at exit, the driver keeps the `.aux`
  files, `.bbl`, `.blg` and `rule` (what the `.bbl` came from) there; at start they fill in missing ones, so a reopened
  project needs no BibTeX run or reference rerun. A `.bib` changed since (or no `rule`) reruns BibTeX.
- `OUT`: the app's scratch folder; every announced file is under it.
- Environment, set by the app: `TEXMFCNF`, `TEXSTORE_URL`, `TEXSTORE_IMAGE` (e.g. `2026.1@r79468`, from the project's
  TeX Live image), `TEXSTORE_ROOT`, `TEXFORMATS`, `SOURCE_DATE_EPOCH` / `FORCE_SOURCE_DATE`.
- As Overleaf's CLSI: `-interaction=batchmode`, latexmk's rerun and BibTeX rules. SyncTeX is plain (`-synctex=-1`,
  so no PDF waits on gzip) unless `--synctex` says otherwise; it never changes the PDF.
- The driver exits when stdin closes, killing every engine process.

## Commands: app → driver (stdin)

One JSON array per line, UTF-8. Paths are relative to `DIR`; offsets are UTF-8 bytes.

| command | meaning |
|---|---|
| `["open", path, text]` | A file's whole text, for each open buffer at start and after a restart, and for a file saved on disk that no editor holds. The driver rolls back from the first changed byte. |
| `["change", path, pos, del, ins]` | Replace `del` bytes at `pos` with `ins`. May come in bursts. |
| `["goal", page]` | The last page in view, 0-based; `-1` is the whole document. |
| `["finish"]` | Finish a PDF of the pages shipped so far, now (asked when a run has been quiet a while). |
| `["cursor", path, line, column]` or `["cursor", path, pos]` | tau-live only: the cursor rests here (`line` 1-based, `column` in bytes), sent 300 ms after it stops, once per place. Snapshots near it are kept, and the driver may typeset up to it quietly (`docs/universal.md`, the scout). |
| `["rescan"]` | Files the engine doesn't get as text changed on disk (`.bib`, `.bst`, images, project `.sty`): reread them and apply latexmk's rule. |

Each `open` and `change` is one *applied* command, counted in order. Events carry `applied`, the count read when the
run that made them started, so the app knows which edits a PDF contains.

## Events: driver → app (stdout)

One JSON object per line, field `ev`; times in microseconds. A file named in an event stays until **three newer**
files of its kind are announced (`para` files: four more previews); the app reads or copies it in its handler.

### `hello`

First line: `{"ev":"hello","protocol":1,"engine":"pdfTeX 3.141592653-2.6-1.40.29 (TeX Live 2026)","image":"2026.1@r79468"}`

### `fetch`

`{"ev":"fetch","file":"tex/latex/hyperref/hyperref.sty","files":41,"bytes":3145728,"waiting":true}`

At most every 100 ms while fetching TeX Live files. `files`/`bytes`: session totals; `waiting`: the run is blocked on
it (not a prefetch).

### `run`

`{"ev":"run","seq":7,"run":1,"applied":12,"why":"edit","from_page":3}`

- `seq`: compile number, one per batch of edits; latexmk's reruns bump `run`.
- `why`: `open`, `edit`, `aux` (rerun after a changed `.aux`/`.toc`/…), `bibtex` (the `.bbl` changed), `rescan`.
- `from_page`: pages before it predate the snapshot the run resumed from, so are unchanged.

### `pdf`

```json
{"ev":"pdf","seq":7,"run":1,"applied":12,"pages":5,"final":false,"from_page":3,
 "path":"OUT/pdf-7-1234.pdf","synctex":"OUT/pdf-7-1234.synctex","log":"OUT/pdf-7-1234.log",
 "edit_us":41000,"finish_us":19000}
```

- The run's pages so far as a complete PDF, finished by pdfTeX in a forked child (or at the run's end).
- `final`: the run ended (`\end{document}` or fatal error); `pages` is the document's. Otherwise pages from `pages` on
  are still the old ones.
- `synctex`: this PDF's SyncTeX (`.synctex` or `.synctex.gz`). `log`: the run's `.log` so far.
- `edit_us`: first edit of `applied` read to PDF written; `finish_us`: the finish alone.

**Display pages (tau-live, pdfTeX and LuaTeX).** Before the run's first finished output comes a `pdf` event with
`"display":true`: the last finished PDF with page `pages` − 1 replaced (an incremental update) by the first page the
run ships that differs (`from_page`, or later if TeX set earlier pages before reaching the edit). No `synctex` or
`log`. It draws exactly what the finished page will (`uni.py display`).

**XeTeX (tau-live).** `path` is the run's `.xdv`. With `tau-pdfmx` beside tau-live (and no `--no-pdfmx`), changed pages
are converted:

```json
{"ev":"pdf", ..., "path":"OUT/t/run-7-1234/main.xdv", "pdf_path":"OUT/t/run-7-1234/main-3-3.pdf",
 "pdf_first":3, "pdf_last":3, "pdfmx_us":5200}
```

- `pdf_path`: pages `pdf_first`..`pdf_last` (0-based, inclusive), byte for byte `xdvipdfmx -q -z 1 -s FIRST+1-LAST+1
  -o PDF_PATH XDV` in the project's directory. `pdf_last < pdf_first`: no page changed (no `pdf_path`), only maybe the count.
- Other pages below `pages` are unchanged. On a `final` event drop pages past `pages`; on an early one keep them.
- A page counts as changed when its XDV bytes, page 1 (its specials apply to all), the units or a font it may use
  changed; the result draws as a whole-document `xdvipdfmx` would (`uni.py xpdf`).
- `pdf_error` (the converter's exit status) instead: convert `path` yourself; the next event converts every page.
- `pdfmx_us`: request to answer. Later events wait behind a pending conversion, keeping order; `para` events don't.

### `done`

`{"ev":"done","seq":7,"runs":2,"pages":36,"code":0,"path":"OUT/final-9.pdf","log":"OUT/final-9.log","blg":"OUT/main-7.blg"}`

The compile settled: latexmk's rule has nothing left to do.

- `path`: the last run's `final` PDF, the settled document (page cache, comment anchors, issues). **Absent when the
  last run wrote no PDF** (fatal error before the first page): the app keeps what it shows and settles anyway.
- `log`: the last run's log, PDF or not; the issues list and status line read it.
- `blg`: BibTeX's log if it ran in this compile. Reopened with `--state`, BibTeX may not run: the app shows
  `STATE/MAIN.blg` until a `blg` comes.
- `code`: the last run's exit status (1 when TeX reported errors; 3 when the engine died, after an `error` with
  `what: "engine"`; the next command starts a new one).

### `bibtex`

`{"ev":"bibtex","seq":7,"code":0,"tool":"bibtex","blg":"OUT/main-7.blg","bbl_changed":true}`

One latexmk step. `tool`: what ran, comma-separated (`bibtex`, `biber`, `makeindex`, `makeglossaries`). `blg` only
when BibTeX or biber ran.

### `error`

`{"ev":"error","what":"offline","message":"can't fetch tex/latex/base/article.cls: no network"}`

`what`: `offline` (a TeX Live file is neither fetchable nor cached), `format` (no format for this image), `engine` (an
engine process died), `bibtex` (BibTeX, biber or makeindex passed `TAUDOT_TOOL_TIMEOUT_S`, 120 s, and was stopped),
`protocol` (an unreadable command). The driver keeps running if it can; the app shows it and keeps the last PDF.

### `para` (paragraph preview)

The edited paragraph alone, typeset (patch 0011) from a process parked at its start and drawn over its old lines, a
few ms after the `change`. Optional; `TAUDOT_PARA=0` turns it off.

```json
{"ev":"para","go":12,"applied":40,"file":"main.tex","state":"exact",
 "pdf":"OUT/pdf-31-5120.pdf","page":9,"path":"OUT/para-0.tdl","overlay":"OUT/para-0.pdf","origin":[0,0],
 "erase":[[133.1,534.2,478.5,543.8],…],"lines":8,"old_lines":8,
 "faults":[30,13],"engine_cpu_us":640,"ship_cpu_us":300,"break_cpu_us":110,
 "engine_us":660,"ship_us":310,"write_us":120,"wake_us":50,"draw_us":700,"us":2400}
```

- `applied`: the edits it shows; removed once a PDF with at least these is on screen. A stale preview is never sent.
- `state`: `exact` (same line count, heights, depths, widths and spacing, and nothing that moves other things: the
  preview is the page), `provisional` (shown; `why` is `lines`, `heights`, `spacing`, `indent`, `mark`, `vadjust`,
  `write`, `savepos` or `glue`; the exact pass reflows what follows), or `none` (no preview; `why`):

  | `why` | when |
  |---|---|
  | `insert` | footnotes, floats, `\marginpar` in the paragraph |
  | `parshape` | `\parshape` of more than one line or `\hangindent`: wrapfig, lettrine, section headings |
  | `shape` | (tau-live) the old lines start at different x (hanging indent, shaped paragraph) |
  | `display` | the edit is inside a display (`\[…\]`, `equation`, …) |
  | `segment` | the old lines on screen are another part of the paragraph (a display between) |
  | `split` | the old lines run across pages or columns |
  | `image` | an image or form in the paragraph |
  | `noanchor` | no run has placed this paragraph on the page on screen yet |
  | `far`, `end` | the paragraph doesn't end within 400 lines or 200 ms, or the document ends |
  | `operator X`, `font`, `glyph`, `nofont` | content the display list can't draw (paths, non-Type 1 fonts) |

- `pdf`, `page`: the newest announced PDF showing the page (0-based) whose run placed the paragraph.
- `overlay`: the lines as a one-page PDF of the page's size (fonts embedded whole, pdfTeX's content stream at the old
  lines' place), so its glyphs match the exact page's pixels. `origin`: where its top-left goes, in points (`[0,0]`
  when the place was known at the go).
- `path`: the same lines as a Taudot display list (TDL 2, `clients/render/dlist.md`: PAGE, FONT outlines, TEXT, RULE,
  END), page points from the top-left; TEXT bboxes are the glyphs' ink.
- `erase`: rectangles (page points, top-left origin, y down) to paper over first: old and new lines, padded to half
  the gap to the next line.
- Times: `engine_us` wake to lines broken (`break_cpu_us` in line_break), `ship_us` content stream, `write_us` file,
  `draw_us` display list and PDF, `wake_us` signal to wake, `us` `change` read to this line. `faults`: page faults
  (before, after the lines).

## When a PDF comes

1. After an edit, the runner resumes at the snapshot before the first changed byte.
2. It finishes a PDF as soon as it ships the **goal page** (or any page, if the goal is before the edit), and also on
   the edit's **first page** shipped when the goal is further on (one test paper, edit on page 1: goal page 2,
   103 → 77 ms; goal page 3, 208 → 69 ms).
3. While the run goes on, again at most every 150 ms, and once the page holding the edited paragraph ships if no PDF of
   this run has it yet.
4. At the run's end a `final` PDF; when the compile settles, `done`.
5. On tau-live a fresh engine (first compile or restart) also finishes once at the goal page (page 1 without a goal),
   before the rest is typeset (paper-b, pdfLaTeX: open → first PDF 1.02 → 0.44 s).
6. `finish` finishes one now from the pages shipped (after an edit, only once the runner is past the edited byte).
7. A new edit during a run cancels its pending finishes; announced PDFs stay valid.
8. **Except under steady typing**: when restarting would show the oldest edit not yet in a PDF more than 150 ms after
   it came (judged from recent runs), the driver holds new edits and lets the run in flight finish. They apply
   together when it announces a PDF or ends, or after max(300 ms, 3 × its time to a PDF). Typing slower than a run is
   never held; `applied` stays exact. A held key gives a new PDF every ~100 ms, longest gap 98–232 ms. There is no
   other coalescing delay.

## What the app does with it

- Draws the newest PDF's pages with Core Graphics into IOSurfaces, skipping pages before `from_page` and pages whose
  content stream is unchanged.
- Takes page sizes, glyph and word boxes (PDFKit), and links from the PDF; forward and inverse search from `synctex`.
- Shows `log`'s errors and warnings (the issues list) and `blg`'s BibTeX warnings.
- Keeps the last PDF on screen through `error`, a run with no pages, and a driver restart.
