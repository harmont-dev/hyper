use super::IsTool;
use crate::safe_dev::{self, BlockDev, DmName, LoopDev};
use clap::{Args, Subcommand};
use serde::Serialize;
use std::fmt;
use std::io;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::str::FromStr;
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

/// A dm-snapshot table line: `0 <sectors> snapshot <origin> <cow> P|N <chunk>`.
/// Only this target is accepted — other dm targets (linear, crypt, …) could map
/// arbitrary devices — and origin/cow are anchored to loop / hyper-* devices by
/// their types. Parsed from the caller's string, then rendered back via
/// `Display` so dmsetup only ever sees a table we reconstructed ourselves.
#[derive(Clone)]
pub struct SnapshotTable {
    sectors: u64,
    origin: BlockDev,
    cow: LoopDev,
    persistent: bool,
    chunk: u64,
}

impl FromStr for SnapshotTable {
    type Err = Error;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let fields: Vec<&str> = s.split_whitespace().collect();
        let [start, sectors, "snapshot", origin, cow, mode, chunk] = fields.as_slice() else {
            return Err(Error::BadTable(s.to_string()));
        };

        let persistent = match *mode {
            "P" => true,
            "N" => false,
            _ => return Err(Error::BadTable(s.to_string())),
        };

        if *start != "0" {
            return Err(Error::BadTable(s.to_string()));
        }

        Ok(Self {
            sectors: sectors.parse().map_err(|_| Error::BadTable(s.to_string()))?,
            origin: origin.parse()?,
            cow: cow.parse()?,
            persistent,
            chunk: chunk.parse().map_err(|_| Error::BadTable(s.to_string()))?,
        })
    }
}

impl fmt::Display for SnapshotTable {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let origin: &Path = self.origin.as_ref();
        let cow: &Path = self.cow.as_ref();
        write!(
            f,
            "0 {} snapshot {} {} {} {}",
            self.sectors,
            origin.display(),
            cow.display(),
            if self.persistent { "P" } else { "N" },
            self.chunk,
        )
    }
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
        table: SnapshotTable,
    },
    Remove {
        #[arg(long)]
        retry: bool,
        name: DmName,
    },
}

#[derive(Serialize)]
#[serde(tag = "result", rename_all = "snake_case")]
pub enum DmsetupOut {
    Created { device: String },
    Removed,
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
            DmOp::Create { name, readonly, table } => {
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
        }

        cmd.env_clear().output()
    }

    fn parse(&self, res: Self::RunT) -> Result<DmsetupOut, Box<dyn std::error::Error>> {
        let out = res.map_err(Error::Spawn)?;
        if !out.status.success() {
            return Err(Error::Failed(String::from_utf8_lossy(&out.stderr).trim().to_string()).into());
        }

        Ok(match &self.op {
            DmOp::Create { name, .. } => DmsetupOut::Created { device: format!("/dev/mapper/{name}") },
            DmOp::Remove { .. } => DmsetupOut::Removed,
        })
    }
}
