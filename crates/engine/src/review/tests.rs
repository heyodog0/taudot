//! Review features against a fake server: `overleaf::fake` for the socket and its OT, behind a small proxy that adds
//! what that fake doesn't have: the comment thread routes and their socket events (`docs/protocol.md`, Comments), the
//! `clientTracking.*` events, `meta.tc` on a collaborator's op, and a project page with a CSRF token.

use super::super::{open_project, Cmd, Note, ProjectHandle};
use crate::Login;
use overleaf::fake::{FakeServer, Mode, DOC_ID, PROJECT_ID};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::broadcast;

#[derive(Default)]
struct ProxyState {
    /// thread ID -> `{messages: [...], resolved?}` as `GET /project/:id/threads` returns it.
    threads: BTreeMap<String, Value>,
    /// Every REST request: (method, path, body, had a CSRF header).
    requests: Vec<(String, String, Value, bool)>,
    /// Added as `meta.tc` to the next op the inner fake broadcasts from the collaborator.
    next_tc: Option<String>,
    next_msg: u64,
}

struct ReviewFake {
    inner: FakeServer,
    base: String,
    state: Arc<Mutex<ProxyState>>,
    events: broadcast::Sender<String>,
}

impl ReviewFake {
    async fn start(text: &str) -> ReviewFake {
        ReviewFake::start_with(FakeServer::start(text, Mode::Confirm).await).await
    }

    async fn start_with(inner: FakeServer) -> ReviewFake {
        let upstream = inner.base.trim_start_matches("http://").to_string();
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let state = Arc::new(Mutex::new(ProxyState::default()));
        let (events, _) = broadcast::channel(256);
        let (s, ev) = (state.clone(), events.clone());
        tokio::spawn(async move {
            loop {
                let Ok((c, _)) = listener.accept().await else { return };
                tokio::spawn(conn(c, upstream.clone(), s.clone(), ev.clone()));
            }
        });
        ReviewFake { inner, base, state, events }
    }

    /// Send a socket event to every connected client.
    fn emit(&self, name: &str, args: Value) {
        let _ = self.events.send(format!("5:::{}", json!({"name": name, "args": args})));
    }

    fn requests(&self) -> Vec<(String, String, Value, bool)> {
        self.state.lock().unwrap().requests.clone()
    }
}

async fn read_head(c: &mut TcpStream) -> Option<(Vec<u8>, String)> {
    let mut buf = vec![];
    let mut b = [0u8; 4096];
    loop {
        let n = c.read(&mut b).await.ok()?;
        if n == 0 {
            return None;
        }
        buf.extend_from_slice(&b[..n]);
        if let Some(i) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            let head = String::from_utf8_lossy(&buf[..i]).to_string();
            let len: usize = head
                .lines()
                .find_map(|l| l.split_once(':').filter(|(k, _)| k.eq_ignore_ascii_case("content-length")).map(|(_, v)| v.trim().parse().unwrap_or(0)))
                .unwrap_or(0);
            while buf.len() < i + 4 + len {
                let n = c.read(&mut b).await.ok()?;
                if n == 0 {
                    break;
                }
                buf.extend_from_slice(&b[..n]);
            }
            return Some((buf, head));
        }
    }
}

async fn conn(mut c: TcpStream, upstream: String, state: Arc<Mutex<ProxyState>>, events: broadcast::Sender<String>) {
    let Some((raw, head)) = read_head(&mut c).await else { return };
    let line = head.lines().next().unwrap_or("").to_string();
    let mut parts = line.split(' ');
    let (method, target) = (parts.next().unwrap_or("").to_string(), parts.next().unwrap_or("").to_string());
    let path = target.split('?').next().unwrap_or("").to_string();
    if path.starts_with("/socket.io/1/websocket/") {
        let mut up = TcpStream::connect(&upstream).await.unwrap();
        up.write_all(&raw).await.unwrap();
        let rx = events.subscribe();
        ws_pump(c, up, state, rx).await;
        return;
    }
    if path.starts_with("/socket.io/") {
        let mut up = TcpStream::connect(&upstream).await.unwrap();
        up.write_all(&raw).await.unwrap();
        let _ = tokio::io::copy_bidirectional(&mut c, &mut up).await;
        return;
    }
    let body_at = raw.windows(4).position(|w| w == b"\r\n\r\n").unwrap() + 4;
    let body: Value = serde_json::from_slice(&raw[body_at..]).unwrap_or(Value::Null);
    let csrf = head.lines().any(|l| l.to_ascii_lowercase().starts_with("x-csrf-token: tok"));
    let (status, out) = rest(&method, &path, &body, csrf, &state, &events);
    let resp = format!("HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{out}", out.len());
    let _ = c.write_all(resp.as_bytes()).await;
}

