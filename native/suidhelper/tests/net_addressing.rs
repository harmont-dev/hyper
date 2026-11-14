//! Laws of a node's address plan, over every prefix the config accepts rather than the
//! cookbook's one `/64`:
//! - a node prefix parses exactly when it is global unicast (`2000::/3`) and `/64` or
//!   shorter, and parsing clears its host bits;
//! - `<prefix>:1::/80` and every guest address sit inside the node prefix, each guest
//!   address maps back to its NetId, and distinct NetIds get distinct addresses;
//! - `Blocked::overlapping` agrees with an interval-intersection oracle, never pairs an
//!   IPv4 range with an IPv6 one, and names the first overlapping range.

use hyper_suidhelper::net::{Blocked, NetId, NodePrefix};
use hyperrs_linux::net::IpNet;
use proptest::prelude::*;
use std::net::{Ipv4Addr, Ipv6Addr};
use test_strategy::proptest;

fn mask(bits: u32, len: u8) -> u128 {
    match u32::from(len) {
        0 => 0,
        len => u128::MAX << (bits - len) & (u128::MAX >> (128 - bits)),
    }
}

fn net_id(id: u16) -> NetId {
    id.try_into().unwrap()
}

/// `[first, last]` of the addresses `net` covers, as integers.
fn interval(net: IpNet) -> (u128, u128, bool) {
    match net {
        IpNet::V4(net) => {
            let m = mask(32, net.prefix.get());
            let first = u128::from(u32::from(net.addr)) & m;
            (first, first | (!m & u128::from(u32::MAX)), false)
        }
        IpNet::V6(net) => {
            let m = mask(128, net.prefix.get());
            let first = u128::from(net.addr) & m;
            (first, first | !m, true)
        }
    }
}

fn shares_an_address(a: IpNet, b: IpNet) -> bool {
    let ((a0, a1, a6), (b0, b1, b6)) = (interval(a), interval(b));
    a6 == b6 && a0 <= b1 && b0 <= a1
}

fn global_unicast_prefix() -> impl Strategy<Value = (Ipv6Addr, u8)> {
    (any::<u128>(), 3u8..=64).prop_map(|(bits, len)| {
        let addr = (bits & !(0b111 << 125)) | (0b001 << 125);
        (Ipv6Addr::from(addr), len)
    })
}

fn ip_net() -> impl Strategy<Value = IpNet> {
    prop_oneof![
        (any::<u32>(), 0u8..=32).prop_map(|(a, l)| format!("{}/{l}", Ipv4Addr::from(a))),
        (any::<u128>(), 0u8..=128).prop_map(|(a, l)| format!("{}/{l}", Ipv6Addr::from(a))),
        (0u8..=255, 0u8..=255, 8u8..=24).prop_map(|(a, b, l)| format!("10.{a}.{b}.0/{l}")),
        (0u16..4, 0u8..=128).prop_map(|(a, l)| format!("2001:db8:{a}::/{l}")),
    ]
    .prop_map(|s| s.parse().unwrap())
}

#[proptest]
fn a_node_prefix_parses_exactly_when_global_unicast_and_at_most_64_bits(
    addr: u128,
    #[strategy(0u8..=128)] len: u8,
) {
    let s = format!("{}/{len}", Ipv6Addr::from(addr));
    let global = len >= 3 && addr >> 125 == 0b001;
    let parsed = s.parse::<NodePrefix>();

    prop_assert_eq!(parsed.is_ok(), global && len <= 64, "{}", s);
    if let Ok(prefix) = parsed {
        prop_assert_eq!(u128::from(prefix.get().addr), addr & mask(128, len));
        prop_assert_eq!(prefix.get().prefix.get(), len);
    }
}

#[proptest]
fn every_guest_address_sits_in_the_node_prefix_and_maps_back_to_its_net_id(
    #[strategy(global_unicast_prefix())] node: (Ipv6Addr, u8),
    #[strategy(0u16..NetId::COUNT)] id: u16,
) {
    let (addr, len) = node;
    let prefix: NodePrefix = format!("{addr}/{len}").parse().unwrap();
    let network = u128::from(prefix.get().addr);
    let range = prefix.vm_range();
    let guest = prefix.guest(net_id(id));

    prop_assert_eq!(range.prefix.get(), 80);
    prop_assert_eq!(u128::from(range.addr) & mask(128, len), network);
    prop_assert_eq!(u128::from(guest) & mask(128, 80), u128::from(range.addr));
    prop_assert_eq!(u128::from(guest) & mask(128, len), network);
    prop_assert_eq!(prefix.guest_net_id(guest), Some(net_id(id)));
}

#[proptest]
fn distinct_net_ids_get_distinct_guest_addresses_under_any_prefix(
    #[strategy(global_unicast_prefix())] node: (Ipv6Addr, u8),
    #[strategy(0u16..NetId::COUNT)] a: u16,
    #[strategy(0u16..NetId::COUNT)] b: u16,
) {
    prop_assume!(a != b);
    let (addr, len) = node;
    let prefix: NodePrefix = format!("{addr}/{len}").parse().unwrap();

    prop_assert_ne!(prefix.guest(net_id(a)), prefix.guest(net_id(b)));
}

#[proptest]
fn no_address_outside_the_vm_range_maps_to_a_net_id(
    #[strategy(global_unicast_prefix())] node: (Ipv6Addr, u8),
    addr: u128,
) {
    let (prefix_addr, len) = node;
    let prefix: NodePrefix = format!("{prefix_addr}/{len}").parse().unwrap();

    if let Some(id) = prefix.guest_net_id(Ipv6Addr::from(addr)) {
        prop_assert_eq!(u128::from(prefix.guest(id)), addr);
    }
}

#[proptest]
fn overlapping_names_the_first_blocked_range_sharing_an_address(
    #[strategy(prop::collection::vec(ip_net(), 0..8))] ranges: Vec<IpNet>,
    #[strategy(ip_net())] net: IpNet,
) {
    let blocked =
        Blocked::try_from(ranges.iter().map(ToString::to_string).collect::<Vec<_>>()).unwrap();

    prop_assert_eq!(
        blocked.overlapping(net),
        ranges
            .iter()
            .copied()
            .find(|range| shares_an_address(net, *range))
    );
}

#[proptest]
fn overlap_is_symmetric(#[strategy(ip_net())] a: IpNet, #[strategy(ip_net())] b: IpNet) {
    let blocked = |net: IpNet| Blocked::try_from(vec![net.to_string()]).unwrap();

    prop_assert_eq!(
        blocked(b).overlapping(a).is_some(),
        blocked(a).overlapping(b).is_some()
    );
}
