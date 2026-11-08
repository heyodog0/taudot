//! `taudot serve`: JSON-RPC 2.0, one object per line, over a Unix socket (docs/api.md, level 0).

use crate::engine::{self, Cmd, Note, ProjectHandle};
use ot::edit::Edit;
use crate::Login;
use anyhow::{anyhow, Context};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::{broadcast, mpsc, watch, Mutex};

pub const API_LEVEL: u64 = 0;

/// This engine process: its pid and start time. A client that sees it change knows the engine restarted, and that the
/// seqs it holds mean nothing to this one.
fn instance() -> &'static str {
    static I: std::sync::OnceLock<String> = std::sync::OnceLock::new();
    I.get_or_init(|| {
        let t = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default();
        format!("{}-{}", std::process::id(), t.as_millis())
    })
}

#[derive(clap::Args)]
pub struct Args {
    #[command(flatten)]
    login: Login,
    /// Engine home, holding `engine.sock` and `engine.json`. Default `$TAUDOT_HOME` or `~/.taudot`.
    #[arg(long, env = "TAUDOT_HOME")]
    home: Option<PathBuf>,
}

struct State {
    login: Login,
    projects: Mutex<HashMap<String, ProjectHandle>>,
    /// Held while a project is being opened, so clients that open it at once share one login and one connection.
    opening: Mutex<()>,
    /// doc_id -> project_id
    doc_project: Mutex<HashMap<String, String>>,
    notes: broadcast::Sender<Note>,
    home: PathBuf,
    next_client: AtomicU64,
}

pub async fn run(a: Args) -> anyhow::Result<()> {
    let home = match a.home {
        Some(h) => h,
        None => crate::compat::default_home()?,
    };
    std::fs::create_dir_all(&home)?;
    let sock = home.join("engine.sock");
    let state_file = home.join("engine.json");
    if sock.exists() {
        if UnixStream::connect(&sock).await.is_ok() {
            anyhow::bail!("an engine is already running at {}", sock.display());
        }
        std::fs::remove_file(&sock)?;
    }
    let listener = UnixListener::bind(&sock)?;
    std::fs::write(
        &state_file,
        serde_json::to_string_pretty(&json!({
            "pid": std::process::id(),
            "socket": sock,
            "api_level": API_LEVEL,
            "version": env!("CARGO_PKG_VERSION"),
        }))?,
    )?;
    eprintln!("taudot engine listening on {}", sock.display());

    let (notes, _) = broadcast::channel(4096);
    let state = Arc::new(State {
        login: a.login,
        projects: Mutex::new(HashMap::new()),
        opening: Mutex::new(()),
        doc_project: Mutex::new(HashMap::new()),
        notes,
        home: home.clone(),
        next_client: AtomicU64::new(1),
    });
    let shutdown = tokio::signal::ctrl_c();
    tokio::pin!(shutdown);
    // launchd stops the agent with SIGTERM.
    let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
    loop {
        tokio::select! {
            r = listener.accept() => {
                let (stream, _) = r?;
                tokio::spawn(client(stream, state.clone()));
            }
            _ = &mut shutdown => break,
            _ = term.recv() => break,
        }
    }
    // Write backups and mirror files before exiting.
    let handles: Vec<ProjectHandle> = state.projects.lock().await.values().cloned().collect();
    for h in handles {
        let _ = tokio::time::timeout(Duration::from_secs(5), h.ask(Cmd::Shutdown)).await;
    }
    let _ = std::fs::remove_file(&sock);
    let _ = std::fs::remove_file(&state_file);
    Ok(())
}

#[derive(Default)]
struct Subs {
    docs: HashSet<String>,
    projects: HashSet<String>,
}

/// One API connection.
struct Conn {
    id: u64,
    subs: std::sync::Mutex<Subs>,
    /// Per doc, the highest `doc.changed` seq the forwarder has passed on (or skipped as this connection's own). A
    /// `doc.edit` result waits for this, so a client gets every change below its result's seq before the result.
    forwarded: watch::Sender<HashMap<String, u64>>,
    /// Notifications to send after the current request's response (a `doc.edit`'s follow-up changes).
    after: std::sync::Mutex<Vec<String>>,
}

async fn client(stream: UnixStream, state: Arc<State>) {
    let (r, mut w) = stream.into_split();
    let (out_tx, mut out_rx) = mpsc::unbounded_channel::<String>();
    tokio::spawn(async move {
        while let Some(line) = out_rx.recv().await {
            if w.write_all(line.as_bytes()).await.is_err() || w.write_all(b"\n").await.is_err() {
                break;
            }
        }
    });
    let conn = Arc::new(Conn {
        id: state.next_client.fetch_add(1, Ordering::Relaxed),
        subs: std::sync::Mutex::new(Subs::default()),
        forwarded: watch::channel(HashMap::new()).0,
        after: std::sync::Mutex::new(Vec::new()),
    });

    // Forward notifications this client subscribed to.
    let mut notes = state.notes.subscribe();
    let (fwd_tx, fwd_conn) = (out_tx.clone(), conn.clone());
    let forward = tokio::spawn(async move {
        loop {
            let n = match notes.recv().await {
                Ok(n) => n,
                Err(broadcast::error::RecvError::Lagged(k)) => {
                    let msg = json!({"jsonrpc": "2.0", "method": "engine.lagged", "params": {"missed": k}});
                    let _ = fwd_tx.send(msg.to_string());
                    continue;
                }
                Err(_) => break,
            };
            let wanted = {
                let s = fwd_conn.subs.lock().unwrap();
                match &n.doc_id {
                    Some(d) if n.method == "doc.changed" || n.method == "doc.state" || n.method == "ranges.changed" => s.docs.contains(d),
                    _ => s.projects.contains(&n.project_id),
                }
            };
            let own = n.from_client == Some(fwd_conn.id);
            if wanted && !own {
                let msg = json!({"jsonrpc": "2.0", "method": n.method, "params": n.params});
                if fwd_tx.send(msg.to_string()).is_err() {
                    break;
                }
            }
            if let (Some(d), Some(seq), "doc.changed") = (&n.doc_id, n.params.get("seq").and_then(Value::as_u64), n.method) {
                fwd_conn.forwarded.send_modify(|m| {
                    let e = m.entry(d.clone()).or_insert(0);
                    *e = (*e).max(seq);
                });
            }
        }
    });

    let mut lines = BufReader::new(r).lines();
    while let Ok(Some(line)) = lines.next_line().await {
        if line.trim().is_empty() {
            continue;
        }
        let req: Value = match serde_json::from_str(&line) {
            Ok(v) => v,
            Err(e) => {
                let _ = out_tx.send(err_response(Value::Null, -32700, &format!("parse error: {e}")).to_string());
                continue;
            }
        };
        let id = req.get("id").cloned().unwrap_or(Value::Null);
        let method = req.get("method").and_then(Value::as_str).unwrap_or("").to_string();
        let params = req.get("params").cloned().unwrap_or(json!({}));
        let r = dispatch(&state, &conn, &out_tx, &method, params).await;
        if req.get("id").is_none() {
            continue; // a notification from the client, no answer
        }
        let resp = match r {
            Ok(v) => json!({"jsonrpc": "2.0", "id": id, "result": v}),
            Err(e) => {
                let code = if format!("{e}").starts_with("unknown method") { -32601 } else { -32000 };
                err_response(id, code, &format!("{e:#}"))
            }
        };
        let _ = out_tx.send(resp.to_string());
        for n in std::mem::take(&mut *conn.after.lock().unwrap()) {
            let _ = out_tx.send(n);
        }
    }
    forward.abort();
}

fn err_response(id: Value, code: i64, msg: &str) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": msg}})
}

fn str_param<'a>(p: &'a Value, k: &str) -> anyhow::Result<&'a str> {
    p.get(k).and_then(Value::as_str).ok_or_else(|| anyhow!("missing string param {k}"))
}
fn u64_param(p: &Value, k: &str) -> anyhow::Result<u64> {
    p.get(k).and_then(Value::as_u64).ok_or_else(|| anyhow!("missing integer param {k}"))
}

/// The project ID from `{project_id}` or an Overleaf URL `{url}` such as `https://host/project/<id>`.
fn project_id_param(p: &Value) -> anyhow::Result<String> {
    if let Some(id) = p.get("project_id").and_then(Value::as_str) {
        return Ok(id.to_string());
    }
    let url = str_param(p, "url").map_err(|_| anyhow!("need project_id or url"))?;
    url.split('/')
        .skip_while(|s| *s != "project")
        .nth(1)
        .map(|s| s.split(['?', '#']).next().unwrap_or(s).to_string())
        .ok_or_else(|| anyhow!("no /project/<id> in {url}"))
}

async fn remember_docs(state: &State, pid: &str, tree: &Value) {
    let mut dp = state.doc_project.lock().await;
    for d in tree["docs"].as_array().into_iter().flatten() {
        if let Some(id) = d["doc_id"].as_str() {
            dp.insert(id.to_string(), pid.to_string());
        }
    }
}

async fn project_for_doc(state: &State, doc_id: &str) -> anyhow::Result<ProjectHandle> {
    let mut pid = state.doc_project.lock().await.get(doc_id).cloned();
    if pid.is_none() {
        // A doc added since the project was opened.
        let handles: Vec<(String, ProjectHandle)> = state.projects.lock().await.iter().map(|(k, v)| (k.clone(), v.clone())).collect();
        for (p, h) in handles {
            if let Ok(tree) = h.ask(Cmd::Tree).await {
                remember_docs(state, &p, &tree).await;
            }
        }
        pid = state.doc_project.lock().await.get(doc_id).cloned();
    }
    let pid = pid.ok_or_else(|| anyhow!("doc {doc_id} is not open"))?;
    let mut projects = state.projects.lock().await;
    match projects.get(&pid).cloned() {
        Some(h) if h.alive() => Ok(h),
        Some(_) => {
            projects.remove(&pid);
            Err(anyhow!("project {pid} stopped; open it again"))
        }
        None => Err(anyhow!("project {pid} is not open")),
    }
}

/// `project.open`: connect (or reuse the connection), mirror into `folder` if given, and note the folder in the
/// clones index (`projects.rs`).
async fn open_project(state: &State, p: &Value) -> anyhow::Result<Value> {
    // A folder names its project in `<folder>/.taudot.json`: {"project": "<id or Overleaf URL>"}.
    let folder = p.get("folder").and_then(Value::as_str).map(PathBuf::from);
    // The server comes from the project's URL when there is one; the engine's own login is for its --url.
    let mut project_url = p.get("url").and_then(Value::as_str).map(String::from);
    let pid = match (&folder, project_id_param(p)) {
        (_, Ok(pid)) => pid,
        (Some(f), Err(_)) => {
            let cfg = crate::compat::project_file(&f);
            let raw = std::fs::read_to_string(&cfg).with_context(|| format!("{} has no .taudot.json", f.display()))?;
            let v: Value = serde_json::from_str(&raw).with_context(|| format!("parsing {}", cfg.display()))?;
            let project = v.get("project").and_then(Value::as_str).ok_or_else(|| anyhow!("no \"project\" in {}", cfg.display()))?;
            project_url = project.contains('/').then(|| project.to_string());
            if project.contains('/') { project_id_param(&json!({"url": project}))? } else { project.to_string() }
        }
        (None, Err(e)) => return Err(e),
    };
    let _opening = state.opening.lock().await;
    // A stopped actor (a panic) leaves its handle behind: open the project afresh rather than fail for good.
    let existing = state.projects.lock().await.get(&pid).cloned().filter(ProjectHandle::alive);
    let h = match existing {
        Some(h) => h,
        None => {
            let h = engine::open_project(&crate::account::login_for(&state.login, project_url.as_deref())?, &pid, &state.home, state.notes.clone()).await?;
            state.projects.lock().await.insert(pid.clone(), h.clone());
            h
        }
    };
    drop(_opening);
    // Mirror: the engine keeps the folder and the project in step, both ways. A folder that already names
    // its project (`.taudot.json`) is ours, so its untracked files are uploaded at once.
    if let Some(f) = &folder {
        let folder = f.clone();
        let adopt = crate::compat::project_file(&f).exists();
        h.ask(|reply| Cmd::Mirror { folder, adopt, reply }).await?;
    }
    let tree = h.ask(Cmd::Tree).await?;
    remember_docs(state, &pid, &tree).await;
    if let Some(f) = &folder {
        let server = crate::login::origin(project_url.as_deref().filter(|u| u.starts_with("http")).unwrap_or(&state.login.url))?;
        if let Err(e) = crate::projects::remember(&state.home, &server, &pid, f, &h.name) {
            tracing::warn!("clones index: {e:#}");
        }
    }
    let folder = folder.map(|f| f.display().to_string());
    Ok(json!({"project_id": pid, "name": h.name, "folder": folder, "docs": tree["docs"], "files": tree["files"], "me": h.me,
        "compiler": h.compiler, "image": h.image}))
}

