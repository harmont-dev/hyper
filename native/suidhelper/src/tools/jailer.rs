// SPDX-License-Identifier: MIT
//! The `jailer` subcommand: validate the BEAM's arguments, re-acquire root
//! permanently, and `execve` the firecracker jailer in our place.
//!
//! Unlike the device tools this is **not** an [`crate::tools::IsTool`]: it does
//! not run a child and parse JSON, it *becomes* the jailer via `execve`, so the
//! unprivileged BEAM's MuonTrap port keeps supervising the resulting process
//! across the image replacement. There is no output and no return on success.
//!
//! The validated newtypes, their refusal contracts, and the `execve` mechanics
//! live in [`crate::util::jailer`]; this module is only the clap surface plus
//! the trusted-config resolution that feeds them.

use crate::config::{BinError, Config};
use crate::util::jailer::Jailer;
use clap::Args;
use std::path::PathBuf;
use thiserror::Error as ThisError;

pub use crate::util::jailer::{validate_id_number, CgroupSetting, JailSock, VmId};

#[derive(Debug, ThisError)]
pub enum Error {
    #[error(transparent)]
    Bin(#[from] BinError),
    #[error(transparent)]
    Jail(#[from] crate::util::jailer::Error),
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
/// [`Jailer::invoke`], which permanently becomes root and `execve`s the jailer.
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

    let uid = validate_id_number(args.uid, range).map_err(Error::Jail)?;
    let gid = validate_id_number(args.gid, range).map_err(Error::Jail)?;

    // The netns path is derived entirely from trusted config (whether VM
    // networking is enabled) and the already-validated `--id` — the caller
    // cannot name it. Must match the `ip netns add <id>` path the network tool
    // creates. Networking is mandatory, so in practice this is always `Some`.
    let netns: Option<PathBuf> = config
        .network()
        .map(|_| PathBuf::from(format!("/var/run/netns/{}", args.id)));

    Ok(Jailer::builder()
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
        .invoke()?)
}
