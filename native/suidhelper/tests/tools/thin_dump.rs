//! Laws of the thin_dump mappings parser:
//!   * oracle: rendering a known device map to thin_dump's XML shape and
//!     parsing it back yields exactly the target device's ranges (singles as
//!     length-1) and the superblock's data_block_size;
//!   * scoping: mappings of OTHER devices in the same dump never leak into
//!     the target's ranges (kills a lost `</device>` transition);
//!   * refusal: a dump without the target dev_id is an error, never an empty
//!     success (an empty result must mean "device exists, no writes");
//!   * a missing superblock is an error;
//!   * integrity: the parsed ranges' total length must equal the target
//!     device's own `mapped_blocks` attribute, so a dump truncated mid-device
//!     is an error, never a silently short success;
//!   * anchoring: every attribute lookup is anchored on a leading space, so a
//!     key can never match as the suffix of another attribute's name (e.g.
//!     `dev_id` inside `snap_dev_id`).

use hyper_suidhelper::tools::thin_dump::{parse_mappings, Error, ThinMappings};
use proptest::prelude::*;

#[derive(Debug, Clone)]
enum M {
    Range { begin: u64, len: u64 },
    Single { block: u64 },
}

fn mapping() -> impl Strategy<Value = M> {
    prop_oneof![
        (0u64..1 << 20, 1u64..512).prop_map(|(begin, len)| M::Range { begin, len }),
        (0u64..1 << 20).prop_map(|block| M::Single { block }),
    ]
}

fn render_device(dev_id: u64, maps: &[M]) -> String {
    if maps.is_empty() {
        // thin_dump self-closes an empty device.
        return format!("  <device dev_id=\"{dev_id}\" mapped_blocks=\"0\" transaction=\"0\" creation_time=\"0\" snap_time=\"1\"/>\n");
    }

    let mapped: u64 = maps
        .iter()
        .map(|m| match m {
            M::Range { len, .. } => *len,
            M::Single { .. } => 1,
        })
        .sum();

    let mut s = format!("  <device dev_id=\"{dev_id}\" mapped_blocks=\"{mapped}\" transaction=\"0\" creation_time=\"0\" snap_time=\"1\">\n");
    for m in maps {
        match m {
            M::Range { begin, len } => s.push_str(&format!(
                "    <range_mapping origin_begin=\"{begin}\" data_begin=\"7\" length=\"{len}\" time=\"0\"/>\n"
            )),
            M::Single { block } => s.push_str(&format!(
                "    <single_mapping origin_block=\"{block}\" data_block=\"9\" time=\"0\"/>\n"
            )),
        }
    }
    s.push_str("  </device>\n");
    s
}

fn render(block_sectors: u64, devices: &[(u64, Vec<M>)]) -> String {
    let mut s = format!(
        "<superblock uuid=\"\" time=\"1\" transaction=\"2\" flags=\"0\" version=\"2\" data_block_size=\"{block_sectors}\" nr_data_blocks=\"16384\">\n"
    );
    for (id, maps) in devices {
        s.push_str(&render_device(*id, maps));
    }
    s.push_str("</superblock>\n");
    s
}

fn expected_ranges(maps: &[M]) -> Vec<(u64, u64)> {
    maps.iter()
        .map(|m| match m {
            M::Range { begin, len } => (*begin, *len),
            M::Single { block } => (*block, 1),
        })
        .collect()
}

proptest! {
    #[test]
    fn extracts_exactly_the_target_devices_ranges(
        block_sectors in 1u64..4096,
        target_maps in proptest::collection::vec(mapping(), 0..64),
        sibling_maps in proptest::collection::vec(mapping(), 0..64),
    ) {
        // Sibling before AND after the target: leaked scoping in either
        // direction corrupts the result.
        let xml = render(block_sectors, &[(1, sibling_maps.clone()), (3, target_maps.clone()), (5, sibling_maps.clone())]);
        let got = parse_mappings(&xml, 3).unwrap();

        prop_assert_eq!(got.block_sectors, block_sectors);
        prop_assert_eq!(got.ranges, expected_ranges(&target_maps));
    }

    #[test]
    fn absent_device_is_an_error_not_empty(
        maps in proptest::collection::vec(mapping(), 0..16),
    ) {
        let xml = render(128, &[(1, maps)]);
        prop_assert!(matches!(parse_mappings(&xml, 99), Err(Error::DeviceNotFound(99))));
    }

    #[test]
    fn truncated_target_device_is_an_error(
        block_sectors in 1u64..4096,
        target_maps in proptest::collection::vec(mapping(), 1..64),
    ) {
        let xml = render(block_sectors, &[(3, target_maps)]);
        // Cut inside the target device: drop the final mapping line together
        // with </device> and </superblock>.
        let cut: String = xml
            .lines()
            .rev()
            .skip(3)
            .collect::<Vec<_>>()
            .into_iter()
            .rev()
            .map(|l| format!("{l}\n"))
            .collect();
        let is_truncated = matches!(parse_mappings(&cut, 3), Err(Error::Truncated { .. }));
        prop_assert!(is_truncated);
    }
}

#[test]
fn missing_superblock_is_an_error() {
    assert!(matches!(
        parse_mappings("<device dev_id=\"3\" mapped_blocks=\"0\"></device>", 3),
        Err(Error::NoSuperblock)
    ));
}

#[test]
fn empty_self_closing_device_parses_to_no_ranges() {
    let xml = render(128, &[(3, vec![])]);
    assert_eq!(
        parse_mappings(&xml, 3).unwrap(),
        ThinMappings {
            block_sectors: 128,
            ranges: vec![]
        }
    );
}

#[test]
fn attribute_lookup_is_anchored_not_suffix_matched() {
    // `snap_dev_id` is a decoy: an unanchored lookup for `dev_id` would match
    // inside it, read 9, and report the real device 3 as missing.
    let xml = "<superblock uuid=\"\" time=\"1\" transaction=\"2\" flags=\"0\" version=\"2\" data_block_size=\"128\" nr_data_blocks=\"1\">\n  <device snap_dev_id=\"9\" dev_id=\"3\" mapped_blocks=\"1\" transaction=\"0\" creation_time=\"0\" snap_time=\"1\">\n    <range_mapping origin_begin=\"0\" data_begin=\"0\" length=\"1\" time=\"0\"/>\n  </device>\n</superblock>\n";
    assert_eq!(parse_mappings(xml, 3).unwrap().ranges, vec![(0, 1)]);
}
