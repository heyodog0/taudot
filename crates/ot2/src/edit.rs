//! The engine's own edits: `{pos, del, ins}` in UTF-8 bytes (`docs/api.md`), and conversion to and from the classic
//! format.

use serde::{Deserialize, Serialize};

use crate::text::{self, Component, Op};
use crate::units::{byte_to_utf16, utf16_to_byte};
use crate::OtError;

/// Delete `del` bytes at byte offset `pos`, then insert `ins` there.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Edit {
    pub pos: usize,
    pub del: usize,
    pub ins: String,
}

/// The byte range an edit removes from `doc`, checked.
fn range(doc: &str, e: &Edit) -> Result<(usize, usize), OtError> {
    let end = e.pos.checked_add(e.del).ok_or(OtError::OutOfRange { index: usize::MAX, len: doc.len() })?;
    if end > doc.len() {
        return Err(OtError::OutOfRange { index: end, len: doc.len() });
    }
    for at in [e.pos, end] {
        if !doc.is_char_boundary(at) {
            return Err(OtError::SplitsCharacter { index: at });
        }
    }
    Ok((e.pos, end))
}

/// Applies edits in order.
pub fn apply(doc: &str, edits: &[Edit]) -> Result<String, OtError> {
    let mut doc = doc.to_owned();
    for e in edits {
        let (a, b) = range(&doc, e)?;
        doc.replace_range(a..b, &e.ins);
    }
    Ok(doc)
}

/// Converts edits made on `doc` into a classic op.
pub fn to_classic(doc: &str, edits: &[Edit]) -> Result<Op, OtError> {
    let mut doc = doc.to_owned();
    let mut op = Op::new();
    for e in edits {
        let (a, b) = range(&doc, e)?;
        let p = byte_to_utf16(&doc, a)?;
        text::append(&mut op, Component::Delete { p, d: doc[a..b].to_owned() });
        text::append(&mut op, Component::Insert { p, i: e.ins.clone() });
        doc.replace_range(a..b, &e.ins);
    }
    Ok(op)
}

/// Converts a classic op on `doc` into edits. Comment components change no text and are skipped.
pub fn from_classic(doc: &str, op: &[Component]) -> Result<Vec<Edit>, OtError> {
    let mut doc = doc.to_owned();
    let mut edits = Vec::new();
    for c in op {
        if matches!(c, Component::Comment { .. }) {
            continue;
        }
        let next = text::apply(&doc, std::slice::from_ref(c))?;
        match c {
            Component::Insert { p, i } => {
                edits.push(Edit { pos: utf16_to_byte(&doc, *p)?, del: 0, ins: i.clone() });
            }
            Component::Delete { p, d } => {
                edits.push(Edit { pos: utf16_to_byte(&doc, *p)?, del: d.len(), ins: String::new() });
            }
            Component::Comment { .. } => {}
        }
        doc = next;
    }
    Ok(edits)
}
