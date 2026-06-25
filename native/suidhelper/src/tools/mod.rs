//! Per-tool CLI fragments and their `IsTool` implementations. Each tool lives in
//! its own submodule and owns its own error type, operand validation, and `--bin`
//! parser; this module owns the shared trait, the `Tool` subcommand tree, and the
//! privilege boundary.

mod blockdev;
pub mod chroot_jail;
mod dmsetup;
mod losetup;

pub use blockdev::{Blockdev, BlockdevArgs};
pub use chroot_jail::ChrootJailOp;
pub use dmsetup::{DmTable, Dmsetup, DmsetupArgs, ThinMessage};
pub use losetup::{Losetup, LosetupArgs};

use crate::util::safe_bin::SafeBin;
use crate::util::setuid_privileged::{self, Privileged};
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

/// A device tool: the clap args it accepts, the result type it produces, and how
/// to run it. `run` performs the operation (invoking the real binary) and returns
/// the result already serialized to a `serde_json::Value` - no argv is exposed to
/// the caller, and the dispatcher needs no per-tool sum type.
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
    /// when it falls out of scope, so `parse` (and serialization) never run as
    /// root. The root window is exactly the one `run_privileged` call. Serializes
    /// the parsed output to a `Value` so every tool returns one common type.
    fn run(&self) -> Result<serde_json::Value, Error> {
        let res = {
            let _privileged = Privileged::acquire()?;
            self.run_privileged()
        };

        let output = self.parse(res).map_err(Error::Tool)?;
        serde_json::to_value(output).map_err(|e| Error::Tool(Box::new(e)))
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
    /// Dispatch to the selected tool's `run` (or, for `chroot-jail`, its nested
    /// op), returning its already-serialized `Value`. The `--bin` is already
    /// validated (it is a `SafeBin`, constructed only by its value parser).
    pub fn run(self) -> Result<serde_json::Value, Error> {
        match self {
            Tool::Losetup { bin, args } => Losetup::new(bin.into(), args).run(),
            Tool::Dmsetup { bin, args } => Dmsetup::new(bin.into(), args).run(),
            Tool::Blockdev { bin, args } => Blockdev::new(bin.into(), args).run(),
            Tool::ChrootJail { op } => op.run(),
        }
    }
}
