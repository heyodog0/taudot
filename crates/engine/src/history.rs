//! `history.*`: a project's version history as Overleaf's History view shows it (`docs/api.md`, History;
//! routes in `docs/history.md`). Read-only.
//!
//! The calls run outside the project's actor, over a copy of its HTTP session ([`Cmd::Http`]), so a slow history
//! request never holds up editing. What can't change is cached in memory: a file's diff between two versions and the
//! file tree between two versions (history versions are never rewritten). The list of versions and the labels are
//! fetched each time, since new versions and labels arrive.
//!
//! [`Cmd::Http`]: crate::engine::Cmd::Http

use anyhow::{anyhow, Context};
use overleaf::history::{blob_hash, files_from_changes, hue_for_user, DocDiff, FileOp, HistoryMeta, HistoryUser, Label, LatestChunk};
use overleaf::Http;
use serde_json::{json, Value};
use std::collections::{HashMap, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};

pub const METHODS: &[&str] = &[
    "history.updates",
    "history.labels",
    "history.tree",
    "history.diff",
    "history.file",
    "history.files_at",
    "history.blob",
    "history.zip_files",
];

/// Most bytes of diffs kept in the cache, across projects.
const CACHE_BYTES: usize = 64 << 20;

#[derive(Default)]
struct Cache {
    map: HashMap<String, (Value, usize)>,
    order: VecDeque<String>,
    bytes: usize,
}

impl Cache {
    fn get(&self, k: &str) -> Option<Value> {
        self.map.get(k).map(|(v, _)| v.clone())
    }

    fn put(&mut self, k: String, v: Value) {
        let size = v.to_string().len();
        if size > CACHE_BYTES / 4 || self.map.contains_key(&k) {
            return;
        }
        while self.bytes + size > CACHE_BYTES {
            let Some(old) = self.order.pop_front() else { break };
            if let Some((_, n)) = self.map.remove(&old) {
                self.bytes -= n;
            }
        }
        self.bytes += size;
        self.order.push_back(k.clone());
        self.map.insert(k, (v, size));
    }
}

fn cache() -> &'static Mutex<Cache> {
    static C: OnceLock<Mutex<Cache>> = OnceLock::new();
    C.get_or_init(Default::default)
}

fn key(http: &Http, project_id: &str, what: &str) -> String {
    format!("{}|{project_id}|{what}", http.base)
}

fn u64_of(p: &Value, k: &str) -> anyhow::Result<u64> {
    p.get(k).and_then(Value::as_u64).ok_or_else(|| anyhow!("missing or bad param {k}"))
}

fn str_of<'a>(p: &'a Value, k: &str) -> anyhow::Result<&'a str> {
    p.get(k).and_then(Value::as_str).ok_or_else(|| anyhow!("missing param {k}"))
}

/// Run one of [`METHODS`] for `project_id` over `http`. `me` is the logged-in user's ID (for `mine` and the hue).
pub async fn call(http: &Http, me: Option<&str>, project_id: &str, method: &str, p: &Value) -> anyhow::Result<Value> {
    match method {
        "history.updates" => updates(http, me, project_id, p).await,
        "history.labels" => {
            let labels = http.history_labels(project_id).await.context("history labels")?;
            Ok(json!({"labels": labels.iter().map(|l| label_json(l, me)).collect::<Vec<_>>()}))
        }
        "history.tree" => {
            let (from, to) = (u64_of(p, "from")?, u64_of(p, "to")?);
            let k = key(http, project_id, &format!("tree|{from}|{to}"));
            if let Some(v) = cache().lock().unwrap().get(&k) {
                return Ok(v);
            }
            let files = http.history_tree(project_id, from, to).await.context("history file tree")?;
            let files: Vec<Value> = files
                .iter()
                .map(|f| {
                    json!({"path": f.pathname, "op": f.operation, "new_path": f.new_pathname,
                        "deleted_at_v": f.deleted_at_v,
                        // An edited file is always text; Overleaf leaves `editable` out for those.
                        "editable": f.editable.unwrap_or(f.operation.as_deref() == Some("edited"))})
                })
                .collect();
            let v = json!({"from": from, "to": to, "files": files});
            cache().lock().unwrap().put(k, v.clone());
            Ok(v)
        }
        "history.diff" => {
            let (from, to) = (u64_of(p, "from")?, u64_of(p, "to")?);
            diff(http, me, project_id, str_of(p, "path")?, from, to).await
        }
        "history.file" => {
            let v = u64_of(p, "version")?;
            let d = diff(http, me, project_id, str_of(p, "path")?, v, v).await?;
            Ok(json!({"path": d["path"], "version": v, "binary": d["binary"], "text": d["text"]}))
        }
        "history.files_at" => files_at(http, project_id, u64_of(p, "version")?).await,
        "history.blob" => {
            let hash = str_of(p, "hash")?;
            let (file, cached) = blob(http, BlobStore::shared(), project_id, hash).await?;
            Ok(json!({"hash": hash, "file": file, "cached": cached}))
        }
        "history.zip_files" => {
            let paths: Vec<String> = p
                .get("paths")
                .and_then(Value::as_array)
                .ok_or_else(|| anyhow!("missing param paths"))?
                .iter()
                .filter_map(|v| v.as_str().map(String::from))
                .collect();
            zip_files(http, BlobStore::shared(), project_id, u64_of(p, "version")?, &paths).await
        }
        _ => Err(anyhow!("unknown method {method}")),
    }
}

