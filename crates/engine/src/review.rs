//! Review features (plan M4): collaborators' cursors, comments and their threads, tracked changes.
//!
//! A child module of `engine`, so it extends the project actor (`impl Actor`) and the hooks in `engine.rs` stay one
//! line each. What it keeps:
//!
//! - Per doc, a [`tracker::Tracker`]: comment ranges and tracked changes, moved by every change the engine records,
//!   local or remote, the way Overleaf's browser moves them (`document-container.ts` `applyOpsToRanges`). Reset from
//!   `joinDoc`'s ranges on every join, then unconfirmed edits are replayed on top (`catchUpRanges`).
//! - Per project, who is connected and where their cursor is (`clientTracking.*` events), positions moved past every
//!   change.
//! - Per project, comment threads from `GET /project/:id/threads` and the socket events that change them. Overleaf
//!   CE has no thread routes (404); then threads are unsupported and only the ranges show.
//!
//! Our own tracked edits: with `review.track` on, local edits go into the doc's tracker as tracked, and the batch that
//! holds them is sent with `meta.tc`, the ID seed the server mints their change IDs from. Each batch (pending, then in
//! flight) has its own seed, as in the browser. Rejecting tracked changes sends their inverse as an undo (`u: true`)
//! batch of its own, as the browser does.

#[path = "review/tracker.rs"]
pub mod tracker;

use super::{user_json, Actor};
use anyhow::{anyhow, bail};
use ot::text::{self, Component, Op, Side};
use overleaf::{JoinedDoc, Update};
use serde_json::{json, Value};
use std::collections::{BTreeMap, HashMap};
use std::time::{Duration, Instant};
use tracker::{string, ts_ms, Kind, Meta, TOp, Tracker};

/// API methods this module answers (`docs/api.md`).
pub const METHODS: &[&str] = &[
    "doc.ranges",
    "thread.get",
    "thread.list",
    "comment.add",
    "thread.reply",
    "thread.resolve",
    "thread.reopen",
    "thread.delete",
    "message.edit",
    "message.delete",
    "change.accept",
    "change.reject",
    "review.track",
];

/// What a remote update said about itself, kept by version until the client processes it.
#[derive(Clone, Debug, Default)]
pub struct RemoteMeta {
    tc: Option<String>,
    user_id: Option<String>,
    ts: Option<Value>,
}

pub struct DocReview {
    pub tracker: Tracker,
    remote: HashMap<u64, RemoteMeta>,
    /// The meta of the remote change being recorded now.
    current: Option<RemoteMeta>,
    pending_seed: String,
    inflight_seed: String,
    pending_tracked: bool,
    inflight_tracked: bool,
    pub(super) pending_undo: bool,
    inflight_undo: bool,
    /// Change IDs to reject once the doc has nothing unsent.
    rejects: Vec<String>,
    /// Our tracked batch was confirmed: take the server's ranges (its change IDs) once the doc is idle.
    refetch: bool,
    /// Ranges changed since the last `ranges.changed`; `sent` is what that one said, positions left out.
    dirty: bool,
    sent: Option<Value>,
}

impl DocReview {
    pub fn new() -> DocReview {
        let mut tracker = Tracker::new();
        let seed = tracker.id_seed().to_string();
        tracker.set_id_seed(&seed);
        DocReview {
            tracker,
            remote: HashMap::new(),
            current: None,
            pending_seed: seed,
            inflight_seed: String::new(),
            pending_tracked: false,
            inflight_tracked: false,
            pending_undo: false,
            inflight_undo: false,
            rejects: vec![],
            refetch: false,
            dirty: true,
            sent: None,
        }
    }

    /// The pending batch is now in flight (`flipped_pending_to_inflight`): it keeps its seed, new edits get a fresh one.
    pub fn flipped(&mut self) {
        self.inflight_seed = std::mem::replace(&mut self.pending_seed, tracker::new_id_seed());
        self.inflight_tracked = std::mem::take(&mut self.pending_tracked);
        self.inflight_undo = std::mem::take(&mut self.pending_undo);
        self.tracker.set_id_seed(&self.pending_seed);
    }

    /// The batch in flight was folded back into the pending one (a rebase found it not applied): the combined batch is
    /// tracked if either was, under the in-flight seed then, and an undo only if nothing was typed after it.
    pub fn folded(&mut self, pending_was_empty: bool) {
        if self.inflight_tracked && !self.pending_tracked {
            self.pending_seed = std::mem::take(&mut self.inflight_seed);
            self.tracker.set_id_seed(&self.pending_seed);
        }
        self.pending_tracked |= self.inflight_tracked;
        self.pending_undo = if pending_was_empty { self.inflight_undo } else { self.pending_undo && self.inflight_undo };
        self.inflight_tracked = false;
        self.inflight_undo = false;
    }

    /// The batch flags, for a backup: replayed edits go out tracked (or as an undo) as they would have.
    pub fn flags_json(&self) -> Value {
        json!({"inflight_tracked": self.inflight_tracked, "inflight_undo": self.inflight_undo, "inflight_seed": self.inflight_seed,
               "pending_tracked": self.pending_tracked, "pending_undo": self.pending_undo, "pending_seed": self.pending_seed})
    }

    /// Restores [`DocReview::flags_json`].
    pub fn restore_flags(&mut self, v: &Value) {
        let b = |k: &str| v.get(k).and_then(Value::as_bool).unwrap_or(false);
        let s = |k: &str| v.get(k).and_then(Value::as_str).filter(|s| !s.is_empty()).map(String::from);
        self.inflight_tracked = b("inflight_tracked");
        self.inflight_undo = b("inflight_undo");
        self.pending_tracked = b("pending_tracked");
        self.pending_undo = b("pending_undo");
        if let Some(seed) = s("inflight_seed") {
            self.inflight_seed = seed;
        }
        if let Some(seed) = s("pending_seed") {
            self.pending_seed = seed;
            self.tracker.set_id_seed(&self.pending_seed);
        }
    }

