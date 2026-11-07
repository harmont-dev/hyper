mod backing;
mod name;
mod table;

use super::IsTool;
pub use backing::{BackingError, BackingFile};
use clap::{Args, Subcommand};
use hyperrs_linux::dm::{self, DmTable, RemoveMode, Role, ThinMessage};
use hyperrs_linux::loopdev::LoopControl;
use hyperrs_linux::Access;
use hyperrs_process::binary::RootSafeBin;
use hyperrs_process::privilege::Root;
pub use name::{HyperDmName, NameError};
use serde::Serialize;
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::time::Duration;
pub use table::{parse_table, resolve_table, TableError};

const ATTACH_TIMEOUT: Duration = Duration::from_secs(1);

#[derive(Args)]
pub struct DmsetupArgs {
    #[command(subcommand)]
    op: DmOp,
}

#[derive(Subcommand)]
enum DmOp {
    Create {
        name: HyperDmName,
        #[arg(long)]
        readonly: bool,
        #[arg(long, value_parser = resolve_table)]
        table: DmTable<BackingFile>,
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
    /// Suspend a dm device (flushes queued I/O; required before `create_snap`
    /// of the device's thin id).
    Suspend { name: HyperDmName },
    /// Resume a suspended dm device.
    Resume { name: HyperDmName },
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
        loops: BTreeMap<Role, PathBuf>,
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
                let attached = table.clone().try_map(|backing, role| {
                    let role_access = match role {
                        Role::Origin => Access::ReadOnly,
                        Role::Cow => access,
                        Role::Metadata | Role::Data => Access::ReadWrite,
                    };
                    let device = control.attach(backing.file(), role_access, ATTACH_TIMEOUT)?;
                    loops.insert(role, device.path().as_ref().to_path_buf());
                    Ok::<_, Box<dyn std::error::Error>>(device)
                })?;
                DmsetupOut::Created {
                    device: dm.create(name, &attached, access)?.path().into(),
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
                dm.thin_pool(name)?.send(*message)?;
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
