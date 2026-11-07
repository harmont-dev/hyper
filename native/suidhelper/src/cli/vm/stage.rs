// SPDX-License-Identifier: MIT
//! `vm stage`: stage the kernel file and create the rootfs device node
//! inside a VM chroot, via the `ChrootJail` builder.

use crate::config::Config;
use crate::dm::HyperDmName;
use crate::id::{IdError, JailOwner};
use clap::Args;
use hyperrs_firecracker::jailer::chroot::{BuildError, JailLayout, KernelError, KernelImage};
use hyperrs_firecracker::VmId;
use hyperrs_fs::path::{IsAbsolute, SafePathBuf, StrictComponents};
use hyperrs_linux::dm::OpenDeviceError;
use hyperrs_process::privilege::{PrivilegeError, Unprivileged};
use thiserror::Error as ThisError;

#[derive(Debug, ThisError)]
pub enum JailStageError {
    #[error("opening jail root: {0}")]
    Jail(#[from] hyperrs_fs::file::ValidationError),
    #[error("opening rootfs device: {0}")]
    Device(#[from] OpenDeviceError),
    #[error(transparent)]
    Build(#[from] BuildError),
    #[error(transparent)]
    Owner(#[from] IdError),
    #[error(transparent)]
    Kernel(#[from] KernelError),
    #[error(transparent)]
    Privilege(#[from] PrivilegeError),
}

#[derive(Args)]
pub struct StageArgs {
    #[arg(long)]
    id: VmId,
    /// Host kernel image path (under /srv/hyper); staged as `<chroot>/vmlinux`.
    #[arg(long)]
    kernel: SafePathBuf<IsAbsolute, StrictComponents>,
    /// Host block device to mirror as `<chroot>/rootfs` (e.g. /dev/loop0 or
    /// /dev/mapper/hyper-vm1). Its major:minor are read by the helper.
    #[arg(long, value_parser = HyperDmName::from_device_path)]
    device: HyperDmName,
    /// UID to own the staged files.
    #[arg(long)]
    uid: u32,
    /// GID to own the staged files.
    #[arg(long)]
    gid: u32,
}

pub fn run(args: StageArgs, token: &mut Unprivileged) -> Result<(), JailStageError> {
    let config = Config::get();
    let range = config.uid_gid_range();
    let owner = JailOwner {
        uid: range.uid(args.uid)?,
        gid: range.gid(args.gid)?,
    };
    let kernel = KernelImage::open(&args.kernel)?;
    let jail_base = config.jail_base();
    let layout = JailLayout::new(&jail_base, &args.id);
    let _root = token.elevate()?;
    let root = layout.open_root()?;
    let device = args.device.open()?;
    Ok(root
        .builder(owner.into())
        .kernel(&kernel)
        .rootfs(&device)
        .tun(config.network().is_some())
        .build()?)
}
