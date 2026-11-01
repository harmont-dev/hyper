//! Properties of the `uid_gid_range` configuration field.
//!
//! Contracts under test:
//! - A valid range (min >= 1, min <= max) is always accepted.
//! - Absent range yields the built-in default (900_000, 999_999).
//! - A valid range round-trips through TOML deserialization + uid_gid_range().
//! - min == 0 is always rejected (uid 0 means root; the jailer must never
//!   receive it — it skips its privilege drop when uid == 0).
//! - min > max is always rejected (incoherent range; likely a config typo).

use hyper_suidhelper::config::Config;
use proptest::prelude::*;

fn parse(min: u32, max: u32) -> Result<Config, toml::de::Error> {
    toml::from_str(&format!(
        "work_dir = \"/srv/hyper\"\n[jails]\nuid_gid_range = [{min}, {max}]\n"
    ))
}

#[test]
fn absent_range_yields_default() {
    let r = Config::default().uid_gid_range();
    assert_eq!((r.min(), r.max()), (900_000, 999_999));
}

proptest! {
    #[test]
    fn valid_range_round_trips_via_toml(min in 1u32.., delta in 0u32..) {
        let max = min.saturating_add(delta);
        let r = parse(min, max).expect("valid TOML").uid_gid_range();
        prop_assert_eq!((r.min(), r.max()), (min, max));
    }

    #[test]
    fn zero_min_always_rejected(max in 0u32..) {
        let err = parse(0, max).unwrap_err();
        prop_assert!(err.to_string().contains("uid_gid_range"));
    }

    #[test]
    fn min_exceeds_max_always_rejected(max in 0u32..u32::MAX) {
        let err = parse(max + 1, max).unwrap_err();
        prop_assert!(err.to_string().contains("uid_gid_range"));
    }
}
