# Overleaf's version history

How Overleaf's History view gets its data, and what Taudot uses. Markers as in `docs/protocol.md`: **verified**
(Overleaf CE `e039ad2`), **observed** (CE 6.3.0, or a throwaway overleaf.com project where said). The engine's methods over these
routes are in `docs/api.md`, History. `crates/engine/tests/ce/history.sh [--history-ot]` checks every route below.

## Who serves what

- **verified** (`services/web/app/src/Features/History/HistoryRouter.mjs`). The web app proxies reads to
  `services/project-history` (user in `X-User-Id`), replacing user IDs in `meta.users` with user objects for `updates`
  and `diff`. Reads need read access; token read-only users are blocked.
- **verified** (`frontend/js/features/history/services/api.ts`). The browser reads `updates`, `labels`,
  `filetree/diff`, `diff` and `version/:v/zip`, and writes `labels`, `restore_file`, `revert_file`, `revert-project`.
- **observed.** The four reads answer the same on classic, history-ot and overleaf.com projects.

## `GET /project/:id/updates?min_count=&before=`

The version list, newest first, in groups.

- **verified** (`project-history` `HttpController.getUpdates`, `SummarizedUpdatesManager.js`). `min_count` (default
  25; the browser sends 10) is a minimum: whole chunks are read, newest first, until there are `min_count` groups, at
  most 5 chunks per call. `before` is a **version**. `nextBeforeTimestamp` is, despite its name, the next `before`;
  absent when the history is exhausted.
- **observed.** A short history comes in one call (`min_count=5` gave all 67 groups on overleaf.com).
- **verified** (`_shouldMergeUpdate`). Consecutive updates merge into one group unless a label sits between them,
  their `origin` kinds (or paths, or restore timestamps) differ, they are 5 minutes or more apart, or one changes text
  and the other files (except history resyncs). Comment-only updates are skipped. A group's `users` is the union,
  newest first.
- **observed** (CE):

  ```json
  {"updates": [{"fromV": 8, "toV": 10,
                "meta": {"users": [{"first_name": "Alice", "email": "alice@…", "id": "6ae7…"}],
                         "start_ts": 1793980986804, "end_ts": 1793980995340},
                "labels": [], "pathnames": [],
                "project_ops": [{"remove": {"pathname": "sections/unicode.tex"}, "atV": 9},
                                {"rename": {"pathname": "refs.bib", "newPathname": "biblio.bib"}, "atV": 8}]}, …],
   "nextBeforeTimestamp": 5}
  ```

  The project at `toV` is the state after the group. `pathnames`: docs whose text changed (sorted). `project_ops`:
  adds, renames and removes, each at version `atV`. `labels`: those at `toV`, shaped as `GET labels`. Times in ms.
