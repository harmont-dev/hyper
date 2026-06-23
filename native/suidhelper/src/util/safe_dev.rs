// SPDX-License-Identifier: AGPL-3.0-only
//! Validated device-name operands.
//!
//! The privileged tools must only ever touch Hyper's own devices, never
//! arbitrary system storage like `/dev/sda`. These newtypes encode that: each
//! wraps a `PathBuf`/`String` and is constructed only through its [`FromStr`]
//! impl (a textual match on the device-node name), so holding one is proof the
//! name is in-bounds. Because they parse via `FromStr`, clap validates the
//! operands at argument-parse time; borrow them as a `Path` via `AsRef`.
//!
//! Filesystem path safety (confinement, symlink-free walks, fd-relative ops)
//! lives in `crate::util::{safe_path, safe_file, safe_dir}`, not here.

use std::fmt;
use std::path::{Path, PathBuf};
use std::str::FromStr;
use thiserror::Error as ThisError;

#[derive(Debug, ThisError)]
pub enum Error {
    #[error("expected /dev/loopN: {0}")]
    Loop(String),
    #[error("expected a loop or hyper-* dm device: {0}")]
    Block(String),
    #[error("dm device name must be a safe hyper-* name: {0}")]
    Name(String),
}

// `/dev/loop` followed by its number and nothing else. Matching the digit suffix
// (not just the prefix) rejects path tricks like `/dev/loop0/../sda`.
fn is_loop(p: &str) -> bool {
    p.strip_prefix("/dev/loop")
        .is_some_and(|n| !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()))
}

// `/dev/mapper/` plus a `hyper-*` name with no path separators, so the device
// is always a direct child of `/dev/mapper` (the charset excludes `/`, so no
// traversal).
fn is_hyper_dm(p: &str) -> bool {
    p.strip_prefix("/dev/mapper/").is_some_and(is_hyper_name)
}

// A device-mapper name we own: `hyper-*`, restricted to a charset with no path
// separators. Shared by `is_hyper_dm` and [`DmName`] so the two never drift.
fn is_hyper_name(name: &str) -> bool {
    name.starts_with("hyper-")
        && name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"-_.".contains(&b))
}

/// A loop device path, `/dev/loopN`.
#[derive(Debug, Clone)]
pub struct LoopDev(PathBuf);

impl FromStr for LoopDev {
    type Err = Error;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        if is_loop(s) {
            Ok(Self(PathBuf::from(s)))
        } else {
            Err(Error::Loop(s.to_string()))
        }
    }
}

impl AsRef<Path> for LoopDev {
    fn as_ref(&self) -> &Path {
        &self.0
    }
}

/// A block-device operand: a loop device or one of our own dm devices — never
/// arbitrary system storage.
#[derive(Debug, Clone)]
pub struct BlockDev(PathBuf);

impl FromStr for BlockDev {
    type Err = Error;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        if is_loop(s) || is_hyper_dm(s) {
            Ok(Self(PathBuf::from(s)))
        } else {
            Err(Error::Block(s.to_string()))
        }
    }
}

impl AsRef<Path> for BlockDev {
    fn as_ref(&self) -> &Path {
        &self.0
    }
}

impl From<BlockDev> for PathBuf {
    fn from(dev: BlockDev) -> Self {
        dev.0
    }
}

/// A device-mapper device name we create/remove: a `hyper-*` name we own.
#[derive(Debug, Clone)]
pub struct DmName(String);

impl FromStr for DmName {
    type Err = Error;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        if is_hyper_name(s) {
            Ok(Self(s.to_string()))
        } else {
            Err(Error::Name(s.to_string()))
        }
    }
}

impl fmt::Display for DmName {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}
