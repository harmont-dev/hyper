mod message;
mod table;

use super::IsTool;
use crate::linux::dm::{self, Access, DmTable, RemoveMode};
use crate::process::binary::RootSafeBin;
use crate::util::safe_dev::DmName;
use clap::{Args, Subcommand};
pub use message::{parse_message, MessageError, ThinMessage};
use serde::Serialize;
use std::path::PathBuf;
pub use table::{parse_table, TableError};

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
        #[arg(long, value_parser = parse_table)]
        table: DmTable,
    },
    Remove {
        #[arg(long)]
        retry: bool,
        name: DmName,
    },
    Message {
        name: DmName,
        #[arg(long, value_parser = parse_message)]
        message: ThinMessage,
    },
    /// Suspend a dm device (flushes queued I/O; required before `create_snap`
    /// of the device's thin id).
    Suspend { name: DmName },
    /// Resume a suspended dm device.
    Resume { name: DmName },
    /// List the target types the kernel device-mapper exposes. Read-only, but
    /// still needs root: it opens `/dev/mapper/control`.
    Targets,
    /// List the names of existing dm devices (for stale-device reclaim).
    Ls,
}

#[derive(Serialize)]
#[serde(tag = "result", rename_all = "snake_case")]
pub enum DmsetupOut {
    Created { device: PathBuf },
    Removed,
    Messaged,
    Suspended,
    Resumed,
    Targets { output: String },
    Listed { output: String },
}

pub struct Dmsetup {
    dmsetup: dm::Dmsetup,
    op: DmOp,
}

impl Dmsetup {
    pub fn new(bin: RootSafeBin<"dmsetup">, args: DmsetupArgs) -> Self {
        Self {
            dmsetup: dm::Dmsetup::new(bin),
            op: args.op,
        }
    }
}

impl IsTool for Dmsetup {
    type Args = DmsetupArgs;
    type Output = DmsetupOut;
    type RunT = Result<DmsetupOut, Box<dyn std::error::Error>>;

    fn run_privileged(&self) -> Self::RunT {
        let dm = &self.dmsetup;
        Ok(match &self.op {
            DmOp::Create {
                name,
                readonly,
                table,
            } => {
                let access = if *readonly {
                    Access::ReadOnly
                } else {
                    Access::ReadWrite
                };
                DmsetupOut::Created {
                    device: dm.create(name.as_ref(), table, access)?.path(),
                }
            }
            DmOp::Remove { retry, name } => {
                let mode = if *retry {
                    RemoveMode::Retry
                } else {
                    RemoveMode::Once
                };
                dm.device(name.as_ref()).remove(mode)?;
                DmsetupOut::Removed
            }
            DmOp::Message { name, message } => {
                let pool = dm.thin_pool(name.as_ref())?;
                match *message {
                    ThinMessage::CreateThin(id) => pool.create_thin(id).map(drop)?,
                    ThinMessage::CreateSnap { id, origin } => pool.create_snap(id, origin)?,
                    ThinMessage::Delete(id) => pool.delete_thin(id)?,
                    ThinMessage::ReserveMetadataSnap => pool.reserve_metadata_snap()?,
                    ThinMessage::ReleaseMetadataSnap => pool.release_metadata_snap()?,
                }
                DmsetupOut::Messaged
            }
            DmOp::Suspend { name } => {
                dm.device(name.as_ref()).suspend()?;
                DmsetupOut::Suspended
            }
            DmOp::Resume { name } => {
                dm.device(name.as_ref()).resume()?;
                DmsetupOut::Resumed
            }
            DmOp::Targets => DmsetupOut::Targets {
                output: dm
                    .targets()?
                    .iter()
                    .map(|target| format!("{} {}\n", target.name, target.version))
                    .collect(),
            },
            DmOp::Ls => DmsetupOut::Listed { output: dm.list()? },
        })
    }

    fn parse(&self, res: Self::RunT) -> Result<DmsetupOut, Box<dyn std::error::Error>> {
        res
    }
}
