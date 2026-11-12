# Implicit state machines

Places where a component's state lived in several flags, optionals, pending tasks, timers, pids or counters instead
of one explicit state, so bad combinations were representable and the order of async events decided what happened.
Each entry is the traced sequence that went wrong; code and tests cite the IDs (`grep -rw E4`).

**Status.** Every item not marked *open* is fixed, and named by ID in a test that drives its sequence:

| Layer | Tests |
|---|---|
| Engine (E) | `crates/engine/src/serve.rs` tests, `review/tests.rs`, `hist.rs`, `service.rs`, `history.rs`, `projects.rs`; Neovim client: `clients/nvim/tests/reconnect.lua`, `connect_spec.lua` |
| App (A) | `clients/mac/Tests/shell_statefix.sh` (drives `StateCheck.swift` in a real window; `TAUDOT_STATECHECK_ONLY=A12,A1` for a subset), `TaudotTests/*State*Tests.swift`, `HistoryTests.swift` |
| PDF pane (P) | `TaudotTests/PDFStateTests.swift`, `LiveTexStateTests.swift`, `DriverLifecycleTests.swift` |
| C drivers (C) | `clients/pdftex/tests/test_serve.py`, `test_real.py`; `clients/render/tests/test_driver.py` |

The fix pattern: one `enum` per machine with a single transition function; a generation or session token captured by
every async task and checked after **each** await; a timeout on every request; pending work kept in one place.

Severity: **high** = an ordinary sequence loses or duplicates text, edits where the user can't see, or sticks until a
restart; **medium** = visibly wrong but recoverable, or needs unusual timing; **low** = cosmetic or rare.

## High

| # | Machine | Sequence |
|---|---|---|
| E1 | Engine reconnect | A reconnect's `joinProject` tree was discarded: offline adds, renames and deletes never mirrored; a deleted open doc failed every reconnect. |
| E2 | Neovim inflight edit on disconnect | The failed `doc.edit` folded into pending before the rebase checked "already applied": an applied edit inserted twice. |
| E3 | Reconnect after a refused op | An op Overleaf rejected was resent after every immediate reconnect, forever, rejoining every doc (429 risk). |
| E4 | OT rejoin with an op in flight | The "was it applied?" guess composed the op into pending; a late ack applied it twice (or lost it). |
| E5 | Project actor on a half-open network | Requests without timeouts froze the actor: API calls hung, backups stopped, SIGTERM lost up to 2 s of edits. |
| A1 | Claude pane fade vs ⌘J | ⌘J twice within 160 ms: the faded pane kept the keyboard; a stale fade hid a re-shown pane. |
| A2 | Pane animation superseded | Two toggles within 200 ms left a pane at width 0 but "visible"; close mid-animation saved half states. |
| A3 | Review draft across a file switch | A comment drafted in a.tex, sent after switching to b.tex, landed at the same line in b.tex. |
| A4 | ⌘Q with one window cancelled | Windows already shut down stayed open on a dead engine connection; edits there were lost. |
| A5 | History tree load vs a diff pick | One shared task: a click right after picking a version cancelled the tree load. |
| A12 | Keys under the History diff | ⌘2, an issue row, a comment click or inverse search focused the live editor beneath the read-only diff. |
| P1 | LiveTex settle with no PDF | A fatal-error run settled on the previous PDF and log, or never on a first run. `done` now always carries `log`. |
| P2 | Comment hover popover | NSPopover on hover flickered and went stale. Now a view of the pane. |
| P3 | Pane `close()` kept state | No generation bump: version A's marks, jump and SyncTeX landed on version B. |
| C1 | pdfTeX serve: waiting for the new runner | A second rollback before "R" signalled the snapshot itself: a dead pid kept, or the engine root killed. |
| C2 | pdfTeX serve command buffer | A command over 1 MB (a big .bib) read as EOF and the driver exited. The buffer now grows. |
| C3 | pdfTeX serve reopen with `--state` | A .bib changed between sessions went unnoticed; STATE saved only on clean EOF. |
| C4 | pdfTeX snapshot table | No thinning: a run over ~80 s hit `exit(1)`. Now capped (`TAUDOT_MAX_SNAPSHOTS`, 256) and thinned. |

