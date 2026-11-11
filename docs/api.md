# Engine API, level 0 (draft)

Level 0 may still change. From level 1 on, methods are only added. Clients call `engine.info` first.

## Transport

- JSON-RPC 2.0, one JSON object per line, over the Unix socket `~/.taudot/engine.sock` (or `$TAUDOT_HOME`).
- `~/.taudot/engine.json` holds `{pid, socket, api_level, version}` for the running engine.
- Server-to-client notifications are JSON-RPC notifications (no `id`).
- `seq` numbers belong to one engine run. A client that reconnects to a new engine (another `pid` in `engine.json`)
  opens its docs again.

## Positions

Positions in this API are **UTF-8 byte offsets** into the document text, because that is what Neovim's `on_bytes`
reports. The engine converts to Overleaf's units. Text is UTF-8, lines end in `\n`.

An edit is `{pos, del, ins}`: delete `del` bytes at `pos`, then insert `ins` there. A list of edits applies in order.

## Methods

| Method | Params | Result |
|---|---|---|
| `engine.info` | | `{api_level: 0, version, instance}` (`instance` changes when the engine restarts: seqs start over) |
| `project.open` | `{url}` or `{project_id}`, `folder?` | `{project_id, folder, docs: [{doc_id, path}], me: {user_id, name, initials}}` |
| `project.status` | `{project_id}` | `{connection, me, users: [...], track_changes, docs: [{doc_id, path, state, unconfirmed, seq, version, type, editable, readonly}]}` |
| `doc.open` | `{project_id, path}` | `{doc_id, text, seq, type, version, editable, readonly}` |
| `doc.edit` | `{doc_id, seq, edits: [...], edit_id?}` | `{seq}` |
| `doc.subscribe` | `{doc_id, since_seq}` | `{seq}`, then notifications |
| `doc.ranges` | `{doc_id}` | `{doc_id, seq, ranges: [range]}` |
| `presence.cursor` | `{doc_id, pos, seq?}` | `{}` |
| `activity.subscribe` | `{project_id, since_seq}` | `{seq}`, then project notifications |
| `thread.get` | `{project_id, thread_id}` | `thread` |
| `thread.list` | `{project_id}` | `{supported, threads: [thread + {doc_id, path, start, end, text, seq}]}` |
| `comment.add` | `{doc_id, start, end, seq?, text}` | `{thread_id, seq}` |
| `thread.reply` | `{project_id, thread_id, text}` | `{}` |
| `thread.resolve`, `thread.reopen`, `thread.delete` | `{project_id, thread_id, doc_id?}` | `{}` |
| `message.edit` | `{project_id, thread_id, message_id, text}` | `{}` |
| `message.delete` | `{project_id, thread_id, message_id}` | `{}` |
| `change.accept`, `change.reject` | `{doc_id, ids: [change id]}` | `{}` |
| `review.track` | `{project_id, on?}` | `{on}` |
| `account.status` | `{url?}` | `{logged_in, server, user_id?, email?, name?, source?, expired?, error?}` |
| `account.login` | `{url?, from?: "browser"\|"cookie", browser?, cookie?, source?}` | as `account.status` |
| `account.logout` | `{url?}` | `{logged_in: false, server}` |
| `projects.list` | `{url?, scan?: [folder]}` | `{server, from, projects: [project]}` |
| `project.clone` | `{url?, project_id, folder, force?}` | `{folder, project_id, name, docs, files}`, `clone.progress` while it runs |
| `project.create` | `{url?, name, template?: "blank"\|"example"}` | `{project_id, name, server}` |
| `project.forget` | `{url?, project_id, folder?}` | `{}` |
| `complete.items` | `{doc_id, pos, before?}` | `{from, to, context, items: [{label, kind, detail, insert, cursor?}]}` |
| `history.updates` | `{project_id, min_count?, before?}` | `{updates: [version group], next_before, head}` |
| `history.labels` | `{project_id}` | `{labels: [label]}` |
| `history.tree` | `{project_id, from, to}` | `{from, to, files: [{path, op, new_path, deleted_at_v, editable}]}` |
| `history.diff` | `{project_id, path, from, to}` | `{path, from, to, binary, text, chunks: [chunk], inserted, deleted}` |
| `history.file` | `{project_id, path, version}` | `{path, version, binary, text}` |
| `history.files_at` | `{project_id, version}` | `{version, head, from, files: [{path, hash, kind}]}` |
| `history.blob` | `{project_id, hash}` | `{hash, file, cached}` |
| `history.zip_files` | `{project_id, version, paths}` | `{version, files: [{path, hash, file}]}` |

