# Implicit state machines

An inventory, 2026-11-06, of the places where a component's state lives in several flags, optionals, pending tasks,
timers, pids or counters instead of one explicit state, so that bad combinations are representable and the order of
async events decides what happens. Found by reading the code and its history (four read-only sweeps: PDF pane, app UI,
engine and sync, C typesetting drivers). **Nothing here was reproduced.** Each "bug" is a traced sequence; fixing one
starts with a test that reproduces it.

Severity: **high** = an ordinary sequence of events loses or duplicates text, edits where the user can't see, or gets
stuck until a restart; **medium** = visibly wrong but recoverable, or needs unusual timing; **low** = cosmetic or rare.

Recent bugs of exactly this shape: the version-PDF hover card flicker (c6deedb), BibTeX warnings lost on reopen
(b198ac3), the .sty crash (565ef58), the swap-file prompt (60b75f8), History ⇧-arrows from the wrong end (1ec525b),
tests racing on a process-wide env var (c6e6465).

The usual fix: one `enum` per machine with a single transition function; a generation or session token captured by
every async task and checked after **each** await; timeouts on every request; "pending" work kept in one place.

## High, all layers

| # | Machine | Where | What goes wrong |
|---|---|---|---|
| E1 | Engine project reconnect | `crates/engine/src/engine.rs:518-546, 295, 406-435` | The joinProject tree from a reconnect is thrown away: docs added/renamed/deleted while offline are never mirrored, and one deleted open doc makes every reconnect fail (offline forever, 30 s backoff). |
| E2 | Neovim buffer inflight on disconnect | `clients/nvim/lua/taudot/buffer.lua:350-365, 534-585`, `rpc.lua:84-96` | On close, the failed `doc.edit` folds inflight into pending before the rebase can test "already applied", so an edit the engine did apply is inserted twice and sent to Overleaf. No `edit_id` sent. The test sets inflight by hand and misses it. |
| E3 | Reconnect without backoff, poisoned op | `engine.rs:406-465, 714-728` | An op Overleaf rejects (`otUpdateError`) is resent after every immediate reconnect, forever; each loop rejoins every doc (429 risk); `forceDisconnect` delay ignored. |
| E4 | OT rejoin on the same connection with an op in flight | `crates/ot2/src/client.rs:273-306`, `engine.rs:770-845` | The "was it applied?" guess composes the inflight op into pending; when the late ack arrives, the op is applied twice (or lost if the guess goes the other way). |
| E5 | Actor blocked on network calls without timeouts | `engine.rs:412, 469-541`, `crates/overleaf/src/http.rs:38`, `socket.rs` | A half-open network during reconnect freezes the project actor: API calls hang, backups stop, SIGTERM loses up to 2 s of edits. |
| A1 | Claude pane fade vs ⌘J | `TaudotApp/ClaudePane.swift:117, 250-286`, `ClaudeFloat.swift:192-212` | ⌘J twice within 160 ms: the pane fades out but keeps the keyboard; typing goes to an invisible Claude prompt. Stale fade completion hides a re-shown docked pane. |
| A2 | Pane animation superseded | `TaudotApp/Panes.swift:295-329`, `ProjectWindow.swift:269-315` | Two pane toggles within 200 ms: the first `finish` never runs; a pane stays width 0 but "visible" (unfocusable, saved as shown, stale divider). ⌘E or close mid-animation saves half states. |
| A3 | Review draft across a file switch | `TaudotReview/ReviewMarginView.swift:108-417`, `FloatingCards.swift:139`, `ReviewController.swift:364` | A comment drafted in a.tex and sent after switching to b.tex is posted at the same line/col in b.tex. "Sending" can stick (timeout only checked on reload). |
| A4 | ⌘Q with one window cancelled | `TaudotApp/main.swift:139-148`, `ProjectWindow.swift:756-773` | Native-mode windows already shut down stay open with a dead engine connection; edits typed there are lost. |
| A5 | History tree load cancelled by a diff pick | `TaudotHistory/HistoryController.swift:41-42, 152-197` | One shared `loadingDiff` task: clicking a PDF mark or a file right after picking a version cancels the tree load; the file list and PDF stay on the old range, the diff on the new one. |
| A12 | Keys to the editor under the History diff | `TaudotApp/History.swift:86-162`, `Panes.swift:45`, `Issues.swift:452-461` | ⌘2, an issue row, a comment click or inverse search focus the live editor beneath the read-only diff: typing edits text you can't see. (Listed medium by the sweep; raised here: it edits invisibly.) |
| P1 | LiveTex run settle with no PDF | `TaudotPDF/LiveTex.swift:768-846` | A run that writes no PDF (fatal error) settles on the previous run's PDF and log, or never settles on the first run; the fatal error's log is never shown. Same shape as b198ac3. |
| P2 | Comment hover popover | `TaudotPDF/NotesOverlay.swift:18-19, 108-117, 225-243` | The NSPopover-on-hover pattern c6deedb replaced in History: can flicker near pane edges; stale text after updates; never closes on window resign. |
| P3 | Pane `close()` keeps everything | `TaudotPDF/TaudotPDF.swift:346-360`, `VersionPDF.swift:52-66` | No generation bump or reset: version A's change marks land on version B, `changesDone` is true too early, A's pending jump replays on B, A's SyncTeX text is cached for B. |
| C1 | pdfTeX serve: waiting for the new runner | `clients/pdftex/live.c:199-209`, `serve.c:307-338` | A second rollback before "R" signals the snapshot itself: a dead pid stays in the table, or at j=0 the engine root is killed and the driver exits. Likely when keystrokes pile up behind a synchronous BibTeX run, or fast preamble edits. |
| C2 | pdfTeX serve: 1 MB command buffer | `serve.c:642-683` | One command line over 1 MB (opening a big .bib) reads 0 bytes, taken as EOF: the driver exits. |
| C3 | pdfTeX serve: reopen with `--state` | `serve.c:195-220, 521-588`, `live.c:576-772` | A .bib changed between sessions isn't noticed (hashes taken from today's .bib), so the bibliography is stale; STATE only saved on clean EOF. |
| C4 | pdfTeX snapshot table | `live.c:50-95` | No thinning: a run over ~80 s hits `exit(1)` (no state saved); before that, every snapshot is a live process, so the user's process limit is hit and forks fail elsewhere. |

