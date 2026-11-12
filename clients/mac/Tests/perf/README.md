# Performance suite

Measures the release app, off the user's screen: its own latency probes, what reaches the screen
(ScreenCaptureKit), its windows and each process's cost (`top`). The typesetters' bench is `docs/bench.md`.

## Budgets

ms, p50 / p95. Launch, interaction and idle: release ba15418, a 36-page paper, mock engine; key → presented:
`run.sh` at 8705b9d; key → page: after the PDF-pipeline change that followed.

| what | budget | last measured |
|---|---|---|
| launch → project window | < 200 | 254 / 287 (~36 ms of it from a defaults domain bloated by test keys) |
| launch → editor text | < 300 | ≤ 422, already in the first captured frame; Native restyles it at ~540 |
| launch → first PDF page | < 300 with last run's pages on disk; < 1 s warm; < 3 s cold | 256 / 289; 2737 / 2937; 3535 / 4688 |
| launch → comments | < 500 | 464 / 483 |
| launch → Projects list | < 300 (last list from disk, then refreshed) | 877 / 920: nothing until the server answers |
| key → presented | p95 < 16 + one frame (≈ 25) | Native 20.1 / 26.0, Neovim 16.2 / 24.2; scroll and jump p95 29–48 |
| key → page shown | p50 ≈ 100 | Native 76 / 85, Neovim 79–88; held key (30/s): 115 / 154, a page every ~102 ms |
| Settings, file from the tree, sidebar tab | < 100 to first change | 64–71; 18–53; 15–78 |
| idle, window in background | ≈ 0 % CPU, < 1 wakeup/s per process | Native app 0.7/s, `pdftex-live` 0; Neovim 374/s (the user's config's 16 ms timer) |
| idle, window visible | < 0.5 % CPU, < 10 wakeups/s, no display link when nothing moves | not measured |
| typing, 8 chars/s | app < 10 % of a core, PDF side < 10 % | app 33–40 %, txp-render 14 % (re-typesets to the end after each key) |

## Files

| file | what |
|---|---|
| `run.sh` | The bench: type a paragraph at 8/s, hold a key at 30/s, scroll, jump; both editor modes and PDF paths; p50/p95/p99/max per stage. `--compare REV_A REV_B` alternates two builds and fails if B's key → presented/committed p95/p99 is over 15 % and 2 ms worse. |
| `keys.sh`, `latency.py` | One scripted run and its probes: stages, outside check, long main-thread turns. |
| `benchsum.py` | `run.sh`'s tables and the A/B comparison. |
| `probe.swift` | Launches or attaches to the app, records a window's changed frames, drives it with a script (keys, menus, scrolling). |
| `analyse.py`, `reactions.py` | Per-pane first drawn and first change; each action's reaction, p50/p95. |
| `launch.sh`, `launchsum.py` | N recorded launches; their p50/p95 table. |
| `steady.sh`, `topsum.py` | CPU, wakeups, RSS and energy of the process tree from `top`, in phases. |
| `quickbuild.sh` | Rebuild only `taudot-app` into the existing bundle. |

## The app's probes

`Sources/TaudotShared/Latency.swift`, on unless `TAUDOT_LATENCY=0`: each stage is a timestamp in a 64 K-entry ring
and an os_signpost event (`app.taudot`, `latency`). `kill -USR1 <pid>` writes the ring as TSV to
`$TAUDOT_LATENCY_OUT` (default `$TMPDIR/taudot-latency-<pid>.tsv`). Times are CACurrentMediaTime, the clock of
NSEvent, CGEvent and ScreenCaptureKit. Cost: 0.27 µs a record, ≈ 0.05 % of a core while typing.

| probe | marks |
|---|---|
| keyDown | `NativeTextView.keyDown` / `EditorView.keyDown` (Neovim), at the event's timestamp |
| handed | the key handler returned |
| model | text storage edited (Native) / Neovim's `flush` applied to the grid |
| committed | Native: end of the run-loop turn (after display and Core Animation commit); Neovim: Metal frame encoded |
| presented | Neovim: the drawable's `presentedTime`. Native: an estimate, the first 120 Hz refresh after the commit |
| typesetSent, typesetRun, pdfReady, pageShown | the edit reached the typesetter / the driver's `run` / its `pdf` or `pages` event covering it / a page in view swapped in |
| scrollFrame, zoomFrame | PDF pane (and Neovim view) scroll or zoom step, main-thread time to the end of the turn |
| longTurn, turnStart | main run-loop turns over 12 ms |
| section | `Latency.shared.section("name") { … }`, when over 1 ms |
| launch | every `timeline(...)` milestone |

## Running

Build first with `clients/mac/bundle.sh`. `TAUDOT_PERF_DOC` is a project folder whose `main.tex` has 400+ lines with
running text at line 177; every run uses a copy, served by the mock engine (or CE with its own `--home`), never the
original or `~/.taudot/`. Sockets go under `/tmp` (Unix sockets are limited to 104 bytes).

```sh
T=clients/mac/Tests/perf
$T/run.sh                                   # all modes, PDF paths and scripts, 3 runs each
$T/run.sh --compare REV_A REV_B -s type

S=$(mktemp -d); cp -R "$TAUDOT_PERF_DOC" $S/paper-a; echo '{"project": "perf-copy"}' > $S/paper-a/.taudot.json
deno run -A clients/mock-engine/main.ts --folder $S/paper-a --socket /tmp/txs-perf.sock &
$T/launch.sh $S/L $S/paper-a /tmp/txs-perf.sock 8 9 TAUDOT_EDITOR_MODE=native   # add XDG_CACHE_HOME=<empty> for cold
uv run $T/launchsum.py native=$S/L
PROBE_SCRIPT=script PHASES="idle:2:20 typing:25:45" $T/steady.sh $S/i $S/paper-a /tmp/txs-perf.sock 92 <engine pid>
uv run $T/reactions.py $S/i/drive
```

`run.sh` runs a copy of the bundle as `app.taudot.bench`, seeded with the user's global `taudot.*` settings, so bench
runs add no per-folder keys to the user's defaults. `PERF_APP=<taudot-app>` points the scripts at another build.

## Off the user's screen

- `TAUDOT_OFFSCREEN=1` by default (no Dock icon, never activated, windows off every display); `probe` exits 3 if a
  window reaches a display. With `TAUDOT_MEASURE=1` the window is also ordered in off-screen and made key, so it
  draws and presents as for the user; without it nothing can be timed.
- Keys go to the PID (`CGEventPostToPid`), menus through Accessibility; never the HID stream or pointer.
- On-screen runs are opt-in (`PERF_ONSCREEN=1`, `FOREGROUND=1` in front). Scripts stop what they start, also on Ctrl-C.

## Caveats

- The capture of an off-screen or occluded window lags the app by tens to hundreds of ms (outside − presented: p50
  13–55, p95 170–220 off-screen), so outside keystroke → glyph is not the app's latency; use `presented`. A true
  outside number needs an unoccluded on-screen run.
- The capture starts ~140 ms after the window appears; what is drawn by then shows as "≤".
- `top`'s phase means are good to ~10 %.
- Posted trackpad scrolls don't reach the views (keyboard scrolling does); window menu items don't act off-screen
  (`press Files` through Accessibility instead).
- Outside `run.sh` the app reads the user's defaults domain (`app.taudot.Taudot`), whose size changes launch times.
  Note its key count with each series: `defaults read app.taudot.Taudot | grep -cE '^    "?[A-Za-z]'`.
