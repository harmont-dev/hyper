// SPDX-License-Identifier: MIT

use derive_more::{Display, Into};
use hyperrs_fs::file::Owner;
use nix::unistd::{Gid, Uid};
use thiserror::Error as ThisError;

#[derive(Debug, ThisError, PartialEq, Eq)]
#[error("uid_gid_range.min must be >= 1 and <= max (got min={min}, max={max})")]
pub struct RangeError {
    pub min: u32,
    pub max: u32,
}

#[derive(Debug, ThisError, PartialEq, Eq)]
#[error("--uid/--gid {value} is outside the configured range [{min}, {max}]")]
pub struct IdError {
    pub value: u32,
    pub min: u32,
    pub max: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct UidGidRange {
    min: u32,
    max: u32,
}

impl TryFrom<[u32; 2]> for UidGidRange {
    type Error = RangeError;

    fn try_from([min, max]: [u32; 2]) -> Result<Self, Self::Error> {
        if min == 0 || min > max {
            return Err(RangeError { min, max });
        }
        Ok(Self { min, max })
    }
}

impl Default for UidGidRange {
    fn default() -> Self {
        Self {
            min: 900_000,
            max: 999_999,
        }
    }
}

impl UidGidRange {
    pub fn min(&self) -> u32 {
        self.min
    }

    pub fn max(&self) -> u32 {
        self.max
    }

    pub fn uid(&self, n: u32) -> Result<JailUid, IdError> {
        self.check(n).map(|n| JailUid(Uid::from_raw(n)))
    }

    pub fn gid(&self, n: u32) -> Result<JailGid, IdError> {
        self.check(n).map(|n| JailGid(Gid::from_raw(n)))
    }

    fn check(&self, value: u32) -> Result<u32, IdError> {
        if (self.min..=self.max).contains(&value) {
            Ok(value)
        } else {
            Err(IdError {
                value,
                min: self.min,
                max: self.max,
            })
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Display, Into)]
pub struct JailUid(Uid);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Display, Into)]
pub struct JailGid(Gid);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct JailOwner {
    pub uid: JailUid,
    pub gid: JailGid,
}

impl From<JailOwner> for Owner {
    fn from(owner: JailOwner) -> Self {
        Owner {
            uid: owner.uid.into(),
            gid: owner.gid.into(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{IdError, RangeError, UidGidRange};
    use nix::unistd::{Gid, Uid};
    use proptest::prelude::*;
    use test_strategy::proptest;

    fn range() -> impl Strategy<Value = UidGidRange> {
        (1u32.., any::<u32>())
            .prop_map(|(min, span)| UidGidRange::try_from([min, min.saturating_add(span)]).unwrap())
    }

    #[proptest]
    fn ordered_nonzero_pair_is_a_range(#[strategy(1u32..)] min: u32, span: u32) {
        let max = min.saturating_add(span);
        let r = UidGidRange::try_from([min, max]).unwrap();
        prop_assert_eq!((r.min(), r.max()), (min, max));
    }

    #[proptest]
    fn zero_min_is_never_a_range(max: u32) {
        prop_assert_eq!(
            UidGidRange::try_from([0, max]),
            Err(RangeError { min: 0, max })
        );
    }

    #[proptest]
    fn inverted_pair_is_never_a_range(
        #[strategy(0u32..u32::MAX)] max: u32,
        #[strategy(1u32..)] gap: u32,
    ) {
        let min = max.saturating_add(gap);
        prop_assert_eq!(
            UidGidRange::try_from([min, max]),
            Err(RangeError { min, max })
        );
    }

    #[proptest]
    fn zero_is_never_minted(#[strategy(range())] r: UidGidRange) {
        prop_assert!(r.uid(0).is_err());
        prop_assert!(r.gid(0).is_err());
    }

    #[proptest]
    fn in_range_id_is_minted_unchanged(#[strategy(range())] r: UidGidRange, off: u32) {
        let n = r.min() + off % (r.max() - r.min() + 1);
        prop_assert_eq!(Uid::from(r.uid(n).unwrap()), Uid::from_raw(n));
        prop_assert_eq!(Gid::from(r.gid(n).unwrap()), Gid::from_raw(n));
    }

    #[proptest]
    fn out_of_range_id_is_refused(#[strategy(range())] r: UidGidRange) {
        let expected = |value| IdError {
            value,
            min: r.min(),
            max: r.max(),
        };
        prop_assert_eq!(r.uid(r.min() - 1), Err(expected(r.min() - 1)));
        prop_assert_eq!(r.gid(r.min() - 1), Err(expected(r.min() - 1)));
        if let Some(above) = r.max().checked_add(1) {
            prop_assert_eq!(r.uid(above), Err(expected(above)));
            prop_assert_eq!(r.gid(above), Err(expected(above)));
        }
    }
}