async fn updates(http: &Http, me: Option<&str>, project_id: &str, p: &Value) -> anyhow::Result<Value> {
    let min_count = p.get("min_count").and_then(Value::as_u64).unwrap_or(25).clamp(1, 500) as u32;
    let before = p.get("before").and_then(Value::as_u64);
    let page = http.history_updates(project_id, min_count, before).await.context("history updates")?;
    let updates: Vec<Value> = page
        .updates
        .iter()
        .map(|u| {
            let ops: Vec<Value> = u
                .project_ops
                .iter()
                .filter_map(|o| {
                    if let Some(a) = &o.add {
                        Some(json!({"op": "add", "path": a.pathname, "at_v": o.at_v}))
                    } else if let Some(r) = &o.rename {
                        Some(json!({"op": "rename", "path": r.pathname, "new_path": r.new_pathname, "at_v": o.at_v}))
                    } else {
                        o.remove.as_ref().map(|r| json!({"op": "remove", "path": r.pathname, "at_v": o.at_v}))
                    }
                })
                .collect();
            let mut v = json!({
                "from_v": u.from_v, "to_v": u.to_v,
                "start_ts": u.meta.start_ts, "end_ts": u.meta.end_ts,
                "users": users_json(&u.meta, me),
                "labels": u.labels.iter().map(|l| label_json(l, me)).collect::<Vec<_>>(),
                "paths": u.pathnames,
                "ops": ops,
            });
            if let Some(o) = &u.meta.origin {
                v["origin"] = o.clone();
            }
            v
        })
        .collect();
    // The newest version there is, when this page starts at the top.
    let head = if before.is_none() { page.updates.first().map(|u| u.to_v) } else { None };
    Ok(json!({"updates": updates, "next_before": page.next_before.filter(|n| *n > 0), "head": head}))
}

fn user_json(u: Option<&HistoryUser>, me: Option<&str>) -> Value {
    let Some(u) = u else {
        return json!({"user_id": null, "name": "Anonymous", "initials": "?", "hue": hue_for_user(None, me), "mine": false});
    };
    let name = u.display_name();
    let initials: String = name.split_whitespace().filter_map(|w| w.chars().next()).take(2).collect::<String>().to_uppercase();
    let id = u.id.as_deref();
    json!({"user_id": id, "name": name, "initials": initials, "hue": hue_for_user(id, me),
        "mine": id.is_some() && id == me})
}

fn users_json(meta: &HistoryMeta, me: Option<&str>) -> Vec<Value> {
    meta.users.iter().map(|u| user_json(u.as_ref(), me)).collect()
}

fn label_json(l: &Label, me: Option<&str>) -> Value {
    json!({"id": l.id, "comment": l.comment, "version": l.version, "user_id": l.user_id,
        "name": l.user_display_name, "created_at": l.created_at,
        "mine": l.user_id.is_some() && l.user_id.as_deref() == me})
}

