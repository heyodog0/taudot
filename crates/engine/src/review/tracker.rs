//! Comments and tracked changes of a classic (`sharejs-text-ot`) doc, moved by every op the way Overleaf moves them.
//!
//! The rules follow `libraries/ranges-tracker/index.cjs` (Overleaf's `RangesTracker`, which both the document
//! updater and the browser run on every op), case by case, so our ranges and the server's agree. Written from reading
//! that file; `tests` below checks it against the original on random ops when `TAUDOT_RANGES_JS` points at it.
//!
//! Positions and lengths are UTF-16 code units, as in classic ops. Text is kept as UTF-16 too, so slicing matches
//! JavaScript exactly.
//!
//! What the ranges mean: a tracked insert is text in the doc; a tracked delete is text no longer in the doc, anchored
//! at the position it was removed from (it takes no room). A comment covers text in the doc.

use ot::text::Component;
use serde_json::{json, Value};

/// `{user_id, ts}` of a change or comment. `ts` is kept as the server sent it (ISO string or ms).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Meta {
    pub user_id: Option<String>,
    pub ts: Option<Value>,
}

#[derive(Clone, Debug, PartialEq)]
pub enum Kind {
    Insert(Vec<u16>),
    Delete(Vec<u16>),
}

#[derive(Clone, Debug, PartialEq)]
pub struct Change {
    pub id: String,
    pub p: usize,
    pub kind: Kind,
    pub meta: Meta,
}

