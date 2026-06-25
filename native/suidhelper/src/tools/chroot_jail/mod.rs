// SPDX-License-Identifier: AGPL-3.0-only
//! `chroot-jail`: per-VM chroot/jail lifecycle.

mod prepare;
pub mod remove;

pub use prepare::PrepareArgs;
pub use remove::RemoveArgs;

use clap::Subcommand;

#[derive(Subcommand)]
pub enum ChrootJailOp {
    /// Prepare a VM chroot: stage the kernel and create the rootfs device node.
    Prepare(PrepareArgs),
    /// Remove a VM's stale chroot and cgroup leaf before relaunching the jailer.
    Remove(RemoveArgs),
}

impl ChrootJailOp {
    /// Route to the selected nested tool. `chroot-jail` itself carries no
    /// behaviour; each op runs in its own privileged scope and returns its own
    /// serialized `Value`.
    pub fn run(self) -> Result<serde_json::Value, crate::tools::Error> {
        match self {
            ChrootJailOp::Prepare(args) => prepare::run(args),
            ChrootJailOp::Remove(args) => remove::run(args),
        }
    }
}
