# Performance: budgets and numbers

The goal (user, 2026-11-03): everything loads basically instantly, at low CPU. The suite is
`clients/mac/Tests/perf/` (README there): it measures the release app from outside, by what reaches the screen
(ScreenCaptureKit), the windows (CGWindowList), `top`, and the app's own `TAUDOT_TIMELINE` milestones. Every run is
off the user's screen (`TAUDOT_OFFSCREEN`); see the README for the rule and its limits.

## Budgets

| What | Budget |
|---|---|
| launch → project window on screen | < 200 ms |
| launch → editor text drawn | < 300 ms (text from disk; the engine connection catches up) |
| launch → first PDF page | < 300 ms when a previous run's pages are on disk; < 1 s warm TeXpresso; < 3 s cold |
| launch → comments shown | < 500 ms |
| launch → Projects list shown | < 300 ms (proposed: the last list from disk, then refreshed) |
| keystroke → glyph | p95 < 16 ms + one frame (≈ 25 ms measured from outside) |
| keystroke → PDF | p50 ≈ 100 ms |
| Settings, ⌘J, file from the tree, tab switch | < 100 ms to first visible change |
| idle, window in the background | ≈ 0 % CPU and < 1 wakeup/s per process |
| idle, window visible | < 0.5 % CPU and < 10 wakeups/s per process; no display link running when nothing moves |
| typing (8 chars/s) | app < 10 % of a core, PDF side < 10 % |

## Keystroke latency, in-app probes (2026-11-06, agent/speed)

**How measured.** The app's own probes (`Sources/TaudotShared/Latency.swift`, always on; Tests/perf/README.md lists
where each sits) on the release app, run by `clients/mac/Tests/perf/run.sh`: the PaperA paper (36 pp.) copied per run,
the mock engine, the app off every screen with `TAUDOT_MEASURE` (window ordered in off-screen and key, so it draws
and presents as for the user), keys posted to its PID by probe.swift, under its own defaults domain
(`app.taudot.bench`, the user's global settings: Native or Neovim, Vim keys). Scripts: **type** a paragraph at
8 chars/s, **hold** a key (30/s), **scroll** (⌃D/⌃U), **jump** (G, gg, 424G…). The machine was shared with other
agents' builds and tests (load average 6–11): run.sh `--compare` runs two builds alternately so load hits both alike.

- **presented**: Neovim mode, the Metal drawable's `presentedTime` (measured). Native mode, an **estimate**: the
  target time of the first display refresh (120 Hz) after the run-loop turn's Core Animation commit. The commit →
  presented step is then 4 ms (to the tick) + 8.3 ms; its true value needs an unoccluded on-screen capture (below).
- **Outside check**: the capture of an off-screen or occluded window lags the app by tens to hundreds of ms
  (outside − presented: p50 13–55, p95 170–220 ms off-screen; p50 30–50 ms on screen behind other windows), so
  **the 2026-11-04 "keystroke → glyph p95 149 ms" was mostly the capture**, not the app: in-app, the same keys
  reached the screen by p95 25–30 ms. An honest outside number needs the window unoccluded on a display: one short
  opt-in run in front (`TAUDOT_ONTOP`) or the Mac mini. Not done on the user's screen.
- Probe cost: 0.27 µs per record, +0.19 µs per main run-loop turn (release); typing records ~10 a key: ≈ 0.05 % of a
  core.

**The editor's tail, before → after** (native, live pdfTeX, type; `run.sh --compare cce11e2 8a75a0a`, 3 runs each,
alternating; ms p50 / p95 / p99 / max):

| stage | before (cce11e2) | after (8a75a0a) |
|---|---|---|
| key → committed | 7.7 / 17.7 / 28.8 / 84.9 | 7.0 / 10.6 / 18.4 / 25.7 |
| key → presented | 20.7 / 29.1 / 49.1 / 122.5 | 20.7 / 25.4 / 32.3 / 34.0 |
| key → typesetter (5e88020, run.sh) | 55 / 61 / 535 (non-edit keys) | 9.1 / 16.4 / 25.1 / 36.7 |
| key → PDF ready (live) | 159 / 169 | 116 / 127 / 139 |

Causes found with the probes and `sample`, and fixed:
1. **The PDF's cursor dot ran inside every keystroke** (`taudot_app_caret` → `TaudotPDFPane.placeCaret`: SyncTeX rows,
   the page's words, the whole source split into lines; ~3 ms a key on this paper, more under load). Now sent after
   the frame's commit (a 0 s timer; coalesced). (8a75a0a)