`connection` is `online`, `connecting`, `offline` or `readonly` (some doc stopped writing; its `readonly` says why).

`kind` (of a range) is `comment`, `tracked_insert` or `tracked_delete`.
### `project.open`

`me` is the logged-in Overleaf user, so a client can leave its own cursor out of `presence.changed`. Its `name` and
`initials` come from the project's member list; `name` falls back to the part of the email before `@`.

With `folder`, the engine keeps every doc of the project at `<folder>/<path>`: it writes each one when the project is
opened and again about 200 ms after its text changes (at most 1 s while edits keep coming), through a temporary file
and a rename, so readers such as the PDF preview never see half a file. A file that already differs from Overleaf is
first copied to `~/.taudot/backup/conflicts/<project_id>/<path>.<unix time>` and an `activity` with kind `conflict`
says so. Changes made in the folder (edits, new files and folders, renames, moves, deletes) are sent to Overleaf.
A folder can also name its project in `<folder>/.taudot.json`: `{"project": "<id or Overleaf URL>"}`.

What syncs is what Overleaf's Git bridge would sync if every upload were a `git add`:

- **Never, either way**: hidden paths (`.taudot*`, `.git`, `.DS_Store`, `.gitignore`, `.latexmkrc`...), LaTeX build
  outputs (`aux`, `log`, `out`, `synctex.gz`, `fls`, `fdb_latexmk`, `bbl`, `blg`, `xdv`, ..., and a PDF named like a
  `.tex` doc) and editor swap and backup files.
- **Not uploaded when new**: paths matched by the folder's `.gitignore` files (at any depth, plus `.git/info/exclude`),
  by `<folder>/.taudotignore`, or by `"ignore": [patterns]` in `.taudot.json`, all in gitignore syntax. Later ones win:
  `!figures/*.pdf` in `.taudotignore` lets back in what `.gitignore` leaves out. A change to these files takes effect
  at once; files it lets in are uploaded.
- **Paths Overleaf already has** keep syncing both ways whatever the rules say (as a file git already tracks), and
  Overleaf's files are always written to the folder. The rules only keep new local files off Overleaf.

### `doc.edit`, `seq` and transforms

`seq` is the engine's per-document sequence number of changes, local and remote. A client sends `doc.edit` with the
`seq` its edits were made at. If other changes arrived since, the engine transforms the edits past them; on equal
positions the changes the client hadn't seen go first, so an insert at the same spot lands after theirs. The result is
the `seq` of the client's change.

The engine saves a client from keeping a copy of the server's text, resending, and transforming its own edits; it
can't save it from transforming incoming ones. A client's edit and a remote change can cross on the socket: the client
has already applied its edit when a `doc.changed` written against the older `seq` arrives. So:

- A client has at most one `doc.edit` in flight per doc. Edits typed meanwhile are composed and sent once the result
  is back.
- The client transforms each incoming `doc.changed` past its unacknowledged edits (the one in flight, then the composed
  pending ones), with the incoming change first on ties, the same rule the engine uses.
- The engine sends every `doc.changed` with a `seq` below a `doc.edit` result before the result, on the same
  connection. The connection that sent an edit doesn't get it back as a `doc.changed`; other connections do.

`edit_id` is an optional string the client picks, unique per doc. The engine remembers the last 1,000 per doc; a
`doc.edit` whose `edit_id` it has seen returns the original result and changes nothing. A client that lost the
connection while an edit was in flight resends it with the same `edit_id` (Overleaf's `dupIfSource` idea at the API
level). It does not survive an engine restart; after one, the client opens its docs again.

An edit to a doc whose `editable` is false fails with a message that says why. Both formats are editable:
`editable` is true for every doc, and a doc that went read-only says so in `readonly`. A `history-ot` doc's text is
its *visible* text, as Overleaf's editor shows it: tracked-deleted text isn't in it.

