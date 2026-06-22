// SPDX-License-Identifier: AGPL-3.0-only
//! `chroot-jail`: per-VM chroot/jail lifecycle.

mod prepare;
mod remove;

pub use prepare::{PrepareArgs, PrepareOut};
pub use remove::{RemoveArgs, RemoveOut};

use clap::Subcommand;

#[derive(Subcommand)]
pub enum ChrootJailOp {
    /// Prepare a VM chroot: stage the kernel and create the rootfs device node.
    Prepare(PrepareArgs),
    /// Remove a VM's stale chroot and cgroup leaf before relaunching the jailer.
    Remove(RemoveArgs),
}

impl ChrootJailOp {
    /// Route to the selected nested tool and wrap its output. `chroot-jail` itself
    /// carries no behaviour; each op runs in its own privileged scope.
    pub fn run(self) -> Result<crate::tools::ToolOutput, crate::tools::Error> {
        match self {
            ChrootJailOp::Prepare(args) => {
                Ok(crate::tools::ToolOutput::Prepare(prepare::run(args)?))
            }
            ChrootJailOp::Remove(args) => {
                Ok(crate::tools::ToolOutput::Remove(remove::run(args)?))
            }
        }
    }
}
