# mock-engine

A stand-in for the Taudot engine so clients can be built and tried before the real one exists. It speaks
`docs/api.md` level 0 (JSON-RPC, one object per line) over a Unix socket and serves the text files of one folder. No
Overleaf: edits are transformed against what the sender hadn't seen yet, applied in order, sent to the other
subscribers and written back to the folder.

```sh
deno task start                                  # serves example/ with the bot, on ~/.taudot/engine.sock
deno run -A main.ts --folder DIR --socket /tmp/e.sock --bot --latency 400
deno task test
```

| Flag | Meaning |
|---|---|
| `--folder DIR` | Folder to serve (`.tex`, `.bib`, `.cls`, `.sty`, `.bst`, `.txt`, `.md`) |
| `--socket PATH` | Socket path, default `~/.taudot/engine.sock`. `engine.json` goes beside it |
| `--bot` | Adds Ada Lovelace (`AL`), who types phrases, moves her cursor, deletes some, leaves one comment and one tracked insertion |
| `--bot-interval MS`, `--bot-char MS` | Pause between bot actions (default 3000) and per typed character (90) |
| `--synthetic-review C,K` | Seed main.tex with C tracked changes (three reviewers, in clusters) and K comments: a long review panel, deterministic |
| `--bot-rounds N` | Stop the bot after N rounds (3: a phrase, the comment, the tracked insertion; then quiet, for tests) |
| `--bot-doc PATH` | Doc the bot edits, default `main.tex` |
| `--latency MS` | Hold each `doc.edit` this long before applying it, to see unconfirmed text |

Every applied edit is logged to stdout as `INITIALS path seq N: @pos -del +"ins"`, with `(from S)` when the edit was
written against an older seq and had to be transformed.

Differences from api.md:

- `project.open` ignores `url`/`project_id` and always returns the served folder as project `mock`.
- Review methods (`docs/api.md`, Review) work on the mock's own threads; there is no server, so `thread.list` always
  says `supported: true`. Tracked changes are simpler than Overleaf's: each tracked edit is its own range, nothing
  merges or cancels.
- `doc.state` is only sent to the connection that made the edit, and is only ever `inflight` (with `--latency`) or
  `idle`.

`ot.ts` is a small byte-based TextOperation (retain, insert, delete) used to transform stale edits. The Neovim client
has the same code in Lua.
