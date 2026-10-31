//! Refusal contracts for the jailer's pure validators — the security core. A
//! valid input must round-trip to its canonical form; an invalid one must
//! *always* be rejected, never silently accepted. These properties are what stop
//! a compromised BEAM from naming uid 0, a privileged path, a traversal, or a
//! flag through the jailer subcommand.

use clap::{Args, FromArgMatches};
use hyper_suidhelper::firecracker::jailer::VmId;
use hyper_suidhelper::tools::jailer::JailerArgs;
use proptest::prelude::*;
use std::str::FromStr;

fn parse(limits: &[&str]) -> Result<JailerArgs, clap::Error> {
    parse_with_sock("/api.sock", limits)
}

fn parse_with_sock(api_sock: &str, limits: &[&str]) -> Result<JailerArgs, clap::Error> {
    let base = [
        "--id",
        "vm1",
        "--uid",
        "900001",
        "--gid",
        "900001",
        "--api-sock",
        api_sock,
    ];
    let matches = JailerArgs::augment_args(clap::Command::new("jailer").no_binary_name(true))
        .try_get_matches_from(base.iter().chain(limits))?;
    JailerArgs::from_arg_matches(&matches)
}

proptest! {
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
fn cgroup_limits_accepted() {
    for limits in [
        &[][..],
        &["--memory-max", "1048576"],
        &["--cpu-quota-us", "50000", "--cpu-period-us", "100000"],
        &[
            "--memory-max",
            "1",
            "--cpu-quota-us",
            "1",
            "--cpu-period-us",
            "1",
        ],
    ] {
        assert!(parse(limits).is_ok(), "{limits:?} refused");
    }
}

#[test]
fn cgroup_limits_refused() {
    for limits in [
        &["--memory-max", "0"][..],
        &["--memory-max", "max"],
        &["--memory-max", "-1"],
        &["--memory-max", "12x"],
        &["--memory-max", "18446744073709551616"],
        &["--memory-max", "1", "--memory-max", "2"],
        &["--cpu-quota-us", "50000"],
        &["--cpu-period-us", "100000"],
        &["--cpu-quota-us", "0", "--cpu-period-us", "100000"],
        &["--cpu-quota-us", "50000", "--cpu-period-us", "0"],
        &[
            "--cpu-quota-us",
            "1",
            "--cpu-quota-us",
            "2",
            "--cpu-period-us",
            "1",
        ],
        &["--cgroup", "memory.max=1"],
    ] {
        assert!(parse(limits).is_err(), "{limits:?} accepted");
    }
}

#[test]
fn api_sock_must_be_a_strict_absolute_path() {
    for ok in ["/api.socket", "/run/fc/api.socket", "/-dash", "/a b"] {
        assert!(parse_with_sock(ok, &[]).is_ok(), "{ok:?} refused");
    }
    for bad in ["", "api.socket", "/../etc/x", "/a/./b", "//x", "/a/"] {
        assert!(parse_with_sock(bad, &[]).is_err(), "{bad:?} accepted");
    }
}
