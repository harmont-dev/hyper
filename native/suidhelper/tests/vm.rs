//! Contracts of per-VM identity (`hyper_suidhelper::vm`) — the refusals that
//! stop a compromised BEAM from requesting uid 0, an out-of-band uid, or a VM id
//! that traverses out of the chroot base or reads as a flag.
//!
//! Laws under test:
//! - `UidGidRange::new(min, max)` is `Ok` iff `1 <= min <= max`.
//! - `range.admit(n)` is `Ok` iff `min <= n <= max`; an admitted id reports
//!   as `n` and has `slot() == n - min`, and 0 is never admitted.
//! - `[jails] uid_gid_range` deserializes through the same constructor: a valid
//!   range round-trips, an invalid one fails the whole config with a message
//!   naming the key, and an absent one yields `UidGidRange::DEFAULT`.
//! - `VmId` round-trips exactly its charset/length and refuses everything else.

use hyper_suidhelper::config::Config;
use hyper_suidhelper::vm::{UidGidRange, VmId};
use proptest::prelude::*;
use std::str::FromStr;

fn jails_toml(min: u32, max: u32) -> String {
    format!("work_dir = \"/srv/hyper\"\n[jails]\nuid_gid_range = [{min}, {max}]\n")
}

/// Ranges biased toward the interesting boundaries (0, equal ends, adjacent
/// ends) rather than uniformly random pairs, which are almost never equal.
fn bounds() -> impl Strategy<Value = (u32, u32)> {
    prop_oneof![
        (any::<u32>(), any::<u32>()),
        (0u32..=2, 0u32..=2),
        any::<u32>().prop_map(|n| (n, n)),
        (1u32..u32::MAX).prop_map(|n| (n + 1, n)),
    ]
}

fn valid_bounds() -> impl Strategy<Value = (u32, u32)> {
    (1u32.., any::<u32>()).prop_map(|(min, delta)| (min, min.saturating_add(delta)))
}

/// A range is pinned down exactly by its boundaries: it admits `min` and `max`
/// and refuses their outer neighbours.
fn has_bounds(range: UidGidRange, min: u32, max: u32) -> bool {
    range.admit(min).is_ok()
        && range.admit(max).is_ok()
        && range.admit(min - 1).is_err()
        && max
            .checked_add(1)
            .is_none_or(|above| range.admit(above).is_err())
}

#[test]
fn absent_range_yields_default() {
    assert!(has_bounds(
        Config::default().uid_gid_range(),
        900_000,
        999_999
    ));
}

proptest! {
    #[test]
    fn range_accepted_iff_coherent((min, max) in bounds()) {
        let coherent = min >= 1 && min <= max;
        prop_assert_eq!(UidGidRange::new(min, max).is_ok(), coherent);
    }

    #[test]
    fn admit_iff_in_range((min, max) in valid_bounds(), n in prop_oneof![
        any::<u32>(),
        Just(0u32),
        Just(u32::MAX),
    ]) {
        let range = UidGidRange::new(min, max).unwrap();
        let in_range = min <= n && n <= max;
        prop_assert_eq!(range.admit(n).is_ok(), in_range);
    }

    #[test]
    fn admitted_id_reports_value_and_slot((min, max) in valid_bounds(), off in any::<u32>()) {
        // `min >= 1`, so `span + 1` cannot overflow and `n` lands in `[min, max]`.
        let n = min + off % (max - min + 1);
        let id = UidGidRange::new(min, max).unwrap().admit(n).unwrap();
        prop_assert_eq!(id.to_string(), n.to_string());
        prop_assert_eq!(id.slot(), n - min);
    }

    #[test]
    fn zero_never_admitted((min, max) in valid_bounds()) {
        prop_assert!(UidGidRange::new(min, max).unwrap().admit(0).is_err());
    }

    #[test]
    fn valid_range_round_trips_via_toml((min, max) in valid_bounds()) {
        let config: Config = toml::from_str(&jails_toml(min, max)).unwrap();
        prop_assert!(has_bounds(config.uid_gid_range(), min, max));
    }

    #[test]
    fn incoherent_range_fails_config_load((min, max) in bounds()
        .prop_filter("incoherent", |&(min, max)| min == 0 || min > max))
    {
        let err = toml::from_str::<Config>(&jails_toml(min, max)).unwrap_err();
        prop_assert!(err.message().contains("uid_gid_range"), "{}", err.message());
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
