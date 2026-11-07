use crate::cli::OpError;
use crate::cli::ThinIdNumber;
use crate::config::Config;
use crate::dm::{HyperDmName, HyperDmTable, TableError};
use hyperrs_linux::dm::{
    self, DevPath, DmTable, LinearTable, Origin, Persistence, RemoveMode, Role, SnapshotTable,
    ThinId, ThinMessage, ThinPoolTable, ThinTable,
};
use hyperrs_linux::loopdev::{self, LoopControl};
use hyperrs_linux::Access;
use hyperrs_process::binary::RootSafeBinError;
use hyperrs_process::privilege::{PrivilegeError, Unprivileged};
use serde::{Deserialize, Serialize};
use serde_with::{serde_as, DisplayFromStr};
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::time::Duration;
use thiserror::Error as ThisError;

const ATTACH_TIMEOUT: Duration = Duration::from_secs(1);

#[serde_as]
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Linear {
    #[serde_as(as = "DisplayFromStr")]
    name: HyperDmName,
    readonly: bool,
    sectors: u64,
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
    sectors: u64,
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
    sectors: u64,
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
    sectors: u64,
    #[serde_as(as = "DisplayFromStr")]
    pool: HyperDmName,
    #[serde_as(as = "ThinIdNumber")]
    thin_id: ThinId,
    #[serde_as(as = "Option<DisplayFromStr>")]
    #[serde(default)]
    origin: Option<Origin>,
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
pub struct Device {
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
}

pub fn linear(
    Linear {
        name,
        readonly,
        sectors,
        origin,
    }: Linear,
    token: &mut Unprivileged,
) -> Result<DmOut, DmError> {
    let table = DmTable::Linear(LinearTable { sectors, origin });
    create(&name, access(readonly), table, token)
}

pub fn snapshot(
    Snapshot {
        name,
        readonly,
        sectors,
        origin,
        cow,
        chunk_sectors,
    }: Snapshot,
    token: &mut Unprivileged,
) -> Result<DmOut, DmError> {
    let table = DmTable::Snapshot(SnapshotTable {
        sectors,
        origin,
        cow,
        persistence: Persistence::Persistent,
        chunk: chunk_sectors,
    });
    create(&name, access(readonly), table, token)
}

pub fn thin_pool(
    ThinPool {
        name,
        sectors,
        metadata,
        data,
        block_sectors,
        low_water,
    }: ThinPool,
    token: &mut Unprivileged,
) -> Result<DmOut, DmError> {
    let table = DmTable::ThinPool(ThinPoolTable {
        sectors,
        metadata,
        data,
        block_sectors,
        low_water,
    });
    create(&name, Access::ReadWrite, table, token)
}

pub fn thin(
    Thin {
        name,
        sectors,
        pool,
        thin_id,
        origin,
    }: Thin,
    token: &mut Unprivileged,
) -> Result<DmOut, DmError> {
    let table = DmTable::Thin(ThinTable {
        sectors,
        pool: (*pool).clone(),
        id: thin_id,
        origin,
    });
    create(&name, Access::ReadWrite, table, token)
}

pub fn remove(Remove { name, retry }: Remove, token: &mut Unprivileged) -> Result<DmOut, DmError> {
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

pub fn suspend(Device { name }: Device, token: &mut Unprivileged) -> Result<DmOut, DmError> {
    let dm = dmsetup()?;
    let _root = token.elevate()?;
    dm.device(&name).suspend()?;
    Ok(DmOut::Suspended)
}

pub fn resume(Device { name }: Device, token: &mut Unprivileged) -> Result<DmOut, DmError> {
    let dm = dmsetup()?;
    let _root = token.elevate()?;
    dm.device(&name).resume()?;
    Ok(DmOut::Resumed)
}

pub fn message(
    Message { name, message }: Message,
    token: &mut Unprivileged,
) -> Result<DmOut, DmError> {
    let dm = dmsetup()?;
    let _root = token.elevate()?;
    dm.thin_pool(&name)?.send(message)?;
    Ok(DmOut::Messaged)
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

impl OpError for DmError {}
