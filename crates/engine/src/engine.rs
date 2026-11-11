//! Engine state: one actor task per open project, owning its connection and docs.
//!
//! Each doc is an [`ot::client::Client`]: one update in flight, later edits composed into one pending op, remote ops
//! transformed past both, catch-up with `joinDoc(fromVersion)` after a reconnect and a rebase onto fresh text when the
//! server no longer has the ops we missed. A client's `doc.edit` written against an older `seq` is transformed past
//! the changes it hadn't seen. The doc goes read-only only if a rebase itself fails; edits are kept either way
//! (principle 5).
//!
//! Besides the socket, the actor keeps two things on disk: the folder mirror (each doc's text at `<folder>/<path>`,
//! written atomically about 200 ms after it changes) and a backup of unconfirmed edits under
//! `<home>/backup/<project_id>/<doc_id>.json`, replayed when the doc is next opened.

#[path = "folder.rs"]
mod folder;

use crate::Login;
use anyhow::{anyhow, bail, Context};
use ot::client::{Client, Event, Incoming};
use ot::edit::{self, Edit};
use ot::text::{self, Op, Side};
use overleaf::{Kind, OtType, OutgoingUpdate, ProjectConn, ServerEvent, Style, Tree, TreeChange, Update};
use serde_json::{json, Value};
use std::collections::{BTreeSet, HashMap, VecDeque};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};
use tokio::sync::{broadcast, mpsc, oneshot};

/// The browser resends after 5 s without a confirmation (`INFLIGHT_OP_TIMEOUT` in `share-js-doc.ts`). It also forces
/// a queued out-of-order update after that long; we rejoin instead.
const RESEND_AFTER: Duration = Duration::from_secs(5);
/// A connection that drops sooner than this after joining counts as a quick drop: the next reconnect waits, doubling
/// from [`QUICK_DROP_DELAY`] up to [`MAX_RECONNECT_DELAY`], so a server that keeps closing on us (a refused op, a
/// project that fails to join) isn't hammered with joinProject and joinDoc calls.
/// A reconnect's joinProject (handshake, websocket, join) gives up after this.
#[cfg(not(test))]
const CONNECT_TIMEOUT: Duration = Duration::from_secs(30);
#[cfg(test)]
const CONNECT_TIMEOUT: Duration = Duration::from_secs(2);
const STABLE_AFTER: Duration = Duration::from_secs(10);
const QUICK_DROP_DELAY: Duration = Duration::from_millis(500);
const MAX_RECONNECT_DELAY: Duration = Duration::from_secs(30);
/// After this many refusals of the same op (`otUpdateError`, or an error acknowledging `applyOtUpdate`) the doc stops
/// sending: read-only, its edits kept. The browser gives up at the first (it shows the out-of-sync error).
const MAX_REFUSALS: u32 = 3;
/// Edits are batched like the browser's (`SINGLE_USER_FLUSH_DELAY` / `MULTI_USER_FLUSH_DELAY` in `share-js-doc.ts`):
/// an edit waits up to 2 s before it is sent, 0.5 s once someone else has edited the doc, so the project's update
/// stream looks like a person typing in Overleaf. `TAUDOT_FLUSH_MS` overrides both.
const SINGLE_USER_FLUSH_DELAY: Duration = Duration::from_millis(2000);
const MULTI_USER_FLUSH_DELAY: Duration = Duration::from_millis(500);

#[cfg(test)]
thread_local! {
    /// (single-user, multi-user) flush delays for the engine run on this test's thread.
    pub static TEST_FLUSH_DELAYS: std::cell::Cell<Option<(Duration, Duration)>> = const { std::cell::Cell::new(None) };
}

#[cfg(not(test))]
fn flush_delay(multi_user: bool) -> Duration {
    static OVERRIDE: std::sync::OnceLock<Option<u64>> = std::sync::OnceLock::new();
    match OVERRIDE.get_or_init(|| std::env::var("TAUDOT_FLUSH_MS").ok().and_then(|v| v.parse().ok())) {
        Some(ms) => Duration::from_millis(*ms),
        None if multi_user => MULTI_USER_FLUSH_DELAY,
        None => SINGLE_USER_FLUSH_DELAY,
    }
}

/// Tests send at once unless they set delays for their (single-threaded) runtime.
#[cfg(test)]
fn flush_delay(multi_user: bool) -> Duration {
    let (single, multi) = TEST_FLUSH_DELAYS.with(|c| c.get()).unwrap_or_default();
    if multi_user { multi } else { single }
}

/// Mirror writes wait this long after the last change, but never more than [`MIRROR_MAX_DELAY`] after the first.
const MIRROR_QUIET: Duration = Duration::from_millis(200);
const MIRROR_MAX_DELAY: Duration = Duration::from_secs(1);
const BACKUP_EVERY: Duration = Duration::from_secs(2);
// Review features (cursors, comments, tracked changes) extend the actor from a child module.
#[path = "review.rs"]
pub mod review;
// Completion (`complete.items`) from an index of the open docs.
#[path = "complete.rs"]
pub mod complete;
// Editing history-ot docs: the server's copy beside the client, versions counted.
#[path = "hist.rs"]
pub mod hist;

const LOG_KEEP: usize = 10_000;
const EDIT_IDS_KEEP: usize = 1_000;
const KEEPALIVE_EVERY: Duration = Duration::from_secs(3600);

/// A notification for clients: JSON-RPC method and params.
#[derive(Debug, Clone)]
pub struct Note {
    pub method: &'static str,
    pub params: Value,
    pub doc_id: Option<String>,
    pub project_id: String,
    /// The API connection whose request caused it. That connection doesn't get it (it has the result instead).
    pub from_client: Option<u64>,
}

/// One applied change, kept so clients can catch up with `since_seq` and stale edits can be transformed.
#[derive(Debug, Clone)]
pub struct Change {
    pub seq: u64,
    pub edits: Vec<Edit>,
    /// The same change as a classic op on the text before it.
    pub op: Op,
    pub origin: &'static str,
    /// `{user_id, name, initials}`, as in `doc.changed`.
    pub author: Value,
    /// Where a local change came from when it wasn't a client: `"disk"` (the folder's file was edited), else none.
    pub source: Option<&'static str>,
}

pub struct Doc {
    pub path: String,
    pub ot_type: OtType,
    pub client: Client,
    pub seq: u64,
    pub log: VecDeque<Change>,
    pub readonly: Option<String>,
    /// When the inflight op was last sent, and whether it must be resent at once (after a reconnect).
    sent_at: Option<Instant>,
    must_resend: bool,
    /// Times Overleaf refused the op in flight (reset when one is confirmed).
    refused: u32,
    /// A big shrink of the file on disk, waiting to be seen again unchanged (`folder.rs`, `disk_changed`).
    pub(super) shrink_seen: Option<(String, Instant)>,
    /// When the pending op got its first edit (it is sent [`flush_delay`] after), and whether a collaborator has
    /// edited this doc since we joined it.
    pending_since: Option<Instant>,
    multi_user: bool,
    /// Since when the client has had out-of-order updates waiting.
    queued_since: Option<Instant>,
    /// Set when our copy no longer matches an update; the next tick does a full rejoin and rebase.
    needs_rejoin: Option<String>,
    /// `meta.user_id` of updates handed to the client, by server version, until the client processes them.
    authors: HashMap<u64, Option<String>>,
    /// `edit_id` of recent `doc.edit`s and the seq each produced.
    edit_ids: VecDeque<(String, u64)>,
    mirror_first: Option<Instant>,
    mirror_last: Instant,
    backup_due: bool,
    pub review: review::DocReview,
    /// The text last known to be in the doc's file, and the seq it was the doc's text at. A file that changes on
    /// disk is diffed against it.
    disk: Option<(u64, String)>,
    /// For a history-ot doc, the server's own copy and what is in flight (`hist.rs`).
    pub hist: Option<hist::Hist>,
}