fn rest(method: &str, path: &str, body: &Value, csrf: bool, state: &Mutex<ProxyState>, events: &broadcast::Sender<String>) -> (&'static str, String) {
    let emit = |name: &str, args: Value| {
        let _ = events.send(format!("5:::{}", json!({"name": name, "args": args})));
    };
    if path == "/project" {
        let html = r#"<html><head><meta name="ol-csrfToken" content="tok"><meta name="ol-user_id" content="u1"></head></html>"#;
        return ("200 OK", html.into());
    }
    let mut s = state.lock().unwrap();
    s.requests.push((method.into(), path.into(), body.clone(), csrf));
    let seg: Vec<&str> = path.trim_start_matches('/').split('/').collect();
    let user = json!({"id": "u1", "first_name": "Alice", "last_name": "", "email": "alice@x"});
    if method != "GET" && !csrf {
        return ("403 Forbidden", "{}".into());
    }
    match (method, seg.as_slice()) {
        ("GET", ["project", _, "threads"]) => ("200 OK", json!(s.threads).to_string()),
        ("POST", ["project", _, "thread", tid, "messages"]) => {
            s.next_msg += 1;
            let msg = json!({"id": format!("m{}", s.next_msg), "content": body["content"], "timestamp": 1_793_628_414_000u64 + s.next_msg,
                "user_id": "u1", "user": user});
            let t = s.threads.entry(tid.to_string()).or_insert_with(|| json!({"messages": []}));
            t["messages"].as_array_mut().unwrap().push(msg.clone());
            emit("new-comment", json!([tid, msg]));
            ("204 No Content", String::new())
        }
        ("POST", ["project", _, "thread", tid, "messages", mid, "edit"]) => {
            emit("edit-message", json!([tid, mid, body["content"]]));
            ("204 No Content", String::new())
        }
        ("DELETE", ["project", _, "thread", tid, "messages" | "own-messages", mid]) => {
            emit("delete-message", json!([tid, mid]));
            ("204 No Content", String::new())
        }
        ("POST", ["project", _, "doc", _, "thread", tid, "resolve"]) => {
            emit("resolve-thread", json!([tid, user]));
            ("204 No Content", String::new())
        }
        ("POST", ["project", _, "doc", _, "thread", tid, "reopen"]) => {
            emit("reopen-thread", json!([tid]));
            ("204 No Content", String::new())
        }
        ("DELETE", ["project", _, "doc", _, "thread", tid]) => {
            s.threads.remove(*tid);
            emit("delete-thread", json!([tid]));
            ("204 No Content", String::new())
        }
        ("POST", ["project", _, "doc", doc, "changes", "accept"]) => {
            emit("accept-changes", json!([doc, body["change_ids"]]));
            ("204 No Content", String::new())
        }
        _ => ("404 Not Found", "{}".into()),
    }
}

/// Copies a WebSocket connection both ways. Frames from the server are parsed so events can be injected between them
/// and the collaborator's ops can get a `meta.tc`.
async fn ws_pump(c: TcpStream, up: TcpStream, state: Arc<Mutex<ProxyState>>, mut inject: broadcast::Receiver<String>) {
    let (mut cr, mut cw) = c.into_split();
    let (mut ur, mut uw) = up.into_split();
    tokio::spawn(async move {
        let _ = tokio::io::copy(&mut cr, &mut uw).await;
    });
    // The 101 response first.
    let mut buf: Vec<u8> = vec![];
    let mut b = [0u8; 8192];
    loop {
        let Ok(n) = ur.read(&mut b).await else { return };
        if n == 0 {
            return;
        }
        buf.extend_from_slice(&b[..n]);
        if let Some(i) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            if cw.write_all(&buf[..i + 4]).await.is_err() {
                return;
            }
            buf.drain(..i + 4);
            break;
        }
    }
    loop {
        // Whole frames in buf go out (possibly rewritten).
        while let Some((len, opcode, payload_at, plen)) = frame_at(&buf) {
            let out = if opcode == 1 {
                let text = String::from_utf8_lossy(&buf[payload_at..payload_at + plen]).to_string();
                ws_text(&rewrite(&text, &state))
            } else {
                buf[..len].to_vec()
            };
            buf.drain(..len);
            if cw.write_all(&out).await.is_err() {
                return;
            }
        }
        tokio::select! {
            r = ur.read(&mut b) => match r {
                Ok(0) | Err(_) => return,
                Ok(n) => buf.extend_from_slice(&b[..n]),
            },
            m = inject.recv() => match m {
                Ok(text) => if cw.write_all(&ws_text(&text)).await.is_err() { return },
                Err(broadcast::error::RecvError::Lagged(_)) => {}
                Err(_) => return,
            },
        }
    }
}

/// `(frame length, opcode, payload start, payload length)` of a whole unmasked frame at the start of `b`.
fn frame_at(b: &[u8]) -> Option<(usize, u8, usize, usize)> {
    if b.len() < 2 {
        return None;
    }
    let opcode = b[0] & 0x0f;
    let (plen, at) = match b[1] & 0x7f {
        126 => (u16::from_be_bytes([*b.get(2)?, *b.get(3)?]) as usize, 4),
        127 => (u64::from_be_bytes(b.get(2..10)?.try_into().ok()?) as usize, 10),
        n => (n as usize, 2),
    };
    (b.len() >= at + plen).then_some((at + plen, opcode, at, plen))
}

