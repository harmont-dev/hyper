use crate::cli::Op;
use crate::cli::ThinIdNumber;
use crate::config::Config;
use crate::dm::{HyperDmName, HyperDmTable, TableError};
use hyperrs_fs::file::{self, OpenFlags};
use hyperrs_linux::dm::{
    self, DevPath, DmTable, LinearTable, Origin, Persistence, RemoveMode, Role, SnapshotTable,
    ThinId, ThinMessage, ThinPoolTable, ThinTable,
};
use hyperrs_linux::loopdev::{self, LoopControl};
use hyperrs_linux::Access;
use hyperrs_process::binary::RootSafeBinError;
use hyperrs_process::privilege::{PrivilegeError, Unprivileged};
use nix::sys::stat::fstat;
use serde::{Deserialize, Serialize};
use serde_with::{serde_as, DisplayFromStr};
use std::collections::BTreeMap;
use std::os::fd::AsRawFd;
use std::path::PathBuf;
use std::time::Duration;
use thiserror::Error as ThisError;

const ATTACH_TIMEOUT: Duration = Duration::from_secs(1);
const SECTOR_BYTES: u64 = 512;

#[serde_as]
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Linear {
    #[serde_as(as = "DisplayFromStr")]
    name: HyperDmName,
    readonly: bool,
    #[serde_as(as = "DisplayFromStr")]
    origin: Origin,
}

#[serde_as]
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Snapshot {
    #[serde_as(as = "DisplayFromStr")]
    name: HyperDmName,
    readonly: bool,
    #[serde_as(as = "DisplayFromStr")]
    origin: Origin,
    #[serde_as(as = "DisplayFromStr")]
    cow: DevPath,
    chunk_sectors: u64,
}

#[serde_as]
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ThinPool {
    #[serde_as(as = "DisplayFromStr")]
    name: HyperDmName,
    #[serde_as(as = "DisplayFromStr")]
    metadata: DevPath,
    #[serde_as(as = "DisplayFromStr")]
    data: DevPath,
    block_sectors: u64,
    low_water: u64,
}

#[serde_as]
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Thin {
    #[serde_as(as = "DisplayFromStr")]
    name: HyperDmName,
    #[serde_as(as = "DisplayFromStr")]
    pool: HyperDmName,
    #[serde_as(as = "ThinIdNumber")]
    thin_id: ThinId,
    #[serde_as(as = "DisplayFromStr")]
    origin: Origin,
}

#[serde_as]
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Remove {
    #[serde_as(as = "DisplayFromStr")]
    name: HyperDmName,
    retry: bool,
}

#[serde_as]
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Suspend {
    #[serde_as(as = "DisplayFromStr")]
    name: HyperDmName,
}

#[serde_as]
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Resume {
    #[serde_as(as = "DisplayFromStr")]
    name: HyperDmName,
}