impl Doc {
    fn new(path: &str, ot_type: OtType, client: Client) -> Doc {
        Doc {
            path: path.to_string(),
            ot_type,
            client,
            seq: 0,
            log: VecDeque::new(),
            readonly: None,
            sent_at: None,
            pending_since: None,
            multi_user: false,
            must_resend: false,
            refused: 0,
            shrink_seen: None,
            queued_since: None,
            needs_rejoin: None,
            authors: HashMap::new(),
            edit_ids: VecDeque::new(),
            mirror_first: None,
            mirror_last: Instant::now(),
            backup_due: false,
            review: review::DocReview::new(),
            disk: None,
            hist: None,
        }
    }

    fn state(&self) -> &'static str {
        if self.client.inflight().is_some() {
            "inflight"
        } else if self.client.pending().is_some() {
            "pending"
        } else {
            "idle"
        }
    }

    fn unconfirmed(&self) -> usize {
        self.client.inflight().map_or(0, Vec::len) + self.client.pending().map_or(0, Vec::len)
    }

    /// The doc's text as it was at `seq`, by undoing later changes.
    fn text_at(&self, seq: u64) -> anyhow::Result<String> {
        if seq > self.seq {
            bail!("seq {seq} is ahead of the doc ({})", self.seq);
        }
        let first = self.log.front().map_or(self.seq + 1, |c| c.seq);
        if seq + 1 < first {
            bail!("seq {seq} is older than the engine's log (starts at {first}); reopen the doc");
        }
        let mut t = self.client.text().to_owned();
        for c in self.log.iter().rev().take_while(|c| c.seq > seq) {
            t = text::apply(&t, &text::invert(&c.op))?;
        }
        Ok(t)
    }

    /// Changes after `seq`, oldest first.
    fn since(&self, seq: u64) -> impl Iterator<Item = &Change> {
        self.log.iter().filter(move |c| c.seq > seq)
    }
}

type Reply<T> = oneshot::Sender<anyhow::Result<T>>;

pub enum Cmd {
    Status(Reply<Value>),
    OpenDoc { path: String, reply: Reply<Value> },
    Edit { doc_id: String, seq: u64, edits: Vec<Edit>, edit_id: Option<String>, from_client: Option<u64>, reply: Reply<(u64, Vec<Change>)> },
    Since { doc_id: String, since: u64, reply: Reply<(u64, Vec<Change>)> },
    Cursor { doc_id: String, pos: usize, seq: Option<u64>, reply: Reply<()> },
    /// `complete.items` params.
    Complete { params: Value, reply: Reply<Value> },
    /// A method of `review::METHODS`.
    Review { method: String, params: Value, reply: Reply<Value> },
    /// Mirror the project into this folder from now on, both ways. With `adopt`, local files not on Overleaf are
    /// uploaded at once; otherwise only once they change.
    Mirror { folder: PathBuf, adopt: bool, reply: Reply<()> },
    /// `{docs: [{doc_id, path}], files: [{file_id, path}]}` as the tree is now.
    Tree(Reply<Value>),
    /// A copy of the project's HTTP session, for REST calls made outside the actor (`history.*`).
    Http(Reply<overleaf::Http>),
    /// Write backups and mirror files now, then stop.
    Shutdown(Reply<()>),
}

#[derive(Clone)]
pub struct ProjectHandle {
    pub tx: mpsc::UnboundedSender<Cmd>,
    /// `{user_id, name, initials}` of the logged-in user.
    pub me: Value,
    /// The project's name on Overleaf.
    pub name: String,
    /// The project's compiler setting (`pdflatex`, `xelatex`, `lualatex`, `latex`), as at open.
    pub compiler: String,
    /// The project's TeX Live image (`texlive-full:2026.1` and so on), as at open. Empty when the server doesn't say.
    pub image: String,
}

impl ProjectHandle {
    /// False once the actor has stopped (it returned, or panicked): the handle is then useless.
    pub fn alive(&self) -> bool {
        !self.tx.is_closed()
    }

    pub async fn ask<T>(&self, f: impl FnOnce(Reply<T>) -> Cmd) -> anyhow::Result<T> {
        let (tx, rx) = oneshot::channel();
        self.tx.send(f(tx)).map_err(|_| anyhow!("project actor stopped"))?;
        rx.await.map_err(|_| anyhow!("project actor stopped"))?
    }
}

/// A user as the API shows it.
fn user_json(id: &str, first: &str, last: &str, email: &str) -> Value {
    let name = format!("{first} {last}").trim().to_string();
    let name = if name.is_empty() { email.split('@').next().unwrap_or(email).to_string() } else { name };
    let initials: String = name.split_whitespace().filter_map(|w| w.chars().next()).take(2).collect::<String>().to_uppercase();
    json!({"user_id": id, "name": name, "initials": initials})
}

/// Owner and members of a joined project, by user ID.
fn project_users(project: &Value) -> HashMap<String, Value> {
    let mut out = HashMap::new();
    let owner = project.get("owner").into_iter();
    let members = project.get("members").and_then(Value::as_array).into_iter().flatten();
    for u in owner.chain(members) {
        let s = |k: &str| u.get(k).and_then(Value::as_str).unwrap_or("").to_string();
        let id = s("_id");
        if !id.is_empty() {
            out.insert(id.clone(), user_json(&id, &s("first_name"), &s("last_name"), &s("email")));
        }
    }
    out
}

fn auth_rejected(e: &overleaf::Error) -> bool {
    match e {
        overleaf::Error::Rejected(m) => m.contains("invalid session") || m.contains("not authorized"),
        overleaf::Error::Handshake(m) => m.starts_with("401") || m.starts_with("403"),
        _ => false,
    }
}

/// Connect to a project and start its actor.
pub async fn open_project(
    login: &Login,
    project_id: &str,
    home: &Path,
    notes: broadcast::Sender<Note>,
) -> anyhow::Result<ProjectHandle> {
    let mut http = login.http().await?;
    if http.user_id.is_none() || http.csrf.is_none() {
        // Logged in with a cookie: the project page names the user and has the CSRF token for REST calls. A server
        // without one is fine until a tree change needs it.
        let _ = http.fetch_csrf("project").await;
    }
    let conn = match ProjectConn::connect(&http, project_id, Style::Auto).await {
        Err(e) if auth_rejected(&e) && login.can_relogin() => {
            http = login.http().await?;
            ProjectConn::connect(&http, project_id, Style::Auto).await?
        }
        Err(e) if auth_rejected(&e) => {
            let origin = http.base.origin().ascii_serialization();
            bail!("the Overleaf session for {origin} has expired ({e}); run `taudot login --url {origin}`")
        }
        r => r?,
    };
    let tree = Tree::from_project(&conn.project);
    let users = project_users(&conn.project);
    let me = match &http.user_id {
        Some(id) => users.get(id).cloned().unwrap_or_else(|| user_json(id, "", "", http.email.as_deref().unwrap_or(""))),
        None => json!({"user_id": null, "name": null, "initials": null}),
    };
    let name = conn.project.get("name").and_then(Value::as_str).unwrap_or("").to_string();
    // joinProject's project carries the compile settings (`compiler`, `imageName`, the latter a full image path on
    // overleaf.com, e.g. `quay.io/sharelatex/texlive-full:2026.1`): the last path segment is what the menu shows.
    let compiler = conn.project.get("compiler").and_then(Value::as_str).unwrap_or("pdflatex").to_string();
    let image = conn.project.get("imageName").and_then(Value::as_str).unwrap_or("").rsplit('/').next().unwrap_or("").to_string();
    let (tx, rx) = mpsc::unbounded_channel();
    let actor = Actor {
        project_id: project_id.to_string(),
        login: login.clone(),
        http,
        conn: Some(conn),
        docs: HashMap::new(),
        tree,
        users,
        me: me.clone(),
        notes,
        connection: "online",
        folder: None,
        home: home.to_path_buf(),
        last_backup: Instant::now(),
        send_errors: mpsc::unbounded_channel(),
        review: Default::default(),
        complete: Default::default(),
        watch: None,
        rules: Default::default(),
        dirty: BTreeSet::new(),
        dirty_at: Instant::now(),
        tree_work: VecDeque::new(),
        last_keepalive: Instant::now(),
        online_since: Some(Instant::now()),
        quick_drops: 0,
        edit_source: None,
        reconnect_at: None,
    };
    tokio::spawn(actor.run(rx));
    Ok(ProjectHandle { tx, me, name, compiler, image })
}

