//! `ot2::filedata`: the CE observations (fixture), and properties of the visible-text mapping and the transform.

mod common;

use common::{boundaries, Rng};
use ot2::filedata::{self, FileData};
use ot2::history::{EditOperation, Range, ScanOp, TextOperation, Tracking, TrackingKind, TrackingProps};
use ot2::text::{self, Component, Op};
use ot2::units::utf16_len;
use proptest::prelude::*;
use serde_json::Value;

/// Every case of `harness/tests/historyot-ranges.ts` run on CE 6.3: same content, comments and tracked changes.
#[test]
fn matches_ce_observations() {
    let cases: Value = serde_json::from_str(include_str!("../fixtures/historyot_ranges.json")).unwrap();
    let mut n = 0;
    for (name, c) in cases.as_object().unwrap() {
        let mut fd = FileData::new("0123456789abcdefghij");
        let mut result = Ok(());
        for u in c["updates"].as_array().unwrap() {
            let ops = match filedata::ops_from_json(u) {
                Ok(o) => o,
                Err(e) => {
                    result = Err(e);
                    break;
                }
            };
            if let Err(e) = fd.apply_all(&ops) {
                result = Err(e.to_string());
                break;
            }
        }
        if c.get("error").is_some() {
            assert!(result.is_err(), "{name}: CE refused it, we accepted: {:?}", fd.to_json());
            continue;
        }
        result.unwrap_or_else(|e| panic!("{name}: {e}"));
        let got = fd.to_json();
        // The probe lists only this case's comments, which are the only ones here.
        assert_eq!(got["content"], c["content"], "{name}: content");
        assert_eq!(got["comments"], c["comments"], "{name}: comments");
        assert_eq!(got["trackedChanges"], c["trackedChanges"], "{name}: tracked changes");
        n += 1;
    }
    assert!(n >= 35, "only {n} cases");
}

const DOC: &[&str] = &["a", "b", " ", "\n", "é", "中", "😀", "x"];
const INS: &[&str] = &["a", "b", " ", "é", "中", "Z"];

fn text_from(rng: &mut Rng, alphabet: &[&str], max: usize) -> String {
    (0..rng.below(max + 1)).map(|_| alphabet[rng.below(alphabet.len())]).collect()
}

fn props(rng: &mut Rng, kind: TrackingKind) -> TrackingProps {
    TrackingProps { kind, user_id: format!("u{}", rng.below(2)), ts: format!("2026-01-0{}T00:00:00.000Z", 1 + rng.below(3)) }
}

/// A random text operation over `doc`, on character boundaries, with tracking of every kind.
fn random_text_op(rng: &mut Rng, doc: &str) -> TextOperation {
    let b = boundaries(doc);
    let mut k = 0;
    let mut ops = vec![];
    loop {
        let left = b.len() - 1 - k;
        match rng.below(6) {
            0 => {
                let mut s = text_from(rng, INS, 3);
                if s.is_empty() {
                    s.push('q');
                }
                let tracking = (rng.below(3) == 0).then(|| Tracking::Set(props(rng, TrackingKind::Insert)));
                ops.push(ScanOp::Insert { text: s, tracking, comment_ids: None });
            }
            1 if left > 0 => {
                let n = 1 + rng.below(left.min(3));
                ops.push(ScanOp::Remove { n: b[k + n] - b[k] });
                k += n;
            }
            2 | 3 if left > 0 => {
                let n = 1 + rng.below(left.min(4));
                let tracking = match rng.below(5) {
                    0 => Some(Tracking::Set(props(rng, TrackingKind::Delete))),
                    1 => Some(Tracking::Clear),
                    2 => Some(Tracking::Set(props(rng, TrackingKind::Insert))),
                    _ => None,
                };
                ops.push(ScanOp::Retain { n: b[k + n] - b[k], tracking });
                k += n;
            }
            _ if left == 0 => break,
            _ => {}
        }
    }
    TextOperation::from_ops(ops).unwrap()
}

/// A random update: one or two edit operations, sometimes a comment.
fn random_update(rng: &mut Rng, fd: &FileData) -> Vec<EditOperation> {
    let mut w = fd.clone();
    let mut out = vec![];
    for _ in 0..1 + rng.below(2) {
        let op = if rng.below(5) == 0 && !w.content.is_empty() {
            let b = boundaries(&w.content);
            let s = rng.below(b.len() - 1);
            let e = s + 1 + rng.below(b.len() - 1 - s);
            EditOperation::AddComment { comment_id: format!("c{}", rng.below(3)), ranges: vec![Range { pos: b[s], length: b[e] - b[s] }], resolved: false }
        } else {
            EditOperation::Text(random_text_op(rng, &w.content))
        };
        w.apply(&op).unwrap();
        out.push(op);
    }
    out
}

