//! A project's version history over REST, as Overleaf's History view reads it (`docs/history.md`).
//!
//! Every route is a `GET` that `services/web` proxies to `services/project-history`; the web app fills in user
//! details for `updates` and `diff`. Reads only: restoring and labels come later.
//!
//! - [`Http::history_updates`]: `GET /project/:id/updates?min_count=&before=`, versions newest first, grouped.
//! - [`Http::history_labels`]: `GET /project/:id/labels`.
//! - [`Http::history_tree`]: `GET /project/:id/filetree/diff?from=&to=`, every file with what happened to it.
//! - [`Http::history_diff`]: `GET /project/:id/diff?from=&to=&pathname=`, one file's text as chunks.

use crate::{Error, Http};
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// A user as the web app injects it into `meta.users` (`HistoryManager.injectUserDetails`). Missing names are
/// left out of the JSON, and a user Overleaf can't find comes as `null`.
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize, Serialize)]
pub struct HistoryUser {
    #[serde(default)]
    pub id: Option<String>,
    #[serde(default)]
    pub first_name: Option<String>,
    #[serde(default)]
    pub last_name: Option<String>,
    #[serde(default)]
    pub email: Option<String>,
}

impl HistoryUser {
    /// "First Last", else the email's local part, else "Anonymous", as `displayNameForUser` does.
    pub fn display_name(&self) -> String {
        let name = format!("{} {}", self.first_name.as_deref().unwrap_or(""), self.last_name.as_deref().unwrap_or(""));
        let name = name.trim();
        if !name.is_empty() {
            return name.to_string();
        }
        match self.email.as_deref() {
            Some(e) if !e.is_empty() => e.split('@').next().unwrap_or(e).to_string(),
            _ => "Anonymous".to_string(),
        }
    }
}

/// `meta` of an update or a diff chunk. Times are ms since 1970.
#[derive(Debug, Clone, Default, PartialEq, Deserialize, Serialize)]
pub struct HistoryMeta {
    #[serde(default)]
    pub users: Vec<Option<HistoryUser>>,
    #[serde(default)]
    pub start_ts: i64,
    #[serde(default)]
    pub end_ts: i64,
    /// `{kind, path?, timestamp?, version?}`: `upload`, `git-bridge`, `file-restore`, `project-restore`...
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub origin: Option<Value>,
}

#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
pub struct Label {
    pub id: String,
    pub comment: String,
    pub version: u64,
    #[serde(default)]
    pub user_id: Option<String>,
    #[serde(default)]
    pub created_at: Option<String>,
    #[serde(default)]
    pub user_display_name: Option<String>,
}

/// An add, rename or remove of a file, at the version it happened (`atV`).
#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
pub struct ProjectOp {
    #[serde(default)]
    pub add: Option<PathOnly>,
    #[serde(default)]
    pub rename: Option<RenameOp>,
    #[serde(default)]
    pub remove: Option<PathOnly>,
    #[serde(rename = "atV")]
    pub at_v: u64,
}

#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
pub struct PathOnly {
    pub pathname: String,
}

#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
pub struct RenameOp {
    pub pathname: String,
    #[serde(rename = "newPathname")]
    pub new_pathname: String,
}

/// A group of versions `fromV..toV` (`SummarizedUpdatesManager`: same kind of change, gaps under five minutes, cut
/// at labels and origins).
#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
pub struct HistoryUpdate {
    #[serde(rename = "fromV")]
    pub from_v: u64,
    #[serde(rename = "toV")]
    pub to_v: u64,
    #[serde(default)]
    pub meta: HistoryMeta,
    #[serde(default)]
    pub labels: Vec<Label>,
    #[serde(default)]
    pub pathnames: Vec<String>,
    #[serde(default)]
    pub project_ops: Vec<ProjectOp>,
}

#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
pub struct UpdatesPage {
    pub updates: Vec<HistoryUpdate>,
    /// Despite the name, a version: pass it as `before` for the next page. Absent on the last page.
    #[serde(rename = "nextBeforeTimestamp", default)]
    pub next_before: Option<u64>,
}

/// One file of `filetree/diff`. `operation` is absent for an unchanged file.
#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
pub struct FileDiff {
    pub pathname: String,
    #[serde(default)]
    pub operation: Option<String>,
    #[serde(rename = "newPathname", default)]
    pub new_pathname: Option<String>,
    #[serde(rename = "deletedAtV", default)]
    pub deleted_at_v: Option<u64>,
    /// Absent on `edited` files, which are always text.
    #[serde(default)]
    pub editable: Option<bool>,
}