    /// The op and `meta` to send for the batch in flight.
    pub fn outgoing(&self, mut op: Value) -> (Value, Option<Value>) {
        if self.inflight_undo {
            for c in op.as_array_mut().into_iter().flatten() {
                if c.get("c").is_none() {
                    c["u"] = json!(true);
                }
            }
        }
        let meta = self.inflight_tracked.then(|| json!({"tc": self.inflight_seed}));
        (op, meta)
    }

    /// Whether the batch in flight is tracked (and not an undo).
    pub fn inflight_tracked(&self) -> bool {
        self.inflight_tracked && !self.inflight_undo
    }

    pub fn confirmed(&mut self) {
        if self.inflight_tracked {
            self.refetch = true;
        }
        self.inflight_tracked = false;
        self.inflight_undo = false;
    }

    pub fn note_remote(&mut self, v: u64, u: &Update) {
        let m = u.meta.as_ref();
        let s = |k: &str| m.and_then(|m| m.get(k)).and_then(Value::as_str).map(String::from);
        self.remote.insert(v, RemoteMeta { tc: s("tc"), user_id: s("user_id"), ts: m.and_then(|m| m.get("ts")).cloned() });
    }

    pub fn take_remote(&mut self, v: u64) {
        self.current = self.remote.remove(&v);
        self.remote.retain(|k, _| *k > v);
    }

    /// Applies a recorded change to the ranges.
    fn apply(&mut self, op: &Op, origin: &str, me: Option<String>, track_mine: bool) {
        let now = json!(now_ms());
        let (track, user, seed, ts, undo) = match (origin, self.current.take()) {
            ("local", _) => {
                if track_mine && !self.pending_undo {
                    self.pending_tracked = true;
                }
                (track_mine && !self.pending_undo, me, None, now, self.pending_undo)
            }
            (_, Some(m)) => (m.tc.is_some(), m.user_id, m.tc, m.ts.unwrap_or(now), false),
            (_, None) => (false, None, None, now, false),
        };
        let old_seed = self.tracker.id_seed().to_string();
        if let Some(s) = &seed {
            self.tracker.set_id_seed(s);
        }
        self.tracker.track_changes = track;
        let meta = Meta { user_id: user, ts: Some(ts) };
        for c in op {
            if let Err(e) = self.tracker.apply(&TOp::from_component(c, undo), &meta) {
                // Out of step with the text; the next join puts it right. Keep going with what we have.
                tracing::warn!("ranges: {e}");
            }
        }
        if seed.is_some() {
            self.tracker.set_id_seed(&old_seed);
        }
        self.tracker.track_changes = false;
        self.dirty = true;
    }
}

impl Default for DocReview {
    fn default() -> Self {
        DocReview::new()
    }
}

#[derive(Clone, Debug)]
struct Presence {
    user: Value,
    doc_id: Option<String>,
    /// UTF-16 offset into the doc's current text.
    pos: Option<usize>,
}

#[derive(Clone, Debug, Default)]
struct Message {
    id: String,
    text: String,
    ts: Option<f64>,
    user: Value,
}

#[derive(Clone, Debug, Default)]
struct Thread {
    resolved: bool,
    resolved_at: Option<Value>,
    resolved_by: Value,
    messages: Vec<Message>,
}

#[derive(Default)]
pub struct ProjectReview {
    pub track_changes: bool,
    /// Overleaf's project-wide setting, `trackChangesState` (`true`, or `{<user_id>: bool, __guests__: bool}`); null
    /// when the project doesn't say.
    pub overleaf_track: Value,
    users: BTreeMap<String, Presence>,
    /// None until loaded; `supported` is false on servers without the thread routes.
    threads: Option<BTreeMap<String, Thread>>,
    supported: Option<bool>,
}

fn now_ms() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_millis() as u64)
}

fn arg_str(args: &[Value], i: usize) -> Option<String> {
    args.get(i).and_then(Value::as_str).map(String::from)
}

enum Verb {
    Get,
    Post,
    Delete,
}

impl Actor {
    fn review_user(&self, id: Option<&str>) -> Value {
        match id {
            Some(id) => self.users.get(id).cloned().unwrap_or_else(|| json!({"user_id": id, "name": null, "initials": null})),
            None => json!({"user_id": null, "name": null, "initials": null}),
        }
    }

    /// A user from a message or event (`{id|_id, first_name, last_name, email}`), preferring the member list.
    fn review_user_from(&self, u: &Value, fallback_id: Option<&str>) -> Value {
        let s = |k: &str| u.get(k).and_then(Value::as_str).unwrap_or("").to_string();
        let id = u.get("id").or(u.get("_id")).and_then(Value::as_str).or(fallback_id);
        match id {
            Some(id) => self.users.get(id).cloned().unwrap_or_else(|| user_json(id, &s("first_name"), &s("last_name"), &s("email"))),
            None if u.is_object() => user_json("", &s("first_name"), &s("last_name"), &s("email")),
            None => Value::Null,
        }
    }

    // ---- hooks called from engine.rs ------------------------------------------------------------------------------

    /// The connection went: who was here is unknown until the reconnect asks again.
    pub(super) fn review_disconnected(&mut self) {
        if !self.review.users.is_empty() {
            self.review.users.clear();
            self.review_presence_note();
        }
    }

