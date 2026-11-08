//! A small fake of Overleaf's real-time service for tests (feature `fake`).
//!
//! One project `p1` (24 hex chars below) with one `sharejs-text-ot` doc `main.tex`. It answers the handshake,
//! `joinProjectResponse`, `joinDoc` (with `fromVersion` catch-up), and `applyOtUpdate` with the same confirmation and
//! broadcast rules as `DocumentUpdaterController.js`, including `dupIfSource`. Like the document updater, it transforms
//! an update made at an older version past the ops since (`ot` crate, the client's op on the left), and applies it.
//!
//! For race tests: [`FakeServer::pause`] holds incoming updates until [`FakeServer::resume`], so remote ops can land
//! first; [`FakeServer::remote_op`] injects a collaborator's op at any version; [`FakeServer::forget_before`] makes
//! `joinDoc(fromVersion)` fail as when the server no longer has old ops.
//!
//! In history-ot mode ([`FakeServer::start_history_ot`], or every server when `TAUDOT_FAKE_HISTORY_OT=1`) `main.tex`
//! is a `history-ot` doc: `joinDoc` sends the `StringFileData` snapshot, updates are lists of edit operations
//! transformed and applied with `ot::filedata`, and, like CE 6.3 (`docs/protocol.md`, history-ot versions), the `v`
//! of a broadcast, a confirmation and a catch-up op is the version the sender made it at, not the one it was applied
//! at. `state.text` is then the visible text; `state.fd` the whole doc.
//!
//! The frames are written from the CE source. Swap in recorded frames once CE runs locally.

use crate::sio::Frame;
use crate::text::encode_packed;
use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use crate::rest::{blob_hash, Kind};
use crate::tree::Tree;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::broadcast;
use tokio_tungstenite::tungstenite::Message;

pub const PROJECT_ID: &str = "0123456789abcdef01234567";
pub const DOC_ID: &str = "aaaaaaaaaaaaaaaaaaaaaaa1";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    Confirm,
    /// Apply the first update but swallow its confirmation, so the client must resend with `dupIfSource`.
    DropFirstConfirm,
}

#[derive(Debug)]
pub struct FakeState {
    pub text: String,
    pub version: u64,
    /// Applied updates, as broadcast (with `meta.source`).
    pub history: Vec<Value>,
    /// Every `applyOtUpdate` as received.
    pub received: Vec<Value>,
    pub cookies: Vec<String>,
    pub heartbeats_answered: usize,
    pub connections: usize,
    pub mode: Mode,
    dropped_confirm: bool,
    paused: bool,
    /// `joinDoc(fromVersion)` below this fails with the missing-ops error.
    forget_before: u64,
    /// The project's tree. `main.tex` is [`DOC_ID`], whose text is `text` above.
    pub tree: Tree,
    /// Binary files' bytes, by ID.
    pub files: HashMap<String, Vec<u8>>,
    /// Docs other than [`DOC_ID`]: text and version. Updates to them apply at the current version only.
    pub docs: HashMap<String, (String, u64)>,
    /// REST calls, as `"METHOD path"`.
    pub rest: Vec<String>,
    /// The dashboard's projects, as `POST /api/project` lists them (`ProjectListController._injectProjectUsers`).
    pub projects: Vec<Value>,
    /// Pages that need a login redirect to `/login`, as for an expired session.
    pub logged_out: bool,
    /// Refuse socket connections, as a server that is down (see [`FakeServer::set_offline`]).
    pub offline: bool,
    /// An `applyOtUpdate` whose JSON contains this is refused as the document updater refuses a bad op: acknowledged,
    /// then `otUpdateError` and a disconnect (`DocumentUpdaterController._processErrorFromDocumentUpdater`).
    pub reject_containing: Option<String>,
    /// Accept connections but never answer, as a half-open network: requests and handshakes hang.
    pub stall: bool,
    next_id: u64,
    /// `main.tex` is a history-ot doc; `fd` is its state, `fds` the state at each version (for remote ops made at an
    /// old one), and `applied_at` the real version of each entry of `history`.
    pub history_ot: bool,
    pub fd: ot::filedata::FileData,
    fds: Vec<(u64, ot::filedata::FileData)>,
    applied_at: Vec<u64>,
}

impl FakeState {
    fn new_id(&mut self) -> String {
        self.next_id += 1;
        format!("{:024x}", 0xf000 + self.next_id)
    }

    /// Text of a doc by path.
    pub fn doc_text(&self, path: &str) -> Option<String> {
        let id = self.tree.find(path)?;
        if id == DOC_ID {
            return Some(self.text.clone());
        }
        self.docs.get(&id).map(|(t, _)| t.clone())
    }

    /// `main.tex`'s (visible) text at version `v`.
    pub fn text_at(&self, v: u64) -> String {
        if self.history_ot {
            return self.fds.iter().rev().find(|(w, _)| *w <= v).map(|(_, f)| f.visible()).unwrap_or_default();
        }
        let mut t = self.text.clone();
        for h in self.history.iter().rev().take_while(|h| h["v"].as_u64().unwrap_or(0) >= v) {
            let op: ot::text::Op = serde_json::from_value(h["op"].clone()).unwrap();
            t = ot::text::apply(&t, &ot::text::invert(&op)).unwrap();
        }
        t
    }