/// A run of a file's text: unchanged (`u`), inserted (`i`) or deleted (`d`) in the range, with who and when.
#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
pub struct DiffChunk {
    #[serde(default)]
    pub u: Option<String>,
    #[serde(default)]
    pub i: Option<String>,
    #[serde(default)]
    pub d: Option<String>,
    #[serde(default)]
    pub meta: Option<HistoryMeta>,
}

/// What `diff` answers: the chunks, or `{binary: true}` for a file that isn't text.
#[derive(Debug, Clone, PartialEq)]
pub enum DocDiff {
    Text(Vec<DiffChunk>),
    Binary,
}

impl Http {
    async fn get_json<T: DeserializeOwned>(&self, path: &str) -> Result<T, Error> {
        let resp = self.client.get(self.base.join(path)?).header(reqwest::header::ACCEPT, "application/json").send().await?;
        let status = resp.status();
        let landed = resp.url().path().to_string();
        let text = resp.text().await.unwrap_or_default();
        if landed.ends_with("/login") {
            return Err(Error::Http(format!("GET /{path}: not logged in")));
        }
        if !status.is_success() {
            let body = if text.trim_start().starts_with('<') { String::new() } else { text.chars().take(200).collect() };
            return Err(Error::Http(format!("GET /{path}: {status} {body}").trim_end().to_string()));
        }
        serde_json::from_str(&text).map_err(|e| Error::Protocol(format!("GET /{path}: {e}")))
    }

    /// Versions newest first: at least `min_count` groups (Overleaf's default 25, the browser asks for 10) unless the
    /// history runs out, all from versions below `before` when given.
    pub async fn history_updates(&self, project_id: &str, min_count: u32, before: Option<u64>) -> Result<UpdatesPage, Error> {
        let mut path = format!("project/{project_id}/updates?min_count={min_count}");
        if let Some(b) = before {
            path.push_str(&format!("&before={b}"));
        }
        self.get_json(&path).await
    }

    pub async fn history_labels(&self, project_id: &str) -> Result<Vec<Label>, Error> {
        self.get_json(&format!("project/{project_id}/labels")).await
    }

    /// Every file that exists at either version, with what happened to it between them.
    pub async fn history_tree(&self, project_id: &str, from: u64, to: u64) -> Result<Vec<FileDiff>, Error> {
        #[derive(Deserialize)]
        struct R {
            diff: Vec<FileDiff>,
        }
        let r: R = self.get_json(&format!("project/{project_id}/filetree/diff?from={from}&to={to}")).await?;
        Ok(r.diff)
    }

    /// One file between two versions. `path` is its name at `to` (a renamed file's new name). With `from == to`, the
    /// file's whole text at that version, as one unchanged chunk.
    pub async fn history_diff(&self, project_id: &str, path: &str, from: u64, to: u64) -> Result<DocDiff, Error> {
        let q = url::form_urlencoded::Serializer::new(String::new())
            .append_pair("from", &from.to_string())
            .append_pair("to", &to.to_string())
            .append_pair("pathname", path)
            .finish();
        let v: Value = self.get_json(&format!("project/{project_id}/diff?{q}")).await?;
        parse_diff(&v)
    }
}

/// `{diff: [chunk...]}` or `{diff: {binary: true}}`.
pub fn parse_diff(v: &Value) -> Result<DocDiff, Error> {
    match v.get("diff") {
        Some(Value::Array(_)) => Ok(DocDiff::Text(serde_json::from_value(v["diff"].clone())?)),
        Some(d) if d.get("binary") == Some(&Value::Bool(true)) => Ok(DocDiff::Binary),
        _ => Err(Error::Protocol(format!("unexpected diff answer: {}", v.to_string().chars().take(200).collect::<String>()))),
    }
}