    /// After the connection is (re)made: who is here, and the threads.
    pub(super) async fn review_connected(&mut self) {
        let Some(conn) = &self.conn else { return };
        let state = conn.project.get("trackChangesState").cloned().unwrap_or(Value::Null);
        self.review_set_overleaf_track(state);
        let Some(conn) = &self.conn else { return };
        let me = conn.public_id.clone();
        match conn.connected_users().await {
            Ok(list) => {
                self.review.users.clear();
                for u in list.as_array().into_iter().flatten() {
                    let Some(cid) = u.get("client_id").and_then(Value::as_str) else { continue };
                    if cid == me {
                        continue;
                    }
                    let uid = u.get("user_id").and_then(Value::as_str);
                    let user = self.review_user_from(u, uid);
                    let cd = u.get("cursorData");
                    let doc_id = cd.and_then(|c| c.get("doc_id")).and_then(Value::as_str).map(String::from);
                    let rc: Option<(u64, u64)> = cd.and_then(|c| Some((c.get("row")?.as_u64()?, c.get("column")?.as_u64()?)));
                    let pos = match (&doc_id, rc) {
                        (Some(d), Some((r, c))) => self.review_rc_to_pos(d, r, c),
                        _ => None,
                    };
                    self.review.users.insert(cid.to_string(), Presence { user, doc_id, pos });
                }
                self.review_presence_note();
            }
            Err(e) => tracing::warn!("clientTracking.getConnectedUsers: {e}"),
        }
        if self.review.supported != Some(false) {
            if let Err(e) = self.review_load_threads().await {
                tracing::warn!("loading comment threads: {e:#}");
            }
        }
    }

    /// A change is being recorded (`Actor::record`): move ranges and cursors past it.
    pub(super) fn review_record(&mut self, doc_id: &str, op: &Op, origin: &str) {
        let me = self.me.get("user_id").and_then(Value::as_str).map(String::from);
        let track = self.review.track_changes;
        if let Some(d) = self.docs.get_mut(doc_id) {
            d.review.apply(op, origin, me, track);
        }
        for p in self.review.users.values_mut() {
            if p.doc_id.as_deref() == Some(doc_id) {
                if let Some(pos) = p.pos {
                    p.pos = Some(text::transform_position(pos, op, Side::Right));
                }
            }
        }
    }

    /// The doc was (re)joined: take the server's ranges, then replay what we haven't had confirmed.
    pub(super) fn review_joined(&mut self, id: &str, j: &JoinedDoc) {
        let Some(d) = self.docs.get_mut(id) else { return };
        let t = match &d.hist {
            Some(h) => super::hist::base_tracker(h),
            None => Tracker::from_json(&j.ranges),
        };
        self.review_rebuild_from(id, t);
    }

    /// A history-ot doc's ranges after an update: the server copy's, then what we haven't had confirmed.
    pub(super) fn review_hist_rebuild(&mut self, id: &str) {
        let Some(t) = self.docs.get(id).and_then(|d| d.hist.as_ref()).map(super::hist::base_tracker) else { return };
        let before = self.docs[id].review.tracker.to_json();
        self.review_rebuild_from(id, t);
        let d = self.docs.get_mut(id).unwrap();
        d.review.dirty = d.review.tracker.to_json() != before;
    }

    /// Ranges from `t` (the server's), with our inflight and pending edits replayed on top.
    fn review_rebuild_from(&mut self, id: &str, mut t: Tracker) {
        let Some(d) = self.docs.get_mut(id) else { return };
        let me = self.me.get("user_id").and_then(Value::as_str).map(String::from);
        let r = &mut d.review;
        r.remote.clear();
        r.current = None;
        let replay = [
            (d.client.inflight().cloned(), r.inflight_seed.clone(), r.inflight_tracked, r.inflight_undo),
            (d.client.pending().cloned(), r.pending_seed.clone(), r.pending_tracked, r.pending_undo),
        ];
        for (op, seed, tracked, undo) in replay {
            let Some(op) = op else { continue };
            t.set_id_seed(&seed);
            t.track_changes = tracked;
            let meta = Meta { user_id: me.clone(), ts: Some(json!(now_ms())) };
            for c in op.iter().filter(|c| !matches!(c, Component::Comment { t, .. } if t == super::hist::WIRE_MARKER)) {
                let _ = t.apply(&TOp::from_component(c, undo), &meta);
            }
        }
        t.track_changes = false;
        t.set_id_seed(&r.pending_seed.clone());
        r.tracker = t;
        r.dirty = true;
        r.sent = None;
    }

