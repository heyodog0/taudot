//! The new format, `history-ot`, as `docs/protocol.md` describes it: a `TextOperation` covers the whole document
//! with retains, removes and inserts, and an update's op list also holds comment operations.
//!
//! The text operation is ot.js's `TextOperation` (MIT, Tim Baumann: `lib/text-operation.js`), with removes as a
//! variant instead of negative numbers, UTF-16 lengths, and the tracking and comment IDs that history-ot adds to
//! retains and inserts.

use serde::{Deserialize, Deserializer, Serialize, Serializer};
use serde_json::{json, Map, Value};

use crate::text::{self, Component, Op};
use crate::units::{split16, utf16_len};
use crate::OtError;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TrackingKind {
    Insert,
    Delete,
}

/// Who made a tracked change and when. `ts` is kept as the ISO 8601 string Overleaf sends.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TrackingProps {
    pub kind: TrackingKind,
    pub user_id: String,
    pub ts: String,
}

/// The tracking on a retain: mark the range as a tracked change, or clear tracking (accept or reject).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Tracking {
    Set(TrackingProps),
    /// `{type: "none"}`.
    Clear,
}

/// One step of a [`TextOperation`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ScanOp {
    /// Skip `n` characters. With `tracking`, mark them as a tracked change (a tracked delete keeps the text) or clear
    /// it.
    Retain { n: usize, tracking: Option<Tracking> },
    /// Insert `text`. Tracking here is always [`Tracking::Set`]; `comment_ids` puts it inside those comments.
    Insert { text: String, tracking: Option<Tracking>, comment_ids: Option<Vec<String>> },
    /// Remove the next `n` characters.
    Remove { n: usize },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Range {
    pub pos: usize,
    pub length: usize,
}

/// A text edit in the new format.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
#[allow(clippy::manual_non_exhaustive)] // a private field, kept from the old crate's API
pub struct TextOperation {
    pub ops: Vec<ScanOp>,
    /// Expected hash of the content after the op, if the sender included one.
    pub content_hash: Option<String>,
    _private: (),
}

/// One edit operation in a history-ot update's op list.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EditOperation {
    Text(TextOperation),
    /// `{commentId, ranges: [{pos, length}], resolved?}`
    AddComment { comment_id: String, ranges: Vec<Range>, resolved: bool },
    /// `{deleteComment: id}`
    DeleteComment { comment_id: String },
    /// `{commentId, resolved}`
    SetCommentState { comment_id: String, resolved: bool },
    /// `{noOp: true}`
    NoOp,
}

/// Whether two trackings can share one scan op, and what the shared one is: equal ones, or tracked changes of the same
/// kind by the same user, which keep the earlier timestamp.
fn merge_tracking(a: &Option<Tracking>, b: &Option<Tracking>) -> Option<Option<Tracking>> {
    match (a, b) {
        (Some(Tracking::Set(x)), Some(Tracking::Set(y))) if x.kind == y.kind && x.user_id == y.user_id => {
            let ts = if y.ts < x.ts { y.ts.clone() } else { x.ts.clone() };
            Some(Some(Tracking::Set(TrackingProps { ts, ..x.clone() })))
        }
        _ if a == b => Some(a.clone()),
        _ => None,
    }
}

impl TextOperation {
    pub fn new() -> Self {
        Self::default()
    }

    /// Length of the text this op applies to.
    pub fn base_len(&self) -> usize {
        self.ops
            .iter()
            .map(|o| match o {
                ScanOp::Retain { n, .. } | ScanOp::Remove { n } => *n,
                ScanOp::Insert { .. } => 0,
            })
            .sum()
    }

    /// Length of the text it produces.
    pub fn target_len(&self) -> usize {
        self.ops
            .iter()
            .map(|o| match o {
                ScanOp::Retain { n, .. } => *n,
                ScanOp::Insert { text, .. } => utf16_len(text),
                ScanOp::Remove { .. } => 0,
            })
            .sum()
    }

    /// True if it changes nothing (no ops, or one untracked retain).
    pub fn is_noop(&self) -> bool {
        matches!(self.ops.as_slice(), [] | [ScanOp::Retain { tracking: None, .. }])
    }

    pub fn retain(&mut self, n: usize, tracking: Option<Tracking>) -> &mut Self {
        if n == 0 {
            return self;
        }
        if let Some(ScanOp::Retain { n: m, tracking: t }) = self.ops.last_mut() {
            if let Some(merged) = merge_tracking(t, &tracking) {
                *m += n;
                *t = merged;
                return self;
            }
        }
        self.ops.push(ScanOp::Retain { n, tracking });
        self
    }

