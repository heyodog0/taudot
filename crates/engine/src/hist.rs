//! Editing `history-ot` docs (`docs/protocol.md`, history-ot), a child module of `engine` like `review`.
//!
//! The engine keeps the *visible* text of a history-ot doc (the content without tracked-deleted text, as Overleaf's
//! editor shows it), so its OT client, buffers, mirror and API work as for classic docs. Beside the client, [`Hist`]
//! keeps the server's own state, an [`ot::filedata::FileData`] at the client's version: incoming updates are applied
//! to it and projected to classic ops on the visible text; outgoing classic ops are turned into history-ot edit
//! operations against it ([`FileData::to_wire`]).
//!
//! Versions follow protocol.md's "What a history-ot client must do": the `v` of `otUpdateApplied` is never used;
//! every update for the doc counts as the next version in arrival order. Updates are also known by
//! `(meta.source, meta.ts)`, so one seen in a catch-up and again on the socket counts once. An update from one of our
//! own earlier connections confirms our inflight op if it was sent under that connection, and is otherwise ours
//! already counted. After a resend with `dupIfSource` two confirmations can arrive (the original's and the
//! duplicate's), so nothing new is sent until the second one has come or [`RESEND_AFTER`] has passed, and the version
//! is checked with `joinDoc(docId, lastKnown)`. An op unconfirmed for [`RESEND_AFTER`] is not resent on the same
//! connection: the engine reconnects, catches up (which tells whether it was applied), and resends only then.
//!
//! Accepting and rejecting tracked changes are ops in history-ot (retain with `tracking: none`, or a remove), so they
//! work on CE, unlike classic's REST route. They are sent alone, from an idle doc, through a marker component in the
//! client's op ([`WIRE_MARKER`]): the client carries their visible effect, and the flush sends the stored update.

use super::{review, Actor, RESEND_AFTER};
use ot::filedata::{self, FileData};
use ot::history::{EditOperation, TextOperation, Tracking, TrackingKind};
use ot::text::{Component, Op};
use overleaf::{JoinedDoc, Update};
use serde_json::Value;
use std::collections::VecDeque;
use std::time::Instant;

/// Thread ID of the marker comment component standing for a stored review update.
pub const WIRE_MARKER: &str = "\u{1}wire";
const SEEN_KEEP: usize = 2_000;
const MINE_KEEP: usize = 50;

pub struct Hist {
    /// The server's doc at the client's version.
    pub fd: FileData,
    /// The inflight op as sent, transformed past the updates received since, so the server's result can be applied to
    /// `fd` when it is confirmed.
    wire: Option<Vec<EditOperation>>,
    /// An accept/reject update waiting in the client's pending op behind [`WIRE_MARKER`].
    review_wire: Option<Vec<EditOperation>>,
    /// Tracked changes to accept (true) or reject, by ID, sent once the doc is idle.
    pub review_queue: Vec<(String, bool)>,
    /// `(source, ts)` of updates applied.
    seen: VecDeque<(String, String)>,
    /// Connections our updates were sent under.
    mine: VecDeque<String>,
    /// The inflight op was resent with `dupIfSource`.
    resent: bool,
    /// Confirmations still expected after a duplicate, and until when to wait for them.
    stray_acks: u32,
    stray_until: Option<Instant>,
    /// Check the version with `joinDoc(docId, from)`.
    pub verify_from: Option<u64>,
    /// Who added each comment (the snapshot doesn't say), from the updates seen.
    authors: std::collections::HashMap<String, String>,
}

impl Hist {
    pub fn new(fd: FileData) -> Hist {
        Hist {
            fd,
            wire: None,
            review_wire: None,
            review_queue: vec![],
            seen: VecDeque::new(),
            mine: VecDeque::new(),
            resent: false,
            stray_acks: 0,
            stray_until: None,
            verify_from: None,
            authors: Default::default(),
        }
    }

    fn note_authors(&mut self, ops: &[EditOperation], user: &str) {
        for o in ops {
            if let EditOperation::AddComment { comment_id, .. } = o {
                self.authors.entry(comment_id.clone()).or_insert_with(|| user.to_string());
            }
        }
    }

    /// The doc was joined afresh: take the server's state, forget what was in flight.
    pub fn reset(&mut self, fd: FileData) {
        self.fd = fd;
        self.wire = None;
        self.review_wire = None;
        self.resent = false;
        self.stray_acks = 0;
        self.stray_until = None;
        self.verify_from = None;
    }

