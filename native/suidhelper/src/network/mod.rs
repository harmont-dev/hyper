// SPDX-License-Identifier: MIT
//! `network`: per-VM egress networking (netns + veth + TAP + NAT).
//!
//! Each op ([`prepare`](mod@prepare), [`teardown`](mod@teardown), [`host_init`](mod@host_init)) derives its `ip`/`nft`
//! argv (built in [`args`]) from the validated uid and [`crate::config::Config::network`],
//! then runs it through `exec::run_all`, which stops at the first non-zero
//! exit. Every refusal — `uid` outside the configured range, a malformed
//! `clone_pool` CIDR, or `[network]` absent from config — happens while
//! resolving the op (see `prepare::resolve`), strictly before `run_privileged`
//! is ever reached, so no privileged command runs on invalid input.
pub mod addr;
pub mod args;
mod exec;
pub mod host_init;
pub mod prepare;
pub mod teardown;
pub mod teardown_orphan;

use crate::config::Network;
use hyperrs_firecracker::VmId;
use hyperrs_process::privilege::Unprivileged;
use thiserror::Error as ThisError;

/// `[network]` is absent from config, i.e. VM networking is disabled.
#[derive(Debug, ThisError, PartialEq, Eq)]
#[error("VM networking is not configured ([network] absent from config)")]
pub struct NetworkingDisabled;

/// Refuse before any privileged command is ever spawned when `[network]` is
/// absent from config. Pure — takes the already-loaded `Option<&Network>`
/// rather than reaching into [`crate::config::Config`] itself — so this exact
/// refusal path is exercisable from tests without root or a live config file,
/// and `prepare`/`teardown`/`host_init` all resolve through this one function
/// rather than duplicating the check.
pub fn resolve_network(network: Option<&Network>) -> Result<&Network, NetworkingDisabled> {
    network.ok_or(NetworkingDisabled)
}

#[derive(Debug, ThisError)]
pub enum TeardownError {
    #[error(transparent)]
    Planned(#[from] teardown::NetworkTeardownError),
    #[error(transparent)]
    Orphan(#[from] teardown_orphan::OrphanTeardownError),
}

pub fn prepare(
    vm_id: &VmId,
    uid: u32,
    token: &mut Unprivileged,
) -> Result<(), prepare::NetworkPrepareError> {
    prepare::Prepare::new(uid, vm_id)?.run(token)
}

pub fn teardown(
    vm_id: &VmId,
    uid: Option<u32>,
    token: &mut Unprivileged,
) -> Result<(), TeardownError> {
    match uid {
        Some(uid) => teardown::Teardown::new(uid, vm_id)?.run(token)?,
        None => teardown_orphan::TeardownOrphan::new(vm_id)?.run(token)?,
    }
    Ok(())
}

pub fn host_init(token: &mut Unprivileged) -> Result<(), host_init::HostInitError> {
    host_init::HostInit::new()?.run(token)
}

pub fn enabled() -> bool {
    crate::config::Config::get().network().is_some()
}
