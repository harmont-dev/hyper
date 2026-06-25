mod message;
mod snapshot;
mod table;
mod thin;
mod thin_pool;

use super::IsTool;
use crate::util::safe_dev::{self, DmName};
use clap::{Args, Subcommand};
pub use message::ThinMessage;
use serde::Serialize;
use std::io;
use std::path::PathBuf;
use std::process::{Command, Output};
pub use table::DmTable;
use thiserror::Error as ThisError;

#[derive(Debug, ThisError)]
pub enum Error {
    #[error("dmsetup table must be a snapshot target: {0}")]
    BadTable(String),
    #[error(transparent)]
    Device(#[from] safe_dev::Error),
    #[error("running dmsetup: {0}")]
    Spawn(#[source] io::Error),
    #[error("dmsetup failed: {0}")]
    Failed(String),
}

#[derive(Args)]
pub struct DmsetupArgs {
    #[command(subcommand)]
    op: DmOp,
}

#[derive(Subcommand)]
enum DmOp {
    Create {
        name: DmName,
        #[arg(long)]
        readonly: bool,
        #[arg(long)]
        table: DmTable,
    },
    Remove {
        #[arg(long)]
        retry: bool,
        name: DmName,
    },
    Message {
        name: DmName,
        #[arg(long)]
        message: ThinMessage,
    },
}

#[derive(Serialize)]
#[serde(tag = "result", rename_all = "snake_case")]
pub enum DmsetupOut {
    Created { device: PathBuf },
    Removed,
    Messaged,
}

pub struct Dmsetup {
    bin: PathBuf,
    op: DmOp,
}

impl Dmsetup {
    pub fn new(bin: PathBuf, args: DmsetupArgs) -> Self {
        Self { bin, op: args.op }
    }
}

impl IsTool for Dmsetup {
    type Args = DmsetupArgs;
    type Output = DmsetupOut;
    type RunT = io::Result<Output>;

    fn run_privileged(&self) -> Self::RunT {
        let mut cmd = Command::new(&self.bin);
        match &self.op {
            DmOp::Create {
                name,
                readonly,
                table,
            } => {
                cmd.arg("create").arg(name.to_string());
                if *readonly {
                    cmd.arg("--readonly");
                }
                cmd.arg("--table").arg(table.to_string());
            }
            DmOp::Remove { retry, name } => {
                cmd.arg("remove");
                if *retry {
                    cmd.arg("--retry");
                }
                cmd.arg(name.to_string());
            }
            DmOp::Message { name, message } => {
                cmd.arg("message")
                    .arg(name.to_string())
                    .arg("0")
                    .arg(message.to_string());
            }
        }

        cmd.env_clear().output()
    }

    fn parse(&self, res: Self::RunT) -> Result<DmsetupOut, Box<dyn std::error::Error>> {
        let out = res.map_err(Error::Spawn)?;
        if !out.status.success() {
            return Err(
                Error::Failed(String::from_utf8_lossy(&out.stderr).trim().to_string()).into(),
            );
        }

        Ok(match &self.op {
            DmOp::Create { name, .. } => DmsetupOut::Created {
                device: PathBuf::from(format!("/dev/mapper/{name}")),
            },
            DmOp::Remove { .. } => DmsetupOut::Removed,
            DmOp::Message { .. } => DmsetupOut::Messaged,
        })
    }
}
