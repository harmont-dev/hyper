//! Laws of `diff_copy`:
//!   * oracle/round-trip: with `dst` starting byte-identical to `reference`,
//!     after `diff_copy(src, Some(reference), dst)` the dst equals `src`;
//!   * no-reference copy: `diff_copy(src, None, dst)` makes dst equal `src`;
//!   * frugality: `written_chunks <= scanned_chunks`, and when `src == reference`
//!     nothing is written at all (the COW store must not absorb no-op chunks).
//!   * reference EOF: chunks past a shorter reference always count as differing and are written.
//!   * ranged copy: dst equals src exactly on the listed block ranges and is untouched elsewhere; empty ranges write nothing.

use hyper_suidhelper::tools::blockcopy::{copy_ranges, diff_copy, RangeSpec};
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

    #[test]
    fn truncated_reference_tail_is_always_written(
        src in proptest::collection::vec(any::<u8>(), 1..8192),
        cut in any::<prop::sample::Index>(),
        chunk in 1u64..600,
    ) {
        // A reference that is a strict prefix of src: identical up to ref_len,
        // then EOF. dst starts as the reference padded with a sentinel — the
        // state a dm-snapshot over the reference would read back.
        let ref_len = cut.index(src.len());
        let reference = src[..ref_len].to_vec();
        let mut dst_init = reference.clone();
        dst_init.resize(src.len(), 0xAA);
        let mut dst = Cursor::new(dst_init);

        diff_copy(
            &mut Cursor::new(&src),
            Some(&mut Cursor::new(&reference)),
            &mut dst,
            chunk as usize,
        ).unwrap();

        prop_assert_eq!(dst.into_inner(), src);
    }

    #[test]
    fn ranged_copy_writes_exactly_the_listed_ranges(
        src in proptest::collection::vec(any::<u8>(), 512..8192),
        cuts in proptest::collection::vec((0usize..16, 1usize..4), 0..6),
        block_sectors in prop_oneof![Just(1u64), Just(2u64)],
        chunk in 64u64..600,
    ) {
        let block_bytes = (block_sectors * 512) as usize;
        let n_blocks = src.len() / block_bytes;
        prop_assume!(n_blocks > 0);

        // Clamp generated cuts into valid (begin, len) block ranges.
        let ranges: Vec<(u64, u64)> = cuts
            .iter()
            .map(|&(b, l)| {
                let begin = b % n_blocks;
                let len = l.min(n_blocks - begin).max(1);
                (begin as u64, len as u64)
            })
            .collect();

        let spec = RangeSpec { block_sectors, ranges: ranges.clone() };
        let sentinel = vec![0xAAu8; src.len()];
        let mut dst = Cursor::new(sentinel.clone());

        copy_ranges(&mut Cursor::new(&src), &mut dst, &spec, chunk as usize).unwrap();
        let out = dst.into_inner();

        // Oracle: build the expected image byte-by-byte from the range list.
        let mut expected = sentinel;
        for &(begin, len) in &ranges {
            let a = (begin as usize) * block_bytes;
            let b = a + (len as usize) * block_bytes;
            expected[a..b].copy_from_slice(&src[a..b]);
        }

        prop_assert_eq!(out, expected);
    }

    #[test]
    fn empty_ranges_write_nothing(
        src in proptest::collection::vec(any::<u8>(), 1..4096),
        chunk in 1u64..600,
    ) {
        let spec = RangeSpec { block_sectors: 1, ranges: vec![] };
        let mut dst = Cursor::new(vec![0xAAu8; src.len()]);

        let stats = copy_ranges(&mut Cursor::new(&src), &mut dst, &spec, chunk as usize).unwrap();

        prop_assert_eq!(stats.written_chunks, 0);
        prop_assert_eq!(dst.into_inner(), vec![0xAAu8; src.len()]);
    }
}