2. **The Settings prewarm** (a 125–141 ms main-thread build at ~5 s) waited only for HID idle, so it landed in the
   middle of typing whenever keys didn't come from the HID stream; it now also waits for 2 s without a key the app
   received. (cce11e2)
3. **Every edit waited 50 ms before it went to the engine** (`NativeDoc.sendDelay`), and the PDF gets our edits
   from the engine: key → typesetter 55 → 9 ms p50. The engine already batches for Overleaf (2 s / 0.5 s). (5e88020;
   Neovim mode's `send_delay = 50` in clients/nvim is a Request.)
4. **Native idle**: the 0.4 s status poll → pushed on change: 0.7 wakeups/s at rest (was 2.5–4.3). (a0222b9)

**What is left in the native tail** (p95 25–30, p99 32–38 ms presented while typing; ~4.3 ms a key in the key
handler, ~60 % of it TextKit 2: `NSTextContentStorage` updates the ranges of every paragraph after the edit, then
layout invalidation): keys that arrive just after a page swap wait behind its turn (PDF event ~1 ms, the page's
CA commit, freeing the old PDF on the main thread); jumps (`177G`) commit in 25–30 ms (layout of the target). Neovim
mode, drawn with Metal: type p50 14.7 / p95 20.5 / p99 26.1, hold p99 30.

**Live pdfTeX starves under a held key**: at 30 keys/s no PDF is finished for 2–4 s (each edit cancels the pending
finish, docs/live-protocol.md rule 6). Typing at 8/s: key → PDF ready p50 116 ms.

### Bench (run.sh --write)

<!-- bench:begin -->
**run.sh at 8705b9d** (+ docs only), load average { 2.49 2.51 2.97 }. ms, p50 / p95 / p99 / max, pooled over the runs. In-app stages from the app's probes (Latency.swift); outside from the off-screen window capture.

| mode · PDF · script | runs | keys | key → committed | key → presented | key → typesetter | key → PDF ready | key → page shown | outside: key → glyph | outside − presented | turns > 12 ms (n, max) |
|---|---|---|---|---|---|---|---|---|---|---|
| native · live · hold | 2 | 244 | 10.9 / 15.5 / 19.3 / 22.1 | 20.7 / 29.1 / 31.6 / 32.7 | 11.4 / 16.0 / 18.8 / 20.2 | 2055.4 / 3859.9 / 4035.2 / 4070.7 | 2059.4 / 3863.9 / 4039.2 / 4074.6 | 50.7 / 112.8 / 180.2 / 214.6 | 29.5 / 94.2 / 163.5 / 196.8 | 6, 28 |
| native · live · jump | 2 | 36 | 8.0 / 27.5 / 38.0 / 38.0 | 22.0 / 40.0 / 46.4 / 46.4 | – | – | – | – | – | 11, 132 |
| native · live · scroll | 2 | 36 | 8.8 / 26.0 / 32.0 / 32.0 | 24.2 / 38.3 / 48.5 / 48.5 | – | – | – | – | – | 8, 150 |
| native · live · type | 2 | 224 | 6.9 / 11.5 / 17.9 / 29.5 | 20.1 / 26.0 / 32.0 / 37.9 | 8.0 / 11.3 / 13.7 / 18.6 | 108.4 / 115.0 / 119.5 / 132.1 | 113.6 / 246.0 / 248.3 / 256.5 | 70.4 / 224.4 / 725.8 / 989.7 | 50.3 / 203.9 / 702.6 / 969.3 | 8, 150 |
| native · texpresso · hold | 2 | 244 | 13.3 / 18.1 / 22.8 / 29.5 | 26.7 / 32.2 / 33.0 / 45.7 | 14.5 / 19.4 / 23.5 / 42.1 | 49.7 / 617.4 / 774.0 / 1287.9 | 63.6 / 724.8 / 1376.5 / 1633.5 | 66.1 / 695.2 / 914.8 / 982.1 | 38.8 / 670.0 / 893.9 / 952.3 | 16, 65 |
| native · texpresso · jump | 2 | 36 | 5.5 / 19.6 / 28.9 / 28.9 | 20.9 / 29.4 / 45.1 / 45.1 | – | – | – | – | – | 13, 131 |
| native · texpresso · scroll | 2 | 36 | 8.1 / 31.0 / 72.2 / 72.2 | 21.9 / 42.6 / 84.9 / 84.9 | – | – | – | – | – | 16, 146 |
| native · texpresso · type | 2 | 224 | 7.2 / 10.0 / 17.0 / 21.7 | 21.1 / 26.0 / 32.5 / 33.4 | 8.3 / 11.3 / 17.8 / 20.3 | 30.8 / 248.2 / 879.2 / 1384.4 | 42.1 / 265.0 / 906.5 / 1411.8 | 69.4 / 229.8 / 749.1 / 1007.9 | 50.1 / 200.6 / 725.7 / 992.4 | 18, 153 |
| neovim · live · hold | 2 | 238 | 12.8 / 19.1 / 21.8 / 42.3 | 20.6 / 26.8 / 29.5 / 49.9 | 26.5 / 33.5 / 66.6 / 72.6 | 2055.2 / 3891.0 / 4074.9 / 4094.5 | 2059.7 / 3895.2 / 4079.4 / 4098.8 | 18.4 / 901.4 / 979.4 / 999.8 | 0.4 / 878.0 / 954.7 / 975.8 | 4, 27 |
| neovim · live · jump | 2 | 14 | 21.2 / 40.3 / 47.8 / 47.8 | 25.6 / 47.9 / 55.2 / 55.2 | – | – | – | – | – | 11, 149 |
| neovim · live · scroll | 2 | 32 | 20.3 / 25.3 / 39.0 / 39.0 | 27.7 / 32.7 / 46.4 / 46.4 | – | – | – | – | – | 7, 142 |
| neovim · live · type | 2 | 218 | 8.6 / 16.4 / 22.7 / 27.2 | 16.2 / 24.2 / 30.0 / 34.9 | 54.9 / 62.7 / 65.4 / 69.0 | 159.5 / 174.0 / 179.3 / 210.2 | 166.4 / 297.6 / 308.2 / 421.4 | 27.7 / 531.3 / 862.4 / 921.0 | 7.5 / 511.3 / 848.1 / 903.0 | 6, 146 |
| neovim · texpresso · hold | 2 | 238 | 13.3 / 18.2 / 41.5 / 53.6 | 20.7 / 24.8 / 48.9 / 60.7 | 25.0 / 32.7 / 93.2 / 93.4 | 50.5 / 615.9 / 787.2 / 871.3 | 62.9 / 693.2 / 1290.0 / 1439.2 | 503.6 / 970.4 / 1123.7 / 1194.5 | 480.7 / 951.7 / 1105.4 / 1172.1 | 16, 75 |
| neovim · texpresso · jump | 2 | 14 | 14.8 / 27.9 / 43.2 / 43.2 | 21.9 / 35.0 / 50.1 / 50.1 | – | – | – | – | – | 13, 152 |
| neovim · texpresso · scroll | 2 | 32 | 20.9 / 41.6 / 45.1 / 45.1 | 28.2 / 47.7 / 52.2 / 52.2 | – | – | – | – | – | 17, 156 |
| neovim · texpresso · type | 2 | 218 | 7.2 / 15.0 / 17.0 / 17.6 | 14.9 / 22.8 / 24.7 / 25.3 | 55.0 / 61.5 / 65.8 / 68.9 | 76.7 / 247.9 / 730.9 / 774.4 | 88.4 / 258.4 / 898.2 / 1275.2 | 481.2 / 989.9 / 1707.4 / 1962.5 | 468.8 / 977.1 / 1690.3 / 1948.6 | 16, 152 |
<!-- bench:end -->

### The PDF pipeline (2026-11-07, agent/pdfpipe)

Item 1 below, done; details in the pdfpipe agent's notes (not public). In the app (PaperA, live pdfTeX, release,
main vs pdfpipe alternating, ms p50 / p95):

