//! Text encodings Overleaf uses on the wire.

use sha1::{Digest, Sha1};

/// Undo `unescape(encodeURIComponent(s))`: each char is one byte of UTF-8.
///
/// The server packs `joinDoc` lines (and range text with `encodeRanges`) this way for `sharejs-text-ot` docs only
/// (`services/real-time/app/js/WebsocketController.js`, `joinDoc`). Op text in `applyOtUpdate` and in broadcast
/// updates is plain.
pub fn decode_packed(s: &str) -> Result<String, PackedError> {
    let mut bytes = Vec::with_capacity(s.len());
    for c in s.chars() {
        let n = c as u32;
        if n > 0xff {
            return Err(PackedError::NotLatin1(c));
        }
        bytes.push(n as u8);
    }
    String::from_utf8(bytes).map_err(|_| PackedError::BadUtf8)
}

/// `unescape(encodeURIComponent(s))`.
pub fn encode_packed(s: &str) -> String {
    s.bytes().map(char::from).collect()
}

#[derive(Debug, Clone, PartialEq, thiserror::Error)]
pub enum PackedError {
    #[error("packed text holds {0:?}, which is not a byte")]
    NotLatin1(char),
    #[error("packed text is not UTF-8")]
    BadUtf8,
}

/// Length in JavaScript string units (UTF-16 code units).
pub fn js_len(s: &str) -> usize {
    s.chars().map(char::len_utf16).sum()
}

/// The document hash the server checks: `sha1("blob " + content.length + "\0" + utf8(content))`, where `length` is
/// the JavaScript string length (`services/document-updater/app/js/ShareJsUpdateManager.js`, `_computeHash`).
pub fn doc_hash(content: &str) -> String {
    let mut h = Sha1::new();
    h.update(format!("blob {}\0", js_len(content)).as_bytes());
    h.update(content.as_bytes());
    h.finalize().iter().map(|b| format!("{b:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn packed_round_trip() {
        for s in ["plain", "é", "naïve ∑ 𝔸 😀", ""] {
            let p = encode_packed(s);
            assert!(p.chars().all(|c| (c as u32) < 256));
            assert_eq!(decode_packed(&p).unwrap(), s);
        }
        // What the server sends for "é": the two UTF-8 bytes as Latin-1 chars.
        assert_eq!(encode_packed("é"), "\u{c3}\u{a9}");
    }

    #[test]
    fn packed_rejects_wide_chars() {
        assert!(decode_packed("€").is_err());
        assert!(decode_packed("\u{c3}").is_err());
    }

    #[test]
    fn js_length_counts_astral_as_two() {
        assert_eq!(js_len("abc"), 3);
        assert_eq!(js_len("é"), 1);
        assert_eq!(js_len("😀"), 2);
    }

    #[test]
    fn hash_matches_git() {
        // `printf 'hello\n' | git hash-object --stdin`
        assert_eq!(doc_hash("hello\n"), "ce013625030ba8dba906f756967f9e9ca394464a");
        // For non-ASCII the header counts UTF-16 units, not bytes, unlike git.
        let mut h = Sha1::new();
        h.update(b"blob 1\0\xc3\xa9");
        let want: String = h.finalize().iter().map(|b| format!("{b:02x}")).collect();
        assert_eq!(doc_hash("é"), want);
    }
}