    /// The op of the `k`th update received for `main.tex`, as a classic op on the text at its version: as sent for a
    /// classic doc, its effect on the visible text for a history-ot one.
    pub fn sent_classic(&self, k: usize) -> Value {
        let u = &self.received[k];
        if !self.history_ot {
            return u["op"].clone();
        }
        let v = u["v"].as_u64().unwrap_or(0);
        let mut fd = self.fds.iter().rev().find(|(w, _)| *w <= v).map(|(_, f)| f.clone()).unwrap_or_default();
        let ops = ot::filedata::ops_from_json(&u["op"]).unwrap();
        json!(fd.apply_projected(&ops).unwrap())
    }

    /// What a client would send for classic `op` on `main.tex` at version `v`: the op itself for a classic doc, the
    /// history-ot update for a history-ot one.
    pub fn wire_for(&self, v: u64, op: Value) -> Value {
        if !self.history_ot {
            return op;
        }
        let classic: ot::text::Op = serde_json::from_value(op).unwrap();
        let fd = self.fds.iter().rev().find(|(w, _)| *w <= v).map(|(_, f)| f.clone()).unwrap_or_default();
        ot::filedata::ops_json(&fd.to_wire(&classic, None).unwrap())
    }

    /// Bytes of a binary file by path.
    pub fn file(&self, path: &str) -> Option<Vec<u8>> {
        self.files.get(&self.tree.find(path)?).cloned()
    }
}

#[derive(Clone, Debug)]
enum Ctl {
    Broadcast(Value),
    /// Any other event, to every client.
    Event(String, Vec<Value>),
    DropAll,
    Resume,
}

pub struct FakeServer {
    pub base: String,
    pub state: Arc<Mutex<FakeState>>,
    ctl: broadcast::Sender<Ctl>,
}

impl FakeServer {
    /// A server whose `main.tex` is a history-ot doc holding `text`.
    pub async fn start_history_ot(text: &str, mode: Mode) -> FakeServer {
        FakeServer::start_as(text, mode, true).await
    }

    /// A server whose `main.tex` is classic, or history-ot when `TAUDOT_FAKE_HISTORY_OT=1`.
    pub async fn start(text: &str, mode: Mode) -> FakeServer {
        let hot = std::env::var("TAUDOT_FAKE_HISTORY_OT").is_ok_and(|v| v == "1");
        FakeServer::start_as(text, mode, hot).await
    }

    async fn start_as(text: &str, mode: Mode, history_ot: bool) -> FakeServer {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let state = Arc::new(Mutex::new(FakeState {
            text: text.into(),
            version: 7,
            history: vec![],
            received: vec![],
            cookies: vec![],
            heartbeats_answered: 0,
            connections: 0,
            mode,
            dropped_confirm: false,
            paused: false,
            forget_before: 0,
            tree: Tree::from_project(&json!({"rootFolder": [{"_id": "r", "name": "rootFolder",
                "docs": [{"_id": DOC_ID, "name": "main.tex"}], "fileRefs": [],
                "folders": [{"_id": "f", "name": "sections", "docs": [], "folders": [],
                    "fileRefs": [{"_id": "x", "name": "fig.png", "hash": blob_hash(FIG)}]}]}]})),
            files: HashMap::from([("x".to_string(), FIG.to_vec())]),
            docs: HashMap::new(),
            rest: vec![],
            projects: vec![
                json!({"id": PROJECT_ID, "name": "Fake paper", "archived": false, "trashed": false, "accessLevel": "owner",
                    "source": "owner", "lastUpdated": "2026-11-01T10:00:00.000Z",
                    "lastUpdatedBy": {"id": "u2", "email": "bob@x", "firstName": "Bob", "lastName": "Other"},
                    "owner": {"id": "u1", "email": "alice@x", "firstName": "Alice", "lastName": "Example"}}),
                json!({"id": "0123456789abcdef0123ffff", "name": "Shared thesis", "archived": true, "trashed": false,
                    "accessLevel": "readWrite", "source": "invite", "lastUpdated": "2026-10-01T10:00:00.000Z",
                    "lastUpdatedBy": null,
                    "owner": {"id": "u2", "email": "bob@x", "firstName": "Bob", "lastName": "Other"}}),
            ],
            logged_out: false,
            offline: false,
            reject_containing: None,
            stall: false,
            next_id: 0,
            history_ot,
            fd: ot::filedata::FileData::new(text),
            fds: vec![(7, ot::filedata::FileData::new(text))],
            applied_at: vec![],
        }));
        let (ctl, _) = broadcast::channel(64);
        let (s, c) = (state.clone(), ctl.clone());
        tokio::spawn(async move {
            loop {
                let Ok((stream, _)) = listener.accept().await else { return };
                tokio::spawn(handle(stream, s.clone(), c.clone()));
            }
        });
        FakeServer { base: format!("http://{addr}"), state, ctl }
    }

    /// A collaborator (`P.other`, user `u2`) inserts `text` at JS index `p`.
    /// A collaborator sends a history-ot update (a list of edit operations) made at version `v`.
    pub fn remote_history_ot(&self, v: u64, ops: Value) -> Result<u64, String> {
        let mut s = self.state.lock().unwrap();
        let applied = apply_history_ot(&mut s, v, &ops, "P.other", "u2")?;
        let _ = self.ctl.send(Ctl::Broadcast(applied));
        Ok(s.version - 1)
    }

