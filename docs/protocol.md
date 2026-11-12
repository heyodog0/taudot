# Overleaf real-time protocol

Checked against Overleaf CE commit `e039ad2` (tip of `main` on 2026-11-01) and run against CE 6.3.0
(`sharelatex/sharelatex:6.3.0`) in `docker/`. Paths are relative to `github.com/overleaf/overleaf`. Claims are
marked **verified** (read in Overleaf's source, file named), **observed** (seen on the local CE 6.3.0, or in a working
third-party client where it says so) or **unverified** (our inference). `test:` names the script in `harness/tests/`
that checks it against CE (`harness/tests/run.sh` runs them all).

## Connecting

- **observed.** Auth is the session cookie: `overleaf.sid` on CE, `overleaf_session2` on overleaf.com. `POST /login`
  with JSON `{email, password}` and header `X-CSRF-Token` (from the `ol-csrfToken` meta tag of any page) answers 302
  and rotates the session ID: keep the new `Set-Cookie`. test: `session.ts`.
- **verified** (`services/real-time/app/js/Router.js:273–715`). The project ID goes in the handshake; there is no
  `joinProject` event and no `connectionAccepted`.
  1. `GET /socket.io/1/?projectId=<id>&t=<ms>` with the cookie → `<sid>:60:60:websocket,xhr-polling` (60 s heartbeat
     and close timeout, observed).
  2. WebSocket to `/socket.io/1/websocket/<sid>?projectId=<id>` with the cookie. No CSRF token or Origin check
     (observed).
  3. The server sends `1::`, then `joinProjectResponse {publicId, project, permissionsLevel, protocolVersion}`.
     `publicId` is this connection's ID, sent back as `meta.source` on its ops. Without a session:
     `connectionRejected {message: "not authorized"}`.
- **observed.** socket.io 0.9 frames are `type:id:endpoint:data`: `1` connect, `2` heartbeat (echo it), `5` event
  (`5:3+::{"name":…,"args":[…]}` asks for an ack), `6` ack (`6:::3+[…]`), `0` disconnect (client:
  `harness/lib/socket.ts`).
- **verified** (`Router.js:22–80`). `joinDoc` options and `applyOtUpdate` updates have strict schemas: an unknown field
  is refused in the ack (`Unrecognized key: "extra"`) and the client disconnected (observed). test: `classic-basics.ts`.

### Session expiry

- **observed.** The session is redis key `sess:<id>`, 5-day TTL (`OVERLEAF_COOKIE_SESSION_LENGTH`), reset by any web
  request (verified, `cookieRollingSession: true` in `services/web/config/settings.defaults.js`) but not by socket
  traffic. A logged-out `GET /user/settings` redirects to `/login`; Taudot uses it to check a session
  (`taudot login --check`) and, hourly, to keep it alive. test: `session.ts`.
- **observed.** With the session gone, a new socket gets `connectionRejected {message: "invalid session"}`.
- **verified.** CE has no long-lived API token (personal access tokens are Server Pro / SaaS).
- **observed.** The `/project` page has `ol-user_id` and `ol-usersEmail` meta tags; `ol-user` has no name. Names come
  from `owner` and `members` in `joinProjectResponse`, and from `clientTracking`.
- **observed on overleaf.com** (a throwaway project): REST and socket (`wss://www.overleaf.com`), the classic doc,
  file transfer, folder create and delete, and the file events behave as on CE.
- **observed** in Workshop (`src/api/base.ts` `updateCookies`), and copied by Taudot: fetch `/socket.io/socket.io.js`
  first and add the cookie it sets (load-balancer affinity?). **unverified** that overleaf.com needs it; its session
  length.

## Joining a document

**verified** (`services/real-time/app/js/WebsocketController.js:201`):

```
joinDoc(docId, fromVersion, options) -> [err, snapshot, version, ops, ranges, type, {canSkipLeaveDoc}]
options: { encodeRanges: true, supportsHistoryOT: true, age?: <ms since last seen> }   (strict: nothing else)
```

