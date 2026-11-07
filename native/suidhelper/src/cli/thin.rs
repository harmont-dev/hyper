use crate::cli::dm::{self as dm_op, Created, DmError};
use crate::cli::{MapperPath, Op};
use crate::dm::{HyperDmName, HyperDmTable};
use hyperrs_fs::file::{self, OpenFlags};
use hyperrs_linux::dm::{
    Active, DevPath, DmTable, OpenThinError, Origin, RemoveMode, Role, RunError, SnapshotError,
    Thin, ThinId, ThinPool, ThinPoolError, ThinPoolTable,
};
use hyperrs_linux::Access;
use hyperrs_process::privilege::{PrivilegeError, Unprivileged};
use serde::{Deserialize, Serialize};
use serde_with::serde_as;
use std::io::Write;
use std::path::PathBuf;
use thiserror::Error as ThisError;

const METADATA_HEADER_BYTES: usize = 4096;

#[derive(Debug, ThisError)]
pub enum ThinError {
    #[error(transparent)]
    Dm(#[from] DmError),
    #[error(transparent)]
    Pool(#[from] ThinPoolError),
    #[error(transparent)]
    Run(#[from] RunError),
    #[error(transparent)]
    Open(#[from] OpenThinError),
    #[error(transparent)]
    Snapshot(#[from] SnapshotError),
    #[error(transparent)]
    Privilege(#[from] PrivilegeError),
    #[error("opening the pool metadata: {0}")]
    Metadata(#[from] file::ValidationError),
    #[error("zeroing the pool metadata header: {0}")]
    Zero(#[source] std::io::Error),
    #[error("the pool table has no metadata device")]
    NoMetadata,
}

#[derive(Serialize)]
#[serde(tag = "result", rename_all = "snake_case")]
pub enum ThinOut {
    Created { device: PathBuf },
    Destroyed,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ThinPoolCreate {
    name: HyperDmName,
    metadata: DevPath,
    data: DevPath,
    block_sectors: u64,
    low_water: u64,
}

#[serde_as]
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ThinVolumeCreate {
    pool: HyperDmName,
    thin_id: ThinId,
    name: HyperDmName,
    #[serde_as(as = "MapperPath")]
    origin: HyperDmName,
    parent: Option<HyperDmName>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ThinDestroy {
    pool: HyperDmName,
    name: HyperDmName,
}

impl Op for ThinPoolCreate {
    type Output = Created;
    type Error = ThinError;

    fn run(self, mut token: Unprivileged) -> Result<Created, ThinError> {
        let table = HyperDmTable::new(DmTable::ThinPool(ThinPoolTable {
            sectors: 0,
            metadata: self.metadata,
            data: self.data,
            block_sectors: self.block_sectors,
            low_water: self.low_water,
        }))
        .map_err(DmError::from)?;
        let dm = dm_op::dmsetup().map_err(DmError::from)?;
        {
            let _root = token.elevate()?;
            let _ = dm.device(&self.name).remove(RemoveMode::Retry);
            let metadata = table.backing(Role::Metadata).ok_or(ThinError::NoMetadata)?;
            metadata
                .file()
                .reopen(OpenFlags::WRONLY)?
                .write_all(&[0; METADATA_HEADER_BYTES])
                .map_err(ThinError::Zero)?;
        }
        Ok(dm_op::create(
            &self.name,
            Access::ReadWrite,
            table,
            &mut token,
        )?)
    }
}

impl Op for ThinVolumeCreate {
    type Output = ThinOut;
    type Error = ThinError;

    fn run(self, mut token: Unprivileged) -> Result<ThinOut, ThinError> {
        let dm = dm_op::dmsetup().map_err(DmError::from)?;
        let _root = token.elevate()?;
        let sectors = dm_op::device_sectors(&self.origin)?;
        let pool = dm.thin_pool(&self.pool)?;
        let thin = match &self.parent {
            None => pool.create_thin(self.thin_id)?,
            Some(parent) => match pool.open_thin(parent)?.snapshot(self.thin_id) {
                Ok(snapshot) => snapshot,
                Err(e @ SnapshotError::Resume(_)) => {
                    let _ = pool.delete_thin(self.thin_id);
                    return Err(e.into());
                }
                Err(e) => return Err(e.into()),
            },
        };
        let activated = thin.activate(&self.name, sectors, origin(&self.origin));
        activate_or_delete(&pool, self.thin_id, activated)
    }
}

impl Op for ThinDestroy {
    type Output = ThinOut;
    type Error = ThinError;

    fn run(self, mut token: Unprivileged) -> Result<ThinOut, ThinError> {
        let dm = dm_op::dmsetup().map_err(DmError::from)?;
        let _root = token.elevate()?;
        dm.thin_pool(&self.pool)?
            .open_thin(&self.name)?
            .deactivate()?
            .delete()?;
        Ok(ThinOut::Destroyed)
    }
}

fn origin(device: &HyperDmName) -> Option<Origin> {
    Some(Origin::Device((**device).clone()))
}

fn activate_or_delete(
    pool: &ThinPool<'_>,
    id: ThinId,
    activated: Result<Thin<'_, Active<'_>>, RunError>,
) -> Result<ThinOut, ThinError> {
    match activated {
        Ok(thin) => Ok(ThinOut::Created {
            device: thin.device().path().as_path().to_path_buf(),
        }),
        Err(e) => {
            let _ = pool.delete_thin(id);
            Err(e.into())
        }
    }
}