| | before | after |
|---|---|---|
| native, typing: key → page shown | 116 / 246 | 76 / 85 |
| native, held key (30/s): key → page shown | 2077 / 3881 | 115 / 154 |
| held key: a page every | none for 2–4 s | ~102 ms, longest gap 118 |
| Neovim, typing: key → page shown | 110 / 242 | 79–88 / 88–216 (3 runs) |
| cursor dot while typing (debug, per key) | 39 / 94 | 0.08 / 0.16 |
| `pdftex-live` at rest | 20.9 wakeups/s | 0 |
| PDF scroll / zoom step, main thread (off-screen, debug) | – | 0.26 / 0.49, 0.09 / 0.17 |

How: the driver holds edits while the run in flight is the quicker way to a PDF (live protocol rule 7), finishes
once the edited page ships instead of waiting for the last page in view (rule 2), and sleeps at rest. The pane
typesets the editor's own buffer (both editors), aligns the cursor's line once per PDF, and frees old PDFs off the
main thread. What's left on PaperA typing: TeX typesetting to the end of the edited page (~55 ms) and the finish
(~10 ms). The scroll and zoom numbers say page drawing costs the main thread under 1 ms a step: Metal pages (3
below) has no measured case yet.

### Next big step, ranked by what the numbers show

1. **The PDF pipeline, not its drawing.** Key → page shown p50 ~120 ms, p95 ~255 ms, and seconds under a held key;
   pdfReady → pageShown is only ~5 ms. Finish a PDF at least every ~150 ms during sustained edits (protocol rule 6
   vs 3), feed the typesetter local edits directly instead of through the engine round trip, and take PDF decoding,
   glyph reading and freeing off the main thread so page swaps stop delaying keys.
