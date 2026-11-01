// SPDX-License-Identifier: MIT
//! `chroot-jail`: per-VM chroot/jail lifecycle.

pub mod grant_api;
pub mod grant_vsock;
mod prepare;
pub mod remove;

pub use grant_api::GrantApiArgs;
pub use grant_vsock::GrantVsockArgs;
pub use prepare::PrepareArgs;
pub use remove::RemoveArgs;

use crate::process::privilege::Unprivileged;
use clap::Subcommand;

#[derive(Subcommand)]
pub enum ChrootJailOp {
    /// Prepare a VM chroot: stage the kernel and create the rootfs device node.
    Prepare(PrepareArgs),
    /// Remove a VM's stale chroot and cgroup leaf before relaunching the jailer.
    Remove(RemoveArgs),
    /// Hand the firecracker API socket to the node user (chown to caller, 0660).
    GrantApi(GrantApiArgs),
    /// Hand the firecracker vsock socket to the node user (chown to caller, 0660).
    GrantVsock(GrantVsockArgs),
}

impl ChrootJailOp {
    /// Route to the selected nested tool. `chroot-jail` itself carries no
    /// behaviour; each op runs in its own privileged scope and returns its own
    /// serialized `Value`.
    pub fn run(self, token: &mut Unprivileged) -> Result<serde_json::Value, crate::tools::Error> {
        match self {
            ChrootJailOp::Prepare(args) => prepare::run(args, token),
            ChrootJailOp::Remove(args) => remove::run(args, token),
            ChrootJailOp::GrantApi(args) => grant_api::run(args, token),
            ChrootJailOp::GrantVsock(args) => grant_vsock::run(args, token),
        }
    }
}
