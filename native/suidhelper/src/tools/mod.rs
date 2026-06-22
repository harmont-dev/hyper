//! Per-tool CLI fragments and their `IsTool` implementations. Each tool lives in
//! its own submodule and owns its own error type, operand validation, and `--bin`
//! parser; this module owns the shared trait, the `Tool` subcommand tree, and the
//! privilege boundary.

mod blockdev;
mod chroot_jail;
mod dmsetup;
mod losetup;
pub(crate) mod mknod;
pub(crate) mod stage;

pub use blockdev::{Blockdev, BlockdevArgs, BlockdevOut};
pub use chroot_jail::{ChrootJail, ChrootJailOp, ChrootJailOut};
pub use dmsetup::{Dmsetup, DmsetupArgs, DmsetupOut};
pub use losetup::{Losetup, LosetupArgs, LosetupOut};

use crate::safe_bin::SafeBin;
use crate::setuid_privileged::{self, Privileged};
use clap::Subcommand;
use serde::Serialize;
use thiserror::Error as ThisError;

/// Errors of the dispatch layer: whatever the privilege guard or the chosen tool
/// raises on the way out. (`--bin` and operand validation are handled by clap at
/// parse time, so they never reach here.)
#[derive(Debug, ThisError)]
pub enum Error {
    #[error(transparent)]
    Privilege(#[from] setuid_privileged::Error),
    /// A tool's own error (operand validation or execution), boxed so this layer
    /// stays decoupled from each tool's concrete error type.
    #[error(transparent)]
    Tool(Box<dyn std::error::Error>),
}

/// The typed result of running a tool, ready to be serialized by the caller.
/// Untagged so each tool's own output shape is emitted verbatim.
#[derive(Serialize)]
#[serde(untagged)]
pub enum ToolOutput {
    Losetup(LosetupOut),
    Dmsetup(DmsetupOut),
    Blockdev(BlockdevOut),
    ChrootJail(ChrootJailOut),
}

/// A device tool: the clap args it accepts, the result type it produces, and how
/// to run it. `run` performs the operation (invoking the real binary) and returns
/// a serializable result - no argv is exposed to the caller.
pub trait IsTool {
    type Args: clap::Args;
    type Output: Serialize;
    type RunT;

    /// Execute the privileged part of the tool - normally invoking `Command`.
    /// This is the only code that runs as root (see `run`).
    fn run_privileged(&self) -> Self::RunT;

    /// Parse the result of `run_privileged` into the output data structure. At
    /// this point, the setuid has been demoted.
    fn parse(&self, res: Self::RunT) -> Result<Self::Output, Box<dyn std::error::Error>>;

    /// The privilege boundary: `run_privileged` executes as root inside the
    /// `Privileged` guard's scope; the guard drops privileges to the real uid
    /// when it falls out of scope, so `parse` never runs as root. The root window
    /// is exactly the one `run_privileged` call.
    fn run(&self) -> Result<Self::Output, Error> {
        let res = {
            let _privileged = Privileged::acquire()?;
            self.run_privileged()
        };

        self.parse(res).map_err(Error::Tool)
    }
}

/// The subcommand tree: one subcommand per tool, each taking its own `--bin`
/// with the tool-specific args flattened in from the submodule.
#[derive(Subcommand)]
pub enum Tool {
    /// Attach/detach loop devices.
    Losetup {
        #[arg(long)]
        bin: SafeBin<"losetup">,
        #[command(flatten)]
        args: LosetupArgs,
    },
    /// Create/remove device-mapper snapshot devices.
    Dmsetup {
        #[arg(long)]
        bin: SafeBin<"dmsetup">,
        #[command(flatten)]
        args: DmsetupArgs,
    },
    /// Query a block device's size.
    Blockdev {
        #[arg(long)]
        bin: SafeBin<"blockdev">,
        #[command(flatten)]
        args: BlockdevArgs,
    },
    /// chroot/jail lifecycle operations (scoped subcommands).
    ChrootJail {
        #[command(subcommand)]
        op: ChrootJailOp,
    },
}

impl Tool {
    /// Hand off to `finish`, which keeps the root window as small as possible:
    /// only the tool's `run` executes as root; privileges are dropped before its
    /// `post` parses the result. The `--bin` is already validated (it is a
    /// `SafeBin`, constructed only by its value parser).
    pub fn run(self) -> Result<ToolOutput, Error> {
        match self {
            Tool::Losetup { bin, args } => {
                Ok(ToolOutput::Losetup(Losetup::new(bin.into(), args).run()?))
            }
            Tool::Dmsetup { bin, args } => {
                Ok(ToolOutput::Dmsetup(Dmsetup::new(bin.into(), args).run()?))
            }
            Tool::Blockdev { bin, args } => {
                Ok(ToolOutput::Blockdev(Blockdev::new(bin.into(), args).run()?))
            }
            Tool::ChrootJail { op } => {
                Ok(ToolOutput::ChrootJail(ChrootJail::new(op).run()?))
            }
        }
    }
}