struct Actor {
    project_id: String,
    login: Login,
    http: overleaf::Http,
    conn: Option<ProjectConn>,
    docs: HashMap<String, Doc>,
    /// The project's docs, files and folders, kept current from tree events.
    tree: Tree,
    users: HashMap<String, Value>,
    me: Value,
    notes: broadcast::Sender<Note>,
    connection: &'static str,
    folder: Option<PathBuf>,
    home: PathBuf,
    last_backup: Instant,
    /// Failed `applyOtUpdate` calls, as (connection public ID, doc ID, error), from the tasks that await them.
    send_errors: (mpsc::UnboundedSender<(String, String, String)>, mpsc::UnboundedReceiver<(String, String, String)>),
    review: review::ProjectReview,
    complete: complete::Index,
    /// The folder watcher, paths it reported that wait to be synced, and when the last one came.
    watch: Option<folder::Watch>,
    /// The folder's ignore rules (`folder::Rules`).
    rules: folder::Rules,
    dirty: BTreeSet<String>,
    dirty_at: Instant,
    /// Remote tree changes whose disk work is still to do.
    tree_work: VecDeque<TreeChange>,
    /// Last web request that kept the session alive (`docs/protocol.md`, Session expiry).
    last_keepalive: Instant,
    /// When the connection joined; consecutive quick drops; the earliest time to reconnect (see [`STABLE_AFTER`]).
    online_since: Option<Instant>,
    quick_drops: u32,
    reconnect_at: Option<Instant>,
    /// Set while a change from the folder is recorded (`Change::source`).
    edit_source: Option<&'static str>,
}

impl Actor {
    fn note(&self, method: &'static str, doc_id: Option<&str>, params: Value) {
        self.note_from(method, doc_id, params, None);
    }

    fn note_from(&self, method: &'static str, doc_id: Option<&str>, params: Value, from_client: Option<u64>) {
        let _ = self.notes.send(Note {
            method,
            params,
            doc_id: doc_id.map(String::from),
            project_id: self.project_id.clone(),
            from_client,
        });
    }