## Medium

**Engine and sync**
- E6 Review tracked/undo flags not moved by `Client::rebase` nor in backups (`review.rs:55-130`): tracked edits go out untracked after a rejoin or a restart.
- E7 Batch flags (`review.rs:98-154, 863-896`, 2 s batching): typing right after a reject is sent as an undo, untracked; toggling tracking mid-batch tags earlier edits.
- E8 Seq ordering, lagged broadcasts (`serve.rs:151-155, 410-418`, `buffer.lua:370-405`, `init.lua:61-105`): a late `doc.changed` dropped as already seen; `engine.lagged` unhandled in Neovim.
- E9 `unflushed` cleared by a stale `doc.state` (`init.lua:92-99`, `buffer.lua:376-381`): with an engine kill, an edit can be removed on rebase.
- E10 Mirror reads mid-write (`engine.rs:889-913`, `folder.rs:692-760`): a half-written file from an external editor is sent as a big deletion.
- E11 Remote rename racing a mirror write (`engine.rs:453-461`, `folder.rs:262-302`): old file left, later uploaded as a duplicate doc.
- E12 Doc removed with unconfirmed edits (`folder.rs:263-267, 562-573`): edits dropped, backup orphaned, Neovim keeps a dead doc_id.
- E13 Launch agent (`service.rs:132-331`): engine exited 0 → "up to date" with no engine; bootout/bootstrap race; app connects to the dying old engine.
- E14 history-ot dedupe and stray acks (`hist.rs:36-290`): updates without `ts` deduped wrongly; a late duplicate ack can confirm the wrong op.

