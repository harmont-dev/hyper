// SPDX-License-Identifier: AGPL-3.0-only
//! `chroot-jail prepare`: stage the kernel file and create the rootfs device node
//! inside a VM chroot, via the [`ChrootJail`] builder.

use crate::util::safe_dev::BlockDev;
use crate::tools::IsTool;
use crate::util::chroot_jail::{self, ChrootJail};
use clap::Args;
use serde::Serialize;

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
    type RunT = Result<(), chroot_jail::Error>;

    fn run_privileged(&self) -> Self::RunT {
        let args = &self.args;
        ChrootJail::new(&args.chroot, args.uid, args.gid)
            .with_kernel(&args.kernel)
            .with_rootfs(args.device.clone())
            .build()
    }

    fn parse(&self, res: Self::RunT) -> Result<PrepareOut, Box<dyn std::error::Error>> {
        res?;
        Ok(PrepareOut::Prepared)
    }
}
