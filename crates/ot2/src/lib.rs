//! The OT core of taudot: Overleaf's two edit formats, conversions between position units, and the client state
//! machine. Pure library, no I/O.
//!
//! Written clean-room from `docs/protocol.md`, ShareJS 0.6's text type and client (MIT, Joseph Gentle) and ot.js
//! (MIT, Tim Baumann); see `docs/agents/otclean.log.md` for what each module was written from.
//!
//! - [`text`]: the classic format, `sharejs-text-ot`, positions in UTF-16 code units.
//! - [`units`]: UTF-8 byte offsets to and from UTF-16 indexes, and Latin-1 packing.
//! - [`history`]: the new format, `history-ot`, and conversion to and from classic ops.
//! - [`edit`]: the engine API's byte-offset edits.
//! - [`diff`]: smallest op between two texts.
//! - [`client`]: one document's inflight and pending ops, as Overleaf's browser client keeps them.

pub mod client;
pub mod diff;
pub mod edit;
pub mod filedata;
pub mod history;
pub mod text;
pub mod units;

/// Everything that can go wrong applying or transforming an op. Any of these means our copy of the document no longer
/// matches the op, so the caller should stop sending and resync.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum OtError {
    #[error("position {index} is past the end ({len})")]
    OutOfRange { index: usize, len: usize },
    #[error("position {index} falls inside a character")]
    SplitsCharacter { index: usize },
    #[error("delete expected {expected:?} but found {found:?}")]
    DeleteMismatch { expected: String, found: String },
    #[error("comment text {expected:?} does not match the document")]
    CommentMismatch { expected: String },
    #[error("overlapping deletes remove different text")]
    OverlapMismatch,
    #[error("character {0:?} is not Latin-1")]
    NotLatin1(char),
    #[error("packed bytes are not valid UTF-8")]
    InvalidUtf8,
    #[error("expected version {expected}, got {got}")]
    Version { expected: u64, got: u64 },
    #[error("confirmation with nothing in flight")]
    NothingInflight,
    #[error("inserted text contains non BMP characters")]
    NonBmpInsert,
    #[error("base length {got} does not match {expected}")]
    BaseLength { expected: usize, got: usize },
    #[error("operations have different lengths")]
    LengthMismatch,
}