    pub fn remote_insert(&self, p: usize, text: &str) {
        let v = self.state.lock().unwrap().version;
        self.remote_op(v, json!([{"p": p, "i": text}])).unwrap();
    }

    /// A collaborator (`P.other`, user `u2`) sends classic `op` made at version `v`. The server transforms it past
    /// newer ops and broadcasts it. Returns the version it was applied at.
    pub fn remote_op(&self, v: u64, op: Value) -> Result<u64, String> {
        let mut s = self.state.lock().unwrap();
        if s.history_ot {
            // The classic op on the visible text at `v`, as the update a browser would send.
            let classic: ot::text::Op = serde_json::from_value(op).map_err(|e| e.to_string())?;
            let at = s.fds.iter().rev().find(|(w, _)| *w <= v).map(|(_, f)| f.clone()).ok_or("no state at that version")?;
            let wire = at.to_wire(&classic, None).map_err(|e| e.to_string())?;
            drop(s);
            return self.remote_history_ot(v, ot::filedata::ops_json(&wire));
        }
        let applied = apply_update(&mut s, v, &op, "P.other", "u2")?;
        let at = applied["v"].as_u64().unwrap();
        let _ = self.ctl.send(Ctl::Broadcast(applied));
        Ok(at)
    }

    /// Broadcast `u` as an `otUpdateApplied` to every client, as is (no state change): a garbled or out-of-order
    /// update.
    pub fn broadcast_raw(&self, u: Value) {
        let _ = self.ctl.send(Ctl::Broadcast(u));
    }

    /// Hold incoming `applyOtUpdate`s (acknowledged only when processed) until [`FakeServer::resume`].
    pub fn pause(&self) {
        self.state.lock().unwrap().paused = true;
    }

    /// Process held updates, in the order they arrived on each connection.
    pub fn resume(&self) {
        self.state.lock().unwrap().paused = false;
        let _ = self.ctl.send(Ctl::Resume);
    }

    /// Make `joinDoc(fromVersion)` fail for versions below the current one.
    pub fn forget_history(&self) {
        let mut s = self.state.lock().unwrap();
        s.forget_before = s.version;
    }

    /// While on, socket connections are closed at once: the project changes "while the client is away" without it
    /// seeing events.
    pub fn set_offline(&self, on: bool) {
        self.state.lock().unwrap().offline = on;
        if on {
            let _ = self.ctl.send(Ctl::DropAll);
        }
    }

    /// Close every client connection, as a server restart would.
    pub fn drop_connections(&self) {
        let _ = self.ctl.send(Ctl::DropAll);
    }

    /// A collaborator adds a doc with `text` in the folder at `folder` (`""` for the root). Returns its ID.
    pub fn remote_new_doc(&self, folder: &str, name: &str, text: &str) -> String {
        let mut s = self.state.lock().unwrap();
        let parent = s.tree.find(folder).expect("folder");
        let id = s.new_id();
        s.tree.insert(&id, Kind::Doc, &parent, name, None);
        s.docs.insert(id.clone(), (text.to_string(), 0));
        let args = vec![json!(parent), json!({"_id": id, "name": name}), json!("editor"), json!("u2")];
        let _ = self.ctl.send(Ctl::Event("reciveNewDoc".into(), args));
        id
    }

    /// A collaborator uploads a binary file into `folder`. An existing file of that name is replaced, as Overleaf
    /// does: `removeEntity(old)`, then `reciveNewFile` with a new ID.
    pub fn remote_new_file(&self, folder: &str, name: &str, bytes: &[u8]) -> String {
        let mut s = self.state.lock().unwrap();
        let (id, events) = add_file(&mut s, folder, name, bytes);
        for (n, a) in events {
            let _ = self.ctl.send(Ctl::Event(n, a));
        }
        id
    }

    /// A collaborator adds a folder. Returns its ID.
    pub fn remote_new_folder(&self, parent: &str, name: &str) -> String {
        let mut s = self.state.lock().unwrap();
        let p = s.tree.find(parent).expect("folder");
        let id = s.new_id();
        s.tree.insert(&id, Kind::Folder, &p, name, None);
        let args = vec![json!(p), json!({"_id": id, "name": name, "docs": [], "fileRefs": [], "folders": []}), json!("u2")];
        let _ = self.ctl.send(Ctl::Event("reciveNewFolder".into(), args));
        id
    }

    pub fn remote_rename(&self, path: &str, name: &str) {
        let mut s = self.state.lock().unwrap();
        let id = s.tree.find(path).expect("entity");
        let args = vec![json!(id), json!(name)];
        s.tree.apply_event("reciveEntityRename", &args);
        let _ = self.ctl.send(Ctl::Event("reciveEntityRename".into(), args));
    }

    pub fn remote_move(&self, path: &str, folder: &str) {
        let mut s = self.state.lock().unwrap();
        let id = s.tree.find(path).expect("entity");
        let f = s.tree.find(folder).expect("folder");
        let args = vec![json!(id), json!(f)];
        s.tree.apply_event("reciveEntityMove", &args);
        let _ = self.ctl.send(Ctl::Event("reciveEntityMove".into(), args));
    }