## Medium

- **Engine and sync.** E6 tracked/undo flags lost by `Client::rebase` and backups (tracked edits sent untracked). E7
  2 s batching: typing after a reject sent as an untracked undo; a toggle mid-batch retagged earlier edits. E8 a late
  `doc.changed` dropped as seen; `engine.lagged` unhandled in Neovim. E9 `unflushed` cleared by a stale `doc.state`.
  E10 a half-written external file read as a big deletion. E11 a remote rename racing a mirror write left a duplicate.
  E12 a doc removed with unconfirmed edits dropped them. E13 launch agent: an engine that exited 0 counted as up; a
  bootout/bootstrap race. E14 history-ot: updates without `ts` deduped wrongly; a late duplicate ack confirmed the
  wrong op.
- **App UI.** A6 window closed during `start()`. A7 native editor: no retry after a failed start; double reconnect.
  A8 concurrent opens: A→B→C could show B. A9 Vim offsets (ranges, marks, pending operators) carried across a text
  replacement. A10 unzoom after Claude exits started a hidden claude. A11 issues settle timer dropped an apply. A13
  double close, two save sheets. A14 cancelled mode switch left two windows on one folder. A15 Claude morph races. A16
  stale trackpad scroll replies in a new gesture. A17 windows opened from Finder or the CLI didn't await
  `BundledTools.ensured`. A18 review actions without timeouts.
- **PDF pane.** P4 a missing TeX Live year restarted TeXpresso on every reconnect. P5 driver launch: no retry, last
  events dropped, backoff never decayed. P6 Txp lost-start check depended on stderr/stdout order. P7 older SyncTeX
  installed over newer. P8 a page changed during a cache save marked clean. P9 render retries with no typesetter;
  requests without timeouts leaking all 4 render slots. P10 EngineFeed reopen storms, notes after close. P11 a late
  word read re-showed a cancelled selection. P12 cursor dot lookup flag never reset. P13 forward-search `jumpDone`
  stuck. P14 History hover cards crossing. P15 comments toggle shared across windows.
- **C drivers** (`driver.c` = TeXpresso path; `live.c`/`serve.c` = live pdfTeX). C5 engine death exited the driver
  (patch 0003). C6 a hung biber froze the driver (now `TAUDOT_TOOL_TIMEOUT_S`, 120 s). C7 finish/goal requests lost
  before "R" (patch 0009). C8 `\bibliography{refs.bib}` statted `refs.bib.bib`. C9 BibTeX failure reruns, a possible
  loop. C10 held edits past 4096 dropped. C11 deferred BibTeX result starved by typing. C12 silent caps (`pend[64]`,
  `texts[512]`, `ch[64]`): over 64 files synced at once left stale content. C13 a first run with no snapshots never
  applied edits.

## Low

- E15 Neovim connect without a generation; E16 buffer path didn't follow renames; E17 stale presence offline; E18 a
  stopped actor's handle kept; E19 *open*: a second, divergent OT client in `crates/overleaf/src/doc.rs` (tests only);
  E20 blob cache evict vs get, unlocked clones index.
- A19 *open*: focus tracking in several places; A20 History anchors stored as group values; A21 HistoryPDF no retry
  after an error; A22 Home sign-in without generations; A23 Home remove-local re-check; A24 *open*:
  `texDiagnosticsLoaded` set before success; A25 CrashReport modal during boot; A26 grow card left on close; A27
  sidebar ghost.
- P16 goal deduplicated in three places; P17 tests sharing `TAUDOT_PAGE_CACHE` (now one each); P18 FolderWatch vs
  EngineFeed gap; P19 fetching/offline notes never cleared; P20 EdgeScroll flags.
- C14 makeindex reported as "bibtex", stale .blg announced; C15 `rerun_once` stuck; C16 *open*: fetch `waiting` and
  `offline` never cleared; C17 BibTeX child `setpgid`, temp dir leak, orphaned xetex forks, unannounced `pdf-*` files.
