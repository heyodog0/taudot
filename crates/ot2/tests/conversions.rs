//! Diffs and conversions between the engine's byte-offset edits and the classic format, on random text.

mod common;

use common::{random_op, random_text, Rng};
use ot2::edit::{self, Edit};
use ot2::text;
use ot2::units::{byte_to_utf16, pack_latin1, unpack_latin1, utf16_to_byte};
use proptest::prelude::*;

proptest! {
    #![proptest_config(ProptestConfig::with_cases(3000))]

    #[test]
    fn diff_turns_one_text_into_another(seed: u64) {
        let mut rng = Rng::new(seed);
        let a = random_text(&mut rng, 30);
        let b = if rng.below(2) == 0 {
            random_text(&mut rng, 30)
        } else {
            text::apply(&a, &random_op(&mut rng, &a, 4, false)).unwrap()
        };
        prop_assert_eq!(text::apply(&a, &ot2::diff::diff(&a, &b)).unwrap(), b);
    }

    #[test]
    fn classic_to_edits_and_back(seed: u64) {
        let mut rng = Rng::new(seed);
        let doc = random_text(&mut rng, 20);
        let op = random_op(&mut rng, &doc, 5, true);
        let after = text::apply(&doc, &op).unwrap();
        let edits: Vec<Edit> = edit::from_classic(&doc, &op).unwrap();
        prop_assert_eq!(edit::apply(&doc, &edits).unwrap(), after.clone());
        let back = edit::to_classic(&doc, &edits).unwrap();
        prop_assert_eq!(text::apply(&doc, &back).unwrap(), after);
    }

    #[test]
    fn index_round_trip(s in "[a-zé中😀𝔸\n]{0,20}", pick: usize) {
        let bytes: Vec<usize> = s.char_indices().map(|(b, _)| b).chain([s.len()]).collect();
        let b = bytes[pick % bytes.len()];
        let u = byte_to_utf16(&s, b).unwrap();
        prop_assert_eq!(utf16_to_byte(&s, u).unwrap(), b);
        prop_assert_eq!(u, s[..b].encode_utf16().count());
    }

    #[test]
    fn latin1_round_trip(s in "\\PC{0,30}") {
        prop_assert_eq!(unpack_latin1(&pack_latin1(&s)).unwrap(), s);
    }
}