- **verified** (`injectUserDetails`). A user is `{id, first_name, last_name, email}`, empty fields left out
  (**observed**: CE's test users have no `last_name`). An unknown ID becomes `null`. `meta.origin`, when present, is
  `{kind}` with kind `upload`, `dropbox`, `git-bridge`, `github`, `history-resync`, `history-migration`, or
  `{kind: "file-restore", path, timestamp, version}` / `{kind: "project-restore", timestamp, version}`
  (`services/types/shared.ts`).

## `GET /project/:id/labels`

- **observed** (CE). `[{id, comment, version, user_id, created_at, user_display_name}]`, `created_at` ISO 8601.
  `POST {comment, version}` (with `X-CSRF-Token`) answers the new label (CE only; we never write history on
  overleaf.com).
- **verified** (`HttpController.getLabels`). 409 when the project doesn't use project-history (very old projects).

## `GET /project/:id/filetree/diff?from=&to=`

- **verified** (`FileTreeDiffGenerator.js`). Every file at either version and what happened to it.
- **observed** (CE):

  ```json
  {"diff": [{"pathname": "main.tex", "operation": "edited"},
            {"pathname": "sections/astral.tex", "editable": false},
            {"pathname": "sections/unicode.tex", "operation": "removed", "deletedAtV": 9, "editable": true},
            {"pathname": "refs.bib", "newPathname": "biblio.bib", "operation": "renamed", "editable": true}]}
  ```

  No `operation`: unchanged. `edited` files have no `editable` (always text); `editable: false` is binary. A rename
  is listed under the old `pathname` with `newPathname`. An add is `operation: "added"`.

## `GET /project/:id/diff?from=&to=&pathname=`

- **verified** (`DiffManager.getDiff`, `DiffGenerator.buildDiff`). `pathname` is the name at `to`.
- **observed** (CE):

  ```json
  {"diff": [{"i": "% bob too\n", "meta": {"users": [{…bob…}], "start_ts": …, "end_ts": …}},
            {"i": "% alice was here\n", "meta": {"users": [{…alice…}], …}},
            {"u": "\\documentclass{article}\n…"}]}
  ```

  In order, the chunks make the text at `to` with deleted text in place: `u` unchanged, `i` inserted, `d` deleted,
  each `i`/`d` with its update's `meta`. The browser colours by `meta.users[0]`.
- **observed.** `from == to` gives one `u` chunk: the text at that version. A renamed file works under its new name, a
  removed one under its old name up to its removal. Binary: `{"diff": {"binary": true}}`. A path not in the project
  at `to`: 500 with an HTML page.

## Colours

- **verified** (`frontend/js/shared/utils/colors.ts`). Author colour `hsl(hue, 70%, 50%)`, `hue =
  parseInt(md5(user_id)[0..8], 16) % 320`, moved out of 180–220 by `hue - 200 + 340`; the viewer's own hue is 200, an
  anonymous user's 100. The engine sends it as `hue` (`overleaf::history::hue_for_user`).

## Files at a version: `latest/history`, `changes`, `blob`, `version/:v/zip`

History-v1 keeps every file as a blob named by its hash. Taudot uses these routes to put a past version's figures
in that version's folder (`history.files_at`, `history.blob`, `history.zip_files` in
`docs/api.md`; the app's `VersionFolder`). Test: `clients/mac/Tests/histblobs_ce.sh`.

- **verified** (`HistoryRouter.mjs`). All `GET`, read access; token read-only users get only `blob`. `blob` (and
  `HEAD`) is limited to `maxEntitiesPerProject` (default 2000) an hour per user, `zip` to 30 an hour; the other two
  aren't limited.
- **verified** (`overleaf-editor-core/lib/blob_utils.js`). A hash is git's blob SHA-1 (`blob <length>\0` + bytes).
  **observed** (CE and overleaf.com): equals `git hash-object`, and `POST /Project/:id/upload` answers it as `hash`.

### `GET /project/:id/latest/history`

- **verified** (`HistoryController.getLatestHistory`, history-v1 `ChunkResponse`). The newest chunk: `{chunk:
  {startVersion, history: {snapshot, changes}}, authors}`. `snapshot` is the project at `startVersion`, `{files:
  {path: file}}`; change `i` makes version `startVersion + i + 1`, the versions `updates` numbers.
- **verified** (`file_data/index.js`). A file is `{hash, byteLength}` (binary), `{hash, stringLength}` (text),
  `{hash}`, or without a hash (`{byteLength}`, `{stringLength}`, `{content}`; not seen in answers).
- **observed** (CE: main.tex, then fig.png uploaded, then replaced): `startVersion: 0`, empty snapshot, four changes:

  ```json
  [{"operations": [{"pathname": "main.tex", "file": {"hash": "fac0…", "stringLength": 80}}]},
   {"operations": [{"pathname": "fig.png", "file": {"hash": "06d7…", "byteLength": 166}}]},
   {"operations": [{"pathname": "fig.png", "newPathname": ""}]},
   {"operations": [{"pathname": "fig.png", "file": {"hash": "82b7…", "byteLength": 169}}]}]
  ```

  Replacing by upload is two versions: a remove (move to `""`), then an add. On overleaf.com, 606 versions were one
  chunk.

### `GET /project/:id/changes?since=&paginated=true`

- **verified** (`HistoryController.getChanges`). Changes from version `since` (default 0) as `{changes, hasMore}`;
  without `paginated`, all of them as a bare array. A change is `{operations, timestamp, authors, v2Authors,
  projectVersion}` (**observed**).
- **verified** (`operation/index.js`). An operation is an add `{pathname, file}`, an edit `{pathname,
  textOperation}` (or `commentId`/`deleteComment`, `noOp`), a move `{pathname, newPathname}` (empty: removed),
  metadata `{pathname, metadata}`, or `{}`. Only adds carry a hash.
- **observed** (CE). `since` past the newest version: 500 with an HTML page.

### `GET /project/:id/blob/:hash`

- **verified** (`HistoryController.requestBlob`). 40 hex characters. `application/octet-stream`, `ETag: <hash>`,
  `Cache-Control: private, max-age=86400, ...`; `If-None-Match` gives 304, `Range` 206, unknown 404. Any blob of the
  project, any version.
- **observed** (CE, overleaf.com): those headers, 404 for unknown or malformed, `HEAD` gives `Content-Length`.

### `GET /project/:id/version/:version/zip`

- **verified** (`HistoryController.downloadZipOfVersion`). The project at the version as `<name> (Version N).zip`;
  402 without a history-v1 ID.
- **observed** (CE). Files at the root under their paths, binaries included; past the newest version, 404.

### How Taudot gets a version's figures

1. `filetree/diff` from the version to now: unchanged binaries are copied from the project folder.
2. For the rest, `history.files_at` replays changes for the version's hashes (newest chunk, or paged `changes` from
   version 0, kept in memory).
3. Same hash as today's copy: copied. Otherwise `history.blob`, stored by hash, fetched once ever.
4. Else `history.zip_files` from the version's zip. Else today's copy, the PDF bar says "figures as they are today",
   and the folder is remade next visit.

## Not used yet

Writes: `POST labels {comment, version}`, `DELETE labels/:label_id`, `POST restore_file {version, pathname}`,
`POST revert_file {version, pathname}`, `POST revert-project {version}`. Downloading a version's zip for the user.
