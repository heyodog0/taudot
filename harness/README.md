# harness

Drives Overleaf's own browser editor against the local CE (`docker/up.sh && docker/seed.sh` first). Other agents use
it as the reference client in fuzz tests. Needs Node 23.6 or later (runs the `.ts` files directly) and
`npm install` in this folder once.

## One-shot: `type.ts`

```sh
harness/type.ts --project classic --file main.tex --pos 0 --text hi        # insert, wait for the server, print text
harness/type.ts --project history-ot --file sections/intro.tex --pos 10 --del 3
harness/type.ts --project <id> --file main.tex --edits '[{"pos":0,"text":"a"},{"pos":4,"del":1}]' --json
harness/type.ts --project classic --file main.tex                          # just print the text
```

- `--project` takes a project ID or `classic` / `history-ot` (IDs from `docker/.env.test`).
- `--user 1|2|admin|<email>` picks the test user (default 1). Both users can edit both projects.
- Positions are JavaScript string indexes (UTF-16 code units), as CodeMirror and `sharejs-text-ot` count them.
  An emoji counts as 2. Edits in `--edits` apply in order, each seeing the ones before.
- The browser editor replaces every surrogate code unit with U+FFFD on input, so a typed emoji reaches the server
  as two U+FFFD (`filter-characters.ts`). The harness does the same before dispatching. A doc in Overleaf never
  holds astral characters when written by the browser, and an uploaded file containing any becomes a binary file.
- Edits are exact CodeMirror changes with `userEvent: "input.type"`, so they go through the editor's own path to
  the socket. `--keys` types with the keyboard instead, closer to a person, but auto-close brackets and auto-indent
  on Enter can change what lands.
- It returns only after the server confirmed every edit (`otUpdateApplied` with no `op`, sent only to the sender).
- `--json` prints `{text, docId, version, type}`. `type` is `sharejs-text-ot` or `history-ot`, from `joinDoc`.
- `--trace frames.jsonl` saves every socket.io frame, `--headed` shows the browser.

## Long-lived: `serve.ts`

For fuzz tests that interleave the browser with other clients. One JSON command per line on stdin, one JSON reply
per line on stdout:

```
{"cmd":"open","project":"classic","file":"main.tex","user":"2"}  -> {"ok":true,"docId":"…","version":12,"type":"sharejs-text-ot"}
{"cmd":"edit","edits":[{"pos":0,"text":"x"},{"pos":3,"del":1}]}   -> {"ok":true}
{"cmd":"settle"}                                                  -> {"ok":true,"version":14}
{"cmd":"text"}                                                    -> {"ok":true,"text":"…","version":14}
{"cmd":"errors"}                                                  -> {"ok":true,"errors":[]}
{"cmd":"close"}
```

`edit` returns once CodeMirror has the change. The browser batches and sends on its own schedule, so call `settle`
before comparing texts. `settle` fails if the server sent `otUpdateError` or disconnected the client.

## Protocol tests: `tests/`

Socket-level regression tests for the answers in `docs/protocol.md`, each against its own project (made with
`docker/seed.sh --name`, never the shared demo projects). Each prints the facts it saw as JSON and exits 0 when they
match the doc.

```sh
harness/tests/run.sh                         # all of them, about 3 minutes
harness/tests/run.sh emoji migration         # some
node harness/tests/historyot-version.ts      # one, with its full output
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

The history-ot bug checks assert the bug, so they fail when Overleaf fixes it and the doc needs updating.

`lib/socket.ts` is the raw socket.io client the tests use; `lib/overleaf.ts` drives the real browser editor. Logins are
rate limited per email, so the tests log in once per user and keep the session cookie in the system temp folder
(`taudot-harness-<port>-user<n>.cookie`); `OverleafEditor.useCookie` reuses it in the browser.

## Test projects: `docker/seed.sh --name`

```sh
docker/seed.sh --name "engine fuzz" [--history-ot] [--from DIR] [--reset]   # prints the project ID
```

Makes (or finds by name) a project owned by user 1 and shared with user 2, from `docker/seed/` or `--from DIR`.
It leaves `docker/.env.test` alone and refuses the two shared names. Name it after yourself.

## Fuzz: `fuzz.ts`

N copies of the browser editor type random edits into one doc for T seconds; then each browser's text is compared
with the server's (a fresh raw join). Browsers alternate between user 1 and user 2. Prints a JSON report, exits 0
when all agree and no server error was seen. `--seed` repeats a run.

```sh
harness/fuzz.ts --browsers 3 --seconds 30 --unicode              # own project "protocol fuzz" (classic)
harness/fuzz.ts --history-ot --browsers 3 --seconds 30           # "protocol fuzz history-ot": fails, Overleaf bug
harness/fuzz.ts --project <id> --file sections/intro.tex --browsers 2 --seconds 60 --tail 5   # alongside engines
```

To fuzz with Taudot engines: make a project (`docker/seed.sh --name "engine fuzz"`), start the engines on it with their own
folders, and run `fuzz.ts --project <id> --mirror <folder> [--mirror <folder2>]` with `--tail` long enough for the
engines to settle. Each mirror's copy of `--file` must equal the server text too. `--emoji` adds astral characters,
which kill history-ot browser tabs (docs/protocol.md).

Results on CE 6.3.0 (2026-11-01): classic, 3 browsers × 30 s, 261 edits, all in sync. history-ot, 1 browser, in
sync; 2 or 3 browsers diverge within seconds (docs/protocol.md "history-ot versions").
