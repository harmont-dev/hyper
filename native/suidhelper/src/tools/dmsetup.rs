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
/// Only this target is accepted - other dm targets (linear, crypt, ...) could map
/// arbitrary devices - and origin/cow are anchored to loop / hyper-* devices by
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

/// A dm-thin-pool table: `0 <sectors> thin-pool <meta> <data> <block_sectors> <low_water>`.
/// meta/data are our own loop devices; no feature args are accepted.
#[derive(Clone)]
pub struct ThinPoolTable {
    sectors: u64,
    metadata: LoopDev,
    data: LoopDev,
    block_sectors: u64,
    low_water: u64,
}

impl FromStr for ThinPoolTable {
    type Err = Error;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let f: Vec<&str> = s.split_whitespace().collect();
        let ["0", sectors, "thin-pool", meta, data, block, low] = f.as_slice() else {
            return Err(Error::BadTable(s.to_string()));
        };
        Ok(Self {
            sectors: sectors.parse().map_err(|_| Error::BadTable(s.to_string()))?,
            metadata: meta.parse()?,
            data: data.parse()?,
            block_sectors: block.parse().map_err(|_| Error::BadTable(s.to_string()))?,
            low_water: low.parse().map_err(|_| Error::BadTable(s.to_string()))?,
        })
    }
}

impl fmt::Display for ThinPoolTable {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let meta: &Path = self.metadata.as_ref();
        let data: &Path = self.data.as_ref();
        write!(
            f,
            "0 {} thin-pool {} {} {} {}",
            self.sectors, meta.display(), data.display(), self.block_sectors, self.low_water
        )
    }
}

/// A dm-thin table: `0 <sectors> thin <pool> <dev_id> [<external_origin>]`.
/// pool + origin are anchored to our own dm/loop devices.
#[derive(Clone)]
pub struct ThinTable {
    sectors: u64,
    pool: BlockDev,
    dev_id: u64,
    origin: Option<BlockDev>,
}

impl FromStr for ThinTable {
    type Err = Error;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let f: Vec<&str> = s.split_whitespace().collect();
        let (sectors, pool, dev_id, origin) = match f.as_slice() {
            ["0", sectors, "thin", pool, id] => (sectors, pool, id, None),
            ["0", sectors, "thin", pool, id, origin] => (sectors, pool, id, Some(origin)),
            _ => return Err(Error::BadTable(s.to_string())),
        };
        Ok(Self {
            sectors: sectors.parse().map_err(|_| Error::BadTable(s.to_string()))?,
            pool: pool.parse()?,
            dev_id: dev_id.parse().map_err(|_| Error::BadTable(s.to_string()))?,
            origin: origin.map(|o| o.parse()).transpose()?,
        })
    }
}

impl fmt::Display for ThinTable {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let pool: &Path = self.pool.as_ref();
        write!(f, "0 {} thin {} {}", self.sectors, pool.display(), self.dev_id)?;
        if let Some(origin) = &self.origin {
            let origin: &Path = origin.as_ref();
            write!(f, " {}", origin.display())?;
        }
        Ok(())
    }
}

/// Any dm table we are willing to create. The variant is chosen by the target
/// keyword; every variant re-renders from validated fields so dmsetup only ever
/// sees a table we reconstructed.
#[derive(Clone)]
pub enum DmTable {
    Snapshot(SnapshotTable),
    ThinPool(ThinPoolTable),
    Thin(ThinTable),
}

impl FromStr for DmTable {
    type Err = Error;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.split_whitespace().nth(2) {
            Some("snapshot") => Ok(DmTable::Snapshot(s.parse()?)),
            Some("thin-pool") => Ok(DmTable::ThinPool(s.parse()?)),
            Some("thin") => Ok(DmTable::Thin(s.parse()?)),
            _ => Err(Error::BadTable(s.to_string())),
        }
    }
}

impl fmt::Display for DmTable {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            DmTable::Snapshot(t) => t.fmt(f),
            DmTable::ThinPool(t) => t.fmt(f),
            DmTable::Thin(t) => t.fmt(f),
        }
    }
}

/// A thin-pool message we permit: provision or drop a thin device by id.
#[derive(Clone)]
pub enum ThinMessage {
    CreateThin(u64),
    Delete(u64),
}

impl FromStr for ThinMessage {
    type Err = Error;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.split_whitespace().collect::<Vec<_>>().as_slice() {
            ["create_thin", id] => Ok(ThinMessage::CreateThin(
                id.parse().map_err(|_| Error::BadTable(s.to_string()))?,
            )),
            ["delete", id] => Ok(ThinMessage::Delete(
                id.parse().map_err(|_| Error::BadTable(s.to_string()))?,
            )),
            _ => Err(Error::BadTable(s.to_string())),
        }
    }
}

impl fmt::Display for ThinMessage {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ThinMessage::CreateThin(id) => write!(f, "create_thin {id}"),
            ThinMessage::Delete(id) => write!(f, "delete {id}"),
        }
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
    Created { device: String },
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
            DmOp::Message { name, message } => {
                cmd.arg("message").arg(name.to_string()).arg("0").arg(message.to_string());
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
            DmOp::Message { .. } => DmsetupOut::Messaged,
        })
    }
}