    /// Socket events this module handles. Returns false for others.
    pub(super) fn review_event(&mut self, name: &str, args: &[Value]) -> bool {
        match name {
            "clientTracking.clientUpdated" => {
                let Some(u) = args.first() else { return true };
                let Some(cid) = u.get("id").and_then(Value::as_str).map(String::from) else { return true };
                let uid = u.get("user_id").and_then(Value::as_str);
                let user = match uid.and_then(|id| self.users.get(id)) {
                    Some(known) => known.clone(),
                    None => {
                        let n = u.get("name").and_then(Value::as_str).unwrap_or("");
                        let e = u.get("email").and_then(Value::as_str).unwrap_or("");
                        user_json(uid.unwrap_or(""), n, "", e)
                    }
                };
                let doc_id = u.get("doc_id").and_then(Value::as_str).map(String::from);
                let (row, col) = (u.get("row").and_then(Value::as_u64).unwrap_or(0), u.get("column").and_then(Value::as_u64).unwrap_or(0));
                let pos = doc_id.as_deref().and_then(|d| self.review_rc_to_pos(d, row, col));
                self.review.users.insert(cid, Presence { user, doc_id, pos });
                self.review_presence_note();
            }
            "clientTracking.clientDisconnected" => {
                if let Some(cid) = arg_str(args, 0) {
                    if self.review.users.remove(&cid).is_some() {
                        self.review_presence_note();
                    }
                }
            }
            "new-comment" => {
                let (Some(tid), Some(m)) = (arg_str(args, 0), args.get(1)) else { return true };
                let msg = self.review_message(m);
                let threads = self.review.threads.get_or_insert_with(BTreeMap::new);
                self.review.supported = Some(true);
                let t = threads.entry(tid.clone()).or_default();
                if !t.messages.iter().any(|x| x.id == msg.id) {
                    t.messages.push(msg);
                }
                self.review_thread_note(&tid);
            }
            "edit-message" => {
                let (Some(tid), Some(mid), Some(content)) = (arg_str(args, 0), arg_str(args, 1), arg_str(args, 2)) else { return true };
                if let Some(t) = self.review.threads.as_mut().and_then(|ts| ts.get_mut(&tid)) {
                    for m in t.messages.iter_mut().filter(|m| m.id == mid) {
                        m.text = content.clone();
                    }
                }
                self.review_thread_note(&tid);
            }
            "delete-message" => {
                let (Some(tid), Some(mid)) = (arg_str(args, 0), arg_str(args, 1)) else { return true };
                if let Some(t) = self.review.threads.as_mut().and_then(|ts| ts.get_mut(&tid)) {
                    t.messages.retain(|m| m.id != mid);
                }
                self.review_thread_note(&tid);
            }
            "resolve-thread" | "reopen-thread" => {
                let Some(tid) = arg_str(args, 0) else { return true };
                let by = if name == "resolve-thread" { args.get(1).map(|u| self.review_user_from(u, None)) } else { None };
                let t = self.review.threads.get_or_insert_with(BTreeMap::new).entry(tid.clone()).or_default();
                t.resolved = name == "resolve-thread";
                t.resolved_by = by.unwrap_or(Value::Null);
                t.resolved_at = t.resolved.then(|| json!(now_ms()));
                self.review_thread_note(&tid);
                self.review_all_dirty();
            }
            "delete-thread" => {
                let Some(tid) = arg_str(args, 0) else { return true };
                if let Some(ts) = self.review.threads.as_mut() {
                    ts.remove(&tid);
                }
                for d in self.docs.values_mut() {
                    if d.review.tracker.comment(&tid).is_some() {
                        d.review.tracker.remove_comment(&tid);
                        d.review.dirty = true;
                    }
                }
                self.note("thread.changed", None, json!({"project_id": self.project_id, "thread_id": tid, "thread": null}));
            }
            "new-comment-threads" => {
                let Some(obj) = args.first().and_then(Value::as_object) else { return true };
                let parsed: Vec<(String, Thread)> = obj.iter().map(|(k, v)| (k.clone(), self.review_thread_from(v))).collect();
                let threads = self.review.threads.get_or_insert_with(BTreeMap::new);
                let ids: Vec<String> = parsed.iter().map(|(k, _)| k.clone()).collect();
                threads.extend(parsed);
                for tid in ids {
                    self.review_thread_note(&tid);
                }
                self.review_all_dirty();
            }
            "toggle-track-changes" => {
                self.review_set_overleaf_track(args.first().cloned().unwrap_or(Value::Null));
            }
            "accept-changes" => {
                let (Some(doc), Some(ids)) = (arg_str(args, 0), args.get(1).and_then(Value::as_array)) else { return true };
                let ids: Vec<String> = ids.iter().filter_map(|v| v.as_str().map(String::from)).collect();
                if let Some(d) = self.docs.get_mut(&doc) {
                    d.review.tracker.remove_changes(&ids);
                    d.review.dirty = true;
                }
            }
            _ => return false,
        }
        true
    }

    /// Every 50 ms: rejections that are due, refetching ranges after our tracked edits, and `ranges.changed`.
    pub(super) async fn review_tick(&mut self) {
        if self.conn.is_none() {
            return;
        }
        let ids: Vec<String> = self.docs.keys().cloned().collect();
        for id in ids {
            if self.docs[&id].hist.is_some() {
                self.hist_review_tick(&id);
                self.docs.get_mut(&id).unwrap().review.refetch = false;
            }
            let d = &self.docs[&id];
            let idle = d.client.is_idle();
            let (rejects, refetch, v) = (!d.review.rejects.is_empty() && d.readonly.is_none(), d.review.refetch, d.client.version());
            if rejects && idle {
                if let Err(e) = self.review_reject_now(&id) {
                    self.activity(Some(&id), "error", format!("rejecting tracked changes: {e:#}"));
                }
            } else if refetch && idle {
                self.docs.get_mut(&id).unwrap().review.refetch = false;
                let conn = self.conn.as_ref().unwrap();
                if let Ok(j) = conn.join_doc(&id, Some(v), None).await {
                    let d = &self.docs[&id];
                    if j.ops.is_empty() && j.version == d.client.version() && d.client.is_idle() {
                        self.review_joined(&id, &j);
                    }
                }
            }
            self.review_maybe_send_ranges(&id);
        }
    }