    pub fn remote_delete(&self, path: &str) {
        let mut s = self.state.lock().unwrap();
        let id = s.tree.find(path).expect("entity");
        s.tree.remove(&id);
        s.docs.remove(&id);
        let _ = self.ctl.send(Ctl::Event("removeEntity".into(), vec![json!(id), json!("editor")]));
    }
}

/// The fake's starting figure, `sections/fig.png`.
pub const FIG: &[u8] = &[0x89, b'P', b'N', b'G', 0, 1, 2, 3];

/// Add or replace a binary file. Returns its ID and the events to send.
fn add_file(s: &mut FakeState, folder: &str, name: &str, bytes: &[u8]) -> (String, Vec<(String, Vec<Value>)>) {
    let parent = s.tree.find(folder).expect("folder");
    let mut events = vec![];
    let path = if folder.is_empty() { name.to_string() } else { format!("{folder}/{name}") };
    if let Some(old) = s.tree.find(&path) {
        s.tree.remove(&old);
        s.files.remove(&old);
        events.push(("removeEntity".to_string(), vec![json!(old), json!("upload")]));
    }
    let id = s.new_id();
    let hash = blob_hash(bytes);
    s.tree.insert(&id, Kind::File, &parent, name, Some(hash.clone()));
    s.files.insert(id.clone(), bytes.to_vec());
    let file = json!({"_id": id, "name": name, "hash": hash, "rev": 0, "linkedFileData": null});
    events.push(("reciveNewFile".to_string(), vec![json!(parent), file, json!("upload"), json!(null), json!("u2")]));
    (id, events)
}

/// The project as `joinProjectResponse` carries it.
fn project_json(t: &Tree) -> Value {
    fn folder(t: &Tree, id: &str, name: &str) -> Value {
        let mut docs = vec![];
        let mut files = vec![];
        let mut folders = vec![];
        let mut kids = t.children(id);
        kids.sort();
        for c in kids {
            let e = &t.entities[&c];
            match e.kind {
                Kind::Doc => docs.push(json!({"_id": c, "name": e.name})),
                Kind::File => files.push(json!({"_id": c, "name": e.name, "hash": e.hash})),
                Kind::Folder => folders.push(folder(t, &c, &e.name)),
            }
        }
        json!({"_id": id, "name": name, "docs": docs, "fileRefs": files, "folders": folders})
    }
    json!({"_id": PROJECT_ID, "name": "Fake", "compiler": "pdflatex", "imageName": "quay.io/sharelatex/texlive-full:2026.1", "rootDoc_id": DOC_ID, "rootFolder": [folder(t, &t.root, "rootFolder")],
        "owner": {"_id": "u1", "first_name": "Alice", "last_name": "", "email": "alice@x"}, "members": []})
}

/// A whole HTTP request: method, path with query, headers (lowercase names), body.
struct Request {
    method: String,
    path: String,
    headers: HashMap<String, String>,
    body: Vec<u8>,
}

async fn read_request(stream: &mut TcpStream) -> Option<Request> {
    let mut buf = vec![];
    let mut chunk = [0u8; 8192];
    let head_end = loop {
        if let Some(i) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            break i + 4;
        }
        let n = stream.read(&mut chunk).await.ok()?;
        if n == 0 {
            return None;
        }
        buf.extend_from_slice(&chunk[..n]);
    };
    let head = String::from_utf8_lossy(&buf[..head_end]).to_string();
    let mut lines = head.lines();
    let mut first = lines.next()?.split(' ');
    let (method, path) = (first.next()?.to_string(), first.next()?.to_string());
    let headers: HashMap<String, String> = lines
        .filter_map(|l| l.split_once(": ").map(|(k, v)| (k.to_ascii_lowercase(), v.to_string())))
        .collect();
    let len: usize = headers.get("content-length").and_then(|v| v.parse().ok()).unwrap_or(0);
    while buf.len() < head_end + len {
        let n = stream.read(&mut chunk).await.ok()?;
        if n == 0 {
            break;
        }
        buf.extend_from_slice(&chunk[..n]);
    }
    Some(Request { method, path, headers, body: buf[head_end..].to_vec() })
}

/// Fields of a `multipart/form-data` body: name -> bytes.
fn multipart(req: &Request) -> HashMap<String, Vec<u8>> {
    let mut out = HashMap::new();
    let Some(b) = req.headers.get("content-type").and_then(|c| c.split("boundary=").nth(1)) else { return out };
    let sep = format!("--{}", b.trim_matches('"'));
    let body = &req.body;
    let mut starts = vec![];
    let mut i = 0;
    while let Some(p) = body[i..].windows(sep.len()).position(|w| w == sep.as_bytes()) {
        starts.push(i + p);
        i += p + sep.len();
    }
    for w in starts.windows(2) {
        let part = &body[w[0] + sep.len()..w[1]];
        let Some(h) = part.windows(4).position(|x| x == b"\r\n\r\n") else { continue };
        let head = String::from_utf8_lossy(&part[..h]);
        let Some(name) = head.split("name=\"").nth(1).and_then(|s| s.split('"').next()) else { continue };
        let data = &part[h + 4..part.len().saturating_sub(2)];
        out.insert(name.to_string(), data.to_vec());
    }
    out
}

