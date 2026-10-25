// SPDX-License-Identifier: MIT
//! The IP link: veth pair, TAP, routes, NAT and proxy NDP.

use super::Unimplemented;
use crate::util::jailer::VmId;
use clap::{Args, Subcommand};

#[derive(Args)]
pub struct HostInitArgs {}

#[derive(Args)]
pub struct PrepareArgs {
    #[arg(long)]
    pub vm_id: VmId,
    #[arg(long)]
    pub uid: u32,
}

#[derive(Args)]
pub struct TeardownArgs {
    #[arg(long)]
    pub vm_id: VmId,
}

#[derive(Subcommand)]
pub enum IpOp {
    /// Prepare the host to be able to serve IP traffic.
    HostInit(HostInitArgs),
    /// Create the IP interfaces in a VM's network namespace.
    Prepare(PrepareArgs),
    /// Tear down the IP interfaces that were created for a VM.
    Teardown(TeardownArgs),
}

impl IpOp {
    /// Every op refuses with [`Unimplemented`]; nothing is run.
    pub fn run(self) -> Result<serde_json::Value, crate::tools::Error> {
        match self {
            IpOp::HostInit(_) | IpOp::Prepare(_) | IpOp::Teardown(_) => {
                Err(crate::tools::Error::Tool(Box::new(Unimplemented)))
            }
        }
    }
}