/// Overleaf's colour for a user, as a hue in degrees (`getHueForUserId` in `frontend/js/shared/utils/colors.ts`):
/// from the MD5 of the ID, kept out of the band around 200 that the viewer sees as their own. Clients that colour
/// authors their own way can ignore it.
pub fn hue_for_user(user_id: Option<&str>, me: Option<&str>) -> u32 {
    const ANONYMOUS: u32 = 100;
    const OWN: u32 = 200;
    const BLOCKED: u32 = 20;
    const TOTAL: u32 = 360;
    let Some(id) = user_id.filter(|i| *i != "anonymous-user") else { return ANONYMOUS };
    if Some(id) == me {
        return OWN;
    }
    let d = md5(id.as_bytes());
    let first = u32::from_be_bytes([d[0], d[1], d[2], d[3]]);
    let mut hue = first % (TOTAL - BLOCKED * 2);
    if hue > OWN - BLOCKED && hue < OWN + BLOCKED {
        hue = hue + TOTAL - BLOCKED - OWN;
    }
    hue
}

/// MD5 (RFC 1321), only for [`hue_for_user`].
fn md5(input: &[u8]) -> [u8; 16] {
    const S: [u32; 64] = [
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 4,
        11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    ];
    let k: Vec<u32> = (0..64).map(|i| ((i as f64 + 1.0).sin().abs() * 4294967296.0) as u32).collect();
    let (mut a0, mut b0, mut c0, mut d0) = (0x67452301u32, 0xefcdab89u32, 0x98badcfeu32, 0x10325476u32);
    let mut msg = input.to_vec();
    let bits = (input.len() as u64).wrapping_mul(8);
    msg.push(0x80);
    while msg.len() % 64 != 56 {
        msg.push(0);
    }
    msg.extend_from_slice(&bits.to_le_bytes());
    for chunk in msg.chunks(64) {
        let m: Vec<u32> = chunk.chunks(4).map(|w| u32::from_le_bytes([w[0], w[1], w[2], w[3]])).collect();
        let (mut a, mut b, mut c, mut d) = (a0, b0, c0, d0);
        for i in 0..64 {
            let (f, g) = match i / 16 {
                0 => ((b & c) | (!b & d), i),
                1 => ((d & b) | (!d & c), (5 * i + 1) % 16),
                2 => (b ^ c ^ d, (3 * i + 5) % 16),
                _ => (c ^ (b | !d), (7 * i) % 16),
            };
            let f = f.wrapping_add(a).wrapping_add(k[i]).wrapping_add(m[g]);
            a = d;
            d = c;
            c = b;
            b = b.wrapping_add(f.rotate_left(S[i]));
        }
        a0 = a0.wrapping_add(a);
        b0 = b0.wrapping_add(b);
        c0 = c0.wrapping_add(c);
        d0 = d0.wrapping_add(d);
    }
    let mut out = [0u8; 16];
    for (i, w) in [a0, b0, c0, d0].iter().enumerate() {
        out[i * 4..i * 4 + 4].copy_from_slice(&w.to_le_bytes());
    }
    out
}

/// A fake of the history routes for tests (feature `fake`): canned JSON per route, served over plain HTTP, and a
/// count of requests per path so tests can check what was cached.
#[cfg(feature = "fake")]
pub mod fake {
    use serde_json::Value;
    use std::collections::HashMap;
    use std::sync::{Arc, Mutex};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;

    #[derive(Default)]
    pub struct Routes {
        /// Path and query (as sent, e.g. `/project/p/labels`) to the JSON answer. A missing path answers 500.
        pub answers: HashMap<String, Value>,
        /// Requests seen, by path and query.
        pub hits: HashMap<String, usize>,
        /// Path and query to raw bytes (blobs, zips).
        pub raw: HashMap<String, Vec<u8>>,
    }

    pub struct FakeHistory {
        pub url: String,
        pub routes: Arc<Mutex<Routes>>,
    }

    impl FakeHistory {
        pub async fn start() -> FakeHistory {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let url = format!("http://{}", listener.local_addr().unwrap());
            let routes: Arc<Mutex<Routes>> = Default::default();
            let r = routes.clone();
            tokio::spawn(async move {
                while let Ok((mut s, _)) = listener.accept().await {
                    let r = r.clone();
                    tokio::spawn(async move {
                        let mut buf = vec![0u8; 16384];
                        let mut got = Vec::new();
                        while !got.windows(4).any(|w| w == b"\r\n\r\n") {
                            match s.read(&mut buf).await {
                                Ok(0) | Err(_) => return,
                                Ok(n) => got.extend_from_slice(&buf[..n]),
                            }
                        }
                        let head = String::from_utf8_lossy(&got).to_string();
                        let path = head.split_whitespace().nth(1).unwrap_or("/").to_string();
                        let (answer, raw) = {
                            let mut g = r.lock().unwrap();
                            *g.hits.entry(path.clone()).or_default() += 1;
                            (g.answers.get(&path).cloned(), g.raw.get(&path).cloned())
                        };
                        let (status, body) = match (answer, raw) {
                            (Some(v), _) => ("200 OK", v.to_string().into_bytes()),
                            (None, Some(b)) => ("200 OK", b),
                            _ => ("500 Internal Server Error", b"<html>Something went wrong</html>".to_vec()),
                        };
                        let head = format!(
                            "HTTP/1.1 {status}\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n",
                            body.len()
                        );
                        let _ = s.write_all(head.as_bytes()).await;
                        let _ = s.write_all(&body).await;
                    });
                }
            });
            FakeHistory { url, routes }
        }

