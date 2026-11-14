use crate::cli::Op;
use crate::config::Config;
use crate::dm::{HyperDmName, HyperDmTable, TableError};
use hyperrs_linux::dm::{
    self, DmTable, LinearTable, Origin, RemoveMode, Role, SnapshotTable, ThinTable,
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
    Size(#[from] dm::SizeError),
    #[error("reading the backing file size: {0}")]
    FileSize(#[source] nix::Error),
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
        let dm = dm::Dmsetup::new(Config::get().dmsetup()?);
        let root = token.elevate()?;
        dm.device(&root, &name).remove(mode)?;
        Ok(DmOut::Removed)
    }
}

impl HyperDmTable {
    pub(super) fn create(
        self,
        name: &HyperDmName,
        access: Access,
        token: &mut Unprivileged,
    ) -> Result<Created, DmError> {
        let sectors = {
            let _root = token.elevate()?;
            self.sectors()?
        };
        self.create_sized(name, access, sectors, token)
    }

    pub(super) fn create_sized(
        self,
        name: &HyperDmName,
        access: Access,
        sectors: u64,
        token: &mut Unprivileged,
    ) -> Result<Created, DmError> {
        let dm = dm::Dmsetup::new(Config::get().dmsetup()?);
        let (device, loops) = {
            let root = token.elevate()?;
            let control = LoopControl::open()?;
            let mut loops = BTreeMap::new();
            let mut attached = self.attach(|role, backing| {
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
            match &mut attached {
                DmTable::Linear(t) => t.sectors = sectors,
                DmTable::Snapshot(t) => t.sectors = sectors,
                DmTable::ThinPool(t) => t.sectors = sectors,
                DmTable::Thin(t) => t.sectors = sectors,
            }
            (
                dm.create(&root, name, &attached, access)?.path().into(),
                loops,
            )
        };
        Ok(Created {
            device,
            loops: loops
                .iter()
                .map(|(&role, device)| (role, device.path().as_ref().to_path_buf()))
                .collect(),
        })
    }

    fn sectors(&self) -> Result<u64, DmError> {
        let origin = match self.table() {
            DmTable::ThinPool(_) => return self.backing_sectors(Role::Data),
            DmTable::Linear(LinearTable { origin, .. })
            | DmTable::Snapshot(SnapshotTable { origin, .. })
            | DmTable::Thin(ThinTable {
                origin: Some(origin),
                ..
            }) => origin,
            DmTable::Thin(ThinTable { origin: None, .. }) => return Err(DmError::Unsized),
        };
        match origin {
            Origin::Path(_) => self.backing_sectors(Role::Origin),
            Origin::Device(name) => Ok(name.sectors()?),
        }
    }

    pub(super) fn backing_sectors(&self, role: Role) -> Result<u64, DmError> {
        let backing = self.backing(role).ok_or(DmError::Unsized)?;
        let stat = fstat(backing.file().as_raw_fd()).map_err(DmError::FileSize)?;
        Ok(stat.st_size as u64 / SECTOR_BYTES)
    }
}
