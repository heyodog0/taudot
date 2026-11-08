//! A history-ot doc as the server keeps it (`StringFileData`): the full content, tracked-deleted text included, plus
//! comments and tracked changes as ranges over it. [`FileData::apply`] moves the ranges the way CE 6.3's server does,
//! as observed with `harness/tests/historyot-ranges.ts` (fixture `fixtures/historyot_ranges.json`):
//!
//! - An insert at a range's start goes before it, one strictly inside splits it, one at its end stays outside.
//! - A remove cuts what it covers out of every range. A comment left with no ranges is kept, with none.
//! - A retain with tracking replaces whatever tracking its span had (`none` just clears it). An insert with tracking
//!   adds a tracked range; with `commentIds` it adds itself to those comments.
//! - Neighbouring ranges merge: a comment's ranges always; tracked changes when kind and user match, keeping the
//!   earlier `ts`.
//!
//! It also maps between the content and the *visible* text (content without tracked-deleted text), which is what
//! Overleaf's editor shows and what the engine edits: [`FileData::apply_projected`] turns an incoming update into the
//! classic op it makes on the visible text, and [`FileData::to_wire`] turns a classic op on the visible text into
//! the update to send. [`transform`] transforms two updates' edit operations past each other, the client's first on
//! equal positions, as the server does (`docs/protocol.md`, history-ot).
//!
//! Written from protocol.md and CE observations; positions are UTF-16 code units.

use serde_json::{json, Value};

