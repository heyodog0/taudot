# Universal live typesetting: unmodified TeX engines, live

Status: prototype (2026-11-07), steps 1–4 of `docs/agents/universal.md` done on pdfTeX, XeTeX and LuaTeX; step 5
(the paragraph pass) works on all three and is exact where it gives an overlay (69/71), but isn't yet at ≤ 2 ms.
Code: `clients/universal/`. Log: `docs/agents/universal.log.md`.

The claim being tested: live, exact, fast typesetting needs no engine patches. One layer below the engine (an
interposer over the C library) and one above it (a few TeX tokens) give what our patched pdfTeX gets from its hooks.

## Pieces

| | What | Where |
|---|---|---|
| `libtau.dylib` | the interposer (`DYLD_INSERT_LIBRARIES`) | `interpose/tau.c`, `interpose/zcache.c` |
| `tau-live` | the driver: spawns the engine under libtau, speaks `docs/live-protocol.md` on stdin/stdout | `driver/tau-live.c` |
| engines | **stock** pdfTeX, XeTeX, LuaHBTeX from TeX Live 2026's release source (tag `release`), no patches | `build-engines.sh` |
| tests | exactness and timing against stock runs and against patched pdfTeX | `tests/uni.py` |

Licence: MIT for everything in `clients/universal/` (`clients/universal/LICENSE`; libtau is meant to be embedded by other editors). The engines stay separate GPL processes, unmodified.

## Below the engine: libtau

- **Project files from memory.** Every file under the project (the driver's APFS clone of it) is read whole on first
  open and served from memory. `read()` returns **one line at a time**, so each refill of the engine's stdio buffer
  happens at a line start with the buffer empty: the **read log** (bytes read per file, +1 once the end was seen) is
  exact, and a fork there is a clean snapshot. Lookups (`stat`, `access`) of project paths are answered from memory;
  misses are logged as "seen empty", so creating the file later invalidates later snapshots.
- **Written files stay in memory** (copy-on-write across forks, so no process ever shares an output file) and shadow
  the disk for later reads. At exit they go to `TAU_OUT/<tag>-<seq>-<pid>/`. Big ones (the PDF) live in a 1 GiB VM
  reservation, so they grow without copying.
- **Other files** (fonts, images, TeX Live) get a fresh file description at the same offset in every forked child,
  so a runner never moves a parked snapshot's offsets.
- **Snapshots**: at a line read of a project text file, at most every 20 ms (`--snapshot-ms`), and at **every line
  from the start of the edited line to the edit** (typing is local; a paragraph is often one long line). The parent
  parks (kqueue: SIGUSR1 = resume, the driver's lifeline pipe closing = exit); the child runs on.
- **Rollback**: the driver picks the newest snapshot whose read log stops at or before the first changed byte of
  every changed file, SIGKILLs everything newer, writes the new text into the clone, writes `ctl-<pid>` and sends
  SIGUSR1. The snapshot forks a runner that reloads the changed files and carries on. Any snapshot can be resumed
  (no parent/child dependency), so thinning past 256 just kills every other one.
- **Fork inside `getc`.** The fork happens inside `read()`, under the stream's lock (`getc`/`fgets` hold it); the
  child's thread has a new id and could never release it. libtau tracks the `FILE` of each fd (`fopen`,
  `fopen$DARWIN_EXTSN`, `fdopen`, `freopen`), counts how deep the parent holds the lock before forking and gives the
  child a fresh recursive lock held as deeply. (`struct __sFILEX` starts with `up` then `fl_mutex` in Libc; stable
  for years, but it is the one private-layout dependency.)
- **No locale-sensitive calls in `open()`**: LuaTeX's `setlocale` opens files under libc's locale lock, and
  `snprintf` there deadlocked (macOS aborts on the recursive lock). Path handling is plain `memcpy`.
- **zcache**: stream compression reused across rollbacks, as patch `0007` does inside pdfTeX. The engines are built
  against TeX Live's own zlib **as a dylib** (same source, same bytes; `build-engines.sh` relinks them), so libtau can
  interpose `deflate`: a stream's input is held until `Z_FINISH`, keyed by SHA-256 (with the level and window), and
  the output comes from `OUT/zcache` or from zlib (then stored). zlib's output doesn't depend on how the input was
  split across `Z_NO_FLUSH` calls. Engines linked statically still work (the zlib imports are weak).
- **TeX Live on demand** (warm-up only): with `TAU_TLROOT`/`TAU_FETCH`, a lookup that misses under the tree runs the
  store client (`tools/texstore/client.py fetch`) once and retries. The patched engines do this in kpathsea; here
  it costs a process per file, so it is only for first runs and format builds.

## Above the engine: a few injected tokens

- **Ship hook** (`tau-live --hook`): the command line becomes
  `\def\taudotsig#1{SIG}\AddToHook{shipout/after}{\taudotsig{ship/\the\ReadonlyShipoutCounter}}\csname @@input\endcsname main.tex`
  where SIG is `\pdffilesize{/.taudot/#1}` (pdfTeX), `\filesize{...}` (XeTeX) or
  `\directlua{lfs.attributes("/.taudot/#1")}` (LuaTeX): an expandable file lookup that expands to nothing, uses no
  stream and writes nothing to the log. libtau sees the lookup of `/.taudot/ship/N` (a few calls per lookup; deduped
  by N). The job name is still `main` (the first file opened). **The PDF stays byte-identical** to a plain stock
  run; the `.log`'s first lines differ (the command line echo, and the LaTeX banner moves).
- **Finishing early**: at a ship (the first one past the edit, then at most every 150 ms, as patched `--serve`)
  the runner double-forks a finisher. Its next read of a project text file (once per open file, since a verbatim
  reader may swallow it) gets one line:
  `\output={\setbox0\box255 \deadcycles=0\relax}\csname @@end\endcsname`
  then end of file: the page in progress is thrown away and TeX's own `\end` closes the document normally (fonts,
  page tree, xref). Simply ending the input doesn't work: TeX stops with "no legal \end found", a fatal error, and
  pdfTeX then deletes the PDF. The finisher writes only the PDF and `_exit`s.