#[serde_as]
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Message {
    #[serde_as(as = "DisplayFromStr")]
    name: HyperDmName,
    #[serde_as(as = "DisplayFromStr")]
    message: ThinMessage,
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
    #[error(transparent)]
    Device(#[from] dm::OpenDeviceError),
    #[error("opening the size source: {0}")]
    Reopen(#[from] file::ValidationError),
    #[error("reading the size source: {0}")]
    Size(#[source] nix::Error),
    #[error("the table has no device to size it from")]
    Unsized,
}

impl Op for Linear {
    type Output = DmOut;
    type Error = DmError;

    fn run(self, mut token: Unprivileged) -> Result<DmOut, DmError> {
        let Linear {
            name,
            readonly,
            origin,
        } = self;
        let table = DmTable::Linear(LinearTable { sectors: 0, origin });
        create(&name, access(readonly), table, &mut token)
    }
}

impl Op for Snapshot {
    type Output = DmOut;
    type Error = DmError;

    fn run(self, mut token: Unprivileged) -> Result<DmOut, DmError> {
        let Snapshot {
            name,
            readonly,
            origin,
            cow,
            chunk_sectors,
        } = self;
        let table = DmTable::Snapshot(SnapshotTable {
            sectors: 0,
            origin,
            cow,
            persistence: Persistence::Persistent,
            chunk: chunk_sectors,
        });
        create(&name, access(readonly), table, &mut token)
    }
}

impl Op for ThinPool {
    type Output = DmOut;
    type Error = DmError;

    fn run(self, mut token: Unprivileged) -> Result<DmOut, DmError> {
        let ThinPool {
            name,
            metadata,
            data,
            block_sectors,
            low_water,
        } = self;
        let table = DmTable::ThinPool(ThinPoolTable {
            sectors: 0,
            metadata,
            data,
            block_sectors,
            low_water,
        });
        create(&name, Access::ReadWrite, table, &mut token)
    }
}

impl Op for Thin {
    type Output = DmOut;
    type Error = DmError;

    fn run(self, mut token: Unprivileged) -> Result<DmOut, DmError> {
        let Thin {
            name,
            pool,
            thin_id,
            origin,
        } = self;
        let table = DmTable::Thin(ThinTable {
            sectors: 0,
            pool: (*pool).clone(),
            id: thin_id,
            origin: Some(origin),
        });
        create(&name, Access::ReadWrite, table, &mut token)
    }
}

impl Op for Remove {
    type Output = DmOut;
    type Error = DmError;

    fn run(self, mut token: Unprivileged) -> Result<DmOut, DmError> {
        let Remove { name, retry } = self;
        let mode = if retry {
            RemoveMode::Retry
        } else {
            RemoveMode::Once
        };
        let dm = dmsetup()?;
        let _root = token.elevate()?;
        dm.device(&name).remove(mode)?;
        Ok(DmOut::Removed)
    }
}

impl Op for Suspend {
    type Output = DmOut;
    type Error = DmError;

    fn run(self, mut token: Unprivileged) -> Result<DmOut, DmError> {
        let Suspend { name } = self;
        let dm = dmsetup()?;
        let _root = token.elevate()?;
        dm.device(&name).suspend()?;
        Ok(DmOut::Suspended)
    }
}

impl Op for Resume {
    type Output = DmOut;
    type Error = DmError;

    fn run(self, mut token: Unprivileged) -> Result<DmOut, DmError> {
        let Resume { name } = self;
        let dm = dmsetup()?;
        let _root = token.elevate()?;
        dm.device(&name).resume()?;
        Ok(DmOut::Resumed)
    }
}

impl Op for Message {
    type Output = DmOut;
    type Error = DmError;

    fn run(self, mut token: Unprivileged) -> Result<DmOut, DmError> {
        let Message { name, message } = self;
        let dm = dmsetup()?;
        let _root = token.elevate()?;
        dm.thin_pool(&name)?.send(message)?;
        Ok(DmOut::Messaged)
    }
}

fn dmsetup() -> Result<dm::Dmsetup, RootSafeBinError> {
    Ok(dm::Dmsetup::new(Config::get().dmsetup()?))
}

fn access(readonly: bool) -> Access {
    if readonly {
        Access::ReadOnly
    } else {
        Access::ReadWrite
    }
}

fn create(
    name: &HyperDmName,
    access: Access,
    table: DmTable,
    token: &mut Unprivileged,
) -> Result<DmOut, DmError> {
    let table = HyperDmTable::new(table)?;
    let dm = dmsetup()?;
    let (device, loops) = {
        let _root = token.elevate()?;
        let sectors = source_sectors(&table)?;
        let control = LoopControl::open()?;
        let mut loops = BTreeMap::new();
        let mut attached = table.attach(|role, backing| {
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
        set_sectors(&mut attached, sectors);
        (dm.create(name, &attached, access)?.path().into(), loops)
    };
    Ok(DmOut::Created {
        device,
        loops: loops
            .iter()
            .map(|(&role, device)| (role, device.path().as_ref().to_path_buf()))
            .collect(),
    })
}

fn source_sectors(table: &HyperDmTable) -> Result<u64, DmError> {
    let origin = match table.table() {
        DmTable::ThinPool(_) => return file_sectors(table, Role::Data),
        DmTable::Linear(LinearTable { origin, .. })
        | DmTable::Snapshot(SnapshotTable { origin, .. })
        | DmTable::Thin(ThinTable {
            origin: Some(origin),
            ..
        }) => origin,
        DmTable::Thin(ThinTable { origin: None, .. }) => return Err(DmError::Unsized),
    };
    match origin {
        Origin::Path(_) => file_sectors(table, Role::Origin),
        Origin::Device(name) => {
            let device = name.open()?.reopen(OpenFlags::RDONLY)?;
            device.sectors().map_err(DmError::Size)
        }
    }
}

fn file_sectors(table: &HyperDmTable, role: Role) -> Result<u64, DmError> {
    let backing = table.backing(role).ok_or(DmError::Unsized)?;
    let stat = fstat(backing.file().as_raw_fd()).map_err(DmError::Size)?;
    Ok(stat.st_size as u64 / SECTOR_BYTES)
}

fn set_sectors(table: &mut DmTable, sectors: u64) {
    match table {
        DmTable::Linear(t) => t.sectors = sectors,
        DmTable::Snapshot(t) => t.sectors = sectors,
        DmTable::ThinPool(t) => t.sectors = sectors,
        DmTable::Thin(t) => t.sectors = sectors,
    }
}
