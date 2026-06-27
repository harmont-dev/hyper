//! Refusal contracts for the jailer's pure validators — the security core. A
//! valid input must round-trip to its canonical form; an invalid one must
//! *always* be rejected, never silently accepted. These properties are what stop
//! a compromised BEAM from naming uid 0, a privileged path, a traversal, or a
//! flag through the jailer subcommand.

use hyper_suidhelper::tools::jailer::{validate_id_number, CgroupSetting, JailSock, VmId};
use proptest::prelude::*;
use std::str::FromStr;

proptest! {
    /// uid/gid 0 is rejected for EVERY range — a jailer run with uid 0 skips its
    /// privilege drop and leaves firecracker running as root.
    #[test]
    fn id_zero_always_rejected(lo in any::<u32>(), span in any::<u32>()) {
        let hi = lo.saturating_add(span);
        prop_assert!(validate_id_number(0, (lo, hi)).is_err());
    }

    /// Any nonzero value inside the (nonempty) range is accepted unchanged.
    #[test]
    fn id_in_range_nonzero_accepted(
        lo in 1u32..=1_000_000,
        span in 0u32..=1_000_000,
        off in 0u32..=1_000_000,
    ) {
        let hi = lo + span;
        let n = lo + (off % (span + 1)); // off bounded into [0, span] => n in [lo, hi]
        prop_assert_eq!(validate_id_number(n, (lo, hi)).ok(), Some(n));
    }

    /// Values just below `lo` (still nonzero) and just above `hi` are rejected.
    #[test]
    fn id_out_of_range_rejected(lo in 2u32..=1_000_000, span in 0u32..=1_000_000) {
        let hi = lo + span;
        prop_assert!(validate_id_number(lo - 1, (lo, hi)).is_err());
        if hi < u32::MAX {
            prop_assert!(validate_id_number(hi + 1, (lo, hi)).is_err());
        }
    }

    /// Every string over the allowed charset/length with a non-dash leader parses
    /// and renders back to itself.
    #[test]
    fn vmid_valid_round_trips(s in "[A-Za-z0-9_][A-Za-z0-9_-]{0,63}") {
        prop_assert_eq!(VmId::from_str(&s).unwrap().to_string(), s);
    }

    /// A leading dash is always rejected (no flag injection via `--id`).
    #[test]
    fn vmid_leading_dash_rejected(s in "-[A-Za-z0-9_-]{0,63}") {
        prop_assert!(VmId::from_str(&s).is_err());
    }

    /// Any embedded path separator is rejected (no chroot traversal via `--id`).
    #[test]
    fn vmid_slash_rejected(s in "[A-Za-z0-9_]{0,10}/[A-Za-z0-9_]{0,10}") {
        prop_assert!(VmId::from_str(&s).is_err());
    }

    /// Over-length ids (>64) are rejected.
    #[test]
    fn vmid_too_long_rejected(s in "[A-Za-z][A-Za-z0-9_-]{64,90}") {
        prop_assert!(VmId::from_str(&s).is_err());
    }

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
fn vmid_rejects_known_bad_shapes() {
    for bad in [
        "",              // empty
        "-leading",      // leading dash
        "a/b",           // separator
        "a.b",           // dot
        "a b",           // whitespace
        "a\tb",          // tab
        "a\0b",          // NUL
        "naïve",         // non-ascii
        &"x".repeat(65), // too long
    ] {
        assert!(VmId::from_str(bad).is_err(), "VmId accepted {bad:?}");
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
