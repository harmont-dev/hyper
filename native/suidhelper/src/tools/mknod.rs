// SPDX-License-Identifier: AGPL-3.0-only
//! `mknod` helper: create a block device node inside a VM chroot.
//!
//! Security model
//! ──────────────
//! 1. `device` is a [`BlockDev`] (lexically restricted to `/dev/loopN` or
//!    `/dev/mapper/hyper-*`): the caller names one of our own devices.
//! 2. We open it as a [`SafeFile<IsBlockDevice, …>`] (`O_PATH|O_NOFOLLOW`): the
//!    type proves, via `fstat`, that it really is a block device, and `rdev()` is
//!    only callable on that proven handle - so the major:minor come from a
//!    verified device node, never a caller-supplied number.
//! 3. `parent` is an already-confined chroot directory fd; `mknod_block` creates
//!    the node and `chown`s it (`AT_SYMLINK_NOFOLLOW`) relative to that fd.

use crate::safe_dev::BlockDev;
use crate::util::safe_dir::{self, SafeDir};
use crate::util::safe_file::{self, Any, IsBlockDevice, SafeFile};
use crate::util::safe_path::{self, IsAbsolute, SafePath, StrictComponents};
use nix::fcntl::OFlag;
use thiserror::Error as ThisError;

#[derive(Debug, ThisError)]
pub enum Error {
    #[error("device path: {0}")]
    DevicePath(#[from] safe_path::ValidationError),
    #[error("device: {0}")]
    Device(#[from] safe_file::ValidationError),
    #[error("mknod {name:?}: {source}")]
    Node {
        name: String,
        #[source]
        source: safe_dir::Error,
    },
}

/// Create a block-device node `name` under `parent`, mirroring `device`'s
/// major:minor, owned `uid:gid`.
pub(crate) fn make_block_node(
    parent: &SafeDir,
    name: &str,
    device: &BlockDev,
    uid: u32,
    gid: u32,
) -> Result<(), Error> {
    let dev_path: SafePath<IsAbsolute, StrictComponents> = device.as_ref().to_path_buf().try_into()?;
    let dev = SafeFile::<IsBlockDevice, Any, Any>::open(&dev_path, OFlag::O_PATH)?;
    let rdev = dev.rdev()?;

    parent
        .mknod_block(name, rdev, uid, gid)
        .map_err(|source| Error::Node { name: name.to_string(), source })
}
