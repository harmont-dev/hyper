// SPDX-License-Identifier: MIT
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
//! lives in `crate::fs::{path, file, dir}`, not here.

use crate::fs::path::{IsAbsolute, SafePath, SafePathBuf, StrictComponents};
use crate::linux::loopdev::LoopDevNum;
use crate::tools::parse_dm_name;
use derive_more::{Display, Into};
use std::path::{Path, PathBuf};
use std::str::FromStr;
use thiserror::Error as ThisError;

#[derive(Debug, ThisError)]
pub enum Error {
    #[error("expected a loop or hyper-* dm device: {0}")]
    Block(String),
}

fn is_hyper_dm(p: &str) -> bool {
    p.strip_prefix("/dev/mapper/")
        .is_some_and(|name| parse_dm_name(name).is_ok())
}

#[derive(Debug, Clone, Display, Into)]
#[display("{}", _0.as_path().display())]
#[into(PathBuf)]
pub struct BlockDev(SafePathBuf<IsAbsolute, StrictComponents>);

impl BlockDev {
    pub fn path(&self) -> &SafePath<IsAbsolute, StrictComponents> {
        &self.0
    }
}

impl FromStr for BlockDev {
    type Err = Error;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let invalid = || Error::Block(s.to_string());
        if s.parse::<LoopDevNum>().is_err() && !is_hyper_dm(s) {
            return Err(invalid());
        }
        PathBuf::from(s).try_into().map(Self).map_err(|_| invalid())
    }
}

impl AsRef<Path> for BlockDev {
    fn as_ref(&self) -> &Path {
        self.0.as_path()
    }
}
