// SPDX-License-Identifier: MIT
//! `chroot-jail prepare`: stage the kernel file and create the rootfs device node
//! inside a VM chroot, via the [`ChrootJail`] builder.

use crate::config::Config;
use crate::firecracker::chroot_jail::{self, JailRoot, KernelImage};
use crate::firecracker::id::JailOwner;
use crate::fs::dir;
use crate::fs::path::{IsAbsolute, SafePathBuf, StrictComponents};
use crate::linux::dm::{DmName, OpenDeviceError};
use crate::process::privilege::{Root, Unprivileged};
use crate::tools::parse_dm_device;
use crate::tools::IsTool;
use clap::Args;
use serde::Serialize;
use thiserror::Error as ThisError;

#[derive(Debug, ThisError)]
pub enum Error {
    #[error(transparent)]
    Jail(#[from] chroot_jail::OpenError),
    #[error(transparent)]
    Kernel(#[from] chroot_jail::KernelError),
    #[error("opening rootfs device: {0}")]
    Device(#[from] OpenDeviceError),
    #[error("staging kernel: {0}")]
    StageKernel(#[source] dir::Error),
    #[error("creating rootfs node: {0}")]
    Rootfs(#[source] dir::Error),
    #[error("creating /dev/net/tun: {0}")]
    Tun(#[source] dir::Error),
}

#[derive(Args)]
pub struct PrepareArgs {
    /// Chroot root directory (under JAIL_BASE, shape <JAIL_BASE>/<exec>/<id>).
    #[arg(long)]
    chroot: SafePathBuf<IsAbsolute, StrictComponents>,
    /// Host kernel image path (under /srv/hyper); staged as <chroot>/vmlinux.
    #[arg(long)]
    kernel: SafePathBuf<IsAbsolute, StrictComponents>,
    /// Host block device to mirror as <chroot>/rootfs (e.g. /dev/loop0 or
    /// /dev/mapper/hyper-vm1). Its major:minor are read by the helper.
    #[arg(long, value_parser = parse_dm_device)]
    device: DmName,
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
pub fn run(
    args: PrepareArgs,
    token: &mut Unprivileged,
) -> Result<serde_json::Value, crate::tools::Error> {
    let config = Config::get();
    let range = config.uid_gid_range();
    let owner = JailOwner {
        uid: range
            .uid(args.uid)
            .map_err(|e| crate::tools::Error::Tool(Box::new(e)))?,
        gid: range
            .gid(args.gid)
            .map_err(|e| crate::tools::Error::Tool(Box::new(e)))?,
    };
    let tun = config.network().is_some();
    Prepare { args, owner, tun }.run(token)
}

struct Prepare {
    args: PrepareArgs,
    owner: JailOwner,
    tun: bool,
}

impl IsTool for Prepare {
    type Args = PrepareArgs;
    type Output = PrepareOut;
    type RunT = Result<(), Error>;

    fn run_privileged(&self, _root: &Root<'_>) -> Self::RunT {
        let config = Config::get();
        let root = JailRoot::open(&config.jail_base(), &self.args.chroot)?;
        let kernel = KernelImage::open(&self.args.kernel, config.hyper_base())?;
        root.stage_kernel(kernel).map_err(Error::StageKernel)?;
        root.add_rootfs(&self.args.device.open()?, self.owner)
            .map_err(Error::Rootfs)?;
        if self.tun {
            root.add_tun(self.owner).map_err(Error::Tun)?;
        }
        Ok(())
    }

    fn parse(&self, res: Self::RunT) -> Result<PrepareOut, Box<dyn std::error::Error>> {
        res?;
        Ok(PrepareOut::Prepared)
    }
}
