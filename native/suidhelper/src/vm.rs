// SPDX-License-Identifier: MIT
//! Validated per-VM identity: the id that names a VM's chroot and netns, and the
//! uid/gid it runs as. Shared by every tool that acts on one VM (`jailer`,
//! `network`), so none of them owns it.
//!
//! ## Laws (property-tested in `tests/vm.rs`)
//! - [`UidGidRange::new`] accepts iff `1 <= min <= max`; any range admitting 0
//!   (root) or with `min > max` is refused.
//! - [`UidGidRange::admit`] accepts iff `min <= n <= max`, so a [`JailId`] is
//!   never 0, and its [`slot`](JailId::slot) is always `n - min`.
//! - [`VmId`] round-trips exactly the allowed charset/length and rejects any
//!   separator, dot, NUL, whitespace, leading dash, empty, or over-long input.

use serde::Deserialize;
use std::fmt;
use std::str::FromStr;
use thiserror::Error as ThisError;

#[derive(Debug, ThisError)]
pub enum Error {
    #[error("invalid VM id {0:?}: must be 1..=64 chars of [A-Za-z0-9_-], not starting with '-'")]
    VmId(String),
    #[error("uid_gid_range.min must be >= 1 and <= max (got min={min}, max={max})")]
    BadRange { min: u32, max: u32 },
    #[error("uid/gid {value} is zero or outside the configured range [{min}, {max}]")]
    OutOfRange { value: u32, min: u32, max: u32 },
}

/// A VM id used as a chroot subdirectory and netns name: `[A-Za-z0-9_-]`, length
/// `1..=64`, first character not `-` (so it can never be read as a flag). No
/// `/`, `.`, NUL, or whitespace can appear, so it can never traverse out of the
/// chroot base.
#[derive(Debug, Clone)]
pub struct VmId(String);

impl FromStr for VmId {
    type Err = Error;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let reject = || Error::VmId(s.to_string());
        let bytes = s.as_bytes();
        if !(1..=64).contains(&bytes.len()) {
            return Err(reject());
        }
        if bytes[0] == b'-' {
            return Err(reject());
        }
        if !bytes
            .iter()
            .all(|&b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
        {
            return Err(reject());
        }
        Ok(Self(s.to_string()))
    }
}

impl fmt::Display for VmId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

/// The band of uids/gids the helper accepts for jails, `[jails] uid_gid_range`
/// in config.toml as a `[min, max]` array. Holding one proves `1 <= min <= max`:
/// a present-but-incoherent range fails the config load rather than being
/// clamped.
#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(try_from = "[u32; 2]")]
pub struct UidGidRange {
    min: u32,
    max: u32,
}

impl UidGidRange {
    /// Matches Elixir's `compile_env` allocation defaults so that an
    /// unconfigured helper and an unconfigured node agree out of the box.
    pub const DEFAULT: Self = Self {
        min: 900_000,
        max: 999_999,
    };

    pub fn new(min: u32, max: u32) -> Result<Self, Error> {
        if min == 0 || min > max {
            return Err(Error::BadRange { min, max });
        }
        Ok(Self { min, max })
    }

    /// Admit `n` as a jail uid/gid. The explicit `0` check is redundant given
    /// `min >= 1`, and kept deliberately: a jailer run with uid 0 skips its
    /// privilege drop and leaves firecracker running as root.
    pub fn admit(&self, n: u32) -> Result<JailId, Error> {
        if n != 0 && self.min <= n && n <= self.max {
            Ok(JailId {
                id: n,
                slot: n - self.min,
            })
        } else {
            Err(Error::OutOfRange {
                value: n,
                min: self.min,
                max: self.max,
            })
        }
    }
}

impl TryFrom<[u32; 2]> for UidGidRange {
    type Error = Error;

    fn try_from([min, max]: [u32; 2]) -> Result<Self, Self::Error> {
        Self::new(min, max)
    }
}

/// A uid or gid admitted by a [`UidGidRange`]: nonzero and in range. The only
/// constructor is [`UidGidRange::admit`].
#[derive(Debug)]
pub struct JailId {
    id: u32,
    slot: u32,
}

impl JailId {
    /// Offset of this id from its range's floor; indexes per-VM resources such
    /// as the clone-pool `/30`.
    pub fn slot(&self) -> u32 {
        self.slot
    }
}

impl fmt::Display for JailId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.id)
    }
}