2. **Metal text for the native editor** (or its text on the Neovim view's renderer). Native costs ~4.3 ms a key in
   TextKit 2 and its commit → glass is an extra frame; Neovim mode with the Metal grid already presents p50 ~15 ms vs
   native ~21. TextKit's per-edit cost grows with the paragraphs after the caret.
3. **Metal pages** last: no measured latency points at page drawing yet (swaps take ~5 ms after the PDF is ready).
   Measure PDF scroll and zoom frame times first (probe `scrollFrame`/`zoomFrame` exist; the pane doesn't emit them
   yet).

## Latest numbers (2026-11-04, Taudot, main ba15418)

**Conditions:** main at ba15418 (after the rename), release build, plus the measurement-only off-screen patch (main's
`TAUDOT_OFFSCREEN` uses `.prohibited`, whose windows never order in, so nothing can be captured; a request is open). The user's settings (Native editor, Vim keys, comments sidebar shown) as they are in the
user's defaults domain now, i.e. with the ~950 test keys described under "Still over budget" (1). Load average 3–6.
p50 / p95 in ms since the process started. ✅ within budget, ❌ over, ≤ = already drawn in the first captured frame
(the capture starts ~140 ms after the window).

### Launch

| run | n | window | editor text | PDF page | full typeset | comments / sidebar |
|---|---|---|---|---|---|---|
| paper-a (36 pp.), Native, last PDF on disk | 8 | 254 / 287 ❌ | ≤ 422 / 439, restyled 541 / 627 | 256 / 289 ✅ | 1958 / 2064 | 464 / 483 ✅ |
| paper-a, Native, no pages, warm TeXpresso | 5 | 262 / 269 ❌ | ≤ 428 / 465, restyled 533 / 571 | 2737 / 2937 ❌ | 1857 / 1900 | 460 / 468 ✅ |
| paper-a, Native, cold (no pages, no format cache) | 5 | 256 / 270 ❌ | ≤ 408 / 452, restyled 1231 / 1269 | 3535 / 4688 ❌ | 2600 / 2711 | 451 / 477 ✅ |
| paper-a, Neovim, last PDF on disk | 8 | 264 / 282 ❌ | ≤ 408 / 477 | 266 / 284 ✅ | 1938 / 2031 | 454 / 477 ✅ |
| paper-a, Neovim, no pages | 5 | 267 / 275 ❌ | ≤ 429 / 431 | 2734 / 2802 ❌ | 1842 / 1871 | 463 / 486 ✅ |
| paper-a, Neovim, cold | 5 | 262 / 268 ❌ | ≤ 407 / 424 | 3451 / 3633 ❌ | 2620 / 2696 | 461 / 478 ✅ |
| Demo Paper (replica), Native, warm | 6 | 205 / 215 ❌ | ≤ 342 / 368, restyled 583 / 585 | 207 / 218 ✅ | 1598 / 1712 | ≤ 342 / 347 ✅ |
| Demo Paper (replica), Neovim, warm | 6 | 219 / 230 ❌ | ≤ 365 / 413 | 221 / 232 ✅ | 1670 / 1693 | ≤ 365 / 413 ✅ |
| Projects window (CE, 49 projects) | 6 | 160 / 182 ✅ | – | – | – | list 877 / 920 ❌ |

**Window: the +50 ms since 2026-11-03 is the defaults domain, not code.** Bisected (no PDF pane, 5 runs per point):
2327d8d 196 ms, 69d3234 206, 64c0d92 200, **6b483d8 (the app rename, new bundle ID) 245**, ba15418 255. The same
ba15418 binary under a scratch bundle ID with a 6-key domain presents in 201 ms; with the user's 17 global settings
added, 218 ms; with the user's real domain (957 keys, 194 KB), 247–254 ms.

Editor text: the disk text is in the first captured frame (≤ ~420 ms; no in-app "text drawn" point yet). In Native mode
it is then **restyled** when the engine's doc arrives (just after "engine online", 500 ms): other shades and a tighter
line height, so the text visibly shifts once.

### Interaction (off-screen; Native reactions now reach the capture within a frame or two)

| What | Native | Neovim |
|---|---|---|
| keystroke → glyph | p50 21, p95 **149** ❌ (n 160) | not presented off-screen |
| keystroke → first PDF-pane change | p50 51, p95 225 (may be the cursor line band, not a re-typeset) | p50 18, p95 153 (same caveat) |
| Settings… → frame first changes / window ordered in | 64–71 / 87–106 ✅ | – |
| file from the tree: select → row; Return → editor | 18–26 / 38–53 ✅ | 18–30 / (editor not presented) |
| sidebar Files → Comments, Comments → Files | 78 / 15–20 ✅ | 78 / 15 ✅ |
| ⌘J Claude | not measured: neither the menu item nor ⌘J posted to the PID acts on a never-activated app | same |

### Steady state (CPU % of a core mean / p95, wakeups = context switches/s mean, RSS MB)

| Process | Native, idle (off-screen) | Native, typing 8 chars/s | Neovim, idle | Neovim, typing |
|---|---|---|---|---|
| app | 0.0, 4.3/s ❌, 171 | **40 / 55** ❌, 1660/s, 158 | 0.0, 0.8/s ✅, 142 | **33 / 46** ❌, 1690/s, 165 |
| nvim | – | – | 0.5, **374/s** ❌, 33 | 4.7, 1020/s, 73 |
| txp-render | 0.0, 0/s ✅, 61 | **14 / 17** ❌, **5060/s**, 237 | 0.0, 0/s ✅, 62 | 14 / 17 ❌, 4910/s, 249 |
| texpresso-xetex | 0.0, 0/s ✅, 172 | 0.0 | 0.0, 0/s ✅, 172 | 0.0 |
| engine (mock) | 0.0, 0/s ✅, 22 | 0.5, 38/s | 0.0, 0/s ✅, 23 | 0.5, 38/s |

Idle is off-screen. The measurement build makes the window key (so keys posted to the PID land), which keeps the new
Vim caret blinking; in real background use (not key) the blink stops, so Native's background figure is ≈ 2.5/s.

## Still over budget, with causes

1. **Test runs fill the user's defaults, and that costs ~36 ms of every launch** (window 201 → 247 ms), plus ~17 ms
   from the user's own global settings (not yet attributed). `ProjectWindow` sets `setFrameAutosaveName` and
   `split.autosaveName` per folder, and the sidebar tab, panes and collapsed-folder keys are per folder, all also in
   background runs: every test on a temp folder adds keys (957 now, 194 KB). Migration also copied the unbundled
   `texsync-app` domain (903 keys from tests). And `NSWindow Frame taudot.home` is saved at x = 3496, off the
   user's 1496-pt display (HomeHost's `showOffscreen` with the autosave on): the user's Projects window may open
   off-screen. (shell, home)
