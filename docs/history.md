# Overleaf's version history

How Overleaf's History view gets its data, and what Taudot uses of it. Same conventions as `docs/protocol.md`: each
claim is **verified** (read in Overleaf CE at `e039ad2`, file named), **observed** (seen on the local CE 6.3.0, or on
the overleaf.com throwaway project where it says so) or **unverified**. Paths are relative to
`github.com/overleaf/overleaf`. The engine's methods over these routes are in `docs/api.md`, History.

The CE test `crates/engine/tests/ce/history.sh [--history-ot]` checks the engine's view of every route below on a new
project with edits by two users, a label and nothing else.

## Who serves what

- **verified** (`services/web/app/src/Features/History/HistoryRouter.mjs`). The web app proxies history reads to
  `services/project-history` with the session's user in `X-User-Id` (`HistoryController.proxyToHistoryApi`). For
  `updates` and `diff` it first replaces the user IDs in every `meta.users` with user objects
  (`proxyToHistoryApiAndInjectUserDetails`, `HistoryManager.injectUserDetails`). All reads need read access to the
  project (`ensureUserCanReadProject`); restricted users (token read-only links) are blocked.
- **verified** (`services/web/frontend/js/features/history/services/api.ts`). The browser's History view calls only
  `updates`, `labels`, `filetree/diff` and `diff`, plus the writes (`labels` POST/DELETE, `restore_file`,
  `revert_file`, `revert-project`) and `version/:v/zip` for downloads. It doesn't call `latest/history` or
  `changes`: those give the raw history-v1 chunk (Files at a version, below).
- **observed.** All four reads answer the same on classic and history-ot projects (CE test, both modes) and on
  overleaf.com.

## `GET /project/:id/updates?min_count=&before=`

The version list, newest first, in groups.

- **verified** (`services/project-history/app/js/HttpController.js` `getUpdates`, `SummarizedUpdatesManager.js`).
  `min_count` (default 25; the browser sends 10) is a minimum: the service reads whole history chunks, newest first,
  until it has `min_count` groups, at most 5 chunks per call. `before` is a **version**: only updates below it.
  The answer's `nextBeforeTimestamp` is, despite its name, the version to pass as the next `before`; it is absent
  when the history is exhausted.
- **observed.** On a short history one call returns everything (`min_count=1` gave all 3 groups on CE; 67 groups
  for `min_count=5` on the overleaf.com throwaway project, `nextBeforeTimestamp` absent).
- **verified** (`SummarizedUpdatesManager._shouldMergeUpdate`). Consecutive updates are merged into one group unless:
  a label is on the version between them; their `origin` kinds (or paths, or restore timestamps) differ; there are 5
  minutes or more between them; or one changes text and the other changes files (except history resyncs). Updates
  with only comment operations are skipped. A merged group's `users` is the union, newest first.
- **observed** (CE). The answer:

  ```json
  {"updates": [{"fromV": 8, "toV": 10,
                "meta": {"users": [{"first_name": "Alice", "email": "alice@…", "id": "6ae7…"}],
                         "start_ts": 1793980986804, "end_ts": 1793980995340},
                "labels": [], "pathnames": [],
                "project_ops": [{"remove": {"pathname": "sections/unicode.tex"}, "atV": 9},
                                {"rename": {"pathname": "refs.bib", "newPathname": "biblio.bib"}, "atV": 8}]}, …],
   "nextBeforeTimestamp": 5}
  ```

  A group covers versions `fromV`..`toV`; the project at version `toV` is the state after it. `pathnames` are the docs
  whose text changed (sorted); `project_ops` the adds, renames and removes, each with the version it happened at
  (`atV`). `labels` are the labels at `toV`, same shape as `GET labels`. Times are ms since 1970.
