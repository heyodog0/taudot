//! Fixtures for the clients' byte-offset ops (`clients/nvim/lua/taudot/ot.lua`, `clients/mac/Sources/TaudotEditor/OT.swift`),
//! with every expected value computed by ot2.
//!
//! The clients' op is ot.js's `TextOperation` counted in UTF-8 bytes: a list of retains (positive numbers), deletes
//! (negative numbers) and inserts (strings), plus the engine's `{pos, del, ins}` byte edits. ot2's
//! `history::TextOperation` is the same op counted in UTF-16 units, so each case is built on character boundaries,
//! converted to UTF-16, run through ot2, and converted back with the text it applies to. Edits, positions and
//! `apply_string` go through `ot2::edit`, `TextOperation::to_classic` and `text::transform_position`.
//!
//! `diff_comps` has no ot2 counterpart; its expected value is written out here: common prefix and suffix kept, at
//! character boundaries, and the middle replaced.
//!
//! Inserted text is in the Basic Multilingual Plane, because ot2's history-ot op refuses anything else; documents
//! still hold emoji, so retains and deletes cross 4-byte characters.
//!
//! - `cargo test -p ot2 --test byte_fixtures` checks `crates/ot2/fixtures/byte_ops.json` is what ot2 gives now.
//! - `TAUDOT_OT_FIXTURE_WRITE=1` rewrites it.
//! - `TAUDOT_OT_FIXTURE_OUT=<path> TAUDOT_OT_FIXTURE_N=<n> [TAUDOT_OT_FIXTURE_SEED=<s>]` writes a larger set for a
//!   differential run (`tools/ot-differential.sh`).

mod common;

use common::Rng;
use ot2::edit::Edit;
use ot2::history::{ScanOp, TextOperation};
use ot2::text::{self, Side};
use ot2::units::{byte_to_utf16, utf16_to_byte};
use serde_json::{json, Value};

const DOC: &[&str] = &["a", "b", " ", "\n", "é", "e\u{301}", "中", "😀", "𝔸", "x"];
const INS: &[&str] = &["a", "b", " ", "\n", "é", "e\u{301}", "中", "x", "yz"];

#[derive(Clone, Debug)]
enum B {
    Retain(usize),
    Delete(usize),
    Insert(String),
}

fn comps_json(c: &[B]) -> Value {
    Value::Array(
        c.iter()
            .map(|c| match c {
                B::Retain(n) => json!(n),
                B::Delete(n) => json!(-(*n as i64)),
                B::Insert(s) => json!(s),
            })
            .collect(),
    )
}

fn edits_json(e: &[Edit]) -> Value {
    Value::Array(e.iter().map(|e| json!({"pos": e.pos, "del": e.del, "ins": e.ins})).collect())
}

fn text(rng: &mut Rng, alphabet: &[&str], max: usize) -> String {
    (0..rng.below(max + 1)).map(|_| alphabet[rng.below(alphabet.len())]).collect()
}

/// Byte offset of each character start, plus the end.
fn bounds(s: &str) -> Vec<usize> {
    s.char_indices().map(|(i, _)| i).chain([s.len()]).collect()
}

/// Byte comps on `base` to ot2 scan ops (no normalizing).
fn to16(base: &str, c: &[B]) -> Vec<ScanOp> {
    let mut at = 0;
    let u = |a: usize, b: usize| byte_to_utf16(&base[a..], b - a).unwrap();
    c.iter()
        .map(|c| match c {
            B::Retain(n) => {
                let o = ScanOp::Retain { n: u(at, at + n), tracking: None };
                at += n;
                o
            }
            B::Delete(n) => {
                let o = ScanOp::Remove { n: u(at, at + n) };
                at += n;
                o
            }
            B::Insert(s) => ScanOp::Insert { text: s.clone(), tracking: None, comment_ids: None },
        })
        .collect()
}