/// `history.diff`: the file's text over the range as chunks, with byte offsets into `text` (the API's units).
async fn diff(http: &Http, me: Option<&str>, project_id: &str, path: &str, from: u64, to: u64) -> anyhow::Result<Value> {
    if from > to {
        return Err(anyhow!("from ({from}) is after to ({to})"));
    }
    // `mine` and `hue` depend on who asks, so the key has the viewer.
    let k = key(http, project_id, &format!("diff|{}|{from}|{to}|{path}", me.unwrap_or("")));
    if let Some(v) = cache().lock().unwrap().get(&k) {
        return Ok(v);
    }
    let d = http.history_diff(project_id, path, from, to).await.with_context(|| format!("history diff of {path}"))?;
    let v = match d {
        DocDiff::Binary => json!({"path": path, "from": from, "to": to, "binary": true, "text": null, "chunks": []}),
        DocDiff::Text(chunks) => {
            let mut text = String::new();
            let mut out = Vec::new();
            for c in &chunks {
                let (kind, s) = match (&c.i, &c.d, &c.u) {
                    (Some(s), _, _) => ("insert", s),
                    (_, Some(s), _) => ("delete", s),
                    (_, _, Some(s)) => ("same", s),
                    _ => continue,
                };
                if s.is_empty() {
                    continue;
                }
                let start = text.len();
                text.push_str(s);
                let mut c_json = json!({"kind": kind, "start": start, "end": text.len()});
                if kind != "same" {
                    let meta = c.meta.clone().unwrap_or_default();
                    c_json["user"] = user_json(meta.users.first().and_then(Option::as_ref), me);
                    c_json["ts"] = json!(meta.end_ts);
                }
                // Neighbouring runs of the same kind by the same user read as one.
                if let Some(last) = out.last_mut() {
                    let l: &mut Value = last;
                    if l["kind"] == c_json["kind"] && l["user"] == c_json["user"] && l["end"] == json!(start) {
                        l["end"] = json!(text.len());
                        if c_json["ts"].as_i64() > l["ts"].as_i64() {
                            l["ts"] = c_json["ts"].clone();
                        }
                        continue;
                    }
                }
                out.push(c_json);
            }
            let inserted: usize = out.iter().filter(|c| c["kind"] == "insert").map(len_of).sum();
            let deleted: usize = out.iter().filter(|c| c["kind"] == "delete").map(len_of).sum();
            json!({"path": path, "from": from, "to": to, "binary": false, "text": text, "chunks": out,
                "inserted": inserted, "deleted": deleted})
        }
    };
    cache().lock().unwrap().put(k, v.clone());
    Ok(v)
}

// ---- files and figures at a version ---------------------------------------------------------------------------------

/// What's known of a project's history to replay it, per server and project: the newest chunk (its prefix never
/// changes, so a version inside it needs no new request) and the changes from version 0 fetched so far (file
/// operations only, a few bytes a change).
#[derive(Default)]
struct Replays {
    latest: HashMap<String, Arc<LatestChunk>>,
    log: HashMap<String, Arc<Vec<Vec<FileOp>>>>,
}

fn replays() -> &'static Mutex<Replays> {
    static R: OnceLock<Mutex<Replays>> = OnceLock::new();
    R.get_or_init(Default::default)
}

/// `history.files_at`: every file at `version` with its blob hash and kind. Exact: replayed from history's own
/// changes. A version's files never change, so the answer is cached.
async fn files_at(http: &Http, project_id: &str, version: u64) -> anyhow::Result<Value> {
    let k = key(http, project_id, &format!("files_at|{version}"));
    if let Some(v) = cache().lock().unwrap().get(&k) {
        return Ok(v);
    }
    let pk = key(http, project_id, "");
    let known = replays().lock().unwrap().latest.get(&pk).cloned();
    let latest = match known {
        // A newer version than it knows needs the newest chunk again; an older one comes from the changes.
        Some(l) if version <= l.head() => l,
        _ => {
            let l = Arc::new(http.history_latest_chunk(project_id).await.context("history latest chunk")?);
            replays().lock().unwrap().latest.insert(pk.clone(), l.clone());
            l
        }
    };
    let (files, from) = if let Some(f) = latest.files_at(version) {
        (f, "latest_chunk")
    } else if version > latest.head() {
        return Err(anyhow!("version {version} is after the newest, {}", latest.head()));
    } else {
        let mut log: Vec<Vec<FileOp>> = replays().lock().unwrap().log.get(&pk).map(|l| l.as_ref().clone()).unwrap_or_default();
        while (log.len() as u64) < version {
            let (page, more) = http.history_changes(project_id, log.len() as u64).await.context("history changes")?;
            if page.is_empty() {
                break;
            }
            log.extend(page);
            if !more {
                break;
            }
        }
        let f = files_from_changes(&log, version).ok_or_else(|| anyhow!("history has {} versions, not {version}", log.len()))?;
        replays().lock().unwrap().log.insert(pk, Arc::new(log));
        (f, "changes")
    };
    let v = json!({"version": version, "head": latest.head(), "from": from, "files": files});
    cache().lock().unwrap().put(k, v.clone());
    Ok(v)
}