    /// Answers an API method from [`METHODS`].
    pub(super) async fn review_cmd(&mut self, method: &str, p: Value) -> anyhow::Result<Value> {
        let s = |k: &str| p.get(k).and_then(Value::as_str).map(String::from);
        let need = |k: &str| s(k).ok_or_else(|| anyhow!("missing string param {k}"));
        match method {
            "doc.ranges" => {
                let doc_id = need("doc_id")?;
                let d = self.docs.get(&doc_id).ok_or_else(|| anyhow!("doc {doc_id} is not open"))?;
                Ok(json!({"doc_id": doc_id, "seq": d.seq, "ranges": self.review_ranges_json(&doc_id)}))
            }
            "thread.get" => {
                let tid = need("thread_id")?;
                self.review_need_threads().await?;
                let t = self.review.threads.as_ref().and_then(|ts| ts.get(&tid)).ok_or_else(|| anyhow!("no thread {tid}"))?;
                Ok(self.review_thread_json(&tid, t))
            }
            "thread.list" => {
                let supported = self.review_need_threads().await.is_ok();
                let mut out = vec![];
                // Every comment range in an open doc, with its thread if the server has threads.
                for (doc_id, d) in &self.docs {
                    for c in &d.review.tracker.comments {
                        let mut v = match self.review.threads.as_ref().and_then(|ts| ts.get(&c.id)) {
                            Some(t) => self.review_thread_json(&c.id, t),
                            None => json!({"thread_id": c.id, "resolved": false, "messages": []}),
                        };
                        let (start, end) = range_bytes(d.client.text(), c.p, c.c.len()).unwrap_or((0, 0));
                        v["doc_id"] = json!(doc_id);
                        v["path"] = json!(d.path);
                        v["start"] = json!(start);
                        v["end"] = json!(end);
                        v["text"] = json!(string(&c.c));
                        v["seq"] = json!(d.seq);
                        out.push(v);
                    }
                }
                Ok(json!({"supported": supported, "threads": out}))
            }
            "comment.add" => {
                let doc_id = need("doc_id")?;
                let content = need("text")?;
                let start = p.get("start").and_then(Value::as_u64).ok_or_else(|| anyhow!("missing integer param start"))? as usize;
                let end = p.get("end").and_then(Value::as_u64).ok_or_else(|| anyhow!("missing integer param end"))? as usize;
                let seq = p.get("seq").and_then(Value::as_u64);
                self.review_add_comment(&doc_id, start, end, seq, &content).await
            }
            "thread.reply" => {
                let tid = need("thread_id")?;
                let content = need("text")?;
                self.review_rest(Verb::Post, &format!("thread/{tid}/messages"), Some(json!({"content": content}))).await?;
                Ok(json!({}))
            }
            "thread.resolve" | "thread.reopen" | "thread.delete" => {
                let tid = need("thread_id")?;
                let doc_id = match s("doc_id") {
                    Some(d) => d,
                    None => self
                        .docs
                        .iter()
                        .find(|(_, d)| d.review.tracker.comment(&tid).is_some())
                        .map(|(id, _)| id.clone())
                        .ok_or_else(|| anyhow!("no open doc has a comment for thread {tid}; pass doc_id"))?,
                };
                let path = format!("doc/{doc_id}/thread/{tid}");
                match method {
                    "thread.resolve" => {
                        self.review_rest(Verb::Post, &format!("{path}/resolve"), Some(json!({}))).await?;
                    }
                    "thread.reopen" => {
                        self.review_rest(Verb::Post, &format!("{path}/reopen"), Some(json!({}))).await?;
                    }
                    _ => {
                        self.review_rest(Verb::Delete, &path, None).await?;
                        if let Some(d) = self.docs.get_mut(&doc_id) {
                            d.review.tracker.remove_comment(&tid);
                            d.review.dirty = true;
                        }
                        if let Some(ts) = self.review.threads.as_mut() {
                            ts.remove(&tid);
                        }
                    }
                };
                Ok(json!({}))
            }
            "message.edit" => {
                let (tid, mid, content) = (need("thread_id")?, need("message_id")?, need("text")?);
                self.review_rest(Verb::Post, &format!("thread/{tid}/messages/{mid}/edit"), Some(json!({"content": content}))).await?;
                Ok(json!({}))
            }
            "message.delete" => {
                let (tid, mid) = (need("thread_id")?, need("message_id")?);
                let me = self.me.get("user_id").and_then(Value::as_str).map(String::from);
                let mine = self
                    .review
                    .threads
                    .as_ref()
                    .and_then(|ts| ts.get(&tid))
                    .and_then(|t| t.messages.iter().find(|m| m.id == mid))
                    .is_none_or(|m| m.user.get("user_id").and_then(Value::as_str).map(String::from) == me);
                // The browser deletes its own messages through `own-messages`, which needs no project-owner rights.
                let route = if mine { "own-messages" } else { "messages" };
                self.review_rest(Verb::Delete, &format!("thread/{tid}/{route}/{mid}"), None).await?;
                Ok(json!({}))
            }
            "change.accept" | "change.reject" => {
                let doc_id = need("doc_id")?;
                let ids: Vec<String> = p
                    .get("ids")
                    .and_then(Value::as_array)
                    .ok_or_else(|| anyhow!("missing list param ids"))?
                    .iter()
                    .filter_map(|v| v.as_str().map(String::from))
                    .collect();
                let d = self.docs.get(&doc_id).ok_or_else(|| anyhow!("doc {doc_id} is not open"))?;
                if let Some(h) = &d.hist {
                    // history-ot: both are ops (hist.rs), so they work where classic's REST route is missing.
                    let known = super::hist::change_ids(&h.fd);
                    let unknown: Vec<&String> = ids.iter().filter(|i| !known.contains(i)).collect();
                    if !unknown.is_empty() {
                        bail!("no confirmed tracked change {} in this doc", unknown.iter().map(|s| s.as_str()).collect::<Vec<_>>().join(", "));
                    }
                    let accept = method == "change.accept";
                    let d = self.docs.get_mut(&doc_id).unwrap();
                    d.hist.as_mut().unwrap().review_queue.extend(ids.into_iter().map(|i| (i, accept)));
                    return Ok(json!({}));
                }
                let unknown: Vec<&String> = ids.iter().filter(|i| !d.review.tracker.changes.iter().any(|c| &c.id == *i)).collect();
                if !unknown.is_empty() {
                    bail!("no tracked change {} in this doc", unknown.iter().map(|s| s.as_str()).collect::<Vec<_>>().join(", "));
                }
                if method == "change.accept" {
                    let r = self.review_rest(Verb::Post, &format!("doc/{doc_id}/changes/accept"), Some(json!({"change_ids": ids}))).await;
                    if let Err(e) = r {
                        if e.to_string().contains("404") {
                            bail!("this server can't accept tracked changes (no /changes/accept route; Overleaf CE has none)");
                        }
                        return Err(e);
                    }
                    let d = self.docs.get_mut(&doc_id).unwrap();
                    d.review.tracker.remove_changes(&ids);
                    d.review.dirty = true;
                } else {
                    let d = self.docs.get_mut(&doc_id).unwrap();
                    d.review.rejects.extend(ids);
                }
                Ok(json!({}))
            }
            "review.track" => {
                if let Some(on) = p.get("on").and_then(Value::as_bool) {
                    if on != self.review.track_changes {
                        self.cut_batches();
                    }
                    self.review.track_changes = on;
                }
                Ok(json!({"on": self.review.track_changes, "overleaf": self.review.overleaf_track}))
            }
            _ => bail!("unknown method {method}"),
        }
    }

