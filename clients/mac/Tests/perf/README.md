# Performance suite

Measures the release app from outside, as the user sees it: what reaches the screen (ScreenCaptureKit), which
windows exist (CGWindowList), and what each process costs (`top`). Nothing in the app is changed for it.
Budgets and the latest numbers: `docs/perf.md`.

| File | What |
|---|---|
| `probe.swift` | Launches the app (or attaches to a PID), logs its windows, records one window frame by frame (downsampled, only changed frames), drives it with a script (keys, typing, menus, scrolling), dumps its split geometry (AX) and process tree. |
| `analyse.py` | Per pane (sidebar, editor, PDF): first drawn and "visually complete" times; for each scripted action, the first change in each pane. |
| `reactions.py` | Keystroke → glyph, keystroke → PDF, and every other action's reaction, p50/p95. |
| `launch.sh` | N launches on a folder, each recorded and analysed. |
| `launchsum.py` | p50/p95 table over launch runs. |
| `steady.sh` | CPU, wakeups (context switches/s), RSS, energy of the app's whole process tree (and the engine) with `top`; background or foreground, optionally driven by a probe script, split into phases. |
| `topsum.py` | The summary of `steady.sh`'s `top` output. |
| `run.sh` | **The bench**: fixed document (the PaperA copy), fixed scripts (type a paragraph, hold a key, scroll, jump), both editor modes, both PDF paths; p50/p95/p99/max per stage; `--write` into docs/perf.md; `--compare REV_A REV_B` builds both and runs them alternately, failing past a margin. |
| `keys.sh` | One scripted run: the app off-screen with `TAUDOT_MEASURE`, probe driving and recording it, then the app's probe ring dumped (SIGUSR1). |
| `latency.py` | One run's probes: key → handed → model → committed → presented, key → typesetter → PDF → page, the outside check (capture vs `presented`), long main-thread turns with what ran in them. |
| `benchsum.py` | `run.sh`'s tables: pooled per mode · PDF path · script; the A/B comparison. |
| `quickbuild.sh` | Rebuild only `taudot-app` (release) into the existing bundle, for quick iterations. |

## The app's own probes

