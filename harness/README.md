# harness

Drives Overleaf's own browser editor against the local CE (`docker/up.sh && docker/seed.sh` first): the reference
client for fuzz tests. Needs Node 23.6+ (runs `.ts` directly) and `npm install` here once.

## One-shot: `type.ts`

```sh
harness/type.ts --project classic --file main.tex --pos 0 --text hi        # insert, wait for the server, print text
harness/type.ts --project history-ot --file sections/intro.tex --pos 10 --del 3
harness/type.ts --project <id> --file main.tex --edits '[{"pos":0,"text":"a"},{"pos":4,"del":1}]' --json
harness/type.ts --project classic --file main.tex                          # just print the text
```

- `--project`: an ID, or `classic` / `history-ot` (from `docker/.env.test`). `--user 1|2|admin|<email>` (default 1).
- Positions are UTF-16 code units, as CodeMirror and `sharejs-text-ot` count (an emoji is 2). `--edits` apply in
  order, each seeing the ones before.
- Like the browser (`filter-characters.ts`), surrogate code units become U+FFFD: a typed emoji arrives as two U+FFFD.
- Edits are CodeMirror changes with `userEvent: "input.type"`. `--keys` types on the keyboard instead (auto-close
  brackets and auto-indent can change what lands).
- Returns once the server confirmed every edit (`otUpdateApplied` with no `op`).
- `--json` prints `{text, docId, version, type}`. `--trace frames.jsonl` saves socket.io frames; `--headed` shows the
  browser.

## Long-lived: `serve.ts`

One JSON command per line on stdin, one reply per line on stdout:

```
{"cmd":"open","project":"classic","file":"main.tex","user":"2"}  -> {"ok":true,"docId":"…","version":12,"type":"sharejs-text-ot"}
{"cmd":"edit","edits":[{"pos":0,"text":"x"},{"pos":3,"del":1}]}   -> {"ok":true}
{"cmd":"settle"}                                                  -> {"ok":true,"version":14}
{"cmd":"text"}                                                    -> {"ok":true,"text":"…","version":14}
{"cmd":"errors"}                                                  -> {"ok":true,"errors":[]}
{"cmd":"close"}
```

`edit` returns once CodeMirror has the change; `settle` waits for the server (fails on `otUpdateError` or a
disconnect).

## Protocol tests: `tests/`

Socket-level tests of `docs/protocol.md`, each on its own project; each prints what it saw as JSON, exit 0 if it
matches.

```sh
harness/tests/run.sh                         # all, about 3 minutes
harness/tests/run.sh emoji migration         # some
node harness/tests/historyot-version.ts      # one, full output
```

| Test | Checks |
|---|---|
| `classic-basics.ts` | plain op text, packed join lines, hash units, strict schema, missing-ops error, `dupIfSource`, bursts |
| `historyot-version.ts` | concurrent history-ot ops are confirmed and broadcast with the old `v` (Overleaf bug) |
| `historyot-stale-browser.ts [--classic]` | the browser then drifts from the server on history-ot, not on classic |
| `historyot-snapshot.ts` | history-ot `joinDoc` shape, tracked deletes, comments, visible-to-content positions |
| `emoji.ts` | emoji typed in the browser and sent raw, both formats |
| `upload-filetypes.ts` | which uploaded files become docs and which binary files |
| `migration.ts` | `otMigrationStage` raised while a doc is open |
| `session.ts` | session TTL: web requests reset it, socket traffic doesn't |
| `entity-events.ts` | REST file-tree changes and the socket events others get |
| `cursors.ts` | `clientTracking.*` shapes |
| `chat-settings.ts` | chat messages and settings changes, and their events |

The history-ot checks assert the bug, so they fail when Overleaf fixes it.

`lib/socket.ts` is the raw socket.io client, `lib/overleaf.ts` the browser driver. Logins are rate limited, so each
user's cookie is kept in the temp folder (`taudot-harness-<port>-user<n>.cookie`).

## Test projects: `docker/seed.sh --name`

```sh
docker/seed.sh --name "engine fuzz" [--history-ot] [--from DIR] [--reset]   # prints the project ID
```

Makes (or finds) a project of user 1 shared with user 2, from `docker/seed/` or `--from DIR`; refuses the two shared
names.

## Fuzz: `fuzz.ts`

N browsers (users 1 and 2 alternating) type random edits into one doc for T seconds, then compare with a fresh raw
join. JSON report; exit 0 when all agree with no server error. `--seed` repeats a run.

```sh
harness/fuzz.ts --browsers 3 --seconds 30 --unicode              # own project "protocol fuzz" (classic)
harness/fuzz.ts --history-ot --browsers 3 --seconds 30           # "protocol fuzz history-ot": fails, Overleaf bug
harness/fuzz.ts --project <id> --file sections/intro.tex --browsers 2 --seconds 60 --tail 5   # alongside engines
```

With Taudot engines on the project, `--mirror <folder>` (repeatable) also checks each engine's copy after `--tail`.
`--emoji` adds astral characters (they kill history-ot browser tabs).

On CE 6.3.0: classic, 3 browsers × 30 s, 261 edits, all in sync. history-ot: 1 browser in sync; 2 or 3 diverge within
seconds (`docs/protocol.md`, "history-ot versions").
