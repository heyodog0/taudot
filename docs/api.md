# Engine API, level 0 (draft)

Level 0 may still change; from level 1 on, methods are only added. Clients call `engine.info` first.

## Transport

- JSON-RPC 2.0, one JSON object per line, over the Unix socket `~/.taudot/engine.sock` (or under `$TAUDOT_HOME`).
  Notifications have no `id`.
- `~/.taudot/engine.json` holds `{pid, socket, api_level, version}` of the running engine.
- `seq` numbers belong to one engine run: a client that reconnects to a new engine (new `pid` or `instance`) reopens
  its docs.

## Positions

**UTF-8 byte offsets** into the doc text (what Neovim's `on_bytes` reports); the engine converts to Overleaf's units.
Lines end in `\n`. An edit is `{pos, del, ins}`: delete `del` bytes at `pos`, insert `ins` there. Lists apply in order.

## Methods

| Method | Params | Result |
|---|---|---|
| `engine.info` | | `{api_level: 0, version, instance}` (`instance` changes on restart) |
| `project.open` | `{url}` or `{project_id}`, `folder?` | `{project_id, folder, docs: [{doc_id, path}], me: {user_id, name, initials}}` |
| `project.status` | `{project_id}` | `{connection, me, users, track_changes, overleaf_track_changes, docs: [{doc_id, path, state, unconfirmed, seq, version, type, editable, readonly}]}` |
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
| `review.track` | `{project_id, on?}` | `{on, overleaf}` |
| `account.status` | `{url?}` | `{logged_in, server, user_id?, email?, name?, source?, expired?, error?}` |
| `account.login` | `{url?, from?: "browser"\|"cookie", browser?, cookie?, source?}` | as `account.status` |
| `account.logout` | `{url?}` | `{logged_in: false, server}` |
| `projects.list` | `{url?, scan?: [folder]}` | `{server, from, projects: [project]}` |
| `project.clone` | `{url?, project_id, folder, force?}` | `{folder, project_id, name, docs, files}` |
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

### `project.open`

`me` is the logged-in user (so a client can skip its own cursor); `name` and `initials` come from the project's
members, `name` falling back to the email before `@`.

With `folder`, the engine mirrors every doc at `<folder>/<path>` on open and about 200 ms after a change (at most 1 s
under steady edits), via a temporary file and rename. A file that already differs from Overleaf is first copied to
`~/.taudot/backup/conflicts/<project_id>/<path>.<unix time>` (`activity` kind `conflict`). Every change in the folder
goes to Overleaf. `<folder>/.taudot.json` can name the project: `{"project": "<id or Overleaf URL>"}`.

Sync follows Overleaf's Git bridge, as if every upload were a `git add`:

- **Never synced**: hidden paths (`.taudot*`, `.git`, `.DS_Store`, `.gitignore`, `.latexmkrc`...), build outputs
  (`aux`, `log`, `out`, `synctex.gz`, `fls`, `fdb_latexmk`, `bbl`, `blg`, `xdv`, ..., a PDF named like a `.tex` doc),
  editor swap and backup files.
- **Not uploaded when new**: matches of the folder's `.gitignore` files (any depth, plus `.git/info/exclude`),
  `.taudotignore`, or `"ignore": [patterns]` in `.taudot.json`, in that order, later winning (`!figures/*.pdf` in
  `.taudotignore` re-admits). Changes apply at once; newly admitted files are uploaded.
- Paths Overleaf already has sync both ways regardless.

### `doc.edit`, `seq` and transforms

`seq` counts a doc's changes, local and remote. `doc.edit` carries the `seq` its edits were made at; the engine
transforms them past later changes (unseen changes first on ties) and returns their `seq`. The client still
transforms incoming changes, since its edit and a remote one can cross:

- At most one `doc.edit` in flight per doc; edits typed meanwhile are composed and sent after the result.
- Transform each incoming `doc.changed` past unacknowledged edits (in flight, then pending), incoming first on ties.
- Every `doc.changed` below a `doc.edit` result's `seq` arrives before that result. The sending connection doesn't
  get its own edit back.

`edit_id` (optional, unique per doc): the engine remembers the last 1,000 per doc; a repeat returns the original
result without applying, so a client resends with it after losing the connection. Lost on engine restart.

`editable` is true in both formats; a doc gone read-only says why in `readonly`, and edits to it fail with that. A
`history-ot` doc's text excludes tracked deletes, as in Overleaf's editor.

### `presence.cursor`

`pos` is at `seq` (default the current one). The engine moves it past unseen changes and sends it to Overleaf
(`clientTracking.updatePosition`).

## Review

Ranges and cursors are at the `seq` given with them; the engine moves them past every change as Overleaf does
(`libraries/ranges-tracker`). Clients map them through their own unacknowledged edits and, between notifications,
move them with the text (an insert at a comment's start goes before it, at its end after it).

**`range`**: `{id, kind, start, end, text, author: {user_id, name, initials}, ts, thread_id?, resolved?}`, `ts` in ms
since 1970.

- `comment`: `thread_id` = `id`; `resolved` from the thread (false while unknown); `author` the first message's, else
  whoever added the range.
- `tracked_insert`: text in the doc. `tracked_delete`: removed text; `start` = `end` is where it was.

**`presence.changed`** lists everyone else connected, whole list on every move, join or leave, including your own
other connections (same `user_id` as `me`). `pos` is null outside the engine's open docs. `project.status` `users` is
the same list.

### Threads

`thread`: `{thread_id, resolved, resolved_at, resolved_by, messages: [{id, text, ts, user}]}`.

Threads need chat REST routes that overleaf.com and Server Pro have and stock CE lacks; our local CE has them
([protocol.md](protocol.md#comments)). Without them, `thread.get` and `comment.add` fail ("this server has no comment
threads") and `thread.list` gives `supported: false` with empty `messages`.

- `thread.list`: every comment range in the open docs, with thread, place and text, resolved ones included.
- `comment.add`: posts the first message, then sends the range op on `[start, end)` (at `seq`, default now); the
  result's `seq` is that op's.
- The other thread and message methods use the browser's routes. `doc_id` is needed only when no open doc has the
  thread's range. Deleting your own message uses the `own-messages` route (no owner rights).

`thread.changed` (`thread` null when deleted) comes for every change, yours included.

### Tracked changes

- `review.track {on: true}` tracks your later edits (you as author); `{}` reads it. A batch already waiting keeps its
  mode.
- The engine follows Overleaf's setting as the browser does (`trackChangesState` at join: `true` or
  `{<user_id>: bool, __guests__: bool}`; then `toggle-track-changes`), and on a change sends the `review.track`
  notification. `review.track {on}` overrides it only until Overleaf's next change, and never writes it.
- `change.reject` sends the inverse as one undo batch (`u: true`), once nothing else is waiting.
- `change.accept` is `POST /project/:id/doc/:doc/changes/accept`, absent on CE (fails saying so). Others' accepts
  arrive as `accept-changes`.
- On history-ot: change IDs are the engine's (`h…`), assigned once the server has the change; accept and reject are
  ops, so they work on CE.

`ranges.changed` (whole list, at most every 50 ms) comes when a range is added or removed, its text changes, or a
thread is resolved or reopened; not for plain moves.

## Accounts and projects

`url` is any URL on the server (default `https://www.overleaf.com`); `server` in results is its origin.

- Sessions are `taudot login`'s: the cookie in the Keychain (service `taudot`, account the origin);
  `<home>/accounts.json` records each one's source (no secrets).
- `account.status` checks the session (`GET /user/settings`). `source`: a browser (`chrome`, `arc`, `brave`, `edge`,
  `vivaldi`, `safari`), `cookie` (pasted), the client's own label (the app's sign-in view says `webview`), or `engine`
  (its own `--cookie`/`--password` login). Expired: `logged_in: false, expired: true, error`.
- `account.login`: `from: "browser"` (default without `cookie`) takes the session from `browser`, else the first
  browser above with one the server accepts (Chromium: macOS asks once for the Safe Storage key; Safari: needs Full
  Disk Access). `from: "cookie"` takes a `Cookie:` header, `name=value`, or the bare value of
  `overleaf_session2` / `overleaf.sid`. Nothing is stored unless it checks out.
- `account.logout` forgets the session; it doesn't sign out on the server (usually the browser's session).

### `projects.list`

`POST /api/project`, else `GET /user/projects` (no owner or dates, no archived or trashed; `from` says which). Each
`project`: `{id, name, owner: {id, name, email}, last_updated, last_updated_by: {id, name, email} | null,
access_level, source, archived, trashed, local_folder?, last_opened?}`.

- `last_updated` is ISO 8601. `access_level`: `owner`, `readWrite`, `review`, `readOnly`, `readAndWrite` (link
  sharing). `source`: `owner`, `invite`, `token`. `owner` is null for read-only link access.
- `local_folder`: the folder mirroring it, from `<home>/clones.json` (every folder the engine mirrors) plus, with
  `scan`, folders directly inside the given ones whose `.taudot.json` names the project. `last_opened`: ms since 1970.

### `project.clone`, `project.create`, `project.forget`

- `project.clone` is `taudot clone`: creates `folder` (absolute, `~/` expanded; must be missing or empty but for
  `.DS_Store`, unless `force`; one already naming the project is just opened), writes `.taudot.json`, opens and
  mirrors. On failure a folder it made is removed. The caller gets `clone.progress`.
- `project.create` is `POST /project/new {projectName, template}` (`example`, or the one-file project). Name trimmed,
  non-empty. Not cloned.
- `project.forget` closes the project for all clients and drops `folder` (or all its folders) from the index; files
  stay. To delete a local copy, forget first, then trash the folder, or the deletes sync.

## Completion

`complete.items` offers what can go at `pos`, from the whole project, as Overleaf's editor does. `context` (and each
item's `kind`) comes from the text before `pos`:

| Before the cursor | `context` | Items |
|---|---|---|
| `\na`, or a lone `\` | `command` | project-defined (`\newcommand`, `\DeclareMathOperator`, `\def`, ...), common, then others used |
| `\begin{`, `\end{` | `env` | for `\end{` the innermost open one first (`detail: "open"`); then defined (`\newenvironment`, `\newtheorem`), common, used |
| `\cite{a, b` (any `*cite*` command, optional `[...]` args) | `cite` | keys of every `.bib` doc and `\bibitem`, `detail` `Author et al. Year · Title` |
| `\ref{`, `\eqref{`, `\cref{a,` (any `*ref`) | `ref` | every `\label`, `detail` its caption (`Figure: ...`) or section (`§ Intro`) |
| `\input{`, `\include{`, `\includegraphics{`, `\bibliography{`, `\addbibresource{` | `file` | project paths of the right type, without the extension LaTeX adds |

Otherwise `context: null`, no items. Clients filter and sort (fuzzy) as the user types and call again only on `\`,
`{` or `,`.

- `from`..`to` is replaced by `insert`: from a command's backslash, or after `{` or the last `,`, to `pos`. `cursor` is
  the byte offset in `insert` for the cursor (inside the first `{}`), else the end.
- `before`: the client's text before the cursor (its line suffices), when it has edits the engine lacks; positions are
  then in the client's text.
- Covers the open docs, each rescanned only when its `seq` moved: about 1 ms per call on a 200 KB paper.

## History

Read-only, as Overleaf's History view (routes: `docs/history.md`), on an open project, never blocking sync. Diffs
and trees are cached (64 MB across projects); versions and labels are fetched each time.

- **version group** `{from_v, to_v, start_ts, end_ts, users: [user], labels: [label], paths, ops, origin?}`:
  Overleaf's grouping (same kind, under five minutes apart, cut at labels); `to_v` is the state after it. `paths`:
  docs whose text changed; `ops`: `{op: "add"|"rename"|"remove", path, new_path?, at_v}`; `origin` as Overleaf gives
  it (`{kind: "upload"}`, `{kind: "file-restore", path, version, timestamp}`, ...). Times are ms since 1970.
- **user** `{user_id, name, initials, hue, mine}`: `hue` in degrees as the browser computes it (200 for yourself);
  unknown users are `{user_id: null, name: "Anonymous"}`.
- **label** `{id, comment, version, user_id, name, created_at, mine}`.
- `history.updates`: newest first, at least `min_count` groups (default 25); `next_before` (null at the end) pages
  back. `head` is on the first page only.
- `history.tree`: every file at either version; `op` is `edited`, `added`, `renamed` (`new_path` at `to`), `removed`
  (with `deleted_at_v`) or null. `editable: false` is binary.
- `history.diff`: `path` is the name at `to`; `text` is the file at `to` with deleted text left in. Chunks are
  `{kind: "same"|"insert"|"delete", start, end, user?, ts?}` in UTF-8 bytes of `text` (same-user neighbours merged).
  `inserted`, `deleted` count bytes. Binary: `binary: true`, no text.
- `history.file`: the text at one version (`history.diff` with `from == to`).
- `history.files_at`: every file with its git blob `hash` and `kind` (`binary`, `text`, `unknown`); `hash` is null for
  text edited since added (use `history.file`). Replayed from the newest chunk if it holds the version
  (`from: "latest_chunk"`), else from version 0 (`from: "changes"`); cached, so another version costs at most one
  request.
- `history.blob`: the blob as `file` in the shared blob store (all projects and servers, hash-checked), fetched only
  if missing (`cached`). `$TAUDOT_BLOB_CACHE`, default `~/Library/Caches/Taudot/blobs/<2 hex>/<hash>` (elsewhere
  `$XDG_CACHE_HOME/taudot/blobs`), LRU above `$TAUDOT_BLOB_CACHE_BYTES` (2 GiB). Copy the file; it may be evicted.
- `history.zip_files`: fallback for `history.blob`. Fetches the version's zip (Overleaf allows 30 an hour) and stores
  only `paths`; one not in the zip gets null `hash` and `file`.

## Notifications

| Method | Params |
|---|---|
| `doc.changed` | `{doc_id, seq, edits, author: {user_id, name, initials}, origin: "local"\|"remote", source?: "disk"}` |
| `doc.state` | `{doc_id, state: "idle"\|"pending"\|"inflight", unconfirmed, oldest_unconfirmed_ms, readonly, seq}` |
| `ranges.changed` | `{doc_id, seq, ranges}` |
| `presence.changed` | `{project_id, users: [{client_id, user_id, name, initials, doc_id, pos, seq}]}` |
| `thread.changed` | `{project_id, thread_id, thread}` |
| `review.track` | `{project_id, on, overleaf}` |
| `activity` | `{project_id, kind, text, doc_id?, ts}` |
| `project.connection` | `{project_id, connection, reason?}` |
| `clone.progress` | `{project_id, folder, stage: "connecting"\|"downloading"\|"done", text}` |
| `engine.lagged` | `{missed}`: notifications were dropped; reopen docs |

- `doc.changed`, `doc.state` and `ranges.changed` go to the doc's subscribers, `clone.progress` to the caller, the
  rest to `activity.subscribe` subscribers. `doc.state`'s `seq` is when the state was taken; it may arrive after a
  later `doc.edit` result.
- `origin: "local"`: made through this engine by another of its clients. `source: "disk"`: made by the engine from
  the mirror folder's file (changed outside Taudot). `author` fields are null when the server didn't say (e.g. a
  rebase).
- `activity` kinds from the engine: `relogin` (session expired, logged in again), `rejoin` and `rebase` (doc fetched
  afresh, unconfirmed edits carried over), `restored` (replayed from backup), `conflict`, `error`. Others are Overleaf
  events passed through. `ts` in ms since 1970.

## Recovery

- Unconfirmed edits go to `~/.taudot/backup/<project_id>/<doc_id>.json` at most every 2 s and at shutdown, deleted
  once all are confirmed. On the next open the engine catches up from the backed-up version (edits the server already
  has count as confirmed) and sends the rest; `doc.open` includes them.
- On session expiry the engine logs in again if started with a password (not with only a cookie).