/// `project.clone {url?, project_id, folder, force?}`: as `taudot clone`. Sends `clone.progress {project_id, folder,
/// stage, text}` to this connection while it works (stage `connecting`, `downloading`, `done`).
async fn clone_project(state: &State, out: &mpsc::UnboundedSender<String>, p: &Value) -> anyhow::Result<Value> {
    let server = crate::account::server(p)?;
    let pid = project_id_param(p)?;
    let folder = crate::projects::expand(str_param(p, "folder")?);
    if !folder.is_absolute() {
        return Err(anyhow!("folder must be an absolute path"));
    }
    let progress = |stage: &str, text: String| {
        let msg = json!({"jsonrpc": "2.0", "method": "clone.progress", "params": {
            "project_id": pid, "folder": folder, "stage": stage, "text": text}});
        let _ = out.send(msg.to_string());
    };
    let made = crate::projects::prepare_clone(&folder, &server, &pid, p["force"].as_bool().unwrap_or(false))?;
    let folder = folder.canonicalize()?;
    progress("connecting", format!("connecting to {server}"));
    let url = format!("{server}/project/{pid}");
    // Open without the folder first, so a project we can't join leaves nothing behind but the empty folder.
    let opened = match open_project(state, &json!({"url": url})).await {
        Ok(v) => v,
        Err(e) => {
            if made {
                let _ = std::fs::remove_dir_all(&folder);
            }
            return Err(e);
        }
    };
    let n = opened["docs"].as_array().map_or(0, Vec::len) + opened["files"].as_array().map_or(0, Vec::len);
    progress("downloading", format!("downloading {n} files"));
    let r = open_project(state, &json!({"url": url, "folder": folder})).await?;
    progress("done", format!("cloned into {}", folder.display()));
    Ok(json!({"folder": folder, "project_id": pid, "name": r["name"],
        "docs": r["docs"].as_array().map_or(0, Vec::len), "files": r["files"].as_array().map_or(0, Vec::len)}))
}

/// `project.forget {url?, project_id, folder?}`: stop syncing the project (its connection closes; every client of
/// it loses it) and drop the folder from the clones index, so the app can then move the folder to the Trash safely.
/// Files in the folder are left as they are.
async fn forget_project(state: &State, p: &Value) -> anyhow::Result<Value> {
    let server = crate::account::server(p)?;
    let pid = project_id_param(p)?;
    let folder = p.get("folder").and_then(Value::as_str).map(crate::projects::expand);
    let h = state.projects.lock().await.remove(&pid);
    if let Some(h) = h {
        let _ = tokio::time::timeout(Duration::from_secs(5), h.ask(Cmd::Shutdown)).await;
        state.doc_project.lock().await.retain(|_, v| *v != pid);
    }
    crate::projects::forget(&state.home, &server, &pid, folder.as_deref())?;
    Ok(json!({}))
}