    fn activity(&self, doc_id: Option<&str>, kind: &str, text: String) {
        tracing::info!(doc = doc_id, kind, "{text}");
        let ts = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_millis() as u64);
        self.note("activity", doc_id, json!({"project_id": self.project_id, "kind": kind, "text": text, "doc_id": doc_id, "ts": ts}));
    }

    fn set_connection(&mut self, c: &'static str, reason: Option<String>) {
        if self.connection != c {
            self.connection = c;
            self.note("project.connection", None, json!({"project_id": self.project_id, "connection": c, "reason": reason}));
        }
    }

    fn doc_state_note(&self, doc_id: &str) {
        if let Some(d) = self.docs.get(doc_id) {
            let oldest = d.sent_at.filter(|_| d.client.inflight().is_some()).map(|t| t.elapsed().as_millis() as u64);
            self.note(
                "doc.state",
                Some(doc_id),
                json!({"doc_id": doc_id, "state": d.state(), "unconfirmed": d.unconfirmed(),
                       "oldest_unconfirmed_ms": oldest, "readonly": d.readonly, "seq": d.seq}),
            );
        }
    }

    async fn run(mut self, mut rx: mpsc::UnboundedReceiver<Cmd>) {
        self.review_connected().await;
        let mut tick = tokio::time::interval(Duration::from_millis(50));
        let mut backoff = Duration::from_secs(1);
        loop {
            if self.conn.is_none() {
                if let Some(at) = self.reconnect_at.take() {
                    if self.idle_until(at, &mut rx, &mut tick).await {
                        return;
                    }
                }
                self.set_connection("connecting", None);
                // Everything unconfirmed is on disk before waiting on the network.
                self.disk_tick(true);
                let Some(first) = self.connect_serving(&mut rx, &mut tick).await else { return };
                let r = match self.connect_after(first).await {
                    Ok(conn) => self.reconnect(conn).await,
                    Err(e) => Err(e),
                };
                match r {
                    Ok(()) => {
                        backoff = Duration::from_secs(1);
                        self.online_since = Some(Instant::now());
                    }
                    Err(e) => {
                        tracing::warn!("reconnect failed: {e:#}");
                        self.conn = None;
                        self.set_connection("offline", Some(format!("{e:#}")));
                        self.reconnect_at = Some(Instant::now() + backoff);
                        backoff = (backoff * 2).min(MAX_RECONNECT_DELAY);
                        continue;
                    }
                }
            }
            let conn = self.conn.as_mut().unwrap();
            tokio::select! {
                cmd = rx.recv() => match cmd {
                    Some(c) => if self.handle(c).await { return },
                    None => { conn.disconnect(); return; }
                },
                ev = conn.next_event() => match ev {
                    None => self.lost("connection closed".into()),
                    Some(ev) => self.on_event(ev),
                },
                Some((public_id, doc, e)) = self.send_errors.1.recv() => {
                    // The update stays in flight and is resent with dupIfSource after reconnecting.
                    if self.conn.as_ref().is_some_and(|c| c.public_id == public_id) {
                        if !doc.is_empty() {
                            self.refused(&doc, &e);
                        }
                        self.lost(format!("applyOtUpdate: {e}"));
                    }
                }
                Some(p) = folder::next_path(&mut self.watch) => self.on_path(p),
                _ = tick.tick() => {
                    self.review_tick().await;
                    self.flush().await;
                    // Remote tree changes reach the disk before local changes are looked at, so a file a
                    // collaborator just renamed isn't taken for one deleted here; and before mirror writes, which
                    // already use the new paths.
                    self.apply_remote_tree().await;
                    self.disk_tick(false);
                    self.keepalive().await;
                    self.sync_local().await;
                }
            }
        }
    }

    /// Hourly, a cheap web request: it keeps a rolling session alive (CE logs out 5 days after the last one) and
    /// tells the user when the session has gone, rather than when the socket next reconnects.
    async fn keepalive(&mut self) {
        if self.last_keepalive.elapsed() < KEEPALIVE_EVERY {
            return;
        }
        self.last_keepalive = Instant::now();
        match self.http.session_alive().await {
            Ok(true) => {}
            Ok(false) if self.login.can_relogin() => match self.login.http().await {
                Ok(h) => {
                    self.http = h;
                    self.activity(None, "relogin", "session expired; logged in again".into());
                }
                Err(e) => self.activity(None, "login_expired", format!("session expired and logging in again failed: {e:#}")),
            },
            Ok(false) => {
                let origin = self.http.base.origin().ascii_serialization();
                self.activity(None, "login_expired", format!("the Overleaf session for {origin} has expired; run `taudot login --url {origin}`"));
            }
            Err(e) => tracing::warn!("keepalive: {e}"),
        }
    }


    fn lost(&mut self, reason: String) {
        self.lost_for(reason, Duration::ZERO);
    }

    /// The connection is gone; reconnect no sooner than `wait` (a `forceDisconnect`'s delay), and later still after
    /// quick drops ([`STABLE_AFTER`]).
    fn lost_for(&mut self, reason: String, wait: Duration) {
        tracing::warn!("lost connection: {reason}");
        let Some(c) = self.conn.take() else { return };
        c.disconnect();
        if self.online_since.take().is_some_and(|t| t.elapsed() >= STABLE_AFTER) {
            self.quick_drops = 0;
        } else {
            self.quick_drops += 1;
        }
        let delay = match self.quick_drops {
            0 => Duration::ZERO,
            n => (QUICK_DROP_DELAY * 2u32.saturating_pow(n.min(16) - 1)).min(MAX_RECONNECT_DELAY),
        };
        self.reconnect_at = Some(Instant::now() + delay.max(wait));
        self.set_connection("connecting", Some(reason));
        // Who was here is unknown until the reconnect asks again: their cursors would otherwise sit still (E17).
        self.review_disconnected();
    }

    /// Serves commands, the folder and the disk while waiting to reconnect. True when the actor should stop.
    async fn idle_until(&mut self, at: Instant, rx: &mut mpsc::UnboundedReceiver<Cmd>, tick: &mut tokio::time::Interval) -> bool {
        let wake = tokio::time::sleep_until(at.into());
        tokio::pin!(wake);
        loop {
            tokio::select! {
                _ = &mut wake => return false,
                _ = tick.tick() => self.disk_tick(false),
                Some(p) = folder::next_path(&mut self.watch) => self.on_path(p),
                cmd = rx.recv() => match cmd {
                    Some(c) => if self.handle(c).await { return true },
                    None => return true,
                }
            }
        }
    }

    /// Overleaf refused the op in flight on `doc_id`. After [`MAX_REFUSALS`] the doc stops sending it.
    fn refused(&mut self, doc_id: &str, why: &str) {
        let Some(d) = self.docs.get_mut(doc_id) else { return };
        if d.client.inflight().is_none() || d.readonly.is_some() {
            return;
        }
        d.refused += 1;
        if d.refused >= MAX_REFUSALS {
            let (n, path) = (d.refused, d.path.clone());
            d.readonly = Some(format!("Overleaf refused an edit {n} times ({why}); your edits are kept, not sent"));
            d.backup_due = true;
            self.activity(Some(doc_id), "error", format!("{path}: Overleaf keeps refusing an edit ({why}); stopped sending"));
            self.doc_state_note(doc_id);
        }
    }

    /// Connects (joinProject) in a task, still serving commands, the folder and the disk meanwhile: a half-open network
    /// can make the connect hang until its timeout, and the project must keep answering (and backing up) through
    /// that. `None` when the actor should stop.
    async fn connect_serving(
        &mut self,
        rx: &mut mpsc::UnboundedReceiver<Cmd>,
        tick: &mut tokio::time::Interval,
    ) -> Option<Result<ProjectConn, overleaf::Error>> {
        let (http, pid) = (self.http.clone(), self.project_id.clone());
        let mut task = tokio::spawn(async move {
            match tokio::time::timeout(CONNECT_TIMEOUT, ProjectConn::connect(&http, &pid, Style::Auto)).await {
                Ok(r) => r,
                Err(_) => Err(overleaf::Error::Timeout("joinProject".into())),
            }
        });
        loop {
            tokio::select! {
                r = &mut task => return Some(r.unwrap_or_else(|e| Err(overleaf::Error::Protocol(format!("connect task: {e}"))))),
                _ = tick.tick() => self.disk_tick(false),
                Some(p) = folder::next_path(&mut self.watch) => self.on_path(p),
                cmd = rx.recv() => {
                    let stop = match cmd {
                        Some(c) => self.handle(c).await,
                        None => true,
                    };
                    if stop {
                        task.abort();
                        return None;
                    }
                }
            }
        }
    }

    /// After the first connect attempt: log in again and retry if the session was rejected.
    async fn connect_after(&mut self, first: Result<ProjectConn, overleaf::Error>) -> anyhow::Result<ProjectConn> {
        match first {
            Ok(c) => Ok(c),
            Err(e) if auth_rejected(&e) && self.login.can_relogin() => {
                self.activity(None, "relogin", format!("session rejected ({e}); logging in again"));
                self.http = self.login.http().await.context("logging in again")?;
                Ok(ProjectConn::connect(&self.http, &self.project_id, Style::Auto).await?)
            }
            Err(e) if auth_rejected(&e) => {
                let origin = self.http.base.origin().ascii_serialization();
                let msg = format!("the Overleaf session for {origin} has expired ({e}); run `taudot login --url {origin}`");
                self.activity(None, "login_expired", msg.clone());
                bail!(msg)
            }
            Err(e) => Err(e.into()),
        }
    }

    /// Joins the docs again on a new connection.
    async fn reconnect(&mut self, conn: ProjectConn) -> anyhow::Result<()> {
        // The tree as it is now: what changed while we were away came as no events.
        let fresh = Tree::from_project(&conn.project);
        let changes = self.tree.changes_to(&fresh);
        if !fresh.root.is_empty() {
            self.tree = fresh;
            self.users = project_users(&conn.project);
        }
        for ch in changes {
            self.take_tree_change(ch);
        }
        let ids: Vec<String> = self.docs.keys().cloned().collect();
        for id in ids {
            let d = self.docs.get_mut(&id).unwrap();
            d.must_resend = d.client.inflight().is_some();
            if let Some(h) = d.hist.as_mut() {
                h.reconnected();
            }
            match conn.join_doc(&id, Some(d.client.version()), None).await {
                Ok(j) => {
                    self.catch_up_doc(&id, j.ops.clone());
                    self.review_joined(&id, &j);
                }
                Err(overleaf::Error::MissingOps) => {
                    let j = conn.join_doc(&id, None, None).await?;
                    let text = self.joined_text(&id, &j)?;
                    self.rebase(&id, &text, j.version, None);
                    self.review_joined(&id, &j);
                }
                Err(e) => return Err(e.into()),
            }
        }
        self.conn = Some(conn);
        self.set_connection("online", None);
        self.review_connected().await;
        Ok(())
    }

    /// The text a full join gave, for the client: lines for a classic doc; for a history-ot doc the visible text, after
    /// taking the server copy from the snapshot.
    fn joined_text(&mut self, id: &str, j: &overleaf::JoinedDoc) -> anyhow::Result<String> {
        if j.ot_type == OtType::HistoryOt {
            self.hist_joined(id, j)
        } else {
            Ok(j.text())
        }
    }

    fn rebase(&mut self, id: &str, server_text: &str, version: u64, inflight_applied: Option<bool>) {
        let Some(d) = self.docs.get_mut(id) else { return };
        let snap = d.client.clone();
        let before = d.client.text().to_owned();
        let had = d.unconfirmed();
        // A classic doc's inflight op that isn't in the text may still be queued on the server: it stays in flight and is
        // resent at once with dupIfSource, which the server drops if the first send lands after all. (history-ot docs
        // never resend on the same connection: hist.rs.)
        let applied = d.client.inflight().is_some() && inflight_applied.unwrap_or_else(|| d.client.inflight_seems_applied(server_text));
        let keep = d.hist.is_none() && d.client.inflight().is_some() && !applied;
        let (had_inflight, pending_was_empty) = (d.client.inflight().is_some(), d.client.pending().is_none());
        let r = if keep { d.client.rebase_keeping_inflight(server_text, version) } else { d.client.rebase(server_text, version, inflight_applied) };
        match r {
            Ok(op) => {
                d.needs_rejoin = None;
                // The review batch flags follow the inflight op: confirmed with it, or folded into pending with it.
                if had_inflight && d.client.inflight().is_none() {
                    if applied {
                        d.review.confirmed();
                    } else {
                        d.review.folded(pending_was_empty);
                    }
                }
                d.sent_at = None;
                d.must_resend = d.client.inflight().is_some();
                d.queued_since = None;
                d.authors.clear();
                d.backup_due = true;
                let edits = edit::from_classic(&before, &op).unwrap_or_default();
                if !op.is_empty() {
                    self.record(id, edits, op, "remote", None, None);
                }
                if had > 0 {
                    self.activity(Some(id), "rebase", format!("rejoined at v{version} and carried {had} unconfirmed edits over"));
                }
                self.doc_state_note(id);
            }
            Err(e) => {
                let d = self.docs.get_mut(id).unwrap();
                d.client = snap;
                d.readonly = Some(format!("could not rebase onto the server's text: {e}; edits kept"));
                self.doc_state_note(id);
            }
        }
    }

    /// Hands one update to the doc's OT client and reports what it did. On an error the client is put back as it was
    /// and the doc is marked for a rejoin.
    fn feed(&mut self, id: &str, u: Update, at_current: bool) {
        let Some(d) = self.docs.get_mut(id) else { return };
        if d.needs_rejoin.is_some() || d.readonly.is_some() {
            return;
        }
        if d.hist.is_some() {
            // history-ot: `v` can't be trusted; every update is the next version (hist.rs).
            let v = d.client.version();
            match self.hist_classify(id, &u) {
                Ok(hist::Incoming::Skip) => {}
                Ok(hist::Incoming::Confirm) => {
                    let source = u.source().map(String::from).filter(|_| u.op.is_some());
                    let op = source.as_ref().map(|_| Op::new());
                    self.deliver(id, &u, v, op, source);
                }
                Ok(hist::Incoming::Remote(op)) => self.deliver(id, &u, v, Some(op), u.source().map(String::from)),
                Err(e) => {
                    self.docs.get_mut(id).unwrap().needs_rejoin = Some(format!("history-ot update doesn't fit our copy: {e:#}"));
                }
            }
            self.review_hist_rebuild(id);
            return;
        }
        let v = if at_current { d.client.version() } else { u.v };
        let source = u.source().map(String::from);
        let op = match u.op.as_ref().map(parse_op) {
            None => None,
            Some(Ok(op)) => Some(op),
            Some(Err(e)) => {
                d.needs_rejoin = Some(format!("unreadable update v{v}: {e}"));
                return;
            }
        };
        self.deliver(id, &u, v, op, source);
    }

    /// Hands an update, as a classic op on our text, to the doc's OT client and reports what it did.
    fn deliver(&mut self, id: &str, u: &Update, v: u64, op: Option<Op>, source: Option<String>) {
        let d = self.docs.get_mut(id).unwrap();
        if op.is_some() {
            d.authors.insert(v, u.user_id().map(String::from));
            d.review.note_remote(v, u);
        }
        let snap = d.client.clone();
        let v0 = d.client.version();
        let mut cur = d.client.text().to_owned();
        let events = match d.client.receive(Incoming { v, op, source }) {
            Ok(ev) => ev,
            Err(e) => {
                d.client = snap;
                d.needs_rejoin = Some(format!("update v{v} does not fit our copy: {e}"));
                return;
            }
        };
        d.queued_since = match (d.client.queued(), d.queued_since) {
            (0, _) => None,
            (_, Some(t)) => Some(t),
            (_, None) => Some(Instant::now()),
        };
        for (k, ev) in events.into_iter().enumerate() {
            let at = v0 + k as u64;
            match ev {
                Event::Confirmed => {
                    let d = self.docs.get_mut(id).unwrap();
                    d.sent_at = None;
                    d.refused = 0;
                    d.must_resend = false;
                    d.backup_due = true;
                    d.authors.remove(&at);
                    d.review.confirmed();
                    if d.hist.is_some() {
                        self.hist_confirmed(id, at);
                    }
                    self.doc_state_note(id);
                }
                Event::Remote(op) => {
                    let d = self.docs.get_mut(id).unwrap();
                    d.multi_user = true;
                    let author = d.authors.remove(&at).flatten();
                    d.review.take_remote(at);
                    let edits = edit::from_classic(&cur, &op).unwrap_or_default();
                    cur = text::apply(&cur, &op).unwrap_or_else(|_| d.client.text().to_owned());
                    if d.unconfirmed() > 0 {
                        d.backup_due = true;
                    }
                    self.record(id, edits, op, "remote", author, None);
                }
            }
        }
        let d = self.docs.get_mut(id).unwrap();
        let version = d.client.version();
        d.authors.retain(|v, _| *v >= version);
        if d.hist.is_some() {
            self.hist_check(id);
        }
    }

    fn record(&mut self, doc_id: &str, edits: Vec<Edit>, op: Op, origin: &'static str, user_id: Option<String>, from: Option<u64>) {
        if !self.docs.contains_key(doc_id) {
            return;
        }
        let author = match user_id.as_deref() {
            Some(id) => self.users.get(id).cloned().unwrap_or_else(|| json!({"user_id": id, "name": null, "initials": null})),
            None => json!({"user_id": null}),
        };
        self.review_record(doc_id, &op, origin);
        let source = if origin == "local" { self.edit_source } else { None };
        let d = self.docs.get_mut(doc_id).unwrap();
        d.seq += 1;
        let seq = d.seq;
        d.log.push_back(Change { seq, edits: edits.clone(), op, origin, author: author.clone(), source });
        while d.log.len() > LOG_KEEP {
            d.log.pop_front();
        }
        let now = Instant::now();
        d.mirror_first.get_or_insert(now);
        d.mirror_last = now;
        self.note_from(
            "doc.changed",
            Some(doc_id),
            changed_params(doc_id, seq, &edits, origin, &author, source),
            from,
        );
    }

    fn on_event(&mut self, ev: ServerEvent) {
        match ev {
            ServerEvent::OtUpdateApplied(u) => {
                let id = u.doc.clone();
                self.feed(&id, u, false);
            }
            ServerEvent::OtUpdateError { error, message } => {
                // The server disconnects us next; the reconnect catches up and resends, until the doc gives up on it.
                tracing::error!("otUpdateError {error} {message}");
                let doc = message.get("doc_id").and_then(Value::as_str).map(String::from);
                self.activity(doc.as_deref(), "error", format!("otUpdateError {error}"));
                if let Some(doc) = doc {
                    self.refused(&doc, &format!("otUpdateError {error}"));
                }
            }
            ServerEvent::Closed { reason } => self.lost(reason),
            ServerEvent::ForceDisconnect { message, delay } => {
                let wait = Duration::from_secs_f64(delay.unwrap_or(0.0).clamp(0.0, 300.0));
                self.lost_for(format!("forceDisconnect {message}"), wait)
            }
            ServerEvent::ReconnectGracefully => self.lost("reconnectGracefully".into()),
            ServerEvent::Other { name, args } if self.on_tree_event(&name, &args) => {}
            ServerEvent::Other { name, args } => {
                if self.review_event(&name, &args) {
                    return;
                }
                tracing::debug!(%name, "event");
                self.note("activity", None, json!({"project_id": self.project_id, "kind": name, "args": args}));
            }
        }
    }

    /// Sends what's due, resends what's overdue, and rejoins docs that drifted.
    async fn flush(&mut self) {
        let Some(conn) = &self.conn else { return };
        let public_id = conn.public_id.clone();
        let now = Instant::now();
        let mut sends = vec![];
        let mut rejoins = vec![];
        let mut verifies = vec![];
        let mut lose = None;
        let me = self.me.get("user_id").and_then(Value::as_str).unwrap_or("").to_string();
        for (id, d) in self.docs.iter_mut() {
            if d.readonly.is_some() {
                continue;
            }
            if let Some(h) = d.hist.as_mut() {
                if let Some(from) = h.verify_from.take() {
                    verifies.push((id.clone(), from));
                }
                if d.needs_rejoin.is_none() {
                    // A history-ot op is never resent on the same connection (a duplicate's confirmation would be
                    // counted as a version): reconnect, catch up, and resend then.
                    if d.client.inflight().is_some() && !d.must_resend && d.sent_at.is_some_and(|t| now.duration_since(t) >= RESEND_AFTER) {
                        lose = Some(format!("{}: history-ot update unconfirmed for {} s", d.path, RESEND_AFTER.as_secs()));
                        continue;
                    }
                    if h.holding(now) {
                        continue;
                    }
                }
            }
            if d.queued_since.is_some_and(|t| now.duration_since(t) >= RESEND_AFTER) && d.needs_rejoin.is_none() {
                d.needs_rejoin = Some("an update before a queued one never arrived".into());
            }
            if let Some(why) = &d.needs_rejoin {
                // history-ot: an op in flight can't be resent on this connection, so give it time to land (or not) first;
                // the rejoin's catch-up then tells which.
                if d.hist.is_some() && d.client.inflight().is_some() && d.sent_at.is_some_and(|t| now.duration_since(t) < RESEND_AFTER) {
                    continue;
                }
                rejoins.push((id.clone(), why.clone()));
                continue;
            }
            let resend = d.client.inflight().is_some();
            let out = if resend {
                if d.must_resend || d.sent_at.is_none_or(|t| now.duration_since(t) >= RESEND_AFTER) {
                    d.client.resend(&public_id)
                } else {
                    None
                }
            } else if d.client.pending().is_none() {
                d.pending_since = None;
                None
            } else if now.duration_since(*d.pending_since.get_or_insert(now)) < flush_delay(d.multi_user) {
                None
            } else {
                d.pending_since = None;
                d.client.flush(&public_id)
            };
            if let Some(out) = out {
                if !resend {
                    d.review.flipped();
                }
                let (op, meta) = match d.hist.as_mut() {
                    None => d.review.outgoing(serde_json::to_value(&out.op).expect("ops serialize")),
                    Some(h) => {
                        let ts = hist::iso_now();
                        let track = d.review.inflight_tracked().then_some((me.as_str(), ts.as_str()));
                        match h.outgoing(&out.op, resend, &public_id, &me, track) {
                            Ok(op) => (op, None),
                            Err(e) => {
                                d.needs_rejoin = Some(format!("can't express our edit as a history-ot update: {e:#}"));
                                continue;
                            }
                        }
                    }
                };
                d.sent_at = Some(now);
                d.must_resend = false;
                d.backup_due = true;
                let update = OutgoingUpdate {
                    doc: id.clone(),
                    op,
                    v: out.v,
                    last_v: None,
                    hash: None,
                    meta,
                    dup_if_source: (!out.dup_if_source.is_empty()).then_some(out.dup_if_source),
                };
                sends.push((id.clone(), update));
            }
        }
        for (id, why) in rejoins {
            self.activity(Some(&id), "rejoin", format!("rejoining: {why}"));
            let conn = self.conn.as_ref().unwrap();
            // With an op in flight, join from our version when the server still has the ops: whether one of them is
            // ours (its source) says exactly whether it was applied, where the full join's text only allows a guess.
            let d = &self.docs[&id];
            let (from, sources) = match d.client.inflight() {
                Some(_) => (Some(d.client.version()), d.client.inflight_sources().to_vec()),
                _ => (None, vec![]),
            };
            let joined = match conn.join_doc(&id, from, None).await {
                Err(overleaf::Error::MissingOps) if from.is_some() => conn.join_doc(&id, None, None).await.map(|j| (j, None)),
                Ok(j) if from.is_some() => {
                    let applied = j.ops.iter().any(|u| u.source().is_some_and(|s| sources.iter().any(|x| x == s)));
                    if j.ot_type == OtType::HistoryOt {
                        // (its snapshot is taken from a full join, as when replaying a backup)
                        conn.join_doc(&id, None, None).await.map(|full| (full, Some(applied)))
                    } else {
                        Ok((j, Some(applied)))
                    }
                }
                r => r.map(|j| (j, None)),
            };
            match joined {
                Ok((j, applied)) => match self.joined_text(&id, &j) {
                    Ok(text) => {
                        self.rebase(&id, &text, j.version, applied);
                        self.review_joined(&id, &j);
                    }
                    Err(e) => {
                        self.lost(format!("joinDoc: {e:#}"));
                        return;
                    }
                },
                Err(e) => {
                    self.lost(format!("joinDoc: {e}"));
                    return;
                }
            }
        }
        // history-ot, after a resend's confirmation: the server's version from joinDoc(lastKnown). Behind ours means
        // we counted a duplicate: rejoin. Ahead is fine: those updates are on their way.
        for (id, from) in verifies {
            let conn = self.conn.as_ref().unwrap();
            match conn.join_doc(&id, Some(from), None).await {
                Ok(j) => {
                    if let Some(d) = self.docs.get_mut(&id) {
                        if j.version < d.client.version() {
                            d.needs_rejoin = Some(format!("server is at v{} but we counted v{}", j.version, d.client.version()));
                        }
                    }
                }
                Err(e) => tracing::warn!("joinDoc to check the version: {e}"),
            }
        }
        if let Some(why) = lose {
            self.lost(why);
            return;
        }
        // Back up what goes out before it goes: an engine killed after the send (before the next backup, up to
        // BACKUP_EVERY later) would otherwise replay a stale backup that still lists these edits as pending, and send
        // them again as new edits. Backed up as in flight, with their source, a replay resends them under the same
        // source and Overleaf drops the duplicate (dupIfSource).
        for (id, _) in &sends {
            if let Err(e) = self.backup(id) {
                self.activity(Some(id), "error", format!("could not back up unconfirmed edits: {e:#}"));
            }
        }
        for (id, u) in sends {
            let conn = self.conn.as_ref().unwrap();
            let send = conn.send_ot_update(&u);
            let (errors, public_id, doc) = (self.send_errors.0.clone(), public_id.clone(), id.clone());
            tokio::spawn(async move {
                if let Err(e) = send.await {
                    tracing::warn!("applyOtUpdate failed: {e}");
                    // Only an error from the server is a refusal of the op; a dropped connection isn't.
                    let doc = if matches!(e, overleaf::Error::Server { .. }) { doc } else { String::new() };
                    let _ = errors.send((public_id, doc, e.to_string()));
                }
            });
            self.doc_state_note(&id);
        }
    }

    /// Mirror files and backups that are due (all of them if `now`).
    fn disk_tick(&mut self, all: bool) {
        let now = Instant::now();
        if let Some(folder) = self.folder.clone() {
            let ids: Vec<String> = self.docs.keys().cloned().collect();
            for id in ids {
                let d = self.docs.get_mut(&id).unwrap();
                let Some(first) = d.mirror_first else { continue };
                if !all && now.duration_since(d.mirror_last) < MIRROR_QUIET && now.duration_since(first) < MIRROR_MAX_DELAY {
                    continue;
                }
                d.mirror_first = None;
                // Another program may have written the file since we last did: send that first, so the write below
                // carries it instead of overwriting it.
                let file = folder.join(&d.path);
                if let (Some((_, known)), Ok(now)) = (&d.disk, std::fs::read(&file)) {
                    if now != known.as_bytes() && now != d.client.text().as_bytes() {
                        self.disk_changed(&id);
                        continue;
                    }
                }
                if let Err(e) = self.write_doc_file(&id) {
                    let path = self.docs.get(&id).map(|d| d.path.clone()).unwrap_or_default();
                    self.activity(Some(&id), "error", format!("could not write {path}: {e:#}"));
                }
            }
        }
        if all || now.duration_since(self.last_backup) >= BACKUP_EVERY {
            self.last_backup = now;
            let ids: Vec<String> = self.docs.iter().filter(|(_, d)| d.backup_due || all).map(|(id, _)| id.clone()).collect();
            for id in ids {
                if let Err(e) = self.backup(&id) {
                    self.activity(Some(&id), "error", format!("could not back up unconfirmed edits: {e:#}"));
                }
            }
        }
    }

    fn backup_path(&self, doc_id: &str) -> PathBuf {
        self.home.join("backup").join(&self.project_id).join(format!("{doc_id}.json"))
    }

    /// Writes the doc's unconfirmed edits to disk, or removes the backup when there are none.
    fn backup(&mut self, id: &str) -> anyhow::Result<()> {
        let path = self.backup_path(id);
        let d = self.docs.get_mut(id).unwrap();
        d.backup_due = false;
        if d.client.is_idle() {
            match std::fs::remove_file(&path) {
                Err(e) if e.kind() != std::io::ErrorKind::NotFound => return Err(e.into()),
                _ => return Ok(()),
            }
        }
        let b = json!({
            "project_id": self.project_id,
            "doc_id": id,
            "path": d.path,
            "version": d.client.version(),
            "base": d.client.server_text(),
            "inflight": d.client.inflight(),
            "sent_under": d.client.inflight_sources(),
            "pending": d.client.pending(),
            "text": d.client.text(),
            "review": d.review.flags_json(),
        });
        write_atomic(&path, &serde_json::to_string(&b)?)
    }

    /// Returns true to stop the actor.
    async fn handle(&mut self, c: Cmd) -> bool {
        match c {
            Cmd::Status(reply) => {
                let docs: Vec<Value> = self
                    .docs
                    .iter()
                    .map(|(id, d)| json!({"doc_id": id, "path": d.path, "state": d.state(), "seq": d.seq,
                        "unconfirmed": d.unconfirmed(), "version": d.client.version(), "type": d.ot_type.as_str(),
                        "editable": true, "readonly": d.readonly}))
                    .collect();
                let connection = if self.docs.values().any(|d| d.readonly.is_some()) { "readonly" } else { self.connection };
                let _ = reply.send(Ok(json!({"project_id": self.project_id, "connection": connection,
                    "users": self.review_users_json(), "track_changes": self.review.track_changes, "overleaf_track_changes": self.review.overleaf_track, "me": self.me, "docs": docs})));
            }
            Cmd::OpenDoc { path, reply } => {
                let _ = reply.send(self.open_doc(&path).await);
            }
            Cmd::Edit { doc_id, seq, edits, edit_id, from_client, reply } => {
                let _ = reply.send(self.edit(&doc_id, seq, edits, edit_id, from_client));
            }
            Cmd::Since { doc_id, since, reply } => {
                let r = match self.docs.get(&doc_id) {
                    None => Err(anyhow!("doc {doc_id} is not open")),
                    Some(d) => {
                        let first = d.log.front().map(|c| c.seq).unwrap_or(d.seq + 1);
                        if since + 1 < first && since < d.seq {
                            Err(anyhow!("since_seq {since} is older than the log; reopen the doc"))
                        } else {
                            Ok((d.seq, d.since(since).cloned().collect()))
                        }
                    }
                };
                let _ = reply.send(r);
            }
            Cmd::Cursor { doc_id, pos, seq, reply } => {
                let _ = reply.send(self.cursor(&doc_id, pos, seq));
            }
            Cmd::Mirror { folder, adopt, reply } => {
                let _ = reply.send(self.mirror(folder, adopt).await);
            }
            Cmd::Tree(reply) => {
                let _ = reply.send(Ok(self.tree_json()));
            }
            Cmd::Http(reply) => {
                let _ = reply.send(Ok(self.http.clone()));
            }
            Cmd::Complete { params, reply } => {
                let _ = reply.send(self.complete_cmd(&params));
            }
            Cmd::Review { method, params, reply } => {
                let _ = reply.send(self.review_cmd(&method, params).await);
            }
            Cmd::Shutdown(reply) => {
                self.disk_tick(true);
                if let Some(c) = &self.conn {
                    c.disconnect();
                }
                let _ = reply.send(Ok(()));
                return true;
            }
        }
        false
    }

    fn cursor(&self, doc_id: &str, pos: usize, seq: Option<u64>) -> anyhow::Result<()> {
        let d = self.docs.get(doc_id).ok_or_else(|| anyhow!("doc {doc_id} is not open"))?;
        let conn = self.conn.as_ref().ok_or_else(|| anyhow!("offline"))?;
        let now = d.client.text();
        let pos = match seq {
            Some(s) if s != d.seq => {
                let then = d.text_at(s)?;
                let mut p = ot::units::byte_to_utf16(&then, pos)?;
                for c in d.since(s) {
                    p = text::transform_position(p, &c.op, Side::Right);
                }
                ot::units::utf16_to_byte(now, p)?
            }
            _ => pos,
        };
        let before = now.get(..pos).ok_or_else(|| anyhow!("bad position {pos}"))?;
        let row = before.matches('\n').count() as u64;
        let line_start = before.rfind('\n').map(|i| i + 1).unwrap_or(0);
        let column = ot::units::utf16_len(&before[line_start..]) as u64;
        conn.update_position(doc_id, row, column)?;
        Ok(())
    }

    async fn mirror(&mut self, folder: PathBuf, adopt: bool) -> anyhow::Result<()> {
        std::fs::create_dir_all(&folder)?;
        // The watcher reports canonical paths (/private/var/... on macOS).
        let folder = folder.canonicalize()?;
        if self.folder.as_ref() == Some(&folder) && self.watch.is_some() {
            return Ok(());
        }
        self.folder = Some(folder.clone());
        for (id, path) in self.tree.list(Kind::Doc) {
            if !self.docs.contains_key(&id) {
                self.open_doc(&path).await?;
            }
            let d = self.docs.get_mut(&id).unwrap();
            d.mirror_first = None;
            let file = folder.join(&path);
            match std::fs::read_to_string(&file) {
                Ok(t) if t == d.client.text() => {
                    d.disk = Some((d.seq, t));
                    continue;
                }
                Ok(t) => {
                    // The file differs from the server, and we can't tell which side is newer. The server wins; the
                    // local copy is kept aside.
                    let stamp = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)?.as_secs();
                    let keep = self.home.join("backup").join("conflicts").join(&self.project_id).join(format!("{path}.{stamp}"));
                    write_atomic(&keep, &t)?;
                    let msg = format!("{path} on disk differed from Overleaf; kept it as {}", keep.display());
                    self.activity(Some(&id), "conflict", msg);
                }
                Err(_) => {}
            }
            self.write_doc_file(&id)?;
        }
        self.mirror_files(&folder).await?;
        self.start_watch(&folder, adopt)?;
        Ok(())
    }

    async fn open_doc(&mut self, path: &str) -> anyhow::Result<Value> {
        let id = self
            .tree
            .find(path)
            .filter(|id| self.tree.get(id).is_some_and(|e| e.kind == Kind::Doc))
            .ok_or_else(|| anyhow!("no doc {path} in the project"))?;
        if !self.docs.contains_key(&id) {
            let backup = self.read_backup(&id);
            let conn = self.conn.as_ref().ok_or_else(|| anyhow!("offline"))?;
            match backup {
                Some(b) => {
                    let r = conn.join_doc(&id, Some(b.version), None).await;
                    let (j, missing) = match r {
                        Ok(j) => (j, false),
                        Err(overleaf::Error::MissingOps) => (conn.join_doc(&id, None, None).await?, true),
                        Err(e) => return Err(e.into()),
                    };
                    let mut d = Doc::new(path, j.ot_type.clone(), b.client);
                    d.review.restore_flags(&b.review);
                    d.must_resend = d.client.inflight().is_some();
                    let n = d.unconfirmed();
                    if j.ot_type == OtType::HistoryOt {
                        // The backup has no server copy at its version, so its edits are rebased onto the doc as it
                        // is now. The catch-up's sources still tell whether the inflight op went through.
                        let sources = d.client.inflight_sources().to_vec();
                        let applied = (!missing && d.client.inflight().is_some())
                            .then(|| j.ops.iter().any(|u| u.source().is_some_and(|s| sources.iter().any(|x| x == s))));
                        let full = if missing { j.clone() } else { conn.join_doc(&id, None, None).await? };
                        d.hist = Some(hist::Hist::new(Default::default()));
                        self.docs.insert(id.clone(), d);
                        let text = self.joined_text(&id, &full)?;
                        self.rebase(&id, &text, full.version, applied);
                    } else {
                        self.docs.insert(id.clone(), d);
                        if missing {
                            self.rebase(&id, &j.text(), j.version, None);
                        } else {
                            self.catch_up_doc(&id, j.ops.clone());
                            let d = &self.docs[&id];
                            if d.client.server_text() != j.text() || d.client.version() != j.version {
                                self.rebase(&id, &j.text(), j.version, None);
                            }
                        }
                    }
                    let d = self.docs.get_mut(&id).unwrap();
                    d.backup_due = true;
                    // The restored edits are in the text clients get from doc.open, so no change is recorded.
                    d.log.clear();
                    self.review_joined(&id, &j);
                    self.activity(Some(&id), "restored", format!("replayed {n} unconfirmed edit(s) to {path} from the backup"));
                }
                None => {
                    let j = conn.join_doc(&id, None, None).await?;
                    let mut d = Doc::new(path, j.ot_type.clone(), Client::new(j.text(), j.version));
                    if j.ot_type == OtType::HistoryOt {
                        d.hist = Some(hist::Hist::new(Default::default()));
                    }
                    self.docs.insert(id.clone(), d);
                    let text = self.joined_text(&id, &j)?;
                    if text != j.text() || j.ot_type == OtType::HistoryOt {
                        self.docs.get_mut(&id).unwrap().client = Client::new(text, j.version);
                    }
                    self.review_joined(&id, &j);
                }
            }
        }
        let d = &self.docs[&id];
        Ok(json!({"doc_id": id, "text": d.client.text(), "seq": d.seq, "type": d.ot_type.as_str(),
                  "version": d.client.version(), "readonly": d.readonly, "editable": true}))
    }

    fn read_backup(&mut self, id: &str) -> Option<Backup> {
        let path = self.backup_path(id);
        let raw = std::fs::read_to_string(&path).ok()?;
        match Backup::parse(&raw) {
            Ok(b) => Some(b),
            Err(e) => {
                let keep = path.with_extension(format!("bad-{}.json", std::process::id()));
                let _ = std::fs::rename(&path, &keep);
                self.activity(Some(id), "error", format!("unreadable backup moved to {}: {e:#}", keep.display()));
                None
            }
        }
    }

    /// Ops from `joinDoc(fromVersion)`. Like the browser's `catchUp`, each is taken to be at the current version.
    fn catch_up_doc(&mut self, id: &str, ops: Vec<Update>) {
        for u in ops {
            self.feed(id, u, true);
        }
    }

    /// A client's edits at its `seq`. Returns the seq of its change, and the changes the engine made on top of it that
    /// the client must also get (after the result): see [`bmp_fix`].
    fn edit(&mut self, doc_id: &str, seq: u64, edits: Vec<Edit>, edit_id: Option<String>, from: Option<u64>) -> anyhow::Result<(u64, Vec<Change>)> {
        let d = self.docs.get_mut(doc_id).ok_or_else(|| anyhow!("doc {doc_id} is not open"))?;
        if let Some(eid) = &edit_id {
            if let Some((_, s)) = d.edit_ids.iter().find(|(e, _)| e == eid) {
                return Ok((*s, Vec::new()));
            }
        }
        if let Some(r) = &d.readonly {
            bail!("doc is read-only: {r}");
        }
        if edits.iter().all(|e| e.del == 0 && e.ins.is_empty()) {
            return Ok((d.seq, Vec::new()));
        }
        let astral = edits.iter().any(|e| e.ins.chars().any(|c| c as u32 > 0xFFFF));
        let then = d.text_at(seq)?;
        let mut op = edit::to_classic(&then, &edits).map_err(|e| anyhow!("edits don't fit the doc at seq {seq}: {e}"))?;
        // Changes the client hadn't seen go first on ties: its insert lands after theirs at the same position.
        for c in d.since(seq) {
            op = text::transform(&op, &c.op, Side::Right)?;
        }
        let edits = edit::from_classic(d.client.text(), &op)?;
        // Characters outside the BMP: Overleaf stores two U+FFFD for each (docs/protocol.md, Astral characters). The
        // server gets the op with them already replaced (same UTF-16 length, so nothing moves); the log records the
        // client's op and then the replacement as a change of its own, which the client is sent after its result.
        let astral_text = if astral { Some(text::apply(d.client.text(), &op)?) } else { None };
        let sent = if astral { bmp_inserts(&op) } else { op.clone() };
        d.client.submit(sent)?;
        d.backup_due = true;
        let me = self.me.get("user_id").and_then(Value::as_str).map(String::from);
        self.record(doc_id, edits, op, "local", me.clone(), from);
        let d = self.docs.get_mut(doc_id).unwrap();
        let seq = d.seq;
        if let Some(eid) = edit_id {
            d.edit_ids.push_back((eid, seq));
            if d.edit_ids.len() > EDIT_IDS_KEEP {
                d.edit_ids.pop_front();
            }
        }
        let mut after = Vec::new();
        if let Some(t) = astral_text {
            let fix = bmp_fix(&t);
            let fix_edits = edit::from_classic(&t, &fix)?;
            self.record(doc_id, fix_edits, fix, "local", me, from);
            after.extend(self.docs[doc_id].log.back().cloned());
        }
        self.doc_state_note(doc_id);
        Ok((seq, after))
    }
}