/// Blobs on disk by hash, shared by every project and version (a blob is checked against its hash before it is
/// kept, so where it came from doesn't matter). Least recently used out when over `max_bytes`.
pub struct BlobStore {
    pub root: PathBuf,
    pub max_bytes: u64,
    /// A blob used this recently isn't evicted (a path `get` handed out may be about to be read).
    pub grace: std::time::Duration,
}

impl BlobStore {
    /// `$TAUDOT_BLOB_CACHE`, else ~/Library/Caches/Taudot/blobs (macOS) or `$XDG_CACHE_HOME`/taudot/blobs;
    /// `$TAUDOT_BLOB_CACHE_BYTES` (default 2 GiB).
    pub fn shared() -> &'static BlobStore {
        static S: OnceLock<BlobStore> = OnceLock::new();
        S.get_or_init(|| {
            let root = std::env::var_os("TAUDOT_BLOB_CACHE").map(PathBuf::from).unwrap_or_else(|| {
                let home = PathBuf::from(std::env::var_os("HOME").unwrap_or_default());
                if cfg!(target_os = "macos") {
                    home.join("Library/Caches/Taudot/blobs")
                } else {
                    std::env::var_os("XDG_CACHE_HOME").map(PathBuf::from).unwrap_or(home.join(".cache")).join("taudot/blobs")
                }
            });
            let max_bytes = std::env::var("TAUDOT_BLOB_CACHE_BYTES").ok().and_then(|s| s.parse().ok()).unwrap_or(2 << 30);
            BlobStore { root, max_bytes, grace: std::time::Duration::from_secs(60) }
        })
    }

    fn path(&self, hash: &str) -> PathBuf {
        self.root.join(&hash[..2]).join(hash)
    }

    /// The blob's file when it's here (and marks it used).
    pub fn get(&self, hash: &str) -> Option<PathBuf> {
        let p = self.path(hash);
        let f = std::fs::File::options().append(true).open(&p).ok()?;
        let _ = f.set_modified(std::time::SystemTime::now());
        Some(p)
    }

    /// Keeps `bytes` if they hash to `hash`; its file.
    pub fn put(&self, hash: &str, bytes: &[u8]) -> anyhow::Result<PathBuf> {
        let got = blob_hash(bytes);
        if got != hash {
            return Err(anyhow!("blob {hash}: the bytes hash to {got}"));
        }
        let p = self.path(hash);
        std::fs::create_dir_all(p.parent().unwrap())?;
        let tmp = p.with_extension(format!("tmp{}-{:?}", std::process::id(), std::thread::current().id()).replace(['(', ')'], ""));
        std::fs::write(&tmp, bytes)?;
        std::fs::rename(&tmp, &p)?;
        self.evict(&p);
        Ok(p)
    }

    /// Oldest-used blobs out until the store is under its size (never `keep`).
    fn evict(&self, keep: &Path) {
        let mut all = Vec::new();
        for d in std::fs::read_dir(&self.root).into_iter().flatten().flatten() {
            for f in std::fs::read_dir(d.path()).into_iter().flatten().flatten() {
                if let Ok(m) = f.metadata() {
                    all.push((m.modified().unwrap_or(std::time::UNIX_EPOCH), m.len(), f.path()));
                }
            }
        }
        let mut total: u64 = all.iter().map(|a| a.1).sum();
        all.sort();
        // A blob used in the last minute may be about to be read through a path `get` handed out: it stays, even over
        // the size for a while.
        let recent = std::time::SystemTime::now() - self.grace;
        for (used, n, p) in all {
            if total <= self.max_bytes {
                break;
            }
            if p != keep && (self.grace.is_zero() || used < recent) && std::fs::remove_file(&p).is_ok() {
                total -= n;
            }
        }
    }
}

fn check_hash(hash: &str) -> anyhow::Result<()> {
    if hash.len() == 40 && hash.bytes().all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase()) {
        Ok(())
    } else {
        Err(anyhow!("bad blob hash {hash:?}"))
    }
}

