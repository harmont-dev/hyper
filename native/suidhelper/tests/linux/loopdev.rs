use hyper_suidhelper::linux::loopdev::LoopDevNum;
use proptest::prelude::*;
use std::path::Path;

proptest! {
    #[test]
    fn canonical_names_round_trip(n in any::<u32>()) {
        let s = format!("/dev/loop{n}");
        let num: LoopDevNum = s.parse().unwrap();
        prop_assert_eq!(num.get(), n);
        prop_assert_eq!(num.to_string(), s.clone());
        let path = num.path().unwrap();
        prop_assert_eq!(path.as_path(), Path::new(&s));
    }

    #[test]
    fn rejects_leading_zeros(digits in "0[0-9]{1,9}") {
        let s = format!("/dev/loop{digits}");
        prop_assert!(s.parse::<LoopDevNum>().is_err());
    }

    #[test]
    fn rejects_values_past_u32(n in (u64::from(u32::MAX) + 1)..=u64::MAX) {
        let s = format!("/dev/loop{n}");
        prop_assert!(s.parse::<LoopDevNum>().is_err());
    }

    #[test]
    fn rejects_non_numeric_suffix(suffix in "([^0-9].*)?") {
        let s = format!("/dev/loop{suffix}");
        prop_assert!(s.parse::<LoopDevNum>().is_err());
    }

    #[test]
    fn rejects_digit_then_junk(n in any::<u32>(), junk in "[^0-9].*") {
        let s = format!("/dev/loop{n}{junk}");
        prop_assert!(s.parse::<LoopDevNum>().is_err());
    }
}

#[test]
fn rejects_known_attack_strings() {
    for bad in [
        "/dev/loop",
        "/dev/loop+7",
        "/dev/loop-1",
        "/dev/loop0/../sda",
        "/dev/sda",
        "../dev/loop0",
        "dev/loop0",
        "/dev//loop0",
        "7",
    ] {
        assert!(bad.parse::<LoopDevNum>().is_err(), "accepted {bad:?}");
    }
}