/// A FileData with random history.
fn random_fd(rng: &mut Rng) -> FileData {
    let mut fd = FileData::new(text_from(rng, DOC, 12));
    for _ in 0..rng.below(4) {
        let u = random_update(rng, &fd);
        fd.apply_all(&u).unwrap();
    }
    fd
}

/// A random classic op on `vis`, with comments.
fn random_visible_op(rng: &mut Rng, vis: &str) -> Op {
    let mut d = vis.to_owned();
    let mut op = Op::new();
    for _ in 0..1 + rng.below(3) {
        let b = boundaries(&d);
        let c = match rng.below(6) {
            0..=2 => {
                let mut i = text_from(rng, INS, 3);
                if i.is_empty() {
                    i.push('q');
                }
                Component::Insert { p: b[rng.below(b.len())], i }
            }
            _ if b.len() < 2 => continue,
            3 | 4 => {
                let s = rng.below(b.len() - 1);
                let e = s + 1 + rng.below((b.len() - 1 - s).min(4));
                Component::Delete { p: b[s], d: ot2::units::slice16(&d, b[s], b[e]).unwrap().into() }
            }
            _ => {
                let s = rng.below(b.len() - 1);
                let e = s + 1 + rng.below(b.len() - 1 - s);
                Component::Comment { p: b[s], c: ot2::units::slice16(&d, b[s], b[e]).unwrap().into(), t: "cc".into() }
            }
        };
        d = text::apply(&d, std::slice::from_ref(&c)).unwrap();
        op.push(c);
    }
    op
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(5000))]

    /// An update's visible effect is the op `apply_projected` returns.
    #[test]
    fn projection_matches_visible_text(seed: u64) {
        let mut rng = Rng::new(seed);
        let mut fd = random_fd(&mut rng);
        let before = fd.visible();
        let u = random_update(&mut rng, &fd);
        let vis = fd.apply_projected(&u).unwrap();
        prop_assert_eq!(text::apply(&before, &vis).unwrap(), fd.visible(), "update {:?}", u);
        prop_assert_eq!(utf16_len(&fd.visible()), utf16_len(&fd.content) - fd.tracked.iter()
            .filter(|t| t.tracking.kind == TrackingKind::Delete).map(|t| t.range.length).sum::<usize>());
    }

    /// The update for a visible op makes that op's change to the visible text; tracked, it keeps deleted text.
    #[test]
    fn wire_makes_the_visible_change(seed: u64) {
        let mut rng = Rng::new(seed);
        let fd = random_fd(&mut rng);
        let vis = fd.visible();
        let op = random_visible_op(&mut rng, &vis);
        let want = text::apply(&vis, &op).unwrap();
        for track in [None, Some(("u9", "2026-02-01T00:00:00.000Z"))] {
            let wire = fd.to_wire(&op, track).unwrap();
            let mut after = fd.clone();
            let shown = after.apply_projected(&wire).unwrap();
            prop_assert_eq!(after.visible(), want.clone(), "track {:?} op {:?} wire {:?}", track, op, wire);
            prop_assert_eq!(text::apply(&vis, &shown).unwrap(), want.clone());
            if track.is_some() {
                let deleted: usize = op.iter().map(|c| match c { Component::Delete { d, .. } => utf16_len(d), _ => 0 }).sum();
                let inserted: usize = op.iter().map(|c| match c { Component::Insert { i, .. } => utf16_len(i), _ => 0 }).sum();
                prop_assert_eq!(utf16_len(&after.content), utf16_len(&fd.content) + inserted, "tracked deletes keep their text ({} deleted)", deleted);
            }
        }
    }

    /// TP1 on whole updates, content and visible text.
    #[test]
    fn transform_converges(seed: u64) {
        let mut rng = Rng::new(seed);
        let fd = random_fd(&mut rng);
        let a = random_update(&mut rng, &fd);
        let b = random_update(&mut rng, &fd);
        let (a2, b2) = filedata::transform(&a, &b).unwrap();
        let mut x = fd.clone();
        x.apply_all(&a).unwrap();
        x.apply_all(&b2).unwrap();
        let mut y = fd.clone();
        y.apply_all(&b).unwrap();
        y.apply_all(&a2).unwrap();
        prop_assert_eq!(&x.content, &y.content);
    }

    /// Mapping positions both ways.
    #[test]
    fn positions_round_trip(seed: u64) {
        let mut rng = Rng::new(seed);
        let fd = random_fd(&mut rng);
        let vis = fd.visible();
        for v in 0..=utf16_len(&vis) {
            prop_assert_eq!(fd.to_visible(fd.to_content(v)), v);
        }
    }
}