    /// Inserts `text`. Fails on characters outside the BMP, which Overleaf refuses.
    pub fn insert(
        &mut self,
        text: &str,
        tracking: Option<Tracking>,
        comment_ids: Option<Vec<String>>,
    ) -> Result<&mut Self, OtError> {
        if text.chars().any(|c| c.len_utf16() == 2) {
            return Err(OtError::NonBmpInsert);
        }
        if text.is_empty() {
            return Ok(self);
        }
        // An insert next to a remove goes before it, as in ot.js, so equal ops have one form.
        let at = match self.ops.last() {
            Some(ScanOp::Remove { .. }) => self.ops.len() - 1,
            _ => self.ops.len(),
        };
        if at > 0 {
            if let ScanOp::Insert { text: t, tracking: tr, comment_ids: ids } = &mut self.ops[at - 1] {
                if *ids == comment_ids {
                    if let Some(merged) = merge_tracking(tr, &tracking) {
                        t.push_str(text);
                        *tr = merged;
                        return Ok(self);
                    }
                }
            }
        }
        self.ops.insert(at, ScanOp::Insert { text: text.to_owned(), tracking, comment_ids });
        Ok(self)
    }

    pub fn remove(&mut self, n: usize) -> &mut Self {
        if n == 0 {
            return self;
        }
        if let Some(ScanOp::Remove { n: m }) = self.ops.last_mut() {
            *m += n;
        } else {
            self.ops.push(ScanOp::Remove { n });
        }
        self
    }

    fn push(&mut self, op: ScanOp) -> Result<(), OtError> {
        match op {
            ScanOp::Retain { n, tracking } => {
                self.retain(n, tracking);
            }
            ScanOp::Insert { text, tracking, comment_ids } => {
                self.insert(&text, tracking, comment_ids)?;
            }
            ScanOp::Remove { n } => {
                self.remove(n);
            }
        }
        Ok(())
    }

    /// Builds an op from scan ops, merging neighbours and dropping empty ones through the builder methods.
    pub fn from_ops(ops: impl IntoIterator<Item = ScanOp>) -> Result<Self, OtError> {
        let mut out = TextOperation::new();
        for op in ops {
            out.push(op)?;
        }
        Ok(out)
    }

    /// Applies the op to the document's full content (tracked deletes included). Tracking and comment changes are
    /// not modelled here; only the text.
    pub fn apply(&self, doc: &str) -> Result<String, OtError> {
        let len = utf16_len(doc);
        if len != self.base_len() {
            return Err(OtError::BaseLength { expected: self.base_len(), got: len });
        }
        let mut out = String::with_capacity(doc.len());
        let mut rest = doc;
        for op in &self.ops {
            match op {
                ScanOp::Retain { n, .. } => {
                    let (a, b) = split16(rest, *n)?;
                    out.push_str(a);
                    rest = b;
                }
                ScanOp::Insert { text, .. } => out.push_str(text),
                ScanOp::Remove { n } => rest = split16(rest, *n)?.1,
            }
        }
        Ok(out)
    }

    /// The op that applies `self`, then `other` (ot.js `compose`).
    pub fn compose(&self, other: &TextOperation) -> Result<TextOperation, OtError> {
        if self.target_len() != other.base_len() {
            return Err(OtError::BaseLength { expected: self.target_len(), got: other.base_len() });
        }
        let mut out = TextOperation::new();
        let mut a = Cursor::new(&self.ops);
        let mut b = Cursor::new(&other.ops);
        loop {
            match (a.peek(), b.peek()) {
                (None, None) => break,
                (Some(ScanOp::Remove { n }), _) => {
                    out.remove(*n);
                    a.next_whole();
                }
                (_, Some(ScanOp::Insert { .. })) => {
                    out.push(b.next_whole())?;
                }
                (Some(x), Some(y)) => {
                    let m = x.len().min(y.len());
                    let x = a.take(m);
                    let y = b.take(m);
                    match (x, y) {
                        (ScanOp::Retain { n, tracking: t1 }, ScanOp::Retain { tracking: t2, .. }) => {
                            out.retain(n, t2.or(t1));
                        }
                        (ScanOp::Retain { .. }, ScanOp::Remove { n }) => {
                            out.remove(n);
                        }
                        (ScanOp::Insert { text, tracking, comment_ids }, ScanOp::Retain { tracking: t2, .. }) => {
                            let tracking = match t2 {
                                None => tracking,
                                Some(Tracking::Clear) => None,
                                Some(t) => Some(t),
                            };
                            out.insert(&text, tracking, comment_ids)?;
                        }
                        (ScanOp::Insert { .. }, ScanOp::Remove { .. }) => {}
                        _ => unreachable!("removes and inserts are handled above"),
                    }
                }
                _ => return Err(OtError::LengthMismatch),
            }
        }
        Ok(out)
    }