        pub fn answer(&self, path: &str, v: Value) {
            self.routes.lock().unwrap().answers.insert(path.to_string(), v);
        }

        pub fn answer_raw(&self, path: &str, b: &[u8]) {
            self.routes.lock().unwrap().raw.insert(path.to_string(), b.to_vec());
        }

        pub fn hits(&self, path: &str) -> usize {
            self.routes.lock().unwrap().hits.get(path).copied().unwrap_or(0)
        }
    }
}

// ---- files at a version (figures included) -------------------------------------------------------------------------
//
// history-v1 keeps every file, binaries included, as blobs named by their git blob SHA-1. A chunk is a snapshot (the
// project at the chunk's `startVersion`) and its changes; change `i` of a chunk makes version `startVersion + i + 1`,
// the versions `updates` numbers (`SummarizedUpdatesManager`: `toV = update.v + 1`). The web app exposes the newest
// chunk (`latest/history`) and every change since a version (`changes?since=`), so the files of any version come from
// replaying changes: from the newest chunk's snapshot when the version is in it, else from version 0.

/// What a file is, as history records it (`FileData.fromRaw` in overleaf-editor-core): `byteLength` is a binary
/// file, `stringLength` editable text; a bare `hash` doesn't say.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum FileKind {
    Text,
    Binary,
    Unknown,
}

/// A file of the project at a version. `hash` is its content's git blob SHA-1 (`blob_utils.js`), the name of its blob
/// (`GET blob/:hash`); `None` for text edited since it was added (its text comes from `history_diff`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct VersionFile {
    pub path: String,
    pub hash: Option<String>,
    pub kind: FileKind,
}

/// What one operation of a change does to the project's files; the rest of an operation (the text of an edit,
/// comments) is dropped, so a long history kept as these is small.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FileOp {
    /// `{pathname, file: {hash, byteLength|stringLength}}`: a file added, or replaced (a new upload).
    Add { path: String, hash: Option<String>, kind: FileKind },
    /// `{pathname, newPathname}`; an empty new name removes the file.
    Move { path: String, to: String },
    /// `{pathname, textOperation}`: the text changed, so its hash is no longer known.
    Edit { path: String },
}

/// One change's file operations, in order (`Operation.fromRaw`). Comment, metadata and no-op operations don't touch
/// a file's content and are left out.
pub fn file_ops(change: &Value) -> Vec<FileOp> {
    let mut out = Vec::new();
    for op in change.get("operations").and_then(Value::as_array).into_iter().flatten() {
        let Some(path) = op.get("pathname").and_then(Value::as_str) else { continue };
        let path = path.to_string();
        if let Some(f) = op.get("file") {
            let (hash, kind) = file_entry(f);
            out.push(FileOp::Add { path, hash, kind });
        } else if op.get("textOperation").is_some() {
            out.push(FileOp::Edit { path });
        } else if let Some(n) = op.get("newPathname").and_then(Value::as_str) {
            out.push(FileOp::Move { path, to: n.to_string() });
        }
    }
    out
}

/// A raw file (`{hash, byteLength}`, `{hash, stringLength}`, `{hash}`, or inline `{content}`): its hash and kind.
fn file_entry(f: &Value) -> (Option<String>, FileKind) {
    let has = |k| f.get(k).is_some();
    let kind = if has("byteLength") {
        FileKind::Binary
    } else if has("stringLength") || has("content") {
        FileKind::Text
    } else {
        FileKind::Unknown
    };
    (f.get("hash").and_then(Value::as_str).map(str::to_string), kind)
}

/// The project's files as history's changes leave them, one change (one version) at a time.
#[derive(Default, Debug, Clone)]
pub struct Replay {
    files: std::collections::BTreeMap<String, (Option<String>, FileKind)>,
    pub version: u64,
}

