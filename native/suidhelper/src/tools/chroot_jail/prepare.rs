// SPDX-License-Identifier: AGPL-3.0-only
//! `chroot-jail prepare`: stage the kernel file and create the rootfs device node
//! inside a VM chroot.
//!
//! Security: `--chroot` is validated as a `SafePath` and reached by an
//! `O_NOFOLLOW` walk from `JAIL_BASE` (`SafeDir::descend`), which proves
//! confinement - a symlinked component anywhere aborts. The kernel
//! (`stage_into`) and the rootfs node (`make_block_node`) are then created
//! relative to that verified chroot directory fd.

use crate::config::Config;
use crate::safe_dev::BlockDev;
use crate::tools::{mknod, stage, IsTool};
use crate::util::safe_dir::{self, SafeDir};
use crate::util::safe_path::{self, IsAbsolute, SafePath, StrictComponents};
use clap::Args;
use serde::Serialize;
use std::path::PathBuf;
use thiserror::Error as ThisError;

/// Fixed in-jail filename for the host kernel image. The Elixir side
/// (`Hyper.Node.FireVMM.ChrootJail`) MUST agree with this name.
const KERNEL_NAME: &str = "vmlinux";

/// Fixed in-jail filename for the rootfs block device node. The Elixir side MUST
/// agree with this name.
const ROOT_NAME: &str = "rootfs";

#[derive(Debug, ThisError)]
pub enum Error {
    #[error("invalid --chroot path: {0}")]
    ChrootPath(#[from] safe_path::ValidationError),
    #[error("walking chroot: {0}")]
    Walk(#[from] safe_dir::Error),
    #[error("stage kernel: {0}")]
    Stage(#[from] stage::Error),
    #[error("mknod rootfs: {0}")]
    Mknod(#[from] mknod::Error),
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
    /// UID to own the staged files.
    #[arg(long)]
    uid: u32,
    /// GID to own the staged files.
    #[arg(long)]
    gid: u32,
}

#[derive(Serialize)]
#[serde(tag = "result", rename_all = "snake_case")]
pub enum PrepareOut {
    Prepared,
}

/// Run the `prepare` op in its own privileged scope (returns its serialized `Value`).
pub fn run(args: PrepareArgs) -> Result<serde_json::Value, crate::tools::Error> {
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
        let jail_base = Config::get().jail_base();

        // Open the chroot dir by walking it from JAIL_BASE with O_NOFOLLOW, so a
        // symlinked component cannot redirect outside the jail.
        let chroot: SafePath<IsAbsolute, StrictComponents> =
            PathBuf::from(&args.chroot).try_into()?;
        let (parents, leaf) = chroot.relative_to(&jail_base)?;
        let anchor_path: SafePath<IsAbsolute, StrictComponents> = jail_base.clone().try_into()?;

        let mut components = parents;
        components.push(leaf);
        let chroot_dir = SafeDir::open(&anchor_path)?.descend(&components)?;

        stage::stage_into(&chroot_dir, KERNEL_NAME, &args.kernel, args.uid, args.gid)?;
        mknod::make_block_node(&chroot_dir, ROOT_NAME, &args.device, args.uid, args.gid)?;

        Ok(())
    }

    fn parse(&self, res: Self::RunT) -> Result<PrepareOut, Box<dyn std::error::Error>> {
        res?;
        Ok(PrepareOut::Prepared)
    }
}