    /// Transforms two concurrent ops (ot.js `transform`). Returns `(a', b')` with `a` then `b'` equal to `b` then
    /// `a'`. On equal positions `a`'s insert goes first. Where both retain a range with tracking, `a`'s tracking wins.
    pub fn transform(a: &TextOperation, b: &TextOperation) -> Result<(TextOperation, TextOperation), OtError> {
        if a.base_len() != b.base_len() {
            return Err(OtError::BaseLength { expected: a.base_len(), got: b.base_len() });
        }
        let (mut a2, mut b2) = (TextOperation::new(), TextOperation::new());
        let mut x = Cursor::new(&a.ops);
        let mut y = Cursor::new(&b.ops);
        loop {
            match (x.peek(), y.peek()) {
                (None, None) => break,
                (Some(ScanOp::Insert { text, .. }), _) => {
                    b2.retain(utf16_len(text), None);
                    a2.push(x.next_whole())?;
                }
                (_, Some(ScanOp::Insert { text, .. })) => {
                    a2.retain(utf16_len(text), None);
                    b2.push(y.next_whole())?;
                }
                (Some(p), Some(q)) => {
                    let m = p.len().min(q.len());
                    match (x.take(m), y.take(m)) {
                        (ScanOp::Retain { tracking: ta, .. }, ScanOp::Retain { tracking: tb, .. }) => {
                            let tb = if ta.is_some() { None } else { tb };
                            a2.retain(m, ta);
                            b2.retain(m, tb);
                        }
                        (ScanOp::Remove { .. }, ScanOp::Remove { .. }) => {}
                        (ScanOp::Remove { .. }, ScanOp::Retain { .. }) => {
                            a2.remove(m);
                        }
                        (ScanOp::Retain { .. }, ScanOp::Remove { .. }) => {
                            b2.remove(m);
                        }
                        _ => unreachable!("inserts are handled above"),
                    }
                }
                _ => return Err(OtError::LengthMismatch),
            }
        }
        Ok((a2, b2))
    }

    /// The op for a classic op on a document `doc_len` UTF-16 units long. Comment components are dropped: in this
    /// format comments are separate [`EditOperation::AddComment`] ops. Fails on inserts outside the BMP.
    pub fn from_classic(doc_len: usize, op: &[Component]) -> Result<TextOperation, OtError> {
        let mut len = doc_len;
        let mut out = TextOperation::new();
        out.retain(len, None);
        for c in op {
            let mut step = TextOperation::new();
            match c {
                Component::Insert { p, i } => {
                    if *p > len {
                        return Err(OtError::OutOfRange { index: *p, len });
                    }
                    step.retain(*p, None).insert(i, None, None)?.retain(len - p, None);
                }
                Component::Delete { p, d } => {
                    let n = utf16_len(d);
                    if p + n > len {
                        return Err(OtError::OutOfRange { index: p + n, len });
                    }
                    step.retain(*p, None).remove(n).retain(len - p - n, None);
                }
                Component::Comment { .. } => continue,
            }
            len = step.target_len();
            out = out.compose(&step)?;
        }
        Ok(out)
    }

    /// The classic op with the same effect on `doc`'s text. Tracking is dropped: a tracked delete keeps its text, so
    /// it changes nothing here, and a tracked insert becomes a plain insert.
    pub fn to_classic(&self, doc: &str) -> Result<Op, OtError> {
        let len = utf16_len(doc);
        if len != self.base_len() {
            return Err(OtError::BaseLength { expected: self.base_len(), got: len });
        }
        let mut op = Op::new();
        let mut pos = 0;
        let mut rest = doc;
        for o in &self.ops {
            match o {
                ScanOp::Retain { n, .. } => {
                    rest = split16(rest, *n)?.1;
                    pos += n;
                }
                ScanOp::Insert { text, .. } => {
                    text::append(&mut op, Component::Insert { p: pos, i: text.clone() });
                    pos += utf16_len(text);
                }
                ScanOp::Remove { n } => {
                    let (d, r) = split16(rest, *n)?;
                    text::append(&mut op, Component::Delete { p: pos, d: d.to_owned() });
                    rest = r;
                }
            }
        }
        Ok(op)
    }

