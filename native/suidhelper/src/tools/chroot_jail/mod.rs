// SPDX-License-Identifier: AGPL-3.0-only
//! `chroot-jail`: per-VM chroot/jail lifecycle.

mod grant;
pub mod grant_api;
pub mod grant_vsock;
mod prepare;
pub mod remove;

pub use grant_api::GrantApiArgs;
pub use grant_vsock::GrantVsockArgs;
pub use prepare::PrepareArgs;
pub use remove::RemoveArgs;

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
    pub fn run(self) -> Result<serde_json::Value, crate::tools::Error> {
        match self {
            ChrootJailOp::Prepare(args) => prepare::run(args),
            ChrootJailOp::Remove(args) => remove::run(args),
            ChrootJailOp::GrantApi(args) => grant_api::run(args),
            ChrootJailOp::GrantVsock(args) => grant_vsock::run(args),
        }
    }
}
