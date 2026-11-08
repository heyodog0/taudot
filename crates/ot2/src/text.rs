//! The classic format, `sharejs-text-ot`.
//!
//! An op is a list of components that apply in order, each one seeing the text left by the ones before it. Positions
//! are UTF-16 code units (JavaScript string indexes).
//!
//! This is ShareJS 0.6's text type (MIT, Joseph Gentle: `src/types/text.coffee` and the `bootstrapTransform` of
//! `src/types/helpers.coffee`), which Overleaf's document updater runs, carried over to UTF-16 positions on Rust
//! strings, plus the comment component `{p, c, t}` that `docs/protocol.md` describes. The server transforms a
//! client's op as the [`Side::Left`] side against the ops it already has, and the browser client calls
//! [`transform_x`]`(client_op, server_op)`, so on equal positions the client's insert goes first.

use serde::{Deserialize, Serialize};

use crate::units::{split16, utf16_len};
use crate::OtError;

/// One component of a classic op.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum Component {
    /// Insert `i` at `p`.
    Insert { p: usize, i: String },
    /// Delete the text `d`, which must be what is at `p`.
    Delete { p: usize, d: String },
    /// Mark the text `c` at `p` as commented, in thread `t`. Changes no text.
    Comment { p: usize, c: String, t: String },
}

impl Component {
    pub fn p(&self) -> usize {
        match self {
            Component::Insert { p, .. } | Component::Delete { p, .. } | Component::Comment { p, .. } => *p,
        }
    }
}

/// A classic op: components applied in order.
pub type Op = Vec<Component>;

/// Which op wins when both insert at the same position. The `Left` op's insert ends up first.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Side {
    Left,
    Right,
}

/// `s` with `ins` put in at UTF-16 index `at`.
fn inject(s: &str, at: usize, ins: &str) -> Result<String, OtError> {
    let (a, b) = split16(s, at)?;
    Ok([a, ins, b].concat())
}

/// The text in `doc` that a delete or comment of `expected` at `p` covers.
fn covered(doc: &str, p: usize, expected: &str) -> Result<String, OtError> {
    let (_, rest) = split16(doc, p)?;
    // Cut short at the end, or where the cut would split a character: either way it can't match.
    Ok(split16(rest, utf16_len(expected)).map_or(rest, |(a, _)| a).to_owned())
}

/// Applies an op to a document.
pub fn apply(doc: &str, op: &[Component]) -> Result<String, OtError> {
    let mut doc = doc.to_owned();
    for c in op {
        match c {
            Component::Insert { p, i } => doc = inject(&doc, *p, i)?,
            Component::Delete { p, d } => {
                let found = covered(&doc, *p, d)?;
                if &found != d {
                    return Err(OtError::DeleteMismatch { expected: d.clone(), found });
                }
                let (a, rest) = split16(&doc, *p)?;
                let (_, b) = split16(rest, utf16_len(d))?;
                doc = [a, b].concat();
            }
            Component::Comment { p, c, .. } => {
                if &covered(&doc, *p, c)? != c {
                    return Err(OtError::CommentMismatch { expected: c.clone() });
                }
            }
        }
    }
    Ok(doc)
}

/// Appends a component to an op, merging it into the last one where ShareJS's `append` does: an insert that starts
/// within the previous insert, or a delete whose range reaches the previous delete's position. Empty inserts and
/// deletes are dropped.
pub fn append(op: &mut Op, c: Component) {
    match &c {
        Component::Insert { i, .. } if i.is_empty() => return,
        Component::Delete { d, .. } if d.is_empty() => return,
        _ => {}
    }
    if let Some(last) = op.last_mut() {
        match (&*last, &c) {
            (Component::Insert { p: lp, i: li }, Component::Insert { p, i })
                if *lp <= *p && *p <= *lp + utf16_len(li) =>
            {
                if let Ok(merged) = inject(li, p - lp, i) {
                    *last = Component::Insert { p: *lp, i: merged };
                    return;
                }
            }
            (Component::Delete { p: lp, d: ld }, Component::Delete { p, d })
                if *p <= *lp && *lp <= *p + utf16_len(d) =>
            {
                if let Ok(merged) = inject(d, lp - p, ld) {
                    *last = Component::Delete { p: *p, d: merged };
                    return;
                }
            }
            _ => {}
        }
    }
    op.push(c);
}