/// `history.blob`: the blob's file in the store, fetched (`GET blob/:hash`) only when it isn't there. The bool: it
/// was there.
async fn blob(http: &Http, store: &BlobStore, project_id: &str, hash: &str) -> anyhow::Result<(PathBuf, bool)> {
    check_hash(hash)?;
    if let Some(p) = store.get(hash) {
        return Ok((p, true));
    }
    let bytes = http.history_blob(project_id, hash).await.with_context(|| format!("history blob {hash}"))?;
    Ok((store.put(hash, &bytes)?, false))
}

/// `history.zip_files`: the fallback when blobs can't be had. Fetches the project at `version` as a zip (Overleaf
/// allows 30 an hour) and keeps only `paths` from it, in the blob store by their hash.
async fn zip_files(http: &Http, store: &BlobStore, project_id: &str, version: u64, paths: &[String]) -> anyhow::Result<Value> {
    let bytes = http.history_version_zip(project_id, version).await.with_context(|| format!("history zip of version {version}"))?;
    let dir = std::env::temp_dir().join(format!("taudot-zip-{}-{version}-{}", std::process::id(), blob_hash(&bytes)));
    std::fs::create_dir_all(&dir)?;
    let zip = dir.join("v.zip");
    std::fs::write(&zip, &bytes)?;
    let mut out = Vec::new();
    for p in paths {
        // `unzip -p` writes one member to stdout. Its names are patterns, so their wildcards are escaped.
        let pattern: String = p.chars().flat_map(|c| if "[]*?\\".contains(c) { vec!['\\', c] } else { vec![c] }).collect();
        let o = tokio::process::Command::new("unzip").arg("-p").arg(&zip).arg(&pattern).output().await;
        match o {
            Ok(o) if o.status.success() => {
                let hash = blob_hash(&o.stdout);
                let file = store.put(&hash, &o.stdout)?;
                out.push(json!({"path": p, "hash": hash, "file": file}));
            }
            _ => out.push(json!({"path": p, "hash": null, "file": null})),
        }
    }
    let _ = std::fs::remove_dir_all(&dir);
    Ok(json!({"version": version, "files": out}))
}

fn len_of(c: &Value) -> usize {
    (c["end"].as_u64().unwrap_or(0) - c["start"].as_u64().unwrap_or(0)) as usize
}

#[cfg(test)]
mod tests {
    use super::*;
    use overleaf::history::fake::FakeHistory;

    const P: &str = "0123456789abcdef01234567";
    const ALICE: &str = "6ae7eb869c93d6e28d0854af";
    const BOB: &str = "6ae7eb869c93d6e28d0854b5";

    fn user(id: &str, first: &str) -> Value {
        json!({"id": id, "first_name": first, "email": format!("{}@x.test", first.to_lowercase())})
    }

    async fn fake() -> (FakeHistory, Http) {
        let f = FakeHistory::start().await;
        let http = Http::new(&f.url).unwrap();
        (f, http)
    }

    #[tokio::test]
    async fn updates_are_shaped_for_clients() {
        let (f, http) = fake().await;
        f.answer(
            &format!("/project/{P}/updates?min_count=10"),
            json!({"updates": [
                {"fromV": 8, "toV": 10, "meta": {"users": [user(ALICE, "Alice")], "start_ts": 3, "end_ts": 4},
                 "labels": [], "pathnames": [],
                 "project_ops": [{"remove": {"pathname": "u.tex"}, "atV": 9},
                                 {"rename": {"pathname": "refs.bib", "newPathname": "biblio.bib"}, "atV": 8}]},
                {"fromV": 5, "toV": 8, "meta": {"users": [user(BOB, "Bob"), null], "start_ts": 1, "end_ts": 2},
                 "labels": [{"id": "l1", "comment": "draft", "version": 8, "user_id": BOB,
                             "created_at": "2026-11-06T18:52:57.223Z", "user_display_name": "Bob"}],
                 "pathnames": ["main.tex"], "project_ops": []}],
                "nextBeforeTimestamp": 5}),
        );
        let v = call(&http, Some(ALICE), P, "history.updates", &json!({"min_count": 10})).await.unwrap();
        assert_eq!(v["head"], 10);
        assert_eq!(v["next_before"], 5);
        let u0 = &v["updates"][0];
        assert_eq!(u0["users"][0]["name"], "Alice");
        assert_eq!(u0["users"][0]["mine"], true);
        assert_eq!(u0["users"][0]["hue"], 200);
        assert_eq!(u0["ops"][0], json!({"op": "remove", "path": "u.tex", "at_v": 9}));
        assert_eq!(u0["ops"][1]["new_path"], "biblio.bib");
        let u1 = &v["updates"][1];
        assert_eq!(u1["users"][0]["hue"], 135);
        assert_eq!(u1["users"][0]["initials"], "B");
        assert_eq!(u1["users"][1]["name"], "Anonymous");
        assert_eq!(u1["labels"][0]["comment"], "draft");
        assert_eq!(u1["labels"][0]["mine"], false);
        assert_eq!(u1["paths"], json!(["main.tex"]));

        // Paging: `before` is passed through, and `head` is only known on the first page.
        f.answer(&format!("/project/{P}/updates?min_count=10&before=5"), json!({"updates": []}));
        let v = call(&http, Some(ALICE), P, "history.updates", &json!({"min_count": 10, "before": 5})).await.unwrap();
        assert_eq!(v["updates"], json!([]));
        assert_eq!(v["head"], Value::Null);
        assert_eq!(v["next_before"], Value::Null);
    }