/// An ot2 op on `base` back to byte comps.
fn from16(base: &str, t: &TextOperation) -> Vec<B> {
    let mut at = 0; // UTF-16 index into base
    let b = |i: usize| utf16_to_byte(base, i).unwrap();
    t.ops
        .iter()
        .map(|o| match o {
            ScanOp::Retain { n, .. } => {
                let c = B::Retain(b(at + n) - b(at));
                at += n;
                c
            }
            ScanOp::Remove { n } => {
                let c = B::Delete(b(at + n) - b(at));
                at += n;
                c
            }
            ScanOp::Insert { text, .. } => B::Insert(text.clone()),
        })
        .collect()
}

fn op(base: &str, c: &[B]) -> TextOperation {
    TextOperation::from_ops(to16(base, c)).unwrap()
}

/// Raw comps over `base` on character boundaries, with zero lengths and empty inserts.
fn raw_comps(rng: &mut Rng, base: &str) -> Vec<B> {
    let b = bounds(base);
    let mut k = 0;
    let mut out = Vec::new();
    while k + 1 < b.len() || rng.below(3) == 0 {
        let left = b.len() - 1 - k;
        match rng.below(4) {
            0 => out.push(B::Insert(text(rng, INS, 3))),
            1 => {
                let n = rng.below(left.min(3) + 1);
                out.push(B::Delete(b[k + n] - b[k]));
                k += n;
            }
            _ => {
                let n = rng.below(left.min(4) + 1);
                out.push(B::Retain(b[k + n] - b[k]));
                k += n;
            }
        }
        if out.len() > 14 {
            break;
        }
    }
    if k + 1 < b.len() {
        out.push(B::Retain(b[b.len() - 1] - b[k]));
    }
    out
}

/// A normalized random op on `base`.
fn random_op(rng: &mut Rng, base: &str) -> Vec<B> {
    let r = raw_comps(rng, base);
    from16(base, &op(base, &r))
}

/// Random byte edits on `base`, applied in order, on character boundaries; sometimes one out of range.
fn random_edits(rng: &mut Rng, base: &str) -> (Vec<Edit>, bool) {
    let mut t = base.to_owned();
    let mut out = Vec::new();
    let mut valid = true;
    for _ in 0..1 + rng.below(3) {
        let b = bounds(&t);
        if rng.below(20) == 0 {
            out.push(Edit { pos: t.len() + rng.below(2), del: 1 + rng.below(2), ins: String::new() });
            valid = false;
            break;
        }
        let s = rng.below(b.len());
        let e = s + rng.below((b.len() - s).min(3));
        let e = Edit { pos: b[s], del: b[e] - b[s], ins: text(rng, INS, 3) };
        t = ot2::edit::apply(&t, std::slice::from_ref(&e)).unwrap();
        out.push(e);
    }
    (out, valid)
}

/// The engine's byte edits for an op on `base`, through the classic format.
fn to_edits(base: &str, t: &TextOperation) -> Vec<Edit> {
    ot2::edit::from_classic(base, &t.to_classic(base).unwrap()).unwrap()
}