fn ws_text(s: &str) -> Vec<u8> {
    let p = s.as_bytes();
    let mut out = vec![0x81u8];
    if p.len() < 126 {
        out.push(p.len() as u8);
    } else if p.len() < 65536 {
        out.push(126);
        out.extend_from_slice(&(p.len() as u16).to_be_bytes());
    } else {
        out.push(127);
        out.extend_from_slice(&(p.len() as u64).to_be_bytes());
    }
    out.extend_from_slice(p);
    out
}

fn rewrite(text: &str, state: &Mutex<ProxyState>) -> String {
    let Some(body) = text.strip_prefix("5:::") else { return text.into() };
    let Ok(mut ev) = serde_json::from_str::<Value>(body) else { return text.into() };
    if ev["name"] == "otUpdateApplied" && ev["args"][0]["meta"]["source"] == "P.other" {
        if let Some(tc) = state.lock().unwrap().next_tc.take() {
            ev["args"][0]["meta"]["tc"] = json!(tc);
            return format!("5:::{ev}");
        }
    }
    text.into()
}

// ---- the engine side ----------------------------------------------------------------------------------------------

struct Eng {
    h: ProjectHandle,
    notes: broadcast::Receiver<Note>,
    seen: Vec<Note>,
}

impl Eng {
    async fn start(fake: &ReviewFake, name: &str) -> Eng {
        let home = std::env::temp_dir().join(format!("taudot-review-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        let login = Login {
            url: fake.base.clone(),
            env_file: None,
            user: "user1".into(),
            email: None,
            password: None,
            cookie: Some("overleaf_session2=s%3Afake".into()),
            sessions: None,
        };
        let (tx, notes) = broadcast::channel(4096);
        let h = open_project(&login, PROJECT_ID, &home, tx).await.unwrap();
        let e = Eng { h, notes, seen: vec![] };
        e.ask(|reply| Cmd::OpenDoc { path: "main.tex".into(), reply }).await;
        e
    }

    async fn ask(&self, f: impl FnOnce(super::super::Reply<Value>) -> Cmd) -> Value {
        self.h.ask(f).await.unwrap()
    }

    async fn call(&self, method: &str, params: Value) -> anyhow::Result<Value> {
        let method = method.to_string();
        self.h.ask(|reply| Cmd::Review { method, params, reply }).await
    }

    async fn edit(&self, pos: usize, del: usize, ins: &str) -> u64 {
        let seq = self.h.ask(|reply| Cmd::Status(reply)).await.unwrap()["docs"][0]["seq"].as_u64().unwrap();
        let edits = vec![ot::edit::Edit { pos, del, ins: ins.into() }];
        self.h.ask(|reply| Cmd::Edit { doc_id: DOC_ID.into(), seq, edits, edit_id: None, from_client: None, reply }).await.unwrap().0
    }

    /// The next note (seen or new) matching `f`.
    async fn wait(&mut self, what: &str, f: impl Fn(&Note) -> bool) -> Note {
        if let Some(i) = self.seen.iter().position(&f) {
            return self.seen.remove(i);
        }
        loop {
            let n = tokio::time::timeout(Duration::from_secs(5), self.notes.recv())
                .await
                .unwrap_or_else(|_| panic!("timed out waiting for {what}"))
                .unwrap();
            if f(&n) {
                return n;
            }
            self.seen.push(n);
        }
    }

    async fn ranges(&mut self, what: &str, f: impl Fn(&[Value]) -> bool) -> Vec<Value> {
        let n = self
            .wait(what, |n| n.method == "ranges.changed" && f(n.params["ranges"].as_array().unwrap()))
            .await;
        n.params["ranges"].as_array().unwrap().clone()
    }

    async fn idle(&mut self) {
        for _ in 0..100 {
            let st = self.h.ask(|reply| Cmd::Status(reply)).await.unwrap();
            if st["docs"][0]["state"] == "idle" {
                return;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        panic!("doc never went idle");
    }
}

const TEXT: &str = "hello brave new world\nsecond line é here\n";

#[tokio::test]
async fn cursors_arrive_move_and_leave() {
    let fake = ReviewFake::start(TEXT).await;
    let mut e = Eng::start(&fake, "cursors").await;
    // Bob's cursor on line 2 after "second line é" (column in UTF-16 units: 13).
    fake.emit("clientTracking.clientUpdated", json!([{"row": 1, "column": 13, "doc_id": DOC_ID, "id": "P.bob", "user_id": "u2",
        "email": "bob@x", "name": "Bob Builder"}]));
    let n = e.wait("presence", |n| n.method == "presence.changed" && !n.params["users"].as_array().unwrap().is_empty()).await;
    let u = &n.params["users"][0];
    let byte = TEXT.find(" here").unwrap();
    assert_eq!((u["name"].as_str(), u["initials"].as_str(), u["pos"].as_u64()), (Some("Bob Builder"), Some("BB"), Some(byte as u64)));
    // A remote insert before it moves it; the status shows the moved position.
    fake.inner.remote_insert(0, "XYZ");
    e.wait("remote change", |n| n.method == "doc.changed").await;
    let st = e.h.ask(|reply| Cmd::Status(reply)).await.unwrap();
    assert_eq!(st["users"][0]["pos"].as_u64(), Some(byte as u64 + 3));
    fake.emit("clientTracking.clientDisconnected", json!(["P.bob"]));
    e.wait("gone", |n| n.method == "presence.changed" && n.params["users"].as_array().unwrap().is_empty()).await;
}

#[tokio::test]
async fn remote_comment_range_moves_with_edits() {
    let fake = ReviewFake::start(TEXT).await;
    let mut e = Eng::start(&fake, "comment-range").await;
    let v = fake.inner.state.lock().unwrap().version;
    fake.inner.remote_op(v, json!([{"p": 6, "c": "brave", "t": "aaaaaaaaaaaaaaaaaaaaaa01"}])).unwrap();
    let r = e.ranges("comment", |r| r.len() == 1).await;
    assert_eq!((r[0]["kind"].as_str(), r[0]["start"].as_u64(), r[0]["end"].as_u64()), (Some("comment"), Some(6), Some(11)));
    assert_eq!(r[0]["thread_id"], "aaaaaaaaaaaaaaaaaaaaaa01");
    // Typing inside the comment grows it; the range's text changes, so clients hear about it.
    e.edit(8, 0, "--").await;
    let r = e.ranges("grown", |r| r.first().is_some_and(|x| x["text"] == "br--ave")).await;
    assert_eq!((r[0]["start"].as_u64(), r[0]["end"].as_u64()), (Some(6), Some(13)));
    // A plain shift doesn't send ranges.changed, but doc.ranges has the new position.
    e.edit(0, 0, "AB").await;
    e.idle().await;
    let d = e.call("doc.ranges", json!({"doc_id": DOC_ID})).await.unwrap();
    assert_eq!(d["ranges"][0]["start"].as_u64(), Some(8));
}

#[tokio::test]
async fn comment_threads_add_reply_resolve_edit_delete() {
    let fake = ReviewFake::start(TEXT).await;
    let mut e = Eng::start(&fake, "threads").await;
    let start = TEXT.find("new").unwrap();
    let r = e.call("comment.add", json!({"doc_id": DOC_ID, "start": start, "end": start + 3, "text": "why new?"})).await.unwrap();
    let tid = r["thread_id"].as_str().unwrap().to_string();
    assert_eq!(tid.len(), 24);
    // Message first, with the CSRF token, then the range op.
    let reqs = fake.requests();
    let post = reqs.iter().find(|(m, p, _, _)| m == "POST" && p.ends_with("/messages")).expect("message posted");
    assert!(post.3, "CSRF header sent");
    assert_eq!(post.2["content"], "why new?");
    let n = e.wait("thread", |n| n.method == "thread.changed" && n.params["thread_id"] == tid.as_str()).await;
    assert_eq!(n.params["thread"]["messages"][0]["text"], "why new?");
    assert_eq!(n.params["thread"]["messages"][0]["user"]["name"], "Alice");
    e.idle().await;
    let sent = {
        let s = fake.inner.state.lock().unwrap();
        s.sent_classic(s.received.len() - 1)
    };
    assert_eq!(sent, json!([{"p": start, "c": "new", "t": tid}]));
    let r = e.ranges("comment range", |r| r.iter().any(|x| x["thread_id"] == tid.as_str())).await;
    assert_eq!(r[0]["author"]["name"], "Alice");
    assert_eq!(r[0]["resolved"], false);

    e.call("thread.reply", json!({"project_id": PROJECT_ID, "thread_id": tid, "text": "because"})).await.unwrap();
    let n = e.wait("reply", |n| n.method == "thread.changed" && n.params["thread"]["messages"].as_array().is_some_and(|m| m.len() == 2)).await;
    let mid = n.params["thread"]["messages"][1]["id"].as_str().unwrap().to_string();
    e.call("message.edit", json!({"project_id": PROJECT_ID, "thread_id": tid, "message_id": mid, "text": "because!"})).await.unwrap();
    e.wait("edited", |n| n.method == "thread.changed" && n.params["thread"]["messages"][1]["text"] == "because!").await;
    e.call("message.delete", json!({"project_id": PROJECT_ID, "thread_id": tid, "message_id": mid})).await.unwrap();
    e.wait("deleted msg", |n| n.method == "thread.changed" && n.params["thread"]["messages"].as_array().is_some_and(|m| m.len() == 1)).await;
    assert!(fake.requests().iter().any(|(m, p, _, _)| m == "DELETE" && p.contains("/own-messages/")), "own message deleted via own-messages");

    e.call("thread.resolve", json!({"project_id": PROJECT_ID, "thread_id": tid})).await.unwrap();
    e.wait("resolved", |n| n.method == "thread.changed" && n.params["thread"]["resolved"] == true).await;
    e.ranges("resolved range", |r| r.first().is_some_and(|x| x["resolved"] == true)).await;
    let list = e.call("thread.list", json!({"project_id": PROJECT_ID})).await.unwrap();
    assert_eq!(list["threads"][0]["path"], "main.tex");
    assert_eq!(list["threads"][0]["text"], "new");
    assert_eq!(list["threads"][0]["resolved"], true);
    e.call("thread.reopen", json!({"project_id": PROJECT_ID, "thread_id": tid})).await.unwrap();
    e.wait("reopened", |n| n.method == "thread.changed" && n.params["thread"]["resolved"] == false).await;

    e.call("thread.delete", json!({"project_id": PROJECT_ID, "thread_id": tid})).await.unwrap();
    e.ranges("comment gone", |r| r.is_empty()).await;
    assert!(fake.requests().iter().any(|(m, p, _, _)| m == "DELETE" && p.ends_with(&format!("/doc/{DOC_ID}/thread/{tid}"))));
}

#[tokio::test]
async fn threads_from_the_server_and_events_from_others() {
    let fake = ReviewFake::start(TEXT).await;
    fake.state.lock().unwrap().threads.insert(
        "bbbbbbbbbbbbbbbbbbbbbb01".into(),
        json!({"messages": [{"id": "m0", "content": "old one", "timestamp": 1_000, "user_id": "u2", "user": {"id": "u2", "first_name": "Bob"}}],
               "resolved": true, "resolved_by_user_id": "u2"}),
    );
    let mut e = Eng::start(&fake, "threads-load").await;
    let t = e.call("thread.get", json!({"project_id": PROJECT_ID, "thread_id": "bbbbbbbbbbbbbbbbbbbbbb01"})).await.unwrap();
    assert_eq!((t["resolved"].as_bool(), t["messages"][0]["user"]["name"].as_str()), (Some(true), Some("Bob")));
    fake.emit("new-comment", json!(["bbbbbbbbbbbbbbbbbbbbbb01", {"id": "m9", "content": "new one", "timestamp": 2_000, "user_id": "u2",
        "user": {"id": "u2", "first_name": "Bob"}}]));
    e.wait("new comment", |n| n.method == "thread.changed" && n.params["thread"]["messages"].as_array().is_some_and(|m| m.len() == 2)).await;
}

#[tokio::test]
async fn tracked_changes_remote_mine_reject_accept() {
    let fake = ReviewFake::start(TEXT).await;
    if fake.inner.state.lock().unwrap().history_ot {
        return; // Classic's meta.tc, undo batches and REST accept; history-ot has tracked_changes_history_ot.
    }
    let mut e = Eng::start(&fake, "tracked").await;
    // A collaborator's tracked insert.
    fake.state.lock().unwrap().next_tc = Some("cccccccccccccccccc".into());
    fake.inner.remote_insert(0, "NEW ");
    let r = e.ranges("tracked insert", |r| r.len() == 1).await;
    assert_eq!((r[0]["kind"].as_str(), r[0]["id"].as_str()), (Some("tracked_insert"), Some("cccccccccccccccccc000001")));
    assert_eq!((r[0]["start"].as_u64(), r[0]["end"].as_u64(), r[0]["author"]["user_id"].as_str()), (Some(0), Some(4), Some("u2")));

    // Our own edits, tracked: sent with meta.tc, shown as ours.
    let on = e.call("review.track", json!({"project_id": PROJECT_ID, "on": true})).await.unwrap();
    assert_eq!(on["on"], true);
    let at = 4 + TEXT.find("brave ").unwrap();
    e.edit(at, 6, "").await; // tracked delete of "brave "
    e.edit(at, 0, "bold ").await; // tracked insert
    e.idle().await;
    let received = fake.inner.state.lock().unwrap().received.clone();
    assert!(received.iter().all(|u| u["meta"]["tc"].as_str().is_some_and(|tc| tc.len() == 18)), "sent with meta.tc: {received:?}");
    let r = e.ranges("mine", |r| r.len() == 3).await;
    let del = r.iter().find(|x| x["kind"] == "tracked_delete").unwrap();
    let ins = r.iter().find(|x| x["kind"] == "tracked_insert" && x["text"] == "bold ").unwrap();
    // The insert typed where the text was deleted goes before the delete marker.
    assert_eq!((del["text"].as_str(), del["start"].as_u64(), del["end"].as_u64()), (Some("brave "), Some(at as u64 + 5), Some(at as u64 + 5)));
    assert_eq!((ins["start"].as_u64(), ins["end"].as_u64()), (Some(at as u64), Some(at as u64 + 5)));
    assert_eq!(ins["author"]["user_id"], "u1");
    e.call("review.track", json!({"project_id": PROJECT_ID, "on": false})).await.unwrap();

    // Reject both of ours: the text comes back, sent as one undo batch.
    let ids: Vec<Value> = vec![del["id"].clone(), ins["id"].clone()];
    e.call("change.reject", json!({"doc_id": DOC_ID, "ids": ids})).await.unwrap();
    e.ranges("rejected", |r| r.len() == 1).await;
    e.idle().await;
    let s = fake.inner.state.lock().unwrap();
    assert_eq!(s.text, format!("NEW {TEXT}"));
    let last = s.received.last().unwrap();
    assert!(last["op"].as_array().unwrap().iter().all(|c| c["u"] == true), "undo flags: {last}");
    assert!(last["meta"].is_null(), "a rejection is not tracked: {last}");
    drop(s);

    // Accept the collaborator's.
    e.call("change.accept", json!({"doc_id": DOC_ID, "ids": ["cccccccccccccccccc000001"]})).await.unwrap();
    e.ranges("accepted", |r| r.is_empty()).await;
    let reqs = fake.requests();
    let acc = reqs.iter().find(|(_, p, _, _)| p.ends_with("/changes/accept")).unwrap();
    assert_eq!(acc.2["change_ids"], json!(["cccccccccccccccccc000001"]));
}

#[tokio::test]
async fn without_thread_routes_ranges_still_work() {
    // The plain fake answers 404 to every REST route, like Overleaf CE.
    let fake = FakeServer::start(TEXT, Mode::Confirm).await;
    let login = Login {
        url: fake.base.clone(),
        env_file: None,
        user: "user1".into(),
        email: None,
        password: None,
        cookie: Some("overleaf_session2=s%3Afake".into()),
        sessions: None,
    };
    let home = std::env::temp_dir().join(format!("taudot-review-ce-{}", std::process::id()));
    let (tx, _rx) = broadcast::channel(64);
    let h = open_project(&login, PROJECT_ID, &home, tx).await.unwrap();
    h.ask(|reply| Cmd::OpenDoc { path: "main.tex".into(), reply }).await.unwrap();
    let call = |m: &str, p: Value| {
        let m = m.to_string();
        let h = h.clone();
        async move { h.ask(|reply| Cmd::Review { method: m, params: p, reply }).await }
    };
    let e = call("comment.add", json!({"doc_id": DOC_ID, "start": 0, "end": 5, "text": "x"})).await.unwrap_err();
    assert!(e.to_string().contains("no comment threads"), "{e}");
    let e = call("thread.get", json!({"project_id": PROJECT_ID, "thread_id": "x"})).await.unwrap_err();
    assert!(e.to_string().contains("no comment threads"), "{e}");
    let l = call("thread.list", json!({"project_id": PROJECT_ID})).await.unwrap();
    assert_eq!(l["supported"], false);
    let v = fake.state.lock().unwrap().version;
    fake.remote_op(v, json!([{"p": 0, "c": "hello", "t": "aaaaaaaaaaaaaaaaaaaaaa01"}])).unwrap();
    tokio::time::sleep(Duration::from_millis(200)).await;
    let l = call("thread.list", json!({"project_id": PROJECT_ID})).await.unwrap();
    assert_eq!((l["threads"][0]["text"].as_str(), l["threads"][0]["messages"].as_array().map(Vec::len)), (Some("hello"), Some(0)));
}

#[tokio::test]
async fn follows_overleafs_track_changes_setting() {
    let fake = ReviewFake::start(TEXT).await;
    let mut e = Eng::start(&fake, "track-setting").await;
    // Someone turns it on for us (u1) in the browser; then for everyone; then off for us only.
    fake.emit("toggle-track-changes", json!([{"u1": true, "u2": false}]));
    let n = e.wait("on", |n| n.method == "review.track" && n.params["on"] == true).await;
    assert_eq!(n.params["overleaf"], json!({"u1": true, "u2": false}));
    let st = e.h.ask(|reply| Cmd::Status(reply)).await.unwrap();
    assert_eq!((st["track_changes"].as_bool(), st["overleaf_track_changes"]["u1"].as_bool()), (Some(true), Some(true)));
    // Our edits are now tracked.
    e.edit(0, 0, "X").await;
    e.idle().await;
    {
        let s = fake.inner.state.lock().unwrap();
        let last = s.received.last().unwrap();
        if s.history_ot {
            assert!(last["op"].to_string().contains(r#""type":"insert""#), "tracked insert: {last}");
        } else {
            assert!(last["meta"]["tc"].is_string());
        }
    }
    fake.emit("toggle-track-changes", json!([{"u1": false, "u2": true}]));
    e.wait("off", |n| n.method == "review.track" && n.params["on"] == false).await;
    fake.emit("toggle-track-changes", json!([true]));
    e.wait("everyone", |n| n.method == "review.track" && n.params["on"] == true && n.params["overleaf"] == true).await;
}

/// history-ot: tracked changes and comments are ops. A collaborator's tracked insert; ours tracked (the deleted text
/// stays in the server's content, the engine shows it as a point); rejecting ours and accepting theirs, both as ops
/// (no REST); a collaborator's comment added, resolved and deleted.
#[tokio::test]
async fn tracked_changes_history_ot() {
    let fake = ReviewFake::start_with(FakeServer::start_history_ot(TEXT, Mode::Confirm).await).await;
    let mut e = Eng::start(&fake, "tracked-hot").await;
    let len = ot::units::utf16_len(TEXT);
    let ts = "2026-11-03T10:00:00.000Z";
    let v = fake.inner.state.lock().unwrap().version;
    fake.inner
        .remote_history_ot(v, json!([{"textOperation": [{"i": "NEW ", "tracking": {"type": "insert", "userId": "u2", "ts": ts}}, len]}]))
        .unwrap();
    let r = e.ranges("tracked insert", |r| r.len() == 1).await;
    assert_eq!((r[0]["kind"].as_str(), r[0]["start"].as_u64(), r[0]["end"].as_u64()), (Some("tracked_insert"), Some(0), Some(4)));
    assert_eq!(r[0]["author"]["user_id"], "u2");
    let theirs = r[0]["id"].as_str().unwrap().to_string();

    e.call("review.track", json!({"project_id": PROJECT_ID, "on": true})).await.unwrap();
    let at = 4 + TEXT.find("brave ").unwrap();
    e.edit(at, 6, "").await;
    e.edit(at, 0, "bold ").await;
    e.idle().await;
    {
        let s = fake.inner.state.lock().unwrap();
        assert_eq!(s.text, format!("NEW hello bold new world\nsecond line é here\n"), "visible");
        assert_eq!(s.fd.content, format!("NEW hello bold brave new world\nsecond line é here\n"), "deleted text kept");
        let sent = serde_json::to_string(&s.received).unwrap();
        assert!(sent.contains(r#""type":"delete","userId":"u1""#) && sent.contains(r#""type":"insert","userId":"u1""#), "{sent}");
        assert!(s.received.iter().all(|u| u.get("meta").is_none_or(|m| m.get("tc").is_none())), "no meta.tc in history-ot");
    }
    e.call("review.track", json!({"project_id": PROJECT_ID, "on": false})).await.unwrap();
    let d = e.call("doc.ranges", json!({"doc_id": DOC_ID})).await.unwrap();
    let r = d["ranges"].as_array().unwrap();
    assert_eq!(r.len(), 3, "{r:?}");
    let del = r.iter().find(|x| x["kind"] == "tracked_delete").unwrap();
    let ins = r.iter().find(|x| x["kind"] == "tracked_insert" && x["text"] == "bold ").unwrap();
    assert_eq!((del["text"].as_str(), del["start"].as_u64(), del["end"].as_u64()), (Some("brave "), Some(at as u64 + 5), Some(at as u64 + 5)));
    assert_eq!((ins["start"].as_u64(), ins["end"].as_u64(), ins["author"]["user_id"].as_str()), (Some(at as u64), Some(at as u64 + 5), Some("u1")));

    // Reject both of ours: one update, the insert removed and the delete's tracking cleared.
    e.call("change.reject", json!({"doc_id": DOC_ID, "ids": [del["id"].clone(), ins["id"].clone()]})).await.unwrap();
    e.ranges("rejected", |r| r.len() == 1).await;
    e.idle().await;
    {
        let s = fake.inner.state.lock().unwrap();
        assert_eq!(s.text, format!("NEW {TEXT}"));
        assert_eq!(s.fd.content, format!("NEW {TEXT}"));
        assert_eq!(s.fd.tracked.len(), 1);
    }
    let st = e.h.ask(|reply| Cmd::Status(reply)).await.unwrap();
    assert_eq!(st["docs"][0]["unconfirmed"], 0);

    // Accept theirs: an op, not a REST call.
    e.call("change.accept", json!({"doc_id": DOC_ID, "ids": [theirs]})).await.unwrap();
    for _ in 0..100 {
        if fake.inner.state.lock().unwrap().fd.tracked.is_empty() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert!(fake.inner.state.lock().unwrap().fd.tracked.is_empty(), "accepted on the server");
    e.idle().await;
    let d = e.call("doc.ranges", json!({"doc_id": DOC_ID})).await.unwrap();
    assert_eq!(d["ranges"], json!([]));
    assert!(!fake.requests().iter().any(|(_, p, _, _)| p.contains("/changes/")), "no REST for history-ot");

    // A collaborator's tracked delete: gone from our text, shown as a point.
    let v = fake.inner.state.lock().unwrap().version;
    fake.inner
        .remote_history_ot(v, json!([{"textOperation": [4, {"r": 6, "tracking": {"type": "delete", "userId": "u2", "ts": ts}}, len - 6]}]))
        .unwrap();
    let r = e.ranges("their delete", |r| r.len() == 1 && r[0]["kind"] == "tracked_delete").await;
    assert_eq!((r[0]["text"].as_str(), r[0]["start"].as_u64()), (Some("hello "), Some(4)));
    let text = e.ask(|reply| Cmd::OpenDoc { path: "main.tex".into(), reply }).await["text"].as_str().unwrap().to_string();
    assert_eq!(text, format!("NEW brave new world\nsecond line é here\n"));

    // A collaborator's comment on "brave", resolved, then deleted.
    let v = fake.inner.state.lock().unwrap().version;
    fake.inner.remote_history_ot(v, json!([{"commentId": "dddddddddddddddddddddd01", "ranges": [{"pos": 10, "length": 5}]}])).unwrap();
    let r = e.ranges("comment", |r| r.iter().any(|x| x["kind"] == "comment")).await;
    let c = r.iter().find(|x| x["kind"] == "comment").unwrap();
    assert_eq!((c["text"].as_str(), c["start"].as_u64()), (Some("brave"), Some(4)));
    let v = fake.inner.state.lock().unwrap().version;
    fake.inner.remote_history_ot(v, json!([{"deleteComment": "dddddddddddddddddddddd01"}])).unwrap();
    e.ranges("comment gone", |r| !r.iter().any(|x| x["kind"] == "comment")).await;
}

#[test]
fn folded_batch_keeps_tracking_and_seed() {
    // E6: a tracked batch in flight, folded back into an untracked pending one, goes out tracked under its seed.
    let mut r = super::DocReview::new();
    r.pending_tracked = true;
    r.flipped();
    let seed = r.inflight_seed.clone();
    assert!(r.inflight_tracked() && !r.pending_tracked);
    r.folded(false);
    assert!(r.pending_tracked && !r.inflight_tracked);
    assert_eq!(r.pending_seed, seed);
    r.flipped();
    let (_, meta) = r.outgoing(serde_json::json!([]));
    assert_eq!(meta, Some(serde_json::json!({"tc": seed})));
    // and the flags survive a backup
    let mut r2 = super::DocReview::new();
    r2.restore_flags(&r.flags_json());
    assert!(r2.inflight_tracked() && r2.inflight_seed == seed);
}

#[tokio::test]
async fn typing_after_a_reject_is_not_part_of_the_undo() {
    // E7: with the browser's 2 s batching, the reject's undo batch waited for the delay and absorbed what was typed
    // next: sent with `u: true` and without `meta.tc`, so a tracked edit landed as an untracked undo.
    let fake = ReviewFake::start(TEXT).await;
    if fake.inner.state.lock().unwrap().history_ot {
        return; // rejects are history-ot ops there, sent alone through WIRE_MARKER
    }
    crate::engine::TEST_FLUSH_DELAYS.with(|c| c.set(Some((Duration::from_secs(2), Duration::from_millis(500)))));
    let mut e = Eng::start(&fake, "rejecttype").await;
    e.call("review.track", json!({"project_id": PROJECT_ID, "on": true})).await.unwrap();
    e.edit(0, 0, "X").await;
    let r = e.ranges("tracked X", |r| r.len() == 1).await;
    e.idle().await;
    e.call("change.reject", json!({"doc_id": DOC_ID, "ids": [r[0]["id"].clone()]})).await.unwrap();
    e.ranges("rejected", |r| r.is_empty()).await;
    tokio::time::sleep(Duration::from_millis(200)).await;
    e.edit(5, 0, "Y").await; // tracked, typed right after
    tokio::time::sleep(Duration::from_millis(2600)).await;
    e.idle().await;
    let s = fake.inner.state.lock().unwrap();
    assert_eq!(s.text, "helloY brave new world\nsecond line é here\n");
    let with_y: Vec<&Value> = s.received.iter().filter(|u| u.to_string().contains("\"Y\"")).collect();
    assert!(!with_y.is_empty());
    for u in with_y {
        assert!(u["meta"]["tc"].is_string() && u["op"].as_array().unwrap().iter().all(|c| c.get("u").is_none()), "typed edit sent as part of the undo: {u}");
    }
    crate::engine::TEST_FLUSH_DELAYS.with(|c| c.set(None));
}

#[tokio::test]
async fn presence_is_cleared_while_offline() {
    // E17: who was here before the connection went is not shown while offline (their cursors would sit still).
    let fake = ReviewFake::start(TEXT).await;
    let mut e = Eng::start(&fake, "presoff").await;
    fake.emit("clientTracking.clientUpdated", json!([{"row": 1, "column": 3, "doc_id": DOC_ID, "id": "P.bob", "user_id": "u2",
        "email": "bob@x", "name": "Bob Builder"}]));
    e.wait("presence", |n| n.method == "presence.changed" && !n.params["users"].as_array().unwrap().is_empty()).await;
    fake.inner.set_offline(true);
    e.wait("offline", |n| n.method == "project.connection" && n.params["connection"] != "online").await;
    e.wait("cleared", |n| n.method == "presence.changed" && n.params["users"].as_array().unwrap().is_empty()).await;
    let st = e.h.ask(|reply| Cmd::Status(reply)).await.unwrap();
    assert_eq!(st["users"], json!([]), "{st}");
    fake.inner.set_offline(false);
}
