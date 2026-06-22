// SPDX-License-Identifier: AGPL-3.0-only
//! `chroot-jail prepare`: stage the kernel file and create the rootfs device node
//! inside a VM chroot.
//!
//! Security: `--chroot` is validated as a `JailPath`; the two dests (`vmlinux`,
//! `rootfs`) are joined onto it and re-parsed as `JailPath`, re-checking
//! confinement under `JAIL_BASE`. `uid`/`gid` are rejected once via `check_owner`
//! if root/system. Kernel staging uses `stage_file` (canonicalize + confine under
//! `HYPER_BASE`, open `O_RDONLY|O_NOFOLLOW`, linkat / EXDEV copy, fchownat
//! `AT_SYMLINK_NOFOLLOW`); the device node uses `make_block_node` (open device
//! `O_PATH|O_NOFOLLOW` + fstat rdev, open_parent_nofollow, mknodat, fchownat
//! `AT_SYMLINK_NOFOLLOW`). The open_parent_nofollow walk is the real symlink guard.

use crate::safe_dev::{self, BlockDev, JailPath};
use crate::tools::{mknod, stage, IsTool};
use clap::Args;
use serde::Serialize;
use thiserror::Error as ThisError;

/// Fixed in-jail filename for the host kernel image. The Elixir side
/// (`Hyper.Node.FireVMM.ChrootJail`) MUST agree with this name.
const KERNEL_NAME: &str = "vmlinux";

/// Fixed in-jail filename for the rootfs block device node. The Elixir side MUST
/// agree with this name.
const ROOT_NAME: &str = "rootfs";

#[derive(Debug, ThisError)]
pub enum Error {
    #[error(transparent)]
    Owner(#[from] safe_dev::Error),
    #[error("stage kernel: {0}")]
    Stage(#[from] stage::Error),
    #[error("mknod rootfs: {0}")]
    Mknod(#[from] mknod::Error),
    #[error("invalid dest path {path}: {source}")]
    DestPath {
        path: String,
        #[source]
        source: safe_dev::Error,
    },
}

#[derive(Args)]
pub struct PrepareArgs {
    /// Chroot root directory (under JAIL_BASE, shape <JAIL_BASE>/<exec>/<id>).
    #[arg(long)]
    chroot: String,
    /// Host kernel image path (under /srv/hyper); staged as <chroot>/vmlinux.
    #[arg(long)]
    kernel: String,
    /// Host block device to mirror as <chroot>/rootfs (e.g. /dev/loop0 or
    /// /dev/mapper/hyper-vm1). Its major:minor are read by the helper.
    #[arg(long)]
    device: BlockDev,
    /// UID to own the staged files; must be >= 1000 (non-root, non-system).
    #[arg(long)]
    uid: u32,
    /// GID to own the staged files; must be >= 1000 (non-root, non-system).
    #[arg(long)]
    gid: u32,
}

#[derive(Serialize)]
#[serde(tag = "result", rename_all = "snake_case")]
pub enum PrepareOut {
    Prepared,
}

/// Run the `prepare` op in its own privileged scope.
pub fn run(args: PrepareArgs) -> Result<PrepareOut, crate::tools::Error> {
    Prepare { args }.run()
}

struct Prepare {
    args: PrepareArgs,
}

impl IsTool for Prepare {
    type Args = PrepareArgs;
    type Output = PrepareOut;
    type RunT = Result<(), Error>;

    fn run_privileged(&self) -> Self::RunT {
        let args = &self.args;

        safe_dev::check_owner(args.uid, args.gid)?;

        let kernel_dest = dest_path(&args.chroot, KERNEL_NAME)?;
        let rootfs_dest = dest_path(&args.chroot, ROOT_NAME)?;

        stage::stage_file(&args.kernel, &kernel_dest, args.uid, args.gid)?;
        mknod::make_block_node(&rootfs_dest, &args.device, args.uid, args.gid)?;

        Ok(())
    }

    fn parse(&self, res: Self::RunT) -> Result<PrepareOut, Box<dyn std::error::Error>> {
        res?;
        Ok(PrepareOut::Prepared)
    }
}

/// Build an in-jail destination by joining `name` onto the chroot root and
/// parsing it as a [`JailPath`], which re-validates confinement under JAIL_BASE
/// (so a bad `--chroot` fails here).
fn dest_path(chroot: &str, name: &str) -> Result<JailPath, Error> {
    let s = format!("{chroot}/{name}");
    s.parse().map_err(|source| Error::DestPath { path: s, source })
}