    fn to_json_ops(&self) -> Value {
        Value::Array(self.ops.iter().map(ScanOp::to_json).collect())
    }
}

impl ScanOp {
    fn len(&self) -> usize {
        match self {
            ScanOp::Retain { n, .. } | ScanOp::Remove { n } => *n,
            ScanOp::Insert { text, .. } => utf16_len(text),
        }
    }

    /// The first `m` units of this op, and what is left.
    fn split(self, m: usize) -> (ScanOp, Option<ScanOp>) {
        if m >= self.len() {
            return (self, None);
        }
        match self {
            ScanOp::Retain { n, tracking } => {
                (ScanOp::Retain { n: m, tracking: tracking.clone() }, Some(ScanOp::Retain { n: n - m, tracking }))
            }
            ScanOp::Remove { n } => (ScanOp::Remove { n: m }, Some(ScanOp::Remove { n: n - m })),
            ScanOp::Insert { text, tracking, comment_ids } => {
                // Inserts hold only BMP characters, so every unit is a character boundary.
                let (a, b) = split16(&text, m).expect("BMP insert");
                (
                    ScanOp::Insert { text: a.to_owned(), tracking: tracking.clone(), comment_ids: comment_ids.clone() },
                    Some(ScanOp::Insert { text: b.to_owned(), tracking, comment_ids }),
                )
            }
        }
    }

    pub fn to_json(&self) -> Value {
        match self {
            ScanOp::Retain { n, tracking: None } => json!(n),
            ScanOp::Retain { n, tracking: Some(t) } => json!({"r": n, "tracking": t.to_json()}),
            ScanOp::Insert { text, tracking: None, comment_ids: None } => json!(text),
            ScanOp::Insert { text, tracking, comment_ids } => {
                let mut m = Map::new();
                m.insert("i".into(), json!(text));
                if let Some(t) = tracking {
                    m.insert("tracking".into(), t.to_json());
                }
                if let Some(ids) = comment_ids {
                    m.insert("commentIds".into(), json!(ids));
                }
                Value::Object(m)
            }
            ScanOp::Remove { n } => json!(-(*n as i64)),
        }
    }

    pub fn from_json(v: &Value) -> Result<ScanOp, String> {
        match v {
            Value::Number(n) => {
                let n = n.as_i64().ok_or_else(|| format!("not an integer: {n}"))?;
                match n.cmp(&0) {
                    std::cmp::Ordering::Greater => Ok(ScanOp::Retain { n: n as usize, tracking: None }),
                    std::cmp::Ordering::Less => Ok(ScanOp::Remove { n: n.unsigned_abs() as usize }),
                    std::cmp::Ordering::Equal => Err("zero-length op".into()),
                }
            }
            Value::String(s) => Ok(ScanOp::Insert { text: s.clone(), tracking: None, comment_ids: None }),
            Value::Object(m) => {
                let tracking = m.get("tracking").map(Tracking::from_json).transpose()?;
                if let Some(i) = m.get("i") {
                    let text = i.as_str().ok_or("insert text is not a string")?.to_owned();
                    let comment_ids = match m.get("commentIds") {
                        None => None,
                        Some(ids) => Some(
                            ids.as_array()
                                .ok_or("commentIds is not a list")?
                                .iter()
                                .map(|x| x.as_str().map(str::to_owned).ok_or("comment ID is not a string"))
                                .collect::<Result<Vec<_>, _>>()?,
                        ),
                    };
                    Ok(ScanOp::Insert { text, tracking, comment_ids })
                } else if let Some(r) = m.get("r") {
                    let n = r.as_u64().filter(|n| *n > 0).ok_or("retain length is not a positive integer")?;
                    Ok(ScanOp::Retain { n: n as usize, tracking })
                } else {
                    Err(format!("unknown scan op: {v}"))
                }
            }
            _ => Err(format!("unknown scan op: {v}")),
        }
    }
}

impl Tracking {
    fn to_json(&self) -> Value {
        match self {
            Tracking::Clear => json!({"type": "none"}),
            Tracking::Set(p) => json!({
                "type": match p.kind { TrackingKind::Insert => "insert", TrackingKind::Delete => "delete" },
                "userId": p.user_id,
                "ts": p.ts,
            }),
        }
    }