## The paragraph pass (step 5)

On every edit whose resume point (the chosen snapshot) lies in the edited file at or before the edit, the
snapshot forks a **pass** before the exact runner (`ctl-para-<pid>`). The pass's view of the file:

1. at the resume point (a line start), one inserted line: an `\output` that hands LaTeX's float penalties
   (< −10000) to LaTeX's own routine, ships the page so far through LaTeX's `\shipout` at a break inside the
   paragraph, and at the pass's own break takes the last `\prevgraf` lines off with `\lastbox` (keeping each
   line's glue) and ships just them through the primitive `\shipout`;
2. the new text up to the end of the edited paragraph (the next blank or structural line: `\begin`, `\section`,
   `\item`, `\[`, ...);
3. `\par\edef\taudotpg{\the\prevgraf}\penalty-10000 \taudotsig{stop/\taudotpg}`; XeTeX also ships one page
   holding a 17 KB `\special`, so its 16 KB DVI buffer reaches the file.

Other project files read as empty and an `alarm(2)` stops a runaway pass. At the stop signal libtau writes the
bytes the engine appended to its output since the pass began (`para-<seq>-<pid>.bin`: the lines' content stream,
or their XDV page) and `_exit`s. The driver emits `{"ev":"para","seq","applied","lines","us","path"}`; an empty
`path` or file means no overlay. Engine-neutral: the same tokens on all three engines.

Measured with `uni.py paragraph`: 20 random edits per engine × paper, each followed by a second key at the same
spot after the first compile, as in typing. The pass's lines are compared with the same lines of that compile's
final output, which step 2 checks against stock. The pass ships its lines at the page's own x (side margin, plus
the column's offset in two-column mode), so pdfTeX rounds horizontal positions the same way as on the real page.

**Coverage** (of all edits: an overlay; provisional, because the paragraph crosses a page or column; or none,
because the paragraph is in a box: a caption, a float, a minipage):

| | overlay | provisional | none |
|---|---|---|---|
| pdfTeX, paper-a | 15/20 | 2 | 3 |
| LuaTeX, paper-a | 15/20 | 2 | 3 |
| XeTeX, paper-a | 12/20 | 4 | 4 |
| pdfTeX, paper-b (two columns) | 12/20 | 6 | 2 |
| LuaTeX, paper-b | 9/20 | 9 | 2 |
| XeTeX, paper-b | 8/20 | 8 | 4 |

