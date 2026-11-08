//! Properties of the history-ot `TextOperation`: TP1, compose, and agreement with the classic format.

mod common;

use common::{boundaries, random_op, Rng};
use ot2::history::{ScanOp, TextOperation, Tracking, TrackingKind, TrackingProps};
use ot2::text;
use ot2::units::utf16_len;
use proptest::prelude::*;

/// Inserts must stay in the BMP; the document may still hold astral characters from before.
const BMP: &[&str] = &["a", "b", "\n", "é", "中", "文", "x"];
const DOC: &[&str] = &["a", "b", "\n", "é", "中", "😀", "𝔸"];

fn text_from(rng: &mut Rng, alphabet: &[&str], max: usize) -> String {
    (0..rng.below(max + 1)).map(|_| alphabet[rng.below(alphabet.len())]).collect()
}

fn tracking(rng: &mut Rng) -> Option<Tracking> {
    match rng.below(6) {
        0 => Some(Tracking::Clear),
        1 => Some(Tracking::Set(TrackingProps {
            kind: if rng.below(2) == 0 { TrackingKind::Insert } else { TrackingKind::Delete },
            user_id: format!("u{}", rng.below(2)),
            ts: format!("2026-01-0{}T00:00:00.000Z", 1 + rng.below(3)),
        })),
        _ => None,
    }
}

/// A random op over `doc`, cutting only on character boundaries.
fn random_text_op(rng: &mut Rng, doc: &str) -> TextOperation {
    let b = boundaries(doc);
    let mut k = 0; // index into b
    let mut ops = Vec::new();
    while k + 1 < b.len() || rng.below(3) == 0 {
        match rng.below(4) {
            0 => {
                let mut s = text_from(rng, BMP, 3);
                if s.is_empty() {
                    s.push('z');
                }
                let t = if rng.below(4) == 0 { tracking(rng).filter(|t| matches!(t, Tracking::Set(_))) } else { None };
                ops.push(ScanOp::Insert { text: s, tracking: t, comment_ids: None });
                if k + 1 >= b.len() {
                    break;
                }
            }
            1 if k + 1 < b.len() => {
                let n = 1 + rng.below((b.len() - 1 - k).min(3));
                ops.push(ScanOp::Remove { n: b[k + n] - b[k] });
                k += n;
            }
            _ if k + 1 < b.len() => {
                let n = 1 + rng.below((b.len() - 1 - k).min(4));
                ops.push(ScanOp::Retain { n: b[k + n] - b[k], tracking: tracking(rng) });
                k += n;
            }
            _ => break,
        }
    }
    let op = TextOperation::from_ops(ops).unwrap();
    assert_eq!(op.base_len(), utf16_len(doc));
    op
}

fn without_ts(op: &TextOperation) -> Vec<ScanOp> {
    let strip = |t: &Option<Tracking>| match t {
        Some(Tracking::Set(p)) => Some(Tracking::Set(TrackingProps { ts: String::new(), ..p.clone() })),
        other => other.clone(),
    };
    op.ops
        .iter()
        .map(|o| match o {
            ScanOp::Retain { n, tracking } => ScanOp::Retain { n: *n, tracking: strip(tracking) },
            ScanOp::Insert { text, tracking, comment_ids } => {
                ScanOp::Insert { text: text.clone(), tracking: strip(tracking), comment_ids: comment_ids.clone() }
            }
            other => other.clone(),
        })
        .collect()
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(5000))]

    #[test]
    fn tp1(seed: u64) {
        let mut rng = Rng::new(seed);
        let doc = text_from(&mut rng, DOC, 12);
        let a = random_text_op(&mut rng, &doc);
        let b = random_text_op(&mut rng, &doc);
        let (a2, b2) = TextOperation::transform(&a, &b).unwrap();
        let x = b2.apply(&a.apply(&doc).unwrap()).unwrap();
        let y = a2.apply(&b.apply(&doc).unwrap()).unwrap();
        prop_assert_eq!(x, y, "doc={:?} a={:?} b={:?}", doc, a, b);
        // And the composed ops agree too, tracking included, except timestamps: adjacent tracked ranges merge to the
        // earlier `ts`, so it depends on order. Overleaf's `TrackingProps.mergeWith` does the same.
        prop_assert_eq!(without_ts(&a.compose(&b2).unwrap()), without_ts(&b.compose(&a2).unwrap()));
    }

    #[test]
    fn compose_is_apply_then_apply(seed: u64) {
        let mut rng = Rng::new(seed);
        let doc = text_from(&mut rng, DOC, 12);
        let a = random_text_op(&mut rng, &doc);
        let mid = a.apply(&doc).unwrap();
        let b = random_text_op(&mut rng, &mid);
        prop_assert_eq!(a.compose(&b).unwrap().apply(&doc).unwrap(), b.apply(&mid).unwrap());
    }

    #[test]
    fn classic_conversion_agrees(seed: u64) {
        let mut rng = Rng::new(seed);
        let doc = text_from(&mut rng, DOC, 12);
        let mut op = random_op(&mut rng, &doc, 4, true);
        // history-ot can't insert astral characters.
        op.retain(|c| !matches!(c, text::Component::Insert { i, .. } if i.chars().any(|c| c.len_utf16() == 2)));
        let Ok(expected) = text::apply(&doc, &op) else { return Ok(()) };
        let h = TextOperation::from_classic(utf16_len(&doc), &op).unwrap();
        prop_assert_eq!(h.apply(&doc).unwrap(), expected.clone());
        let back = h.to_classic(&doc).unwrap();
        prop_assert_eq!(text::apply(&doc, &back).unwrap(), expected);
    }
}

/// Seed where the two orders gave the same op but different tracked-delete timestamps.
#[test]
fn tp1_tracking_ts_regression() {
    let mut rng = Rng::new(9100320607942738253);
    let doc = text_from(&mut rng, DOC, 12);
    let a = random_text_op(&mut rng, &doc);
    let b = random_text_op(&mut rng, &doc);
    let (a2, b2) = TextOperation::transform(&a, &b).unwrap();
    assert_eq!(b2.apply(&a.apply(&doc).unwrap()).unwrap(), a2.apply(&b.apply(&doc).unwrap()).unwrap());
    assert_eq!(without_ts(&a.compose(&b2).unwrap()), without_ts(&b.compose(&a2).unwrap()));
}