impl Replay {
    /// A chunk's snapshot (`{files: {path: raw file}}`), the project at `version`.
    pub fn from_snapshot(snapshot: &Value, version: u64) -> Replay {
        let mut r = Replay { version, ..Default::default() };
        for (p, f) in snapshot.get("files").and_then(Value::as_object).into_iter().flatten() {
            r.files.insert(p.clone(), file_entry(f));
        }
        r
    }

    /// One change: the next version.
    pub fn apply(&mut self, ops: &[FileOp]) {
        for op in ops {
            match op {
                FileOp::Add { path, hash, kind } => {
                    self.files.insert(path.clone(), (hash.clone(), *kind));
                }
                FileOp::Move { path, to } => {
                    if let Some(e) = self.files.remove(path) {
                        if !to.is_empty() {
                            self.files.insert(to.clone(), e);
                        }
                    }
                }
                FileOp::Edit { path } => {
                    if let Some(e) = self.files.get_mut(path) {
                        e.0 = None;
                        e.1 = FileKind::Text;
                    }
                }
            }
        }
        self.version += 1;
    }

    pub fn files(&self) -> Vec<VersionFile> {
        self.files.iter().map(|(p, (h, k))| VersionFile { path: p.clone(), hash: h.clone(), kind: *k }).collect()
    }
}

/// The newest chunk, reduced to file operations.
#[derive(Debug, Clone)]
pub struct LatestChunk {
    pub start_version: u64,
    /// The project at `start_version`.
    pub snapshot: Replay,
    /// Change `i` makes version `start_version + i + 1`.
    pub changes: Vec<Vec<FileOp>>,
}

impl LatestChunk {
    /// The newest version.
    pub fn head(&self) -> u64 {
        self.start_version + self.changes.len() as u64
    }

    /// The files at `version`, when it is in this chunk.
    pub fn files_at(&self, version: u64) -> Option<Vec<VersionFile>> {
        if version < self.start_version || version > self.head() {
            return None;
        }
        let mut r = self.snapshot.clone();
        for c in &self.changes[..(version - self.start_version) as usize] {
            r.apply(c);
        }
        Some(r.files())
    }
}

/// The files at `version` from every change since version 0 (`changes[i]` makes version `i + 1`).
pub fn files_from_changes(changes: &[Vec<FileOp>], version: u64) -> Option<Vec<VersionFile>> {
    if version > changes.len() as u64 {
        return None;
    }
    let mut r = Replay::default();
    for c in &changes[..version as usize] {
        r.apply(c);
    }
    Some(r.files())
}

/// Where `history_files_at` found the version: the newest chunk (`latest/history`, one request) or the changes from
/// version 0 (`changes?since=`, paged).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum FilesFrom {
    LatestChunk,
    Changes,
}

/// The hash history gives `bytes` (git's blob SHA-1: `blob <length>\0` then the bytes).
pub fn blob_hash(bytes: &[u8]) -> String {
    use sha1::{Digest, Sha1};
    let mut h = Sha1::new();
    h.update(format!("blob {}\0", bytes.len()).as_bytes());
    h.update(bytes);
    h.finalize().iter().map(|b| format!("{b:02x}")).collect()
}

impl Http {
    async fn get_bytes(&self, path: &str) -> Result<Vec<u8>, Error> {
        let resp = self.client.get(self.base.join(path)?).send().await?;
        let status = resp.status();
        if resp.url().path().ends_with("/login") {
            return Err(Error::Http(format!("GET /{path}: not logged in")));
        }
        if !status.is_success() {
            return Err(Error::Http(format!("GET /{path}: {status}")));
        }
        Ok(resp.bytes().await?.to_vec())
    }

    /// The newest chunk (`GET /project/:id/latest/history`: `{chunk: {startVersion, history: {snapshot, changes}}}`).
    pub async fn history_latest_chunk(&self, project_id: &str) -> Result<LatestChunk, Error> {
        let v: Value = self.get_json(&format!("project/{project_id}/latest/history")).await?;
        let chunk = &v["chunk"];
        let start_version = chunk["startVersion"].as_u64().ok_or_else(|| Error::Protocol("latest/history: no startVersion".into()))?;
        let snapshot = Replay::from_snapshot(&chunk["history"]["snapshot"], start_version);
        let changes = chunk["history"]["changes"].as_array().map(|a| a.iter().map(file_ops).collect()).unwrap_or_default();
        Ok(LatestChunk { start_version, snapshot, changes })
    }