/// `op` with each insert's characters outside the BMP replaced by two U+FFFD.
fn bmp_inserts(op: &Op) -> Op {
    op.iter()
        .map(|c| match c {
            text::Component::Insert { p, i } => text::Component::Insert { p: *p, i: folder::bmp_only(i).into_owned() },
            c => c.clone(),
        })
        .collect()
}

/// The classic op replacing each character outside the BMP in `text` with two U+FFFD, as Overleaf's classic server
/// stores them. Both are two UTF-16 units, so nothing else moves.
pub fn bmp_fix(text: &str) -> Op {
    let mut op = Op::new();
    let mut p = 0;
    for c in text.chars() {
        if c as u32 > 0xFFFF {
            text::append(&mut op, text::Component::Delete { p, d: c.to_string() });
            text::append(&mut op, text::Component::Insert { p, i: "\u{FFFD}\u{FFFD}".into() });
        }
        p += c.len_utf16();
    }
    op
}

/// A classic update's op.
fn parse_op(op: &Value) -> anyhow::Result<Op> {
    Ok(serde_json::from_value(op.clone())?)
}

/// A backup of one doc's unconfirmed edits.
struct Backup {
    version: u64,
    client: Client,
    /// The review batch flags (`DocReview::flags_json`).
    review: Value,
}