    /// A new connection: confirmations meant for the old one won't come.
    pub fn reconnected(&mut self) {
        self.stray_acks = 0;
        self.stray_until = None;
    }

    /// Whether to hold new sends: a duplicate's confirmation may still be on its way. After [`RESEND_AFTER`] sends go
    /// on, but the confirmation still owed is kept: when it comes it is taken for the duplicate's, not for the op in
    /// flight then (if it never comes, that op's own confirmation is taken instead, and the op is settled by the
    /// reconnect after [`RESEND_AFTER`], whose catch-up tells by source).
    pub fn holding(&mut self, now: Instant) -> bool {
        self.stray_acks > 0 && self.stray_until.is_some_and(|t| now < t)
    }

    fn remember(&mut self, key: (String, String)) {
        self.seen.push_back(key);
        while self.seen.len() > SEEN_KEEP {
            self.seen.pop_front();
        }
    }

    /// The update to send for the client's outgoing op, `resend` for the inflight one again.
    pub fn outgoing(&mut self, op: &Op, resend: bool, conn: &str, me: &str, track: Option<(&str, &str)>) -> anyhow::Result<Value> {
        let wire = match (&self.wire, resend) {
            (Some(w), true) => w.clone(),
            _ if op.iter().any(|c| matches!(c, Component::Comment { t, .. } if t == WIRE_MARKER)) => {
                self.review_wire.take().ok_or_else(|| anyhow::anyhow!("review update lost"))?
            }
            _ => self.fd.to_wire(op, track)?,
        };
        let wire = if wire.is_empty() { vec![EditOperation::NoOp] } else { wire };
        self.note_authors(&wire, me);
        self.wire = Some(wire.clone());
        self.resent = resend;
        if !self.mine.iter().any(|m| m == conn) {
            self.mine.push_back(conn.to_string());
            while self.mine.len() > MINE_KEEP {
                self.mine.pop_front();
            }
        }
        Ok(filedata::ops_json(&wire))
    }
}

/// What a history-ot update means for the client.
pub enum Incoming {
    /// Already counted: skip it.
    Skip,
    /// Our inflight op is confirmed.
    Confirm,
    /// Someone else's change, as a classic op on the visible text.
    Remote(Op),
}

/// Content position ranges of tracked changes and their IDs, in [`FileData::tracked`] order. An ID is the change's
/// author, kind and time, numbered when several share them, so it stays the same while the change exists.
pub fn change_ids(fd: &FileData) -> Vec<String> {
    let mut seen: std::collections::HashMap<String, usize> = Default::default();
    fd.tracked
        .iter()
        .map(|t| {
            let kind = if t.tracking.kind == TrackingKind::Insert { "i" } else { "d" };
            let key = format!("{kind}{:x}", fnv(&format!("{}|{}", t.tracking.user_id, t.tracking.ts)));
            let n = seen.entry(key.clone()).or_default();
            *n += 1;
            format!("h{key}-{n}")
        })
        .collect()
}

fn fnv(s: &str) -> u64 {
    s.bytes().fold(0xcbf2_9ce4_8422_2325, |h, b| (h ^ b as u64).wrapping_mul(0x100_0000_01b3))
}

/// The ranges of `fd` on its visible text, in the classic tracker's terms: comments over their visible span, tracked
/// inserts over their text, tracked deletes as a point holding the deleted text.
pub fn base_tracker(h: &Hist) -> review::tracker::Tracker {
    let fd = &h.fd;
    use review::tracker::{u16s, Change, Comment, Kind, Meta, Tracker};
    let mut t = Tracker::new();
    let vis = u16s(&fd.visible());
    let content = u16s(&fd.content);
    for c in &fd.comments {
        let (Some(a), Some(b)) = (c.ranges.iter().map(|r| r.pos).min(), c.ranges.iter().map(|r| r.pos + r.length).max()) else { continue };
        let (va, vb) = (fd.to_visible(a), fd.to_visible(b));
        if vb > va {
            let meta = Meta { user_id: h.authors.get(&c.id).cloned(), ts: None };
            t.comments.push(Comment { id: c.id.clone(), p: va, c: vis[va..vb.min(vis.len())].to_vec(), meta });
        }
    }
    for (tc, id) in fd.tracked.iter().zip(change_ids(fd)) {
        let r = &tc.range;
        let text = content[r.pos.min(content.len())..(r.pos + r.length).min(content.len())].to_vec();
        let p = fd.to_visible(r.pos);
        let kind = if tc.tracking.kind == TrackingKind::Insert { Kind::Insert(text) } else { Kind::Delete(text) };
        let meta = Meta { user_id: Some(tc.tracking.user_id.clone()), ts: Some(Value::String(tc.tracking.ts.clone())) };
        t.changes.push(Change { id, p, kind, meta });
    }
    t
}

