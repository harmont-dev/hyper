// SPDX-License-Identifier: MIT
//! `network`: per-VM networking — an **unimplemented placeholder** pending a
//! ground-up rewrite.
//!
//! The subcommand tree and its arguments are kept as the CLI interface, but
//! every op fails with [`Unimplemented`] without acquiring privilege or
//! touching the system.

use crate::util::jailer::VmId;
use clap::{Args, Subcommand};
use thiserror::Error as ThisError;

/// Returned by every `network` op until VM networking is rewritten.
#[derive(Debug, ThisError, PartialEq, Eq)]
#[error("VM networking is unimplemented (pending the networking rewrite)")]
pub struct Unimplemented;

#[derive(Args)]
pub struct PrepareArgs {
    /// Microvm id.
    #[arg(long)]
    pub vm_id: VmId,
    /// Unprivileged uid the VM runs as.
    #[arg(long)]
    pub uid: u32,
}

#[derive(Args)]
pub struct TeardownArgs {
    /// Microvm id.
    #[arg(long)]
    pub vm_id: VmId,
    /// Unprivileged uid the VM ran as.
    #[arg(long)]
    pub uid: u32,
}

#[derive(Args)]
pub struct TeardownOrphanArgs {
    /// Microvm id.
    #[arg(long)]
    pub vm_id: VmId,
}

#[derive(Args)]
pub struct HostInitArgs {}

#[derive(Subcommand)]
pub enum NetworkOp {
    /// Set up a VM's networking (unimplemented).
    Prepare(PrepareArgs),
    /// Tear down a VM's networking (unimplemented).
    Teardown(TeardownArgs),
    /// Reclaim an orphan VM's networking by vm_id alone (unimplemented).
    TeardownOrphan(TeardownOrphanArgs),
    /// One-time host networking setup (unimplemented).
    HostInit(HostInitArgs),
}

impl NetworkOp {
    /// Every op refuses with [`Unimplemented`]; nothing is run.
    pub fn run(self) -> Result<serde_json::Value, crate::tools::Error> {
        match self {
            NetworkOp::Prepare(_)
            | NetworkOp::Teardown(_)
            | NetworkOp::TeardownOrphan(_)
            | NetworkOp::HostInit(_) => Err(crate::tools::Error::Tool(Box::new(Unimplemented))),
        }
    }
}