    fn from_json(v: &Value) -> Result<Tracking, String> {
        let kind = match v.get("type").and_then(Value::as_str) {
            Some("none") => return Ok(Tracking::Clear),
            Some("insert") => TrackingKind::Insert,
            Some("delete") => TrackingKind::Delete,
            _ => return Err(format!("unknown tracking: {v}")),
        };
        let field = |k: &str| v.get(k).and_then(Value::as_str).map(str::to_owned).ok_or(format!("tracking needs {k}"));
        Ok(Tracking::Set(TrackingProps { kind, user_id: field("userId")?, ts: field("ts")? }))
    }
}

/// Walks a list of scan ops, taking a part of the current one at a time.
struct Cursor<'a> {
    ops: std::slice::Iter<'a, ScanOp>,
    head: Option<ScanOp>,
}

impl<'a> Cursor<'a> {
    fn new(ops: &'a [ScanOp]) -> Self {
        let mut ops = ops.iter();
        let head = ops.next().cloned();
        Cursor { ops, head }
    }

    fn peek(&self) -> Option<&ScanOp> {
        self.head.as_ref()
    }

    fn next_whole(&mut self) -> ScanOp {
        let h = self.head.take().expect("peeked");
        self.head = self.ops.next().cloned();
        h
    }

    fn take(&mut self, m: usize) -> ScanOp {
        let (a, rest) = self.head.take().expect("peeked").split(m);
        self.head = rest.or_else(|| self.ops.next().cloned());
        a
    }
}

impl EditOperation {
    pub fn to_json(&self) -> Value {
        match self {
            EditOperation::Text(t) => {
                let mut m = Map::new();
                m.insert("textOperation".into(), t.to_json_ops());
                if let Some(h) = &t.content_hash {
                    m.insert("contentHash".into(), json!(h));
                }
                Value::Object(m)
            }
            EditOperation::AddComment { comment_id, ranges, resolved } => {
                let mut m = Map::new();
                m.insert("commentId".into(), json!(comment_id));
                m.insert("ranges".into(), json!(ranges));
                if *resolved {
                    m.insert("resolved".into(), json!(true));
                }
                Value::Object(m)
            }
            EditOperation::DeleteComment { comment_id } => json!({"deleteComment": comment_id}),
            EditOperation::SetCommentState { comment_id, resolved } => {
                json!({"commentId": comment_id, "resolved": resolved})
            }
            EditOperation::NoOp => json!({"noOp": true}),
        }
    }

    /// Parses one edit operation: a text operation, then a comment added (`commentId` with `ranges`), a comment
    /// deleted, a comment's state set (`commentId` with `resolved`), and a no-op, in that order.
    pub fn from_json(v: &Value) -> Result<EditOperation, String> {
        let str_field = |k: &str| v.get(k).and_then(Value::as_str).map(str::to_owned);
        if let Some(ops) = v.get("textOperation") {
            let ops = ops.as_array().ok_or("textOperation is not a list")?;
            let ops = ops.iter().map(ScanOp::from_json).collect::<Result<Vec<_>, _>>()?;
            let mut t = TextOperation::from_ops(ops).map_err(|e| e.to_string())?;
            t.content_hash = str_field("contentHash");
            return Ok(EditOperation::Text(t));
        }
        if let (Some(comment_id), Some(ranges)) = (str_field("commentId"), v.get("ranges")) {
            let ranges: Vec<Range> = serde_json::from_value(ranges.clone()).map_err(|e| e.to_string())?;
            let resolved = v.get("resolved").and_then(Value::as_bool).unwrap_or(false);
            return Ok(EditOperation::AddComment { comment_id, ranges, resolved });
        }
        if let Some(comment_id) = str_field("deleteComment") {
            return Ok(EditOperation::DeleteComment { comment_id });
        }
        if let (Some(comment_id), Some(resolved)) = (str_field("commentId"), v.get("resolved").and_then(Value::as_bool))
        {
            return Ok(EditOperation::SetCommentState { comment_id, resolved });
        }
        if v.get("noOp").is_some() {
            return Ok(EditOperation::NoOp);
        }
        Err(format!("unknown edit operation: {v}"))
    }
}

impl Serialize for EditOperation {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        self.to_json().serialize(s)
    }
}

impl<'de> Deserialize<'de> for EditOperation {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let v = Value::deserialize(d)?;
        EditOperation::from_json(&v).map_err(serde::de::Error::custom)
    }
}
