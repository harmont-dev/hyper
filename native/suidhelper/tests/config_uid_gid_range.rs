//! Properties of the `uid_gid_range` configuration field.
//!
//! Contracts under test:
//! - A valid range (min >= 1, min <= max) is always accepted.
//! - Absent range yields the built-in default (900_000, 999_999).
//! - A valid range round-trips through TOML deserialization + uid_gid_range().
//! - min == 0 is always rejected (uid 0 means root; the jailer must never
//!   receive it — it skips its privilege drop when uid == 0).
//! - min > max is always rejected (incoherent range; likely a config typo).

use hyper_suidhelper::config::{validate_uid_gid_range, Config, LoadingError, UidGidRange};
use proptest::prelude::*;

#[test]
fn absent_range_yields_default() {
    assert_eq!(Config::default().uid_gid_range(), (900_000, 999_999));
}

proptest! {
    #[test]
    fn valid_range_accepted(min in 1u32.., delta in 0u32..) {
        // max = min + delta, saturating so it never wraps past u32::MAX.
        let max = min.saturating_add(delta);
        let r = UidGidRange { min, max };
        prop_assert!(validate_uid_gid_range(&r).is_ok());
    }

    #[test]
    fn valid_range_round_trips_via_toml(min in 1u32.., delta in 0u32..) {
        let max = min.saturating_add(delta);
        let body = format!(
            "work_dir = \"/srv/hyper\"\n[uid_gid_range]\nmin = {min}\nmax = {max}\n"
        );
        let config: Config = toml::from_str(&body).expect("valid TOML");
        prop_assert_eq!(config.uid_gid_range(), (min, max));
    }

    #[test]
    fn zero_min_always_rejected(max in 0u32..) {
        let r = UidGidRange { min: 0, max };
        let rejected = matches!(
            validate_uid_gid_range(&r),
            Err(LoadingError::BadUidGidRange { min: 0, .. })
        );
        prop_assert!(rejected);
    }

    #[test]
    fn min_exceeds_max_always_rejected(max in 0u32..u32::MAX) {
        // min = max + 1 is always strictly greater than max and always >= 1.
        let min = max + 1;
        let r = UidGidRange { min, max };
        let rejected = matches!(
            validate_uid_gid_range(&r),
            Err(LoadingError::BadUidGidRange { .. })
        );
        prop_assert!(rejected);
    }
}