use crate::history::{EditOperation, Range, ScanOp, TextOperation, Tracking, TrackingKind, TrackingProps};
use crate::text::{self, Component, Op};
use crate::units::{slice16, split16, utf16_len};
use crate::OtError;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Comment {
    pub id: String,
    pub ranges: Vec<Range>,
    pub resolved: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TrackedChange {
    pub range: Range,
    pub tracking: TrackingProps,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct FileData {
    pub content: String,
    pub comments: Vec<Comment>,
    pub tracked: Vec<TrackedChange>,
}

fn end(r: &Range) -> usize {
    r.pos + r.length
}

/// Where a position goes after `len` units are inserted at `p`, for a range edge: `start` edges at `p` move, end
/// edges at `p` stay.
fn shift_insert(x: usize, p: usize, len: usize, start: bool) -> usize {
    if x > p || (x == p && start) {
        x + len
    } else {
        x
    }
}

/// Ranges after inserting `len` units at `p`: before a range's start it moves, strictly inside it splits.
fn insert_ranges(rs: &[Range], p: usize, len: usize) -> Vec<Range> {
    let mut out = Vec::with_capacity(rs.len() + 1);
    for r in rs {
        if p > r.pos && p < end(r) {
            out.push(Range { pos: r.pos, length: p - r.pos });
            out.push(Range { pos: p + len, length: end(r) - p });
        } else {
            let a = shift_insert(r.pos, p, len, true);
            out.push(Range { pos: a, length: r.length });
        }
    }
    out
}

/// A position after removing `[p, p + n)`.
fn shift_remove(x: usize, p: usize, n: usize) -> usize {
    if x <= p {
        x
    } else if x >= p + n {
        x - n
    } else {
        p
    }
}

fn remove_ranges(rs: &[Range], p: usize, n: usize) -> Vec<Range> {
    rs.iter()
        .filter_map(|r| {
            let (a, b) = (shift_remove(r.pos, p, n), shift_remove(end(r), p, n));
            (b > a).then_some(Range { pos: a, length: b - a })
        })
        .collect()
}

/// Sorted, with overlapping and touching ranges merged.
fn merge_ranges(mut rs: Vec<Range>) -> Vec<Range> {
    rs.retain(|r| r.length > 0);
    rs.sort_by_key(|r| r.pos);
    let mut out: Vec<Range> = Vec::with_capacity(rs.len());
    for r in rs {
        match out.last_mut() {
            Some(l) if r.pos <= end(l) => l.length = end(l).max(end(&r)) - l.pos,
            _ => out.push(r),
        }
    }
    out
}

fn same_author(a: &TrackingProps, b: &TrackingProps) -> bool {
    a.kind == b.kind && a.user_id == b.user_id
}

impl FileData {
    pub fn new(content: impl Into<String>) -> FileData {
        FileData { content: content.into(), ..Default::default() }
    }

    /// From `joinDoc`'s history-ot snapshot, `{content, comments?, trackedChanges?}`.
    pub fn from_json(v: &Value) -> Result<FileData, String> {
        let content = v.get("content").and_then(Value::as_str).ok_or("snapshot has no content")?.to_owned();
        let range = |r: &Value| -> Option<Range> {
            Some(Range { pos: r.get("pos")?.as_u64()? as usize, length: r.get("length")?.as_u64()? as usize })
        };
        let mut comments = vec![];
        for c in v.get("comments").and_then(Value::as_array).into_iter().flatten() {
            let id = c.get("id").and_then(Value::as_str).ok_or("comment without id")?.to_owned();
            let ranges = c.get("ranges").and_then(Value::as_array).into_iter().flatten().filter_map(range).collect();
            let resolved = c.get("resolved").and_then(Value::as_bool).unwrap_or(false);
            comments.push(Comment { id, ranges, resolved });
        }
        let mut tracked = vec![];
        for t in v.get("trackedChanges").and_then(Value::as_array).into_iter().flatten() {
            let r = t.get("range").and_then(range).ok_or("tracked change without range")?;
            let tr = t.get("tracking").ok_or("tracked change without tracking")?;
            let kind = match tr.get("type").and_then(Value::as_str) {
                Some("insert") => TrackingKind::Insert,
                Some("delete") => TrackingKind::Delete,
                other => return Err(format!("unknown tracked change type {other:?}")),
            };
            let s = |k: &str| tr.get(k).and_then(Value::as_str).unwrap_or("").to_owned();
            tracked.push(TrackedChange { range: r, tracking: TrackingProps { kind, user_id: s("userId"), ts: s("ts") } });
        }
        Ok(FileData { content, comments, tracked })
    }

    pub fn to_json(&self) -> Value {
        let r = |r: &Range| json!({"pos": r.pos, "length": r.length});
        let comments: Vec<Value> = self
            .comments
            .iter()
            .map(|c| {
                let mut v = json!({"id": c.id, "ranges": c.ranges.iter().map(r).collect::<Vec<_>>()});
                if c.resolved {
                    v["resolved"] = json!(true);
                }
                v
            })
            .collect();
        let tracked: Vec<Value> = self
            .tracked
            .iter()
            .map(|t| {
                let kind = if t.tracking.kind == TrackingKind::Insert { "insert" } else { "delete" };
                json!({"range": r(&t.range), "tracking": {"type": kind, "userId": t.tracking.user_id, "ts": t.tracking.ts}})
            })
            .collect();
        json!({"content": self.content, "comments": comments, "trackedChanges": tracked})
    }

    // ---- applying updates ------------------------------------------------------------------------------------------

    /// Applies one edit operation.
    pub fn apply(&mut self, op: &EditOperation) -> Result<(), OtError> {
        match op {
            EditOperation::Text(t) => self.apply_text(t),
            EditOperation::AddComment { comment_id, ranges, resolved } => {
                let ranges = merge_ranges(ranges.clone());
                match self.comments.iter_mut().find(|c| &c.id == comment_id) {
                    Some(c) => {
                        c.ranges = ranges;
                        c.resolved = *resolved;
                    }
                    None => self.comments.push(Comment { id: comment_id.clone(), ranges, resolved: *resolved }),
                }
                Ok(())
            }
            EditOperation::DeleteComment { comment_id } => {
                self.comments.retain(|c| &c.id != comment_id);
                Ok(())
            }
            EditOperation::SetCommentState { comment_id, resolved } => {
                if let Some(c) = self.comments.iter_mut().find(|c| &c.id == comment_id) {
                    c.resolved = *resolved;
                }
                Ok(())
            }
            EditOperation::NoOp => Ok(()),
        }
    }

    pub fn apply_all(&mut self, ops: &[EditOperation]) -> Result<(), OtError> {
        ops.iter().try_for_each(|o| self.apply(o))
    }

    fn apply_text(&mut self, t: &TextOperation) -> Result<(), OtError> {
        let content = t.apply(&self.content)?;
        if t.ops.iter().any(|o| matches!(o, ScanOp::Insert { tracking: Some(Tracking::Clear), .. })) {
            // The server refuses these ("Invalid input").
            return Err(OtError::LengthMismatch);
        }
        let mut pos = 0;
        for o in &t.ops {
            match o {
                ScanOp::Retain { n, tracking } => {
                    if let Some(tr) = tracking {
                        self.set_tracking(pos, *n, tr);
                    }
                    pos += n;
                }
                ScanOp::Insert { text, tracking, comment_ids } => {
                    let len = utf16_len(text);
                    self.insert_at(pos, len);
                    if let Some(Tracking::Set(p)) = tracking {
                        self.tracked.push(TrackedChange { range: Range { pos, length: len }, tracking: p.clone() });
                        self.merge_tracked();
                    }
                    for id in comment_ids.iter().flatten() {
                        if let Some(c) = self.comments.iter_mut().find(|c| &c.id == id) {
                            c.ranges.push(Range { pos, length: len });
                            c.ranges = merge_ranges(std::mem::take(&mut c.ranges));
                        }
                    }
                    pos += len;
                }
                ScanOp::Remove { n } => self.remove_at(pos, *n),
            }
        }
        self.content = content;
        Ok(())
    }

    fn insert_at(&mut self, p: usize, len: usize) {
        for c in &mut self.comments {
            c.ranges = merge_ranges(insert_ranges(&c.ranges, p, len));
        }
        let mut out = Vec::with_capacity(self.tracked.len() + 1);
        for t in &self.tracked {
            for r in insert_ranges(std::slice::from_ref(&t.range), p, len) {
                out.push(TrackedChange { range: r, tracking: t.tracking.clone() });
            }
        }
        self.tracked = out;
    }

    fn remove_at(&mut self, p: usize, n: usize) {
        for c in &mut self.comments {
            c.ranges = merge_ranges(remove_ranges(&c.ranges, p, n));
        }
        let mut out = Vec::with_capacity(self.tracked.len());
        for t in &self.tracked {
            for r in remove_ranges(std::slice::from_ref(&t.range), p, n) {
                out.push(TrackedChange { range: r, tracking: t.tracking.clone() });
            }
        }
        self.tracked = out;
        self.merge_tracked();
    }

    fn set_tracking(&mut self, p: usize, n: usize, tr: &Tracking) {
        let (a, b) = (p, p + n);
        let mut out = Vec::with_capacity(self.tracked.len() + 2);
        for t in &self.tracked {
            let (s, e) = (t.range.pos, end(&t.range));
            if e <= a || s >= b {
                out.push(t.clone());
                continue;
            }
            if s < a {
                out.push(TrackedChange { range: Range { pos: s, length: a - s }, tracking: t.tracking.clone() });
            }
            if e > b {
                out.push(TrackedChange { range: Range { pos: b, length: e - b }, tracking: t.tracking.clone() });
            }
        }
        if let Tracking::Set(props) = tr {
            out.push(TrackedChange { range: Range { pos: a, length: n }, tracking: props.clone() });
        }
        self.tracked = out;
        self.merge_tracked();
    }

    /// Sorted; touching changes by the same user and of the same kind merge, keeping the earlier `ts`.
    fn merge_tracked(&mut self) {
        let mut ts = std::mem::take(&mut self.tracked);
        ts.retain(|t| t.range.length > 0);
        ts.sort_by_key(|t| t.range.pos);
        for t in ts {
            match self.tracked.last_mut() {
                Some(l) if end(&l.range) == t.range.pos && same_author(&l.tracking, &t.tracking) => {
                    l.range.length += t.range.length;
                    if t.tracking.ts < l.tracking.ts {
                        l.tracking.ts = t.tracking.ts;
                    }
                }
                _ => self.tracked.push(t),
            }
        }
    }

    // ---- the visible text -------------------------------------------------------------------------------------------

    fn deleted(&self) -> impl Iterator<Item = &Range> {
        self.tracked.iter().filter(|t| t.tracking.kind == TrackingKind::Delete).map(|t| &t.range)
    }

    /// The content without tracked-deleted text.
    pub fn visible(&self) -> String {
        let mut out = String::with_capacity(self.content.len());
        let mut at = 0;
        for r in self.deleted() {
            out += slice16(&self.content, at, r.pos).unwrap_or("");
            at = end(r);
        }
        out += split16(&self.content, at.min(utf16_len(&self.content))).map(|(_, b)| b).unwrap_or("");
        out
    }

    /// The visible position of content position `c`: inside tracked-deleted text, where that text starts.
    pub fn to_visible(&self, c: usize) -> usize {
        let mut hidden = 0;
        for r in self.deleted() {
            if r.pos >= c {
                break;
            }
            hidden += end(r).min(c) - r.pos;
        }
        c - hidden
    }

    /// The content position for an insert at visible position `v`: before any tracked-deleted text there, as
    /// Overleaf's editor does (protocol.md, history-ot).
    pub fn to_content(&self, v: usize) -> usize {
        let mut c = v;
        for r in self.deleted() {
            if r.pos < c {
                c += r.length;
            } else {
                break;
            }
        }
        c
    }

    /// Content position of the visible character at `v` (the first visible one at or after a tracked delete).
    fn char_to_content(&self, v: usize) -> usize {
        let mut c = v;
        for r in self.deleted() {
            if r.pos <= c {
                c += r.length;
            } else {
                break;
            }
        }
        c
    }

    /// Splits content `[c, c + n)` into runs of visible and tracked-deleted text: `(length, deleted)`.
    fn runs(&self, c: usize, n: usize) -> Vec<(usize, bool)> {
        let (mut at, stop) = (c, c + n);
        let mut out = vec![];
        for r in self.deleted() {
            if end(r) <= at {
                continue;
            }
            if r.pos >= stop {
                break;
            }
            if r.pos > at {
                out.push((r.pos - at, false));
            }
            let e = end(r).min(stop);
            out.push((e - at.max(r.pos), true));
            at = e;
        }
        if at < stop {
            out.push((stop - at, false));
        }
        out
    }

    /// Applies an update and returns what it did to the visible text, as a classic op on it. Comments added become
    /// comment components over their visible span.
    pub fn apply_projected(&mut self, ops: &[EditOperation]) -> Result<Op, OtError> {
        let mut out = Op::new();
        for op in ops {
            match op {
                EditOperation::Text(t) => {
                    let vis = self.project_text(t)?;
                    self.apply_text(t)?;
                    for c in vis {
                        text::append(&mut out, c);
                    }
                }
                EditOperation::AddComment { comment_id, ranges, .. } => {
                    self.apply(op)?;
                    if let (Some(a), Some(b)) = (ranges.iter().map(|r| r.pos).min(), ranges.iter().map(end).max()) {
                        let (va, vb) = (self.to_visible(a), self.to_visible(b));
                        if vb > va {
                            let vis = self.visible();
                            let c = slice16(&vis, va, vb)?.to_owned();
                            out.push(Component::Comment { p: va, c, t: comment_id.clone() });
                        }
                    }
                }
                _ => self.apply(op)?,
            }
        }
        Ok(out)
    }

    /// The classic op a text operation makes on the visible text (before it is applied).
    fn project_text(&self, t: &TextOperation) -> Result<Op, OtError> {
        let len = utf16_len(&self.content);
        if t.base_len() != len {
            return Err(OtError::BaseLength { expected: t.base_len(), got: len });
        }
        let mut out = Op::new();
        let (mut c, mut vp) = (0usize, 0usize);
        let content = &self.content;
        let piece = |a: usize, n: usize| -> Result<String, OtError> { Ok(slice16(content, a, a + n)?.to_owned()) };
        for o in &t.ops {
            match o {
                ScanOp::Retain { n, tracking } => {
                    for (len, deleted) in self.runs(c, *n) {
                        let hide = matches!(tracking, Some(Tracking::Set(p)) if p.kind == TrackingKind::Delete);
                        let show = matches!(tracking, Some(Tracking::Clear))
                            || matches!(tracking, Some(Tracking::Set(p)) if p.kind == TrackingKind::Insert);
                        match (deleted, hide, show) {
                            (false, true, _) => text::append(&mut out, Component::Delete { p: vp, d: piece(c, len)? }),
                            (false, false, _) => vp += len,
                            (true, _, true) => {
                                text::append(&mut out, Component::Insert { p: vp, i: piece(c, len)? });
                                vp += len;
                            }
                            (true, _, false) => {}
                        }
                        c += len;
                    }
                }
                ScanOp::Insert { text, tracking, .. } => {
                    if !matches!(tracking, Some(Tracking::Set(p)) if p.kind == TrackingKind::Delete) {
                        text::append(&mut out, Component::Insert { p: vp, i: text.clone() });
                        vp += utf16_len(text);
                    }
                }
                ScanOp::Remove { n } => {
                    for (len, deleted) in self.runs(c, *n) {
                        if !deleted {
                            text::append(&mut out, Component::Delete { p: vp, d: piece(c, len)? });
                        }
                        c += len;
                    }
                }
            }
        }
        Ok(out)
    }

    /// The update for a classic op on the visible text. With `track`, inserts are tracked and deletes become tracked
    /// deletes (the text stays in the content). Comment components become `AddComment`s.
    pub fn to_wire(&self, op: &[Component], track: Option<(&str, &str)>) -> Result<Vec<EditOperation>, OtError> {
        let mut w = self.clone();
        let mut out: Vec<EditOperation> = vec![];
        let props = |kind| track.map(|(user, ts)| TrackingProps { kind, user_id: user.into(), ts: ts.into() });
        for c in op {
            let len = utf16_len(&w.content);
            let e = match c {
                Component::Insert { p, i } => {
                    let at = w.to_content(*p);
                    let mut t = TextOperation::new();
                    t.retain(at, None).insert(i, props(TrackingKind::Insert).map(Tracking::Set), None)?.retain(len - at, None);
                    EditOperation::Text(t)
                }
                Component::Delete { p, d } => {
                    let at = w.char_to_content(*p);
                    let mut t = TextOperation::new();
                    t.retain(at, None);
                    let (mut c, mut left) = (at, utf16_len(d));
                    // Visible text goes (or is marked deleted); tracked-deleted text inside stays as it is.
                    for (n, deleted) in w.runs(at, len - at) {
                        if left == 0 {
                            break;
                        }
                        if deleted {
                            t.retain(n, None);
                            c += n;
                            continue;
                        }
                        let k = n.min(left);
                        match props(TrackingKind::Delete) {
                            Some(pr) => t.retain(k, Some(Tracking::Set(pr))),
                            None => t.remove(k),
                        };
                        left -= k;
                        c += k;
                    }
                    if left > 0 {
                        return Err(OtError::OutOfRange { index: p + utf16_len(d), len: utf16_len(&w.visible()) });
                    }
                    t.retain(len - c, None);
                    EditOperation::Text(t)
                }
                Component::Comment { p, c: text, t } => {
                    let n = utf16_len(text);
                    if n == 0 {
                        continue;
                    }
                    let a = w.char_to_content(*p);
                    let b = w.char_to_content(p + n - 1) + 1;
                    EditOperation::AddComment { comment_id: t.clone(), ranges: vec![Range { pos: a, length: b - a }], resolved: false }
                }
            };
            w.apply(&e)?;
            match (out.last_mut(), e) {
                (Some(EditOperation::Text(prev)), EditOperation::Text(t)) => *prev = prev.compose(&t)?,
                (_, e) => out.push(e),
            }
        }
        Ok(out)
    }
}

/// Ranges moved through a text operation, by the rules [`FileData::apply`] uses for comments.
fn map_ranges(rs: &[Range], t: &TextOperation) -> Vec<Range> {
    let mut rs = rs.to_vec();
    let mut pos = 0;
    for o in &t.ops {
        match o {
            ScanOp::Retain { n, .. } => pos += n,
            ScanOp::Insert { text, .. } => {
                let len = utf16_len(text);
                rs = insert_ranges(&rs, pos, len);
                pos += len;
            }
            ScanOp::Remove { n } => rs = remove_ranges(&rs, pos, *n),
        }
    }
    merge_ranges(rs)
}

fn transform1(a: &EditOperation, b: &EditOperation) -> Result<(EditOperation, EditOperation), OtError> {
    Ok(match (a, b) {
        (EditOperation::Text(x), EditOperation::Text(y)) => {
            let (x2, y2) = TextOperation::transform(x, y)?;
            (EditOperation::Text(x2), EditOperation::Text(y2))
        }
        (EditOperation::AddComment { comment_id, ranges, resolved }, EditOperation::Text(y)) => (
            EditOperation::AddComment { comment_id: comment_id.clone(), ranges: map_ranges(ranges, y), resolved: *resolved },
            b.clone(),
        ),
        (EditOperation::Text(x), EditOperation::AddComment { comment_id, ranges, resolved }) => (
            a.clone(),
            EditOperation::AddComment { comment_id: comment_id.clone(), ranges: map_ranges(ranges, x), resolved: *resolved },
        ),
        _ => (a.clone(), b.clone()),
    })
}

/// Transforms two concurrent updates: `(a', b')` with `a` then `b'` equal to `b` then `a'`. On equal positions `a`'s
/// inserts go first: pass the client's update as `a`, as the server does.
pub fn transform(a: &[EditOperation], b: &[EditOperation]) -> Result<(Vec<EditOperation>, Vec<EditOperation>), OtError> {
    let mut a: Vec<EditOperation> = a.to_vec();
    let mut b_out = Vec::with_capacity(b.len());
    for bi in b {
        let mut bi = bi.clone();
        let mut a_new = Vec::with_capacity(a.len());
        for ai in &a {
            let (ai2, bi2) = transform1(ai, &bi)?;
            a_new.push(ai2);
            bi = bi2;
        }
        a = a_new;
        b_out.push(bi);
    }
    Ok((a, b_out))
}

/// Edit operations as the JSON list an update's `op` holds.
pub fn ops_json(ops: &[EditOperation]) -> Value {
    Value::Array(ops.iter().map(EditOperation::to_json).collect())
}

/// An update's `op` list parsed.
pub fn ops_from_json(v: &Value) -> Result<Vec<EditOperation>, String> {
    v.as_array().ok_or("history-ot op is not a list")?.iter().map(EditOperation::from_json).collect()
}
