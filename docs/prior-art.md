# Prior art

The clients below don't speak `history-ot`, so they will stop working on projects Overleaf migrates. A few MCP tools
do as of 2026-09/10 (overleaf-mcp-rt, Overleaf-mcp, olcli); see `docs/research/prior-art.md` §1, the fuller survey.

| Project | What it is | Verdict |
|---|---|---|
| `mei28/nvim-overleaf` | Neovim plugin, TypeScript on Deno, MIT | Best design to learn from. OT core has bugs, see below |
| `iamhyc/Overleaf-Workshop` | VS Code extension | Most used. Sync works more like file sync than OT, see below |
| `deepghs/overleaf-mcp` (fork of `netique/overleaf-mcp`) | MCP server for agents, AGPL | Socket OT edits plus verification. AGPL, don't copy |
| `michu5696/overleaf-review` | npm CLI | Incremental OT edits so review ranges survive |
| `genggng/overleaf-git-sync` | Python tool and VS Code extension | Uses `joinDoc` / `applyOtUpdate` to sync a git repo, aimed at CE |
| `eric-xw/Overleaf-Desktop` | macOS app | Git bridge, not real-time |
| TeXpresso | Live LaTeX preview | Snapshots the TeX process to re-typeset from the edit point. Basis for our preview |

## nvim-overleaf

Paths are under `denops/overleaf/`. About 3,900 lines including tests.

Keep:
- The layering: `protocol/` (own socket.io 0.9 client), `ot/`, `document/`, `sync/`, `auth/`.
- The Latin-1 decoding (`util/encoding.ts`), the git blob hash (`ot/hash.ts`).
- The Lua bridge that forwards `nvim_buf_attach` `on_bytes` events (`lua/overleaf/bridge.lua`), the byte to character
  conversion, the 100 ms send batching.
- The echo guards: `sync/echo_guard.ts` for disk writes, an `applying_remote` flag for buffer writes.
- The state names: idle, pending, inflight, inflight and pending (`document/document.ts`).

Bugs, worst first:
1. **Multi-component transforms are wrong** (`ot/transform.ts`, `transformOps`). Components of an op list apply in
   order, but the loop transforms each component against the remote op without moving the remote op past the earlier
   components. Pending ops accumulate many components, so concurrent typing lands text in the wrong place. Tests cover
   single components only.
2. **Pending ops are transformed against the wrong op** (`document/document.ts`, `onRemoteOp`). After transforming the
   remote op past `pendingOps`, it then transforms `pendingOps` against that result. It should use the remote op as it
   was after the inflight transform.
3. **Confirms on the socket callback** (`document/document_manager.ts`). Overleaf's callback only means queued. The real
   confirmation, `otUpdateApplied` with `{v, doc}` and no op, then arrives as a "remote op" with an old version, which
   fails the version check and triggers a rejoin. Confirmed against CE, not yet reproduced on a live server.
4. **Rejoin drops unsent edits** (`Document.reset`), then replaces the whole buffer with `nvim_buf_set_lines`, which also
   moves the cursor.
5. **No hash is ever sent.** The 30 s drift check compares the client's own two copies, not the server.
6. **File mode replaces whole files** (`sync/file_sync.ts`): a save becomes "delete all, insert all".
7. **Positions count code points** (`Array.from`), but the server counts JavaScript string indexes.
8. **Runs inside Neovim** as a Denops plugin, so quitting Neovim ends sync, and other tools can't attach.
9. No comments, no tracked changes, cursors sent but not drawn, cookie copied by hand.

## Overleaf Workshop

Paths are under `src/`.

- Good reference for connection styles and the event list (`api/socketio.ts`), REST calls (`api/base.ts`), and the
  socket-closing fix for issue #309.
- Sync happens on save. `core/remoteFileSystemProvider.ts` diffs the whole file with diff-match-patch against a cached
  server copy and patches fuzzily. Concurrent nearby edits can land in the wrong place.
- No transforms. A remote op whose version doesn't match clears both caches, and the next save then returns without
  sending (around line 839). The edit is silently lost.
- Unicode handling is shaky: some conversions are no-ops and deletes are decoded as ASCII.
- No queue of unconfirmed edits, no resend after a reconnect.

## Glideshow (the owner's project, the model for this repo)

`~/code/lab/glideshow`, `~/code/lab/glideshow-dev`. Patterns to copy:

- The data is one plain folder that agents can edit directly. The editor reloads live.
- One background server per machine (standard library only), found through a state file. Every window, the CLI and
  agents are clients of it.
- A complete non-interactive CLI with `--json` (`render`, `check`, `selection`, `comments`).
- A git commit per save for history (`glideshow/history.py`).
- `docs/` holds the format, an agent guide and dated plans. A backlog or `PLAN.md` is worked top to bottom by `/loop`
  skills, each item checked off with what was done.
- A fidelity harness that measures against the real reference (Google's own render).
- Tests run with a temp home folder, and fail if they touch the user's real data.
- `glideshow-dev/docs/terminal.md` already plans Rex as one more client, and a `glideshow watch` pane that shows slides
  through the Kitty graphics protocol. The LaTeX preview pane needs the same component, so build it once.