impl Change {
    fn ins(&self) -> Option<&Vec<u16>> {
        match &self.kind {
            Kind::Insert(i) => Some(i),
            Kind::Delete(_) => None,
        }
    }
    fn del(&self) -> Option<&Vec<u16>> {
        match &self.kind {
            Kind::Delete(d) => Some(d),
            Kind::Insert(_) => None,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Comment {
    /// The thread ID.
    pub id: String,
    pub p: usize,
    pub c: Vec<u16>,
    pub meta: Meta,
}

/// One op component as the tracker sees it: an insert, delete or comment, and whether it undoes (`u: true`).
#[derive(Clone, Debug)]
pub enum TOp {
    Insert { p: usize, i: Vec<u16>, u: bool },
    Delete { p: usize, d: Vec<u16> },
    Comment { p: usize, c: Vec<u16>, t: String },
}

impl TOp {
    pub fn from_component(c: &Component, undo: bool) -> TOp {
        match c {
            Component::Insert { p, i } => TOp::Insert { p: *p, i: u16s(i), u: undo },
            Component::Delete { p, d } => TOp::Delete { p: *p, d: u16s(d) },
            Component::Comment { p, c, t } => TOp::Comment { p: *p, c: u16s(c), t: t.clone() },
        }
    }
}

pub fn u16s(s: &str) -> Vec<u16> {
    s.encode_utf16().collect()
}

pub fn string(v: &[u16]) -> String {
    String::from_utf16_lossy(v)
}

/// JavaScript's `s.slice(a, b)` for non-negative indexes.
fn slice(s: &[u16], a: usize, b: usize) -> Vec<u16> {
    let b = b.min(s.len());
    let a = a.min(b);
    s[a..b].to_vec()
}

fn cat(parts: &[&[u16]]) -> Vec<u16> {
    parts.concat()
}

#[derive(Clone, Debug, Default)]
pub struct Tracker {
    pub changes: Vec<Change>,
    pub comments: Vec<Comment>,
    pub track_changes: bool,
    id_seed: String,
    id_increment: u32,
}

/// The first 18 hex characters of an ObjectId: 8 of time, then 10 random. Change IDs are this plus a 6-digit counter;
/// thread IDs are this plus `000001` (`RangesTracker.generateId`).
pub fn new_id_seed() -> String {
    let t = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_secs());
    let mut x = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(1, |d| d.as_nanos() as u64);
    static N: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    x ^= (std::process::id() as u64).wrapping_mul(0x9E37_79B9_7F4A_7C15);
    x = x.wrapping_add(N.fetch_add(1, std::sync::atomic::Ordering::Relaxed).wrapping_mul(0xD1B5_4A32_D192_ED03));
    // splitmix64, enough for IDs that only need to differ
    x = x.wrapping_add(0x9E37_79B9_7F4A_7C15);
    let mut z = x;
    z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
    z ^= z >> 31;
    format!("{:08x}{:010x}", t as u32, z & 0xff_ffff_ffff)
}

pub fn new_thread_id() -> String {
    format!("{}000001", new_id_seed())
}

impl Tracker {
    pub fn new() -> Tracker {
        Tracker { id_seed: new_id_seed(), ..Default::default() }
    }

    pub fn id_seed(&self) -> &str {
        &self.id_seed
    }

    pub fn set_id_seed(&mut self, seed: &str) {
        self.id_seed = seed.to_string();
        self.id_increment = 0;
    }

    fn new_id(&mut self) -> String {
        self.id_increment += 1;
        format!("{}{:06x}", self.id_seed, self.id_increment)
    }

    pub fn comment(&self, id: &str) -> Option<&Comment> {
        self.comments.iter().find(|c| c.id == id)
    }

    pub fn remove_comment(&mut self, id: &str) {
        self.comments.retain(|c| c.id != id);
    }

    pub fn remove_changes(&mut self, ids: &[String]) {
        self.changes.retain(|c| !ids.contains(&c.id));
    }

    /// Applies one component that has just been applied to the doc.
    pub fn apply(&mut self, op: &TOp, meta: &Meta) -> Result<(), String> {
        match op {
            TOp::Insert { p, i, u } => {
                self.insert_to_changes(*p, i, *u, meta);
                self.insert_to_comments(*p, i);
            }
            TOp::Delete { p, d } => {
                let d2 = d.clone();
                self.delete_to_changes(*p, d, meta)?;
                self.delete_to_comments(*p, &d2)?;
            }
            TOp::Comment { p, c, t } => self.add_comment(*p, c, t, meta),
        }
        Ok(())
    }

    fn add_comment(&mut self, p: usize, c: &[u16], t: &str, meta: &Meta) {
        if let Some(existing) = self.comments.iter_mut().find(|x| x.id == t) {
            existing.p = p;
            existing.c = c.to_vec();
        } else {
            self.comments.push(Comment { id: t.to_string(), p, c: c.to_vec(), meta: meta.clone() });
        }
    }

    fn insert_to_comments(&mut self, p: usize, i: &[u16]) {
        for c in &mut self.comments {
            if p <= c.p {
                c.p += i.len();
            } else if p < c.p + c.c.len() {
                let off = p - c.p;
                c.c = cat(&[&c.c[..off], i, &c.c[off..]]);
            }
        }
    }

    fn delete_to_comments(&mut self, p: usize, d: &[u16]) -> Result<(), String> {
        let (op_start, op_len) = (p, d.len());
        let op_end = p + op_len;
        for c in &mut self.comments {
            let (cs, ce) = (c.p, c.p + c.c.len());
            if op_end <= cs {
                c.p -= op_len;
            } else if op_start >= ce {
            } else {
                let before = if op_start <= cs { vec![] } else { slice(&c.c, 0, op_start - cs) };
                let after = if op_end >= ce { vec![] } else { slice(&c.c, op_end - cs, c.c.len()) };
                let deleted = slice(&c.c, before.len(), c.c.len() - after.len());
                let offset = cs.saturating_sub(op_start);
                let from_op = slice(&slice(d, offset, d.len()), 0, deleted.len());
                if deleted != from_op {
                    return Err("deleted content does not match comment content".into());
                }
                c.p = cs.min(op_start);
                c.c = cat(&[&before, &after]);
            }
        }
        Ok(())
    }

    fn insert_to_changes(&mut self, op_start: usize, op_i: &[u16], undoing: bool, meta: &Meta) {
        let op_len = op_i.len();
        let op_end = op_start + op_len;
        let mut already_merged = false;
        // Indexes into self.changes; `previous` is the change looked at last.
        let mut previous: Option<usize> = None;
        let mut remove: Vec<usize> = vec![];
        let mut new_changes: Vec<(usize, Vec<u16>, Meta)> = vec![];
        let mut deletes_at_op: Vec<usize> = vec![];
        let n = self.changes.len();
        for k in 0..n {
            let change_start = self.changes[k].p;
            if let Some(d) = self.changes[k].del().cloned() {
                if op_start < change_start {
                    self.changes[k].p += op_len;
                } else if op_start == change_start {
                    if !already_merged && undoing && d.len() >= op_len && d[..op_len] == *op_i {
                        let rest = d[op_len..].to_vec();
                        self.changes[k].p += op_len;
                        if rest.is_empty() {
                            remove.push(k);
                        }
                        self.changes[k].kind = Kind::Delete(rest);
                        already_merged = true;
                        for &j in &deletes_at_op {
                            self.changes[j].p -= op_len;
                        }
                    } else {
                        self.changes[k].p += op_len;
                        if !already_merged {
                            deletes_at_op.push(k);
                        }
                    }
                }
            } else if let Some(ci) = self.changes[k].ins().cloned() {
                let change_end = change_start + ci.len();
                let overlapping = op_start >= change_start && op_start <= change_end;
                let same_user = meta.user_id == self.changes[k].meta.user_id;
                let next = self.changes.get(k + 1);
                let adjacent_next_delete =
                    next.is_some_and(|nx| nx.del().is_some() && op_start == change_end && nx.p == op_start);
                let cancels_next_delete = undoing
                    && adjacent_next_delete
                    && next.and_then(|nx| nx.del()).is_some_and(|nd| slice(nd, 0, op_len) == op_i);
                let blocked_by_delete =
                    previous.is_some_and(|pi| self.changes[pi].del().is_some() && self.changes[pi].p == op_end);
                if self.track_changes && overlapping && !blocked_by_delete && !already_merged && !cancels_next_delete && same_user {
                    let off = op_start - change_start;
                    let merged = cat(&[&ci[..off], op_i, &ci[off..]]);
                    self.changes[k].kind = Kind::Insert(merged);
                    self.changes[k].meta.ts = pick_ts(&self.changes[k].meta.ts, &meta.ts);
                    already_merged = true;
                } else if op_start <= change_start {
                    self.changes[k].p += op_len;
                } else if (!same_user || !self.track_changes) && change_start < op_start && op_start < change_end {
                    let off = op_start - change_start;
                    let before = ci[..off].to_vec();
                    let after = ci[off..].to_vec();
                    self.changes[k].kind = Kind::Insert(before);
                    new_changes.push((change_start + off + op_len, after, self.changes[k].meta.clone()));
                }
            }
            previous = Some(k);
        }
        // Removals by index first (the indexes above refer to the list before any additions).
        let removed: Vec<String> = remove.iter().map(|&k| self.changes[k].id.clone()).collect();
        if self.track_changes && !already_merged {
            self.add_change(op_start, Kind::Insert(op_i.to_vec()), meta.clone());
        }
        for (p, i, m) in new_changes {
            self.add_change(p, Kind::Insert(i), m);
        }
        self.changes.retain(|c| !removed.contains(&c.id));
    }

    fn delete_to_changes(&mut self, op_p: usize, op_d: &[u16], meta: &Meta) -> Result<(), String> {
        let op_start = op_p;
        let op_len = op_d.len();
        let op_end = op_start + op_len;
        let mut remove: Vec<usize> = vec![];
        // Modifications to the delete: insert `i` at `p`, or delete `d` at `p`, positions within op_d.
        enum Modi {
            I(usize, Vec<u16>),
            D(usize, Vec<u16>),
        }
        let mut mods: Vec<Modi> = vec![];
        for k in 0..self.changes.len() {
            let change_start = self.changes[k].p;
            if let Some(ci) = self.changes[k].ins().cloned() {
                let change_end = change_start + ci.len();
                if op_end <= change_start {
                    self.changes[k].p -= op_len;
                } else if op_start >= change_end {
                } else {
                    let (del_before, ins_before) = if op_start >= change_start {
                        (vec![], slice(&ci, 0, op_start - change_start))
                    } else {
                        (slice(op_d, 0, change_start - op_start), vec![])
                    };
                    let (del_after, ins_after) = if op_end <= change_end {
                        (vec![], slice(&ci, op_end - change_start, ci.len()))
                    } else {
                        (slice(op_d, change_end - op_start, op_d.len()), vec![])
                    };
                    let remaining = cat(&[&ins_before, &ins_after]);
                    if !remaining.is_empty() {
                        self.changes[k].kind = Kind::Insert(remaining);
                        self.changes[k].p = change_start.min(op_start);
                    } else {
                        remove.push(k);
                    }
                    let removed_len = op_d.len() - del_before.len() - del_after.len();
                    let start = del_before.len();
                    let d = slice(op_d, start, start + removed_len);
                    if !d.is_empty() {
                        mods.push(Modi::D(start, d));
                    }
                }
            } else if let Some(cd) = self.changes[k].del().cloned() {
                if op_end < change_start || (!self.track_changes && op_end == change_start) {
                    self.changes[k].p -= op_len;
                } else if op_start <= change_start && change_start <= op_end {
                    if self.track_changes {
                        mods.push(Modi::I(change_start - op_start, cd));
                        remove.push(k);
                    } else {
                        self.changes[k].p = op_start;
                    }
                }
            }
        }
        // Apply the modifications in descending position, deletes first at equal positions.
        mods.sort_by(|a, b| {
            let (pa, ia) = match a {
                Modi::I(p, _) => (*p, true),
                Modi::D(p, _) => (*p, false),
            };
            let (pb, ib) = match b {
                Modi::I(p, _) => (*p, true),
                Modi::D(p, _) => (*p, false),
            };
            pb.cmp(&pa).then(match (ia, ib) {
                (true, false) => std::cmp::Ordering::Greater,
                (false, true) => std::cmp::Ordering::Less,
                _ => std::cmp::Ordering::Equal,
            })
        });
        let mut content = op_d.to_vec();
        for m in mods {
            match m {
                Modi::I(p, i) => content = cat(&[&slice(&content, 0, p), &i, &slice(&content, p, content.len())]),
                Modi::D(p, d) => {
                    if slice(&content, p, p + d.len()) != d {
                        return Err("deletion does not match text in document".into());
                    }
                    content = cat(&[&slice(&content, 0, p), &slice(&content, p + d.len(), content.len())]);
                }
            }
        }
        let mut op_d_now = content;
        let mut gone: Vec<String> = vec![];
        for &k in &remove {
            let c = &mut self.changes[k];
            let is_del_overlapping =
                !op_d_now.is_empty() && c.del().is_some() && op_start <= c.p && c.p <= op_start + op_d_now.len();
            if is_del_overlapping {
                c.p = op_start;
                c.kind = Kind::Delete(op_d_now.clone());
                c.meta = meta.clone();
                op_d_now.clear();
            } else {
                gone.push(c.id.clone());
            }
        }
        self.changes.retain(|c| !gone.contains(&c.id));
        if self.track_changes && !op_d_now.is_empty() {
            self.add_change(op_start, Kind::Delete(op_d_now), meta.clone());
        } else {
            self.merge_adjacent();
        }
        Ok(())
    }

    fn add_change(&mut self, p: usize, kind: Kind, meta: Meta) {
        let id = self.new_id();
        self.changes.push(Change { id, p, kind, meta });
        // Stable sort by position, deletes before inserts at the same position (as JS's Array.sort, stable).
        self.changes.sort_by(|a, b| {
            a.p.cmp(&b.p).then(match (a.ins().is_some(), b.ins().is_some()) {
                (true, false) => std::cmp::Ordering::Greater,
                (false, true) => std::cmp::Ordering::Less,
                _ => std::cmp::Ordering::Equal,
            })
        });
    }

    fn merge_adjacent(&mut self) {
        let mut prev: Option<usize> = None;
        let mut remove: Vec<usize> = vec![];
        for k in 0..self.changes.len() {
            if let Some(pi) = prev {
                let (a, b) = (&self.changes[pi], &self.changes[k]);
                if let (Some(ai), Some(bi)) = (a.ins(), b.ins()) {
                    if a.p + ai.len() == b.p && a.meta.user_id == b.meta.user_id {
                        let merged = cat(&[ai, bi]);
                        let ts = pick_ts(&a.meta.ts, &b.meta.ts);
                        self.changes[pi].kind = Kind::Insert(merged);
                        self.changes[pi].meta.ts = ts;
                        remove.push(k);
                    }
                    // JS quirk: after two inserts, merged or not, `previousChange` stays the earlier one.
                    continue;
                } else if let (Some(ad), Some(bd)) = (a.del(), b.del()) {
                    if a.p == b.p {
                        let merged = cat(&[ad, bd]);
                        self.changes[pi].kind = Kind::Delete(merged);
                        remove.push(k);
                        continue;
                    }
                }
            }
            prev = Some(k);
        }
        let mut k = 0;
        self.changes.retain(|_| {
            k += 1;
            !remove.contains(&(k - 1))
        });
    }

    #[cfg_attr(not(test), allow(dead_code))]
    /// The ranges as Overleaf's `joinDoc` gives them: `{changes: [{id, op: {p, i|d}, metadata}], comments: [...]}`.
    pub fn to_json(&self) -> Value {
        let meta = |m: &Meta| json!({"user_id": m.user_id, "ts": m.ts});
        let changes: Vec<Value> = self
            .changes
            .iter()
            .map(|c| {
                let op = match &c.kind {
                    Kind::Insert(i) => json!({"p": c.p, "i": string(i)}),
                    Kind::Delete(d) => json!({"p": c.p, "d": string(d)}),
                };
                json!({"id": c.id, "op": op, "metadata": meta(&c.meta)})
            })
            .collect();
        let comments: Vec<Value> = self
            .comments
            .iter()
            .map(|c| json!({"id": c.id, "op": {"p": c.p, "c": string(&c.c), "t": c.id}, "metadata": meta(&c.meta)}))
            .collect();
        json!({"changes": changes, "comments": comments})
    }

    /// Reads `joinDoc`'s ranges (already decoded from the Latin-1 packing).
    pub fn from_json(v: &Value) -> Tracker {
        let mut t = Tracker::new();
        let meta = |m: Option<&Value>| Meta {
            user_id: m.and_then(|m| m.get("user_id")).and_then(Value::as_str).map(String::from),
            ts: m.and_then(|m| m.get("ts")).cloned().filter(|v| !v.is_null()),
        };
        for c in v.get("changes").and_then(Value::as_array).into_iter().flatten() {
            let (Some(id), Some(op)) = (c.get("id").and_then(Value::as_str), c.get("op")) else { continue };
            let p = op.get("p").and_then(Value::as_u64).unwrap_or(0) as usize;
            let kind = match (op.get("i").and_then(Value::as_str), op.get("d").and_then(Value::as_str)) {
                (Some(i), _) => Kind::Insert(u16s(i)),
                (None, Some(d)) => Kind::Delete(u16s(d)),
                _ => continue,
            };
            t.changes.push(Change { id: id.into(), p, kind, meta: meta(c.get("metadata")) });
        }
        for c in v.get("comments").and_then(Value::as_array).into_iter().flatten() {
            let Some(op) = c.get("op") else { continue };
            let id = c.get("id").or(op.get("t")).and_then(Value::as_str).unwrap_or("").to_string();
            let p = op.get("p").and_then(Value::as_u64).unwrap_or(0) as usize;
            let text = op.get("c").and_then(Value::as_str).unwrap_or("");
            t.comments.push(Comment { id, p, c: u16s(text), meta: meta(c.get("metadata")) });
        }
        t
    }
}

pub fn ts_ms(v: &Value) -> Option<f64> {
    match v {
        Value::Number(n) => n.as_f64(),
        Value::String(s) => parse_iso_ms(s),
        _ => None,
    }
}

/// Milliseconds since 1970 of an ISO 8601 UTC time such as `2026-11-02T14:06:54.150Z`.
pub fn parse_iso_ms(s: &str) -> Option<f64> {
    let b = s.as_bytes();
    if b.len() < 19 {
        return None;
    }
    let n = |a: usize, l: usize| s.get(a..a + l)?.parse::<i64>().ok();
    let (y, mo, d, h, mi, se) = (n(0, 4)?, n(5, 2)?, n(8, 2)?, n(11, 2)?, n(14, 2)?, n(17, 2)?);
    let frac = s.get(19..).and_then(|r| r.strip_prefix('.')).map(|r| r.trim_end_matches('Z')).unwrap_or("");
    let ms = if frac.is_empty() { 0.0 } else { format!("0.{frac}").parse::<f64>().ok()? * 1000.0 };
    // days from civil (Howard Hinnant)
    let y2 = if mo <= 2 { y - 1 } else { y };
    let era = y2.div_euclid(400);
    let yoe = y2 - era * 400;
    let doy = (153 * (if mo > 2 { mo - 3 } else { mo + 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146097 + doe - 719468;
    Some(((days * 86400 + h * 3600 + mi * 60 + se) * 1000) as f64 + ms)
}

/// The earlier of two timestamps; a missing one never wins (`pickTimestamp`).
fn pick_ts(old: &Option<Value>, new: &Option<Value>) -> Option<Value> {
    match (old, new) {
        (None, n) => n.clone(),
        (o, None) => o.clone(),
        (Some(o), Some(n)) => match (ts_ms(o), ts_ms(n)) {
            (Some(a), Some(b)) if a < b => Some(o.clone()),
            (Some(_), Some(_)) => Some(n.clone()),
            _ => Some(n.clone()),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn m(u: &str) -> Meta {
        Meta { user_id: Some(u.into()), ts: None }
    }
    fn ins(p: usize, s: &str) -> TOp {
        TOp::Insert { p, i: u16s(s), u: false }
    }
    fn del(p: usize, s: &str) -> TOp {
        TOp::Delete { p, d: u16s(s) }
    }

    #[test]
    fn comment_moves_and_grows() {
        let mut t = Tracker::new();
        t.apply(&TOp::Comment { p: 4, c: u16s("brave"), t: "t1".into() }, &m("a")).unwrap();
        t.apply(&ins(0, "XX"), &m("a")).unwrap();
        assert_eq!((t.comments[0].p, string(&t.comments[0].c)), (6, "brave".into()));
        t.apply(&ins(8, "--"), &m("a")).unwrap();
        assert_eq!(string(&t.comments[0].c), "br--ave");
        // An insert at the end is outside, at the start it pushes the comment along.
        t.apply(&ins(13, "!"), &m("a")).unwrap();
        assert_eq!(string(&t.comments[0].c), "br--ave");
        t.apply(&del(5, "Xb"), &m("a")).unwrap();
        assert_eq!((t.comments[0].p, string(&t.comments[0].c)), (5, "r--ave".into()));
    }

    #[test]
    fn delete_with_wrong_text_is_an_error() {
        let mut t = Tracker::new();
        t.apply(&TOp::Comment { p: 0, c: u16s("abc"), t: "t1".into() }, &m("a")).unwrap();
        assert!(t.apply(&del(1, "zz"), &m("a")).is_err());
    }

    #[test]
    fn tracked_insert_then_delete_inside_it_cancels() {
        let mut t = Tracker::new();
        t.set_id_seed("bbbbbbbbbbbbbbbbbb");
        t.track_changes = true;
        t.apply(&ins(0, "TRACKED "), &m("a")).unwrap();
        assert_eq!(t.changes[0].id, "bbbbbbbbbbbbbbbbbb000001");
        t.apply(&del(0, "TRA"), &m("a")).unwrap();
        assert_eq!(t.changes.len(), 1);
        assert_eq!(t.changes[0].kind, Kind::Insert(u16s("CKED ")));
        // Same user types inside: merged.
        t.apply(&ins(2, "zz"), &m("a")).unwrap();
        assert_eq!(t.changes[0].kind, Kind::Insert(u16s("CKzzED ")));
        // Another user splits it.
        t.apply(&ins(1, "Q"), &m("b")).unwrap();
        let kinds: Vec<_> = t.changes.iter().map(|c| (c.p, c.kind.clone())).collect();
        assert_eq!(kinds[0], (0, Kind::Insert(u16s("C"))));
        assert!(kinds.contains(&(1, Kind::Insert(u16s("Q")))));
        assert!(kinds.contains(&(2, Kind::Insert(u16s("KzzED ")))));
    }

    #[test]
    fn tracked_delete_and_undo_reinsert_removes_it() {
        let mut t = Tracker::new();
        t.track_changes = true;
        t.apply(&del(5, "brave "), &m("a")).unwrap();
        assert_eq!(t.changes[0].kind, Kind::Delete(u16s("brave ")));
        t.track_changes = false;
        t.apply(&TOp::Insert { p: 5, i: u16s("brave "), u: true }, &m("a")).unwrap();
        assert!(t.changes.is_empty());
    }

    #[test]
    fn untracked_delete_over_tracked_delete_moves_it() {
        let mut t = Tracker::new();
        t.track_changes = true;
        t.apply(&del(5, "xy"), &m("a")).unwrap();
        t.track_changes = false;
        t.apply(&del(2, "abc"), &m("a")).unwrap();
        assert_eq!(t.changes[0].p, 2);
    }

    #[test]
    fn iso_time() {
        assert_eq!(parse_iso_ms("1970-01-01T00:00:01.500Z"), Some(1500.0));
        assert_eq!(parse_iso_ms("2026-11-02T14:06:54.150Z"), Some(1_793_628_414_150.0));
    }

    #[test]
    fn json_round_trip() {
        let v = json!({"changes": [{"id": "c1", "op": {"p": 0, "i": "Größe"}, "metadata": {"user_id": "u", "ts": "2026-11-02T14:06:54.150Z"}},
            {"id": "c2", "op": {"p": 9, "d": "x"}, "metadata": {"user_id": "u"}}],
            "comments": [{"id": "t1", "op": {"p": 2, "c": "öß", "t": "t1"}, "metadata": {}}]});
        let t = Tracker::from_json(&v);
        assert_eq!(t.changes.len(), 2);
        assert_eq!(t.to_json()["comments"][0]["op"]["c"], "öß");
    }

    /// Differential test against Overleaf's own `RangesTracker`. Set `TAUDOT_RANGES_JS` to its `index.cjs` (in an
    /// Overleaf CE source checkout) and have `node` on the PATH; skipped otherwise.
    #[test]
    fn matches_overleaf_ranges_tracker() {
        let Ok(js) = std::env::var("TAUDOT_RANGES_JS") else {
            eprintln!("TAUDOT_RANGES_JS not set; skipping the differential test");
            return;
        };
        let seed: u64 = std::env::var("TAUDOT_FUZZ_SEED").ok().and_then(|s| s.parse().ok()).unwrap_or(1);
        let rounds: usize = std::env::var("TAUDOT_FUZZ_ROUNDS").ok().and_then(|s| s.parse().ok()).unwrap_or(300);
        let mut rng = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        let mut next = move |n: usize| {
            rng ^= rng << 13;
            rng ^= rng >> 7;
            rng ^= rng << 17;
            (rng % n.max(1) as u64) as usize
        };
        let mut cases = vec![];
        let mut expected = vec![];
        for _ in 0..rounds {
            let mut doc: Vec<u16> = u16s("the quick brown fox jumps over the lazy dog");
            let mut t = Tracker::new();
            t.set_id_seed("aaaaaaaaaaaaaaaaaa");
            let mut steps = vec![];
            let users = ["u1", "u2"];
            for s in 0..12 {
                let user = users[next(2)];
                let track = next(3) > 0;
                let undo = next(4) == 0;
                let kind = next(5);
                let op = if kind == 0 && doc.len() > 2 {
                    let p = next(doc.len() - 1);
                    let l = 1 + next((doc.len() - p).min(6));
                    TOp::Comment { p, c: slice(&doc, p, p + l), t: format!("t{s}") }
                } else if kind <= 2 || doc.len() < 4 {
                    let p = next(doc.len() + 1);
                    let i: Vec<u16> = u16s(["ab", "X", "hello ", "é", "q"][next(5)]);
                    TOp::Insert { p, i, u: undo }
                } else {
                    let p = next(doc.len() - 1);
                    let l = 1 + next((doc.len() - p).min(5));
                    TOp::Delete { p, d: slice(&doc, p, p + l) }
                };
                match &op {
                    TOp::Insert { p, i, .. } => doc = cat(&[&doc[..*p], i, &doc[*p..]]),
                    TOp::Delete { p, d } => doc = cat(&[&doc[..*p], &doc[*p + d.len()..]]),
                    TOp::Comment { .. } => {}
                }
                let opj = match &op {
                    TOp::Insert { p, i, u } => json!({"p": p, "i": string(i), "u": u}),
                    TOp::Delete { p, d } => json!({"p": p, "d": string(d)}),
                    TOp::Comment { p, c, t } => json!({"p": p, "c": string(c), "t": t}),
                };
                t.track_changes = track;
                let meta = Meta { user_id: Some(user.into()), ts: Some(json!(1000 + s)) };
                if t.apply(&op, &meta).is_err() {
                    break;
                }
                steps.push(json!({"op": opj, "track": track, "user": user, "ts": 1000 + s}));
            }
            cases.push(json!(steps));
            expected.push(t.to_json());
        }
        let script = format!(
            r#"const RT = require({js:?});
const cases = JSON.parse(require('fs').readFileSync(0, 'utf8'));
const out = cases.map(steps => {{
  const t = new RT(); t.setIdSeed('aaaaaaaaaaaaaaaaaa');
  for (const s of steps) {{
    t.track_changes = s.track;
    const op = {{...s.op}}; if (!op.u) delete op.u;
    try {{ t.applyOp(op, {{user_id: s.user, ts: s.ts}}) }} catch (e) {{ break }}
  }}
  return {{changes: t.changes.map(c => ({{id: c.id, op: c.op, metadata: {{user_id: c.metadata.user_id ?? null, ts: c.metadata.ts ?? null}}}})),
          comments: t.comments.map(c => ({{id: c.id, op: {{p: c.op.p, c: c.op.c, t: c.id}}, metadata: {{user_id: c.metadata.user_id ?? null, ts: c.metadata.ts ?? null}}}}))}}
}});
process.stdout.write(JSON.stringify(out));"#
        );
        let dir = std::env::temp_dir().join(format!("taudot-ranges-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("diff.cjs");
        std::fs::write(&path, script).unwrap();
        let mut child = std::process::Command::new("node")
            .arg(&path)
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .expect("node");
        use std::io::Write;
        child.stdin.take().unwrap().write_all(json!(cases).to_string().as_bytes()).unwrap();
        let out = child.wait_with_output().unwrap();
        let got: Vec<Value> = serde_json::from_slice(&out.stdout).expect("node output");
        let norm = |v: &Value| {
            // JS keeps `u` on the op it stored; compare only p/i/d/c and metadata.
            let mut v = v.clone();
            for c in v["changes"].as_array_mut().unwrap() {
                c["op"].as_object_mut().unwrap().remove("u");
            }
            v
        };
        let mut bad = 0;
        for (k, (g, e)) in got.iter().zip(&expected).enumerate() {
            if norm(g) != norm(e) {
                if bad < 3 {
                    eprintln!("case {k}: steps {}\n js:   {}\n rust: {}", cases[k], norm(g), norm(e));
                }
                bad += 1;
            }
        }
        assert_eq!(bad, 0, "{bad} of {rounds} cases differ from Overleaf's RangesTracker");
    }
}
