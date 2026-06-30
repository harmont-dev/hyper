//! Per-tool CLI fragments and their `IsTool` implementations. Each tool lives in
//! its own submodule and owns its own error type and operand validation; this
//! module owns the shared trait, the `Tool` subcommand tree, and the privilege
//! boundary. The binary each tool runs is resolved from the trusted config here,
//! never passed by the caller.

mod blockdev;
pub mod chroot_jail;
mod dmsetup;
mod losetup;

pub use blockdev::{Blockdev, BlockdevArgs};
pub use chroot_jail::ChrootJailOp;
pub use dmsetup::{DmTable, Dmsetup, DmsetupArgs, ThinMessage};
pub use losetup::{Losetup, LosetupArgs};

use crate::config::Config;
use crate::util::setuid_privileged::{self, Privileged};
use clap::Subcommand;
use serde::Serialize;
use thiserror::Error as ThisError;

/// Errors of the dispatch layer: an invalid configured binary (`SafeBin`), the
/// privilege guard, or the chosen tool's own failure on the way out. (Operand
/// validation is handled by clap at parse time, so it never reaches here.)
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

/// The subcommand tree: one subcommand per tool, with the tool-specific args
/// flattened in from the submodule. The binary each tool runs is not a caller
/// argument - it comes from the root-owned config (see [`Config`]).
#[derive(Subcommand)]
pub enum Tool {
    /// Attach/detach loop devices.
    Losetup {
        #[command(flatten)]
        args: LosetupArgs,
    },
    /// Create/remove device-mapper snapshot devices.
    Dmsetup {
        #[command(flatten)]
        args: DmsetupArgs,
    },
    /// Query a block device's size.
    Blockdev {
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
    /// op), returning its already-serialized `Value`. The binary path is taken
    /// from the trusted config and validated (`SafeBin`) here, as the real uid,
    /// before any privilege is acquired.
    pub fn run(self) -> Result<serde_json::Value, Error> {
        let config = Config::get();
        match self {
            Tool::Losetup { args } => {
                let bin = config.losetup().map_err(|e| Error::Tool(Box::new(e)))?;
                Losetup::new(bin.into(), args).run()
            }
            Tool::Dmsetup { args } => {
                let bin = config.dmsetup().map_err(|e| Error::Tool(Box::new(e)))?;
                Dmsetup::new(bin.into(), args).run()
            }
            Tool::Blockdev { args } => {
                let bin = config.blockdev().map_err(|e| Error::Tool(Box::new(e)))?;
                Blockdev::new(bin.into(), args).run()
            }
            Tool::ChrootJail { op } => op.run(),
        }
    }
}