async fn dispatch(
    state: &State,
    conn: &Conn,
    out: &mpsc::UnboundedSender<String>,
    method: &str,
    p: Value,
) -> anyhow::Result<Value> {
    match method {
        "engine.info" => Ok(json!({"api_level": API_LEVEL, "version": env!("CARGO_PKG_VERSION"), "instance": instance()})),
        "project.open" => open_project(state, &p).await,
        "project.clone" => clone_project(state, out, &p).await,
        "project.forget" => forget_project(state, &p).await,
        "account.status" => crate::account::status(&state.login, &state.home, &p).await,
        "account.login" => crate::account::login(&state.login, &state.home, &p).await,
        "account.logout" => crate::account::logout(&state.login, &state.home, &p).await,
        "projects.list" => crate::projects::list(&state.login, &state.home, &p).await,
        "project.create" => crate::projects::create(&state.login, &p).await,
        "project.status" => {
            let pid = project_id_param(&p)?;
            let h = state.projects.lock().await.get(&pid).cloned().ok_or_else(|| anyhow!("project {pid} is not open"))?;
            h.ask(Cmd::Status).await
        }
        "doc.open" => {
            let pid = project_id_param(&p)?;
            let path = str_param(&p, "path")?.to_string();
            let h = state.projects.lock().await.get(&pid).cloned().ok_or_else(|| anyhow!("project {pid} is not open"))?;
            h.ask(|reply| Cmd::OpenDoc { path, reply }).await
        }
        "doc.edit" => {
            let doc_id = str_param(&p, "doc_id")?.to_string();
            let seq = u64_param(&p, "seq")?;
            let edits: Vec<Edit> = serde_json::from_value(p.get("edits").cloned().unwrap_or(json!([])))?;
            let edit_id = p.get("edit_id").and_then(|v| v.as_str().map(String::from).or_else(|| v.as_u64().map(|n| n.to_string())));
            let h = project_for_doc(state, &doc_id).await?;
            let d = doc_id.clone();
            let from_client = Some(conn.id);
            let (seq, after) = h.ask(|reply| Cmd::Edit { doc_id: d, seq, edits, edit_id, from_client, reply }).await?;
            // Changes the engine made on top of the client's (forwarded to its other connections, not to this one):
            // they reach this client right after the result.
            for c in after {
                let msg = json!({"jsonrpc": "2.0", "method": "doc.changed", "params": {
                    "doc_id": doc_id, "seq": c.seq, "edits": c.edits, "origin": c.origin, "author": c.author}});
                conn.after.lock().unwrap().push(msg.to_string());
            }
            // Changes below `seq` reach this client before the result does.
            if conn.subs.lock().unwrap().docs.contains(&doc_id) {
                let mut rx = conn.forwarded.subscribe();
                let _ = tokio::time::timeout(
                    Duration::from_secs(2),
                    rx.wait_for(|m| m.get(&doc_id).copied().unwrap_or(0) + 1 >= seq),
                )
                .await;
            }
            Ok(json!({"seq": seq}))
        }
        "doc.subscribe" => {
            let doc_id = str_param(&p, "doc_id")?.to_string();
            let since = p.get("since_seq").and_then(Value::as_u64).unwrap_or(0);
            let h = project_for_doc(state, &doc_id).await?;
            // Subscribe first so nothing falls between the replay and live notifications. A change can then arrive
            // twice; clients drop seqs they've seen.
            conn.subs.lock().unwrap().docs.insert(doc_id.clone());
            let d = doc_id.clone();
            let (seq, changes) = h.ask(|reply| Cmd::Since { doc_id: d, since, reply }).await?;
            for c in changes {
                let msg = json!({"jsonrpc": "2.0", "method": "doc.changed", "params": {
                    "doc_id": doc_id, "seq": c.seq, "edits": c.edits, "origin": c.origin,
                    "author": c.author}});
                let _ = out.send(msg.to_string());
            }
            Ok(json!({"seq": seq}))
        }
        "activity.subscribe" => {
            let pid = project_id_param(&p)?;
            conn.subs.lock().unwrap().projects.insert(pid);
            Ok(json!({"seq": 0}))
        }
        "presence.cursor" => {
            let doc_id = str_param(&p, "doc_id")?.to_string();
            let pos = u64_param(&p, "pos")? as usize;
            let seq = p.get("seq").and_then(Value::as_u64);
            let h = project_for_doc(state, &doc_id).await?;
            h.ask(|reply| Cmd::Cursor { doc_id, pos, seq, reply }).await?;
            Ok(json!({}))
        }
        "complete.items" => {
            let h = project_for_doc(state, str_param(&p, "doc_id")?).await?;
            h.ask(|reply| Cmd::Complete { params: p, reply }).await
        }
        m if crate::history::METHODS.contains(&m) => {
            let pid = project_id_param(&p)?;
            let h = state.projects.lock().await.get(&pid).cloned().ok_or_else(|| anyhow!("project {pid} is not open"))?;
            let http = h.ask(Cmd::Http).await?;
            let me = h.me["user_id"].as_str().map(String::from);
            crate::history::call(&http, me.as_deref(), &pid, m, &p).await
        }
        m if engine::review::METHODS.contains(&m) => {
            // Review features: the project from `project_id`, else from `doc_id`.
            let h = match project_id_param(&p) {
                Ok(pid) => state.projects.lock().await.get(&pid).cloned().ok_or_else(|| anyhow!("project {pid} is not open"))?,
                Err(_) => project_for_doc(state, str_param(&p, "doc_id")?).await?,
            };
            let method = method.to_string();
            h.ask(|reply| Cmd::Review { method, params: p, reply }).await
        }
        _ => Err(anyhow!("unknown method {method}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn project_id_from_url() {
        assert_eq!(
            project_id_param(&json!({"url": "http://localhost:8800/project/0123456789abcdef01234567?x=1"})).unwrap(),
            "0123456789abcdef01234567"
        );
        assert_eq!(project_id_param(&json!({"project_id": "abc"})).unwrap(), "abc");
        assert!(project_id_param(&json!({"url": "http://x/y"})).is_err());
    }
}

#[cfg(test)]
mod e2e {
    use super::*;
    use overleaf::fake::{FakeServer, Mode, PROJECT_ID};
    use std::time::Duration;
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

    struct Rpc {
        w: tokio::net::unix::OwnedWriteHalf,
        lines: tokio::io::Lines<BufReader<tokio::net::unix::OwnedReadHalf>>,
        next: u64,
        notes: Vec<Value>,
    }

    impl Rpc {
        async fn call(&mut self, method: &str, params: Value) -> Result<Value, Value> {
            self.next += 1;
            let id = self.next;
            let req = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
            self.w.write_all(format!("{req}\n").as_bytes()).await.unwrap();
            loop {
                let line = tokio::time::timeout(Duration::from_secs(10), self.lines.next_line())
                    .await
                    .expect("rpc timeout")
                    .unwrap()
                    .unwrap();
                let v: Value = serde_json::from_str(&line).unwrap();
                if v.get("id") == Some(&json!(id)) {
                    return match v.get("error") {
                        Some(e) => Err(e.clone()),
                        None => Ok(v["result"].clone()),
                    };
                }
                self.notes.push(v);
            }
        }

        /// Wait for a notification matching `f`, looking at ones already received first.
        async fn wait_note(&mut self, f: impl Fn(&Value) -> bool) -> Value {
            if let Some(i) = self.notes.iter().position(&f) {
                return self.notes.remove(i);
            }
            loop {
                let line = tokio::time::timeout(Duration::from_secs(15), self.lines.next_line())
                    .await
                    .expect("notification timeout")
                    .unwrap()
                    .unwrap();
                let v: Value = serde_json::from_str(&line).unwrap();
                if f(&v) {
                    return v;
                }
                self.notes.push(v);
            }
        }
    }

    fn test_home(name: &str) -> PathBuf {
        let home = std::env::temp_dir().join(format!("taudot-test-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        home
    }

    async fn start_engine(fake: &FakeServer, name: &str) -> (Rpc, PathBuf) {
        start_engine_in(fake, test_home(name)).await
    }

    async fn start_engine_in(fake: &FakeServer, home: PathBuf) -> (Rpc, PathBuf) {
        let login = Login {
            url: fake.base.clone(),
            env_file: None,
            user: "user1".into(),
            email: None,
            password: None,
            cookie: Some("overleaf_session2=s%3Afake".into()),
            sessions: None,
        };
        let h = home.clone();
        tokio::spawn(async move { run(Args { login, home: Some(h) }).await.unwrap() });
        let sock = home.join("engine.sock");
        for _ in 0..100 {
            if let Ok(s) = UnixStream::connect(&sock).await {
                let (r, w) = s.into_split();
                return (Rpc { w, lines: BufReader::new(r).lines(), next: 0, notes: vec![] }, home);
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        panic!("engine did not start");
    }

    fn is_state(doc: &str, state: &str) -> impl Fn(&Value) -> bool {
        let (doc, state) = (doc.to_string(), state.to_string());
        move |v| v["method"] == "doc.state" && v["params"]["doc_id"] == doc.as_str() && v["params"]["state"] == state.as_str()
    }

    #[tokio::test]
    async fn edit_remote_and_reconnect() {
        let fake = FakeServer::start("héllo\nworld", Mode::Confirm).await;
        let (mut rpc, home) = start_engine(&fake, "e2e").await;
        assert!(home.join("engine.json").exists());

        let info = rpc.call("engine.info", json!({})).await.unwrap();
        assert_eq!(info["api_level"], 0);
        assert_eq!(rpc.call("nope", json!({})).await.unwrap_err()["code"], -32601);

        let url = format!("{}/project/{PROJECT_ID}", fake.base);
        let p = rpc.call("project.open", json!({"url": url})).await.unwrap();
        assert_eq!(p["docs"][0]["path"], "main.tex");
        let d = rpc.call("doc.open", json!({"project_id": PROJECT_ID, "path": "main.tex"})).await.unwrap();
        assert_eq!(d["text"], "héllo\nworld");
        let doc = d["doc_id"].as_str().unwrap().to_string();
        assert_eq!(rpc.call("doc.subscribe", json!({"doc_id": doc, "since_seq": 0})).await.unwrap()["seq"], 0);

        // Local edit: bytes 7 is after "héllo\n" (é is 2 bytes); JS index 6.
        let r = rpc.call("doc.edit", json!({"doc_id": doc, "seq": 0, "edits": [{"pos": 7, "del": 0, "ins": "big "}]})).await;
        assert_eq!(r.unwrap()["seq"], 1);
        rpc.wait_note(is_state(&doc, "idle")).await;
        assert_eq!(fake.state.lock().unwrap().text, "héllo\nbig world");
        assert_eq!(fake.state.lock().unwrap().sent_classic(0), json!([{"p": 6, "i": "big "}]));

        // An edit from seq 0 (before "big ") is transformed: "!" after "héllo" lands before "\nbig ".
        let r = rpc.call("doc.edit", json!({"doc_id": doc, "seq": 0, "edits": [{"pos": 6, "del": 0, "ins": "!"}]})).await;
        assert_eq!(r.unwrap()["seq"], 2);
        rpc.wait_note(is_state(&doc, "idle")).await;
        assert_eq!(fake.state.lock().unwrap().text, "héllo!\nbig world");
        // The sender doesn't get its own edits back as notifications.
        assert!(!rpc.notes.iter().any(|v| v["method"] == "doc.changed" && v["params"]["origin"] == "local"));

        // A collaborator types.
        fake.remote_insert(1, "Z");
        let n = rpc.wait_note(|v| v["method"] == "doc.changed" && v["params"]["origin"] == "remote").await;
        assert_eq!(n["params"]["edits"], json!([{"pos": 1, "del": 0, "ins": "Z"}]));
        assert_eq!(n["params"]["author"]["user_id"], "u2");
        assert_eq!(n["params"]["seq"], 3);

        // Server drops everyone; a remote edit lands while we're away; the engine reconnects and catches up.
        let mut st = rpc.call("project.status", json!({"project_id": PROJECT_ID})).await.unwrap();
        assert_eq!(st["connection"], "online");
        fake.drop_connections();
        tokio::time::sleep(Duration::from_millis(50)).await;
        fake.remote_insert(0, "A");
        let n = rpc.wait_note(|v| v["method"] == "doc.changed" && v["params"]["seq"] == 4).await;
        assert_eq!(n["params"]["edits"], json!([{"pos": 0, "del": 0, "ins": "A"}]));
        for _ in 0..50 {
            st = rpc.call("project.status", json!({"project_id": PROJECT_ID})).await.unwrap();
            if st["connection"] == "online" {
                break;
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        assert_eq!(st["connection"], "online");
        assert_eq!(fake.state.lock().unwrap().connections, 2);

        // Edits still go through on the new connection.
        rpc.call("doc.edit", json!({"doc_id": doc, "seq": 4, "edits": [{"pos": 0, "del": 1, "ins": ""}]})).await.unwrap();
        rpc.wait_note(is_state(&doc, "idle")).await;
        assert_eq!(fake.state.lock().unwrap().version, 12);
        let _ = std::fs::remove_dir_all(&home);
    }

    #[tokio::test]
    async fn inflight_across_reconnect_is_not_applied_twice() {
        // The server applies our update but the confirmation is lost; then the connection drops. The catch-up
        // joinDoc returns our own op (meta.source = old connection), which must count as the confirmation.
        let fake = FakeServer::start("abc", Mode::DropFirstConfirm).await;
        let (mut rpc, home) = start_engine(&fake, "inflight").await;
        rpc.call("project.open", json!({"project_id": PROJECT_ID})).await.unwrap();
        let d = rpc.call("doc.open", json!({"project_id": PROJECT_ID, "path": "main.tex"})).await.unwrap();
        let doc = d["doc_id"].as_str().unwrap().to_string();
        rpc.call("doc.subscribe", json!({"doc_id": doc, "since_seq": 0})).await.unwrap();
        rpc.call("doc.edit", json!({"doc_id": doc, "seq": 0, "edits": [{"pos": 3, "del": 0, "ins": "!"}]})).await.unwrap();
        rpc.wait_note(is_state(&doc, "inflight")).await;
        fake.drop_connections();
        rpc.wait_note(is_state(&doc, "idle")).await;
        let s = fake.state.lock().unwrap();
        assert_eq!(s.text, "abc!", "applied exactly once");
        assert_eq!(s.version, 8);
        // Either no resend, or a resend the server recognised as a dup.
        assert!(s.received.iter().skip(1).all(|u| u["dupIfSource"].is_array()));
        drop(s);
        let _ = std::fs::remove_dir_all(&home);
    }

    async fn open_main(rpc: &mut Rpc, folder: Option<&std::path::Path>) -> String {
        let mut p = json!({"project_id": PROJECT_ID});
        if let Some(f) = folder {
            p["folder"] = json!(f);
        }
        rpc.call("project.open", p).await.unwrap();
        let d = rpc.call("doc.open", json!({"project_id": PROJECT_ID, "path": "main.tex"})).await.unwrap();
        let doc = d["doc_id"].as_str().unwrap().to_string();
        rpc.call("doc.subscribe", json!({"doc_id": doc, "since_seq": d["seq"]})).await.unwrap();
        doc
    }

    /// Waits until the doc is idle and its text equals the server's; returns the text.
    async fn converged(rpc: &mut Rpc, fake: &FakeServer, doc: &str) -> String {
        let mut last = Value::Null;
        for _ in 0..200 {
            let st = rpc.call("project.status", json!({"project_id": PROJECT_ID})).await.unwrap();
            let d = st["docs"].as_array().unwrap().iter().find(|d| d["doc_id"] == doc).unwrap().clone();
            assert!(d["readonly"].is_null(), "doc went read-only: {d}");
            if d["state"] == "idle" && st["connection"] == "online" {
                let t = rpc.call("doc.open", json!({"project_id": PROJECT_ID, "path": "main.tex"})).await.unwrap();
                let server = fake.state.lock().unwrap().text.clone();
                if t["text"] == server.as_str() {
                    return server;
                }
                last = json!({"engine": t["text"], "server": server});
            } else {
                last = d;
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        panic!("did not converge: {last}");
    }

    #[tokio::test]
    async fn remote_op_racing_inflight_edit_is_transformed() {
        let fake = FakeServer::start("hello world", Mode::Confirm).await;
        let (mut rpc, home) = start_engine(&fake, "race").await;
        let doc = open_main(&mut rpc, None).await;
        fake.pause();
        rpc.call("doc.edit", json!({"doc_id": doc, "seq": 0, "edits": [{"pos": 5, "del": 0, "ins": ","}]})).await.unwrap();
        rpc.wait_note(is_state(&doc, "inflight")).await;
        // A collaborator's edit lands first; ours is transformed on the server, theirs in the engine.
        fake.remote_op(7, json!([{"p": 6, "d": "w"}, {"p": 6, "i": "W"}])).unwrap();
        let n = rpc.wait_note(|v| v["method"] == "doc.changed" && v["params"]["origin"] == "remote").await;
        assert_eq!(n["params"]["seq"], 2);
        // history-ot puts an insert before a remove at the same place, so the visible edits come in that order.
        let want = if fake.state.lock().unwrap().history_ot {
            json!([{"pos": 7, "del": 0, "ins": "W"}, {"pos": 8, "del": 1, "ins": ""}])
        } else {
            json!([{"pos": 7, "del": 1, "ins": ""}, {"pos": 7, "del": 0, "ins": "W"}])
        };
        assert_eq!(n["params"]["edits"], want);
        // A stale edit from before both changes: "!" at the end of "hello world".
        rpc.call("doc.edit", json!({"doc_id": doc, "seq": 0, "edits": [{"pos": 11, "del": 0, "ins": "!"}]})).await.unwrap();
        fake.resume();
        assert_eq!(converged(&mut rpc, &fake, &doc).await, "hello, World!");
        let _ = std::fs::remove_dir_all(&home);
    }

    #[tokio::test]
    async fn missing_ops_while_inflight_rebases() {
        let fake = FakeServer::start("one two", Mode::Confirm).await;
        let (mut rpc, home) = start_engine(&fake, "rebase").await;
        let folder = home.join("proj");
        let doc = open_main(&mut rpc, Some(&folder)).await;
        assert_eq!(std::fs::read_to_string(folder.join("main.tex")).unwrap(), "one two");
        fake.pause();
        rpc.call("doc.edit", json!({"doc_id": doc, "seq": 0, "edits": [{"pos": 7, "del": 0, "ins": " three"}]})).await.unwrap();
        rpc.wait_note(is_state(&doc, "inflight")).await;
        // The held update is lost with the connection, the server moves on and forgets the ops we'd need.
        fake.drop_connections();
        fake.remote_op(7, json!([{"p": 0, "i": "zero "}])).unwrap();
        fake.forget_history();
        fake.resume();
        assert_eq!(converged(&mut rpc, &fake, &doc).await, "zero one two three");
        tokio::time::sleep(Duration::from_millis(400)).await;
        assert_eq!(std::fs::read_to_string(folder.join("main.tex")).unwrap(), "zero one two three");
        let _ = std::fs::remove_dir_all(&home);
    }

    #[tokio::test]
    async fn edits_are_batched_like_the_browser() {
        // Scaled-down browser delays: alone, an edit waits 600 ms; once someone else edits, 150 ms.
        engine::TEST_FLUSH_DELAYS.with(|c| c.set(Some((Duration::from_millis(600), Duration::from_millis(150)))));
        let fake = FakeServer::start("abc", Mode::Confirm).await;
        let (mut rpc, home) = start_engine(&fake, "batch").await;
        let doc = open_main(&mut rpc, None).await;
        let sent = |f: &FakeServer| f.state.lock().unwrap().received.len();
        // Typing alone for 1.2 s, a key every 60 ms: two or three updates, not twenty.
        for i in 0..20u64 {
            rpc.call("doc.edit", json!({"doc_id": doc, "seq": i, "edits": [{"pos": 3 + i, "del": 0, "ins": "x"}]}))
                .await
                .unwrap();
            tokio::time::sleep(Duration::from_millis(60)).await;
        }
        assert_eq!(converged(&mut rpc, &fake, &doc).await, format!("abc{}", "x".repeat(20)));
        let alone = sent(&fake);
        assert!((1..=3).contains(&alone), "{alone} updates for 20 keys typed alone");
        // A collaborator edits: from then on updates go out every 150 ms.
        fake.remote_insert(0, ">");
        tokio::time::sleep(Duration::from_millis(200)).await;
        let before = sent(&fake);
        for i in 0..20u64 {
            rpc.call("doc.edit", json!({"doc_id": doc, "seq": 21 + i, "edits": [{"pos": 24 + i, "del": 0, "ins": "y"}]}))
                .await
                .unwrap();
            tokio::time::sleep(Duration::from_millis(60)).await;
        }
        converged(&mut rpc, &fake, &doc).await;
        let together = sent(&fake) - before;
        assert!((4..=12).contains(&together), "{together} updates for 20 keys with a collaborator");
        let _ = std::fs::remove_dir_all(&home);
    }

    #[tokio::test]
    async fn rejoin_with_an_op_still_queued_applies_it_once() {
        // E4: a doc rejoins on the same connection (an update didn't fit our copy) while our op is still queued on
        // the server. The full join doesn't show it, so it must not be sent again as a new op: when the queued one
        // is applied, it would be there twice.
        let fake = FakeServer::start("abc", Mode::Confirm).await;
        let (mut rpc, home) = start_engine(&fake, "rejoinq").await;
        let doc = open_main(&mut rpc, None).await;
        fake.pause();
        rpc.call("doc.edit", json!({"doc_id": doc, "seq": 0, "edits": [{"pos": 3, "del": 0, "ins": "!"}]})).await.unwrap();
        rpc.wait_note(is_state(&doc, "inflight")).await;
        let v = fake.state.lock().unwrap().version;
        fake.broadcast_raw(json!({"doc": overleaf::fake::DOC_ID, "v": v, "op": [{"p": 99, "d": "zzz"}],
            "meta": {"source": "P.x", "user_id": "u2", "ts": 1}}));
        tokio::time::sleep(Duration::from_millis(500)).await;
        fake.resume();
        let text = converged(&mut rpc, &fake, &doc).await;
        assert_eq!(text, "abc!", "applied once");
        let _ = std::fs::remove_dir_all(&home);
    }

    #[tokio::test]
    async fn rejoin_after_a_lost_confirmation_applies_it_once() {
        // E4, the other way: our op was applied but its confirmation lost; a same-connection rejoin must count it.
        let fake = FakeServer::start("abc", Mode::DropFirstConfirm).await;
        let (mut rpc, home) = start_engine(&fake, "rejoinc").await;
        let doc = open_main(&mut rpc, None).await;
        rpc.call("doc.edit", json!({"doc_id": doc, "seq": 0, "edits": [{"pos": 0, "del": 0, "ins": "!"}]})).await.unwrap();
        let s = fake.state.clone();
        until("applied", || s.lock().unwrap().text == "!abc").await;
        let v = fake.state.lock().unwrap().version;
        fake.broadcast_raw(json!({"doc": overleaf::fake::DOC_ID, "v": v, "op": [{"p": 99, "d": "zzz"}],
            "meta": {"source": "P.x", "user_id": "u2", "ts": 1}}));
        assert_eq!(converged(&mut rpc, &fake, &doc).await, "!abc");
        let _ = std::fs::remove_dir_all(&home);
    }

    #[tokio::test]
    async fn actor_answers_while_a_reconnect_hangs() {
        // E5: a half-open network (the server accepts and never answers) during a reconnect must not freeze the
        // project: status and edits are answered, and the edits are backed up.
        let fake = FakeServer::start("abc", Mode::Confirm).await;
        let (mut rpc, home) = start_engine(&fake, "stall").await;
        let doc = open_main(&mut rpc, None).await;
        fake.state.lock().unwrap().stall = true;
        fake.drop_connections();
        tokio::time::sleep(Duration::from_millis(1200)).await;
        let t = std::time::Instant::now();
        let st = rpc.call("project.status", json!({"project_id": PROJECT_ID})).await.unwrap();
        assert_ne!(st["connection"], "online");
        let r = rpc.call("doc.edit", json!({"doc_id": doc, "seq": 0, "edits": [{"pos": 0, "del": 0, "ins": "x"}]})).await.unwrap();
        assert_eq!(r["seq"], 1);
        assert!(t.elapsed() < Duration::from_secs(2), "answered after {:?}", t.elapsed());
        let backups = home.join("backup");
        until("edit backed up while offline", || {
            walk(&backups).iter().any(|p| std::fs::read_to_string(p).is_ok_and(|s| s.contains("xabc") || s.contains("\"x\"")))
        })
        .await;
        fake.state.lock().unwrap().stall = false;
        assert_eq!(converged(&mut rpc, &fake, &doc).await, "xabc");
        let _ = std::fs::remove_dir_all(&home);
    }

    fn walk(dir: &std::path::Path) -> Vec<PathBuf> {
        let mut out = vec![];
        for e in std::fs::read_dir(dir).into_iter().flatten().flatten() {
            let p = e.path();
            if p.is_dir() {
                out.extend(walk(&p));
            } else {
                out.push(p);
            }
        }
        out
    }

    #[tokio::test]
    async fn tracked_edit_replayed_from_a_backup_stays_tracked() {
        // E6: an engine dies with a tracked edit in flight; the next one replays it from the backup, tracked.
        let fake = FakeServer::start("abc", Mode::Confirm).await;
        let (mut rpc, home) = start_engine(&fake, "trackbk").await;
        let doc = open_main(&mut rpc, None).await;
        rpc.call("review.track", json!({"project_id": PROJECT_ID, "on": true})).await.unwrap();
        fake.pause();
        rpc.call("doc.edit", json!({"doc_id": doc, "seq": 0, "edits": [{"pos": 3, "del": 0, "ins": "T"}]})).await.unwrap();
        let file = home.join("backup").join(PROJECT_ID).join(format!("{doc}.json"));
        let f2 = file.clone();
        until("backup written", || f2.exists()).await;
        // The crash: a second engine finds this backup; the first one's send never reaches the server.
        let mut b: Value = serde_json::from_str(&std::fs::read_to_string(&file).unwrap()).unwrap();
        b["sent_under"] = json!(["P.never"]);
        let home2 = test_home("trackbk2");
        engine::write_atomic(&home2.join("backup").join(PROJECT_ID).join(format!("{doc}.json")), &b.to_string()).unwrap();
        fake.state.lock().unwrap().received.clear();
        fake.state.lock().unwrap().reject_containing = Some("\"T\"".into()); // (the first engine's held copy, refused)
        fake.drop_connections();
        fake.resume();
        let (mut rpc2, _) = start_engine_in(&fake, home2.clone()).await;
        fake.state.lock().unwrap().reject_containing = None;
        let doc2 = open_main(&mut rpc2, None).await;
        assert_eq!(converged(&mut rpc2, &fake, &doc2).await, "abcT");
        let s = fake.state.lock().unwrap();
        let sent: Vec<&Value> = s.received.iter().filter(|u| u.to_string().contains("\"T\"")).collect();
        // (tracked: `meta.tc` on a classic update, `tracking` in a history-ot one)
        assert!(!sent.is_empty() && sent.iter().all(|u| u["meta"]["tc"].is_string() || u["op"].to_string().contains("tracking")), "replayed untracked: {sent:?}");
        drop(s);
        for h in [home, home2] {
            let _ = std::fs::remove_dir_all(&h);
        }
    }

    #[tokio::test]
    async fn doc_deleted_with_unsent_edits_keeps_them() {
        // E12: a collaborator deletes a doc while our edit to it is unconfirmed. The edit can't go anywhere, but the
        // text with it is kept (and said so), and its backup isn't left behind to be replayed.
        let fake = FakeServer::start("abc", Mode::Confirm).await;
        let (mut rpc, home) = start_engine(&fake, "delunsent").await;
        rpc.call("project.open", json!({"project_id": PROJECT_ID})).await.unwrap();
        rpc.call("activity.subscribe", json!({"project_id": PROJECT_ID})).await.unwrap();
        fake.remote_new_doc("", "gone.tex", "Gone.\n");
        rpc.wait_note(|v| v["method"] == "project.tree" && v["params"]["change"]["path"] == "gone.tex").await;
        let d = rpc.call("doc.open", json!({"project_id": PROJECT_ID, "path": "gone.tex"})).await.unwrap();
        let id = d["doc_id"].as_str().unwrap().to_string();
        rpc.call("doc.subscribe", json!({"doc_id": id, "since_seq": d["seq"]})).await.unwrap();
        fake.pause();
        rpc.call("doc.edit", json!({"doc_id": id, "seq": d["seq"], "edits": [{"pos": 0, "del": 0, "ins": "UNSENT "}]})).await.unwrap();
        let backup = home.join("backup").join(PROJECT_ID).join(format!("{id}.json"));
        let b2 = backup.clone();
        until("backup written", || b2.exists()).await;
        fake.remote_delete("gone.tex");
        let n = rpc.wait_note(|v| v["method"] == "activity" && v["params"]["text"].as_str().is_some_and(|t| t.contains("unsent"))).await;
        assert!(n["params"]["text"].as_str().unwrap().contains("gone.tex"), "{n}");
        let kept = walk(&home.join("backup").join("deleted"));
        assert!(kept.iter().any(|p| std::fs::read_to_string(p).is_ok_and(|t| t == "UNSENT Gone.\n")), "{kept:?}");
        assert!(!backup.exists(), "backup of a deleted doc left behind");
        fake.resume();
        let _ = std::fs::remove_dir_all(&home);
    }

    #[tokio::test]
    async fn half_written_file_is_not_sent_as_a_deletion() {
        // E10: another program writes a doc's file slowly (truncate, then the rest half a second later). The engine
        // must not send the half it read as a big deletion (it would delete what collaborators wrote there too).
        let long: String = (0..40).map(|i| format!("Line {i} of the paper, long enough to matter.\n")).collect();
        let fake = FakeServer::start(&long, Mode::Confirm).await;
        let (mut rpc, home) = start_engine(&fake, "halfwrite").await;
        let folder = home.join("proj");
        rpc.call("project.open", json!({"project_id": PROJECT_ID, "folder": folder})).await.unwrap();
        let folder = folder.canonicalize().unwrap();
        let main = folder.join("main.tex");
        let m2 = main.clone();
        let l2 = long.clone();
        until("mirrored", || std::fs::read_to_string(&m2).is_ok_and(|t| t == l2)).await;
        tokio::time::sleep(Duration::from_millis(500)).await;
        let full = format!("{long}One more line.\n");
        std::fs::write(&main, &full[..200]).unwrap();
        tokio::time::sleep(Duration::from_millis(600)).await;
        std::fs::write(&main, &full).unwrap();
        let s = fake.state.clone();
        let f2 = full.clone();
        until("the whole file reached the server", || s.lock().unwrap().text == f2).await;
        let s = fake.state.lock().unwrap();
        let big_delete = s.received.iter().any(|u| u["op"].as_array().into_iter().flatten().any(|c| c["d"].as_str().is_some_and(|d| d.len() > 100)));
        assert!(!big_delete, "a half-written file was sent: {:?}", s.received);
        drop(s);
        // A real cut stays cut, and goes out once confirmed.
        std::fs::write(&main, "Short now.\n").unwrap();
        let s = fake.state.clone();
        until("the cut reached the server", || s.lock().unwrap().text == "Short now.\n").await;
        let _ = std::fs::remove_dir_all(&home);
    }

    #[tokio::test]
    async fn remote_rename_after_the_mirror_wrote_the_new_name() {
        // E11: the mirror wrote the doc under its new name before the rename's disk work ran. The old file must not
        // be left behind (a later scan would upload it as a second doc).
        let fake = FakeServer::start("hello\n", Mode::Confirm).await;
        let (mut rpc, home) = start_engine(&fake, "renrace").await;
        let folder = home.join("proj");
        rpc.call("project.open", json!({"project_id": PROJECT_ID, "folder": folder})).await.unwrap();
        let folder = folder.canonicalize().unwrap();
        let f2 = folder.clone();
        until("mirrored", || std::fs::read_to_string(f2.join("main.tex")).is_ok_and(|t| t == "hello\n")).await;
        // (the mirror's write under the new name, as when it runs first in the tick)
        std::fs::write(folder.join("paper.tex"), "hello\n").unwrap();
        fake.remote_rename("main.tex", "paper.tex");
        let f2 = folder.clone();
        until("old name gone", || !f2.join("main.tex").exists() && f2.join("paper.tex").exists()).await;
        tokio::time::sleep(Duration::from_millis(800)).await;
        let s = fake.state.lock().unwrap();
        assert!(s.tree.find("main.tex").is_none() && s.tree.list(overleaf::Kind::Doc).len() == 1, "{:?}", s.tree.list(overleaf::Kind::Doc));
        drop(s);
        let _ = std::fs::remove_dir_all(&home);
    }

    #[tokio::test]
    async fn a_stopped_project_actor_is_replaced() {
        // E18: a project actor that stopped (a panic, here a shutdown) left its handle in the map: every later call
        // for the project failed with "project actor stopped" until the engine restarted.
        let fake = FakeServer::start("abc", Mode::Confirm).await;
        let home = test_home("deadactor");
        let login = Login { url: fake.base.clone(), env_file: None, user: "user1".into(), email: None, password: None,
            cookie: Some("overleaf_session2=s%3Afake".into()), sessions: None };
        let state = State { login, projects: Mutex::new(HashMap::new()), opening: Mutex::new(()),
            doc_project: Mutex::new(HashMap::new()), notes: broadcast::channel(64).0, home: home.clone(),
            next_client: AtomicU64::new(1) };
        let p = json!({"project_id": PROJECT_ID});
        open_project(&state, &p).await.unwrap();
        let h = state.projects.lock().await.get(PROJECT_ID).cloned().unwrap();
        h.ask(Cmd::Shutdown).await.unwrap();
        tokio::time::sleep(Duration::from_millis(100)).await;
        let r = open_project(&state, &p).await;
        assert!(r.is_ok(), "reopening after the actor stopped: {r:?}");
        let doc = r.unwrap()["docs"][0]["doc_id"].as_str().unwrap().to_string();
        let h = project_for_doc(&state, &doc).await.unwrap();
        assert!(h.ask(Cmd::Tree).await.is_ok());
        let _ = std::fs::remove_dir_all(&home);
    }

    #[tokio::test]
    async fn rejected_op_is_not_resent_forever() {
        // E3: Overleaf refuses an op (otUpdateError, then disconnect). The engine must not reconnect and resend it in
        // a tight loop: the doc stops sending (read-only, edits kept) and reconnects back off.
        let fake = FakeServer::start("abc", Mode::Confirm).await;
        let (mut rpc, home) = start_engine(&fake, "poison").await;
        let doc = open_main(&mut rpc, None).await;
        fake.state.lock().unwrap().reject_containing = Some("POISON".into());
        rpc.call("doc.edit", json!({"doc_id": doc, "seq": 0, "edits": [{"pos": 3, "del": 0, "ins": "POISON"}]})).await.unwrap();
        tokio::time::sleep(Duration::from_secs(4)).await;
        let (conns, sent) = {
            let s = fake.state.lock().unwrap();
            (s.connections, s.received.len())
        };
        assert!(conns <= 5, "reconnected {conns} times in 4 s");
        assert!(sent <= 3, "the refused op was sent {sent} times");
        let st = rpc.call("project.status", json!({"project_id": PROJECT_ID})).await.unwrap();
        let d = st["docs"].as_array().unwrap().iter().find(|d| d["doc_id"] == doc.as_str()).unwrap().clone();
        assert!(d["readonly"].as_str().is_some_and(|r| r.contains("refused")), "{d}");
        assert_eq!(fake.state.lock().unwrap().text, "abc");
        let _ = std::fs::remove_dir_all(&home);
    }

    #[tokio::test]
    async fn edit_id_resend_is_applied_once() {
        let fake = FakeServer::start("abc", Mode::Confirm).await;
        let (mut rpc, home) = start_engine(&fake, "editid").await;
        let doc = open_main(&mut rpc, None).await;
        let e = json!({"doc_id": doc, "seq": 0, "edit_id": "e1", "edits": [{"pos": 0, "del": 0, "ins": "x"}]});
        assert_eq!(rpc.call("doc.edit", e.clone()).await.unwrap()["seq"], 1);
        assert_eq!(rpc.call("doc.edit", e).await.unwrap()["seq"], 1);
        assert_eq!(converged(&mut rpc, &fake, &doc).await, "xabc");
        let _ = std::fs::remove_dir_all(&home);
    }

    #[tokio::test]
    async fn emoji_become_replacement_characters() {
        // As Overleaf stores them (docs/protocol.md, Astral characters): the server only ever gets U+FFFD, and the
        // editing client gets the replacement as a doc.changed right after its result.
        let fake = FakeServer::start("abc", Mode::Confirm).await;
        let (mut rpc, home) = start_engine(&fake, "emoji").await;
        let doc = open_main(&mut rpc, None).await;
        let r = rpc.call("doc.edit", json!({"doc_id": doc, "seq": 0, "edits": [{"pos": 1, "del": 0, "ins": "😀é😀"}]})).await;
        assert_eq!(r.unwrap()["seq"], 1);
        assert!(!rpc.notes.iter().any(|v| v["method"] == "doc.changed"), "nothing before the result");
        let n = rpc.wait_note(|v| v["method"] == "doc.changed" && v["params"]["seq"] == 2).await;
        assert_eq!(n["params"]["edits"], json!([
            {"pos": 1, "del": 4, "ins": ""}, {"pos": 1, "del": 0, "ins": "\u{FFFD}\u{FFFD}"},
            {"pos": 9, "del": 4, "ins": ""}, {"pos": 9, "del": 0, "ins": "\u{FFFD}\u{FFFD}"},
        ]));
        assert_eq!(n["params"]["origin"], "local");
        // An edit made before the client saw seq 2 is transformed past it.
        rpc.call("doc.edit", json!({"doc_id": doc, "seq": 1, "edits": [{"pos": 11, "del": 0, "ins": "!"}]})).await.unwrap();
        assert_eq!(converged(&mut rpc, &fake, &doc).await, "a\u{FFFD}\u{FFFD}é\u{FFFD}\u{FFFD}!bc");
        let st = fake.state.lock().unwrap();
        assert!(!st.text.contains('😀'));
        assert!(st.received.iter().all(|u| !u.to_string().contains('😀')), "an update with the emoji was sent: {:?}", st.received);
        drop(st);
        let _ = std::fs::remove_dir_all(&home);
    }

    #[tokio::test]
    async fn backup_is_written_and_replayed() {
        let fake = FakeServer::start("abc", Mode::Confirm).await;
        let (mut rpc, home) = start_engine(&fake, "backup").await;
        let doc = open_main(&mut rpc, None).await;
        fake.pause();
        rpc.call("doc.edit", json!({"doc_id": doc, "seq": 0, "edits": [{"pos": 3, "del": 0, "ins": "d"}]})).await.unwrap();
        let file = home.join("backup").join(PROJECT_ID).join(format!("{doc}.json"));
        for _ in 0..60 {
            if file.exists() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        let b: Value = serde_json::from_str(&std::fs::read_to_string(&file).unwrap()).unwrap();
        assert_eq!(b["text"], "abcd");
        assert_eq!(b["sent_under"], json!(["P.1"]));
        fake.resume();
        converged(&mut rpc, &fake, &doc).await;
        tokio::time::sleep(Duration::from_millis(2500)).await;
        assert!(!file.exists(), "backup removed once confirmed");

        // A second engine finds a backup from a crash: "e" in flight under P.1 (never applied), "f" pending.
        let home2 = test_home("backup2");
        let file2 = home2.join("backup").join(PROJECT_ID).join(format!("{doc}.json"));
        engine::write_atomic(&file2, &json!({"version": 8, "base": "abcd", "inflight": [{"p": 4, "i": "e"}],
            "sent_under": ["P.1"], "pending": [{"p": 5, "i": "f"}], "text": "abcdef"}).to_string()).unwrap();
        fake.remote_insert(0, ">");
        let (mut rpc2, _) = start_engine_in(&fake, home2.clone()).await;
        let doc2 = open_main(&mut rpc2, None).await;
        assert_eq!(converged(&mut rpc2, &fake, &doc2).await, ">abcdef");

        // And one whose inflight op the server did apply before the crash: it must not be applied twice.
        let home3 = test_home("backup3");
        let file3 = home3.join("backup").join(PROJECT_ID).join(format!("{doc}.json"));
        let v = fake.state.lock().unwrap().version;
        let http = overleaf::Http::with_cookie(&fake.base, "overleaf_session2=s%3Afake").unwrap();
        let conn = overleaf::ProjectConn::connect(&http, PROJECT_ID, overleaf::Style::Auto).await.unwrap();
        let public_id = conn.public_id.clone();
        let op = fake.state.lock().unwrap().wire_for(v, json!([{"p": 7, "i": "g"}]));
        conn.apply_ot_update(&overleaf::OutgoingUpdate { doc: doc.clone(), op, v,
            last_v: None, hash: None, meta: None, dup_if_source: None }).await.unwrap();
        conn.disconnect();
        engine::write_atomic(&file3, &json!({"version": v, "base": ">abcdef", "inflight": [{"p": 7, "i": "g"}],
            "sent_under": [public_id], "pending": null, "text": ">abcdefg"}).to_string()).unwrap();
        let (mut rpc3, _) = start_engine_in(&fake, home3.clone()).await;
        let doc3 = open_main(&mut rpc3, None).await;
        assert_eq!(converged(&mut rpc3, &fake, &doc3).await, ">abcdefg");
        for h in [home, home2, home3] {
            let _ = std::fs::remove_dir_all(&h);
        }
    }

    /// xorshift, so the fuzz test needs no dependency and replays from its seed.
    struct Rng(u64);
    impl Rng {
        fn next(&mut self) -> u64 {
            self.0 ^= self.0 << 13;
            self.0 ^= self.0 >> 7;
            self.0 ^= self.0 << 17;
            self.0
        }
        fn below(&mut self, n: usize) -> usize {
            if n == 0 { 0 } else { (self.next() % n as u64) as usize }
        }
    }

    const WORDS: [&str; 6] = ["a", "é", "中文", " ", "\n", "xyz"];

    /// A random edit on `text` in bytes.
    fn random_edit(rng: &mut Rng, text: &str) -> Value {
        let bounds: Vec<usize> = text.char_indices().map(|(i, _)| i).chain([text.len()]).collect();
        let a = bounds[rng.below(bounds.len())];
        let b = bounds[rng.below(bounds.len())];
        let (pos, end) = (a.min(b), a.max(b));
        let del = if rng.below(3) == 0 { (end - pos).min(6).min(end - pos) } else { 0 };
        let del = bounds.iter().copied().filter(|&x| x >= pos && x <= pos + del).max().unwrap_or(pos) - pos;
        let ins = if del > 0 && rng.below(2) == 0 { String::new() } else { WORDS[rng.below(WORDS.len())].to_string() };
        json!({"pos": pos, "del": del, "ins": ins})
    }

    /// A random classic op on `text` (JS indexes).
    fn random_remote(rng: &mut Rng, text: &str) -> Value {
        let units: Vec<u16> = text.encode_utf16().collect();
        let bounds: Vec<usize> = (0..=units.len()).filter(|&i| i == units.len() || !(0xDC00..0xE000).contains(&units[i])).collect();
        let p = bounds[rng.below(bounds.len())];
        if rng.below(3) == 0 && p < units.len() {
            let end = bounds.iter().copied().filter(|&x| x > p && x <= p + 4).max().unwrap_or(p);
            if end > p {
                return json!([{"p": p, "d": String::from_utf16(&units[p..end]).unwrap()}]);
            }
        }
        json!([{"p": p, "i": WORDS[rng.below(WORDS.len())]}])
    }

    #[tokio::test]
    async fn fuzz_local_and_remote_edits_converge() {
        let seed = std::env::var("TAUDOT_FUZZ_SEED").ok().and_then(|s| s.parse().ok()).unwrap_or(0x5eed_1234_u64);
        let rounds: usize = std::env::var("TAUDOT_FUZZ_ROUNDS").ok().and_then(|s| s.parse().ok()).unwrap_or(3);
        let fake = FakeServer::start("start\n", Mode::Confirm).await;
        let (mut rpc, home) = start_engine(&fake, "fuzz").await;
        let folder = home.join("proj");
        let doc = open_main(&mut rpc, Some(&folder)).await;
        let mut rng = Rng(seed);
        for round in 0..rounds {
            // The API client edits from a snapshot that goes stale while the collaborator types.
            let snap = rpc.call("doc.open", json!({"project_id": PROJECT_ID, "path": "main.tex"})).await.unwrap();
            let (seq, text) = (snap["seq"].as_u64().unwrap(), snap["text"].as_str().unwrap().to_string());
            for step in 0..40 {
                match rng.below(10) {
                    0..=3 => {
                        // Every edit in a round is made on the round's snapshot, so later ones are stale against
                        // the earlier ones as well as the collaborator's.
                        let e = random_edit(&mut rng, &text);
                        rpc.call("doc.edit", json!({"doc_id": doc, "seq": seq, "edits": [e]})).await.unwrap();
                    }
                    4..=7 => {
                        let (v, t) = {
                            let s = fake.state.lock().unwrap();
                            // Sometimes at an older version, as a collaborator whose op crossed others.
                            let back = rng.below(3).min(s.history.len()) as u64;
                            let v = s.version - back;
                            let t = s.text_at(v);
                            (v, t)
                        };
                        fake.remote_op(v, random_remote(&mut rng, &t)).unwrap();
                    }
                    8 => {
                        if rng.below(2) == 0 { fake.pause() } else { fake.resume() }
                    }
                    _ => {
                        if rng.below(4) == 0 {
                            fake.drop_connections();
                        }
                    }
                }
                if step % 5 == 0 {
                    tokio::time::sleep(Duration::from_millis(rng.below(30) as u64)).await;
                }
            }
            if round % 3 == 2 {
                fake.resume();
                converged(&mut rpc, &fake, &doc).await;
            }
        }
        fake.resume();
        let text = converged(&mut rpc, &fake, &doc).await;
        tokio::time::sleep(Duration::from_millis(400)).await;
        assert_eq!(std::fs::read_to_string(folder.join("main.tex")).unwrap(), text);
        let _ = std::fs::remove_dir_all(&home);
    }

    /// Against the local Overleaf CE: Alice's and Bob's engines, and optionally a browser running Overleaf's own editor
    /// (`harness/serve.ts`), type random edits into one doc at once; all must converge with the server, with no doc
    /// going read-only, and both folder mirrors must match. Needs a throwaway project
    /// (`crates/engine/tests/ce/new-project.sh`), never the demo one:
    ///
    ///   TAUDOT_CE_PROJECT=<id> [TAUDOT_CE_SECS=60] [TAUDOT_CE_BROWSER=~/code/lab/taudot/harness/serve.ts] \
    ///     cargo test -p taudot-engine ce_ -- --ignored --nocapture
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    #[ignore = "needs local Overleaf CE and TAUDOT_CE_PROJECT"]
    async fn ce_two_engines_and_a_browser_converge() {
        let _ = tracing_subscriber::fmt()
            .with_env_filter(tracing_subscriber::EnvFilter::from_env("TAUDOT_LOG"))
            .with_writer(std::io::stderr)
            .try_init();
        let project = std::env::var("TAUDOT_CE_PROJECT").expect("TAUDOT_CE_PROJECT");
        let env_file = PathBuf::from(std::env::var("TAUDOT_ENV_FILE").unwrap_or_else(|_| {
            format!("{}/code/lab/taudot/docker/.env.test", std::env::var("HOME").unwrap())
        }));
        let secs: u64 = std::env::var("TAUDOT_CE_SECS").ok().and_then(|s| s.parse().ok()).unwrap_or(20);
        let seed: u64 = std::env::var("TAUDOT_FUZZ_SEED").ok().and_then(|s| s.parse().ok()).unwrap_or(0xce);
        let login = |user: &str| Login {
            url: "http://localhost:8800".into(),
            env_file: Some(env_file.clone()),
            user: user.into(),
            email: None,
            password: None,
            cookie: None,
            sessions: None,
        };
        async fn start(login: Login, home: PathBuf) -> Rpc {
            let h = home.clone();
            tokio::spawn(async move { run(Args { login, home: Some(h) }).await.unwrap() });
            for _ in 0..200 {
                if let Ok(s) = UnixStream::connect(home.join("engine.sock")).await {
                    let (r, w) = s.into_split();
                    return Rpc { w, lines: BufReader::new(r).lines(), next: 0, notes: vec![] };
                }
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
            panic!("engine did not start");
        }
        let (ha, hb) = (test_home("ce-alice"), test_home("ce-bob"));
        let mut a = start(login("user1"), ha.clone()).await;
        let mut b = start(login("user2"), hb.clone()).await;
        let mut docs = vec![];
        for (rpc, home) in [(&mut a, &ha), (&mut b, &hb)] {
            let r = rpc.call("project.open", json!({"project_id": project, "folder": home.join("proj")})).await.unwrap();
            eprintln!("opened as {}", r["me"]);
            let d = rpc.call("doc.open", json!({"project_id": project, "path": "main.tex"})).await.unwrap();
            docs.push(d["doc_id"].as_str().unwrap().to_string());
        }
        let doc = docs[0].clone();

        // The browser, if asked for.
        let mut browser = match std::env::var("TAUDOT_CE_BROWSER") {
            Ok(script) => {
                let script = script.replace('~', &std::env::var("HOME").unwrap());
                let mut child = tokio::process::Command::new("node")
                    .arg(&script)
                    .env("TAUDOT_ENV_FILE", &env_file)
                    .stdin(std::process::Stdio::piped())
                    .stdout(std::process::Stdio::piped())
                    .kill_on_drop(true)
                    .spawn()
                    .expect("node harness/serve.ts");
                let stdin = child.stdin.take().unwrap();
                let out = BufReader::new(child.stdout.take().unwrap()).lines();
                let mut br = Browser { _child: child, stdin, out };
                let r = br.cmd(json!({"cmd": "open", "project": project, "file": "main.tex", "user": "1"})).await;
                assert_eq!(r["ok"], true, "browser open: {r}");
                Some(br)
            }
            Err(_) => None,
        };

        let deadline = tokio::time::Instant::now() + Duration::from_secs(secs);
        let typer = |mut rpc: Rpc, project: String, doc: String, seed: u64| async move {
            let mut rng = Rng(seed);
            let mut sent = 0;
            while tokio::time::Instant::now() < deadline {
                let snap = rpc.call("doc.open", json!({"project_id": project, "path": "main.tex"})).await.unwrap();
                let (seq, text) = (snap["seq"].as_u64().unwrap(), snap["text"].as_str().unwrap().to_string());
                // Up to three edits from the same snapshot, so later ones are stale against the earlier ones and
                // whatever arrives meanwhile.
                for _ in 0..1 + rng.below(3) {
                    let e = random_edit(&mut rng, &text);
                    if let Err(e) = rpc.call("doc.edit", json!({"doc_id": doc, "seq": seq, "edits": [e]})).await {
                        panic!("doc.edit failed: {e}");
                    }
                    sent += 1;
                    tokio::time::sleep(Duration::from_millis(10 + rng.below(60) as u64)).await;
                }
                rpc.notes.clear();
            }
            (rpc, sent)
        };
        let ta = tokio::spawn(typer(a, project.clone(), doc.clone(), seed));
        let tb = tokio::spawn(typer(b, project.clone(), doc.clone(), seed ^ 0xb0b));
        let mut browser_edits = 0;
        if let Some(br) = browser.as_mut() {
            let mut rng = Rng(seed ^ 0xb7);
            while tokio::time::Instant::now() < deadline {
                let t = br.cmd(json!({"cmd": "text"})).await;
                let text = t["text"].as_str().unwrap_or("").to_string();
                let op = random_remote(&mut rng, &text);
                let c = &op[0];
                let e = match c.get("i") {
                    Some(i) => json!({"pos": c["p"], "text": i}),
                    None => json!({"pos": c["p"], "del": c["d"].as_str().unwrap().encode_utf16().count()}),
                };
                let r = br.cmd(json!({"cmd": "edit", "edits": [e]})).await;
                // The text can change between reading it and editing; then the harness refuses the edit.
                let stale = r["error"].as_str().is_some_and(|e| e.contains("outside doc"));
                assert!(r["ok"] == true || stale, "browser edit: {r}");
                browser_edits += usize::from(r["ok"] == true);
                tokio::time::sleep(Duration::from_millis(100 + rng.below(200) as u64)).await;
            }
        }
        let (mut a, na) = ta.await.unwrap();
        let (mut b, nb) = tb.await.unwrap();
        eprintln!("edits sent: alice {na}, bob {nb}, browser {browser_edits}");
        if let Some(br) = browser.as_mut() {
            let r = br.cmd(json!({"cmd": "settle", "timeoutMs": 60000})).await;
            assert_eq!(r["ok"], true, "browser settle: {r}");
        }

        // Wait for both engines to be idle and agree, then read the server's text with a fresh join.
        let mut texts = vec![];
        for rpc in [&mut a, &mut b] {
            let mut ok = false;
            for _ in 0..300 {
                let st = rpc.call("project.status", json!({"project_id": project})).await.unwrap();
                let d = st["docs"].as_array().unwrap().iter().find(|d| d["doc_id"] == doc.as_str()).unwrap().clone();
                assert!(d["readonly"].is_null(), "doc went read-only: {d}");
                if d["state"] == "idle" && st["connection"] == "online" {
                    ok = true;
                    break;
                }
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
            assert!(ok, "engine never went idle");
        }
        tokio::time::sleep(Duration::from_secs(2)).await;
        let mut hot = false;
        for rpc in [&mut a, &mut b] {
            let t = rpc.call("doc.open", json!({"project_id": project, "path": "main.tex"})).await.unwrap();
            texts.push(t["text"].as_str().unwrap().to_string());
            hot = t["type"] == "history-ot";
        }
        let http = login("user1").http().await.unwrap();
        let conn = ProjectConnForTest::join(&http, &project, &doc).await;
        eprintln!("server v{}, {} chars", conn.1, conn.0.chars().count());
        assert_eq!(texts[0], conn.0, "alice's engine differs from the server");
        assert_eq!(texts[1], conn.0, "bob's engine differs from the server");
        if let Some(br) = browser.as_mut() {
            let t = br.cmd(json!({"cmd": "text"})).await;
            let errs = br.cmd(json!({"cmd": "errors"})).await;
            if hot {
                // CE 6.3's browser drifts on history-ot docs with concurrent edits (Overleaf's bug, docs/protocol.md,
                // history-ot versions). Report it; the engines must be in sync regardless (checked above).
                let same = t["text"].as_str() == Some(conn.0.as_str());
                let n = errs["errors"].as_array().map_or(0, Vec::len);
                eprintln!("browser (history-ot): in sync with the server: {same}; server errors seen: {n}; first: {}",
                    errs["errors"].get(0).map(|e| e.to_string().chars().take(200).collect::<String>()).unwrap_or_default());
            } else {
                assert_eq!(t["text"].as_str().unwrap(), conn.0, "the browser differs from the server");
                assert_eq!(errs["errors"], json!([]), "browser saw server errors");
            }
            br.cmd(json!({"cmd": "close"})).await;
        }
        for home in [&ha, &hb] {
            let f = std::fs::read_to_string(home.join("proj/main.tex")).unwrap();
            assert_eq!(f, conn.0, "mirror in {} differs", home.display());
        }
        for home in [ha, hb] {
            let _ = std::fs::remove_dir_all(home);
        }
    }

    struct Browser {
        _child: tokio::process::Child,
        stdin: tokio::process::ChildStdin,
        out: tokio::io::Lines<BufReader<tokio::process::ChildStdout>>,
    }
    impl Browser {
        async fn cmd(&mut self, c: Value) -> Value {
            self.stdin.write_all(format!("{c}\n").as_bytes()).await.unwrap();
            let line = tokio::time::timeout(Duration::from_secs(90), self.out.next_line()).await.expect("browser timeout").unwrap().unwrap();
            serde_json::from_str(&line).unwrap()
        }
    }

    struct ProjectConnForTest;
    impl ProjectConnForTest {
        async fn join(http: &overleaf::Http, project: &str, doc: &str) -> (String, u64) {
            let conn = overleaf::ProjectConn::connect(http, project, overleaf::Style::Auto).await.unwrap();
            let j = conn.join_doc(doc, None, None).await.unwrap();
            conn.disconnect();
            (j.text(), j.version)
        }
    }

    /// Polls `f` until it's true (5 s), else panics with `what`.
    async fn until(what: &str, mut f: impl FnMut() -> bool) {
        for _ in 0..100 {
            if f() {
                return;
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        panic!("timed out: {what}");
    }

    #[tokio::test]
    async fn folder_ignore_rules() {
        let fake = FakeServer::start("hello\n", Mode::Confirm).await;
        let (mut rpc, home) = start_engine(&fake, "ignore").await;
        let folder = home.join("proj");
        std::fs::create_dir_all(&folder).unwrap();
        // .gitignore leaves out every PNG (sections/fig.png is already on Overleaf) and data/; .taudotignore lets
        // figs/*.png back in.
        std::fs::write(folder.join(".gitignore"), "*.png\ndata/\n").unwrap();
        std::fs::write(folder.join(".taudotignore"), "!figs/*.png\n").unwrap();
        rpc.call("project.open", json!({"project_id": PROJECT_ID, "folder": folder})).await.unwrap();
        let folder = folder.canonicalize().unwrap();
        // Overleaf's files are written whatever the rules say.
        assert_eq!(std::fs::read(folder.join("sections/fig.png")).unwrap(), overleaf::fake::FIG);
        std::fs::create_dir_all(folder.join("figs")).unwrap();
        std::fs::create_dir_all(folder.join("data")).unwrap();
        std::fs::write(folder.join("shot.png"), b"\x89PNG shot").unwrap();
        std::fs::write(folder.join("data/table.tex"), "x\n").unwrap();
        std::fs::write(folder.join(".latexmkrc"), "x").unwrap();
        std::fs::write(folder.join("figs/a.png"), b"\x89PNG a").unwrap();
        // A file Overleaf has keeps syncing, as a tracked file does in git.
        std::fs::write(folder.join("sections/fig.png"), b"\x89PNG v2").unwrap();
        let s = fake.state.clone();
        until("let-in and tracked files uploaded", || {
            let s = s.lock().unwrap();
            s.file("figs/a.png").as_deref() == Some(b"\x89PNG a".as_slice()) && s.file("sections/fig.png").as_deref() == Some(b"\x89PNG v2".as_slice())
        })
        .await;
        tokio::time::sleep(Duration::from_millis(600)).await;
        {
            let s = fake.state.lock().unwrap();
            for p in ["shot.png", "data", "data/table.tex", ".latexmkrc", ".gitignore", ".taudotignore"] {
                assert!(s.tree.find(p).is_none(), "{p} should stay local");
            }
        }
        // A remote file the rules match is still written locally.
        fake.remote_new_file("", "remote.png", b"\x89PNG r");
        let f2 = folder.clone();
        until("remote.png written", || std::fs::read(f2.join("remote.png")).is_ok_and(|b| b == b"\x89PNG r")).await;
        // Changing the rules lets data/ in: its files are uploaded without being touched.
        std::fs::write(folder.join(".gitignore"), "*.png\n").unwrap();
        let s = fake.state.clone();
        until("data/ let in", || s.lock().unwrap().doc_text("data/table.tex").as_deref() == Some("x\n")).await;
        assert!(fake.state.lock().unwrap().tree.find("shot.png").is_none());
        let _ = std::fs::remove_dir_all(&home);
    }

#[tokio::test]
    async fn tree_changed_while_offline_is_mirrored_on_reconnect() {
        // E1: docs added, renamed and deleted while the engine is away (no tree events) reach the folder and the
        // clients from the reconnect's joinProject tree; a deleted open doc doesn't make every reconnect fail.
        let fake = FakeServer::start("hello\n", Mode::Confirm).await;
        let (mut rpc, home) = start_engine(&fake, "offlinetree").await;
        let folder = home.join("proj");
        rpc.call("project.open", json!({"project_id": PROJECT_ID, "folder": folder})).await.unwrap();
        rpc.call("activity.subscribe", json!({"project_id": PROJECT_ID})).await.unwrap();
        let folder = folder.canonicalize().unwrap();
        fake.remote_new_doc("", "gone.tex", "Gone.\n");
        let f2 = folder.clone();
        until("gone.tex written", || f2.join("gone.tex").exists()).await;
        let d = rpc.call("doc.open", json!({"project_id": PROJECT_ID, "path": "gone.tex"})).await.unwrap();
        rpc.call("doc.subscribe", json!({"doc_id": d["doc_id"], "since_seq": d["seq"]})).await.unwrap();

        fake.set_offline(true);
        let mut st = Value::Null;
        for _ in 0..50 {
            st = rpc.call("project.status", json!({"project_id": PROJECT_ID})).await.unwrap();
            if st["connection"] != "online" {
                break;
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        assert_ne!(st["connection"], "online");
        fake.remote_delete("gone.tex");
        fake.remote_new_doc("", "new.tex", "New.\n");
        fake.remote_new_folder("", "parts");
        fake.remote_new_doc("parts", "deep.tex", "Deep.\n");
        fake.remote_rename("main.tex", "paper.tex");
        fake.remote_move("sections/fig.png", "parts");
        fake.set_offline(false);

        let f2 = folder.clone();
        until("offline tree changes mirrored", || {
            !f2.join("gone.tex").exists()
                && std::fs::read_to_string(f2.join("new.tex")).is_ok_and(|t| t == "New.\n")
                && std::fs::read_to_string(f2.join("parts/deep.tex")).is_ok_and(|t| t == "Deep.\n")
                && f2.join("paper.tex").exists()
                && !f2.join("main.tex").exists()
                && f2.join("parts/fig.png").exists()
                && !f2.join("sections/fig.png").exists()
        })
        .await;
        let st = rpc.call("project.status", json!({"project_id": PROJECT_ID})).await.unwrap();
        assert_eq!(st["connection"], "online", "{st}");
        let p = rpc.call("project.open", json!({"project_id": PROJECT_ID})).await.unwrap();
        let mut paths: Vec<&str> = p["docs"].as_array().unwrap().iter().map(|d| d["path"].as_str().unwrap()).collect();
        paths.sort();
        assert_eq!(paths, ["new.tex", "paper.tex", "parts/deep.tex"]);
        rpc.wait_note(|v| v["method"] == "project.tree" && v["params"]["change"]["op"] == "removed" && v["params"]["change"]["path"] == "gone.tex").await;
        // Nothing local was pushed back: no upload, no delete, no doc re-created.
        let rest = fake.state.lock().unwrap().rest.clone();
        assert!(!rest.iter().any(|r| r.starts_with("POST") || r.starts_with("DELETE")), "{rest:?}");
        let _ = std::fs::remove_dir_all(&home);
    }

    #[tokio::test]
    async fn folder_and_tree_sync_both_ways() {
        let fake = FakeServer::start("hello\n", Mode::Confirm).await;
        let (mut rpc, home) = start_engine(&fake, "tree").await;
        let folder = home.join("proj");
        let p = rpc.call("project.open", json!({"project_id": PROJECT_ID, "folder": folder})).await.unwrap();
        rpc.call("activity.subscribe", json!({"project_id": PROJECT_ID})).await.unwrap();
        assert_eq!(p["files"], json!([{"file_id": "x", "path": "sections/fig.png"}]));
        let folder = folder.canonicalize().unwrap();
        assert_eq!(std::fs::read(folder.join("sections/fig.png")).unwrap(), overleaf::fake::FIG);
        assert_eq!(std::fs::read_to_string(folder.join("main.tex")).unwrap(), "hello\n");

        // Remote: a new binary file, a new doc, a rename, a move, a delete.
        fake.remote_new_file("sections", "plot.png", b"\x89PNG plot");
        let n = rpc.wait_note(|v| v["method"] == "project.tree" && v["params"]["change"]["path"] == "sections/plot.png").await;
        assert_eq!(n["params"]["change"]["op"], "added");
        let f2 = folder.clone();
        until("plot.png downloaded", || std::fs::read(f2.join("sections/plot.png")).is_ok_and(|b| b == b"\x89PNG plot")).await;
        fake.remote_new_doc("sections", "intro.tex", "Intro.\n");
        let f2 = folder.clone();
        until("intro.tex written", || std::fs::read_to_string(f2.join("sections/intro.tex")).is_ok_and(|t| t == "Intro.\n")).await;
        let n = rpc.wait_note(|v| v["method"] == "project.tree" && v["params"]["change"]["path"] == "sections/intro.tex").await;
        assert!(n["params"]["docs"].as_array().unwrap().iter().any(|d| d["path"] == "sections/intro.tex"));
        // The new doc can be opened and edited through the API.
        let d = rpc.call("doc.open", json!({"project_id": PROJECT_ID, "path": "sections/intro.tex"})).await.unwrap();
        let intro = d["doc_id"].as_str().unwrap().to_string();
        rpc.call("doc.subscribe", json!({"doc_id": intro, "since_seq": d["seq"]})).await.unwrap();
        rpc.call("doc.edit", json!({"doc_id": intro, "seq": d["seq"], "edits": [{"pos": 0, "del": 0, "ins": "The "}]})).await.unwrap();
        let s = fake.state.clone();
        until("edit to the new doc reached the server", || s.lock().unwrap().doc_text("sections/intro.tex").as_deref() == Some("The Intro.\n")).await;
        fake.remote_rename("sections/intro.tex", "start.tex");
        let f2 = folder.clone();
        until("rename on disk", || f2.join("sections/start.tex").exists() && !f2.join("sections/intro.tex").exists()).await;
        let d = rpc.call("doc.open", json!({"project_id": PROJECT_ID, "path": "sections/start.tex"})).await.unwrap();
        assert_eq!(d["doc_id"], intro.as_str());
        fake.remote_move("sections/start.tex", "");
        let f2 = folder.clone();
        until("move on disk", || f2.join("start.tex").exists()).await;
        fake.remote_delete("sections/plot.png");
        let f2 = folder.clone();
        until("delete on disk", || !f2.join("sections/plot.png").exists()).await;
        assert!(home.join("backup/deleted").join(PROJECT_ID).exists(), "deleted file kept in the backup");

        // Local: another program edits main.tex while a collaborator types; both land.
        let main = folder.join("main.tex");
        std::fs::write(&main, "hello\nworld\n").unwrap();
        fake.remote_insert(0, ">");
        let s = fake.state.clone();
        until("disk edit reached the server", || s.lock().unwrap().text == ">hello\nworld\n").await;
        let m2 = main.clone();
        until("merged text written back", || std::fs::read_to_string(&m2).is_ok_and(|t| t == ">hello\nworld\n")).await;

        // Local: a new figure, a new .tex file, a rename, a delete.
        std::fs::create_dir_all(folder.join("figs")).unwrap();
        std::fs::write(folder.join("figs/new.png"), b"\x89PNG\0new").unwrap();
        std::fs::write(folder.join("notes.tex"), "Notes.\n").unwrap();
        std::fs::write(folder.join("main.aux"), "ignored").unwrap();
        let s = fake.state.clone();
        until("local files uploaded", || {
            let s = s.lock().unwrap();
            s.file("figs/new.png").as_deref() == Some(b"\x89PNG\0new".as_slice()) && s.doc_text("notes.tex").as_deref() == Some("Notes.\n")
        })
        .await;
        assert!(fake.state.lock().unwrap().tree.find("main.aux").is_none(), "build outputs stay local");
        std::fs::rename(folder.join("notes.tex"), folder.join("figs/notes2.tex")).unwrap();
        let s = fake.state.clone();
        until("local move + rename", || {
            let s = s.lock().unwrap();
            s.tree.find("notes.tex").is_none() && s.doc_text("figs/notes2.tex").as_deref() == Some("Notes.\n")
        })
        .await;
        std::fs::remove_file(folder.join("start.tex")).unwrap();
        let s = fake.state.clone();
        until("local delete", || s.lock().unwrap().tree.find("start.tex").is_none()).await;
        // A changed binary file is uploaded again.
        std::fs::write(folder.join("figs/new.png"), b"\x89PNG\0v2").unwrap();
        let s = fake.state.clone();
        until("changed figure uploaded", || s.lock().unwrap().file("figs/new.png").as_deref() == Some(b"\x89PNG\0v2".as_slice())).await;
        // Nothing was uploaded over a doc, and the engine's own writes caused no edits.
        let rest = fake.state.lock().unwrap().rest.clone();
        assert_eq!(rest.iter().filter(|r| r.contains("/upload")).count(), 3, "{rest:?}");
        let _ = std::fs::remove_dir_all(&home);
    }

    #[tokio::test]
    async fn changes_below_a_result_arrive_before_it() {
        let fake = FakeServer::start("0123456789", Mode::Confirm).await;
        let (mut a, home) = start_engine(&fake, "order").await;
        let doc = open_main(&mut a, None).await;
        let s = UnixStream::connect(home.join("engine.sock")).await.unwrap();
        let (r, w) = s.into_split();
        let mut b = Rpc { w, lines: BufReader::new(r).lines(), next: 0, notes: vec![] };
        b.call("doc.subscribe", json!({"doc_id": doc, "since_seq": 0})).await.unwrap();
        let mut own = vec![];
        for round in 0..20u64 {
            // A types three edits from a stale snapshot while remote changes arrive; B always edits at seq 0's view
            // of position 0, so its edits are transformed too.
            for k in 0..3 {
                a.call("doc.edit", json!({"doc_id": doc, "seq": round * 5 + k, "edits": [{"pos": 0, "del": 0, "ins": "a"}]})).await.unwrap();
            }
            fake.remote_insert(0, "r");
            let before = b.notes.iter().filter(|v| v["method"] == "doc.changed").count();
            let res = b.call("doc.edit", json!({"doc_id": doc, "seq": round * 5, "edits": [{"pos": 0, "del": 0, "ins": "b"}]})).await;
            let seq = res.unwrap()["seq"].as_u64().unwrap();
            let seen: Vec<u64> = b.notes.iter().filter(|v| v["method"] == "doc.changed").filter_map(|v| v["params"]["seq"].as_u64()).collect();
            assert!(seen.len() > before);
            for want in (1..seq).filter(|s| !own.contains(s)) {
                assert!(seen.contains(&want), "round {round}: seq {want} missing before result {seq}: {seen:?}");
            }
            assert!(!seen.contains(&seq), "B got its own edit back");
            own.push(seq);
            // Five changes a round: A's three, the remote one, B's.
            for _ in 0..50 {
                let st = a.call("project.status", json!({"project_id": PROJECT_ID})).await.unwrap();
                if st["docs"][0]["seq"] == round * 5 + 5 {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        }
        converged(&mut a, &fake, &doc).await;
        let _ = std::fs::remove_dir_all(&home);
    }

    /// An engine with no credentials of its own (as the launchd service runs), keeping sessions in a file.
    async fn start_bare_engine(home: PathBuf) -> Rpc {
        std::fs::create_dir_all(&home).unwrap();
        let login = Login {
            url: "http://127.0.0.1:9".into(),
            env_file: None,
            user: "user1".into(),
            email: None,
            password: None,
            cookie: None,
            sessions: Some(home.join("sessions.json")),
        };
        let h = home.clone();
        tokio::spawn(async move { run(Args { login, home: Some(h) }).await.unwrap() });
        for _ in 0..100 {
            if let Ok(s) = UnixStream::connect(home.join("engine.sock")).await {
                let (r, w) = s.into_split();
                return Rpc { w, lines: BufReader::new(r).lines(), next: 0, notes: vec![] };
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        panic!("engine did not start");
    }

    #[tokio::test]
    async fn account_projects_and_clone() {
        let fake = FakeServer::start("hello\n", Mode::Confirm).await;
        let home = test_home("account");
        let mut rpc = start_bare_engine(home.clone()).await;
        let url = fake.base.clone();

        let st = rpc.call("account.status", json!({"url": url})).await.unwrap();
        assert_eq!(st["logged_in"], false);
        let e = rpc.call("projects.list", json!({"url": url})).await.unwrap_err();
        assert!(e["message"].as_str().unwrap().contains("not logged in"), "{e}");
        let e = rpc.call("account.login", json!({"url": url, "browser": "netscape"})).await.unwrap_err();
        assert!(e["message"].as_str().unwrap().contains("unknown browser"), "{e}");

        let me = rpc.call("account.login", json!({"url": url, "from": "cookie", "cookie": "s%3Afake"})).await.unwrap();
        assert_eq!(me["logged_in"], true);
        assert_eq!((me["user_id"].as_str(), me["email"].as_str(), me["name"].as_str(), me["source"].as_str()),
            (Some("u1"), Some("alice@x"), Some("Alice Example"), Some("cookie")));
        let stored: Value = serde_json::from_str(&std::fs::read_to_string(home.join("sessions.json")).unwrap()).unwrap();
        assert_eq!(stored[&url], "overleaf.sid=s%3Afake");
        let st = rpc.call("account.status", json!({"url": format!("{url}/project")})).await.unwrap();
        assert_eq!((st["logged_in"].as_bool(), st["source"].as_str()), (Some(true), Some("cookie")));

        let list = rpc.call("projects.list", json!({"url": url})).await.unwrap();
        assert_eq!(list["from"], "api/project");
        let ps = list["projects"].as_array().unwrap();
        assert_eq!(ps.len(), 2);
        assert_eq!(ps[0]["id"], PROJECT_ID);
        assert_eq!(ps[0]["owner"], json!({"id": "u1", "name": "Alice Example", "email": "alice@x"}));
        assert_eq!(ps[0]["last_updated_by"]["name"], "Bob Other");
        assert_eq!(ps[0]["last_updated"], "2026-11-01T10:00:00.000Z");
        assert_eq!((ps[1]["access_level"].as_str(), ps[1]["archived"].as_bool()), (Some("readWrite"), Some(true)));
        assert!(ps.iter().all(|p| p.get("local_folder").is_none()));
        assert!(fake.state.lock().unwrap().rest.contains(&"POST /api/project".to_string()));

        // Clone: progress notes, then the folder holds the project and the list marks it.
        let folder = home.join("Overleaf").join("Fake-paper");
        let r = rpc.call("project.clone", json!({"url": url, "project_id": PROJECT_ID, "folder": folder})).await.unwrap();
        let folder = folder.canonicalize().unwrap();
        assert_eq!(r["folder"], json!(folder));
        assert_eq!(std::fs::read_to_string(folder.join("main.tex")).unwrap(), "hello\n");
        let stages: Vec<String> = rpc.notes.iter().filter(|n| n["method"] == "clone.progress").map(|n| n["params"]["stage"].as_str().unwrap().to_string()).collect();
        assert_eq!(stages, ["connecting", "downloading", "done"]);
        let e = rpc.call("project.clone", json!({"url": url, "project_id": "0123456789abcdef0123ffff", "folder": folder})).await.unwrap_err();
        assert!(e["message"].as_str().unwrap().contains("another project"), "{e}");
        let list = rpc.call("projects.list", json!({"url": url})).await.unwrap();
        assert_eq!(list["projects"][0]["local_folder"], json!(folder));
        assert!(list["projects"][0]["last_opened"].as_u64().is_some());
        assert!(list["projects"][1].get("local_folder").is_none());

        // Forget: syncing stops (the project is no longer open) and the mark goes; the files stay.
        rpc.call("project.forget", json!({"url": url, "project_id": PROJECT_ID, "folder": folder})).await.unwrap();
        assert!(rpc.call("project.status", json!({"project_id": PROJECT_ID})).await.is_err());
        let list = rpc.call("projects.list", json!({"url": url})).await.unwrap();
        assert!(list["projects"][0].get("local_folder").is_none());
        assert!(folder.join("main.tex").exists());
        // Scanning the clone root finds it again from its .taudot.json.
        let list = rpc.call("projects.list", json!({"url": url, "scan": [home.join("Overleaf")]})).await.unwrap();
        assert_eq!(list["projects"][0]["local_folder"], json!(folder));

        // A new project shows up in the list.
        let made = rpc.call("project.create", json!({"url": url, "name": "  Fresh paper "})).await.unwrap();
        assert_eq!(made["name"], "Fresh paper");
        let list = rpc.call("projects.list", json!({"url": url})).await.unwrap();
        assert_eq!(list["projects"][0]["id"], made["project_id"]);
        assert_eq!(list["projects"][0]["name"], "Fresh paper");
        assert!(rpc.call("project.create", json!({"url": url, "name": " "})).await.is_err());
        assert!(rpc.call("project.create", json!({"url": url, "name": "x", "template": "thesis"})).await.is_err());

        // An expired session reads as logged out, saying so.
        fake.state.lock().unwrap().logged_out = true;
        let st = rpc.call("account.status", json!({"url": url})).await.unwrap();
        assert_eq!((st["logged_in"].as_bool(), st["expired"].as_bool()), (Some(false), Some(true)));
        assert!(rpc.call("account.login", json!({"url": url, "cookie": "s%3Aold"})).await.is_err());
        fake.state.lock().unwrap().logged_out = false;

        rpc.call("account.logout", json!({"url": url})).await.unwrap();
        assert_eq!(rpc.call("account.status", json!({"url": url})).await.unwrap()["logged_in"], false);
        let stored: Value = serde_json::from_str(&std::fs::read_to_string(home.join("sessions.json")).unwrap()).unwrap();
        assert!(stored.get(&url).is_none());
        let _ = std::fs::remove_dir_all(&home);
    }

    #[tokio::test]
    async fn account_status_with_the_engines_own_login() {
        let fake = FakeServer::start("x\n", Mode::Confirm).await;
        let (mut rpc, home) = start_engine(&fake, "own-login").await;
        let st = rpc.call("account.status", json!({"url": fake.base})).await.unwrap();
        assert_eq!((st["logged_in"].as_bool(), st["source"].as_str(), st["name"].as_str()), (Some(true), Some("engine"), Some("Alice Example")));
        let list = rpc.call("projects.list", json!({"url": fake.base})).await.unwrap();
        assert_eq!(list["projects"].as_array().unwrap().len(), 2);
        let _ = std::fs::remove_dir_all(&home);
    }
}