/// The op that applies `a`, then `b`.
pub fn compose(a: &[Component], b: &[Component]) -> Op {
    let mut out = a.to_vec();
    for c in b {
        append(&mut out, c.clone());
    }
    out
}

/// Removes empty components and merges neighbours, as ShareJS's `normalize` does.
pub fn normalize(op: Op) -> Op {
    compose(&[], &op)
}

/// The op that undoes `op`. Comments have no inverse in this format and are dropped.
pub fn invert(op: &[Component]) -> Op {
    op.iter()
        .rev()
        .filter_map(|c| match c {
            Component::Insert { p, i } => Some(Component::Delete { p: *p, d: i.clone() }),
            Component::Delete { p, d } => Some(Component::Insert { p: *p, i: d.clone() }),
            Component::Comment { .. } => None,
        })
        .collect()
}

/// Where a position ends up after component `c`. With `insert_after`, an insert exactly at the position pushes it
/// along.
fn shift(pos: usize, c: &Component, insert_after: bool) -> usize {
    match c {
        Component::Insert { p, i } => {
            if *p < pos || (*p == pos && insert_after) {
                pos + utf16_len(i)
            } else {
                pos
            }
        }
        Component::Delete { p, d } => {
            let n = utf16_len(d);
            if pos <= *p {
                pos
            } else if pos <= p + n {
                *p
            } else {
                pos - n
            }
        }
        Component::Comment { .. } => pos,
    }
}

/// Moves a cursor past an op. On [`Side::Right`] an insert at the cursor pushes it along.
pub fn transform_position(pos: usize, op: &[Component], side: Side) -> usize {
    op.iter().fold(pos, |pos, c| shift(pos, c, side == Side::Right))
}

/// UTF-16 slice of `s` from `a` to `b`.
fn sub(s: &str, a: usize, b: usize) -> Result<String, OtError> {
    let (_, rest) = split16(s, a)?;
    Ok(split16(rest, b - a)?.0.to_owned())
}

/// What is left of a range `[p, p + text)` once `[q, q + n)` is deleted: the text outside the deleted part.
fn cut(p: usize, text: &str, q: usize, n: usize) -> Result<String, OtError> {
    let len = utf16_len(text);
    let mut out = String::new();
    if p < q {
        out += &sub(text, 0, (q - p).min(len))?;
    }
    if p + len > q + n {
        out += &sub(text, (q + n).saturating_sub(p), len)?;
    }
    Ok(out)
}

/// Two overlapping ranges, `[p, p + a)` and `[q, q + b)`, must hold the same text where they overlap. Each part is cut
/// out of its own text, which is refused inside a surrogate pair.
fn check_overlap(p: usize, a: &str, q: usize, b: &str) -> Result<(), OtError> {
    let start = p.max(q);
    let end = (p + utf16_len(a)).min(q + utf16_len(b));
    if sub(a, start - p, end - p)? != sub(b, start - q, end - q)? {
        return Err(OtError::OverlapMismatch);
    }
    Ok(())
}

