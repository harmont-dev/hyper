//! Laws of `diff_copy`:
//!   * oracle/round-trip: with `dst` starting byte-identical to `reference`,
//!     after `diff_copy(src, Some(reference), dst)` the dst equals `src`;
//!   * no-reference copy: `diff_copy(src, None, dst)` makes dst equal `src`;
//!   * frugality: `written_chunks <= scanned_chunks`, and when `src == reference`
//!     nothing is written at all (the COW store must not absorb no-op chunks).

use hyper_suidhelper::tools::blockcopy::diff_copy;
use proptest::prelude::*;
use std::io::Cursor;

proptest! {
    #[test]
    fn dst_equals_src_and_only_diffs_are_written(
        src in proptest::collection::vec(any::<u8>(), 0..8192),
        seed in proptest::collection::vec(any::<u8>(), 0..8192),
        chunk in 1u64..600,
    ) {
        // reference has src's length (devices are equal-sized); bytes differ freely.
        let reference: Vec<u8> =
            src.iter().zip(seed.iter().cycle().chain(std::iter::repeat(&0)))
               .map(|(s, r)| s ^ r).collect();
        let mut dst = Cursor::new(reference.clone());

        let stats = diff_copy(
            &mut Cursor::new(&src),
            Some(&mut Cursor::new(&reference)),
            &mut dst,
            chunk as usize,
        ).unwrap();

        prop_assert_eq!(dst.into_inner(), src.clone());
        prop_assert!(stats.written_chunks <= stats.scanned_chunks);
        prop_assert_eq!(stats.scanned_chunks, (src.len() as u64).div_ceil(chunk));
    }

    #[test]
    fn no_reference_is_a_full_copy(
        src in proptest::collection::vec(any::<u8>(), 0..8192),
        chunk in 1u64..600,
    ) {
        let mut dst = Cursor::new(vec![0xAAu8; src.len()]);
        diff_copy(&mut Cursor::new(&src), None, &mut dst, chunk as usize).unwrap();
        prop_assert_eq!(dst.into_inner(), src);
    }

    #[test]
    fn identical_src_and_reference_writes_nothing(
        src in proptest::collection::vec(any::<u8>(), 1..8192),
        chunk in 1u64..600,
    ) {
        let mut dst = Cursor::new(src.clone());
        let stats = diff_copy(
            &mut Cursor::new(&src),
            Some(&mut Cursor::new(&src)),
            &mut dst,
            chunk as usize,
        ).unwrap();
        prop_assert_eq!(stats.written_chunks, 0);
    }
}
