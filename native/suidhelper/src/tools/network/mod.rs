// SPDX-License-Identifier: AGPL-3.0-only
//! `network`: per-VM egress networking (netns + veth + TAP + NAT).
//!
//! Each op ([`prepare`], [`teardown`], [`host_init`]) derives its `ip`/`nft`
//! argv (built in [`args`]) from the validated uid and [`crate::config::Config::network`],
//! then runs it through [`exec::run_all`], which stops at the first non-zero
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
use clap::Subcommand;
use serde::Serialize;
use thiserror::Error as ThisError;

pub use host_init::HostInitArgs;
pub use prepare::PrepareArgs;
pub use teardown::TeardownArgs;
pub use teardown_orphan::TeardownOrphanArgs;

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

/// The result shape shared by all three networking ops, tagged by which ran.
#[derive(Serialize)]
#[serde(tag = "result", rename_all = "snake_case")]
pub enum NetworkOut {
    Prepared,
    ToreDown,
    HostReady,
}

#[derive(Subcommand)]
pub enum NetworkOp {
    /// Create a VM's netns, veth pair, TAP device, and in-netns NAT.
    Prepare(PrepareArgs),
    /// Remove a VM's netns and any lingering host-side veth end.
    Teardown(TeardownArgs),
    /// Idempotently remove an orphan VM's netns by vm_id alone (no uid).
    TeardownOrphan(TeardownOrphanArgs),
    /// One-time host setup: the `hyper` nftables table and forward policy.
    HostInit(HostInitArgs),
}

impl NetworkOp {
    /// Route to the selected op; each runs in its own privileged scope and
    /// returns its own serialized `Value`.
    pub fn run(self) -> Result<serde_json::Value, crate::tools::Error> {
        match self {
            NetworkOp::Prepare(args) => prepare::run(args),
            NetworkOp::Teardown(args) => teardown::run(args),
            NetworkOp::TeardownOrphan(args) => teardown_orphan::run(args),
            NetworkOp::HostInit(args) => host_init::run(args),
        }
    }
}