    /// One page of changes from version `since` (`GET /project/:id/changes?since=&paginated=true`: `{changes,
    /// hasMore}`; history-v1 answers at most a chunk's worth). The bool: more pages follow.
    pub async fn history_changes(&self, project_id: &str, since: u64) -> Result<(Vec<Vec<FileOp>>, bool), Error> {
        let page: Value = self.get_json(&format!("project/{project_id}/changes?since={since}&paginated=true")).await?;
        // Without `paginated` the web app answers a bare array of everything.
        let (list, more) = match &page {
            Value::Array(a) => (a.as_slice(), false),
            _ => (page["changes"].as_array().map(Vec::as_slice).unwrap_or(&[]), page["hasMore"].as_bool().unwrap_or(false)),
        };
        Ok((list.iter().map(file_ops).collect(), more && !list.is_empty()))
    }

    /// Every file of the project at `version` with its hash: from the newest chunk when the version is in it (one
    /// request), else by replaying the changes from version 0 up to it. The engine caches these; this is the plain way.
    pub async fn history_files_at(&self, project_id: &str, version: u64) -> Result<(Vec<VersionFile>, FilesFrom), Error> {
        let latest = self.history_latest_chunk(project_id).await?;
        if let Some(files) = latest.files_at(version) {
            return Ok((files, FilesFrom::LatestChunk));
        }
        if version > latest.head() {
            return Err(Error::Protocol(format!("version {version} is after the newest, {}", latest.head())));
        }
        let mut all: Vec<Vec<FileOp>> = Vec::new();
        while (all.len() as u64) < version {
            let (page, more) = self.history_changes(project_id, all.len() as u64).await?;
            if page.is_empty() {
                break;
            }
            all.extend(page);
            if !more {
                break;
            }
        }
        files_from_changes(&all, version)
            .map(|f| (f, FilesFrom::Changes))
            .ok_or_else(|| Error::Protocol(format!("history has {} versions, not {version}", all.len())))
    }

    /// A stored file by its hash (`GET /project/:id/blob/:hash`), any version's. Overleaf allows as many an hour as a
    /// project may have files (2000 by default).
    pub async fn history_blob(&self, project_id: &str, hash: &str) -> Result<Vec<u8>, Error> {
        self.get_bytes(&format!("project/{project_id}/blob/{hash}")).await
    }

