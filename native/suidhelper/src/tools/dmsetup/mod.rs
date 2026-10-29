mod backing;
mod message;
mod name;
mod table;

use super::IsTool;
use crate::linux::dm::{self, DmName, RemoveMode};
use crate::linux::loopdev::LoopControl;
use crate::linux::Access;
use crate::process::binary::RootSafeBin;
use crate::process::privilege::Root;
pub use backing::{BackingError, BackingFile};
use clap::{Args, Subcommand};
pub use message::{parse_message, MessageError, ThinMessage};
pub use name::{parse_dm_device, parse_dm_name, NameError};
use serde::Serialize;
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::time::Duration;
pub use table::{parse_table, resolve_table, Slot, Source, TableError, TableSpec};

const ATTACH_TIMEOUT: Duration = Duration::from_secs(1);

#[derive(Args)]
pub struct DmsetupArgs {
    #[command(subcommand)]
    op: DmOp,
}

#[derive(Subcommand)]
enum DmOp {
    Create {
        #[arg(value_parser = parse_dm_name)]
        name: DmName,
        #[arg(long)]
        readonly: bool,
        #[arg(long, value_parser = resolve_table)]
        table: TableSpec<BackingFile>,
    },
    Remove {
        #[arg(long)]
        retry: bool,
        #[arg(value_parser = parse_dm_name)]
        name: DmName,
    },
    Message {
        #[arg(value_parser = parse_dm_name)]
        name: DmName,
        #[arg(long, value_parser = parse_message)]
        message: ThinMessage,
    },
    /// Suspend a dm device (flushes queued I/O; required before `create_snap`
    /// of the device's thin id).
    Suspend {
        #[arg(value_parser = parse_dm_name)]
        name: DmName,
    },
    /// Resume a suspended dm device.
    Resume {
        #[arg(value_parser = parse_dm_name)]
        name: DmName,
    },
    /// List the target types the kernel device-mapper exposes. Read-only, but
    /// still needs root: it opens `/dev/mapper/control`.
    Targets,
    /// List the names of existing dm devices (for stale-device reclaim).
    Ls,
}

#[derive(Serialize)]
#[serde(tag = "result", rename_all = "snake_case")]
pub enum DmsetupOut {
    Created {
        device: PathBuf,
        loops: BTreeMap<Slot, PathBuf>,
    },
    Removed,
    Messaged,
    Suspended,
    Resumed,
    Targets {
        output: String,
    },
    Listed {
        output: String,
    },
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

    fn run_privileged(&self, _root: &Root<'_>) -> Self::RunT {
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
                let control = LoopControl::open()?;
                let mut loops = BTreeMap::new();
                let attached = table.try_map(|backing, slot| {
                    let slot_access = match slot {
                        Slot::Origin => Access::ReadOnly,
                        Slot::Cow => access,
                        Slot::Metadata | Slot::Data => Access::ReadWrite,
                    };
                    let device = control.attach(backing.file(), slot_access, ATTACH_TIMEOUT)?;
                    loops.insert(slot, device.path().as_ref().to_path_buf());
                    Ok::<_, Box<dyn std::error::Error>>(device)
                })?;
                DmsetupOut::Created {
                    device: dm.create(name, &attached.to_dm(), access)?.path().into(),
                    loops,
                }
            }
            DmOp::Remove { retry, name } => {
                let mode = if *retry {
                    RemoveMode::Retry
                } else {
                    RemoveMode::Once
                };
                dm.device(name).remove(mode)?;
                DmsetupOut::Removed
            }
            DmOp::Message { name, message } => {
                let pool = dm.thin_pool(name)?;
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
                dm.device(name).suspend()?;
                DmsetupOut::Suspended
            }
            DmOp::Resume { name } => {
                dm.device(name).resume()?;
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