/// The update accepting (`true`) or rejecting tracked changes by ID: accepting an insert or rejecting a delete clears
/// its tracking, the other two remove the text. Unknown IDs are left out.
pub fn review_update(fd: &FileData, which: &[(String, bool)]) -> Option<Vec<EditOperation>> {
    let ids = change_ids(fd);
    let mut picks: Vec<(usize, usize, bool)> = vec![]; // content pos, length, remove?
    for (tc, id) in fd.tracked.iter().zip(&ids) {
        if let Some((_, accept)) = which.iter().find(|(w, _)| w == id) {
            let insert = tc.tracking.kind == TrackingKind::Insert;
            picks.push((tc.range.pos, tc.range.length, insert != *accept));
        }
    }
    if picks.is_empty() {
        return None;
    }
    let len = ot::units::utf16_len(&fd.content);
    let mut t = TextOperation::new();
    let mut at = 0;
    for (pos, n, remove) in picks {
        t.retain(pos - at, None);
        if remove {
            t.remove(n);
        } else {
            t.retain(n, Some(Tracking::Clear));
        }
        at = pos + n;
    }
    t.retain(len - at, None);
    Some(vec![EditOperation::Text(t)])
}

/// Now as ISO 8601 with milliseconds, as Overleaf writes `ts`.
pub fn iso_now() -> String {
    let ms = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_millis() as i64);
    let (days, rem) = (ms.div_euclid(86_400_000), ms.rem_euclid(86_400_000));
    // Civil from days (Howard Hinnant's algorithm).
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(m <= 2);
    let (h, mi, s, milli) = (rem / 3_600_000, rem / 60_000 % 60, rem / 1000 % 60, rem % 1000);
    format!("{y:04}-{m:02}-{d:02}T{h:02}:{mi:02}:{s:02}.{milli:03}Z")
}

impl Actor {
    /// Sorts a history-ot update: counted already, our confirmation, or a remote change to show. Applies a remote one
    /// to the server copy and moves our inflight update past it.
    pub(super) fn hist_classify(&mut self, id: &str, u: &Update) -> anyhow::Result<Incoming> {
        let d = self.docs.get_mut(id).unwrap();
        let has_inflight = d.client.inflight().is_some();
        let sources: Vec<String> = d.client.inflight_sources().to_vec();
        d.hist.as_mut().unwrap().classify(id, u, has_inflight, &sources)
    }
}

impl Hist {
    /// [`Actor::hist_classify`] on this doc's state: whether our op is in flight and the connections it went under.
    pub fn classify(&mut self, id: &str, u: &Update, has_inflight: bool, sources: &[String]) -> anyhow::Result<Incoming> {
        let h = self;
        let Some(op) = &u.op else {
            if h.stray_acks > 0 {
                h.stray_acks -= 1;
                return Ok(Incoming::Skip);
            }
            if has_inflight {
                return Ok(Incoming::Confirm);
            }
            {
                tracing::warn!(doc = id, "history-ot confirmation with nothing in flight; ignored");
            }
            return Ok(Incoming::Skip);
        };
        let source = u.source().unwrap_or("").to_string();
        // Without `meta.ts`, the op itself tells two updates from one connection apart (the same one seen in a catch-up
        // and on the socket is identical).
        let ts = u.meta.as_ref().and_then(|m| m.get("ts")).map(|t| t.to_string()).unwrap_or_else(|| format!("op:{op}"));
        let key = (source.clone(), ts);
        if !source.is_empty() && h.seen.contains(&key) {
            return Ok(Incoming::Skip);
        }
        h.remember(key);
        if h.mine.iter().any(|m| m == &source) {
            if has_inflight && sources.iter().any(|s| *s == source) {
                if h.resent {
                    // The original went through; the resend's duplicate will be confirmed too.
                    h.stray_acks += 1;
                    h.stray_until = Some(Instant::now() + RESEND_AFTER);
                }
                return Ok(Incoming::Confirm);
            }
            return Ok(Incoming::Skip);
        }
        let ops = filedata::ops_from_json(op).map_err(|e| anyhow::anyhow!("{e}"))?;
        h.note_authors(&ops, u.user_id().unwrap_or(""));
        if let Some(w) = &h.wire {
            h.wire = Some(filedata::transform(w, &ops)?.0);
        }
        Ok(Incoming::Remote(h.fd.apply_projected(&ops)?))
    }
}