2. **Typing costs 33–40 % of a core in the app and 14 % in txp-render** (5000 wakeups/s). txp-render re-typesets
   to the end of the document after every keystroke (`want_step`: "keep typesetting to the end"), in ≤ 5 ms steps
   with a round trip to the xetex fork between them. (pdf, editor)
3. **First PDF page with no pages on disk: 2.7 s** (1.86 s on 2026-11-03), ~880 ms after the full typeset
   ("page in view in 879 ms"); budget 1 s warm. Cold 3.5 s (budget 3 s). Show pages as they arrive; find what the
   new 880 ms after the typeset is (dark/sepia pages, 2a3f783, is a candidate). (pdf)
4. **Keystroke → glyph p95 149 ms** in Native mode (p50 21): long tail, needs the in-app keyDown → presented points.
   (editor)
5. **Neovim mode wakes ~374×/s at rest** (mostly the user's config's 16 ms timer); **Native's app 2.5/s in the
   background**: `NativeEditor.startStatus` polls every 0.4 s forever; push the status on change instead. (editor)
6. **Projects list 877 ms** (744 ms on 2026-11-03): nothing until the server answers; show the last list from disk.
   (home)
7. **Native editor restyles its first paint** when the engine's doc arrives (~500 ms): paint the disk text in the
   final style. (editor)

Fixed since step 1, measured: the last PDF from disk at launch (6.5 s → 256 ms), Settings (590 → ~70 ms), no
SIGPIPE on a bare PATH, parallel startup. File from the tree and tab switch are within budget.

Measurement gaps: editor text below ~400 ms, keystroke → PDF (vs the cursor band), ⌘J, Neovim keystroke → glyph,
visible idle: they need the in-app timeline points (Request) or one opt-in on-screen run.
