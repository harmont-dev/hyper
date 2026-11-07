use crate::cli::dm::{self as dm_op, DmError};
use crate::cli::{MapperPath, Op};
use crate::dm::HyperDmName;
use hyperrs_linux::dm::{
    Active, OpenThinError, Origin, RunError, SnapshotError, Thin, ThinId, ThinPool, ThinPoolError,
};
use hyperrs_process::privilege::{PrivilegeError, Unprivileged};
use serde::{Deserialize, Serialize};
use serde_with::serde_as;
use std::path::PathBuf;
use thiserror::Error as ThisError;

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
}

#[derive(Serialize)]
#[serde(tag = "result", rename_all = "snake_case")]
pub enum ThinOut {
    Created { device: PathBuf },
    Destroyed,
}

#[serde_as]
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ThinCreate {
    pool: HyperDmName,
    thin_id: ThinId,
    name: HyperDmName,
    #[serde_as(as = "MapperPath")]
    origin: HyperDmName,
}

#[serde_as]
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ThinSnapshot {
    pool: HyperDmName,
    parent: HyperDmName,
    thin_id: ThinId,
    name: HyperDmName,
    #[serde_as(as = "MapperPath")]
    origin: HyperDmName,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ThinDestroy {
    pool: HyperDmName,
    name: HyperDmName,
}

impl Op for ThinCreate {
    type Output = ThinOut;
    type Error = ThinError;

    fn run(self, mut token: Unprivileged) -> Result<ThinOut, ThinError> {
        let dm = dm_op::dmsetup().map_err(DmError::from)?;
        let _root = token.elevate()?;
        let sectors = dm_op::device_sectors(&self.origin)?;
        let pool = dm.thin_pool(&self.pool)?;
        let thin = pool.create_thin(self.thin_id)?;
        let activated = thin.activate(&self.name, sectors, origin(&self.origin));
        activate_or_delete(&pool, self.thin_id, activated)
    }
}

impl Op for ThinSnapshot {
    type Output = ThinOut;
    type Error = ThinError;

    fn run(self, mut token: Unprivileged) -> Result<ThinOut, ThinError> {
        let dm = dm_op::dmsetup().map_err(DmError::from)?;
        let _root = token.elevate()?;
        let sectors = dm_op::device_sectors(&self.origin)?;
        let pool = dm.thin_pool(&self.pool)?;
        let snapshot = match pool.open_thin(&self.parent)?.snapshot(self.thin_id) {
            Ok(snapshot) => snapshot,
            Err(e @ SnapshotError::Resume(_)) => {
                let _ = pool.delete_thin(self.thin_id);
                return Err(e.into());
            }
            Err(e) => return Err(e.into()),
        };
        let activated = snapshot.activate(&self.name, sectors, origin(&self.origin));
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
