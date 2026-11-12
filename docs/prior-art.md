# Prior art

Two parts: other Overleaf clients (what to keep from them, and their bugs), then live and incremental typesetting
(who does what, and what is new in Taudot). Surveyed 2026-11-07, updated 2026-11-11. Stars and last push are from
`gh api` on 2026-11-07. **Checked** means we read the code (file named) or ran it; **read** means README, paper or
post. AGPL code was read, not copied.

## Part 1: Overleaf clients

| Project | What it is | Licence | Verdict |
|---|---|---|---|
| [leo1oel/lattice](https://github.com/leo1oel/lattice) | Mac app (Tauri + CodeMirror), own Rust socket client, ShareJS OT with a randomised convergence test; presence, chat, comments, suggestions (`meta.tc`), history with latexdiff, SyncTeX, Claude Code/Codex panel | Apache-2.0, 314★ | The direct competitor. `joinDoc` without `supportsHistoryOT`, so migrated projects are refused. **checked** `src-tauri/src/overleaf_rt.rs`, `src/overleaf/ot.ts` |
| [mei28/nvim-overleaf](https://github.com/mei28/nvim-overleaf) | Neovim plugin, TypeScript on Deno | MIT | Best design to learn from. OT core has bugs, below |
| [overleaf-workshop/Overleaf-Workshop](https://github.com/overleaf-workshop/Overleaf-Workshop) | VS Code extension | AGPL-3.0, 1,703★ | Most used. Syncs like file sync, not OT, below. Review panel PR #95 open since 2024-02 |
| [DanielHou315/overleaf-mcp-rt](https://github.com/DanielHou315/overleaf-mcp-rt) | MCP server: live doc, inflight transform, confirm on `otUpdateApplied`, history-ot read and opt-in write, comments; live test matrix on CE 4.2/5.5/6.0/6.3 | AGPL-3.0-or-later (port of Workshop) | Best protocol cross-check. **checked** `src/overleaf/{ot,text-ot,history-ot,socket}.ts` |
| [GhoshSrinjoy/Overleaf-mcp](https://github.com/GhoshSrinjoy/Overleaf-mcp) | MCP + VS Code; one-shot ShareJS and history-ot ops; suggest mode | MIT | **checked** `src/core/overleaf/ot.ts` |
| [aloth/olcli](https://github.com/aloth/olcli) | CLI: reads both OT types over the socket, writes whole files over REST; comments, tracked changes | MIT, 248★ | **checked** `src/client.ts` |
| [ayghri/overleaf-mcp](https://github.com/ayghri/overleaf-mcp) | Python MCP, live ShareJS, every agent edit a tracked change | MIT | **checked** `overleaf_mcp/editor.py` |
| `deepghs/overleaf-mcp` (fork of `netique/overleaf-mcp`) | MCP server: socket OT edits plus verification | AGPL | Don't copy |
| `michu5696/overleaf-review` | npm CLI | | Incremental OT edits so review ranges survive |
| `genggng/overleaf-git-sync` | Python tool and VS Code extension | | `joinDoc` / `applyOtUpdate` to sync a git repo, aimed at CE |
| [da-h/airlatex.vim](https://github.com/da-h/airlatex.vim) | Vim plugin, ShareJS only | MIT, 88★, last push 2023-05 | |
| `moritzgloeckl/overleaf-sync`, `mjyoo2/OverleafMCP`, `eric-xw/Overleaf-Desktop`, ~10 more | zip, REST or git bridge | | Not real time |

Three clients speak `history-ot` (overleaf-mcp-rt, Overleaf-mcp, olcli); the rest will stop working on projects
Overleaf migrates. What none ships: history-ot writes on by default, and one background engine that an app, a CLI
with `--json` and agents share. That edge holds only with convergence tests as strong as mcp-rt's per-version CE
matrix.

overleaf-mcp-rt's `CLAUDE.md` states protocol facts worth checking against `docs/protocol.md`: an ack is not
"applied"; history-ot versions are not restamped on transformed updates; ShareJS and history-ot transforms disagree
on some overlaps; lone surrogates become U+FFFD.

### nvim-overleaf

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

### Overleaf Workshop

Paths are under `src/`.

- Good reference for connection styles and the event list (`api/socketio.ts`), REST calls (`api/base.ts`), and the
  socket-closing fix for issue #309.
- Sync happens on save. `core/remoteFileSystemProvider.ts` diffs the whole file with diff-match-patch against a cached
  server copy and patches fuzzily. Concurrent nearby edits can land in the wrong place.
- No transforms. A remote op whose version doesn't match clears both caches, and the next save then returns without
  sending (around line 839). The edit is silently lost.
- Unicode handling is shaky: some conversions are no-ops and deletes are decoded as ASCII.
- No queue of unconfirmed edits, no resend after a reconnect.

## Part 2: Live and incremental typesetting

Taudot's live typesetting comes in two forms: a patched pdfTeX (`clients/pdftex`), and universal (`docs/universal.md`),
which runs unmodified pdfTeX, XeTeX and LuaTeX under libtau, a libc interposer, plus a few injected tokens. It takes
fork() snapshots at line reads during the body, resumes from the newest one before an edit, and checks every page it
sends against stock. Measured side by side with TeXpresso, Rosina, rtex and Typst in `docs/bench.md`.

| | Engine | Snapshots | Paragraph preview | Output vs stock |
|---|---|---|---|---|
| **Taudot (universal)** | unmodified pdfTeX, XeTeX, LuaTeX | fork() mid-document, resume on edit | yes, from a fork at the paragraph | byte-identical on every bench key |
| TeXpresso | patched XeTeX (Tectonic) | fork() about every 500 ms of engine time | no | XDV, no PDF; no claim |
| liveTeX-Rosina | unmodified pdfTeX, XeTeX (LuaTeX via a Lua worker) | one fork point, after the preamble | provisional fragment | final build is stock; no identity claim |
| FlashTeX | Rust port of pdfTeX | checkpoints in a resident host | edited page | byte-identical to pdflatex on 11 documents |
| rtex | unmodified LuaLaTeX | none (captured context) | yes | glyph-identical to 1 sp; pagination may be stale |
| Lode / texlode | unmodified LuaLaTeX | none (persistent workers) | yes | claimed identical |
| tex-fast-recompile | unmodified, LuaTeX included | none: waits after the preamble | no | full run |
| Fine's Instant Preview (2001) | resident TeX | none | fragments | own slices |
| INCTEX (1991) | the formatter itself | checkpoints of formatter state | no | reformats selected pages |
| Typst | not TeX | memoisation | incremental | n/a |

### Entries

**Peter Selinger, pdftex mailing list, 15 January 2022**
([post](https://tug.org/pipermail/pdftex/2022-January/009257.html)). A proposal, never built. Snapshot an unmodified
TeX process, intercept its reads and writes ("can almost be done at the operating system level … except to replace a
few system calls"), and on an edit restart from "the most recent snapshot that could be affected". Ross Moore and
Doug McKenna doubted it in the thread. This is libtau's design. **read**

**TeXpresso** ([let-def/texpresso](https://github.com/let-def/texpresso), F. Bour, MIT, 806★). A modified Tectonic
XeTeX that takes fork(2) snapshots and re-runs from the newest one before the edit. I/O is intercepted inside the
patched engine. It snapshots about every 500 ms of engine time (`need_snapshot`, `src/frontend/engine_tex.c` ~l.474);
Taudot snapshots at line reads near the cursor. XeTeX only, drawn from XDV by its own DVI interpreter and MuPDF, no
PDF and no identity claim. Taudot is built on it. Lode cites a TUGboat 44(2) article (2023) that we couldn't
find on tug.org. **checked** `src/engine/main/fork.c`

**liveTeX-Rosina** ([PetalAdrift/liveTeX-Rosina](https://github.com/PetalAdrift/liveTeX-Rosina), created
2026-10-24, custom licence that forbids redistributing modified versions). The closest single project. An
`fopen`/`fclose` interposer loaded with `DYLD_INSERT_LIBRARIES` / `LD_PRELOAD` on stock pdfLaTeX and XeLaTeX. The
engine waits at a gate file after the preamble and forks one child per request. It previews the edited paragraph
first (quick mode writes region JSON; PDF mode composites fragment PDFs on the old pages), then runs a full stock
build after 500 ms. Even its warm-document checkpoint sits before the body, so a full correction typesets the whole
body. Editors drive it by atomically rewriting a `--source-buffer` file, which it polls. It shows nothing until the
first full build, snapshots included, is done. On the arXiv papers in our bench every key fell back to a full build
with no preview. Differs from universal: no mid-document snapshots, no identity check, no reaping. **checked**
`src/resident_hook.cpp`; built and run from source outside this repo.

**FlashTeX** ([flash-tex/flashtex](https://github.com/flash-tex/flashtex), 2026). A Rust port of pdfTeX
(custom, not stock) with a resident host that keeps checkpoints and re-typesets the edited page in milliseconds. Its
PDFs are byte-identical to pdflatex on 11 documents, and it has memory modes. Differs: a rewritten engine, not stock
binaries. **read**

**rtex** ([HenryXiaoYang/realtime-tex](https://github.com/HenryXiaoYang/realtime-tex), MIT, 276★). Stock LuaLaTeX
with no patches. A parked LuaLaTeX restores context captured by a background run, behind an allow-list, a probe and
leak checks. `apply_edit` to a decoded paragraph takes 0.29–1.65 ms, flat from 10 to 300 pages (its numbers, cloud
VM); glyph-identical to 1 sp in CI. Pages are exact only after a background pass (0.2 s at 10 pages, ~5–10 s at 300);
the final PDF is a clean stock build. Differs: LuaLaTeX only, and state comes from a capture vocabulary, not a fork,
so it cannot carry arbitrary earlier macros or catcodes. **checked** `docs/how-it-works.md`, `tex/rtex-serve.lua`

**Lode, "Real-Time LuaTeX" (TUG 2026 preprint) / texlode**
([preprint](https://www.tug.org/tug2026/preprints/lode-realtime.pdf), [texlode.com](https://texlode.com)). Stock
LuaLaTeX in persistent workers: the paragraph in about 1 ms (line breaking 0.17–1.99 ms, round trip 0.79–6.11 ms),
then full layout in the background. Output claimed identical; needs special templates. Closed, runs in the browser.
Its benchmark repo says the paper's Typst numbers don't reproduce with its script (issue #1). Differs: LuaLaTeX only,
no snapshots. **read**

**tex-fast-recompile** ([user202729/tex-fast-recompile](https://github.com/user202729/tex-fast-recompile), 2023). A
stock engine, LuaTeX included, compiles the preamble and waits until the file changes. No fork, so each change
re-runs the body. **read**

**Fine, "Instant Preview and the TeX daemon"**, TUGboat 22(4), 2001
([PDF](https://tug.org/TUGboat/tb22-4/tb72fine.pdf)). A resident TeX fed fragments through a pipe, typesetting on
each keystroke. An early form of a parked engine and a paragraph preview. Dormant, as are BaKoMa's Dynamical Preview
(~2002, own engine, reformats one page) and WhizzyTeX (format-dumped preamble plus slices). **read**

**INCTEX** (Harrison & Pan, UCB/CSD-91-614, 1991, VorTeX lineage;
[report](https://www2.eecs.berkeley.edu/Pubs/TechRpts/1991/5231.html)). Checkpoints the formatter's state,
reformats only selected pages, and stops when the state matches again. Snapshots and resume in concept, done inside
the formatter. The report is a scan; we couldn't confirm whether TeX itself was modified. **read**

**Typst** ([typst/typst](https://github.com/typst/typst), Apache-2.0, 57,036★). Not LaTeX: incremental by
memoisation in its own compiler (Haug's 2022 thesis). `watch` takes 18 / 146 / 414 ms at 10 / 100 / 300 pages in
rtex's bench (Typst 0.15.1); `docs/bench.md` has ours. Cited for contrast. **read**

Also seen: Texifier/Texpad's Live Typeset (own TeX fork, TexpadTeX, 2017; no numbers or identity claim), Fuchs at
TUG 2019 (a rewritten engine that records state at each page), Textures Flash Mode and TeXShop flash (full re-runs),
SwiftLaTeX, busytex and Tectonic (stock engines in WASM or a Rust wrapper, full compiles), Overleaf's own full
server compile.

### What is new

To our knowledge, Taudot is the first to resume from mid-document fork() snapshots on unmodified pdfTeX, XeTeX
and LuaTeX via library interposition, with output byte-identical to stock across a benchmark; it realizes
Selinger's 2022 proposal.

The idea is Selinger's; what is new is building it and checking it. The rest exists elsewhere:

| Piece | Prior work |
|---|---|
| fork() snapshots and resume | TeXpresso (patched XeTeX), INCTEX (inside the formatter) |
| Interposing on stock TeX | liveTeX-Rosina (one checkpoint, before the body) |
| A parked, resident engine | Rosina, rtex, Lode, tex-fast-recompile, Fine 2001 |
| Two-tier preview: paragraph first, exact page after | Rosina, Lode, rtex |
| Byte-identical incremental output as a goal | FlashTeX (own engine), Lode (claimed) |
| Giving memory back when idle (reaping) | routine engineering; FlashTeX has memory modes |

The paragraph preview on pdfTeX and XeTeX, the engines Overleaf users compile with, is ours, but the preview itself
is not new: rtex and texlode do it on LuaLaTeX at the same or better speed. Getting the state from a fork instead of a
capture vocabulary means macros, catcodes and `\parshape` from anywhere earlier just work. We found no
counterexample to the claim above, but the field moved fast in 2026 (Rosina, FlashTeX, texlode) and closed tools
can't be checked.

### Open

- Texifier's live typesetter: no numbers or exactness claims to compare against; worth a hands-on run.
- TeXpresso's TUGboat 44(2) article: not found.
- No published tinymist (Typst preview) latency.
