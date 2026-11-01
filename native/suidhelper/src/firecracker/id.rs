// SPDX-License-Identifier: MIT

use crate::fs::file::Owner;
use derive_more::{Display, Into};
use nix::unistd::{Gid, Uid};
use serde::Deserialize;
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

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(try_from = "[u32; 2]")]
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
