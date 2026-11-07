// SPDX-License-Identifier: MIT

use derive_more::Display;
use hyperrs_fs::path::{ComponentError, StrictComponent, StrictComponentBuf};
use std::ops::Deref;
use std::str::FromStr;
use thiserror::Error as ThisError;

#[derive(Debug, ThisError)]
pub enum VmIdError {
    #[error("invalid VM id {0:?}: must be 1..=64 chars of [A-Za-z0-9-], not starting with '-'")]
    VmId(String),
    #[error(transparent)]
    Component(#[from] ComponentError),
}

/// A VM name that can be accepted by Firecracker.
#[derive(Debug, Clone, Display)]
#[display("{}", _0.as_os_str().display())]
pub struct VmId(
    // This needs to be a path because jailer will expect to chroot into a directory of this name.
    StrictComponentBuf,
);

impl FromStr for VmId {
    type Err = VmIdError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let jailer_grammar = (1..=64).contains(&s.len())
            && !s.starts_with('-')
            && s.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-');

        if !jailer_grammar {
            return Err(VmIdError::VmId(s.to_string()));
        }

        let component: &StrictComponent = s.try_into()?;
        Ok(Self(component.to_owned()))
    }
}

impl Deref for VmId {
    type Target = StrictComponent;
    fn deref(&self) -> &StrictComponent {
        &self.0
    }
}

#[cfg(test)]
mod tests {
    use super::VmId;
    use proptest::prelude::*;
    use rstest::rstest;
    use std::str::FromStr;
    use test_strategy::proptest;

    /// Every string over the allowed charset/length with a non-dash leader parses
    /// and renders back to itself.
    #[proptest]
    fn vmid_valid_round_trips(#[strategy("[A-Za-z0-9][A-Za-z0-9-]{0,63}")] s: String) {
        prop_assert_eq!(VmId::from_str(&s).unwrap().to_string(), s);
    }

    /// A leading dash is always rejected (no flag injection via `--id`).
    #[proptest]
    fn vmid_leading_dash_rejected(#[strategy("-[A-Za-z0-9-]{0,63}")] s: String) {
        prop_assert!(VmId::from_str(&s).is_err());
    }

    /// Any embedded path separator is rejected (no chroot traversal via `--id`).
    #[proptest]
    fn vmid_slash_rejected(#[strategy("[A-Za-z0-9_]{0,10}/[A-Za-z0-9_]{0,10}")] s: String) {
        prop_assert!(VmId::from_str(&s).is_err());
    }

    /// Over-length ids (>64) are rejected.
    #[proptest]
    fn vmid_too_long_rejected(#[strategy("[A-Za-z][A-Za-z0-9-]{64,90}")] s: String) {
        prop_assert!(VmId::from_str(&s).is_err());
    }

    #[rstest]
    #[case::empty("")]
    #[case::leading_dash("-leading")]
    #[case::separator("a/b")]
    #[case::dot("a.b")]
    #[case::current_dir(".")]
    #[case::parent_dir("..")]
    #[case::underscore("a_b")]
    #[case::space("a b")]
    #[case::tab("a\tb")]
    #[case::nul("a\0b")]
    #[case::non_ascii("naïve")]
    #[case::too_long(&"x".repeat(65))]
    fn vmid_rejects_known_bad_shapes(#[case] bad: &str) {
        assert!(VmId::from_str(bad).is_err(), "VmId accepted {bad:?}");
    }
}
