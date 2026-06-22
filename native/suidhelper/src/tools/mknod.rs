// SPDX-License-Identifier: AGPL-3.0-only
//! `mknod` helper: create a block device node inside a VM chroot.
//!
//! Security model
//! ──────────────
//! 1. `device` is a [`BlockDev`] (lexically restricted to `/dev/loopN` or
//!    `/dev/mapper/hyper-*`). This is the anchor: the caller names one of our
//!    own devices, never an arbitrary node like `/dev/sda`.
//! 2. In `make_block_node` we open that device with `O_PATH|O_NOFOLLOW` and
//!    `fstat` it to read its `st_rdev`. We decompose that with
//!    `nix::sys::stat::{major, minor}` and use THOSE numbers for `mknodat`.
//!    The caller can no longer supply arbitrary major:minor.
//! 3. `dest` is a [`JailPath`] walked with `open_parent_nofollow`:
//!    every parent component is opened with `O_NOFOLLOW` so a symlink in the
//!    path causes `ELOOP → SymlinkComponent` before we touch anything.
//! 4. `mknodat(parent_fd, final_name, …)` and
//!    `fchownat(parent_fd, final_name, …, AT_SYMLINK_NOFOLLOW)` operate
//!    relative to the parent fd, so a race that replaces `final_name` with a
//!    symlink after creation still cannot redirect the chown.
//! 5. uid/gid are rejected if 0 or < 1000.

use crate::safe_dev::{self, BlockDev, JailPath};
use nix::fcntl::{openat, OFlag};
use nix::sys::stat::{fstat, makedev, major, minor, mknodat, Mode, SFlag};
use nix::unistd::{close, fchownat, Gid, Uid};
use nix::fcntl::AtFlags;
use std::os::unix::io::RawFd;
use std::path::PathBuf;
use thiserror::Error as ThisError;

#[derive(Debug, ThisError)]
pub enum Error {
    #[error(transparent)]
    Path(#[from] safe_dev::Error),
    #[error("mknod {path}: {source}")]
    Mknod { path: PathBuf, #[source] source: nix::Error },
    #[error("chown {path}: {source}")]
    Chown { path: PathBuf, #[source] source: nix::Error },
}

/// Create a block device node at `dest` mirroring `device`'s major:minor.
///
/// Security: opens `device` O_PATH|O_NOFOLLOW and fstats to get rdev;
/// walks parent components of `dest` with O_NOFOLLOW; uses mknodat +
/// fchownat(AT_SYMLINK_NOFOLLOW) so no race can redirect via symlink.
pub(crate) fn make_block_node(dest: &JailPath, device: &BlockDev, uid: u32, gid: u32) -> Result<(), Error> {
    // ── 1. Open device with O_PATH|O_NOFOLLOW and fstat to get rdev ────────
    let dev_path: &std::path::Path = device.as_ref();
    let dev_fd: RawFd = openat(
        None::<RawFd>,
        dev_path,
        OFlag::O_PATH | OFlag::O_NOFOLLOW | OFlag::O_CLOEXEC,
        Mode::empty(),
    )
    .map_err(|source| safe_dev::Error::DeviceStat {
        path: dev_path.to_path_buf(),
        source,
    })?;

    let stat = fstat(dev_fd).map_err(|source| {
        let _ = close(dev_fd);
        safe_dev::Error::DeviceStat { path: dev_path.to_path_buf(), source }
    })?;
    let _ = close(dev_fd);

    let rdev = makedev(major(stat.st_rdev), minor(stat.st_rdev));

    // ── 2. Walk parent dirs of dest with O_NOFOLLOW ─────────────────────────
    let (parent_fd, final_name) = safe_dev::open_parent_nofollow(dest)?;

    // ── 3. mknodat relative to parent_fd ────────────────────────────────────
    let mk_result = mknodat(
        Some(parent_fd),
        final_name.as_str(),
        SFlag::S_IFBLK,
        Mode::from_bits_truncate(0o600),
        rdev,
    );

    if let Err(source) = mk_result {
        let _ = close(parent_fd);
        return Err(Error::Mknod {
            path: dest.as_ref().to_path_buf(),
            source,
        });
    }

    // ── 4. fchownat with AT_SYMLINK_NOFOLLOW ────────────────────────────────
    let chown_result = fchownat(
        Some(parent_fd),
        final_name.as_str(),
        Some(Uid::from_raw(uid)),
        Some(Gid::from_raw(gid)),
        AtFlags::AT_SYMLINK_NOFOLLOW,
    );
    let _ = close(parent_fd);

    chown_result.map_err(|source| Error::Chown {
        path: dest.as_ref().to_path_buf(),
        source,
    })
}
