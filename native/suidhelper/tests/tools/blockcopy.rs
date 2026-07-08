//! Laws of `copy_ranges`:
//!   * ranged copy: dst equals src exactly on the listed block ranges and is untouched elsewhere; empty ranges write nothing.

use hyper_suidhelper::tools::blockcopy::{copy_ranges, RangeSpec};
use proptest::prelude::*;
use std::io::Cursor;

proptest! {
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
