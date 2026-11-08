//! Random documents and ops for the property tests. Ops are built from a seed so they are always valid for the
//! document they're made against; proptest shrinks the seed list.
#![allow(dead_code)]

use ot2::text::{Component, Op};
use ot2::units::utf16_len;

/// Characters chosen to hit every UTF-8 and UTF-16 width: ASCII, Latin-1, CJK, emoji (astral), math (astral).
pub const ALPHABET: &[&str] = &["a", "b", "\n", "é", "中", "文", "😀", "𝔸", "x"];

pub struct Rng(u64);

impl Rng {
    pub fn new(seed: u64) -> Self {
        Rng(seed ^ 0x9e37_79b9_7f4a_7c15)
    }
    pub fn next(&mut self) -> u64 {
        // splitmix64
        self.0 = self.0.wrapping_add(0x9e37_79b9_7f4a_7c15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
        z ^ (z >> 31)
    }
    pub fn below(&mut self, n: usize) -> usize {
        if n == 0 { 0 } else { (self.next() % n as u64) as usize }
    }
}

pub fn random_text(rng: &mut Rng, max: usize) -> String {
    let n = rng.below(max + 1);
    (0..n).map(|_| ALPHABET[rng.below(ALPHABET.len())]).collect()
}

/// UTF-16 index of the start of each character, plus the end.
pub fn boundaries(doc: &str) -> Vec<usize> {
    let mut out = vec![0];
    let mut u = 0;
    for ch in doc.chars() {
        u += ch.len_utf16();
        out.push(u);
    }
    out
}

/// A random component valid on `doc`.
pub fn random_component(rng: &mut Rng, doc: &str, comments: bool) -> Component {
    let b = boundaries(doc);
    let chars: Vec<char> = doc.chars().collect();
    let kind = rng.below(if comments { 10 } else { 9 });
    if kind < 5 || chars.is_empty() {
        let k = rng.below(b.len());
        let mut i = random_text(rng, 4);
        if i.is_empty() {
            i.push('z');
        }
        Component::Insert { p: b[k], i }
    } else {
        let start = rng.below(chars.len());
        let len = 1 + rng.below((chars.len() - start).min(5));
        let text: String = chars[start..start + len].iter().collect();
        if kind < 9 {
            Component::Delete { p: b[start], d: text }
        } else {
            Component::Comment { p: b[start], c: text, t: format!("t{}", rng.below(100)) }
        }
    }
}

/// A random op of up to `max` components, valid on `doc`.
pub fn random_op(rng: &mut Rng, doc: &str, max: usize, comments: bool) -> Op {
    let mut doc = doc.to_owned();
    let mut op = Op::new();
    for _ in 0..1 + rng.below(max) {
        let c = random_component(rng, &doc, comments);
        doc = ot2::text::apply(&doc, std::slice::from_ref(&c)).unwrap();
        op.push(c);
    }
    op
}

pub fn len16(s: &str) -> usize {
    utf16_len(s)
}
