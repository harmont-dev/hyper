// SPDX-License-Identifier: AGPL-3.0-only
//! `network`: per-VM egress networking (netns + veth + TAP + NAT).
//!
//! This module currently wires the CLI skeleton (`NetworkOp` and its arg
//! structs) and the pure argv builders in [`args`]. The `run` bodies are typed
//! no-ops; the real privileged execution (invoking `ip`/`nft` with the argv
//! [`args`] builds) lands with the rest of the prepare/teardown/host-init logic.
pub mod addr;
pub mod args;

use crate::tools::jailer::VmId;
use clap::{Args, Subcommand};

#[derive(Args)]
pub struct PrepareArgs {
    /// Microvm id; becomes the netns name.
    #[arg(long)]
    vm_id: VmId,
    /// Unprivileged uid the VM runs as; derives its clone-pool `/30` slot.
    #[arg(long)]
    uid: u32,
}

#[derive(Args)]
pub struct TeardownArgs {
    /// Microvm id; names the netns to remove.
    #[arg(long)]
    vm_id: VmId,
    /// Unprivileged uid the VM ran as; derives its clone-pool `/30` slot.
    #[arg(long)]
    uid: u32,
}

#[derive(Args)]
pub struct HostInitArgs {}

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
    /// Route to the selected op. Bodies are stubs for now (Task 4 fills the
    /// privileged execution); each already returns its own serialized `Value`.
    pub fn run(self) -> Result<serde_json::Value, crate::tools::Error> {
        match self {
            NetworkOp::Prepare(_) => Ok(serde_json::json!({"result": "noop"})),
            NetworkOp::Teardown(_) => Ok(serde_json::json!({"result": "noop"})),
            NetworkOp::HostInit(_) => Ok(serde_json::json!({"result": "noop"})),
        }
    }
}
