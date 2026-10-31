use hyper_suidhelper::firecracker::id::{JailUid, UidGidRange};
use hyper_suidhelper::firecracker::jailer::VmId;
use hyper_suidhelper::tools::network::addr::{self, AddrError, Plan};
use proptest::prelude::*;
use std::net::Ipv4Addr;
use std::str::FromStr;

const POOL: Ipv4Addr = Ipv4Addr::new(172, 31, 0, 0);
const FLOOR: u32 = 900_000;

fn range() -> UidGidRange {
    UidGidRange::try_from([FLOOR, 999_999]).unwrap()
}

fn jail_uid(n: u32) -> JailUid {
    range().uid(n).unwrap()
}

fn vm_id() -> VmId {
    VmId::from_str("vaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa").unwrap()
}

#[test]
fn slot_zero_is_first_block() {
    let p = Plan::derive(jail_uid(FLOOR), range(), POOL, &vm_id()).unwrap();
    assert_eq!(p.slot, 0);
    assert_eq!(p.veth_host_ip, Ipv4Addr::new(172, 31, 0, 1));
    assert_eq!(p.veth_ns_ip, Ipv4Addr::new(172, 31, 0, 2));
    assert_eq!(p.veth_host, "hv0");
    assert_eq!(p.veth_ns, "hp0");
}

#[test]
fn uid_below_range_is_refused() {
    assert!(matches!(
        Plan::derive(
            UidGidRange::try_from([1, 100]).unwrap().uid(42).unwrap(),
            range(),
            POOL,
            &vm_id()
        ),
        Err(AddrError::UidBelowRange { .. })
    ));
}

proptest! {
    // Inner and clone address spaces never overlap, and veth names always fit
    // IFNAMSIZ, for every uid the helper would ever accept.
    #[test]
    fn derived_plan_is_well_formed(offset in 0u32..16_384) {
        let uid = FLOOR + offset;
        let p = Plan::derive(jail_uid(uid), range(), POOL, &vm_id()).unwrap();
        prop_assert!(p.veth_host.len() <= 15 && p.veth_ns.len() <= 15);
        // clone addresses live in 172.31/16, never in the inner 172.30/30
        prop_assert_eq!(p.veth_host_ip.octets()[1], 31);
        prop_assert_ne!(p.veth_host_ip, addr::INNER_GUEST_IP);
        // host and ns ends are distinct and adjacent
        prop_assert_eq!(u32::from(p.veth_ns_ip), u32::from(p.veth_host_ip) + 1);
    }

    // A slot past the /16's capacity is always refused, never wrapped.
    #[test]
    fn slot_past_pool_is_refused(offset in 16_384u32..40_000) {
        let uid = FLOOR + offset;
        let result = Plan::derive(jail_uid(uid), range(), POOL, &vm_id());
        let is_slot_out_of_pool = matches!(result, Err(AddrError::SlotOutOfPool { .. }));
        prop_assert!(is_slot_out_of_pool);
    }

    // Two distinct uids always derive non-overlapping /30 blocks: the gap
    // between their veth_host_ip addresses is exactly 4x the slot distance,
    // never wrapping one VM's address into another's.
    #[test]
    fn distinct_slots_never_share_a_block(
        offset_a in 0u32..16_384,
        offset_b in 0u32..16_384,
    ) {
        let uid_a = FLOOR + offset_a;
        let uid_b = FLOOR + offset_b;
        let plan_a = Plan::derive(jail_uid(uid_a), range(), POOL, &vm_id()).unwrap();
        let plan_b = Plan::derive(jail_uid(uid_b), range(), POOL, &vm_id()).unwrap();

        let ip_a = u32::from(plan_a.veth_host_ip);
        let ip_b = u32::from(plan_b.veth_host_ip);
        let slot_gap = i64::from(plan_b.slot) - i64::from(plan_a.slot);
        let ip_gap = i64::from(ip_b) - i64::from(ip_a);

        prop_assert_eq!(ip_gap, slot_gap * 4);
        if plan_a.slot != plan_b.slot {
            prop_assert_ne!(ip_a, ip_b);
        }
    }
}