### `presence.cursor`

`pos` is measured at `seq`; without `seq`, at the doc's current `seq`. The engine moves it past changes the client
hasn't seen and sends `clientTracking.updatePosition` to Overleaf.

## Review: cursors, comments, tracked changes

### Positions that move

Ranges and cursors are UTF-8 byte offsets at the doc's `seq` given with them (`doc.ranges`, `ranges.changed`, and
`seq` on each user in `presence.changed`). The engine moves them past every change, the way Overleaf does
(`libraries/ranges-tracker`). A client that has edits of its own not yet acknowledged maps the positions through them,
as it does for `doc.changed`. Between notifications a client moves what it draws with the text itself (Neovim's
extmarks): an insert at a comment's start goes before it, one at its end goes after it.

### `range`

`{id, kind, start, end, text, author: {user_id, name, initials}, ts, thread_id?, resolved?}`, `ts` in ms since 1970.

- `comment`: `text` is the commented text, `thread_id` (= `id`) its thread, `resolved` from the thread (false while
  threads are unknown). `author` is the thread's first message's author, else whoever added the range.
- `tracked_insert`: text in the doc, from `start` to `end`.
- `tracked_delete`: text no longer in the doc; `start` = `end` is where it was, `text` what it was. The same on a
  history-ot doc, whose server copy keeps the text (the engine's text is the visible one).

### `presence.changed`

`{project_id, users: [{client_id, user_id, name, initials, doc_id, pos, seq}]}`, everyone else connected to the
project, whole list each time: when someone moves their cursor, joins or leaves. `pos` is null when the cursor isn't
in a doc the engine has open. Your own other connections are in it too (same `user_id` as `me`).
`project.status` has the same list as `users`.

### Threads

`thread`: `{thread_id, resolved, resolved_at, resolved_by, messages: [{id, text, ts, user}]}`.

Threads live in Overleaf's chat service, reached through REST routes. overleaf.com and Server Pro have these routes;
stock **Overleaf CE doesn't** (404). **Our local CE has them** through `harness/ce-threads`, a test-only module that
`docker/up.sh` installs. Re-run `harness/ce-threads/install.sh` after the container is recreated. So thread tests
run on our CE.

On a server without the routes, comment ranges still show:
- `thread.get` and `comment.add` fail with "this server has no comment threads".
- `thread.list` says `supported: false` and lists the ranges with empty `messages`.

- `thread.list`: every comment range in the docs the engine has open (all of them with a mirror folder), each with
  its thread, where it is and the text it covers. Resolved ones are included; clients hide them.
- `comment.add`: comment on `[start, end)` (measured at `seq`, default now) with a first message `text`. As in the
  browser, the message is posted first, then the range is sent as an op; the result's `seq` is that op's change.
- `thread.reply`, `thread.resolve`, `thread.reopen`, `thread.delete`, `message.edit`, `message.delete`: the browser's
  routes. `doc_id` is only needed when no open doc has the thread's range. `message.delete` of your own message uses
  the `own-messages` route, which needs no owner rights.

Notifications: `thread.changed {project_id, thread_id, thread}` whenever a thread changes (`thread` null when it was
deleted). Changes you make come back this way too, from Overleaf's socket events.

### Tracked changes

- `review.track {on: true}` makes your later edits tracked: each batch is sent with `meta.tc`, and the edits show as
  `tracked_insert` and `tracked_delete` with you as author. `{}` just reads it. The result is `{on, overleaf}`.
  An edit already waiting to be sent when the toggle changes goes in its batch's mode.
- The engine follows Overleaf's own project-wide setting, as the browser does: `trackChangesState` from joining the
  project (`true` for everyone, or `{<user_id>: bool, __guests__: bool}`) and the `toggle-track-changes` event.
  When it changes, your edits are tracked if your entry says so, and the engine sends the notification
  `review.track {project_id, on, overleaf}` (to `activity.subscribe` subscribers). `review.track {on}` only changes
  the engine's own mode until Overleaf's setting next changes; it doesn't write Overleaf's setting.
  `project.status` has it as `overleaf_track_changes`.
- `change.reject`: the changes' inverse (tracked inserts deleted, tracked deletes put back) is sent as one undo batch
  (`u: true`), as the browser does, once the doc has nothing else waiting to be sent.
- `change.accept`: `POST /project/:id/doc/:doc/changes/accept`. Overleaf CE has no such route; there it fails with a
  message saying so. Others' accepts arrive as Overleaf's `accept-changes` event.
- history-ot docs: comments, tracked changes and the track-changes setting work as above, with three differences.
  Tracked change IDs are the engine's (`h…`), not the server's, and a change has one only once the server has it.
  `change.accept` and `change.reject` send an op (accepting an insert or rejecting a delete clears its tracking, the
  other two remove the text), so both work on Overleaf CE. Our tracked edits carry `tracking` in the op instead of
  `meta.tc`.

Notifications: `ranges.changed {doc_id, seq, ranges}`, the whole list, at most every 50 ms, when a range was added
or removed, its text changed, or a thread was resolved or reopened. Plain moves don't send it (see above). It goes to
connections subscribed to the doc. `presence.changed` and `thread.changed` go to `activity.subscribe` subscribers.

## Accounts and projects

For the app's home window: who is logged in, the project list, cloning. `url` is any URL on the server (default
`https://www.overleaf.com`); results name it as `server`, its origin.

