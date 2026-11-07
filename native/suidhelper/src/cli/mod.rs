//! CLI interface of the setuid helper.

pub mod dm;
mod host_init;
mod sys_test;
pub mod thin_copy;
mod version;
pub mod vm;

use crate::config::Config;
use clap::{Parser, Subcommand};
use hyperrs_process::privilege::{self, Unprivileged};
use serde::Serialize;
use thiserror::Error as ThisError;
use vm::VmOp;

/// Errors of the dispatch layer: an invalid configured binary (`RootSafeBin`), the
/// privilege guard, or the chosen tool's own failure on the way out. (Operand
/// validation is handled by clap at parse time, so it never reaches here.)
#[derive(Debug, ThisError)]
pub enum DispatchError {
    #[error(transparent)]
    Privilege(#[from] privilege::PrivilegeError),
    /// A tool's own error (operand validation or execution), boxed so this layer
    /// stays decoupled from each tool's concrete error type.
    #[error(transparent)]
    Tool(Box<dyn std::error::Error>),
    #[error(transparent)]
    Retryable(Box<dyn std::error::Error>),
}

pub const EXIT_FAILURE: i32 = 2;
pub const EXIT_RETRYABLE: i32 = 75;

impl DispatchError {
    pub fn tool(e: impl std::error::Error + 'static) -> Self {
        DispatchError::Tool(Box::new(e))
    }

    pub fn exit_code(&self) -> i32 {
        match self {
            DispatchError::Retryable(_) => EXIT_RETRYABLE,
            DispatchError::Privilege(_) | DispatchError::Tool(_) => EXIT_FAILURE,
        }
    }
}

pub fn to_json(out: impl Serialize) -> Result<serde_json::Value, DispatchError> {
    serde_json::to_value(out).map_err(DispatchError::tool)
}

#[derive(Parser)]
#[command(
    name = "hyper-suidhelper",
    about = "Privileged device helper for the Hyper node"
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

/// The subcommand tree: one subcommand per tool, with the tool-specific args
/// flattened in from the submodule. The binary each tool runs is not a caller
/// argument - it comes from the root-owned config (see [`Config`]).
#[derive(Subcommand)]
enum Command {
    Vm {
        #[command(subcommand)]
        op: VmOp,
    },
    Dm {
        #[command(flatten)]
        args: dm::DmArgs,
    },
    ThinCopy {
        #[command(flatten)]
        args: thin_copy::ThinCopyArgs,
    },
    HostInit,
    SysTest,
    Version,
}

pub fn run(token: Unprivileged) {
    let command = Cli::parse().command;

    // `version` is a pure self-report: it touches neither config nor privileges,
    // so render it before any setup that could fail (e.g. a missing config file).
    if let Command::Version = command {
        println!("{}", serde_json::to_string(&version::render()).unwrap());
        return;
    }

    Config::init();

    let output = dispatch(command, token)
        .and_then(|value| serde_json::to_string(&value).map_err(DispatchError::tool));
    match output {
        Ok(json) => println!("{json}"),
        Err(e) => {
            eprintln!("{e}");
            std::process::exit(e.exit_code());
        }
    }
}

fn dispatch(command: Command, mut token: Unprivileged) -> Result<serde_json::Value, DispatchError> {
    match command {
        Command::Vm { op } => op.run(token),
        Command::Dm { args } => to_json(dm::run(args, &mut token).map_err(DispatchError::tool)?),
        Command::ThinCopy { args } => {
            to_json(thin_copy::run(args, &mut token).map_err(DispatchError::tool)?)
        }
        Command::HostInit => to_json(host_init::run(&mut token).map_err(DispatchError::tool)?),
        Command::SysTest => to_json(sys_test::run(&mut token)?),
        Command::Version => unreachable!("handled in `run`"),
    }
}