    /// `users` for `project.status` and `presence.changed`.
    pub(super) fn review_users_json(&self) -> Value {
        let users: Vec<Value> = self
            .review
            .users
            .iter()
            .map(|(cid, p)| {
                let mut u = p.user.clone();
                u["client_id"] = json!(cid);
                u["doc_id"] = json!(p.doc_id);
                let d = p.doc_id.as_ref().and_then(|d| self.docs.get(d));
                u["pos"] = match (d, p.pos) {
                    (Some(d), Some(pos)) => ot::units::utf16_to_byte(d.client.text(), pos.min(ot::units::utf16_len(d.client.text())))
                        .map_or(Value::Null, |b| json!(b)),
                    _ => Value::Null,
                };
                u["seq"] = json!(d.map(|d| d.seq));
                u
            })
            .collect();
        json!(users)
    }

    // ---- internals ------------------------------------------------------------------------------------------------

    /// Overleaf's track-changes setting changed (or was read on joining). Like the browser's `setWantTrackChanges`,
    /// our edits follow our own entry in it; `review.track` can still override until the next change.
    fn review_set_overleaf_track(&mut self, state: Value) {
        let me = self.me.get("user_id").and_then(Value::as_str).unwrap_or("__guests__").to_string();
        let on = match &state {
            Value::Bool(b) => *b,
            Value::Object(m) => m.get(&me).and_then(Value::as_bool).unwrap_or(false),
            _ => self.review.track_changes,
        };
        let changed = state != self.review.overleaf_track || on != self.review.track_changes;
        if on != self.review.track_changes {
            self.cut_batches();
        }
        self.review.overleaf_track = state;
        self.review.track_changes = on;
        if changed {
            self.note("review.track", None, json!({"project_id": self.project_id, "on": on, "overleaf": self.review.overleaf_track}));
        }
    }

    fn review_rc_to_pos(&self, doc_id: &str, row: u64, column: u64) -> Option<usize> {
        let t = self.docs.get(doc_id)?.client.text();
        let mut start = 0usize;
        for _ in 0..row {
            start += t[start..].find('\n')? + 1;
        }
        let line = t[start..].split('\n').next().unwrap_or("");
        let col = (column as usize).min(ot::units::utf16_len(line));
        Some(ot::units::utf16_len(&t[..start]) + col)
    }

    fn review_presence_note(&self) {
        self.note("presence.changed", None, json!({"project_id": self.project_id, "users": self.review_users_json()}));
    }

    fn review_all_dirty(&mut self) {
        for d in self.docs.values_mut() {
            d.review.dirty = true;
        }
    }

    fn review_message(&self, m: &Value) -> Message {
        let uid = m.get("user_id").and_then(Value::as_str);
        Message {
            id: m.get("id").or(m.get("_id")).and_then(Value::as_str).unwrap_or("").to_string(),
            text: m.get("content").and_then(Value::as_str).unwrap_or("").to_string(),
            ts: m.get("timestamp").and_then(ts_ms),
            user: self.review_user_from(m.get("user").unwrap_or(&Value::Null), uid),
        }
    }

    fn review_thread_from(&self, v: &Value) -> Thread {
        Thread {
            resolved: v.get("resolved").and_then(Value::as_bool).unwrap_or(false),
            resolved_at: v.get("resolved_at").cloned().filter(|x| !x.is_null()),
            resolved_by: match v.get("resolved_by_user") {
                Some(u) if u.is_object() => self.review_user_from(u, v.get("resolved_by_user_id").and_then(Value::as_str)),
                _ => v.get("resolved_by_user_id").and_then(Value::as_str).map_or(Value::Null, |id| self.review_user(Some(id))),
            },
            messages: v.get("messages").and_then(Value::as_array).into_iter().flatten().map(|m| self.review_message(m)).collect(),
        }
    }

    fn review_thread_json(&self, tid: &str, t: &Thread) -> Value {
        let messages: Vec<Value> =
            t.messages.iter().map(|m| json!({"id": m.id, "text": m.text, "ts": m.ts.map(|x| x as u64), "user": m.user})).collect();
        let at = t.resolved_at.as_ref().and_then(ts_ms).map(|x| x as u64);
        json!({"thread_id": tid, "resolved": t.resolved, "resolved_at": at, "resolved_by": t.resolved_by, "messages": messages})
    }

