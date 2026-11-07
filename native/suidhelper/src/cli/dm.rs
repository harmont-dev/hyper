use crate::config::Config;
use crate::dm::{HyperDmName, HyperDmTable, TableError};
use clap::{Args, Subcommand};
use hyperrs_linux::dm::{
    self, DevPath, DmTable, LinearTable, Origin, Persistence, RemoveMode, Role, SnapshotTable,
    ThinId, ThinMessage, ThinPoolTable, ThinTable,
};
use hyperrs_linux::loopdev::{self, LoopControl};
use hyperrs_linux::Access;
use hyperrs_process::binary::RootSafeBinError;
use hyperrs_process::privilege::{PrivilegeError, Unprivileged};
use serde::Serialize;
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::time::Duration;
use thiserror::Error as ThisError;

const ATTACH_TIMEOUT: Duration = Duration::from_secs(1);

#[derive(Args)]
pub struct DmArgs {
    #[command(subcommand)]
    op: DmOp,
}

#[derive(Args)]
struct CreateArgs {
    name: HyperDmName,
    #[arg(long)]
    readonly: bool,
    #[arg(long)]
    sectors: u64,
}

#[derive(Subcommand)]
enum DmOp {
    Linear {
        #[command(flatten)]
        create: CreateArgs,
        #[arg(long)]
        origin: Origin,
    },
    Snapshot {
        #[command(flatten)]
        create: CreateArgs,
        #[arg(long)]
        origin: Origin,
        #[arg(long)]
        cow: DevPath,
        #[arg(long)]
        chunk_sectors: u64,
    },
    ThinPool {
        #[command(flatten)]
        create: CreateArgs,
        #[arg(long)]
        metadata: DevPath,
        #[arg(long)]
        data: DevPath,
        #[arg(long)]
        block_sectors: u64,
        #[arg(long)]
        low_water: u64,
    },
    Thin {
        #[command(flatten)]
        create: CreateArgs,
        #[arg(long)]
        pool: HyperDmName,
        #[arg(long)]
        thin_id: ThinId,
        #[arg(long)]
        origin: Option<Origin>,
    },
    Remove {
        #[arg(long)]
        retry: bool,
        name: HyperDmName,
    },
    Message {
        name: HyperDmName,
        #[arg(long)]
        message: ThinMessage,
    },
    Suspend {
        name: HyperDmName,
    },
    Resume {
        name: HyperDmName,
    },
}

impl DmOp {
    fn into_plan(self) -> Result<Plan, TableError> {
        let (table, create) = match self {
            DmOp::Linear { create, origin } => (
                DmTable::Linear(LinearTable {
                    sectors: create.sectors,
                    origin,
                }),
                create,
            ),
            DmOp::Snapshot {
                create,
                origin,
                cow,
                chunk_sectors,
            } => (
                DmTable::Snapshot(SnapshotTable {
                    sectors: create.sectors,
                    origin,
                    cow,
                    persistence: Persistence::Persistent,
                    chunk: chunk_sectors,
                }),
                create,
            ),
            DmOp::ThinPool {
                create,
                metadata,
                data,
                block_sectors,
                low_water,
            } => (
                DmTable::ThinPool(ThinPoolTable {
                    sectors: create.sectors,
                    metadata,
                    data,
                    block_sectors,
                    low_water,
                }),
                create,
            ),
            DmOp::Thin {
                create,
                pool,
                thin_id,
                origin,
            } => (
                DmTable::Thin(ThinTable {
                    sectors: create.sectors,
                    pool: (*pool).clone(),
                    id: thin_id,
                    origin,
                }),
                create,
            ),
            DmOp::Remove { retry, name } => return Ok(Plan::Remove { retry, name }),
            DmOp::Message { name, message } => return Ok(Plan::Message { name, message }),
            DmOp::Suspend { name } => return Ok(Plan::Suspend { name }),
            DmOp::Resume { name } => return Ok(Plan::Resume { name }),
        };
        Ok(Plan::Create {
            name: create.name,
            readonly: create.readonly,
            table: HyperDmTable::new(table)?,
        })
    }
}

enum Plan {
    Create {
        name: HyperDmName,
        readonly: bool,
        table: HyperDmTable,
    },
    Remove {
        retry: bool,
        name: HyperDmName,
    },
    Message {
        name: HyperDmName,
        message: ThinMessage,
    },
    Suspend {
        name: HyperDmName,
    },
    Resume {
        name: HyperDmName,
    },
}

#[derive(Serialize)]
#[serde(tag = "result", rename_all = "snake_case")]
pub enum DmOut {
    Created {
        device: PathBuf,
        loops: BTreeMap<Role, PathBuf>,
    },
    Removed,
    Messaged,
    Suspended,
    Resumed,
}

#[derive(Debug, ThisError)]
pub enum DmError {
    #[error(transparent)]
    Table(#[from] TableError),
    #[error(transparent)]
    Privilege(#[from] PrivilegeError),
    #[error(transparent)]
    LoopControl(#[from] loopdev::OpenError),
    #[error(transparent)]
    Attach(#[from] loopdev::AttachError),
    #[error(transparent)]
    Run(#[from] dm::RunError),
    #[error(transparent)]
    Pool(#[from] dm::ThinPoolError),
    #[error(transparent)]
    Bin(#[from] RootSafeBinError),
}

pub fn run(args: DmArgs, token: &mut Unprivileged) -> Result<DmOut, DmError> {
    let dm = dm::Dmsetup::new(Config::get().dmsetup()?);
    Ok(match args.op.into_plan()? {
        Plan::Create {
            name,
            readonly,
            table,
        } => {
            let access = if readonly {
                Access::ReadOnly
            } else {
                Access::ReadWrite
            };
            let (device, loops) = {
                let _root = token.elevate()?;
                let control = LoopControl::open()?;
                let mut loops = BTreeMap::new();
                let attached = table.attach(|role, backing| {
                    let role_access = match role {
                        Role::Origin => Access::ReadOnly,
                        Role::Cow => access,
                        Role::Metadata | Role::Data => Access::ReadWrite,
                    };
                    let device = control.attach(backing.file(), role_access, ATTACH_TIMEOUT)?;
                    let path = device.path().to_owned();
                    loops.insert(role, device);
                    Ok::<_, DmError>(path)
                })?;
                (dm.create(&name, &attached, access)?.path().into(), loops)
            };
            DmOut::Created {
                device,
                loops: loops
                    .iter()
                    .map(|(&role, device)| (role, device.path().as_ref().to_path_buf()))
                    .collect(),
            }
        }
        Plan::Remove { retry, name } => {
            let mode = if retry {
                RemoveMode::Retry
            } else {
                RemoveMode::Once
            };
            let _root = token.elevate()?;
            dm.device(&name).remove(mode)?;
            DmOut::Removed
        }
        Plan::Message { name, message } => {
            let _root = token.elevate()?;
            dm.thin_pool(&name)?.send(message)?;
            DmOut::Messaged
        }
        Plan::Suspend { name } => {
            let _root = token.elevate()?;
            dm.device(&name).suspend()?;
            DmOut::Suspended
        }
        Plan::Resume { name } => {
            let _root = token.elevate()?;
            dm.device(&name).resume()?;
            DmOut::Resumed
        }
    })
}