### Accounts

Sessions are the ones `taudot login` keeps: the server's session cookie in the Keychain (service `taudot`, account
the origin). `<home>/accounts.json` remembers where each came from (no secrets).

- `account.status`: checks the stored session against the server (`GET /user/settings`: its `ol-user_id`,
  `ol-usersEmail` and `ol-user` give ID, email and name). `source` is where the session came from: a browser
  (`chrome`, `arc`, `brave`, `edge`, `vivaldi`, `safari`), `cookie` (pasted), what the client said at login (the
  app's sign-in view says `webview`), or `engine` when it is the engine's own `--cookie`/`--password` login. An
  expired session gives `logged_in: false, expired: true` and `error`. `name` falls back to the part of the email
  before `@`.
- `account.login`: `from: "browser"` (the default without `cookie`) takes the session from `browser`, or else from
  the first of chrome, arc, brave, edge, vivaldi, safari that has one the server accepts; `source` in the result says
  which. Reading a Chromium browser's cookies makes macOS ask once for its Safe Storage key; Safari's need Full Disk
  Access for the engine. `from: "cookie"` takes `cookie`: a `Cookie:` header, `name=value`, or the bare value of
  `overleaf_session2` (overleaf.com) or `overleaf.sid` (CE). The session is checked before it is stored; a failure
  stores nothing.
- `account.logout`: forgets the stored session. It doesn't sign out on the server: the cookie is usually the
  browser's own session.

### `projects.list`

The dashboard's list (`POST /api/project`; on a server without it, `GET /user/projects`, which has no owner or dates
and leaves out archived and trashed projects; `from` says which). Each `project`:

`{id, name, owner: {id, name, email}, last_updated, last_updated_by: {id, name, email} | null, access_level, source,
archived, trashed, local_folder?, last_opened?}`

- `last_updated` is an ISO 8601 time. `access_level` is `owner`, `readWrite`, `review`, `readOnly` or
  `readAndWrite` (link sharing); `source` is `owner`, `invite` or `token`. `owner` is null for read-only link access.
- `local_folder` is the folder on this Mac that mirrors the project, if any: the engine notes every folder it mirrors
  (`project.open` with `folder`, `project.clone`) in `<home>/clones.json`, and `scan` adds the folders directly inside
  the given ones (such as `~/Overleaf`) whose `.taudot.json` names a project of this server. A folder that no
  longer names the project doesn't count. `last_opened` (ms since 1970) is when the engine last opened that folder.

### `project.clone`

As `taudot clone`: makes `folder` (absolute; `~/` is expanded), writes `.taudot.json`, opens the project and
mirrors it there. `folder` must be missing or empty (`.DS_Store` aside), unless `force`; a folder that already names
this project is opened as it is. If the project can't be opened, a folder the call made is removed again. While it
works the calling connection gets `clone.progress {project_id, folder, stage, text}` with `stage` `connecting`,
`downloading`, then `done`.