- `fromVersion = -1`: whole doc; any other value also returns the `ops` since.
- **verified + observed.** Redis keeps a doc's last ops for an hour, trimmed to 100 before each push, so 101 survive
  (`RedisManager.js` `DOC_OPS_TTL`, `DOC_OPS_MAX_LENGTH`). Older ones fail with the ack error `doc updater could not
  load requested ops` (`Errors.js:3`, `Router._handleError`): do a full join and rebase local edits. test:
  `classic-basics.ts`.
- `type` is `sharejs-text-ot` (classic: `snapshot` is lines packed as below; `ranges` holds comments and tracked
  changes) or `history-ot` (**observed**: `snapshot` is the raw `StringFileData` `{content, comments?,
  trackedChanges?}`, unpacked; `ranges` is `{}`; test: `historyot-snapshot.ts`).
- `leaveDoc` does nothing: ops go to the project room, clients filter by doc (`WebsocketController.js:370`).
- Users with restricted access get no comments in `ranges`.

## The two edit formats

**verified.** The document updater picks the format when it loads a doc: `otMigrationStage > 0` means `history-ot`
(`services/document-updater/app/js/PersistenceManager.js:69`; field `projects.overleaf.history.otMigrationStage`, only
ever raised, `ProjectOptionsHandler.setOTMigrationStage` `$max`). Joining a history-ot doc without `supportsHistoryOT`
fails with `client does not support history-ot` (`WebsocketController.js:297`).

### sharejs-text-ot (classic)

- **verified.** Components `{p, i}` insert, `{p, d}` delete, `{p, c, t}` comment on text `c`, thread `t`; any may carry
  `u: true` (undo; `DocumentManager.js:229`). They apply in order, each seeing the ones before.
- **verified** (`WebsocketController.js:290–335`). Only `joinDoc`'s lines and, with `encodeRanges`, range texts
  (`comment.op.c`, `change.op.i`, `change.op.d`) are UTF-8 packed into Latin-1 (`unescape(encodeURIComponent(s))`).
  Op text everywhere else (`applyOtUpdate`, `otUpdateApplied`, catch-up `ops`) is plain (`share-js-doc.ts:109`,
  `document-container.ts:730–750`). test: `classic-basics.ts`.
- **verified.** Positions are UTF-16 code units: a non-BMP character counts 2 (`sharejs/types/text.js`).
- **verified.** Tracked changes: `meta.tc`, 18 hex characters, seeds `RangesTracker`'s change IDs (`Router.js`).

### history-ot (new)

**verified** in `libraries/overleaf-editor-core`, **observed** on CE where a test is named.

- `op` is a list of operations applied in order (`edit_operation_builder.js`): `{textOperation: [...], contentHash?}`;
  `{commentId, ranges: [{pos, length}], resolved?}` adds a comment (test: `historyot-snapshot.ts`);
  `{deleteComment: id}`; `{commentId, resolved}`; `{noOp: true}`.
- A `textOperation` spans the whole doc: positive retains, negative removes, a string inserts; `{i, tracking?,
  commentIds?}` inserts, `{r, tracking}` retains and changes tracking. Retains plus removes must equal the doc length,
  or `ApplyError` (`text_operation.js`). E.g. `[31, "x", 226]`, `[30, -1, 241]`.
- UTF-16 units. Inserts may not contain surrogates (`scan_op.js` `InsertOp`).
- `tracking` is `{type: "insert" | "delete", userId, ts}` (ISO 8601) or `{type: "none"}` (clear). A tracked delete keeps
  the text: `{r: n, tracking: {type: "delete"…}}`. An update of only plain retains, tracked inserts and tracked retains
  needs review permission, not edit (`WebsocketController.js` `_isHistoryOTTrackedChangesUpdate`).
- **Tracked deletes stay in the content and positions count over them** (observed: `content` keeps the deleted text,
  with `trackedChanges: [{range: {pos, length}, tracking}]`). The browser shows content without them
  (`source-editor/utils/tracked-deletes.ts`, verified): a content position inside a tracked delete maps to its start;
  a visible position at a delete's boundary maps **before** the deleted text (observed: typing at visible 6 in
  `hello |big…` sent `[6, "Y", 21]`, giving `hello Ybrave big…`). The engine keeps the full content, edits in content
  positions and gives clients the visible text. test: `historyot-snapshot.ts`.
