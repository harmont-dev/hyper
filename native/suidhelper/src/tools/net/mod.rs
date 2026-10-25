// SPDX-License-Identifier: MIT
//! Networking commands.

pub mod ip;

use crate::util::jailer::VmId;
use clap::{Args, Subcommand};
use ip::IpOp;
use thiserror::Error as ThisError;

#[derive(Debug, ThisError, PartialEq, Eq)]
#[error("VM networking is unimplemented (pending the networking rewrite)")]
pub struct Unimplemented;

#[derive(Args)]
pub struct PrepareArgs {
    #[arg(long)]
    pub vm_id: VmId,
}

#[derive(Args)]
pub struct TeardownArgs {
    #[arg(long)]
    pub vm_id: VmId,
}

#[derive(Subcommand)]
pub enum NetOp {
    /// Create a VM's network namespace.
    Prepare(PrepareArgs),
    /// Delete a VM's network namespace.
    Teardown(TeardownArgs),
    /// The IP link inside a VM's network namespace.
    Ip {
        #[command(subcommand)]
        op: IpOp,
    },
}

impl NetOp {
    /// Every op refuses with [`Unimplemented`]; nothing is run.
    pub fn run(self) -> Result<serde_json::Value, crate::tools::Error> {
        match self {
            NetOp::Prepare(_) | NetOp::Teardown(_) => {
                Err(crate::tools::Error::Tool(Box::new(Unimplemented)))
            }
            NetOp::Ip { op } => op.run(),
        }
    }
}