    fn review_thread_note(&self, tid: &str) {
        let thread = self.review.threads.as_ref().and_then(|ts| ts.get(tid)).map(|t| self.review_thread_json(tid, t));
        self.note("thread.changed", None, json!({"project_id": self.project_id, "thread_id": tid, "thread": thread}));
    }

    async fn review_load_threads(&mut self) -> anyhow::Result<()> {
        match self.review_rest(Verb::Get, "threads", None).await {
            Ok(v) => {
                let map: BTreeMap<String, Thread> =
                    v.as_object().into_iter().flatten().map(|(k, t)| (k.clone(), self.review_thread_from(t))).collect();
                self.review.threads = Some(map);
                self.review.supported = Some(true);
                self.review_all_dirty();
                Ok(())
            }
            Err(e) if e.to_string().contains("404") => {
                self.review.supported = Some(false);
                Err(e)
            }
            Err(e) => Err(e),
        }
    }

    async fn review_need_threads(&mut self) -> anyhow::Result<()> {
        if self.review.supported == Some(false) {
            bail!("this server has no comment threads (GET /project/{}/threads: 404)", self.project_id);
        }
        if self.review.threads.is_none() {
            self.review_load_threads().await?;
        }
        Ok(())
    }

    /// A call to `/project/<id>/<path>` with the CSRF token, JSON in and out. Errors name the status.
    async fn review_rest(&mut self, verb: Verb, path: &str, body: Option<Value>) -> anyhow::Result<Value> {
        if !matches!(verb, Verb::Get) && self.http.csrf.is_none() {
            self.http.fetch_csrf("project").await?;
        }
        let url = self.http.base.join(&format!("project/{}/{path}", self.project_id))?;
        let c = &self.http.client;
        let mut req = match verb {
            Verb::Get => c.get(url),
            Verb::Post => c.post(url),
            Verb::Delete => c.delete(url),
        };
        req = req.header("Accept", "application/json");
        if let Some(t) = &self.http.csrf {
            req = req.header("X-CSRF-Token", t);
        }
        if let Some(b) = body {
            req = req.json(&b);
        }
        let resp = req.send().await?;
        let status = resp.status();
        let text = resp.text().await.unwrap_or_default();
        if status.as_u16() == 404 && self.review.supported.is_none() {
            // Overleaf CE has none of the review routes.
        }
        if !status.is_success() {
            let short: String = text.chars().take(200).collect();
            if status.as_u16() == 404 {
                bail!("{} /project/{}/{path}: 404 (this server has no such route)", verb_name(&verb), self.project_id);
            }
            bail!("{} /project/{}/{path}: {status} {short}", verb_name(&verb), self.project_id);
        }
        Ok(serde_json::from_str(&text).unwrap_or(Value::Null))
    }

    async fn review_add_comment(&mut self, doc_id: &str, start: usize, end: usize, seq: Option<u64>, content: &str) -> anyhow::Result<Value> {
        {
            let d = self.docs.get(doc_id).ok_or_else(|| anyhow!("doc {doc_id} is not open"))?;
            if let Some(r) = &d.readonly {
                bail!("doc is read-only: {r}");
            }
            if end <= start {
                bail!("a comment needs some text: start {start} end {end}");
            }
        }
        if self.review.supported == Some(false) {
            bail!("this server has no comment threads (Overleaf CE): can't add a comment");
        }
        let (p, len) = self.review_span_now(doc_id, start, end, seq)?;
        let thread_id = tracker::new_thread_id();
        // As the browser does: the message first, then the range.
        let r = self.review_rest(Verb::Post, &format!("thread/{thread_id}/messages"), Some(json!({"content": content}))).await;
        if let Err(e) = r {
            if e.to_string().contains("404") {
                self.review.supported = Some(false);
                bail!("this server has no comment threads (Overleaf CE): can't add a comment");
            }
            return Err(e);
        }
        // The text may have changed while the request was out: no, the actor handles one thing at a time.
        let d = self.docs.get_mut(doc_id).ok_or_else(|| anyhow!("doc {doc_id} closed"))?;
        let c = ot::units::slice16(d.client.text(), p, p + len)?.to_string();
        let op = vec![Component::Comment { p, c, t: thread_id.clone() }];
        d.client.submit(op.clone())?;
        self.record(doc_id, vec![], op, "local", self.me.get("user_id").and_then(Value::as_str).map(String::from), None);
        self.doc_state_note(doc_id);
        let seq = self.docs[doc_id].seq;
        Ok(json!({"thread_id": thread_id, "seq": seq}))
    }

    /// A byte span measured at `seq` (or now), as a UTF-16 start and length in the current text.
    fn review_span_now(&self, doc_id: &str, start: usize, end: usize, seq: Option<u64>) -> anyhow::Result<(usize, usize)> {
        let d = &self.docs[doc_id];
        let (s16, e16) = match seq {
            Some(s) if s != d.seq => {
                let then = d.text_at(s)?;
                let mut a = ot::units::byte_to_utf16(&then, start)?;
                let mut b = ot::units::byte_to_utf16(&then, end)?;
                for c in d.since(s) {
                    a = text::transform_position(a, &c.op, Side::Right);
                    b = text::transform_position(b, &c.op, Side::Left);
                }
                (a, b.max(a))
            }
            _ => (ot::units::byte_to_utf16(d.client.text(), start)?, ot::units::byte_to_utf16(d.client.text(), end)?),
        };
        if e16 <= s16 {
            bail!("the commented text is gone");
        }
        Ok((s16, e16 - s16))
    }