- Server transform: `EditOperationTransformer.transformMultiple(clientOps, serverOps)`, the client's insert first on
  equal positions, as in classic (`HistoryOTUpdateManager.js`); `dupIfSource` as in classic.
- **observed** (test: `historyot-ranges.ts`, 39 cases, results in `crates/ot2/fixtures/historyot_ranges.json`,
  reproduced by `ot2::filedata`). How ranges move:
  - An insert at a range's start goes before it, strictly inside **splits** it, at its end stays outside. Comments
    don't grow.
  - A remove cuts its span out of every range; a comment left empty stays, `ranges: []`.
  - A retain with `tracking` replaces the span's tracking (any user's, tracked inserts too); `none` clears it. So
    accept = `{r, tracking: none}` on an insert, a remove on a delete; reject the reverse. Plain ops, so they work on
    CE, which lacks classic's `/changes/accept` route.
  - An insert with `tracking` adds a tracked range; with `commentIds` it joins those comments. With `tracking:
    {type: "none"}` it is refused (`Invalid input`).
  - Neighbours merge: comments always, tracked changes of the same kind and user (earlier `ts` kept). A comment with an
    existing ID replaces its ranges.
- **observed** (`ce_review.sh --history-ot`). Overleaf's editor shows text whose tracked delete was rejected only
  after reload.
- **verified.** `contentHash` is SHA-1 of the visible content after the op, no `blob` prefix
  (`history-v1/storage/lib/content_hash.js`); only history-v1 checks it, a mismatch only flags a resync. The browser
  doesn't send it; don't. The update-level `hash` is never checked (`HistoryOTUpdateManager`), so nothing on the
  server catches a drifted history-ot client.

### history-ot versions are wrong for concurrent ops

**observed, Overleaf bug** (test: `historyot-version.ts`, `historyot-stale-browser.ts`).
`HistoryOTUpdateManager.tryApplyUpdate` transforms an old op past newer ones but never sets `update.v` to the version
it was applied at (verified, unchanged on `main`; classic does). Two clients sending at v0 both get confirmations,
broadcasts and catch-up ops saying `v: v0`, though the doc correctly reaches v0 + 2 and `joinDoc`'s `version` is right.

Overleaf's browser drops a broadcast whose `v` is below its own (sharejs `_onMessage`) and silently drifts; our
engine's edits vanish from collaborators' screens the same way. Its next op then fails (`Both operations have to have
the same base length`, disconnect, edit lost; `harness/fuzz.ts`): three browsers typing for 30 s all drifted; two
typing every 3 to 6 s diverged within 20 s. One browser alone, or classic with three, stays in sync. On CE 6.3.0,
history-ot is unusable for two people in the browser.

A history-ot client must:

1. Ignore `v` in `otUpdateApplied`. Count every `otUpdateApplied` for the doc (own or other) as the next version in
   arrival order, and send with `v` = that count.
2. Treat a confirmation after a `dupIfSource` resend as possibly a duplicate (same `{v, doc}` shape either way,
   verified, `DocumentUpdaterController.js:45–105`), and take the version from `joinDoc(docId, lastKnownVersion)`.
3. Not drop or reorder incoming ops by `v`. **unverified**: that the redis channel delivers them in applied order on a
   single-node CE (it did in every test).

**observed** (`crates/engine/src/hist.rs`). The engine does 1 to 3, counts an update seen twice (catch-up and socket)
once by `(meta.source, meta.ts)`, and never resends an unconfirmed op on the same connection: it reconnects, and the
catch-up's `meta.source` says whether the op went through. Two engines typing into one doc for 60 s (about 2,900
edits) stayed in sync with no rejoin; with a browser typing too, the engines matched the server, the browser drifted. test: `ce_two_engines_and_a_browser_converge` on a `--history-ot` project.

### Astral characters (emoji, 𝔸)

Observed on CE 6.3.0; test: `emoji.ts`, `upload-filetypes.ts`.