- **verified** (`HistoryManager.injectUserDetails`). A user is `{id, first_name, last_name, email}`; fields that are
  empty are left out (**observed**: CE's test users have no `last_name` key). An ID the web app can't find becomes
  `null` in `users`. `meta.origin`, when present, is `{kind}` with kind `upload`, `dropbox`, `git-bridge`, `github`,
  `history-resync`, `history-migration`, or `{kind: "file-restore", path, timestamp, version}` /
  `{kind: "project-restore", timestamp, version}` (`frontend/js/features/history/services/types/shared.ts`).
  **observed** on overleaf.com: `{"kind": "upload"}` on a group of file uploads.

## `GET /project/:id/labels`

- **observed** (CE). `[{id, comment, version, user_id, created_at, user_display_name}]`, `created_at` ISO 8601.
  `POST` with `{comment, version}` (and `X-CSRF-Token`) answers the new label in that shape (CE only; we never write
  history on overleaf.com).
- **verified** (`project-history` `HttpController.getLabels`). 409 when the project doesn't use project-history
  (very old projects).

## `GET /project/:id/filetree/diff?from=&to=`

- **verified** (`FileTreeDiffGenerator.js`, via `DiffManager.getFileTreeDiff`). Every file that exists at either
  version, and what happened to it between them.
- **observed** (CE):

  ```json
  {"diff": [{"pathname": "main.tex", "operation": "edited"},
            {"pathname": "sections/astral.tex", "editable": false},
            {"pathname": "sections/unicode.tex", "operation": "removed", "deletedAtV": 9, "editable": true},
            {"pathname": "refs.bib", "newPathname": "biblio.bib", "operation": "renamed", "editable": true}]}
  ```

  `operation` is absent for an unchanged file, and `edited` files have no `editable` (always text). `editable: false`
  is a binary file. A renamed file is listed under its old `pathname` with `newPathname`. A file added in the range
  has `operation: "added"`.

## `GET /project/:id/diff?from=&to=&pathname=`

One file's text across the range.

- **verified** (`DiffManager.getDiff`, `DiffGenerator.buildDiff`). `pathname` is the file's name at `to`.
- **observed** (CE):

  ```json
  {"diff": [{"i": "% bob too\n", "meta": {"users": [{…bob…}], "start_ts": …, "end_ts": …}},
            {"i": "% alice was here\n", "meta": {"users": [{…alice…}], …}},
            {"u": "\\documentclass{article}\n…"}]}
  ```

  The chunks in order make the whole text as of `to` with the deleted text in place: `u` unchanged, `i` inserted and
  `d` deleted in the range, each `i`/`d` with the `meta` of the update that made it (users injected as above). The
  browser colours each by `meta.users[0]` (`utils/highlights-from-diff-response.ts`).
- **observed.** With `from == to` the answer is one `u` chunk: the file's text at that version. A renamed file's diff
  works under its new name; a removed file's under its old name up to the version it was removed.
- **observed.** A binary file answers `{"diff": {"binary": true}}`. A path not in the project at `to` answers 500
  with an HTML error page.

## Colours

- **verified** (`frontend/js/shared/utils/colors.ts`). The browser's author colour is `hsl(hue, 70%, 50%)` with
  `hue = parseInt(md5(user_id)[0..8], 16) % 320`, moved out of 180–220 by `hue - 200 + 340`; the viewer's own hue
  is always 200 and an anonymous user's 100. The engine sends this as `hue` (`overleaf::history::hue_for_user`,
  checked against node's md5 for the CE users). Taudot's clients colour authors their own way (the margin's colours)
  and may ignore it.

## Files at a version: `latest/history`, `changes`, `blob`, `version/:v/zip`

The browser's History view doesn't preview binary files, but history keeps them: history-v1 stores every file,
figures included, as a blob named by its hash. Taudot uses these four routes to put each figure of a past version
in that version's folder (`history.files_at`, `history.blob`, `history.zip_files` in `docs/api.md`; the app's
`VersionFolder`). The CE test `clients/mac/Tests/histblobs_ce.sh` checks them end to end.

- **verified** (`HistoryRouter.mjs`). All four are `GET`s on the web app needing read access; token read-only users
  are blocked from all but `blob`. `blob` (and `HEAD blob`) is rate-limited to `maxEntitiesPerProject` (default
  2000) an hour per user, `version/:v/zip` to 30 an hour; `latest/history` and `changes` aren't limited.
- **verified** (`libraries/overleaf-editor-core/lib/blob_utils.js`). A blob's hash is git's blob SHA-1: SHA-1 of
  `blob <byte length>\0` then the bytes. **observed** (CE and overleaf.com): `git hash-object` of the file gives the
  same hash, and the upload route (`POST /Project/:id/upload`) answers it as `hash`.

### `GET /project/:id/latest/history`

- **verified** (`HistoryController.getLatestHistory` → history-v1 `projects.getLatestHistory`, `ChunkResponse`). The
  newest chunk: `{chunk: {startVersion, history: {snapshot, changes}}, authors}`. `snapshot` is the project at
  `startVersion`, `{files: {path: file}}`; change `i` makes version `startVersion + i + 1`.
- **verified** (`project-history` `SummarizedUpdatesManager`: `toV = update.v + 1`, `update.v` counting from a
  chunk's `startVersion`). These are the versions `updates` numbers: the project after change `v - 1`.
- **verified** (`file_data/index.js` `FileData.fromRaw`). A file is `{hash, byteLength}` (binary), `{hash,
  stringLength}` (editable text), `{hash}` (kind not said), or without a hash (`{byteLength}`, `{stringLength}`,
  `{content}`: not stored, not seen in answers).
- **observed** (CE, a project with main.tex, then fig.png uploaded, then replaced): `startVersion: 0`, an empty
  snapshot, and four changes:

  ```json
  [{"operations": [{"pathname": "main.tex", "file": {"hash": "fac0…", "stringLength": 80}}]},
   {"operations": [{"pathname": "fig.png", "file": {"hash": "06d7…", "byteLength": 166}}]},
   {"operations": [{"pathname": "fig.png", "newPathname": ""}]},
   {"operations": [{"pathname": "fig.png", "file": {"hash": "82b7…", "byteLength": 169}}]}]
  ```

  Replacing a file by an upload is two versions: a remove (a move to `""`), then an add.
- **observed** (overleaf.com throwaway project, read-only): 606 versions, all in one chunk (`startVersion: 0`).

### `GET /project/:id/changes?since=&paginated=true`

- **verified** (`HistoryController.getChanges`, history-v1 `projects.getChanges`). The changes from version `since`
  (default 0) as `{changes, hasMore}`, at most what history-v1 reads at once; without `paginated` the web app pages
  through all of them and answers a bare array. Each change is `{operations, timestamp, authors, v2Authors,
  projectVersion}` (**observed** on CE).
- **verified** (`operation/index.js` `Operation.fromRaw`). An operation is an add `{pathname, file}`, an edit
  `{pathname, textOperation}` (or comment edits `commentId`/`deleteComment`, and `noOp`), a move `{pathname,
  newPathname}` (empty: removed), metadata `{pathname, metadata}`, or `{}`. Only adds carry a hash; after an edit a
  text file's hash isn't in the change (history-v1 works it out when it stores the next chunk).
- **observed** (CE). `since` past the newest version answers 500 with an HTML page (history-v1's 400 isn't passed
  on).

### `GET /project/:id/blob/:hash`

- **verified** (`HistoryController.requestBlob`). `hash` must be 40 hex characters. Answers the bytes as
  `application/octet-stream` with `ETag: <hash>` and `Cache-Control: private, max-age=86400, ...`; `If-None-Match:
  <hash>` answers 304; `Range` is honoured (206); an unknown blob is 404. Any blob of the project, from any version.
- **observed** (CE): those headers; 404 for an unknown or malformed hash; `HEAD` gives `Content-Length`. On
  overleaf.com: main.tex's blob at version 1 came back, 201 bytes, its git hash the one asked for.

### `GET /project/:id/version/:version/zip`

- **verified** (`HistoryController.downloadZipOfVersion`). The project at the version, streamed from history-v1
  (CE) as `<project name> (Version N).zip`; 402 when the project has no history-v1 ID.
- **observed** (CE). Files at the zip's root under their paths, binaries included; a version past the newest is
  404. Not tried on overleaf.com (rate-limited; on SaaS the web app fetches it differently, the `saas` branch).

### How Taudot gets a version's figures

1. The tree from the version to now (`filetree/diff`) says which binary files changed since; the others are copied
   from the project folder with no request.
2. For the ones that changed (or aren't in the folder any more), `history.files_at`: the version's hashes by replaying
   changes, from the newest chunk (one request) or from version 0 (paged `changes`; kept in memory per project).
3. A file whose today's copy has the same hash is copied; otherwise `history.blob`, kept in a store by hash for every
   version and project (fetched once, ever).
4. If that fails, `history.zip_files` takes only those paths out of the version's zip. If that fails too, today's
   copy is used and the PDF bar says "figures as they are today"; such a folder is made again on the next visit.

## Not used yet

- Writes, for later: `POST labels {comment, version}`, `DELETE labels/:label_id`, `POST restore_file {version,
  pathname}` (a deleted file), `POST revert_file {version, pathname}`, `POST revert-project {version}`. Downloading a version as a zip
  for the user (the route is above).
