use super::{Access, Device, DmTable, Dmsetup, RemoveMode, RunError, ThinTable};
use std::fmt;
use std::path::PathBuf;
use thiserror::Error as ThisError;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ThinId(u32);

#[derive(Debug, ThisError)]
#[error("thin device id {0} exceeds the 24-bit limit")]
pub struct ThinIdOutOfRange(u32);

impl ThinId {
    pub const MAX: u32 = (1 << 24) - 1;

    pub fn new(id: u32) -> Result<Self, ThinIdOutOfRange> {
        if id <= Self::MAX {
            Ok(Self(id))
        } else {
            Err(ThinIdOutOfRange(id))
        }
    }
}

impl From<ThinId> for u64 {
    fn from(id: ThinId) -> Self {
        u64::from(id.0)
    }
}

impl fmt::Display for ThinId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.fmt(f)
    }
}

#[derive(Debug, ThisError)]
pub enum ThinPoolError {
    #[error(transparent)]
    Run(#[from] RunError),
    #[error("{name} is not a thin-pool device: {table:?}")]
    NotAThinPool { name: String, table: String },
}

#[derive(Debug, ThisError)]
pub enum SnapshotError {
    #[error("suspending origin: {0}")]
    Suspend(#[source] RunError),
    #[error("sending create_snap: {0}")]
    CreateSnap(#[source] RunError),
    #[error("resuming origin: {0}")]
    Resume(#[source] RunError),
}

#[derive(Debug, Clone)]
pub struct ThinPool<'a> {
    device: Device<'a>,
}

#[derive(Debug, Clone, Copy)]
pub struct Inactive;

#[derive(Debug)]
pub struct Active<'a>(Device<'a>);

#[derive(Debug)]
pub struct Thin<'a, S> {
    pool: ThinPool<'a>,
    id: ThinId,
    state: S,
}

impl<'a> ThinPool<'a> {
    pub(super) fn open(dmsetup: &'a Dmsetup, name: &str) -> Result<Self, ThinPoolError> {
        let table = dmsetup.run(["table", name])?;
        match table.lines().collect::<Vec<_>>().as_slice() {
            [line] if line.split_whitespace().nth(2) == Some("thin-pool") => Ok(Self {
                device: dmsetup.device(name),
            }),
            _ => Err(ThinPoolError::NotAThinPool {
                name: name.to_string(),
                table,
            }),
        }
    }

    pub fn device(&self) -> &Device<'a> {
        &self.device
    }

    pub fn create_thin(&self, id: ThinId) -> Result<Thin<'a, Inactive>, RunError> {
        self.message(&format!("create_thin {id}"))?;
        Ok(Thin {
            pool: self.clone(),
            id,
            state: Inactive,
        })
    }

    pub fn create_snap(&self, id: ThinId, origin: ThinId) -> Result<(), RunError> {
        self.message(&format!("create_snap {id} {origin}"))
    }

    pub fn delete_thin(&self, id: ThinId) -> Result<(), RunError> {
        self.message(&format!("delete {id}"))
    }

    pub fn reserve_metadata_snap(&self) -> Result<(), RunError> {
        self.message("reserve_metadata_snap")
    }

    pub fn release_metadata_snap(&self) -> Result<(), RunError> {
        self.message("release_metadata_snap")
    }

    fn message(&self, message: &str) -> Result<(), RunError> {
        self.device
            .dmsetup
            .run(["message", self.device.name(), "0", message])
            .map(drop)
    }
}

impl<S> Thin<'_, S> {
    pub fn id(&self) -> ThinId {
        self.id
    }
}

impl<'a> Thin<'a, Inactive> {
    pub fn activate(
        self,
        name: &str,
        sectors: u64,
        origin: Option<PathBuf>,
    ) -> Result<Thin<'a, Active<'a>>, RunError> {
        let table = DmTable::Thin(ThinTable {
            sectors,
            pool: self.pool.device.path(),
            id: self.id,
            origin,
        });
        let device = self
            .pool
            .device
            .dmsetup
            .create(name, &table, Access::ReadWrite)?;
        Ok(Thin {
            pool: self.pool,
            id: self.id,
            state: Active(device),
        })
    }

    pub fn delete(self) -> Result<(), RunError> {
        self.pool.delete_thin(self.id)
    }
}

impl<'a> Thin<'a, Active<'a>> {
    pub fn device(&self) -> &Device<'a> {
        &self.state.0
    }

    pub fn snapshot(&self, new_id: ThinId) -> Result<Thin<'a, Inactive>, SnapshotError> {
        let device = self.device();
        device.suspend().map_err(SnapshotError::Suspend)?;
        let snapped = self.pool.create_snap(new_id, self.id);
        device.resume().map_err(SnapshotError::Resume)?;
        snapped.map_err(SnapshotError::CreateSnap)?;
        Ok(Thin {
            pool: self.pool.clone(),
            id: new_id,
            state: Inactive,
        })
    }

    pub fn deactivate(self) -> Result<Thin<'a, Inactive>, RunError> {
        self.state.0.remove(RemoveMode::Retry)?;
        Ok(Thin {
            pool: self.pool,
            id: self.id,
            state: Inactive,
        })
    }
}
