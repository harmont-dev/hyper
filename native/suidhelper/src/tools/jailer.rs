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
//! live in [`crate::firecracker::jailer`]; this module is only the clap surface plus
//! the trusted-config resolution that feeds them.

use crate::config::{BinError, Config};
use crate::firecracker::id::IdError;
use crate::firecracker::jailer::{CgroupLimits, CpuMax, Jailer, VmId};
use crate::fs::path::{IsAbsolute, SafePath, SafePathBuf, StrictComponents};
use crate::linux::netns;
use crate::process::privilege::Unprivileged;
use clap::Args;
use std::convert::Infallible;
use std::num::NonZeroU64;
use thiserror::Error as ThisError;

#[derive(Debug, ThisError)]
pub enum Error {
    #[error(transparent)]
    Bin(#[from] BinError),
    #[error(transparent)]
    Jail(#[from] crate::firecracker::jailer::Error),
    #[error(transparent)]
    Id(#[from] IdError),
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
    #[arg(long)]
    memory_max: Option<NonZeroU64>,
    #[command(flatten)]
    cpu_max: Option<CpuMax>,
    /// Absolute firecracker API socket path (single filename under `/`).
    #[arg(long = "api-sock")]
    api_sock: SafePathBuf<IsAbsolute, StrictComponents>,
}

/// Validate the caller's args against trusted config, then hand off to
/// [`Jailer::invoke`], which permanently becomes root and `execve`s the jailer.
/// On success this never returns (the process image is replaced); the `Ok` arm
/// is therefore [`std::convert::Infallible`]. Every failure is returned as
/// [`Error`] for the caller to print and exit non-zero.
pub fn run(args: JailerArgs, token: Unprivileged) -> ! {
    let Err(e) = try_run(args, token);
    eprintln!("{e}");
    std::process::exit(2)
}

fn try_run(args: JailerArgs, token: Unprivileged) -> Result<Infallible, Error> {
    let config = Config::get();

    // Resolve everything that can fail as the REAL uid, before any privilege is
    // raised: config accessors, binary validation, range, and arg validation.
    let jailer = config.jailer()?;
    let firecracker = config.firecracker()?;
    let jail_base = config.jail_base();
    let range = config.uid_gid_range();

    let uid = range.uid(args.uid)?;
    let gid = range.gid(args.gid)?;

    // The netns path is derived entirely from trusted config (whether VM
    // networking is enabled) and the already-validated `--id` — the caller
    // cannot name it. Must match the `ip netns add <id>` path the network tool
    // creates. Networking is mandatory, so in practice this is always `Some`.
    let netns = config
        .network()
        .map(|_| SafePath::from_static::<{ netns::DIR }>().join(&args.id));

    Jailer::builder()
        .jailer(&jailer)
        .firecracker(&firecracker)
        .jail_base(&jail_base)
        .parent_cgroup(config.parent_cgroup())
        .vm(&args.id)
        .uid(uid)
        .gid(gid)
        .limits(
            CgroupLimits::builder()
                .maybe_memory_max(args.memory_max)
                .maybe_cpu_max(args.cpu_max)
                .build(),
        )
        .api_sock(&args.api_sock)
        .maybe_netns(netns.as_deref())
        .build()
        .invoke(token)
}
