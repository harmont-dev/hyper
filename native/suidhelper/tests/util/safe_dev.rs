//! Property tests for the device/name validators — the lexical gate that keeps
//! the privileged tools off arbitrary storage and blocks path tricks. Runs
//! against the `hyper_suidhelper` library crate, not inline in source.

use hyper_suidhelper::util::safe_dev::BlockDev;
use proptest::prelude::*;
use std::path::Path;

fn dm_suffix() -> impl Strategy<Value = String> {
    "[0-9A-Za-z#+.:=@_-]{0,16}"
}

proptest! {
    #[test]
    fn accepts_loop_and_preserves_path(n in any::<u32>()) {
        let s = format!("/dev/loop{n}");
        let dev = s.parse::<BlockDev>().unwrap();
        prop_assert_eq!(dev.path().as_path(), Path::new(&s));
    }

    #[test]
    fn accepts_hyper_dm_and_preserves_path(suffix in dm_suffix()) {
        let s = format!("/dev/mapper/hyper-{suffix}");
        let dev = s.parse::<BlockDev>().unwrap();
        prop_assert_eq!(dev.path().as_path(), Path::new(&s));
    }

    // BlockDev rejects a non-hyper dm device (e.g. `/dev/mapper/cryptroot`) —
    // any mapper name not starting with `hyper-`.
    #[test]
    fn rejects_non_hyper_dm(name in "[a-z][a-z0-9._-]{0,12}") {
        prop_assume!(!name.starts_with("hyper-"));
        let s = format!("/dev/mapper/{name}");
        prop_assert!(s.parse::<BlockDev>().is_err());
    }
}

#[test]
fn rejects_known_attack_strings() {
    for bad in [
        "/dev/loop",
        "/dev/loop0/../sda",
        "/dev/loopX",
        "/dev/loop00",
        "/dev/loop4294967296",
        "/dev/sda",
        "/dev/mapper/hyper-x/../../sda",
        "/dev/mapper/hyper-x/",
        "/dev/mapper/cryptroot",
        "/dev/mapper/control",
        "../dev/loop0",
    ] {
        assert!(
            bad.parse::<BlockDev>().is_err(),
            "BlockDev accepted {bad:?}"
        );
    }
}