- **Classic.** The browser turns each surrogate into U+FFFD as typed (`filter-characters.ts`, verified), and so does
  the server for a raw client (`UpdateManager.js:358`, verified). Replace locally too, or the copy drifts.
- **history-ot, raw client.** A surrogate in an insert gets `otUpdateError "inserted text contains non BMP characters"`
  and a disconnect. Replace with U+FFFD first.
- **history-ot, browser (Overleaf bug).** Typing an emoji (Playwright `keyboard.type`, the emoji picker's `insertText`
  path; real keyboards unverified) throws `ApplyError: The operation's base length must be equal to the string's
  length`; the tab sends nothing more until reload.
- **Uploads.** A text file with a surrogate or NUL, or at the max doc length, becomes a binary file
  (`Features/Uploads/FileTypeManager.mjs` `isEditable`, verified); Latin-1 files become docs. So the engine must not
  create a doc from a local file with astral characters.

## Sending an edit

**verified** (`WebsocketController.js:498`, `Router.js` schema):

```
applyOtUpdate(docId, { doc, op, v, lastV?, hash?, meta?: {tc?}, dupIfSource? }, callback)
```

- `v` is the version the op was made against; the browser adds `lastV`, its previous op's (observed). `op` must be
  non-empty.
- The server sets `meta.source` (your connection) and `meta.user_id` (your name in history). `meta` accepts only `tc`.
- **The callback only means "queued"**, not confirmed.
- Comment-only ops need view access, tracked-change ops review, anything else edit. Failing disconnects after 100 ms.
- **No rate limits on CE.** Verified: none on `applyOtUpdate`; `RateLimitManager` only queues; only `joinProject` can
  return 429. Observed: 50 unawaited ops confirmed in about 70 ms (test: `classic-basics.ts`). Login is limited per
  email (429 after a dozen in a few minutes). **unverified** on overleaf.com.

## Confirmation and broadcast

**verified** (`services/real-time/app/js/DocumentUpdaterController.js:45–105`):

- The sender gets `otUpdateApplied {v, doc}`, the confirmation (project-wide; filter by `doc`).
- Others get `{doc, op, v, meta: {source, user_id, ts}}`.
- A duplicate (`dup`) goes only to its sender, as a confirmation with the **original** op's version, possibly older
  than the client's (`model.js`). The browser ignores confirmations below its version (`sharejs.js` `_onMessage`).
  test: `classic-basics.ts`.
- Catch-up ops carry `meta: {source, user_id, ts}` in both formats (observed), so **after a reconnect,
  `joinDoc(docId, inflight.v)` tells whether the inflight op was applied**: one of them has a `meta.source` it was
  sent under. Only while the ops are kept (101, 1 hour); the history API lists users, not connections.

## Resending safely

**verified** (`services/web/frontend/js/features/ide-react/editor/share-js-doc.ts:483–515`):

- Without a timely confirmation the browser resends the same op with `dupIfSource: [currentConnectionId,
  ...earlierConnectionIds]`. If the server applied it from one of those (`sharejs/server/model.js:181`;
  `HistoryOTUpdateManager.js`), it marks it `dup` and only confirms. Keep every connection ID an op was sent under.
  test: `classic-basics.ts`.
- The browser waits `INFLIGHT_OP_TIMEOUT` for a queued out-of-order update (`pushOntoQueue`). Rejoin if the queue
  stays non-empty that long.

## Hash checks (classic)

- **verified + observed.** Git blob SHA-1 of the doc **after** the op, `sha1("blob " + length + "\0" + utf8(content))`,
  `length` in UTF-16 units (`ShareJsUpdateManager._computeHash`); a byte-length hash is refused. Checked only when `v`
  is the current version; mismatch → `Invalid hash` (`ShareJsUpdateManager.js:102`). test: `classic-basics.ts`.
- **observed.** CE's browser sends one (`ol-useShareJsHash`) at most every 5 s.

## Errors and limits

**verified.** A document updater error sends `otUpdateError(error, message)` to clients on the doc, then disconnects
them (`DocumentUpdaterController.js:118`).