`Sources/TaudotShared/Latency.swift`, always on (TAUDOT_LATENCY=0 turns them off): each stage of a keystroke and of
the PDF's way to the screen is a timestamp in an in-memory ring (64 K entries, no allocation) and an os_signpost
event (subsystem `app.taudot`, category `latency`: Instruments' Points of Interest / os_signpost track shows them).
`kill -USR1 <pid>` writes the ring as TSV to `$TAUDOT_LATENCY_OUT` (default `$TMPDIR/taudot-latency-<pid>.tsv`).
Times are host seconds (CACurrentMediaTime), the clock of NSEvent and CGEvent timestamps and of ScreenCaptureKit, so
probe.swift's capture lines up with them (its `clock.txt` holds its t0).

| probe | where |
|---|---|
| keyDown | `NativeTextView.keyDown`, `EditorView.keyDown` (Neovim), at the event's timestamp |
| handed | the key handler returned (NSTextView edited / `nvim_input` sent) |
| model | the text storage edited (native) / Neovim's `flush` applied to the grid |
| committed | native: the end of the run-loop turn (after AppKit's display and Core Animation's commit); Neovim: the Metal frame encoded |
| presented | native: the target time of the first display refresh after the commit; Neovim: the drawable's `presentedTime` |
| typesetSent / typesetRun / pdfReady / pageShown | the edit reached the typesetter (its command count) / the driver's `run` / its `pdf` or `pages` event covering that count / a page in view swapped in |
| longTurn, turnStart | main run-loop turns over 12 ms |
| section | `Latency.shared.section("name") { … }`, recorded when over 1 ms |
| launch | every `timeline(...)` milestone |

`TAUDOT_MEASURE=1` (with `TAUDOT_OFFSCREEN`): the app is `.accessory` and its project window is ordered in **off
every screen** and made key (inside the never-activated app), so frames are drawn, committed and presented as for
the user and keys posted to its PID land. `.prohibited` (plain `TAUDOT_OFFSCREEN`) never orders windows in: nothing
is drawn there, so nothing in-app or outside can be timed.

`run.sh` runs a copy of the bundle under the bundle ID `app.taudot.bench`, seeded with the user's global `taudot.*`
settings, so bench runs never add per-folder keys to the user's defaults.

## Running

Build first: `clients/mac/bundle.sh` (release). A test project is a **copy** (never the original project itself, never
`~/.taudot/`), served by the mock engine or a CE engine with its own `--home`. Socket paths must be short
(`/tmp/...`): Unix sockets are limited to 104 bytes.

```sh
S=$(mktemp -d); cp -R "$TAUDOT_PERF_DOC" $S/paper-a; echo '{"project": "perf-copy"}' > $S/paper-a/.taudot.json
deno run -A clients/mock-engine/main.ts --folder $S/paper-a --socket /tmp/txs-perf.sock &
T=clients/mac/Tests/perf
$T/launch.sh $S/L-native $S/paper-a /tmp/txs-perf.sock 8 9 TAUDOT_EDITOR_MODE=native
mkdir $S/xdg; $T/launch.sh $S/L-cold $S/paper-a /tmp/txs-perf.sock 1 12 XDG_CACHE_HOME=$S/xdg   # no TeXpresso format cache
uv run $T/launchsum.py native=$S/L-native
$T/launch.sh $S/P - /tmp/txs-perf-ce/engine.sock 6 6                                   # Projects window
$T/steady.sh $S/idle $S/paper-a /tmp/txs-perf.sock 60 <engine pid> TAUDOT_EDITOR_MODE=neovim      # idle
PROBE_SCRIPT=script PHASES="idle:2:20 typing:25:45" $T/steady.sh $S/i $S/paper-a /tmp/txs-perf.sock 92 <engine pid>
uv run $T/reactions.py $S/i/drive
```

## Off the user's screen

Tests must not disturb whoever is using the Mac while they run.
- Every run is **off-screen by default**: `TAUDOT_OFFSCREEN=1` (no Dock icon, never activated, windows placed off
  every display). `launch.sh` and `steady.sh` refuse an app binary without it.
- `probe` stops the app at once (exit 3) if any of its windows comes onto a display.
- ScreenCaptureKit records windows that are entirely off-screen (checked 2026-11-03), so the captures need no
  screen. Keys go to the app's PID (`CGEventPostToPid`), menus and buttons through Accessibility: never the HID
  stream, never the pointer.
- On-screen runs are opt-in, `PERF_ONSCREEN=1` (behind the user's windows; `FOREGROUND=1` in front): only when the
  thing measured needs the real screen, batched into one short run.
- Every script stops what it starts (the app's whole tree, Neovim, TeXpresso's forks), also on Ctrl-C.
- `PERF_APP=<taudot-app>` points the scripts at another build.

## Caveats

- Times come from ScreenCaptureKit timestamps: they include up to one capture frame (~8–16 ms) of latency.
- The capture starts ~140 ms after the window is ordered in. What is already drawn by then is reported as "≤" that
  time; the app's own `TAUDOT_TIMELINE` milestones (in each `runN.log`) cover the earlier part.
- Detection is on 1/8-scale block means; a change under ~6 levels in a block isn't seen.
- `top`'s samples are ~1.2 s apart and its clock lines have 1 s resolution: per-sample wakeup rates are rough,
  means over a phase are good to ~10%.
- Synthetic trackpad scroll events posted to the app's PID don't reach the views (keyboard scrolling does);
  the shell's in-app `TAUDOT_BENCH` covers trackpad scrolling frame timing.
- Menu items aimed at the project window (View ▸ Show Files) don't act on an off-screen window; press the control
  through Accessibility instead (`press Files`).
- The app reads the user's real defaults domain (`app.taudot.Taudot`), whose size changes launch times (957 keys of
  test leftovers cost ~36 ms of window time, 2026-11-04). Note its key count with each series:
  `defaults read app.taudot.Taudot | grep -cE '^    "?[A-Za-z]'`.