    #[tokio::test]
    async fn diff_has_byte_offsets_and_authors_and_is_cached() {
        let (f, http) = fake().await;
        let path = format!("/project/{P}/diff?from=5&to=8&pathname=sections%2Fintro.tex");
        f.answer(
            &path,
            json!({"diff": [
                {"i": "% bob é\n", "meta": {"users": [user(BOB, "Bob")], "start_ts": 1, "end_ts": 7}},
                {"i": "more\n", "meta": {"users": [user(BOB, "Bob")], "start_ts": 1, "end_ts": 9}},
                {"u": "\\section{Intro}\n"},
                {"d": "old", "meta": {"users": [user(ALICE, "Alice")], "start_ts": 2, "end_ts": 2}},
                {"u": ""},
                {"u": " end\n"}]}),
        );
        let p = json!({"path": "sections/intro.tex", "from": 5, "to": 8});
        let v = call(&http, Some(ALICE), P, "history.diff", &p).await.unwrap();
        assert_eq!(v["binary"], false);
        let text = v["text"].as_str().unwrap();
        assert_eq!(text, "% bob é\nmore\n\\section{Intro}\nold end\n");
        let c = v["chunks"].as_array().unwrap();
        // Bob's two inserts merge; é is two bytes.
        assert_eq!(c.len(), 4);
        assert_eq!((c[0]["kind"].as_str(), c[0]["start"].as_u64(), c[0]["end"].as_u64()), (Some("insert"), Some(0), Some(14)));
        assert_eq!(c[0]["ts"], 9);
        assert_eq!(c[0]["user"]["name"], "Bob");
        assert_eq!(c[2]["kind"], "delete");
        assert_eq!(&text[c[2]["start"].as_u64().unwrap() as usize..c[2]["end"].as_u64().unwrap() as usize], "old");
        assert_eq!(c[2]["user"]["mine"], true);
        assert_eq!(c[3]["kind"], "same");
        assert!(c[3].get("user").is_none());
        assert_eq!(v["inserted"], 14);
        assert_eq!(v["deleted"], 3);

        // Second call from the cache.
        call(&http, Some(ALICE), P, "history.diff", &p).await.unwrap();
        assert_eq!(f.hits(&path), 1);
    }

