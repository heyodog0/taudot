# Overleaf real-time protocol

Checked against Overleaf CE commit `e039ad2` (2026-08-28, still the tip of `main` on 2026-11-01) and run against CE
6.3.0 (`sharelatex/sharelatex:6.3.0`) in `docker/`. Paths are relative to `github.com/overleaf/overleaf`. Each claim
is marked:

- **verified**: read in Overleaf's source, with the file named
- **observed**: seen on the local CE 6.3.0, or in a working third-party client where it says so
- **unverified**: our inference, check before relying on it

A `test:` note names the script in `harness/tests/` that checks the claim against CE. `harness/tests/run.sh` runs
them all; see `harness/README.md`.

Services involved: `services/real-time` (the socket), `services/document-updater` (applies ops), `services/chat`
(comment threads), `services/web` (REST, and the browser editor in `services/web/frontend`), `services/history-v1`
and `services/project-history` (history).

**Two Overleaf bugs matter to us** (both observed on CE 6.3.0, both in history-ot only): concurrent ops carry the
wrong version ([history-ot versions](#history-ot-versions-are-wrong-for-concurrent-ops)), and an emoji typed in the
browser breaks the tab ([astral characters](#astral-characters-emoji-𝔸)).

## Connecting

- **observed.** Auth is the browser session cookie: `overleaf.sid` on CE, `overleaf_session2` on overleaf.com
  (Workshop). Log in with `POST /login`, JSON `{email, password}` and the `X-CSRF-Token` header (the token is in the
  `ol-csrfToken` meta tag of any page). Login answers 302 and rotates the session ID: keep the new `Set-Cookie`.
  test: `session.ts`.
- **verified** (`services/real-time/app/js/Router.js:273–715`). Only one connection style exists: the project ID goes
  in the handshake. There is no `joinProject` event and no `connectionAccepted`.
  1. `GET /socket.io/1/?projectId=<id>&t=<ms>` with the cookie returns `<sid>:60:60:websocket,xhr-polling`
     (heartbeat and close timeout 60 s, observed).
  2. WebSocket to `/socket.io/1/websocket/<sid>?projectId=<id>`, with the cookie. No CSRF token, no Origin check
     (observed).
  3. The server sends `1::`, then the event `joinProjectResponse` with
     `{publicId, project, permissionsLevel, protocolVersion}`. `publicId` is this connection's ID; ops sent on it carry
     it as `meta.source`.
  - Without a logged-in session the server sends `connectionRejected {message: "not authorized"}`.
- **observed.** Transport is socket.io 0.9. Frames are `type:id:endpoint:data`: `1` connect, `2` heartbeat (echo
  it), `5` event (`5:3+::{"name":…,"args":[…]}` asks for an ack), `6` ack (`6:::3+[…]`), `0` disconnect.
  `harness/lib/socket.ts` is a 200-line client.
- **verified** (`Router.js:22–80`). `joinDoc` options and `applyOtUpdate` updates are strict schemas: an unknown field
  is refused in the ack (`{message: 'Unrecognized key: "extra"'}`) and the client is disconnected (observed).
  test: `classic-basics.ts`.

### Session expiry

- **observed.** The session is redis key `sess:<id>` with a 5-day TTL (`OVERLEAF_COOKIE_SESSION_LENGTH` on CE). It
  rolls: any web request resets it (verified, `cookieRollingSession: true` in `services/web/config/settings.defaults.js`).
  Socket traffic does not. A long-running engine must make a cheap web request (e.g. `GET /user/settings`) now and
  then, or it is logged out 5 days after its last one. test: `session.ts`.
- **observed** (engine agent). Once the session is gone from redis, a new socket gets `connectionRejected {message:
  "invalid session"}`. Log in again then.
- **verified.** CE has no long-lived token for non-browser clients; personal access tokens are Server Pro / SaaS.
- **observed** (engine agent). The `/project` page carries `ol-user_id` and `ol-usersEmail` meta tags (who we are);
  `ol-user` has no name. Names come from the project's `owner` and `members` in `joinProjectResponse`, and from
  `clientTracking` (below).
- **unverified.** overleaf.com's session length.
- **observed on overleaf.com** (2026-11-02, the owner's throwaway project, Taudot engine): a browser session cookie
  `overleaf_session2` works for REST and the socket; the handshake and WebSocket are on `www.overleaf.com` itself
  (`/socket.io/1/?projectId=…`, `wss://`), `joinProjectResponse` as on CE; the project's doc was
  `sharejs-text-ot`. Binary download, upload, folder create, folder delete, `reciveNewFile`/`reciveNewDoc`, and file
  `hash` = git blob SHA-1 all behave as on CE. Not tested: whether the `socket.io.js` cookie below is needed.
- **observed** in Workshop (`src/api/base.ts` `updateCookies`): before connecting the socket it fetches
  `/socket.io/socket.io.js` and adds the cookie that answer sets to its cookie header. Presumably overleaf.com's
  load-balancer affinity, so the handshake and the WebSocket reach the same real-time node. Taudot does the same
  (harmless on CE). **unverified** that overleaf.com needs it.
- **observed** on CE 6.3.0. A logged-out `GET /user/settings` redirects to `/login`; Taudot uses that to check a
  stored session (`taudot login --check`) and, hourly, to keep the rolling session alive.

## Joining a document

**verified** (`services/real-time/app/js/WebsocketController.js:201`):

```
joinDoc(docId, fromVersion, options) -> [err, snapshot, version, ops, ranges, type, {canSkipLeaveDoc}]
options: { encodeRanges: true, supportsHistoryOT: true, age?: <ms since last seen> }   (strict: nothing else)
```

- `fromVersion = -1` returns the whole document. Any other value also returns `ops`, the updates since that version, so
  a reconnecting client can catch up instead of reloading.
- **verified + observed.** The document updater keeps a doc's last ops in redis for an hour, trimmed to 100 before each
  push, so 101 survive (`RedisManager.js` `DOC_OPS_TTL`, `DOC_OPS_MAX_LENGTH`). Asking for older ones fails with the
  ack error `{message: "doc updater could not load requested ops"}`, not by class name (`Errors.js:3`,
  `Router._handleError`). Then do a full join and rebase local edits onto it. test: `classic-basics.ts`.
- `type` is `sharejs-text-ot` or `history-ot`, see below. `snapshot` depends on it:
  - classic: a list of lines, UTF-8 packed in Latin-1 (below). `ranges` holds comments and tracked changes.
  - history-ot (**observed**): the raw `StringFileData`, `{content, comments?, trackedChanges?}`, not packed;
    `ranges` is `{}`. test: `historyot-snapshot.ts`.
- `leaveDoc` does nothing on the server now. Applied ops go to the whole project room and clients filter by doc ID
  (comment at `WebsocketController.js:370`).
- Users with restricted access get no comments in `ranges`.

## The two edit formats

**verified.** The document updater picks the format per project when it loads a doc from mongo: `otMigrationStage > 0`
means `history-ot` (`services/document-updater/app/js/PersistenceManager.js:69`). The field is
`projects.overleaf.history.otMigrationStage`; web only ever raises it (`ProjectOptionsHandler.setOTMigrationStage`,
`$max`). A client that joins a `history-ot` doc without `supportsHistoryOT` gets the error
`client does not support history-ot` (`WebsocketController.js:297`).

### sharejs-text-ot (classic)

- **verified.** Op components: `{p, i}` insert, `{p, d}` delete, `{p, c, t}` comment on text `c` with thread ID `t`.
  Any of them may carry `u: true` (undo; `DocumentManager.js:229`, read by `libraries/ranges-tracker`). A list of
  components applies in order, each one seeing the result of the ones before it.
- **verified** (`WebsocketController.js:290–335`). Only `joinDoc`'s lines and, with `encodeRanges`, the range texts
  (`comment.op.c`, `change.op.i`, `change.op.d`) are UTF-8 bytes packed into Latin-1 characters,
  `unescape(encodeURIComponent(s))`. Decode those on receipt. Op text in `applyOtUpdate`, in `otUpdateApplied` and in
  catch-up `ops` is plain JSON text (the browser decodes only lines and ranges: `share-js-doc.ts:109`,
  `document-container.ts:730–750`). test: `classic-basics.ts`.
- **verified.** Positions are JavaScript string indexes (UTF-16 code units), so a character outside the Basic
  Multilingual Plane counts as 2 (`services/document-updater/app/js/sharejs/types/text.js` slices strings).
- **verified.** Tracked changes: set `meta.tc` on the update, 18 hex characters (`Router.js` schema: the first 18
  characters of an ObjectId, the seed `RangesTracker` builds change IDs from).

### history-ot (new)

**verified** in `libraries/overleaf-editor-core` (ot-core, round 1), **observed** on CE where a test is named.

- An update's `op` is a list of edit operations, applied in order, each one of (`edit_operation_builder.js`):
  - `{textOperation: [...], contentHash?}` a text edit
  - `{commentId, ranges: [{pos, length}], resolved?}` add a comment (test: `historyot-snapshot.ts`)
  - `{deleteComment: id}`, `{commentId, resolved}` (set state), `{noOp: true}`
- A `textOperation` covers the whole document, start to end: a positive number retains, a negative number removes that
  many characters, a string inserts. Object forms: `{i, tracking?, commentIds?}` insert, `{r, tracking}` retain that
  changes tracking. Retained plus removed lengths must equal the document length exactly, or it throws `ApplyError`
  (`text_operation.js` `apply`). Example: `[31, "x", 226]`, `[30, -1, 241]`.
- Units are UTF-16 code units, like classic. Inserts may not contain surrogates (`scan_op.js` `InsertOp`), see
  [astral characters](#astral-characters-emoji-𝔸).
- `tracking` is `{type: "insert" | "delete", userId, ts}` (`ts` ISO 8601) or `{type: "none"}` to clear it (accept or
  reject). A tracked insert is `{i, tracking: {type: "insert"…}}`. A tracked delete keeps the text:
  `{r: n, tracking: {type: "delete"…}}`. Real-time treats an update of only plain retains, tracked inserts and tracked
  retains as needing review permission, not edit (`WebsocketController.js` `_isHistoryOTTrackedChangesUpdate`).
- **Tracked deletes stay in the content, and positions count over them** (observed: after a tracked delete of
  `brave ` in `hello brave new world`, `content` is still the whole text, with
  `trackedChanges: [{range: {pos, length}, tracking}]`). The browser shows the content without tracked-deleted text
  and maps between the two (`source-editor/utils/tracked-deletes.ts`, verified):
  - content → visible: a position inside a tracked delete maps to where the delete starts.
  - visible → content: at a delete's boundary an insert goes **before** the deleted text (observed: typing at
    visible 6 in `hello |big…` sent `[6, "Y", 21]`, giving `hello Ybrave big…`).
  - The engine keeps the full content and the tracked changes, edits in content positions, and gives clients the
    visible text, mapping offsets the same way. test: `historyot-snapshot.ts`.
- Server transform: `EditOperationTransformer.transformMultiple(clientOps, serverOps)`, so on equal positions the
  client's insert goes first, as in classic (`HistoryOTUpdateManager.js`). `dupIfSource` works as in classic.
- **observed** (CE 6.3.0, test: `historyot-ranges.ts`, 39 cases; the results are `crates/ot2/fixtures/historyot_ranges.json`
  and `ot2::filedata` reproduces all of them). How the server moves ranges:
  - An insert at a range's start goes before it; one strictly inside **splits** it (a comment gets two ranges, a
    tracked change two changes); one at its end stays outside. Comments don't grow.
  - A remove cuts what it covers out of every range. A comment left with no text is kept, with `ranges: []`.
  - A retain with `tracking` replaces whatever tracking its span had, any user's, a tracked insert's included;
    `{type: "none"}` just clears it. Accepting is therefore `{r, tracking: none}` for an insert and a remove for a
    delete; rejecting is the other way round. These are ordinary ops: they work on CE, which has no REST route for
    accepting (classic's `/changes/accept`).
  - An insert with `tracking` adds a tracked range; with `commentIds` it adds itself to those comments.
  - Neighbouring ranges merge: a comment's always, tracked changes when kind and user match (the earlier `ts` is
    kept). Adding a comment whose ID exists replaces its ranges; `{commentId, resolved}` sets `resolved`;
    `{deleteComment}` removes it.
  - An insert with `tracking: {type: "none"}` is refused (`Invalid input`).
- **observed** (CE 6.3.0, `ce_review.sh --history-ot`). Overleaf's editor doesn't show text whose tracked delete was
  rejected (tracking cleared) until the page reloads. The server has it at once.
- **verified.** `contentHash` on a `textOperation` is SHA-1 of the visible content (tracked deletes filtered) after the
  op, plain (no `blob` prefix) (`services/history-v1/storage/lib/content_hash.js`). Only history-v1 checks it, when it
  persists history; a mismatch logs a warning and marks the project for a history resync. The client never hears
  about it. The browser does not send one. Don't send it.
- **verified.** The update-level `hash` (classic's blob SHA-1) is accepted on history-ot updates but never checked:
  `HistoryOTUpdateManager` has no hash check. So nothing on the server catches a history-ot client that has drifted.

### history-ot versions are wrong for concurrent ops

**observed on CE 6.3.0, Overleaf bug** (test: `historyot-version.ts`, `historyot-stale-browser.ts`).

`HistoryOTUpdateManager.tryApplyUpdate` transforms an op made at an old version past the newer ones but never sets
`update.v` to the version it was applied at (verified, unchanged on `main`). Classic does. So when two clients send
at the same version v0:

- both confirmations say `v: v0`, the broadcast to the other client says `v: v0`, and catch-up from v0 returns both
  ops with `v: v0`. The doc correctly ends at v0 + 2 with both edits, and `joinDoc`'s `version` is right.
- Overleaf's own browser drops a broadcast whose `v` is below its version (sharejs `_onMessage`). A browser that has
  already counted the other op misses this one and silently drifts from the server; its later edits are still
  confirmed, and no hash check notices. Classic stays in sync in the same test. So two people typing at once in a
  history-ot doc can lose each other's edits on screen until one reloads. Our engine's edits are lost on collaborators'
  screens the same way whenever they cross one of theirs.
- It gets worse from there (`harness/fuzz.ts`, observed): once a browser has drifted, its next op has the wrong base
  length after the server transforms it, and the server answers `otUpdateError "Both operations have to have the same
  base length"` and disconnects it, losing that edit. Three browsers typing for 30 s left the server at v4 with every
  browser out of sync; two browsers each typing every 3 to 6 s diverged within 20 s. One browser alone stays in sync,
  and classic stays in sync with three. So on CE 6.3.0 history-ot is not usable for two people editing one doc in
  the browser, whatever our engine does.

What a history-ot client must do instead (classic is unaffected):

1. Never use `v` from `otUpdateApplied` on a history-ot doc. Count instead: every `otUpdateApplied` for the doc, our
   own confirmation or someone else's op, is the next version, in arrival order. Send ops with `v` = that count.
2. A confirmation after a resend with `dupIfSource` may be a duplicate (nothing applied, verified: same
   `{v, doc}` shape either way, `DocumentUpdaterController.js:45–105`). After one, take the version from
   `joinDoc(docId, lastKnownVersion)`: its `version` is right, and its ops are in order.
3. Don't drop or reorder incoming history-ot ops by `v`. **unverified**: that the project's redis channel delivers
   them in the order applied on a single-node CE (it did in every test).

**observed** (CE 6.3.0, the engine since 2026-11-03, `crates/engine/src/hist.rs`). The engine follows 1 to 3 and
adds two rules. Updates are told apart by `(meta.source, meta.ts)`, so one seen in a catch-up and again on the
socket counts once. An unconfirmed op is never resent on the same connection: the engine reconnects instead, and the
catch-up's `meta.source` tells whether the op went through. With that, two engines typing at once into one
history-ot doc for 60 s (about 2,900 edits, v2196) stayed in sync with the server with no rejoin or rebase. With
Overleaf's browser typing too (about 300 edits, two runs) the engines still matched the server; the browser drifted
both times, with no `otUpdateError` seen. Test: `ce_two_engines_and_a_browser_converge` on a `--history-ot` project.

### Astral characters (emoji, 𝔸)

All observed on CE 6.3.0; test: `emoji.ts`, `upload-filetypes.ts`.

- **Classic.** The browser replaces each surrogate code unit with U+FFFD as it is typed (`filter-characters.ts`,
  verified), so an emoji is sent as two U+FFFD and positions stay in UTF-16 units. A raw client may send an emoji:
  the server stores two U+FFFD in its place (`UpdateManager.js:358`, verified). Our client must make the same
  replacement locally before sending, or its copy drifts and the next delete or hash fails.
- **history-ot, raw client.** An insert with a surrogate is refused: `otUpdateError "inserted text contains non BMP
  characters"`, then a disconnect. Replace surrogates with U+FFFD before sending.
- **history-ot, browser (Overleaf bug).** Typing an emoji (Playwright `keyboard.type`, the same `insertText` path as
  the macOS emoji picker, unverified for real keyboards) throws `ApplyError: The operation's base length must be equal
  to the string's length` in the page. Sometimes the two U+FFFD are sent first, but the editor and the server differ
  afterwards, and nothing more is sent from that tab: a plain letter typed after it never leaves. Collaborators should
  expect a tab that has typed an emoji into a history-ot doc to be dead until reload.
- **Uploads.** A text file with any surrogate or NUL, or as long as the max doc length, becomes a binary file, not a
  doc (`Features/Uploads/FileTypeManager.mjs` `isEditable`, verified). Latin-1 files are detected and stored as docs.
  This is why round 1's `sections/unicode.tex`, which first held emoji, seeded as a binary file. The engine must not
  create a doc from a local file with astral characters: it becomes a binary file and can't be edited live.

## Sending an edit

**verified** (`WebsocketController.js:498`, `Router.js` schema):

```
applyOtUpdate(docId, { doc, op, v, lastV?, hash?, meta?: {tc?}, dupIfSource? }, callback)
```

- `v` is the document version the op was made against. The browser adds `lastV`, the version of its previous op
  (observed).
- The server overwrites `meta.source` with your connection ID and `meta.user_id` with your session's user. That is what
  puts your name in history. `meta` accepts only `tc`.
- **The callback only means "queued".** It is not the confirmation. `op` must be non-empty.
- Permission depends on the op. Comment-only ops need view access, tracked-change ops need review access, anything else
  needs edit access. Failing the check disconnects the client after 100 ms.
- **Rate limits: none on CE.** Verified: no limiter on `applyOtUpdate` in real-time; the document updater's
  `RateLimitManager` limits worker concurrency (queues, never rejects). Only `joinProject` can return 429. Observed:
  50 ops sent without waiting all confirmed in about 70 ms (test: `classic-basics.ts`). The login form is rate limited
  per email (observed 429 after a dozen logins in a few minutes). **unverified**: overleaf.com.

## Confirmation and broadcast

**verified** (`services/real-time/app/js/DocumentUpdaterController.js:45–105`):

- The sender receives `otUpdateApplied` with only `{v, doc}`. That is the confirmation. Increment the version then.
  It goes to the whole project room; filter by `doc`.
- Every other client receives the full update, `{doc, op, v, meta: {source, user_id, ts}}`.
- A duplicate update (flagged `dup`) goes only to its sender, as a confirmation, with the **original** op's version, so
  it can be older than the client's version (`model.js` stops counting when it finds the earlier copy). The browser
  ignores confirmations with `v` below its version (`sharejs.js` `_onMessage`). test: `classic-basics.ts`.
- During catch-up, an op whose `meta.source` is one of the inflight op's connection IDs is taken as its confirmation
  (same function). Catch-up ops carry `meta: {source, user_id, ts}` in both formats (observed), so **after a
  reconnect, `joinDoc(docId, inflight.v)` tells whether the inflight op was applied**: it was if one of the returned
  ops has a `meta.source` the op was sent under. This works while the ops are kept (101 ops, 1 hour). Past that,
  nothing on the socket can tell; the history API lists users, not connections.
- On history-ot, `v` is wrong for concurrent ops, see above.

## Resending safely

**verified** (`services/web/frontend/js/features/ide-react/editor/share-js-doc.ts:483–515`):

- If no confirmation arrives in time, the browser resends the same op with
  `dupIfSource: [currentConnectionId, ...earlierConnectionIds]`. The server compares against ops it already applied
  (`services/document-updater/app/js/sharejs/server/model.js:181`; `HistoryOTUpdateManager.js` for history-ot). If it
  finds one from those sources, it marks the update `dup` and only confirms it. test: `classic-basics.ts`.
- Keep a list of every connection ID an op was sent under, across reconnects.
- The browser waits `INFLIGHT_OP_TIMEOUT` for a queued out-of-order update before forcing it (`share-js-doc.ts`
  `pushOntoQueue`). Rejoin if the queue stays non-empty that long.

## Hash checks (classic)

- **verified + observed.** The hash is the git blob SHA-1 of the doc **after** the op,
  `sha1("blob " + length + "\0" + utf8(content))`, with `length` the JavaScript string length (UTF-16 units)
  (`ShareJsUpdateManager._computeHash`; the browser's `sharejs.js` uses `str.length`). A byte-length hash is refused.
  test: `classic-basics.ts`.
- **verified.** The server checks `hash` only when the update's `v` equals its current version. A mismatch fails with
  `Invalid hash` (`ShareJsUpdateManager.js:102`).
- **observed.** CE's browser sends one (`ol-useShareJsHash` is on) at most every 5 s, on the op where it is due.
- history-ot: see `contentHash` above; `hash` is not checked.

## Errors and limits

**verified.** Any document updater error sends `otUpdateError(error, message)` to clients on that doc, then disconnects
them (`DocumentUpdaterController.js:118`). Messages:

| Message | Meaning | test |
|---|---|---|
| `Delete component '…' does not match deleted text '…'` | Our copy of the text has drifted from the server's | |
| `Invalid hash` | Same, caught by the hash (classic only) | `classic-basics.ts` |
| `Op too old` | Our version is too far behind, rejoin | |
| `update is too large` | Split the edit. The server confirms it, then errors and disconnects | |
| `Update takes doc over max doc size` | The doc would pass 2 MB | |
| `ot type mismatch` | The doc changed format under us, see below | `migration.ts` |
| `inserted text contains non BMP characters` | history-ot insert with a surrogate | `emoji.ts` |
| `Both operations have to have the same base length` | history-ot op from a client that drifted (the version bug) | `fuzz.ts` |
| `client does not support history-ot` | Join with `supportsHistoryOT` (an ack error) | |

Ack errors (in the callback, not `otUpdateError`): schema failures (`Unrecognized key: "…"`), and `doc updater could
not load requested ops` from `joinDoc`.

- **verified.** Max doc length is 2 MB (`services/real-time/config/settings.defaults.cjs:126`). Max update size is
  derived from it in the same file.

## A project moving to history-ot while open

**observed** (test: `migration.ts`). The format is fixed when the document updater loads the doc. While it stays loaded,
classic ops keep working after `otMigrationStage` is raised. Once it unloads the doc (flush, or idle), the next classic
op gets `otUpdateError "ot type mismatch"` and a disconnect, and the op is not applied. A rejoin returns `history-ot`.
The browser shows "Out of sync … Reload editor" and the unconfirmed edit survives only in "Show Local File Contents".
Our engine must keep the edit, rejoin, and resend it as a history-ot op.

## Other socket events

File-tree changes go through REST (`Features/Editor/EditorRouter.mjs`, verified), each with the `X-CSRF-Token`
header, and every client in the project gets an event (`EditorController.mjs`, verified; observed with the arguments
below, test: `entity-events.ts`). Note Overleaf's own spelling.

| REST call | Event to others |
|---|---|
| `POST /project/:id/doc {name, parent_folder_id}` → `{_id, name}` | `reciveNewDoc(folderId, {_id, name}, source, userId)` |
| `POST /project/:id/folder {name, parent_folder_id}` | `reciveNewFolder(parentId, {_id, name, docs, fileRefs, folders}, userId)` |
| `POST /project/:id/:type/:entityId/rename {name}` | `reciveEntityRename(entityId, newName)` |
| `POST /project/:id/:type/:entityId/move {folder_id}` | `reciveEntityMove(entityId, folderId)` |
| `DELETE /project/:id/doc/:entityId` (also `file`, `folder`) | `removeEntity(entityId, source)` |
| `POST /Project/:id/upload?folder_id=` (multipart, see [Files](#binary-files)) | `reciveNewFile(folderId, file, "upload", linkedFileData, userId)` |

`:type` is `doc`, `file` or `folder`. Creating docs is rate limited per project (`addDocToProject`).

Cursors, **observed** on CE (test: `cursors.ts`):

| Event | Shape |
|---|---|
| `clientTracking.updatePosition({row, column, doc_id})` (emit) | Our cursor. Strict schema, nothing else allowed (`Router.js`, verified) |
| `clientTracking.clientUpdated` (to others) | `{row, column, doc_id, id: publicId, user_id, email, name}` |
| `clientTracking.getConnectedUsers` (emit, ack) | `[{client_id, user_id, first_name, last_name, email, cursorData?, connected, client_age, last_updated_at}]`, us included |
| `clientTracking.clientDisconnected` (to others) | `(publicId)` |

Chat and settings, **observed** on CE (test: `chat-settings.ts`; routes in `router.mjs`, events in
`ChatController.mjs` and `EditorController.mjs`, verified):

| REST call | Event to everyone |
|---|---|
| `POST /project/:id/messages {content}` (204); `GET …/messages?limit=N` lists | `new-chat-message({id, content, timestamp, user_id, room_id, user: {id, first_name, email}})` |
| `POST /project/:id/settings {compiler}` (204) | `compilerUpdated(compiler)` |
| `POST /project/:id/settings {spellCheckLanguage}` | `spellCheckLanguageUpdated(language)` |
| other fields of `…/settings` and `…/settings/admin` (not tested) | `rootDocUpdated`, `imageNameUpdated`, `projectNameUpdated`, … |

Still only **observed** in Workshop (`src/api/socketio.ts`):

| Event | Use |
|---|---|
| `forceDisconnect` | Server is closing the connection |

File creation, renames, moves, deletes and binary uploads go through REST in `services/web`, not the socket.

### Binary files

**verified** (`Features/Uploads/UploadsRouter.mjs`, `ProjectUploadController.mjs`, `router.mjs`) and **observed** on CE
6.3.0 (test: `files.ts`):

- Download: `GET /Project/:id/file/:fileId` (capital P) returns the bytes. Needs read access.
- Upload: `POST /Project/:id/upload?folder_id=<id>`, multipart with fields `name`, optional `type`, optional
  `relativePath`, and the file as `qqfile`; `X-CSRF-Token` header. Answers
  `{success: true, entity_id, entity_type: "file" | "doc", hash?}`. Errors are 422 with `{success: false, error}`
  (`invalid_filename`, `duplicate_file_name`, `project_has_too_many_files`, `folder_not_found`). Rate limit 500 per
  15 minutes per project (`fileUpload`). Size limit `Settings.maxUploadSize`, 50 MB on CE (multer refuses larger).
- Overleaf decides doc or file (`FileTypeManager.isEditable`): text becomes a doc (`reciveNewDoc`, source
  `"upload"`), anything else a file. Uploads replace: an existing **file** of that name is removed and the new one
  gets a **new ID** (`removeEntity(oldId, "upload")`, then `reciveNewFile`); an existing **doc** keeps its ID and has
  its whole content replaced (`upsertDoc`), so never upload over a doc you mean to edit with ops.
- `relativePath` (`dir/sub/name`) creates the missing folders first, each with its own `reciveNewFolder(parentId,
  folder, null)` (third argument observed `null`, not the user ID).
- A file's `hash` (in `fileRefs` of `joinProjectResponse`, in `reciveNewFile`, and in the upload answer) is the git blob
  SHA-1 of its bytes, `sha1("blob " + length + "\0" + bytes)`: the same as `git hash-object`. A client can tell
  whether its local copy is current without downloading.
- Deleting a folder sends one `removeEntity(folderId, "editor")`, nothing for what was in it.
- **unverified**: overleaf.com's upload limit and rate limits.

## Comments

**verified** (`services/web/frontend/js/features/review-panel/context/threads-context.tsx`):

- The commented text is a range in the doc: a `{p, c, t}` op in classic, a `{commentId, ranges}` operation in
  history-ot (observed accepted and returned in the snapshot's `comments`, test: `historyot-snapshot.ts`). The server
  moves ranges as text changes (`libraries/ranges-tracker`, or the history-ot snapshot).
- **Not on CE.** The thread routes below are missing from CE's `router.mjs` and its modules (verified at `e039ad2`;
  only `Features/Chat/ChatApiHandler.mjs` talks to the chat service), and `GET /project/:id/threads` answers 404 on
  CE 6.3.0 (observed by the engine agent). They come from a Server Pro / overleaf.com module. So on stock CE comment
  ranges work but their conversations can't be read or written.
- **Our local CE has them:** `harness/ce-threads` is a test-only module of ours (AGPL, never shipped) that adds the
  routes below using CE's internals. `docker/up.sh` installs it; re-run `harness/ce-threads/install.sh` after the
  container is recreated. Thread tests run there.
  - **observed** 2026-11-04: `replicate.ts check demo-paper` reads all 5 threads with their messages.
  - **observed** the same day: `ce_review.sh` adds a comment with its thread ("comment added").
- The conversation lives in the chat service (**observed** in Workshop and the frontend, `threads-context.tsx`):

| Action | Call |
|---|---|
| Load threads | `GET /project/:id/threads` |
| New comment | `POST /project/:id/thread/:threadId/messages`, then send the range op |
| Reply | `POST /project/:id/thread/:threadId/messages` |
| Edit or delete a message | `POST …/messages/:msgId/edit`, `DELETE …/messages/:msgId` |
| Resolve, reopen | `POST /project/:id/doc/:docId/thread/:threadId/resolve`, `…/reopen` |
| Delete a thread | `DELETE /project/:id/doc/:docId/thread/:threadId` |

- Socket events: `new-comment`, `edit-message`, `delete-message`, `resolve-thread`, `reopen-thread`, `delete-thread`,
  `new-comment-threads`.

## What the browser client does that we must also do

**verified** (`services/web/frontend/js/features/ide-react/editor/`):

- One op in flight, later edits queued, incoming ops transformed against both (`share-js-doc.ts`).
- Out-of-order server updates are queued until the expected version arrives (`processUpdateFromServerInOrder`).
  Not on history-ot, whose `v` can't be trusted.
- Every 2 s, unsent edits are backed up with the version and snapshot, and replayed after a reload
  (`offline-doc-backup.ts`). Ours goes to disk.
- Surrogates become U+FFFD before anything is sent.
- **observed.** It holds edits about 2 s before sending.

## Open questions

Answered in round 2 (each has a test above): history-ot format, snapshot, tracked deletes, comments, `contentHash` and
versions; hash units; the `otMigrationStage` change; rate limits on CE; session expiry on CE; emoji in both formats;
the binary `unicode.tex`; file-tree, cursor, chat and settings events.

Still open:

1. **Does overleaf.com have the history-ot version bug and the emoji bug?** Blocked: needs a throwaway overleaf.com
   project of the owner's, moved to history-ot (not something we can set there). Test: run `historyot-version.ts` and
   `emoji.ts` against it with `TAUDOT_ENV_FILE` pointing at its credentials.
2. **Rate limits and session length on overleaf.com.** Same block. Test: `session.ts` (TTL can't be read there; watch
   for logout instead) and the burst in `classic-basics.ts`.
3. **Order of history-ot broadcasts** on a multi-node deployment (rule 3 above). Can't be tested on single-node CE.