fn case(rng: &mut Rng) -> Value {
    let base = text(rng, DOC, 10);
    let a = random_op(rng, &base);
    let b = random_op(rng, &base);
    let (ta, tb) = (op(&base, &a), op(&base, &b));
    let after_a = ta.apply(&base).unwrap();
    let after_b = tb.apply(&base).unwrap();
    let c = random_op(rng, &after_a);
    let tc = op(&after_a, &c);
    let composed = from16(&base, &ta.compose(&tc).unwrap());
    let (a2, b2) = TextOperation::transform(&ta, &tb).unwrap();
    let raw = raw_comps(rng, &base);

    let (edits, valid) = random_edits(rng, &base);
    let from_edits = if valid {
        let classic = ot2::edit::to_classic(&base, &edits).unwrap();
        comps_json(&from16(&base, &TextOperation::from_classic(ot2::units::utf16_len(&base), &classic).unwrap()))
    } else {
        Value::Null
    };

    let edits_a = to_edits(&base, &ta);
    let classic_a = ta.to_classic(&base).unwrap();
    let map: Vec<Value> = bounds(&base)
        .into_iter()
        .flat_map(|p| {
            let u = byte_to_utf16(&base, p).unwrap();
            [("left", Side::Left), ("right", Side::Right)].map(|(name, side)| {
                let q = text::transform_position(u, &classic_a, side);
                json!([p, name, utf16_to_byte(&after_a, q).unwrap()])
            })
        })
        .collect();

    // diff_comps: prefix and suffix on character boundaries.
    let other = if rng.below(3) == 0 { text(rng, DOC, 10) } else { after_b.clone() };
    let (oc, nc): (Vec<char>, Vec<char>) = (base.chars().collect(), other.chars().collect());
    let pre = oc.iter().zip(&nc).take_while(|(x, y)| x == y).count();
    let suf = oc[pre..].iter().rev().zip(nc[pre..].iter().rev()).take_while(|(x, y)| x == y).count();
    let bytes = |cs: &[char]| cs.iter().map(|c| c.len_utf8()).sum::<usize>();
    let (pre_b, suf_b) = (bytes(&oc[..pre]), bytes(&oc[oc.len() - suf..]));
    let del = bytes(&oc[pre..oc.len() - suf]);
    let ins: String = nc[pre..nc.len() - suf].iter().collect();
    let mut dc = Vec::new();
    if pre_b > 0 {
        dc.push(B::Retain(pre_b));
    }
    if !ins.is_empty() {
        dc.push(B::Insert(ins.clone()));
    }
    if del > 0 {
        dc.push(B::Delete(del));
    }
    if suf_b > 0 {
        dc.push(B::Retain(suf_b));
    }
    let marks = if ins.is_empty() { json!([]) } else { json!([[pre_b, pre_b + ins.len()]]) };

    // An op on a text of another length, which compose and transform must refuse.
    let wrong = text(rng, DOC, 10);
    let x = if wrong.len() != base.len() { Some(random_op(rng, &wrong)) } else { None };

    json!({
        "base": base,
        "a": comps_json(&a),
        "b": comps_json(&b),
        "c": comps_json(&c),
        "compose_ac": comps_json(&composed),
        "transform_ab": [comps_json(&from16(&after_b, &a2)), comps_json(&from16(&after_a, &b2))],
        "raw": comps_json(&raw),
        "from_comps": comps_json(&from16(&base, &op(&base, &raw))),
        "edits": edits_json(&edits),
        "from_edits": from_edits,
        "to_edits_a": edits_json(&edits_a),
        "count_a": edits_a.len(),
        "after_a": after_a,
        "map_a": map,
        "other": other,
        "diff": {"comps": comps_json(&dc), "marks": marks},
        "wrong_len": x.map(|x| comps_json(&x)),
    })
}

fn generate(seed: u64, n: usize) -> String {
    let mut rng = Rng::new(seed);
    let cases: Vec<Value> = (0..n).map(|_| case(&mut rng)).collect();
    let mut s = String::from("[\n");
    for (i, c) in cases.iter().enumerate() {
        s += &serde_json::to_string(c).unwrap();
        s += if i + 1 < cases.len() { ",\n" } else { "\n" };
    }
    s + "]\n"
}

const FIXTURE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/fixtures/byte_ops.json");

#[test]
fn byte_ops_fixture() {
    if let Ok(out) = std::env::var("TAUDOT_OT_FIXTURE_OUT") {
        let n = std::env::var("TAUDOT_OT_FIXTURE_N").ok().and_then(|s| s.parse().ok()).unwrap_or(100_000);
        let seed = std::env::var("TAUDOT_OT_FIXTURE_SEED").ok().and_then(|s| s.parse().ok()).unwrap_or(11);
        std::fs::write(&out, generate(seed, n)).unwrap();
        eprintln!("wrote {n} cases to {out}");
        return;
    }
    let want = generate(1, 800);
    if std::env::var_os("TAUDOT_OT_FIXTURE_WRITE").is_some() {
        std::fs::create_dir_all(std::path::Path::new(FIXTURE).parent().unwrap()).unwrap();
        std::fs::write(FIXTURE, &want).unwrap();
        return;
    }
    let have = std::fs::read_to_string(FIXTURE).expect("fixture missing: run with TAUDOT_OT_FIXTURE_WRITE=1");
    assert!(have == want, "{FIXTURE} is out of date: run with TAUDOT_OT_FIXTURE_WRITE=1");
}