impl Actor {

    /// Our inflight update is confirmed (the client counted it): apply it to the server copy, and put the client
    /// right if its idea of the server's text differs.
    pub(super) fn hist_confirmed(&mut self, id: &str, version_before: u64) {
        let d = self.docs.get_mut(id).unwrap();
        let h = d.hist.as_mut().unwrap();
        if let Some(w) = h.wire.take() {
            if let Err(e) = h.fd.apply_all(&w) {
                d.needs_rejoin = Some(format!("our confirmed history-ot update doesn't fit the server copy: {e}"));
                return;
            }
        }
        if std::mem::take(&mut h.resent) {
            h.verify_from = Some(version_before);
        }
        self.hist_check(id);
    }

    /// The client's server text must be the visible text of the server copy. Where a transform tie went another way
    /// in the two (visible and content positions), rebase the client onto the server copy.
    pub(super) fn hist_check(&mut self, id: &str) {
        let d = &self.docs[id];
        if d.client.inflight().is_some() {
            return;
        }
        let Some(h) = &d.hist else { return };
        let vis = h.fd.visible();
        if d.client.server_text() != vis {
            tracing::warn!(doc = id, "visible text differs from the history-ot server copy; rebasing");
            let v = d.client.version();
            self.rebase(id, &vis, v, Some(false));
        }
    }

    /// After a full `joinDoc` of a history-ot doc: the server copy from its snapshot, and the visible text.
    pub(super) fn hist_joined(&mut self, id: &str, j: &JoinedDoc) -> anyhow::Result<String> {
        let snap = j.history_snapshot.as_ref().ok_or_else(|| anyhow::anyhow!("history-ot join without a snapshot"))?;
        let fd = FileData::from_json(snap).map_err(|e| anyhow::anyhow!("{e}"))?;
        let vis = fd.visible();
        if let Some(h) = self.docs.get_mut(id).and_then(|d| d.hist.as_mut()) {
            h.reset(fd);
        }
        Ok(vis)
    }

