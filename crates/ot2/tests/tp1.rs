//! Transform property 1 for random multi-component classic ops: applying `a` then `b'` gives the same text as `b`
//! then `a'`.

mod common;

use common::{random_op, random_text, Rng};
use ot2::text::{apply, compose, transform, transform_x, Side};
use proptest::prelude::*;

proptest! {
    #![proptest_config(ProptestConfig::with_cases(5000))]

    #[test]
    fn tp1(seed: u64, comments: bool) {
        let mut rng = Rng::new(seed);
        let doc = random_text(&mut rng, 12);
        let a = random_op(&mut rng, &doc, 4, comments);
        let b = random_op(&mut rng, &doc, 4, comments);
        let (a2, b2) = transform_x(&a, &b).unwrap();
        let x = apply(&apply(&doc, &a).unwrap(), &b2).unwrap();
        let y = apply(&apply(&doc, &b).unwrap(), &a2).unwrap();
        prop_assert_eq!(&x, &y, "doc={:?} a={:?} b={:?}", doc, a, b);
        prop_assert_eq!(transform(&a, &b, Side::Left).unwrap(), a2);
        prop_assert_eq!(transform(&b, &a, Side::Right).unwrap(), b2);
    }

    /// Transforming past a composed op equals transforming past its parts in turn, which is what the client state
    /// machine relies on when it composes pending edits.
    #[test]
    fn transform_past_composition(seed: u64) {
        let mut rng = Rng::new(seed);
        let doc = random_text(&mut rng, 12);
        let a = random_op(&mut rng, &doc, 3, false);
        let b1 = random_op(&mut rng, &doc, 3, false);
        let mid = apply(&doc, &b1).unwrap();
        let b2 = random_op(&mut rng, &mid, 3, false);
        let b = compose(&b1, &b2);
        prop_assert_eq!(apply(&doc, &b).unwrap(), apply(&mid, &b2).unwrap());
        let whole = apply(&apply(&doc, &b).unwrap(), &transform(&a, &b, Side::Left).unwrap()).unwrap();
        let a1 = transform(&a, &b1, Side::Left).unwrap();
        let steps = apply(&apply(&mid, &b2).unwrap(), &transform(&a1, &b2, Side::Left).unwrap()).unwrap();
        prop_assert_eq!(whole, steps);
    }
}