    #[tokio::test]
    async fn file_tree_binary_and_errors() {
        let (f, http) = fake().await;
        f.answer(
            &format!("/project/{P}/filetree/diff?from=0&to=3"),
            json!({"diff": [{"pathname": "main.tex", "operation": "edited"},
                            {"pathname": "a.png", "editable": false},
                            {"pathname": "old.tex", "operation": "removed", "deletedAtV": 2, "editable": true},
                            {"pathname": "r.bib", "newPathname": "s.bib", "operation": "renamed", "editable": true}]}),
        );
        let v = call(&http, None, P, "history.tree", &json!({"from": 0, "to": 3})).await.unwrap();
        let files = v["files"].as_array().unwrap();
        assert_eq!(files[0], json!({"path": "main.tex", "op": "edited", "new_path": null, "deleted_at_v": null, "editable": true}));
        assert_eq!(files[1]["op"], Value::Null);
        assert_eq!(files[1]["editable"], false);
        assert_eq!(files[2]["deleted_at_v"], 2);
        assert_eq!(files[3]["new_path"], "s.bib");

        f.answer(&format!("/project/{P}/diff?from=3&to=3&pathname=a.png"), json!({"diff": {"binary": true}}));
        let v = call(&http, None, P, "history.file", &json!({"path": "a.png", "version": 3})).await.unwrap();
        assert_eq!(v["binary"], true);
        assert_eq!(v["text"], Value::Null);

        f.answer(&format!("/project/{P}/diff?from=3&to=3&pathname=main.tex"), json!({"diff": [{"u": "hello\n"}]}));
        let v = call(&http, None, P, "history.file", &json!({"path": "main.tex", "version": 3})).await.unwrap();
        assert_eq!(v["text"], "hello\n");

        // A path Overleaf doesn't know: CE answers 500 with an HTML page.
        let e = call(&http, None, P, "history.diff", &json!({"path": "nope.tex", "from": 0, "to": 3})).await.unwrap_err();
        assert!(format!("{e:#}").contains("500"), "{e:#}");
        let e = call(&http, None, P, "history.diff", &json!({"path": "main.tex", "from": 4, "to": 3})).await.unwrap_err();
        assert!(e.to_string().contains("after"));
    }


