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

use clap::Subcommand;
use serde::Serialize;

pub use host_init::HostInitArgs;
pub use prepare::PrepareArgs;
pub use teardown::TeardownArgs;

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
            NetworkOp::HostInit(args) => host_init::run(args),
        }
    }
}