**Exactness of the overlays**, three checks:

1. *Lines* (glyph strings per line, each line's start x, baselines; no kerning tolerance in the strings): 69/71
   identical. The two misses (pdfTeX, one per paper) both resumed from a snapshot far before the edit
   (~120–190 ms passes); not yet understood.
2. *Bytes*: XeTeX: every run byte-equal (glyph ids and positions in integer sp), 20/20. pdfTeX/LuaTeX: all TJ
   operands byte-equal in 7/14 and 8/15 (paper-a) and 3/11 and 0/9 (paper-b); in the others pdfTeX's 1-unit correction
   kerns land elsewhere because the vertical origin differs (below).
3. *Pixels*, independent of the above: the pass's content stream is put on a copy of the exact page and both are
   drawn with Core Graphics at 288 dpi over the band of the paragraph's lines. Every pixel that differs counts:

| | cases with 0 px differing | worst case | position difference in those cases |
|---|---|---|---|
| pdfTeX, paper-a | 12/14 | 7601 px (4357 by > 64) | ≤ 0.001 pt |
| LuaTeX, paper-a | 13/15 | 7604 px | ≤ 0.001 pt |
| pdfTeX, paper-b | 9/11 | 7004 px | ≤ 0.001 pt |
| LuaTeX, paper-b | 4/9 | 6679 px | ≤ 0.008 pt |
| XeTeX | not drawn: byte-equal XDV (check 2) | | 0 |

Where pixels differ, the only difference in the content streams is in positions **0.001 pt** apart (pdfTeX; LuaTeX
up to 0.008). These are PDF numbers printed to three decimals relative to the page origin. The pass ships at the
page's x, but the lines' y on the real page depends on the page's vertical glue, which is set only when the page
is complete, so the vertical rounding (and with it where pdfTeX puts its 1-unit correction kerns) can differ. Core
Graphics snaps glyph origins to a subpixel grid, so 0.001 pt (0.004 px) can move a whole line's outlines by a
grid step: thousands of pixels, all in one line. Each case was looked at (`PIX_DUMP`): same glyphs, same line breaks,
one line's outlines shifted. A pane that draws the overlay at the page's own line positions from SyncTeX (not the
pass's) avoids this.

- "No overlay": the paragraph is in a box (a caption, a float: internal vertical mode has no page builder) or
  crosses a page or column (the pass counts its own ships in `\taudotn` and reports `pieces`; more than one means
  provisional). Two-column papers cross columns often (12 of 20 on paper-b).
- If anything but lines, glue and penalties follows the lines (a footnote's insert, a mark), `\lastbox` can't take
  them, so the page so far ships instead (checked with e-TeX's `\lastnodetype`); the reader takes the last lines.
- **Warm pass** (2026-11-07): every dense snapshot (at the edited line) keeps a pass child already forked, files
  reopened, parked in kqueue (`W` message); the driver writes `ctl-warm-<pid>` with the paragraph's new text from
  the resume point (no rereading the file) and signals it; the snapshot parks a new one when it exits. Typing keys
  (second key at a spot), paper-a/paper-b: all but 3 of 102 used a warm pass. Edit → lines written p50 **3.8 ms**
  (pdfTeX, XeTeX; was 4.6–6.2), LuaTeX 6.9–10.6 ms; with the hot-page pre-touch below, pdfTeX 2.9 ms. Of that, the pass starts 0.2–1.3 ms after the edit (LuaTeX
  3–4.5 ms) and TeX takes 2.6–3.6 ms (LuaTeX 3.9–6.1). Still not ≤ 2 ms of TeX time.
- **The wake, measured** (coordinator's three ideas, one at a time; pdfTeX, paper-a, 20 edits each, typing keys, p50;
  `tests/wake.awk` over the driver's log):

| | signal → wake | faults wake → lines | pass ready → lines | edit → lines written |
|---|---|---|---|---|
| baseline | 0.31–0.37 ms | 914–931 | 2.97–3.15 ms | 3.7–4.0 ms |
| (a) QoS user-interactive (class 33 confirmed) | 0.33 | 918 | 3.14 | 3.8 |
| (c) FIFO `read()` instead of SIGUSR1 + kqueue | 0.35 | 920 | 3.06 | 3.9 |
| (b) pre-touch every resident writable page (5550 pages, ~88 MB a child) | 0.19–0.31 | 70–71 | 1.88–2.14 | 2.6–2.9 |
| (b) pre-touch the pages the last pass copied (671 pages, ~10.5 MB) | 0.36 | 187 | 2.21 | 2.9 |
| all three | 0.16 | 70 | 1.98 | 2.7 |

  - **Copy-on-write faults were the cost**, not the wake: ~920 faults (≈ 1 µs each, ~1 ms) after the fork. Writing
    those pages while parked moves them before the key. Default now: the pages the previous pass copied (`mincore`'s
    `MINCORE_COPIED`, written to `OUT/hot` at each pass's stop), most of the gain for an eighth of the memory.
  - QoS: `pthread_set_qos_class_self_np` returns EPERM in a forked child that hasn't exec'd (checked in a bare
    test), so it is set once in the exec'd engine and inherited (`TAU_WARM_QOS=ui`); no measurable gain here.
  - The earlier 0.4–1.5 ms wakes didn't recur (0.3 ms in these runs); the machine was busier then.
- **Toward 2 ms of TeX time** (coordinator's list, 2026-11-07; each measured):
  - *Profile first* (Instruments Time Profiler, system-wide, 200 typing keys; samples kept by the pass's thread id
    from its `B` message, since pids are reused at this fork rate; `tests/prof.py`). It showed: (i) every pass hit
    "Extra \else": `\loop`'s unmatched `\ifnum` inside `\output` unbalanced TeX's skipping of the branches not
    taken, and error printing cost time; (ii) `\unvcopy255` copied the whole page; (iii) the hot-page list
    (`mincore` over all regions) took ~6 ms of CPU after every pass; (iv) a tail: 10% of passes took 100–176 ms.
  - Fixes: all the pass's macros (`\taudotout`, `\taudotgrab`, `\taudotpage`, `\taudotflush`, `\taudotx`) are
    defined once on the command line (checked: output still byte-identical, all 3 engines × 2 papers, `uni.py
    prelude`), so a pass's own text is two short lines and nothing big is tokenized at flush; the whole-page
    fallback uses `\unvbox` (no copy); the hot-page list is rewritten at most every 5 s.
  - The tail (iv) is page 1: every snapshot valid for an edit there is older than the first shipped page, so the
    pass loads pdfTeX's font map (`fm_read_info`, all of `pdftex.map`) when it ships. The exact runner pays the same.
    Not fixable from outside without changing the output's object order.
  - Phase markers (`TAU_PHASES=1`: `\taudotmark{N}` = a lookup of `/.taudot/t/N`, 3–4 µs each, measured in TeX with
    `\pdfelapsedtime`), pdfTeX, paper-b, typing keys, p50: reading the paragraph 0.58 ms, flush tokens 0.02, **`\par`
    (line breaking) 1.33**, page builder + `\output` + taking the lines 0.02, `\shipout` 0.15, writing 0.10;
    LuaTeX: 0.69 / 0.01 / **1.57** / 0.04 / 0.34 / 0.11. On paper-b, TeX's own line breaking of long paragraphs with
    microtype's font expansion is most of it, the same work the exact run does.
  - Tried, no gain: the paragraph in one `read()` instead of line by line (2.25–2.33 vs 2.33 ms); QoS and a FIFO
    wake (above). Not tried: replacing the primitive `\shipout` (now 0.15–0.34 ms) by `\showbox` into the log.

**TeX time per typing key now** (warm pass ready → lines written, a key every 120 ms, 100 keys, p50 / p90):

| | paper-a | paper-b (two columns, long paragraphs) |
|---|---|---|
| pdfTeX | **1.28** / 1.77 ms | 2.91 / 4.92 ms |
| XeTeX | **1.43** / 1.77 ms | 2.06 / 3.65 ms |
| LuaTeX | 2.02 / 2.53 ms | 8.14 / 9.70 ms |

Edit → lines written p50: 1.6, 1.8, 2.4 ms (paper-a), 3.3, 2.4, 9.3 ms (paper-b).

**LuaTeX on paper-b (8.14 ms) explained** (2026-11-07): the keys are bimodal, 2.5–3.2 ms and 7.4–8.6 ms. All slow keys
are one 29-line paragraph that crosses a column (`pieces` = 2: provisional, no overlay). Inside its `\par` the page
builder runs the pass's output routine, which ships the first column through LaTeX's `\shipout` (with its hooks);
`\par` measures 5.4 ms in the pass against 2.5 ms in a stock run for the same paragraph (timed with
`os.gettimeofday` around `\par`), the difference being that ship. Ruled out: copy-on-write (pre-touching
everything: faults 577 → 119, `\par` unchanged) and Lua's collector (stopped in the pass: unchanged). The table's
p50 just had more such keys (5 spots). Passes that give an overlay (one piece) on LuaTeX/paper-b: **2.7–2.9 ms**.
Possible later: a provisional pass could stop at the first break inside its paragraph instead of shipping it. The 2 ms target holds on paper-a for
pdfTeX and XeTeX; on paper-b, line breaking alone is 1.3–1.6 ms. The stretch (1 ms) would need less line-breaking
work than TeX does, so not without changing what is computed.
- The pane side (drawing these lines over the page) is not done: the reader here is a Python test
  (`tests/para.py`); a C reader into TDL is next.

## tau-live as a drop-in for the app's live driver (2026-11-07)

Same command line and protocol as `pdftex-live --serve` (`docs/live-protocol.md`):

    tau-live --serve --engine PATH [--bibtex PATH] [--biber PATH] [--makeindex PATH] [--max-runs N]
             [--state STATE] [--snapshot-ms N] DIR MAIN OUT

With `--engine`, tau-live runs `ENGINE [-no-pdf for XeTeX] -interaction=batchmode -synctex=-1 MAIN` with the hook
and the paragraph pass on; the older `DIR MAIN OUT -- ENGINE ARGS...` form stays for tests.

- **latexmk's rule** (written from `clients/pdftex/README.md`'s description, not from `serve.c`): after each run
  the files it wrote (except the document, logs, SyncTeX) go into the clone when they differ; BibTeX runs when the bib
  lines of the main `.aux` and the `.aux` files it `\@input`s changed, or a `.bib` changed (biber when there is a
  `.bcf`, with `--biber`); makeindex when the `.idx` changed (`--makeindex`). Then, if any changed file was read by
  the run (its read log), the engine resumes from the newest snapshot before the first changed byte (`run` event,
  same `seq`, `run` + 1, `why` `aux` or `bibtex`), up to `--max-runs` (5); else `done`. BibTeX beside the engine is
  used by default.
- Fixed on the way: a rerun may resume an old snapshot whose memory still has text from before later edits; every
  resume now reloads the source files from the clone (safe: what any kept snapshot read is unchanged).
- `--state`: missing `.aux/.bbl/.blg/.toc/.out` come from STATE at start and go back when a compile settles and at
  exit, with `STATE/rule` (the `.bib` files' hash): a reopened project settles in one run without BibTeX.
- `goal` (finish at once when that page ships), `finish` (SIGUSR2: a PDF of the pages so far at the runner's next
  line read), `rescan` (files changed in DIR that no editor holds: copied into the clone, BibTeX & co., a rerun if
  needed). Events: `hello` (with `image`), `fetch` (when libtau fetches a TeX Live file), `run`, `pdf` (with
  `synctex`, `log`, `finish_us`; SyncTeX of early PDFs too), `bibtex`, `done` (`runs`, `code` = the engine's exit
  status, `log`, `blg`), `para` (paragraph pass: `lines`, `pieces`, `path`; empty `path` means no overlay).
- Checked: from projects without `.aux`/`.bbl`, the settled output equals stock runs with BibTeX on all three engines,
  paper-a and paper-b (`uni.py rule`: open → bibtex → reruns → done); 64/64 random edits identical to stock with the
  rule (`uni.py edits`, the reference now gets the same rule); typing finals identical; `uni.py serve`: four runs
  and BibTeX on the first compile, `goal` + `finish`, `rescan` after a `.bib` change runs BibTeX, a second session
  with `--state` settles in one run.
- The paragraph pass now gives an overlay only when its own break shipped the lines (a page break on the way to a
  paragraph inside a box had counted as a piece), and is skipped when its snapshot is > 4 KB before the edit or
  before the first shipped page. Lines check: **55/55** overlays identical (3 engines × 2 papers).

## Readers into TDL (2026-11-07)

`tau-tdl` (`clients/universal/readers/`, C) turns a pass's output into a list the app's TDL drawer already draws
(`clients/render/dlist.md`):

- **XeTeX**: `tau-tdl xdv DOC.xdv PASS.bin OUT.tdl`. The pass's XDV page (the last complete bop..eop it appended,
  found with the interpreter's own instruction sizes) is appended to the last exact XDV (whose pages define the
  fonts) and run through TeXpresso's DVI interpreter on the renderer's runtime, recorded by the renderer's TDL
  device: `clients/render/{glyphs,dlist}.c` are compiled in whole, unmodified, with the few statics they expect;
  TeX Live files through kpathsea. Checked on a pass: the 7 lines as TEXT runs with the paragraph's glyphs. 73 ms
  the first time (every font the document defines is loaded); a resident process would pay it once.
- **pdfTeX, LuaTeX**: `tau-tdl pdf EXACT.pdf PAGE PASS.bin OUT.pdf OUT.tdl`. No PDF interpreter is needed (the
  runtime has none since nomupdf): OUT.pdf is an APFS clone of the last exact PDF plus an **incremental update** in
  which page PAGE draws only the pass's content stream (moved by `dy`: the offset of one of its lines that is
  unchanged on the exact page), with every page's fonts in its resources; OUT.tdl is one `FIGURE` op drawing that
  page, which the drawer renders with Core Graphics like any included PDF. `readers/pdfmini.c` reads classic xref
  tables, xref streams and object streams (pdfTeX's and LuaTeX's output).
- Checked by drawing the overlay page as the app would (Core Graphics, 288 dpi) against the exact page over the
  paragraph's band: **0 px differing in 27 of 28** placed overlays (pdfTeX paper-a 8/8, paper-b 7/7; LuaTeX paper-a 8/8,
  paper-b 4/5; the fifth: 2972 px, the ≤ 0.008 pt vertical rounding above). 6–11 ms, mostly walking every page for
  font resources (next: only the fonts the pass uses).
- Left to the app: hiding the old paragraph under the overlay (its rect from SyncTeX or the previous list), and
  placement when no line of the pass is on the exact page (`dy` null: the edit is in every line).

## Results (TeX Live 2026, M-series Mac, 2026-11-07)

Papers: paper-a (32 pages, one column, review-mode line numbers) and paper-b (the corpus's arXiv 2103.00020, 48 pages, two columns). "Stock" is TeX Live's
own static build; the live engines are the same source with zlib as a dylib (checked byte-identical to stock).

**Step 1: a run under libtau == a stock run.** Byte-identical PDF, `.aux`, `.out` and even `.log`, both papers. Time:
1615 vs 1661 ms (paper-a), 926 vs 923 ms (paper-b): no measurable overhead. The project directory is never written.

**Step 2: snapshots and rollback.** Random edits (insert/delete a word, change a letter) anywhere after
`\begin{document}`, each final PDF compared with a fresh stock run of the edited copy:

| paper | identical | edit → final PDF (whole rest of the document) | snapshots kept | footprint |
|---|---|---|---|---|
| paper-a | 20/20 (and 10/10 earlier) | p50 578 ms, p95 888 | 45 | 25 MiB max per snapshot |
| paper-b | 20/20 | p50 475 ms, p95 704 | 46 | 25 MiB max per snapshot |

(Footprint summed over snapshots is 487–524 MiB, but that counts copy-on-write pages each one shares; the real
cost is lower. To measure: free memory before/after.)

**Step 3: finishing by injection.** Every early PDF's pages equal the full run's pages (content streams and fonts
per page; an earlier version of this check compared fonts only, because pypdf's content stream object is falsy:
fixed, and all re-run): **32/32 paper-a, 48/48 paper-b** (pdfTeX), the same for LuaTeX. After random edits, the first exact PDF (the page past the edit), against
patched pdfTeX (`pdftex-live --serve`, same machine, same edits, goal page 0):

| | stock + libtau | patched pdfTeX | ratio |
|---|---|---|---|
| paper-a, random jumps | p50 53–57 ms, max 75 | p50 46 ms, max 72 | 1.2× |
| paper-b, random jumps | p50 61 ms, max 75 | p50 49 ms, max 61 | 1.24× |
| paper-a, typing (3 spots × 20 keys, 120 ms apart) | p50 50 ms, p95 103–109 | p50 49 ms, p95 64 | 1.0× / 1.7× |
| paper-b, typing | p50 40 ms, p95 49 | p50 40 ms, p95 50 | **1.0×** |

Typing (the common case) is at parity. All final PDFs after typing are identical to stock runs.

**Step 4: the same on XeTeX and LuaTeX**, with no change to libtau or the driver (XeTeX runs with `-no-pdf`: its
output is the XDV, compared page by page with `tests/xdv.py`; the PDF is xdvipdfmx's deterministic function of it).

| | step 1 | step 2 (random edits) | step 3 (early outputs) | edit → first exact page | typing, per key |
|---|---|---|---|---|---|
| XeTeX, paper-a | identical (xdv, aux, out, log) | 12/12 | 32/32 | p50 30 ms, max 49 | p50 13 ms, p95 31 |
| XeTeX, paper-b | identical | 12/12 | 51/51 | p50 30 ms, max 46 | p50 13 ms, p95 17 |
| LuaTeX, paper-a | identical* | 12/12* | 32/32 | p50 76 ms, max 115 | p50 72 ms, p95 125 |
| LuaTeX, paper-b | identical* | 12/12* | 51/51 | p50 130 ms, max 185 | p50 103 ms, p95 119 |

\* LuaTeX's `/ID` is an MD5 that includes the output file's **absolute path** (pdfTeX's doesn't), so it is
byte-identical only when the paths match: step 1 runs both in the same directory; live runs (in the driver's clone)
are compared with `/ID` masked. To match Overleaf byte for byte, a LuaLaTeX project must run at CLSI's path
(`/compile/...`), e.g. by making the clone's path the same; unverified.

XeTeX's exact page is an XDV page: the pane needs an XDV reader (TeXpresso's path) or xdvipdfmx per update.
LuaTeX's time is LuaTeX's own: a stock LuaLaTeX run of the paper-b paper takes 1.8 s against pdfTeX's 0.9 s, and its
finish (OpenType subsetting, PDF objects in Lua) is heavier. Snapshot footprint: XeTeX up to 158 MiB, LuaTeX 76 MiB,
pdfTeX 25 MiB (max single snapshot).

### Where the remaining time goes

- **Finishing** (`\end` + close): 15–35 ms of CPU, ~2–3k copy-on-write page faults; patched's
  `close_files_and_terminate` alone takes 12–21 ms. Mine also runs the rest of the output routine and the line, and
  `\end`'s page discard. Compression is not the cost (`\pdfcompresslevel=0` in the finisher saves ~1.5 ms).
- **paper-a's p95 while typing**: the typed paragraph ends page 24; page 25 holds two RGBA PNGs. pdfTeX writes every
  `\pdfximage` when it closes, so the page-24 finisher decodes both images (~60 ms) as well as the runner. zcache
  saves the deflate (300 → 64 ms per ship), not the PNG decode. Next: cache `inflate` the same way (keyed by the
  compressed input), or start finishers at the next text read after a ship, so the runner's work isn't repeated.
- **Random jumps**: resuming from up to 20 ms before the edit, then typesetting to the page end; same as patched.

## Open

- Step 5: ≤ 2 ms of TeX time (the warm pass is in; the ship and the wake are what's left), the two far-snapshot
  misses, a C reader into TDL, the pane overlay.
- The latexmk rule (reruns, BibTeX) is not in `tau-live` yet: one run per edit.
- `goal`/`finish` commands are accepted but not acted on; `--state` and `fetch` events are missing.
- Readers into TDL (PDF content streams, XDV) for the paragraph pass.
- A real memory measurement (free memory with N snapshots).
