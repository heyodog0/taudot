//! Position units and wire encodings.
//!
//! Three ways to count a position in the same text:
//!
//! - UTF-8 byte offsets: the engine API (`docs/api.md`), and what Neovim's `on_bytes` reports.
//! - UTF-16 code units: JavaScript string indexes, which is what Overleaf's classic format uses. A character outside
//!   the Basic Multilingual Plane (emoji, 𝔸) counts as 2.
//! - Unicode scalar values (Rust `char`s), which nobody here uses for positions.
//!
//! The classic format also sends text as UTF-8 bytes packed one per character into a Latin-1 string, the result of
//! JavaScript's `unescape(encodeURIComponent(s))`. [`pack_latin1`] and [`unpack_latin1`] convert.

use crate::OtError;

/// Length of `s` in UTF-16 code units (JavaScript's `s.length`).
pub fn utf16_len(s: &str) -> usize {
    s.chars().map(char::len_utf16).sum()
}

/// Converts a UTF-8 byte offset into `s` to a UTF-16 index.
///
/// Fails if the offset is past the end or is not on a character boundary.
pub fn byte_to_utf16(s: &str, byte: usize) -> Result<usize, OtError> {
    if byte > s.len() {
        return Err(OtError::OutOfRange { index: byte, len: s.len() });
    }
    if !s.is_char_boundary(byte) {
        return Err(OtError::SplitsCharacter { index: byte });
    }
    Ok(utf16_len(&s[..byte]))
}

/// Converts a UTF-16 index into `s` to a UTF-8 byte offset.
///
/// Fails if the index is past the end or falls between the two halves of a surrogate pair.
pub fn utf16_to_byte(s: &str, index: usize) -> Result<usize, OtError> {
    let mut units = 0;
    for (b, ch) in s.char_indices() {
        if units == index {
            return Ok(b);
        }
        units += ch.len_utf16();
        if units > index {
            return Err(OtError::SplitsCharacter { index });
        }
    }
    if units == index {
        Ok(s.len())
    } else {
        Err(OtError::OutOfRange { index, len: units })
    }
}

/// Splits `s` at a UTF-16 index.
pub fn split16(s: &str, index: usize) -> Result<(&str, &str), OtError> {
    let b = utf16_to_byte(s, index)?;
    Ok(s.split_at(b))
}

/// The substring of `s` between two UTF-16 indexes, which must be on character boundaries.
pub fn slice16(s: &str, start: usize, end: usize) -> Result<&str, OtError> {
    let (_, rest) = split16(s, start)?;
    // `end` is counted within what follows `start`. A backwards range wraps to a huge length, which is out of range.
    Ok(split16(rest, end.wrapping_sub(start))?.0)
}

/// Packs a string's UTF-8 bytes one per character, as `unescape(encodeURIComponent(s))` does.
pub fn pack_latin1(s: &str) -> String {
    s.bytes().map(char::from).collect()
}

/// Reverses [`pack_latin1`]. Fails if a character is above U+00FF or the bytes are not valid UTF-8.
pub fn unpack_latin1(packed: &str) -> Result<String, OtError> {
    let mut bytes = Vec::with_capacity(packed.len());
    for ch in packed.chars() {
        let n = ch as u32;
        if n > 0xFF {
            return Err(OtError::NotLatin1(ch));
        }
        bytes.push(n as u8);
    }
    String::from_utf8(bytes).map_err(|_| OtError::InvalidUtf8)
}
