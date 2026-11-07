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

use super::VmOut;
use crate::cli::{Op, OpError};
use crate::config::{BinError, Config};
use crate::id::IdError;
use hyperrs_firecracker::jailer::chroot::JailLayout;
use hyperrs_firecracker::jailer::{CgroupLimits, CpuMax, Jailer};
use hyperrs_firecracker::VmId;
use hyperrs_fs::path::SafePath;
use hyperrs_linux::netns;
use hyperrs_process::privilege::Unprivileged;
use serde::Deserialize;
use serde_with::{serde_as, DisplayFromStr};
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

#[serde_as]
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Launch {
    /// Microvm id; becomes the chroot subdirectory name.
    #[serde_as(as = "DisplayFromStr")]
    id: VmId,
    /// Unprivileged uid the jailer drops to (rejected if 0 or out of range).
    uid: u32,
    /// Unprivileged gid the jailer drops to (rejected if 0 or out of range).
    gid: u32,
    memory_max: Option<NonZeroU64>,
    cpu_max: Option<CpuMaxArgs>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct CpuMaxArgs {
    quota_us: NonZeroU64,
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
impl Op for Launch {
    type Output = VmOut;
    type Error = JailerError;

    fn run(self, token: Unprivileged) -> Result<VmOut, JailerError> {
        try_run(self, token).map(|never| match never {})
    }
}

fn try_run(args: Launch, token: Unprivileged) -> Result<Infallible, JailerError> {
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

impl OpError for JailerError {}

#[cfg(test)]
mod tests {
    use super::Launch;
    use pretty_assertions::assert_eq;
    use rstest::rstest;
    use serde_json::{json, Value};

    fn parse(id: &str, extra: Value) -> Result<Launch, serde_json::Error> {
        let mut request = json!({"id": id, "uid": 900_001, "gid": 900_001});
        request
            .as_object_mut()
            .unwrap()
            .extend(extra.as_object().unwrap().clone());
        serde_json::from_value(request)
    }

    #[rstest]
    #[case::none(json!({}), true)]
    #[case::memory_max(json!({"memory_max": 1_048_576}), true)]
    #[case::cpu_max(json!({"cpu_max": {"quota_us": 50_000, "period_us": 100_000}}), true)]
    #[case::all_minimal(json!({"memory_max": 1, "cpu_max": {"quota_us": 1, "period_us": 1}}), true)]
    #[case::explicit_nulls(json!({"memory_max": null, "cpu_max": null}), true)]
    #[case::zero_memory(json!({"memory_max": 0}), false)]
    #[case::negative_memory(json!({"memory_max": -1}), false)]
    #[case::string_memory(json!({"memory_max": "max"}), false)]
    #[case::memory_past_u64(json!({"memory_max": 18_446_744_073_709_551_616_f64}), false)]
    #[case::quota_without_period(json!({"cpu_max": {"quota_us": 50_000}}), false)]
    #[case::period_without_quota(json!({"cpu_max": {"period_us": 100_000}}), false)]
    #[case::zero_quota(json!({"cpu_max": {"quota_us": 0, "period_us": 100_000}}), false)]
    #[case::zero_period(json!({"cpu_max": {"quota_us": 50_000, "period_us": 0}}), false)]
    #[case::extra_cpu_field(json!({"cpu_max": {"quota_us": 1, "period_us": 1, "burst_us": 1}}), false)]
    #[case::raw_cgroup(json!({"cgroup": "memory.max=1"}), false)]
    #[case::caller_named_api_socket(json!({"api_sock": "/api.socket"}), false)]
    #[case::caller_named_netns(json!({"netns": "/var/run/netns/other"}), false)]
    #[case::caller_named_exec_file(json!({"exec_file": "/bin/sh"}), false)]
    #[case::caller_named_chroot_base(json!({"chroot_base_dir": "/"}), false)]
    #[case::negative_uid(json!({"uid": -1}), false)]
    #[case::string_uid(json!({"uid": "900001"}), false)]
    fn fields(#[case] extra: Value, #[case] accepted: bool) {
        assert_eq!(parse("vm1", extra.clone()).is_ok(), accepted, "{extra}");
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
        assert_eq!(parse(id, json!({})).is_ok(), accepted, "{id:?}");
    }
}