impl Backup {
    fn parse(raw: &str) -> anyhow::Result<Backup> {
        let v: Value = serde_json::from_str(raw)?;
        let version = v.get("version").and_then(Value::as_u64).ok_or_else(|| anyhow!("no version"))?;
        let base = v.get("base").and_then(Value::as_str).ok_or_else(|| anyhow!("no base"))?;
        let inflight: Option<Op> = serde_json::from_value(v.get("inflight").cloned().unwrap_or(Value::Null))?;
        let sent_under: Vec<String> = serde_json::from_value(v.get("sent_under").cloned().unwrap_or(json!([])))?;
        let pending: Option<Op> = serde_json::from_value(v.get("pending").cloned().unwrap_or(Value::Null))?;
        let client = Client::restore(base, version, inflight.map(|op| (op, sent_under)), pending)?;
        if let Some(t) = v.get("text").and_then(Value::as_str) {
            if t != client.text() {
                bail!("backup text does not match its ops");
            }
        }
        Ok(Backup { version, client, review: v.get("review").cloned().unwrap_or(Value::Null) })
    }
}

/// Writes `text` to `path` through a temporary file in the same folder and a rename, so readers never see half a file.
pub fn write_atomic(path: &Path, text: &str) -> anyhow::Result<()> {
    write_atomic_bytes(path, text.as_bytes())
}

/// [`write_atomic`] for any bytes.
pub fn write_atomic_bytes(path: &Path, bytes: &[u8]) -> anyhow::Result<()> {
    let dir = path.parent().ok_or_else(|| anyhow!("{} has no parent folder", path.display()))?;
    std::fs::create_dir_all(dir)?;
    let name = path.file_name().ok_or_else(|| anyhow!("{} has no file name", path.display()))?;
    let tmp = dir.join(format!(".{}.taudot-{}~", name.to_string_lossy(), std::process::id()));
    std::fs::write(&tmp, bytes).with_context(|| format!("writing {}", tmp.display()))?;
    std::fs::rename(&tmp, path).with_context(|| format!("renaming onto {}", path.display()))?;
    Ok(())
}

/// `doc.changed`'s params; `source` only when there is one (`"disk"`: the folder's file was edited, by an editor or an
/// agent outside Taudot).
pub fn changed_params(doc_id: &str, seq: u64, edits: &[Edit], origin: &str, author: &Value, source: Option<&str>) -> Value {
    let mut p = json!({"doc_id": doc_id, "seq": seq, "edits": edits, "origin": origin, "author": author});
    if let Some(s) = source {
        p["source"] = json!(s);
    }
    p
}