    /// Tracking was switched: pending batches go out now, so the edits before the switch aren't tagged by what comes
    /// after (a batch is tracked or not as a whole, as in the browser).
    fn cut_batches(&mut self) {
        for d in self.docs.values_mut() {
            if d.client.pending().is_some() {
                d.pending_since = Some(Instant::now() - Duration::from_secs(3600));
            }
        }
    }

    /// Sends the inverse of the queued tracked changes as one undo batch (`reject-changes.ts`).
    fn review_reject_now(&mut self, id: &str) -> anyhow::Result<()> {
        let d = self.docs.get_mut(id).unwrap();
        let ids = std::mem::take(&mut d.review.rejects);
        let mut changes: Vec<tracker::Change> = d.review.tracker.changes.iter().filter(|c| ids.contains(&c.id)).cloned().collect();
        if changes.is_empty() {
            return Ok(());
        }
        // Highest position first, so each inverse leaves the earlier ones where they are.
        changes.sort_by(|a, b| b.p.cmp(&a.p));
        let mut op = Op::new();
        let mut doc = d.client.text().to_owned();
        for c in &changes {
            let comp = match &c.kind {
                Kind::Insert(i) => {
                    let s = string(i);
                    let at = ot::units::slice16(&doc, c.p, c.p + i.len())?;
                    if at != s {
                        bail!("tracked insert {} no longer matches the text", c.id);
                    }
                    Component::Delete { p: c.p, d: s }
                }
                Kind::Delete(dd) => Component::Insert { p: c.p, i: string(dd) },
            };
            doc = text::apply(&doc, std::slice::from_ref(&comp))?;
            op.push(comp);
        }
        let before = d.client.text().to_owned();
        d.client.submit(op.clone())?;
        d.review.pending_undo = true;
        // Sent on this tick's flush (the doc is idle), not after the batching delay: what is typed next must not join
        // the undo batch (it would go out as an untracked undo).
        d.pending_since = Some(Instant::now() - Duration::from_secs(3600));
        let edits = ot::edit::from_classic(&before, &op)?;
        let me = self.me.get("user_id").and_then(Value::as_str).map(String::from);
        self.record(id, edits, op, "local", me, None);
        self.doc_state_note(id);
        Ok(())
    }

    fn review_ranges_json(&self, doc_id: &str) -> Value {
        let Some(d) = self.docs.get(doc_id) else { return json!([]) };
        let text = d.client.text();
        let mut out = vec![];
        for c in &d.review.tracker.comments {
            let Some((start, end)) = range_bytes(text, c.p, c.c.len()) else { continue };
            let t = self.review.threads.as_ref().and_then(|ts| ts.get(&c.id));
            let author = t.and_then(|t| t.messages.first()).map(|m| m.user.clone()).unwrap_or_else(|| self.review_user(c.meta.user_id.as_deref()));
            out.push(json!({"id": c.id, "kind": "comment", "start": start, "end": end, "thread_id": c.id, "text": string(&c.c),
                "resolved": t.is_some_and(|t| t.resolved), "author": author, "ts": c.meta.ts.as_ref().and_then(ts_ms).map(|x| x as u64)}));
        }
        for c in &d.review.tracker.changes {
            let (kind, len, t) = match &c.kind {
                Kind::Insert(i) => ("tracked_insert", i.len(), i),
                // A point in the text, as the deleted text isn't shown (history-ot's is in the content, but the
                // engine's text for such a doc is the visible one).
                Kind::Delete(dd) => ("tracked_delete", 0, dd),
            };
            let Some((start, end)) = range_bytes(text, c.p, len) else { continue };
            out.push(json!({"id": c.id, "kind": kind, "start": start, "end": end, "text": string(t),
                "author": self.review_user(c.meta.user_id.as_deref()), "ts": c.meta.ts.as_ref().and_then(ts_ms).map(|x| x as u64)}));
        }
        out.sort_by_key(|r| (r["start"].as_u64(), r["end"].as_u64()));
        json!(out)
    }

    fn review_maybe_send_ranges(&mut self, doc_id: &str) {
        let Some(d) = self.docs.get(doc_id) else { return };
        if !d.review.dirty {
            return;
        }
        let ranges = self.review_ranges_json(doc_id);
        // Clients move ranges with the text themselves (extmarks); only tell them when something else changed.
        let shape: Vec<Value> = ranges
            .as_array()
            .unwrap()
            .iter()
            .map(|r| {
                let mut r = r.clone();
                let o = r.as_object_mut().unwrap();
                o.remove("start");
                o.remove("end");
                r
            })
            .collect();
        let shape = json!(shape);
        let seq = d.seq;
        let d = self.docs.get_mut(doc_id).unwrap();
        d.review.dirty = false;
        if d.review.sent.as_ref() == Some(&shape) {
            return;
        }
        d.review.sent = Some(shape);
        self.note("ranges.changed", Some(doc_id), json!({"doc_id": doc_id, "seq": seq, "ranges": ranges}));
    }
}

fn verb_name(v: &Verb) -> &'static str {
    match v {
        Verb::Get => "GET",
        Verb::Post => "POST",
        Verb::Delete => "DELETE",
    }
}

/// UTF-16 `[p, p + len)` as byte offsets in `text`.
fn range_bytes(text: &str, p: usize, len: usize) -> Option<(usize, usize)> {
    Some((ot::units::utf16_to_byte(text, p).ok()?, ot::units::utf16_to_byte(text, p + len).ok()?))
}

#[cfg(test)]
#[path = "review/tests.rs"]
mod tests;