**App UI**
- A6 Window closed during `start()` (`ProjectWindow.swift:512-574, 704-729`): an orphan typesetter, RPC to a dead Neovim; a failed boot never sets `editorStarted`.
- A7 Native editor connection (`TaudotEditor/NativeEditor.swift:27-161, 385-390`): no retry after a failed start; double reconnect leaks a connection and rebases twice; stuck offline on a live socket; timers survive stop.
- A8 Native editor concurrent opens (`NativeEditor.swift:201-222`): duplicate subscriptions; A→B→C can show B.
- A9 Vim engine offsets across text replacement (`Vim/VimEngine.swift`, `NativeEditorView.swift:243-264`): visual ranges, marks, pending operators carried into another file or past remote edits; out-of-range `NSRange` (the .sty crash's shape).
- A10 Claude exits while zoomed (`ClaudePane.swift:302-306`, `Panes.swift:216-249`): unzoom starts a fresh hidden claude process.
- A11 Issues settle timer (`TaudotApp/Issues.swift:36-126`): an invalidated timer not set to nil drops a pending apply and blocks BibTeX's list; `hasLog` not reset on restart.
- A13 Double close (`ProjectWindow.swift:748-773`, `TaudotNeovim/Quit.swift:23-46`): two quit flows, two save sheets.
- A14 Mode switch reopen (`main.swift:48-57`): opens the new window first; cancel leaves Neovim and native windows on one folder.
- A15 Claude morph races (`ClaudePane.swift:184-241`).
- A16 Trackpad finger scroll (`TaudotNeovim/EditorView+Input.swift:184-332`): stale scroll replies paid into a new gesture (jumps, blank rows).
- A17 `BundledTools.ensured` awaited only by Home (`TaudotShared/BundledTools.swift:44-64`): windows opened from Finder/CLI connect to an engine about to restart.
- A18 Review pending actions never time out (`ReviewController.swift:279-421`).

**PDF pane**
- P4 Typesetter choice forgets the request (`TaudotPDF.swift:200-238`): a missing TeX Live year → TeXpresso restarted on every engine reconnect.
- P5 Driver lifecycle, both paths (`LiveTex.swift:628-714`, `Txp.swift:383-450`): no retry after a failed launch; last events before an exit dropped; backoff never decays; Txp's watchdog only covers startup.
- P6 Txp lost-start check depends on stderr/stdout order (`Txp.swift:237-252, 395-409`).
- P7 SyncTeX after done not re-checked after awaits (`TaudotPDF.swift:410-431`): older SyncTeX installed over newer; mismatched version.pdf/.synctex.
- P8 Page cache dirty set (`TaudotPDF.swift:1191-1268`, `PageCache.swift`): a page changed during a save is marked clean; reused pane never shows cached pages.
- P9 Render pipeline (`PDFPaneView.swift:127-521`): 10 Hz retry forever with no typesetter; Txp requests without timeouts can leak all 4 render slots (pane blank); `onPageShown` gaps and false reports (also skews the speed numbers).
- P10 EngineFeed (`EngineFeed.swift:54-231`): concurrent reopen storms; notifications after close; no resend while reconnecting.
- P11 PDF text selection (`TaudotPDF.swift:832-862`, `PDFSelection.swift`): Esc then the late word read shows the selection and pill again.
- P12 Cursor dot lookup flag never reset (`TaudotPDF.swift:1098-1184`).
- P13 Forward-search marks: `jumpDone` can stick at false; pending jump always deliberate; dim timer not cancelled.
- P14 History hover card leftovers (`VersionPDF.swift:263-554`): B's pending card replaces A's; a failed show leaves `pendingID` set.
- P15 Comments toggle shared across windows via UserDefaults (`NotesOverlay.swift:29-38`): drawn but dead notes.

**C drivers** (`driver.c` = TeXpresso path; `live.c`/`serve.c` = live pdfTeX)
- C5 Engine death in serve (`serve.c:652-675`, patch 0003): driver exits instead of restarting; signals may hit reused pids.
- C6 Synchronous latexmk rules (`live.c:387-685`): a hung biber freezes the driver; children inherit the command pipe.
- C7 Dropped finish/goal requests (`serve.c:705-711`, patch 0009): no reply, lost before "R", goal before the first snapshot never seen.
- C8 BibTeX signature misses `refs.bib` (`driver.c:769-805`): `\bibliography{refs.bib}` stats `refs.bib.bib`; a saved .bib never reruns BibTeX.
- C9 BibTeX failure reruns and possible loop (`driver.c:954-1089, 1356-1372`).
- C10 Held edits dropped past 4096 (`driver.c:573-670`): a big replace-all silently desyncs the typesetter; rescan jumps the queue.
- C11 Deferred BibTeX result starved by typing, leaked on overwrite (`driver.c:1045-1081`).
- C12 Silent caps in serve (`pend[64]`, `texts[512]`, `ch[64]`): a git checkout or Overleaf sync of >64 files leaves stale content.
- C13 First run with no snapshots (`serve.c:451-465, 678, 722-725`): edits never applied; `j<0` drops edits and never compiles again.

## Low

- E15 Neovim connect without a generation (`init.lua:110-316`); E16 Neovim buffer path doesn't follow renames;
  E17 stale presence while offline; E18 a panicked project actor's handle kept forever (`serve.rs:283-292`);
  E19 a second, divergent OT client in `crates/overleaf/src/doc.rs` (tests only); E20 blob cache evict vs get,
  unbounded `Replays.log`, unlocked clones index.
- A19 focus tracking in several places; A20 History anchors stored as group values (stale after merge);
  A21 HistoryPDF won't retry the same range after an error; A22 Home sign-in without generations; A23 Home
  remove-local re-check; A24 `texDiagnosticsLoaded` set before success; A25 CrashReport marks seen before parsing and
  runs modal during boot (may stall Neovim replies: check); A26 grow animation card left on close; A27 sidebar ghost.
- P16 goal deduplicated in three places; P17 tests still share `TAUDOT_PAGE_CACHE` (pass the root through `init`);
  P18 FolderWatch vs EngineFeed `liveDocs` gap; P19 fetching/offline notes never cleared; P20 EdgeScroll flags;
  PDFHost `featureWait` may accept the cache's old SyncTeX.
- C14 makeindex reported as the "bibtex" step; stale .blg announced as new; C15 `rerun_once` sticks; C16 fetch
  `waiting:true` and `offline` never cleared; C17 BibTeX child `setpgid` only in the child, temp dir leak, orphaned
  xetex forks, unannounced `pdf-*` files.

## Order of work (suggested)

1. **Edits never lost or doubled** (E1–E5, E2 first; then E6, E9, E12): sync tests against the fake server and CE that
   reproduce each, then the fix. Highest stakes: a collaborator's paper.
2. **Invisible editing and wrong targets** (A12, A3, A1, A4, A9).
3. **Typesetting liveness** (C1–C4, C13, P1, P5, P9): the driver must never exit or freeze; the pane always says what
   happened.
4. **Lifecycle tokens in the PDF pane and History** (P3, A5, P7, P10, P14, P2).
5. The rest, alongside whatever touches those files.
