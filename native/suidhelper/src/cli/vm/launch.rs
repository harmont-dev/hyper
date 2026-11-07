// SPDX-License-Identifier: MIT
//! The `jailer` subcommand: validate the BEAM's arguments, re-acquire root
//! permanently, and `execve` the firecracker jailer in our place.
//!
//! Unlike the device tools this is **not** an `IsTool`: it does
//! not run a child and parse JSON, it *becomes* the jailer via `execve`, so the
//! unprivileged BEAM's MuonTrap port keeps supervising the resulting process
//! across the image replacement. There is no output and no return on success.
//!
//! The validated newtypes, their refusal contracts, and the `execve` mechanics
//! live in [`hyperrs_firecracker::jailer`]; this module is only the clap surface plus
//! the trusted-config resolution that feeds them.

use crate::config::{BinError, Config};
use crate::id::IdError;
use clap::Args;
use hyperrs_firecracker::jailer::chroot::JailLayout;
use hyperrs_firecracker::jailer::{CgroupLimits, CpuMax, Jailer};
use hyperrs_firecracker::VmId;
use hyperrs_fs::path::SafePath;
use hyperrs_linux::netns;
use hyperrs_process::privilege::Unprivileged;
use std::convert::Infallible;
use std::num::NonZeroU64;
use thiserror::Error as ThisError;

#[derive(Debug, ThisError)]
pub enum JailerError {
    #[error(transparent)]
    Bin(#[from] BinError),
    #[error(transparent)]
    Jail(#[from] hyperrs_firecracker::VmIdError),
    #[error(transparent)]
    Id(#[from] IdError),
}

#[derive(Args)]
pub struct LaunchArgs {
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
    cpu_max: Option<CpuMaxArgs>,
}

#[derive(Args)]
struct CpuMaxArgs {
    #[arg(long = "cpu-quota-us", required = false, requires = "period_us")]
    quota_us: NonZeroU64,
    #[arg(long = "cpu-period-us", required = false, requires = "quota_us")]
    period_us: NonZeroU64,
}

impl From<CpuMaxArgs> for CpuMax {
    fn from(
        CpuMaxArgs {
            quota_us,
            period_us,
        }: CpuMaxArgs,
    ) -> Self {
        Self {
            quota_us,
            period_us,
        }
    }
}

/// Validate the caller's args against trusted config, then hand off to
/// [`Jailer::invoke`], which permanently becomes root and `execve`s the jailer.
/// On success this never returns (the process image is replaced); the `Ok` arm
/// is therefore [`std::convert::Infallible`]. Every failure is returned as
/// [`JailerError`] for the caller to print and exit non-zero.
pub fn run(args: LaunchArgs, token: Unprivileged) -> ! {
    let Err(e) = try_run(args, token);
    eprintln!("{e}");
    std::process::exit(2)
}

fn try_run(args: LaunchArgs, token: Unprivileged) -> Result<Infallible, JailerError> {
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

    let layout = JailLayout::new(&jail_base, &args.id);
    let api_sock = SafePath::from_static::<"/">().join(super::API_SOCKET);

    Jailer::builder()
        .jailer(&jailer)
        .firecracker(&firecracker)
        .layout(&layout)
        .parent_cgroup(config.parent_cgroup())
        .uid(uid.into())
        .gid(gid.into())
        .limits(
            CgroupLimits::builder()
                .maybe_memory_max(args.memory_max)
                .maybe_cpu_max(args.cpu_max.map(CpuMax::from))
                .build(),
        )
        .api_sock(&api_sock)
        .maybe_netns(netns.as_deref())
        .build()
        .invoke(token)
}

#[cfg(test)]
mod tests {
    use super::LaunchArgs;
    use clap::{Args, FromArgMatches};
    use pretty_assertions::assert_eq;
    use rstest::rstest;

    fn parse(id: &str, extra: &[&str]) -> Result<LaunchArgs, clap::Error> {
        let base = ["--id", id, "--uid", "900001", "--gid", "900001"];
        let matches = LaunchArgs::augment_args(clap::Command::new("launch").no_binary_name(true))
            .try_get_matches_from(base.iter().chain(extra))?;
        LaunchArgs::from_arg_matches(&matches)
    }

    #[rstest]
    #[case::none(&[], true)]
    #[case::memory_max(&["--memory-max", "1048576"], true)]
    #[case::cpu_quota_and_period(&["--cpu-quota-us", "50000", "--cpu-period-us", "100000"], true)]
    #[case::all_minimal(&["--memory-max", "1", "--cpu-quota-us", "1", "--cpu-period-us", "1"], true)]
    #[case::zero_memory(&["--memory-max", "0"], false)]
    #[case::literal_max_memory(&["--memory-max", "max"], false)]
    #[case::negative_memory(&["--memory-max", "-1"], false)]
    #[case::suffixed_memory(&["--memory-max", "12x"], false)]
    #[case::memory_past_u64(&["--memory-max", "18446744073709551616"], false)]
    #[case::repeated_memory(&["--memory-max", "1", "--memory-max", "2"], false)]
    #[case::quota_without_period(&["--cpu-quota-us", "50000"], false)]
    #[case::period_without_quota(&["--cpu-period-us", "100000"], false)]
    #[case::zero_quota(&["--cpu-quota-us", "0", "--cpu-period-us", "100000"], false)]
    #[case::zero_period(&["--cpu-quota-us", "50000", "--cpu-period-us", "0"], false)]
    #[case::repeated_quota(
        &["--cpu-quota-us", "1", "--cpu-quota-us", "2", "--cpu-period-us", "1"],
        false
    )]
    #[case::raw_cgroup(&["--cgroup", "memory.max=1"], false)]
    #[case::caller_named_api_socket(&["--api-sock", "/api.socket"], false)]
    #[case::caller_named_netns(&["--netns", "/var/run/netns/other"], false)]
    #[case::caller_named_exec_file(&["--exec-file", "/bin/sh"], false)]
    #[case::caller_named_chroot_base(&["--chroot-base-dir", "/"], false)]
    fn caller_flags(#[case] extra: &[&str], #[case] accepted: bool) {
        assert_eq!(parse("vm1", extra).is_ok(), accepted, "{extra:?}");
    }

    #[rstest]
    #[case::plain("vm1", true)]
    #[case::dashed("vm-1", true)]
    #[case::empty("", false)]
    #[case::parent("..", false)]
    #[case::traversal("../vm1", false)]
    #[case::nested("a/b", false)]
    #[case::leading_dash("-vm1", false)]
    #[case::underscore("a_b", false)]
    fn vm_id(#[case] id: &str, #[case] accepted: bool) {
        assert_eq!(parse(id, &[]).is_ok(), accepted, "{id:?}");
    }
}