    /// Accepts and rejects that are due: once the doc has nothing unconfirmed, as one update of their own.
    pub(super) fn hist_review_tick(&mut self, id: &str) {
        let d = self.docs.get_mut(id).unwrap();
        if !d.client.is_idle() || d.readonly.is_some() || d.needs_rejoin.is_some() {
            return;
        }
        let Some(h) = d.hist.as_mut() else { return };
        if h.review_queue.is_empty() || h.review_wire.is_some() {
            return;
        }
        let which = std::mem::take(&mut h.review_queue);
        let Some(wire) = review_update(&h.fd, &which) else { return };
        let mut after = h.fd.clone();
        let vis = match after.apply_projected(&wire) {
            Ok(v) => v,
            Err(e) => {
                tracing::warn!("review update: {e}");
                return;
            }
        };
        let before = d.client.text().to_owned();
        let mut op = vis.clone();
        op.push(Component::Comment { p: 0, c: String::new(), t: WIRE_MARKER.into() });
        if let Err(e) = d.client.submit(op) {
            tracing::warn!("review update: {e}");
            return;
        }
        h.review_wire = Some(wire);
        d.review.pending_undo = true;
        // Sent on this tick's flush, not after the batching delay.
        d.pending_since = Some(Instant::now() - std::time::Duration::from_secs(3600));
        let edits = ot::edit::from_classic(&before, &vis).unwrap_or_default();
        let me = self.me.get("user_id").and_then(Value::as_str).map(String::from);
        self.record(id, edits, vis, "local", me, None);
        self.doc_state_note(id);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ot::history::{Range, TrackingProps};

    #[test]
    fn iso_now_looks_like_overleafs() {
        let s = iso_now();
        assert_eq!(s.len(), 24, "{s}");
        assert!(s.starts_with("20") && s.ends_with('Z') && &s[10..11] == "T" && &s[19..20] == ".", "{s}");
    }

    #[test]
    fn change_ids_survive_edits_elsewhere() {
        let tp = |kind, user: &str| TrackingProps { kind, user_id: user.into(), ts: "2026-01-01T00:00:00.000Z".into() };
        let mut fd = FileData::new("0123456789");
        fd.tracked.push(filedata::TrackedChange { range: Range { pos: 2, length: 2 }, tracking: tp(TrackingKind::Insert, "a") });
        fd.tracked.push(filedata::TrackedChange { range: Range { pos: 6, length: 2 }, tracking: tp(TrackingKind::Delete, "b") });
        let before = change_ids(&fd);
        let mut t = TextOperation::new();
        t.insert("xx", None, None).unwrap().retain(10, None);
        fd.apply(&EditOperation::Text(t)).unwrap();
        assert_eq!(change_ids(&fd), before);
        // Accept the insert, reject the delete: both clear tracking; the text stays.
        let u = review_update(&fd, &[(before[0].clone(), true), (before[1].clone(), false)]).unwrap();
        fd.apply_all(&u).unwrap();
        assert!(fd.tracked.is_empty());
        assert_eq!(fd.content, "xx0123456789");
    }

    fn update(source: &str, ts: Option<&str>, op: Value) -> Update {
        let mut meta = serde_json::json!({"source": source, "user_id": "u2"});
        if let Some(t) = ts {
            meta["ts"] = serde_json::json!(t);
        }
        serde_json::from_value(serde_json::json!({"doc": "d", "v": 1, "op": op, "meta": meta})).unwrap()
    }

    fn insert_at(p: usize, s: &str, len: usize) -> Value {
        let mut t = vec![];
    if p > 0 {
        t.push(serde_json::json!(p));
    }
    t.push(serde_json::json!(s));
    if len > p {
        t.push(serde_json::json!(len - p));
    }
    serde_json::json!([{"textOperation": t}])
    }

    #[test]
    fn updates_without_ts_are_not_taken_for_each_other() {
        // E14: two different updates from one connection, neither with meta.ts: both are changes.
        let mut h = Hist::new(FileData::new("abc"));
        let a = h.classify("d", &update("P.x", None, insert_at(0, "1", 3)), false, &[]).unwrap();
        let b = h.classify("d", &update("P.x", None, insert_at(0, "2", 4)), false, &[]).unwrap();
        assert!(matches!(a, Incoming::Remote(_)) && matches!(b, Incoming::Remote(_)));
        assert_eq!(h.fd.content, "21abc");
        // The same one again (a catch-up and the socket): counted once.
        let u = update("P.y", Some("2026-11-06T00:00:00.000Z"), insert_at(0, "3", 5));
        assert!(matches!(h.classify("d", &u, false, &[]).unwrap(), Incoming::Remote(_)));
        assert!(matches!(h.classify("d", &u, false, &[]).unwrap(), Incoming::Skip));
    }

    #[test]
    fn a_late_duplicate_confirmation_does_not_confirm_the_next_op() {
        // E14: we resent op A with dupIfSource; A's original is applied (confirmed), so the duplicate's confirmation is
        // still to come. It comes after the wait, when op B is in flight: it must not count as B's.
        let mut h = Hist::new(FileData::new("abc"));
        let a: Op = vec![Component::Insert { p: 3, i: "!".into() }];
        h.outgoing(&a, false, "P.1", "u1", None).unwrap();
        h.outgoing(&a, true, "P.2", "u1", None).unwrap(); // the resend
        let original = update("P.1", Some("2026-11-06T00:00:01.000Z"), insert_at(3, "!", 3));
        let sources = vec!["P.1".to_string(), "P.2".to_string()];
        assert!(matches!(h.classify("d", &original, true, &sources).unwrap(), Incoming::Confirm));
        assert!(h.holding(Instant::now()));
        // The wait runs out; B goes out.
        assert!(!h.holding(Instant::now() + RESEND_AFTER + std::time::Duration::from_secs(1)));
        let b: Op = vec![Component::Insert { p: 0, i: "B".into() }];
        h.outgoing(&b, false, "P.2", "u1", None).unwrap();
        let ack: Update = serde_json::from_value(serde_json::json!({"doc": "d", "v": 9})).unwrap();
        assert!(matches!(h.classify("d", &ack, true, &["P.2".to_string()]).unwrap(), Incoming::Skip), "the late duplicate's ack");
        assert!(matches!(h.classify("d", &ack, true, &["P.2".to_string()]).unwrap(), Incoming::Confirm), "B's own");
    }
}
