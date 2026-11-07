use crate::cli::dm::{self as dm_op, Created, DmError};
use crate::cli::Op;
use crate::dm::{HyperDmName, HyperDmTable, NameError};
use hyperrs_linux::dm::{DevPath, DmTable, LinearTable, Origin, RemoveMode, Role};
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
            Some((_, base)) => dm_op::file_sectors(base, Role::Origin)?,
            None => return Err(DmError::Unsized.into()),
        };
        let mut created: Vec<HyperDmName> = Vec::new();
        let mut device = PathBuf::new();
        for (name, table) in layers {
            match dm_op::create_sized(&name, Access::ReadOnly, table, sectors, &mut token) {
                Ok(Created { device: path, .. }) => {
                    device = path;
                    created.push(name);
                }
                Err(e) => {
                    remove_all(&created, &mut token);
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
            let table = dm_op::snapshot_table(origin, cow.clone(), self.chunk_sectors);
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

fn remove_all(names: &[HyperDmName], token: &mut Unprivileged) {
    let Ok(dm) = dm_op::dmsetup() else { return };
    let Ok(_root) = token.elevate() else { return };
    for name in names.iter().rev() {
        let _ = dm.device(name).remove(RemoveMode::Retry);
    }
}
