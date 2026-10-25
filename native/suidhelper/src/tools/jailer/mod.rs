// SPDX-License-Identifier: MIT
//! The `jailer` subcommand: validate the BEAM's arguments, re-acquire root
//! permanently, and `execve` the firecracker jailer in our place.
//!
//! Unlike the device tools this is **not** an [`crate::tools::IsTool`]: it does
//! not run a child and parse JSON, it *becomes* the jailer via `execve`, so the
//! unprivileged BEAM's MuonTrap port keeps supervising the resulting process
//! across the image replacement. There is no output and no return on success.
//!
//! Threat model: the BEAM is untrusted. It supplies only the VM id, uid/gid,
//! cgroup settings, and the API socket path — each guarded by a newtype
//! ([`VmId`], [`JailId`](crate::vm::JailId), [`args`]). Every privileged path
//! (the jailer binary, the firecracker `--exec-file`, the chroot base, the
//! parent cgroup) comes from the root-owned config, never the caller. A
//! compromised BEAM must not be able to name a privileged path, request uid 0,
//! traverse out of the chroot base, inject a flag, or smuggle an
//! environment/fd into root.

pub mod args;
mod cstr;
mod invoke;

pub use args::{CgroupSetting, JailSock, MAX_CGROUPS};

use crate::config::{BinError, Config};
use crate::privilege;
use crate::vm::{self, VmId};
use clap::Args;
use invoke::Jailer;
use nix::errno::Errno;
use std::ffi::NulError;
use std::path::PathBuf;
use thiserror::Error as ThisError;

#[derive(Debug, ThisError)]
pub enum Error {
    #[error(transparent)]
    Bin(#[from] BinError),
    #[error(transparent)]
    Vm(#[from] vm::Error),
    #[error("invalid --cgroup {0:?}: unknown key or value outside its grammar")]
    Cgroup(String),
    #[error("invalid --api-sock {0:?}: must be /<name> with name in [A-Za-z0-9_.-]")]
    Sock(String),
    #[error("too many --cgroup settings: {0} (max {MAX_CGROUPS})")]
    TooManyCgroups(usize),
    #[error(transparent)]
    Privilege(#[from] privilege::Error),
    #[error("argument contains an interior NUL byte")]
    NulArgument(#[from] NulError),
    #[error("execve {path:?} failed: {errno}")]
    Exec { path: PathBuf, errno: Errno },
}

#[derive(Args)]
pub struct JailerArgs {
    /// Microvm id; becomes the chroot subdirectory name.
    #[arg(long)]
    id: VmId,
    /// Unprivileged uid the jailer drops to (rejected if 0 or out of range).
    #[arg(long)]
    uid: u32,
    /// Unprivileged gid the jailer drops to (rejected if 0 or out of range).
    #[arg(long)]
    gid: u32,
    /// Repeatable `KEY=VALUE` cgroup setting from the allowlist.
    #[arg(long = "cgroup")]
    cgroup: Vec<CgroupSetting>,
    /// Absolute firecracker API socket path (single filename under `/`).
    #[arg(long = "api-sock")]
    api_sock: JailSock,
}

/// Validate the caller's args against trusted config, then hand off to
/// `Jailer::invoke`, which permanently becomes root and `execve`s the jailer.
/// On success this never returns (the process image is replaced); the `Ok` arm
/// is therefore [`std::convert::Infallible`]. Every failure is returned as
/// [`Error`] for the caller to print and exit non-zero.
pub fn run(args: JailerArgs) -> Result<std::convert::Infallible, Error> {
    let config = Config::get();

    // Resolve everything that can fail as the REAL uid, before any privilege is
    // raised: config accessors, binary validation, range, and arg validation.
    let jailer: PathBuf = config.jailer()?.into();
    let firecracker: PathBuf = config.firecracker()?.into();
    let jail_base = config.jail_base();
    let range = config.uid_gid_range();

    let uid = range.admit(args.uid)?;
    let gid = range.admit(args.gid)?;

    // The netns path is derived entirely from trusted config (whether VM
    // networking is enabled) and the already-validated `--id` — the caller
    // cannot name it. Must match the `ip netns add <id>` path the network tool
    // creates. Networking is mandatory, so in practice this is always `Some`.
    let netns: Option<PathBuf> = config
        .network()
        .map(|_| PathBuf::from(format!("/var/run/netns/{}", args.id)));

    Jailer::builder()
        .jailer(&jailer)
        .firecracker(&firecracker)
        .jail_base(&jail_base)
        .parent_cgroup(config.parent_cgroup())
        .vm(&args.id)
        .uid(uid)
        .gid(gid)
        .cgroups(&args.cgroup)
        .api_sock(&args.api_sock)
        .maybe_netns(netns.as_deref())
        .build()
        .invoke()
}