/// Transforms component `c` past `other` and appends the result to `dest` (ShareJS's `transformComponent`).
fn transform_component(dest: &mut Op, c: &Component, other: &Component, side: Side) -> Result<(), OtError> {
    match c {
        Component::Insert { p, i } => {
            append(dest, Component::Insert { p: shift(*p, other, side == Side::Right), i: i.clone() });
        }
        Component::Delete { p, d } => match other {
            Component::Insert { p: q, i } => {
                let mut s = d.clone();
                if p < q {
                    let (before, after) = split16(d, (q - p).min(utf16_len(d)))?;
                    append(dest, Component::Delete { p: *p, d: before.to_owned() });
                    s = after.to_owned();
                }
                if !s.is_empty() {
                    append(dest, Component::Delete { p: p + utf16_len(i), d: s });
                }
            }
            Component::Delete { p: q, d: od } => {
                let (n, on) = (utf16_len(d), utf16_len(od));
                if *p >= q + on {
                    append(dest, Component::Delete { p: p - on, d: d.clone() });
                } else if p + n <= *q {
                    append(dest, c.clone());
                } else {
                    check_overlap(*p, d, *q, od)?;
                    let rest = cut(*p, d, *q, on)?;
                    if !rest.is_empty() {
                        append(dest, Component::Delete { p: shift(*p, other, false), d: rest });
                    }
                }
            }
            Component::Comment { .. } => append(dest, c.clone()),
        },
        Component::Comment { p, c: text, t } => {
            let n = utf16_len(text);
            match other {
                Component::Insert { p: q, i } => {
                    if *q <= *p {
                        append(dest, Component::Comment { p: p + utf16_len(i), c: text.clone(), t: t.clone() });
                    } else if *q < p + n {
                        let c2 = inject(text, q - p, i)?;
                        append(dest, Component::Comment { p: *p, c: c2, t: t.clone() });
                    } else {
                        append(dest, c.clone());
                    }
                }
                Component::Delete { p: q, d: od } => {
                    let on = utf16_len(od);
                    if *p >= q + on {
                        append(dest, Component::Comment { p: p - on, c: text.clone(), t: t.clone() });
                    } else if p + n <= *q {
                        append(dest, c.clone());
                    } else {
                        check_overlap(*p, text, *q, od)?;
                        let rest = cut(*p, text, *q, on)?;
                        append(dest, Component::Comment { p: shift(*p, other, false), c: rest, t: t.clone() });
                    }
                }
                Component::Comment { .. } => append(dest, c.clone()),
            }
        }
    }
    Ok(())
}

/// Transforms two concurrent ops against each other. Returns `(left', right')`, where `left'` applies after `right`
/// and `right'` applies after `left`. Both lead to the same text. This is ShareJS's `transformX`.
pub fn transform_x(left: &[Component], right: &[Component]) -> Result<(Op, Op), OtError> {
    let mut left: Op = left.to_vec();
    let mut new_right = Op::new();
    for rc in right {
        let mut rc = Some(rc.clone());
        let mut new_left = Op::new();
        let mut k = 0;
        while k < left.len() {
            let r = rc.clone().expect("set while looping");
            let mut next = Op::new();
            transform_component(&mut new_left, &left[k], &r, Side::Left)?;
            transform_component(&mut next, &r, &left[k], Side::Right)?;
            k += 1;
            match next.len() {
                1 => rc = next.pop(),
                0 => {
                    for l in &left[k..] {
                        append(&mut new_left, l.clone());
                    }
                    rc = None;
                    break;
                }
                _ => {
                    let (l2, r2) = transform_x(&left[k..], &next)?;
                    for l in l2 {
                        append(&mut new_left, l);
                    }
                    for r in r2 {
                        append(&mut new_right, r);
                    }
                    rc = None;
                    break;
                }
            }
        }
        if let Some(r) = rc {
            append(&mut new_right, r);
        }
        left = new_left;
    }
    Ok((left, new_right))
}

/// Transforms `op` so it applies after `other`, which happened concurrently. This is ShareJS's `transform`.
pub fn transform(op: &[Component], other: &[Component], side: Side) -> Result<Op, OtError> {
    if other.is_empty() {
        return Ok(op.to_vec());
    }
    if op.len() == 1 && other.len() == 1 {
        let mut out = Op::new();
        transform_component(&mut out, &op[0], &other[0], side)?;
        return Ok(out);
    }
    match side {
        Side::Left => Ok(transform_x(op, other)?.0),
        Side::Right => Ok(transform_x(other, op)?.1),
    }
}
