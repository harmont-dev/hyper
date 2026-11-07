use crate::cli::Op;
use crate::config::Config;
use crate::dm::{HyperDmName, HyperDmTable, TableError};
use hyperrs_fs::file::{self, OpenFlags};
use hyperrs_linux::dm::{
    self, DevPath, DmName, DmTable, LinearTable, Origin, Persistence, RemoveMode, Role,
    SnapshotTable, ThinTable,
};
use hyperrs_linux::loopdev::{self, LoopControl};
use hyperrs_linux::Access;
use hyperrs_process::binary::RootSafeBinError;
use hyperrs_process::privilege::{PrivilegeError, Unprivileged};
use nix::sys::stat::fstat;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::os::fd::AsRawFd;
use std::path::PathBuf;
use std::time::Duration;
use thiserror::Error as ThisError;

const ATTACH_TIMEOUT: Duration = Duration::from_secs(1);
const SECTOR_BYTES: u64 = 512;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Remove {
    name: HyperDmName,
    retry: bool,
}

#[derive(Serialize)]
#[serde(tag = "result", rename_all = "snake_case")]
pub enum DmOut {
    Removed,
}

#[derive(Serialize)]
#[serde(tag = "result", rename = "created")]
pub struct Created {
    pub device: PathBuf,
    pub loops: BTreeMap<Role, PathBuf>,
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

pub(super) fn dmsetup() -> Result<dm::Dmsetup, RootSafeBinError> {
    Ok(dm::Dmsetup::new(Config::get().dmsetup()?))
}

pub(super) fn create(
    name: &HyperDmName,
    access: Access,
    table: HyperDmTable,
    token: &mut Unprivileged,
) -> Result<Created, DmError> {
    let sectors = {
        let _root = token.elevate()?;
        source_sectors(&table)?
    };
    create_sized(name, access, table, sectors, token)
}

pub(super) fn create_sized(
    name: &HyperDmName,
    access: Access,
    table: HyperDmTable,
    sectors: u64,
    token: &mut Unprivileged,
) -> Result<Created, DmError> {
    let dm = dmsetup()?;
    let (device, loops) = {
        let _root = token.elevate()?;
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
    Ok(Created {
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
        Origin::Device(name) => device_sectors(name),
    }
}

pub(super) fn device_sectors(name: &DmName) -> Result<u64, DmError> {
    let device = name.open()?.reopen(OpenFlags::RDONLY)?;
    device.sectors().map_err(DmError::Size)
}

pub(super) fn snapshot_table(origin: Origin, cow: DevPath, chunk_sectors: u64) -> DmTable {
    DmTable::Snapshot(SnapshotTable {
        sectors: 0,
        origin,
        cow,
        persistence: Persistence::Persistent,
        chunk: chunk_sectors,
    })
}

pub(super) fn file_sectors(table: &HyperDmTable, role: Role) -> Result<u64, DmError> {
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
