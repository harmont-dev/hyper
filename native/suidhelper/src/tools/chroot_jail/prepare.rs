// SPDX-License-Identifier: MIT
//! `chroot-jail prepare`: stage the kernel file and create the rootfs device node
//! inside a VM chroot, via the [`ChrootJail`] builder.

use crate::config::Config;
use crate::id::JailOwner;
use crate::tools::parse_dm_device;
use crate::tools::IsTool;
use clap::Args;
use hyperrs_firecracker::jailer::chroot::{BuildError, JailLayout, KernelImage};
use hyperrs_firecracker::VmId;
use hyperrs_fs::path::{IsAbsolute, SafePathBuf, StrictComponents};
use hyperrs_linux::dm::{DmName, OpenDeviceError};
use hyperrs_process::privilege::{Root, Unprivileged};
use serde::Serialize;
use thiserror::Error as ThisError;

#[derive(Debug, ThisError)]
pub enum JailPrepareError {
    #[error("opening jail root: {0}")]
    Jail(#[from] hyperrs_fs::file::ValidationError),
    #[error("opening rootfs device: {0}")]
    Device(#[from] OpenDeviceError),
    #[error(transparent)]
    Build(#[from] BuildError),
}

#[derive(Args)]
pub struct PrepareArgs {
    #[arg(long)]
    id: VmId,
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
) -> Result<serde_json::Value, crate::tools::DispatchError> {
    let config = Config::get();
    let range = config.uid_gid_range();
    let owner = JailOwner {
        uid: range
            .uid(args.uid)
            .map_err(|e| crate::tools::DispatchError::Tool(Box::new(e)))?,
        gid: range
            .gid(args.gid)
            .map_err(|e| crate::tools::DispatchError::Tool(Box::new(e)))?,
    };
    let kernel = KernelImage::open(&args.kernel)
        .map_err(|e| crate::tools::DispatchError::Tool(Box::new(e)))?;
    let tun = config.network().is_some();
    Prepare {
        args,
        kernel,
        owner,
        tun,
    }
    .run(token)
}

struct Prepare {
    args: PrepareArgs,
    kernel: KernelImage,
    owner: JailOwner,
    tun: bool,
}

impl IsTool for Prepare {
    type Args = PrepareArgs;
    type Output = PrepareOut;
    type RunT = Result<(), JailPrepareError>;

    fn run_privileged(&self, _root: &Root<'_>) -> Self::RunT {
        let config = Config::get();
        let jail_base = config.jail_base();
        let root = JailLayout::new(&jail_base, &self.args.id).open_root()?;
        let device = self.args.device.open()?;
        root.builder(self.owner.into())
            .kernel(&self.kernel)
            .rootfs(&device)
            .tun(self.tun)
            .build()?;
        Ok(())
    }

    fn parse(&self, res: Self::RunT) -> Result<PrepareOut, Box<dyn std::error::Error>> {
        res?;
        Ok(PrepareOut::Prepared)
    }
}