### `project.create`

A new project on the server, as the dashboard's New Project: `POST /project/new {projectName, template}`
(`ProjectController.newProject`; `example` makes Overleaf's example project, anything else the basic one-file
one). The name is trimmed and must not be empty. It isn't cloned; call `project.clone` for that.

### `project.forget`

Stops syncing the project (the engine closes it, for all its clients) and drops `folder` (or, without one, all the
project's folders) from the clones index. The files stay. A client that wants to delete a local copy calls this
first, then moves the folder to the Trash: deleting a folder the engine still mirrors would be synced as deletes.

## Completion

### `complete.items`

What can go at `pos` in the doc, from the whole project, as Overleaf's editor offers it. `context` (and each item's
`kind`) is decided from the text before `pos`:

| Before the cursor | `context` | Items |
|---|---|---|
| `\na`, or a lone `\` | `command` | commands defined in the project (`\newcommand`, `\DeclareMathOperator`, `\def`, ...), then common LaTeX ones, then the others used in the project |
| `\begin{`, `\end{` | `env` | for `\end{` first the innermost environment still open (`detail: "open"`); then `\newenvironment`/`\newtheorem` ones, common ones, ones used |
| `\cite{a, b` (any command with `cite` in its name, optional `[...]` args) | `cite` | keys of every `.bib` doc (and `\bibitem`s), `detail` `Author et al. Year · Title` |
| `\ref{`, `\eqref{`, `\cref{a,` (names ending in `ref`) | `ref` | every `\label`, `detail` the caption (`Figure: ...`) or section (`§ Intro`) it is under |
| `\input{`, `\include{`, `\includegraphics{`, `\bibliography{`, `\addbibresource{` | `file` | project paths of the right type (`.tex` and `.bib` without the extension where LaTeX adds it) |

Anything else gives `context: null` and no items. The engine doesn't filter by what is typed: clients filter and sort
(fuzzy) as the user types, and only call again on a trigger (`\`, `{`, `,`).

- `from`..`to` is the text an item replaces: from the backslash of a command, from after `{` or the last `,` of a
  citation or reference list, to `pos`. `insert` replaces it; `cursor`, when present, is the byte offset in `insert`
  where the cursor goes (inside the first `{}`), else it goes at the end.
- `before` is the text before the cursor as the client has it (its current line is enough). Pass it when the client
  has edits the engine hasn't got yet; `pos`, `from` and `to` are then in the client's own text. Without it the engine
  reads its own text at its current `seq`.
- The index covers the docs the engine has open (all of them when it mirrors a folder). Each doc is rescanned only
  when its `seq` moved, on the next call; nothing is read from disk. About 1 ms per call on a 200 KB paper.

## History

The project's versions as Overleaf's History view shows them, read-only (routes and their quirks: `docs/history.md`).
The project must be open. The calls run beside the project's sync, never blocking it. Diffs and file trees between
two versions never change, so the engine keeps them in memory (64 MB across projects); the version list and labels
are asked for each time.

- A **version group** is `{from_v, to_v, start_ts, end_ts, users: [user], labels: [label], paths, ops, origin?}`:
  Overleaf's grouping of consecutive updates (same kind, under five minutes apart, cut at labels). The project at
  `to_v` is the state after it. `paths` are the docs whose text changed; `ops` the file changes,
  `{op: "add"|"rename"|"remove", path, new_path?, at_v}`. Times are ms since 1970. `origin` is Overleaf's
  (`{kind: "upload"}`, `{kind: "file-restore", path, version, timestamp}`, ...).
- A **user** is `{user_id, name, initials, hue, mine}`. `hue` is Overleaf's colour for that user, in degrees, as
  the browser computes it (200 for yourself); clients may colour authors their own way instead. A user Overleaf
  no longer knows comes as `{user_id: null, name: "Anonymous"}`.
- A **label** is `{id, comment, version, user_id, name, created_at, mine}`.
- `history.updates`: newest first, at least `min_count` groups (default 25) unless the history runs out; for older
  ones pass the result's `next_before` as `before` (null on the last page). `head` is the newest version, on the first
  page only.
- `history.tree`: every file at either version; `op` is `edited`, `added`, `renamed` (`new_path` is the name at
  `to`), `removed` (with `deleted_at_v`) or null (unchanged). `editable: false` is a binary file.
- `history.diff`: `path` is the file's name at `to`. `text` is the file at `to` with the text deleted in the range
  left in place; each chunk is `{kind: "same"|"insert"|"delete", start, end, user?, ts?}` with `start`..`end` in UTF-8
  bytes of `text` (as everywhere in this API) and, for inserts and deletes, who made it and when (neighbouring runs
  by the same user are merged). `inserted`, `deleted` count bytes. A binary file gives `binary: true`, no text.
- `history.file`: the file's whole text at one version (`history.diff` with `from == to`).
- `history.files_at`: every file at the version with its blob `hash` (git's blob SHA-1, the name history stores it
  under) and `kind`: `binary`, `text` or `unknown` (history didn't say). `hash` is null for text edited since it was
  added: get that with `history.file`. Exact: replayed from history's own changes, from the newest chunk when the
  version is in it (`from: "latest_chunk"`, one request) else from version 0 (`from: "changes"`). Answers are kept in
  memory, and so is what's needed to replay (file operations only), so another version costs no request or one.
- `history.blob`: the blob's `file`, a path in the engine's blob store, fetched only when it isn't there already
  (`cached`). The store is shared by every project, version and server (a blob is checked against its hash before it
  is kept): `$TAUDOT_BLOB_CACHE`, default `~/Library/Caches/Taudot/blobs/<2 hex>/<hash>` (elsewhere
  `$XDG_CACHE_HOME/taudot/blobs`), least recently used out over `$TAUDOT_BLOB_CACHE_BYTES` (default 2 GiB). Clients
  copy the file; it may be evicted later.
- `history.zip_files`: the fallback when `history.blob` fails. Downloads the version as a zip (Overleaf allows 30 an
  hour) and puts only `paths` from it into the blob store; a path not in the zip has `hash` and `file` null.

## Notifications

| Method | Params |
|---|---|
| `doc.changed` | `{doc_id, seq, edits, author: {user_id, name, initials}, origin: "local"\|"remote", source?: "disk"}` |
| `doc.state` | `{doc_id, state: "idle"\|"pending"\|"inflight", unconfirmed, oldest_unconfirmed_ms, readonly, seq}` (`seq`: the doc's seq when the state was taken; a note can arrive after a later `doc.edit` result) |
| `ranges.changed` | `{doc_id, seq, ranges}` |
| `presence.changed` | `{project_id, users: [{client_id, user_id, name, initials, doc_id, pos, seq}]}` |
| `thread.changed` | `{project_id, thread_id, thread}` |
| `review.track` | `{project_id, on, overleaf}` |
| `activity` | `{project_id, kind, text, doc_id?, ts}` (`ts` in ms since 1970) |
| `project.connection` | `{project_id, connection, reason?}` |
| `clone.progress` | `{project_id, folder, stage: "connecting"\|"downloading"\|"done", text}` (to the caller of `project.clone`) |
| `engine.lagged` | `{missed}`: the client fell behind and missed notifications; it should reopen its docs. |

`origin: "local"` is an edit made through this engine (by another of its clients). `source: "disk"` marks a local
edit the engine made from the project folder's file (an editor or an agent outside Taudot changed it); it is absent
otherwise. `author` is null-valued when the
server didn't say who made a change, such as the change a rebase produces.

`activity` kinds from the engine itself: `relogin` (the session expired and the engine logged in again), `rejoin` and
`rebase` (a doc was fetched afresh and unconfirmed edits carried over), `restored` (unconfirmed edits replayed from the
on-disk backup), `conflict` (see `project.open`), `error`. Other kinds are Overleaf events passed through.

## Recovery

- Unconfirmed edits are written to `~/.taudot/backup/<project_id>/<doc_id>.json` at most every 2 s and when the
  engine stops, and the file is removed once everything is confirmed. When the doc is next opened the engine replays
  it: it catches up from the backed-up version, so an edit the server had already applied counts as confirmed and is
  not sent twice, and otherwise sends it. `doc.open` returns the text with the replayed edits.
- When the session expires, the engine logs in again if it was started with a password (not with only a cookie).
