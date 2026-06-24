//! Property tests for the device/name validators — the lexical gate that keeps
//! the privileged tools off arbitrary storage and blocks path tricks. Runs
//! against the `hyper_suidhelper` library crate, not inline in source.

use hyper_suidhelper::util::safe_dev::{BlockDev, DmName, LoopDev};
use proptest::prelude::*;
use std::path::Path;

// The charset of a valid `hyper-*` dm name suffix: ascii-alphanumeric plus
// `-`/`_`/`.`. Crucially excludes `/`, so a valid name can never traverse.
fn name_suffix() -> impl Strategy<Value = String> {
    "[a-zA-Z0-9._-]{0,16}"
}

proptest! {
    // LoopDev accepts exactly `/dev/loop<digits>` and preserves the path.
    #[test]
    fn loopdev_accepts_dev_loop_n(n in any::<u64>()) {
        let s = format!("/dev/loop{n}");
        let dev = s.parse::<LoopDev>().unwrap();
        prop_assert_eq!(dev.as_ref(), Path::new(&s));
    }

    // A `/dev/loop` whose suffix is empty or starts with a non-digit is never a
    // valid loop device (covers `/dev/loop`, `/dev/loopX`, and path tricks whose
    // first post-prefix byte is non-numeric).
    #[test]
    fn loopdev_rejects_non_numeric_suffix(suffix in "([^0-9].*)?") {
        let s = format!("/dev/loop{suffix}");
        prop_assert!(s.parse::<LoopDev>().is_err());
    }

    // A digit-led suffix that then contains any non-digit (e.g. `0/../sda`,
    // `1a`, `2/x`) is rejected: is_loop requires the WHOLE suffix to be digits.
    #[test]
    fn loopdev_rejects_digit_then_junk(n in any::<u32>(), junk in "[^0-9].*") {
        let s = format!("/dev/loop{n}{junk}");
        prop_assert!(s.parse::<LoopDev>().is_err());
    }

    // BlockDev accepts a valid loop device.
    #[test]
    fn blockdev_accepts_loop(n in any::<u64>()) {
        let s = format!("/dev/loop{n}");
        prop_assert!(s.parse::<BlockDev>().is_ok());
    }

    // BlockDev accepts a valid `/dev/mapper/hyper-*` dm device.
    #[test]
    fn blockdev_accepts_hyper_dm(suffix in name_suffix()) {
        let s = format!("/dev/mapper/hyper-{suffix}");
        prop_assert!(s.parse::<BlockDev>().is_ok());
    }

    // BlockDev rejects a non-hyper dm device (e.g. `/dev/mapper/cryptroot`) —
    // any mapper name not starting with `hyper-`.
    #[test]
    fn blockdev_rejects_non_hyper_dm(name in "[a-z][a-z0-9]{0,12}") {
        prop_assume!(!name.starts_with("hyper-"));
        let s = format!("/dev/mapper/{name}");
        prop_assert!(s.parse::<BlockDev>().is_err());
    }

    // DmName accepts a `hyper-*` safe name and round-trips it through Display.
    #[test]
    fn dmname_accepts_hyper_name(suffix in name_suffix()) {
        let s = format!("hyper-{suffix}");
        let dm = s.parse::<DmName>().unwrap();
        prop_assert_eq!(dm.to_string(), s);
    }

    // DmName rejects any name containing a `/` — the no-traversal guarantee.
    #[test]
    fn dmname_rejects_any_slash(pre in name_suffix(), post in name_suffix()) {
        let s = format!("hyper-{pre}/{post}");
        prop_assert!(s.parse::<DmName>().is_err());
    }

    // DmName rejects a name not starting with `hyper-`.
    #[test]
    fn dmname_rejects_non_hyper_prefix(s in "[a-z][a-zA-Z0-9._-]{0,12}") {
        prop_assume!(!s.starts_with("hyper-"));
        prop_assert!(s.parse::<DmName>().is_err());
    }
}

// A curated set of concrete attack/edge strings that no generator is guaranteed
// to hit, asserted explicitly. These are the cases the validators exist to stop.
#[test]
fn rejects_known_attack_strings() {
    for bad in [
        "/dev/loop",                     // empty number
        "/dev/loop0/../sda",             // traversal off a loop dev
        "/dev/loopX",                    // non-numeric
        "/dev/sda",                      // arbitrary storage
        "/dev/mapper/hyper-x/../../sda", // traversal via a hyper-looking name
        "/dev/mapper/cryptroot",         // non-hyper dm
        "../dev/loop0",                  // relative
    ] {
        assert!(bad.parse::<LoopDev>().is_err(), "LoopDev accepted {bad:?}");
        assert!(
            bad.parse::<BlockDev>().is_err(),
            "BlockDev accepted {bad:?}"
        );
    }
    for bad in [
        "sda",
        "hyper",
        "nothyper-x",
        "hyper-x/y",
        "hyper-../x",
        "/hyper-x",
    ] {
        assert!(bad.parse::<DmName>().is_err(), "DmName accepted {bad:?}");
    }
}