    fn store(name: &str, max_bytes: u64) -> BlobStore {
        let root = std::env::temp_dir().join(format!("taudot-blobs-test-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        BlobStore { root, max_bytes, grace: std::time::Duration::ZERO }
    }

    #[tokio::test]
    async fn files_at_is_cached_and_replays_older_versions_once() {
        let (f, http) = fake().await;
        let q = "0123456789abcdef0123456a"; // a project of its own: the replay cache is process-wide
        let red = blob_hash(b"red");
        let blue = blob_hash(b"blue");
        let add = |p: &str, h: &str| json!({"operations": [{"pathname": p, "file": {"hash": h, "byteLength": 3}}]});
        let changes = vec![
            add("fig.png", &red),
            json!({"operations": [{"pathname": "fig.png", "newPathname": ""}]}),
            add("fig.png", &blue),
        ];
        f.answer(&format!("/project/{q}/latest/history"),
            json!({"chunk": {"startVersion": 2, "history": {"snapshot": {"files": {}}, "changes": changes[2..].to_vec()}}}));
        f.answer(&format!("/project/{q}/changes?since=0&paginated=true"), json!({"changes": changes, "hasMore": false}));
        let v = call(&http, None, q, "history.files_at", &json!({"version": 3})).await.unwrap();
        assert_eq!(v["from"], "latest_chunk");
        assert_eq!(v["head"], 3);
        assert_eq!(v["files"], json!([{"path": "fig.png", "hash": blue, "kind": "binary"}]));
        let v = call(&http, None, q, "history.files_at", &json!({"version": 1})).await.unwrap();
        assert_eq!(v["from"], "changes");
        assert_eq!(v["files"][0]["hash"], json!(red));
        let v = call(&http, None, q, "history.files_at", &json!({"version": 2})).await.unwrap();
        assert_eq!(v["files"], json!([]));
        // Again: from memory. Version 2 is in the known chunk; 1 and 2 came from the kept log.
        for n in 1..=3 {
            call(&http, None, q, "history.files_at", &json!({"version": n})).await.unwrap();
        }
        assert_eq!(f.hits(&format!("/project/{q}/latest/history")), 1);
        assert_eq!(f.hits(&format!("/project/{q}/changes?since=0&paginated=true")), 1);
        let e = call(&http, None, q, "history.files_at", &json!({"version": 9})).await.unwrap_err();
        assert!(e.to_string().contains("after the newest"), "{e}");
    }

    #[tokio::test]
    async fn blobs_are_fetched_once_checked_and_evicted() {
        let (f, http) = fake().await;
        let s = store("fetch", 1 << 20);
        let red = blob_hash(b"red pixels");
        f.answer_raw(&format!("/project/{P}/blob/{red}"), b"red pixels");
        let (p, cached) = blob(&http, &s, P, &red).await.unwrap();
        assert!(!cached);
        assert_eq!(std::fs::read(&p).unwrap(), b"red pixels");
        let (p2, cached) = blob(&http, &s, P, &red).await.unwrap();
        assert!(cached);
        assert_eq!(p, p2);
        assert_eq!(f.hits(&format!("/project/{P}/blob/{red}")), 1);
        // the same blob for another project of the server: no request
        assert!(blob(&http, &s, "another", &red).await.unwrap().1);

        // Bytes that don't match their hash aren't kept.
        let liar = blob_hash(b"something else");
        f.answer_raw(&format!("/project/{P}/blob/{liar}"), b"red pixels");
        let e = blob(&http, &s, P, &liar).await.unwrap_err();
        assert!(e.to_string().contains("hash to"), "{e}");
        assert!(s.get(&liar).is_none());
        assert!(blob(&http, &s, P, "../../etc/passwd").await.is_err());
        assert!(blob(&http, &s, P, &blob_hash(b"nowhere")).await.is_err());

        // Over the size, least recently used out first.
        let s = store("evict", 25);
        let (a, b, c) = (blob_hash(b"aaaaaaaaaa"), blob_hash(b"bbbbbbbbbb"), blob_hash(b"cccccccccc"));
        s.put(&a, b"aaaaaaaaaa").unwrap();
        std::thread::sleep(std::time::Duration::from_millis(20));
        s.put(&b, b"bbbbbbbbbb").unwrap();
        std::thread::sleep(std::time::Duration::from_millis(20));
        assert!(s.get(&a).is_some()); // a used after b
        std::thread::sleep(std::time::Duration::from_millis(20));
        s.put(&c, b"cccccccccc").unwrap();
        assert!(s.get(&b).is_none());
        assert!(s.get(&a).is_some());
        assert!(s.get(&c).is_some());
        let _ = std::fs::remove_dir_all(&s.root);
    }

    #[tokio::test]
    async fn zip_fallback_keeps_only_the_paths_asked_for() {
        let (f, http) = fake().await;
        let s = store("zip", 1 << 20);
        let dir = std::env::temp_dir().join(format!("taudot-zip-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("figs [old]")).unwrap();
        std::fs::write(dir.join("main.tex"), "text").unwrap();
        std::fs::write(dir.join("figs [old]/a*.png"), "old figure").unwrap();
        let ok = std::process::Command::new("zip").current_dir(&dir).args(["-qr", "v.zip", "main.tex", "figs [old]"]).status().unwrap();
        assert!(ok.success());
        f.answer_raw(&format!("/project/{P}/version/4/zip"), &std::fs::read(dir.join("v.zip")).unwrap());
        let v = call_zip(&http, &s, &["figs [old]/a*.png", "gone.png"]).await;
        let got = &v["files"][0];
        assert_eq!(got["hash"], json!(blob_hash(b"old figure")));
        assert_eq!(std::fs::read(got["file"].as_str().unwrap()).unwrap(), b"old figure");
        assert_eq!(v["files"][1]["hash"], Value::Null);
        assert!(s.get(&blob_hash(b"text")).is_none(), "only what was asked for");
        let _ = std::fs::remove_dir_all(&dir);
        let _ = std::fs::remove_dir_all(&s.root);
    }

    async fn call_zip(http: &Http, s: &BlobStore, paths: &[&str]) -> Value {
        let paths: Vec<String> = paths.iter().map(|p| p.to_string()).collect();
        zip_files(http, s, P, 4, &paths).await.unwrap()
    }

    #[test]
    fn cache_evicts_oldest() {
        let mut c = Cache::default();
        let big = json!("x".repeat(CACHE_BYTES / 5));
        for i in 0..6 {
            c.put(format!("k{i}"), big.clone());
        }
        assert!(c.bytes <= CACHE_BYTES);
        assert!(c.get("k0").is_none());
        assert!(c.get("k5").is_some());
    }

    #[test]
    fn a_blob_just_handed_out_is_not_evicted() {
        // E20: `get` hands out a path; a `put` right after (over the size limit) evicted it before the caller read it.
        let root = std::env::temp_dir().join(format!("taudot-blobs-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let store = BlobStore { root: root.clone(), max_bytes: 10, grace: std::time::Duration::from_secs(60) };
        let (a, b) = (b"first blob".as_slice(), b"second blob".as_slice());
        store.put(&blob_hash(a), a).unwrap();
        let pa = store.get(&blob_hash(a)).unwrap();
        store.put(&blob_hash(b), b).unwrap();
        assert!(pa.exists(), "the blob just handed out was evicted");
        let _ = std::fs::remove_dir_all(&root);
    }
}