/// Overleaf makes text a doc when it has no NUL and no astral character (`FileTypeManager.isEditable`), for text
/// extensions.
fn is_editable(name: &str, bytes: &[u8]) -> bool {
    let text_ext = [".tex", ".bib", ".txt", ".md", ".cls", ".sty", ".bst"].iter().any(|e| name.ends_with(e));
    text_ext && std::str::from_utf8(bytes).is_ok_and(|t| !t.contains('\0') && t.chars().all(|c| (c as u32) < 0x10000))
}

fn http_response(status: &str, content_type: &str, body: &[u8]) -> Vec<u8> {
    let mut r = format!("HTTP/1.1 {status}\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", body.len())
        .into_bytes();
    r.extend_from_slice(body);
    r
}

/// The REST side: the project page (CSRF token, user), file download, upload, and tree changes. Returns the response.
fn rest(req: &Request, state: &Mutex<FakeState>, ctl: &broadcast::Sender<Ctl>) -> Vec<u8> {
    let mut s = state.lock().unwrap();
    let path = req.path.split('?').next().unwrap_or("").to_string();
    let query = req.path.split_once('?').map(|(_, q)| q.to_string()).unwrap_or_default();
    s.rest.push(format!("{} {path}", req.method));
    let parts: Vec<&str> = path.trim_matches('/').split('/').collect();
    let ok = |v: Value| http_response("200 OK", "application/json", v.to_string().as_bytes());
    let send = |events: Vec<(String, Vec<Value>)>| {
        for (n, a) in events {
            let _ = ctl.send(Ctl::Event(n, a));
        }
    };
    let body: Value = serde_json::from_slice(&req.body).unwrap_or(Value::Null);
    let csrf_ok = req.headers.get("x-csrf-token").map(String::as_str) == Some("fake-csrf");
    if req.method != "GET" && !csrf_ok {
        return http_response("403 Forbidden", "text/plain", b"invalid csrf token");
    }
    if s.logged_out && !matches!(parts.as_slice(), ["login"]) {
        return b"HTTP/1.1 302 Found\r\nLocation: /login\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".to_vec();
    }
    match (req.method.as_str(), parts.as_slice()) {
        ("GET", ["login"]) => http_response("200 OK", "text/html", b"<form>log in</form>"),
        ("POST", ["project", "new"]) => {
            let id = s.new_id();
            let name = body["projectName"].as_str().unwrap_or("Untitled").to_string();
            s.projects.insert(0, json!({"id": id, "name": name, "archived": false, "trashed": false, "accessLevel": "owner",
                "source": "owner", "lastUpdated": "2026-11-03T12:00:00.000Z", "lastUpdatedBy": null,
                "owner": {"id": "u1", "email": "alice@x", "firstName": "Alice", "lastName": "Example"}}));
            ok(json!({"project_id": id, "owner_ref": "u1"}))
        }
        ("POST", ["api", "project"]) => ok(json!({"totalSize": s.projects.len(), "projects": s.projects})),
        ("GET", ["user", "projects"]) => ok(json!({"projects": s.projects.iter()
            .filter(|p| !(p["archived"] == true || p["trashed"] == true))
            .map(|p| json!({"_id": p["id"], "name": p["name"], "accessLevel": p["accessLevel"]})).collect::<Vec<_>>()})),
        ("GET", ["project"]) | ("GET", ["project", _]) => http_response(
            "200 OK",
            "text/html",
            br#"<meta name="ol-csrfToken" content="fake-csrf"><meta name="ol-user_id" content="u1"><meta name="ol-usersEmail" content="alice@x">"#,
        ),
        ("GET", ["user", "settings"]) => http_response(
            "200 OK",
            "text/html",
            br#"<meta name="ol-csrfToken" content="fake-csrf"><meta name="ol-user_id" content="u1"><meta name="ol-usersEmail" content="alice@x"><meta name="ol-user" data-type="json" content="{&quot;email&quot;:&quot;alice@x&quot;,&quot;first_name&quot;:&quot;Alice&quot;,&quot;last_name&quot;:&quot;Example&quot;}">"#,
        ),
        ("GET", ["Project", _, "file", id]) => match s.files.get(*id) {
            Some(b) => http_response("200 OK", "application/octet-stream", b),
            None => http_response("404 Not Found", "text/plain", b"no such file"),
        },
        ("POST", ["Project", _, "upload"]) => {
            let f = multipart(req);
            let name = String::from_utf8_lossy(f.get("name").map(Vec::as_slice).unwrap_or(b"")).to_string();
            let Some(bytes) = f.get("qqfile").cloned() else { return http_response("422 Unprocessable", "application/json", b"{}") };
            let folder_id = query.split('&').find_map(|kv| kv.strip_prefix("folder_id=")).unwrap_or("").to_string();
            let Some(folder) = s.tree.path(&folder_id) else {
                return http_response("422 Unprocessable", "application/json", br#"{"success":false,"error":"folder_not_found"}"#);
            };
            let path = if folder.is_empty() { name.clone() } else { format!("{folder}/{name}") };
            let existing = s.tree.find(&path);
            if is_editable(&name, &bytes) {
                let text = String::from_utf8(bytes).unwrap();
                if let Some(id) = existing.filter(|id| s.tree.get(id).is_some_and(|e| e.kind == Kind::Doc)) {
                    // upsertDoc: whole content replaced.
                    if id == DOC_ID {
                        s.text = text;
                        s.version += 1;
                    } else if let Some(d) = s.docs.get_mut(&id) {
                        *d = (text, d.1 + 1);
                    }
                    return ok(json!({"success": true, "entity_id": id, "entity_type": "doc"}));
                }
                let id = s.new_id();
                s.tree.insert(&id, Kind::Doc, &folder_id, &name, None);
                s.docs.insert(id.clone(), (text, 0));
                send(vec![("reciveNewDoc".into(), vec![json!(folder_id), json!({"_id": id, "name": name}), json!("upload"), json!("u1")])]);
                return ok(json!({"success": true, "entity_id": id, "entity_type": "doc"}));
            }
            let (id, events) = add_file(&mut s, &folder, &name, &bytes);
            send(events);
            ok(json!({"success": true, "entity_id": id, "entity_type": "file", "hash": blob_hash(&bytes)}))
        }
        ("POST", ["project", _, "doc"]) | ("POST", ["project", _, "folder"]) => {
            let is_doc = parts[2] == "doc";
            let name = body["name"].as_str().unwrap_or("").to_string();
            let parent = body["parent_folder_id"].as_str().unwrap_or("").to_string();
            let Some(folder) = s.tree.path(&parent) else { return http_response("404 Not Found", "text/plain", b"no folder") };
            let path = if folder.is_empty() { name.clone() } else { format!("{folder}/{name}") };
            if s.tree.find(&path).is_some() {
                return http_response("400 Bad Request", "text/plain", b"file already exists");
            }
            let id = s.new_id();
            if is_doc {
                s.tree.insert(&id, Kind::Doc, &parent, &name, None);
                s.docs.insert(id.clone(), (String::new(), 0));
                send(vec![("reciveNewDoc".into(), vec![json!(parent), json!({"_id": id, "name": name}), json!("editor"), json!("u1")])]);
            } else {
                s.tree.insert(&id, Kind::Folder, &parent, &name, None);
                let f = json!({"_id": id, "name": name, "docs": [], "fileRefs": [], "folders": []});
                send(vec![("reciveNewFolder".into(), vec![json!(parent), f, json!("u1")])]);
            }
            ok(json!({"_id": id, "name": name}))
        }
        ("POST", ["project", _, _, id, action @ ("rename" | "move")]) => {
            let (event, args) = if *action == "rename" {
                ("reciveEntityRename", vec![json!(id), body["name"].clone()])
            } else {
                ("reciveEntityMove", vec![json!(id), body["folder_id"].clone()])
            };
            if s.tree.apply_event(event, &args).is_none() && s.tree.get(id).is_none() {
                return http_response("404 Not Found", "text/plain", b"no entity");
            }
            send(vec![(event.into(), args)]);
            http_response("204 No Content", "text/plain", b"")
        }
        ("DELETE", ["project", _, _, id]) => {
            if s.tree.remove(id).is_none() {
                return http_response("404 Not Found", "text/plain", b"no entity");
            }
            s.files.remove(*id);
            s.docs.remove(*id);
            send(vec![("removeEntity".into(), vec![json!(id), json!("editor")])]);
            http_response("204 No Content", "text/plain", b"")
        }
        _ => http_response("404 Not Found", "text/plain", b"not found"),
    }
}

/// Transforms `op` made at `v` past newer history, as the document updater does, and applies it. Returns the update
/// as broadcast.
fn apply_update(s: &mut FakeState, v: u64, op: &Value, source: &str, user: &str) -> Result<Value, String> {
    if v > s.version {
        return Err(format!("Version mismatch: update v{v} is ahead of the doc at v{}", s.version));
    }
    let mut op: ot::text::Op = serde_json::from_value(op.clone()).map_err(|e| e.to_string())?;
    for h in s.history.iter().filter(|h| h["v"].as_u64().unwrap_or(0) >= v) {
        let past: ot::text::Op = serde_json::from_value(h["op"].clone()).map_err(|e| e.to_string())?;
        op = ot::text::transform(&op, &past, ot::text::Side::Left).map_err(|e| e.to_string())?;
    }
    s.text = ot::text::apply(&s.text, &op).map_err(|e| format!("Delete component does not match: {e}"))?;
    let applied = json!({"doc": DOC_ID, "v": s.version, "op": op,
        "meta": {"source": source, "user_id": user, "ts": 1}});
    s.version += 1;
    s.history.push(applied.clone());
    Ok(applied)
}

/// The history-ot version of [`apply_update`]: transformed past what was applied since `v` (ours first on ties),
/// applied, and broadcast with `v` as the sender made it (CE 6.3's bug).
fn apply_history_ot(s: &mut FakeState, v: u64, op: &Value, source: &str, user: &str) -> Result<Value, String> {
    use ot::filedata;
    if v > s.version {
        return Err(format!("Version mismatch: update v{v} is ahead of the doc at v{}", s.version));
    }
    let mut ops = filedata::ops_from_json(op)?;
    for (h, at) in s.history.iter().zip(&s.applied_at) {
        if *at >= v {
            let past = filedata::ops_from_json(&h["op"])?;
            ops = filedata::transform(&ops, &past).map_err(|e| e.to_string())?.0;
        }
    }
    let mut fd = s.fd.clone();
    fd.apply_all(&ops).map_err(|_| "Both operations have to have the same base length".to_string())?;
    s.fd = fd;
    s.text = s.fd.visible();
    let applied = json!({"doc": DOC_ID, "v": v, "op": filedata::ops_json(&ops),
        "meta": {"source": source, "user_id": user, "ts": 1_700_000_000_000u64 + s.version}});
    s.applied_at.push(s.version);
    s.version += 1;
    s.history.push(applied.clone());
    let (ver, fd) = (s.version, s.fd.clone());
    s.fds.push((ver, fd));
    Ok(applied)
}

fn frame(f: Frame) -> Message {
    Message::Text(f.to_string())
}

fn event(name: &str, args: Vec<Value>) -> Message {
    frame(Frame::Event { name: name.into(), args, ack: None })
}

async fn handle(mut stream: TcpStream, state: Arc<Mutex<FakeState>>, ctl: broadcast::Sender<Ctl>) {
    if state.lock().unwrap().stall {
        std::future::pending::<()>().await; // (the stream stays open: it is dropped only when this returns)
    }
    let mut buf = [0u8; 8192];
    let Ok(n) = stream.peek(&mut buf).await else { return };
    let head = String::from_utf8_lossy(&buf[..n]).to_string();
    let first = head.lines().next().unwrap_or("").to_string();
    if let Some(c) = head.lines().find_map(|l| {
        let (k, v) = l.split_once(": ")?;
        k.eq_ignore_ascii_case("cookie").then_some(v)
    }) {
        state.lock().unwrap().cookies.push(c.to_string());
    }
    if !first.contains("/socket.io/1/websocket/") {
        let Some(req) = read_request(&mut stream).await else { return };
        let resp = if req.path.starts_with("/socket.io/1/") {
            http_response("200 OK", "text/plain", b"sid123:60:60:websocket,xhr-polling")
        } else {
            rest(&req, &state, &ctl)
        };
        let _ = stream.write_all(&resp).await;
        return;
    }
    let Ok(mut ws) = tokio_tungstenite::accept_async(stream).await else { return };
    if state.lock().unwrap().offline {
        let _ = ws.close(None).await;
        return;
    }
    let public_id = {
        let mut s = state.lock().unwrap();
        s.connections += 1;
        format!("P.{}", s.connections)
    };
    let _ = ws.send(frame(Frame::Connect)).await;
    if !first.contains("projectId=") {
        let msg = json!({"message": "missing/bad ?projectId=... query flag on handshake"});
        let _ = ws.send(event("connectionRejected", vec![msg])).await;
        let _ = ws.close(None).await;
        return;
    }
    let _ = ws.send(frame(Frame::Heartbeat)).await;
    let project = project_json(&state.lock().unwrap().tree);
    let _ = ws
        .send(event(
            "joinProjectResponse",
            vec![json!({"publicId": public_id, "project": project, "permissionsLevel": "owner", "protocolVersion": 2})],
        ))
        .await;
    let mut ctl_rx = ctl.subscribe();
    let mut held: Vec<(Vec<Value>, Option<u64>)> = vec![];
    loop {
        tokio::select! {
            c = ctl_rx.recv() => match c {
                Ok(Ctl::Broadcast(u)) => {
                    let to_sender = u["meta"]["source"] == json!(public_id);
                    let msg = if to_sender { json!({"v": u["v"], "doc": u["doc"]}) } else { u };
                    if ws.send(event("otUpdateApplied", vec![msg])).await.is_err() { return; }
                }
                Ok(Ctl::Event(name, args)) => {
                    if ws.send(event(&name, args)).await.is_err() { return; }
                }
                Ok(Ctl::Resume) => {
                    for (args, ack) in std::mem::take(&mut held) {
                        let reply = on_event("applyOtUpdate", &args, &state, &ctl, &public_id);
                        if let (Some(id), Some(r)) = (ack, reply) {
                            let _ = ws.send(frame(Frame::Ack { id, args: r })).await;
                        }
                    }
                }
                Ok(Ctl::DropAll) | Err(_) => { let _ = ws.close(None).await; return; }
            },
            m = ws.next() => {
                let Some(Ok(Message::Text(t))) = m else { return };
                let Ok(f) = Frame::parse(&t) else { continue };
                match f {
                    Frame::Heartbeat => state.lock().unwrap().heartbeats_answered += 1,
                    Frame::Event { name, args, ack } if name == "applyOtUpdate" && state.lock().unwrap().paused => {
                        held.push((args, ack));
                    }
                    Frame::Event { name, args, ack } if name == "applyOtUpdate" && rejects(&state, &args) => {
                        state.lock().unwrap().received.push(args.get(1).cloned().unwrap_or(Value::Null));
                        if let Some(id) = ack {
                            let _ = ws.send(frame(Frame::Ack { id, args: vec![] })).await;
                        }
                        let doc = args.first().cloned().unwrap_or(Value::Null);
                        let _ = ws.send(event("otUpdateError", vec![json!("Delete component does not match"), json!({"doc_id": doc})])).await;
                        let _ = ws.close(None).await;
                        return;
                    }
                    Frame::Event { name, args, ack } => {
                        let reply = on_event(&name, &args, &state, &ctl, &public_id);
                        if let (Some(id), Some(r)) = (ack, reply) {
                            let _ = ws.send(frame(Frame::Ack { id, args: r })).await;
                        }
                    }
                    _ => {}
                }
            }
        }
    }
}

fn on_event(
    name: &str,
    args: &[Value],
    state: &Mutex<FakeState>,
    ctl: &broadcast::Sender<Ctl>,
    public_id: &str,
) -> Option<Vec<Value>> {
    let mut s = state.lock().unwrap();
    match name {
        "joinDoc" if args.first().and_then(Value::as_str) != Some(DOC_ID) => {
            let id = args.first().and_then(Value::as_str).unwrap_or("");
            let Some((text, v)) = s.docs.get(id) else { return Some(vec![json!({"message": "not found"})]) };
            let lines: Vec<Value> = text.split('\n').map(|l| json!(encode_packed(l))).collect();
            Some(vec![Value::Null, json!(lines), json!(v), json!([]), json!({}), json!("sharejs-text-ot"), json!({"canSkipLeaveDoc": true})])
        }
        "applyOtUpdate" if args.first().and_then(Value::as_str) != Some(DOC_ID) => {
            let u = args.get(1).cloned().unwrap_or(Value::Null);
            s.received.push(u.clone());
            let id = args.first().and_then(Value::as_str).unwrap_or("").to_string();
            let Some((text, v)) = s.docs.get(&id).cloned() else { return Some(vec![json!({"message": "not found"})]) };
            if u["v"].as_u64() != Some(v) {
                return Some(vec![json!({"message": "fake: extra docs take updates at the current version only"})]);
            }
            let op: ot::text::Op = match serde_json::from_value(u["op"].clone()) { Ok(o) => o, Err(e) => return Some(vec![json!({"message": e.to_string()})]) };
            let Ok(t) = ot::text::apply(&text, &op) else { return Some(vec![json!({"message": "Delete component does not match"})]) };
            s.docs.insert(id.clone(), (t, v + 1));
            let applied = json!({"doc": id, "v": v, "op": op, "meta": {"source": public_id, "user_id": "u1", "ts": 1}});
            let _ = ctl.send(Ctl::Broadcast(applied));
            Some(vec![])
        }
        "joinDoc" => {
            let from = args.get(1).and_then(Value::as_i64).unwrap_or(-1);
            if from >= 0 && (from as u64) < s.forget_before {
                return Some(vec![json!({"message": "doc updater could not load requested ops"})]);
            }
            if s.history_ot {
                let ops: Vec<Value> = if from < 0 {
                    vec![]
                } else {
                    s.history.iter().zip(&s.applied_at).filter(|(_, at)| **at as i64 >= from).map(|(u, _)| u.clone()).collect()
                };
                return Some(vec![Value::Null, s.fd.to_json(), json!(s.version), json!(ops), json!({}), json!("history-ot"),
                    json!({"canSkipLeaveDoc": true})]);
            }
            let lines: Vec<Value> = s.text.split('\n').map(|l| json!(encode_packed(l))).collect();
            let ops: Vec<Value> = if from < 0 {
                vec![]
            } else {
                s.history.iter().filter(|u| u["v"].as_i64().unwrap_or(0) >= from).cloned().collect()
            };
            Some(vec![Value::Null, json!(lines), json!(s.version), json!(ops), json!({}), json!("sharejs-text-ot"),
                json!({"canSkipLeaveDoc": true})])
        }
        "applyOtUpdate" => {
            let u = args.get(1).cloned().unwrap_or(Value::Null);
            s.received.push(u.clone());
            let v = u["v"].as_u64().unwrap_or(0);
            // dupIfSource: an op from one of those sources at or after v was already applied.
            let dup_sources: Vec<String> = u["dupIfSource"]
                .as_array()
                .map(|a| a.iter().filter_map(|x| x.as_str().map(String::from)).collect())
                .unwrap_or_default();
            let hot = s.history_ot;
            let dup = s.history.iter().enumerate().find(|(k, h)| {
                let at = if hot { s.applied_at[*k] } else { h["v"].as_u64().unwrap_or(0) };
                at >= v && h["meta"]["source"].as_str().is_some_and(|src| dup_sources.iter().any(|d| d == src))
            }).map(|(_, h)| h);
            if let Some(h) = dup {
                // Only the sender hears about a dup.
                let mut h = h.clone();
                h["meta"]["source"] = json!(public_id);
                h["dup"] = json!(true);
                let _ = ctl.send(Ctl::Broadcast(h));
                return Some(vec![]);
            }
            let applied = if s.history_ot {
                apply_history_ot(&mut s, v, &u["op"], public_id, "u1")
            } else {
                apply_update(&mut s, v, &u["op"], public_id, "u1")
            };
            let applied = match applied {
                Ok(a) => a,
                Err(e) => return Some(vec![json!({"message": e})]),
            };
            if s.mode == Mode::DropFirstConfirm && !s.dropped_confirm {
                s.dropped_confirm = true;
            } else {
                let _ = ctl.send(Ctl::Broadcast(applied));
            }
            Some(vec![])
        }
        "clientTracking.updatePosition" => None,
        "clientTracking.getConnectedUsers" => Some(vec![Value::Null, json!([])]),
        _ => Some(vec![json!({"message": format!("fake: unknown {name}")})]),
    }
}

fn rejects(state: &Mutex<FakeState>, args: &[Value]) -> bool {
    let s = state.lock().unwrap();
    s.reject_containing.as_ref().is_some_and(|pat| args.get(1).is_some_and(|u| u.to_string().contains(pat.as_str())))
}
