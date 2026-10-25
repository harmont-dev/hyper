//! Refusal contracts for the jailer's argument newtypes — the security core. A
//! valid input must round-trip to its canonical form; an invalid one must
//! *always* be rejected, never silently accepted. These properties are what stop
//! a compromised BEAM from naming a privileged path, a traversal, or a flag
//! through the jailer subcommand. (VM id and uid/gid refusals: `tests/vm.rs`.)

use hyper_suidhelper::tools::jailer::{CgroupSetting, JailSock};
use proptest::prelude::*;
use std::str::FromStr;

proptest! {
    /// A valid `memory.max` setting re-renders to exactly `key=value`.
    #[test]
    fn cgroup_memory_round_trips(s in "memory[.]max=([0-9]{1,20}|max)") {
        prop_assert_eq!(CgroupSetting::from_str(&s).unwrap().to_string(), s);
    }

    /// A valid `cpu.max` setting re-renders to exactly `key=value`.
    #[test]
    fn cgroup_cpu_round_trips(s in "cpu[.]max=([0-9]{1,20} [0-9]{1,20}|max [0-9]{1,20})") {
        prop_assert_eq!(CgroupSetting::from_str(&s).unwrap().to_string(), s);
    }

    /// A single-filename absolute socket path round-trips; `.`/`..` filenames are
    /// rejected even though they are within the charset.
    #[test]
    fn jailsock_single_filename(name in "[A-Za-z0-9_.-]{1,40}") {
        let s = format!("/{name}");
        let res = JailSock::from_str(&s);
        if name == "." || name == ".." {
            prop_assert!(res.is_err());
        } else {
            prop_assert_eq!(res.unwrap().to_string(), s);
        }
    }

    /// A second path component is always rejected (the socket must be a direct
    /// child of `/`).
    #[test]
    fn jailsock_multi_component_rejected(
        a in "[A-Za-z0-9_]{1,10}",
        b in "[A-Za-z0-9_]{1,10}",
    ) {
        let s = format!("/{a}/{b}");
        prop_assert!(JailSock::from_str(&s).is_err());
    }
}

#[test]
fn cgroup_rejects_known_bad_shapes() {
    for bad in [
        "linear=10",               // unknown key
        "memory.high=10",          // unknown key
        "memory.max=",             // empty value
        "memory.max=12x",          // non-digit
        "memory.max=1=2",          // second '='
        "memory.max",              // no '='
        "cpu.max=100000",          // missing period field
        "cpu.max=100000 100000 5", // extra field
        "cpu.max=x 100000",        // bad quota
        "cpu.max=max max",         // bad period
        "cpu.max=max",             // missing period
    ] {
        assert!(
            CgroupSetting::from_str(bad).is_err(),
            "CgroupSetting accepted {bad:?}"
        );
    }
}

#[test]
fn jailsock_rejects_known_bad_shapes() {
    for bad in [
        "",         // empty
        "relative", // not absolute
        "/",        // no filename
        "/a/b",     // multi-component
        "/../etc",  // traversal
        "/..",      // traversal as whole filename
        "/.",       // current dir
        "/a b",     // whitespace
        "/a\0b",    // NUL
        "//x",      // empty leading component
    ] {
        assert!(
            JailSock::from_str(bad).is_err(),
            "JailSock accepted {bad:?}"
        );
    }
}
