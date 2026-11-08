# Architecture

Neovim's shape: one core process owns all state, every interface is a client of a versioned API.

```
 Neovim plugin   Rex activity float   Rex preview pane   CLI, agents   native app (later)
       \               |                   |                 |              /
        +--------- engine API: JSON-RPC over a Unix socket, versioned --------+
                                        |
             sync engine, one per machine, survives every client
             - docs and OT state (inflight, pending, version, hash)
             - anchored ranges: comments, cursors, tracked changes, my recent edits
             - history log of every op by author
             - event bus with sequence numbers
             - on-disk backup of unsent edits
                                        |
        Overleaf backend          own backend (later)        local folder mirror
        socket OT + REST          CRDT, Yjs or Loro          latexmk, git, grep, agents
```

## Engine

- Language: **Rust** (decided 2026-11-01). Enums make the compiler check every op kind and OT state; `proptest` for
  the fuzz tests; Loro and Yrs are native Rust for the later CRDT backend; one small binary; good C interop for the
  TeX preview and a native app. Cost: write a socket.io 0.9 client, a few hundred lines, using nvim-overleaf's
  `protocol/` as the guide. Go was the runner-up and Zig was ruled out (pre-1.0 churn, no mature networking or CRDT
  libraries). Rex's own server is Go, which doesn't matter: the engine only talks to Rex through its CLI and API.
- Test harness: TypeScript, because Playwright drives the real browser editor as the reference client. Keeping it in
  another language also keeps the tests independent of the engine.
- Neovim plugin: Lua, a thin client of the engine socket. No Denops.
- One internal op type with converters to and from both Overleaf formats.
- Anchored ranges are the engine's version of Neovim extmarks. Every op moves them, and clients only draw them.
- The engine finds or starts itself through a state file, like Glideshow's `~/.glideshow/server.json`.

## API, borrowed from Neovim

| Neovim | Engine |
|---|---|
| `nvim --listen` socket | One Unix socket per machine |
| `nvim_buf_attach`, `on_bytes` | `doc.subscribe` streams each op with its author |
| Extmarks in namespaces | Anchored ranges. Each client draws them in its own namespace |
| `api_info`, API level | `engine.info`. Functions are added, never changed |
| `--remote-ui` reattach | Reconnect with the last sequence number to get missed events |

## Clients

- **Neovim plugin.** Thin, in Lua. It sends edits from `on_bytes` and applies remote ops with `nvim_buf_set_text`. It
  draws author colours that fade after a few seconds, collaborator cursors as virtual text, and comments as highlights
  with a sign.
- **Rex activity float.** A small terminal program in a floating layer. It shows your edits going from pending to sent
  to confirmed, collaborators' edits by name with file and line, and connection and hash status.
- **Rex alerts.** The engine opens a floating layer itself when a collaborator edits the paragraph you're in, when a
  reconnect forced a rebase, or when an edit has gone unconfirmed for over 5 s.
- **CLI.** `status`, `comments`, `selection`, `render`, all with `--json`.

## Rex facts (checked 2026-11-01)

- The server API has `session.new_layer` (bounds as fractions of the window), `session.float_block`,
  `session.raise_layer`, `session.lower_layer`, `session.resize_layer` and `session.close_layer`. See them with
  `rex api describe <method>`. There is also an event stream (`rex events`, Lua `rex.on`) and `rex focus`.
- Panes draw inline images. A Kitty graphics query got `_Gi=31;OK` back from a pane. The app bundles libghostty with its
  Kitty graphics code. `tools/kitty-graphics-check.sh <png>` repeats the test. It sends
  `ESC _Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA ESC \`, looks for `OK`, then draws the PNG.
- Rex docs: https://www.superlogical.com/rex/docs/llms.txt. Its changelog and roadmap are only on the Discord-gated
  community MCP server.

## Preview

- First version: `latexmk` on the local folder. Render changed pages to PNG with `mutool draw` or `pdftocairo`, send
  them over the Kitty protocol by image ID so pages update in place, and map clicks to SyncTeX.
- Later: incremental typesetting the TeXpresso way. Dump a format file when the preamble changes, snapshot the TeX
  process at page boundaries, re-typeset from the snapshot before the edit, stop once the output matches the previous
  run, and draw XDV pages directly. Target 50 to 300 ms per edit. References and citations update in a background pass.
- Share the "show pages in a Rex pane" component with Glideshow's planned `glideshow watch`.

## Risks

- Overleaf's protocol is unofficial and changes. Keep it inside the Overleaf backend module and fail safe.
- Automating your own account is a grey area under Overleaf's terms. Keep traffic at normal editing rates.
- Overleaf's code is AGPL. Read, don't copy.
