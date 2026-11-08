# Plan

Work top to bottom. Check an item off with a one-line note of what was done and how it was checked. A step blocked on
the user gets **(waiting: …)** and the next step goes ahead.

## M0. Test bed
- [ ] Overleaf CE in Docker on this machine, with a script to create test users and projects, one per edit format.
      Find how to set `otMigrationStage` per project so both formats can be tested.
- [ ] Drive a real browser editor against it (Playwright) as the reference client.
- [ ] Settle the open questions in `protocol.md` against the running server, and update the doc.

## M1. OT core
- [ ] Internal op type, transform and apply, with converters for `sharejs-text-ot` and `history-ot`.
- [ ] Unit tests for multi-component ops, non-ASCII and astral characters, and the inflight and pending case. These are
      where nvim-overleaf's bugs are.
- [ ] Fuzz test: two or three simulated clients plus one Playwright browser, random concurrent edits against CE. Pass
      when every client and the server end with the same text. Run it in both formats.

## M2. Engine
- [ ] Overleaf backend: connect, join, send, confirm on `otUpdateApplied`, resend with `dupIfSource`, catch up with
      `joinDoc(fromVersion)`, full rejoin plus rebase on `ClientRequestedMissingOpsError`.
- [ ] On-disk backup of unsent edits every 2 s, replayed on start.
- [ ] Local folder mirror with minimal diffs both ways.
- [ ] Socket API with `engine.info`, `doc.subscribe`, sequence numbers.
- [ ] Kill tests: kill the engine, drop the network and restart the CE container in the middle of the fuzz test. Pass
      when nothing typed is lost.

## M3. Clients
- [ ] Neovim plugin: live edits, author colours, cursors.
- [ ] CLI with `--json`.
- [ ] Rex activity float and alerts.

## M4. Review features
- [ ] Comments: ranges, threads, live events.
- [ ] Tracked changes in both formats.

## M5. Preview
- [ ] `latexmk` plus Kitty graphics pane plus SyncTeX.
- [ ] TeXpresso-style incremental preview.

## Later
- Own CRDT backend. Native app.
