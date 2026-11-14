use crate::cli::dm::{Created, DmError};
use crate::cli::Op;
use crate::config::Config;
use crate::dm::{HyperDmName, HyperDmTable, NameError};
use hyperrs_linux::dm::{
    self, DevPath, DmTable, LinearTable, Origin, Persistence, RemoveMode, Role, SnapshotTable,
};
use hyperrs_linux::Access;
use hyperrs_process::privilege::Unprivileged;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use thiserror::Error as ThisError;

#[derive(Debug, ThisError)]
pub enum ImgError {
    #[error(transparent)]
    Dm(#[from] DmError),
    #[error(transparent)]
    Name(#[from] NameError),
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ImgActivate {
    name: HyperDmName,
    base: DevPath,
    deltas: Vec<DevPath>,
    chunk_sectors: u64,
}

#[derive(Serialize)]
#[serde(tag = "result", rename_all = "snake_case")]
pub enum ImgOut {
    Activated { device: PathBuf, names: Vec<String> },
}

impl Op for ImgActivate {
    type Output = ImgOut;
    type Error = ImgError;

    fn run(self, mut token: Unprivileged) -> Result<ImgOut, ImgError> {
        let layers = self.layers()?;
        let sectors = match layers.first() {
            Some((_, base)) => base.backing_sectors(Role::Origin)?,
            None => return Err(DmError::Unsized.into()),
        };
        let dm = dm::Dmsetup::new(Config::get().dmsetup().map_err(DmError::from)?);
        let mut created: Vec<HyperDmName> = Vec::new();
        let mut device = PathBuf::new();
        for (name, table) in layers {
            match table.create_sized(&name, Access::ReadOnly, sectors, &mut token) {
                Ok(Created { device: path, .. }) => {
                    device = path;
                    created.push(name);
                }
                Err(e) => {
                    let root = token.elevate().map_err(DmError::from)?;
                    for name in created.iter().rev() {
                        let _ = dm.device(&root, name).remove(RemoveMode::Retry);
                    }
                    return Err(e.into());
                }
            }
        }
        Ok(ImgOut::Activated {
            device,
            names: created.iter().map(ToString::to_string).collect(),
        })
    }
}

impl ImgActivate {
    fn layers(&self) -> Result<Vec<(HyperDmName, HyperDmTable)>, ImgError> {
        if self.deltas.is_empty() {
            let table = DmTable::Linear(LinearTable {
                sectors: 0,
                origin: Origin::Path(self.base.clone()),
            });
            return Ok(vec![(
                self.layer(0)?,
                HyperDmTable::new(table).map_err(DmError::from)?,
            )]);
        }
        let mut origin = Origin::Path(self.base.clone());
        let mut layers = Vec::with_capacity(self.deltas.len());
        for (idx, cow) in self.deltas.iter().enumerate() {
            let name = self.layer(idx + 1)?;
            let table = DmTable::Snapshot(SnapshotTable {
                sectors: 0,
                origin,
                cow: cow.clone(),
                persistence: Persistence::Persistent,
                chunk: self.chunk_sectors,
            });
            layers.push((
                name.clone(),
                HyperDmTable::new(table).map_err(DmError::from)?,
            ));
            origin = Origin::Device((*name).clone());
        }
        Ok(layers)
    }

    fn layer(&self, idx: usize) -> Result<HyperDmName, NameError> {
        format!("{}-{idx}", self.name).parse()
    }
}