| Message | Meaning | test |
|---|---|---|
| `Delete component '…' does not match deleted text '…'` | Our copy has drifted | |
| `Invalid hash` | Same, caught by the hash (classic) | `classic-basics.ts` |
| `Op too old` | Too far behind; rejoin | |
| `update is too large` | Split the edit. Confirmed, then error and disconnect | |
| `Update takes doc over max doc size` | The doc would pass 2 MB | |
| `ot type mismatch` | The doc changed format under us (below) | `migration.ts` |
| `inserted text contains non BMP characters` | history-ot insert with a surrogate | `emoji.ts` |
| `Both operations have to have the same base length` | history-ot op from a drifted client | `fuzz.ts` |
| `client does not support history-ot` | Join with `supportsHistoryOT` (ack error) | |

Other ack errors: schema failures (`Unrecognized key: "…"`) and `joinDoc`'s `doc updater could not load requested
ops`. **verified**: max doc length 2 MB, max update size derived from it
(`services/real-time/config/settings.defaults.cjs:126`).

## A project moving to history-ot while open

**observed** (test: `migration.ts`). Classic ops work until the document updater unloads the doc (flush or idle);
then the next one gets `otUpdateError "ot type mismatch"` and a disconnect, unapplied, and a rejoin returns
`history-ot`. The browser shows "Out of sync … Reload editor". Our engine keeps the edit, rejoins and resends it as a
history-ot op.

## Other socket events

File-tree changes go through REST (`Features/Editor/EditorRouter.mjs`, verified) with `X-CSRF-Token`; every client in
the project gets an event (`EditorController.mjs`, verified; observed, test: `entity-events.ts`). Spelling is
Overleaf's.

| REST call | Event to others |
|---|---|
| `POST /project/:id/doc {name, parent_folder_id}` → `{_id, name}` | `reciveNewDoc(folderId, {_id, name}, source, userId)` |
| `POST /project/:id/folder {name, parent_folder_id}` | `reciveNewFolder(parentId, {_id, name, docs, fileRefs, folders}, userId)` |
| `POST /project/:id/:type/:entityId/rename {name}` | `reciveEntityRename(entityId, newName)` |
| `POST /project/:id/:type/:entityId/move {folder_id}` | `reciveEntityMove(entityId, folderId)` |
| `DELETE /project/:id/doc/:entityId` (also `file`, `folder`) | `removeEntity(entityId, source)` |
| `POST /Project/:id/upload?folder_id=` ([Binary files](#binary-files)) | `reciveNewFile(folderId, file, "upload", linkedFileData, userId)` |

`:type` is `doc`, `file` or `folder`. Doc creation is rate limited per project (`addDocToProject`).

Cursors, **observed** (test: `cursors.ts`):

| Event | Shape |
|---|---|
| `clientTracking.updatePosition({row, column, doc_id})` (emit) | Our cursor. Strict schema (`Router.js`, verified) |
| `clientTracking.clientUpdated` (to others) | `{row, column, doc_id, id: publicId, user_id, email, name}` |
| `clientTracking.getConnectedUsers` (emit, ack) | `[{client_id, user_id, first_name, last_name, email, cursorData?, connected, client_age, last_updated_at}]`, us included |
| `clientTracking.clientDisconnected` (to others) | `(publicId)` |

Chat and settings, **observed** (test: `chat-settings.ts`; routes in `router.mjs`, events in `ChatController.mjs`,
`EditorController.mjs`, verified):

| REST call | Event to everyone |
|---|---|
| `POST /project/:id/messages {content}` (204); `GET …/messages?limit=N` lists | `new-chat-message({id, content, timestamp, user_id, room_id, user: {id, first_name, email}})` |
| `POST /project/:id/settings {compiler}` (204) | `compilerUpdated(compiler)` |
| `POST /project/:id/settings {spellCheckLanguage}` | `spellCheckLanguageUpdated(language)` |
| other fields of `…/settings` and `…/settings/admin` (not tested) | `rootDocUpdated`, `imageNameUpdated`, `projectNameUpdated`, … |

`forceDisconnect` (server closing the connection) is **observed** only in Workshop (`src/api/socketio.ts`).

### Binary files

**verified** (`Features/Uploads/UploadsRouter.mjs`, `ProjectUploadController.mjs`, `router.mjs`), **observed** (test:
`files.ts`):

- Download: `GET /Project/:id/file/:fileId` (capital P), read access.
- Upload: `POST /Project/:id/upload?folder_id=<id>`, multipart `name`, `type?`, `relativePath?`, file as `qqfile`,
  `X-CSRF-Token`. → `{success: true, entity_id, entity_type: "file" | "doc", hash?}`, or 422 `{success: false, error}`
  (`invalid_filename`, `duplicate_file_name`, `project_has_too_many_files`, `folder_not_found`). 500 per 15 minutes
  per project (`fileUpload`); `Settings.maxUploadSize` 50 MB on CE.
- Text becomes a doc (`reciveNewDoc`, source `"upload"`), anything else a file (`isEditable`). An existing **file** is
  replaced under a **new ID** (`removeEntity(oldId, "upload")`, `reciveNewFile`); an existing **doc** keeps its ID and
  gets the new content (`upsertDoc`), so never upload over a doc you edit with ops.
- `relativePath` (`dir/sub/name`) creates missing folders, each with `reciveNewFolder(parentId, folder, null)`.
- A file's `hash` (`fileRefs`, `reciveNewFile`, upload answer) is `sha1("blob " + length + "\0" + bytes)`, as `git
  hash-object`.
- Deleting a folder sends one `removeEntity(folderId, "editor")`.
- **unverified**: overleaf.com's upload and rate limits.

## Comments

**verified** (`services/web/frontend/js/features/review-panel/context/threads-context.tsx`):

- The commented text is a range: `{p, c, t}` in classic, `{commentId, ranges}` in history-ot (observed, test:
  `historyot-snapshot.ts`). The server moves it as text changes.
- **Not on CE.** The thread routes below are Server Pro / overleaf.com only: not in CE's `router.mjs` or modules
  (verified at `e039ad2`), `GET /project/:id/threads` is 404 (observed). Stock CE has comment ranges but no
  conversations.
- **Our local CE has them** through `harness/ce-threads`, a test-only module (AGPL, never shipped) that `docker/up.sh`
  installs; re-run `harness/ce-threads/install.sh` after recreating the container. Observed there: `replicate.ts check`
  reads threads and messages; `ce_review.sh` adds a comment with its thread.
- Conversations live in the chat service (**observed** in Workshop and `threads-context.tsx`):

| Action | Call |
|---|---|
| Load threads | `GET /project/:id/threads` |
| New comment | `POST /project/:id/thread/:threadId/messages`, then send the range op |
| Reply | `POST /project/:id/thread/:threadId/messages` |
| Edit or delete a message | `POST …/messages/:msgId/edit`, `DELETE …/messages/:msgId` |
| Resolve, reopen | `POST /project/:id/doc/:docId/thread/:threadId/resolve`, `…/reopen` |
| Delete a thread | `DELETE /project/:id/doc/:docId/thread/:threadId` |

Socket events: `new-comment`, `edit-message`, `delete-message`, `resolve-thread`, `reopen-thread`, `delete-thread`,
`new-comment-threads`.

## What the browser does that we must also do

**verified** (`services/web/frontend/js/features/ide-react/editor/`):

- One op in flight, later edits queued, incoming ops transformed against both (`share-js-doc.ts`).
- Out-of-order updates queued until the expected version arrives (`processUpdateFromServerInOrder`), not on
  history-ot.
- Unsent edits backed up every 2 s with version and snapshot, replayed after reload (`offline-doc-backup.ts`).
- **observed.** Edits held about 2 s before sending.

## Open questions

1. **overleaf.com: the history-ot version and emoji bugs, rate limits, session length.** Needs an overleaf.com
   project in history-ot (we can't set that). Run `historyot-version.ts`, `emoji.ts`, `session.ts` and
   `classic-basics.ts` with `TAUDOT_ENV_FILE` set to its credentials.
2. **Order of history-ot broadcasts** on multi-node deployments (rule 3); single-node CE can't show it.