    /// The project at a version as a zip (`GET /project/:id/version/:v/zip`; Overleaf allows 30 an hour).
    pub async fn history_version_zip(&self, project_id: &str, version: u64) -> Result<Vec<u8>, Error> {
        self.get_bytes(&format!("project/{project_id}/version/{version}/zip")).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;


    // As CE 6.3 answered `latest/history` for a project where fig.png was uploaded, then replaced (docs/history.md).
    const RED: &str = "06d79dfcb718a0d01aa7bbb1d9124748c6236403";
    const BLUE: &str = "82b703671717b9ffe6d639768c80d3d614e95df5";
    fn ce_changes() -> Value {
        json!([
            {"operations": [{"pathname": "main.tex", "file": {"hash": "fac073d8fbdb31663c51b06c77d007df6e90e5f9", "stringLength": 80}}]},
            {"operations": [{"pathname": "fig.png", "file": {"hash": RED, "byteLength": 166}}]},
            {"operations": [{"pathname": "fig.png", "newPathname": ""}]},
            {"operations": [{"pathname": "fig.png", "file": {"hash": BLUE, "byteLength": 169}}]},
            {"operations": [{"pathname": "main.tex", "textOperation": [3, "x", 77]}]},
            {"operations": [{"pathname": "fig.png", "newPathname": "figs/fig.png"},
                            {"pathname": "main.tex", "commentId": "c1", "ranges": []},
                            {"pathname": "main.tex", "metadata": {}}]}
        ])
    }

    fn at(files: &[VersionFile], path: &str) -> Option<(Option<String>, FileKind)> {
        files.iter().find(|f| f.path == path).map(|f| (f.hash.clone(), f.kind))
    }

    #[test]
    fn blob_hash_is_gits() {
        // `git hash-object` of "hello\n", and of nothing.
        assert_eq!(blob_hash(b"hello\n"), "ce013625030ba8dba906f756967f9e9ca394464a");
        assert_eq!(blob_hash(b""), "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391");
    }

    #[test]
    fn replay_follows_adds_replaces_moves_and_edits() {
        let ops: Vec<Vec<FileOp>> = ce_changes().as_array().unwrap().iter().map(file_ops).collect();
        assert_eq!(ops[2], vec![FileOp::Move { path: "fig.png".into(), to: "".into() }]);
        // comments and metadata don't touch content
        assert_eq!(ops[5].len(), 1);
        let v = |n| files_from_changes(&ops, n).unwrap();
        assert!(v(0).is_empty());
        assert_eq!(at(&v(1), "main.tex"), Some((Some("fac073d8fbdb31663c51b06c77d007df6e90e5f9".into()), FileKind::Text)));
        assert_eq!(at(&v(2), "fig.png"), Some((Some(RED.into()), FileKind::Binary)));
        assert_eq!(at(&v(3), "fig.png"), None);
        assert_eq!(at(&v(4), "fig.png"), Some((Some(BLUE.into()), FileKind::Binary)));
        // edited text: hash unknown from here on
        assert_eq!(at(&v(5), "main.tex"), Some((None, FileKind::Text)));
        assert_eq!(at(&v(6), "figs/fig.png"), Some((Some(BLUE.into()), FileKind::Binary)));
        assert_eq!(at(&v(6), "fig.png"), None);
        assert!(files_from_changes(&ops, 7).is_none());
    }

    #[test]
    fn snapshot_kinds_and_chunk_bounds() {
        let snap = json!({"files": {"a.png": {"hash": RED, "byteLength": 1}, "t.tex": {"hash": BLUE, "stringLength": 3},
                                    "old.pdf": {"hash": RED}}});
        let chunk = LatestChunk {
            start_version: 10,
            snapshot: Replay::from_snapshot(&snap, 10),
            changes: vec![vec![FileOp::Add { path: "a.png".into(), hash: Some(BLUE.into()), kind: FileKind::Binary }]],
        };
        assert_eq!(chunk.head(), 11);
        assert!(chunk.files_at(9).is_none());
        assert!(chunk.files_at(12).is_none());
        let f10 = chunk.files_at(10).unwrap();
        assert_eq!(at(&f10, "a.png"), Some((Some(RED.into()), FileKind::Binary)));
        assert_eq!(at(&f10, "old.pdf").unwrap().1, FileKind::Unknown);
        assert_eq!(at(&f10, "t.tex").unwrap().1, FileKind::Text);
        assert_eq!(at(&chunk.files_at(11).unwrap(), "a.png").unwrap().0.as_deref(), Some(BLUE));
    }

    #[tokio::test]
    async fn files_at_from_the_newest_chunk_or_the_changes() {
        let f = fake::FakeHistory::start().await;
        let http = Http::new(&f.url).unwrap();
        let all = ce_changes();
        let a = all.as_array().unwrap();
        // newest chunk: versions 4..=6
        f.answer("/project/p/latest/history", json!({"chunk": {"startVersion": 4, "history": {
            "snapshot": {"files": {"main.tex": {"hash": "x", "stringLength": 80}, "fig.png": {"hash": BLUE, "byteLength": 169}}},
            "changes": a[4..].to_vec()}}}));
        let (files, from) = http.history_files_at("p", 6).await.unwrap();
        assert_eq!(from, FilesFrom::LatestChunk);
        assert_eq!(at(&files, "figs/fig.png").unwrap().0.as_deref(), Some(BLUE));
        assert_eq!(f.hits("/project/p/changes?since=0&paginated=true"), 0);
        // older: the changes from 0, in two pages
        f.answer("/project/p/changes?since=0&paginated=true", json!({"changes": a[..2].to_vec(), "hasMore": true}));
        f.answer("/project/p/changes?since=2&paginated=true", json!({"changes": a[2..].to_vec(), "hasMore": false}));
        let (files, from) = http.history_files_at("p", 2).await.unwrap();
        assert_eq!(from, FilesFrom::Changes);
        assert_eq!(at(&files, "fig.png").unwrap().0.as_deref(), Some(RED));
        assert_eq!(f.hits("/project/p/changes?since=2&paginated=true"), 0, "stops when it has the version");
        let (files, _) = http.history_files_at("p", 3).await.unwrap();
        assert_eq!(at(&files, "fig.png"), None);
        assert!(http.history_files_at("p", 7).await.is_err());

        f.answer_raw(&format!("/project/p/blob/{RED}"), b"\x89PNG red");
        assert_eq!(http.history_blob("p", RED).await.unwrap(), b"\x89PNG red");
        let e = http.history_blob("p", BLUE).await.unwrap_err().to_string();
        assert!(e.contains("500"), "{e}");
    }

    #[test]
    fn md5_known_values() {
        let hex = |d: [u8; 16]| d.iter().map(|b| format!("{b:02x}")).collect::<String>();
        assert_eq!(hex(md5(b"")), "d41d8cd98f00b204e9800998ecf8427e");
        assert_eq!(hex(md5(b"The quick brown fox jumps over the lazy dog")), "9e107d9d372bb6826bd81d3542a419d6");
    }

    #[test]
    fn hue_matches_overleaf() {
        // Overleaf's getHueForUserId for the CE test users (md5 in node, same formula).
        assert_eq!(hue_for_user(Some("6ae7eb869c93d6e28d0854af"), None), 237);
        assert_eq!(hue_for_user(Some("6ae7eb869c93d6e28d0854b5"), None), 135);
        assert_eq!(hue_for_user(Some("6ae7eb869c93d6e28d0854a9"), None), 31);
        let id = "6ae7eb869c93d6e28d0854af";
        assert_eq!(hue_for_user(Some(id), Some(id)), 200);
        assert_eq!(hue_for_user(None, None), 100);
        assert!(!(181..220).contains(&hue_for_user(Some("x"), None)));
    }

    #[test]
    fn parses_ce_answers() {
        // As CE 6.3 answered (docs/history.md), trimmed.
        let page: UpdatesPage = serde_json::from_value(json!({"updates": [
            {"fromV": 8, "toV": 10, "meta": {"users": [{"first_name": "Alice", "email": "alice@x", "id": "a"}],
              "start_ts": 1, "end_ts": 2}, "labels": [], "pathnames": [],
             "project_ops": [{"remove": {"pathname": "u.tex"}, "atV": 9},
                             {"rename": {"pathname": "refs.bib", "newPathname": "biblio.bib"}, "atV": 8}]},
            {"fromV": 5, "toV": 8, "meta": {"users": [null], "start_ts": 0, "end_ts": 0},
             "labels": [{"id": "l", "comment": "first draft", "version": 8, "user_id": "b",
                         "created_at": "2026-11-06T18:52:57.223Z", "user_display_name": "Bob"}],
             "pathnames": ["main.tex"], "project_ops": []}]}))
        .unwrap();
        assert_eq!(page.next_before, None);
        assert_eq!(page.updates[0].project_ops[1].rename.as_ref().unwrap().new_pathname, "biblio.bib");
        assert_eq!(page.updates[1].meta.users[0], None);
        assert_eq!(page.updates[1].labels[0].comment, "first draft");

        let files: Vec<FileDiff> = serde_json::from_value(json!([
            {"pathname": "main.tex", "operation": "edited"},
            {"pathname": "u.tex", "operation": "removed", "deletedAtV": 9, "editable": true},
            {"pathname": "a.png", "editable": false}]))
        .unwrap();
        assert_eq!(files[1].deleted_at_v, Some(9));
        assert_eq!(files[2].operation, None);

        let d = parse_diff(&json!({"diff": [{"u": "a"}, {"i": "b", "meta": {"users": [{"id": "x"}], "start_ts": 1, "end_ts": 1}}]})).unwrap();
        assert!(matches!(d, DocDiff::Text(ref c) if c.len() == 2 && c[1].i.as_deref() == Some("b")));
        assert_eq!(parse_diff(&json!({"diff": {"binary": true}})).unwrap(), DocDiff::Binary);
        assert!(parse_diff(&json!({"nope": 1})).is_err());
    }

    #[test]
    fn display_names() {
        let u = |f: Option<&str>, l: Option<&str>, e: Option<&str>| HistoryUser {
            id: None,
            first_name: f.map(String::from),
            last_name: l.map(String::from),
            email: e.map(String::from),
        };
        assert_eq!(u(Some("Alice"), None, Some("a@x")).display_name(), "Alice");
        assert_eq!(u(Some("Ada"), Some("Lovelace"), None).display_name(), "Ada Lovelace");
        assert_eq!(u(None, None, Some("carol@x")).display_name(), "carol");
        assert_eq!(u(None, None, None).display_name(), "Anonymous");
    }
}
