// SPDX-License-Identifier: AGPL-3.0-only
//! `mknod` subcommand: create a block device node inside a VM chroot.
//!
//! Security model
//! ──────────────
//! 1. `--device` is a [`BlockDev`] (lexically restricted to `/dev/loopN` or
//!    `/dev/mapper/hyper-*`). This is the anchor: the caller names one of our
//!    own devices, never an arbitrary node like `/dev/sda`.
//! 2. In `run_privileged` we open that device with `O_PATH|O_NOFOLLOW` and
//!    `fstat` it to read its `st_rdev`. We decompose that with
//!    `nix::sys::stat::{major, minor}` and use THOSE numbers for `mknodat`.
//!    The caller can no longer supply arbitrary major:minor.
//! 3. `--dest` is a [`JailPath`] walked with `open_parent_nofollow`:
//!    every parent component is opened with `O_NOFOLLOW` so a symlink in the
//!    path causes `ELOOP → SymlinkComponent` before we touch anything.
//! 4. `mknodat(parent_fd, final_name, …)` and
//!    `fchownat(parent_fd, final_name, …, AT_SYMLINK_NOFOLLOW)` operate
//!    relative to the parent fd, so a race that replaces `final_name` with a
//!    symlink after creation still cannot redirect the chown.
//! 5. uid/gid are rejected if 0 or < 1000.

use super::IsTool;
use crate::safe_dev::{self, BlockDev, JailPath};
use clap::Args;
use nix::fcntl::{openat, OFlag};
use nix::sys::stat::{fstat, makedev, major, minor, mknodat, Mode, SFlag};
use nix::unistd::{close, fchownat, Gid, Uid};
use nix::fcntl::AtFlags;
use serde::Serialize;
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

#[derive(Args)]
pub struct MknodArgs {
    /// Destination path inside the jail (e.g. /srv/hyper/jails/vm1/dev/vda).
    #[arg(long)]
    dest: JailPath,
    /// The existing block device to mirror (e.g. /dev/loop0 or
    /// /dev/mapper/hyper-vm1). Its major:minor are read by the helper — the
    /// caller cannot supply raw numbers.
    #[arg(long)]
    device: BlockDev,
    /// UID to own the node; must be >= 1000 (non-root, non-system).
    #[arg(long)]
    uid: u32,
    /// GID to own the node; must be >= 1000 (non-root, non-system).
    #[arg(long)]
    gid: u32,
}

#[derive(Serialize)]
#[serde(tag = "result", rename_all = "snake_case")]
pub enum MknodOut {
    Made,
}

pub struct Mknod {
    args: MknodArgs,
}

impl Mknod {
    pub fn new(args: MknodArgs) -> Self {
        Self { args }
    }
}

impl IsTool for Mknod {
    type Args = MknodArgs;
    type Output = MknodOut;
    type RunT = Result<(), Error>;

    fn run_privileged(&self) -> Self::RunT {
        // ── 1. Reject system/root uid/gid before doing anything ────────────
        safe_dev::check_owner(self.args.uid, self.args.gid)?;

        // ── 2. Open device with O_PATH|O_NOFOLLOW and fstat to get rdev ────
        let dev_path: &std::path::Path = self.args.device.as_ref();
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

        // ── 3. Walk parent dirs of dest with O_NOFOLLOW ─────────────────────
        let (parent_fd, final_name) = safe_dev::open_parent_nofollow(&self.args.dest)?;

        // ── 4. mknodat relative to parent_fd ────────────────────────────────
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
                path: self.args.dest.as_ref().to_path_buf(),
                source,
            });
        }

        // ── 5. fchownat with AT_SYMLINK_NOFOLLOW ────────────────────────────
        let chown_result = fchownat(
            Some(parent_fd),
            final_name.as_str(),
            Some(Uid::from_raw(self.args.uid)),
            Some(Gid::from_raw(self.args.gid)),
            AtFlags::AT_SYMLINK_NOFOLLOW,
        );
        let _ = close(parent_fd);

        chown_result.map_err(|source| Error::Chown {
            path: self.args.dest.as_ref().to_path_buf(),
            source,
        })
    }

    fn parse(&self, res: Self::RunT) -> Result<MknodOut, Box<dyn std::error::Error>> {
        res?;
        Ok(MknodOut::Made)
    }
}
