use crate::linux::dm::{
    DmTable, Persistence, SnapshotTable, ThinId, ThinIdOutOfRange, ThinPoolTable, ThinTable,
};
use crate::util::safe_dev::{self, BlockDev, LoopDev};
use std::path::{Path, PathBuf};
use thiserror::Error as ThisError;

#[derive(Debug, ThisError)]
pub enum TableError {
    #[error("unsupported dm table: {0}")]
    Malformed(String),
    #[error(transparent)]
    Device(#[from] safe_dev::Error),
    #[error(transparent)]
    ThinId(#[from] ThinIdOutOfRange),
}

pub fn parse_table(s: &str) -> Result<DmTable, TableError> {
    let malformed = || TableError::Malformed(s.to_string());
    let number = |t: &str| t.parse::<u64>().map_err(|_| malformed());
    let thin_id = |t: &str| -> Result<ThinId, TableError> {
        Ok(ThinId::new(t.parse().map_err(|_| malformed())?)?)
    };

    let block = |t: &str| -> Result<PathBuf, TableError> {
        let dev: BlockDev = t.parse()?;
        Ok(AsRef::<Path>::as_ref(&dev).to_path_buf())
    };
    let looped = |t: &str| -> Result<PathBuf, TableError> {
        let dev: LoopDev = t.parse()?;
        Ok(AsRef::<Path>::as_ref(&dev).to_path_buf())
    };

    let fields: Vec<&str> = s.split_whitespace().collect();
    Ok(match fields.as_slice() {
        ["0", sectors, "snapshot", origin, cow, mode, chunk] => {
            let persistence = match *mode {
                "P" => Persistence::Persistent,
                "N" => Persistence::Transient,
                _ => return Err(malformed()),
            };
            DmTable::Snapshot(SnapshotTable {
                sectors: number(sectors)?,
                origin: block(origin)?,
                cow: looped(cow)?,
                persistence,
                chunk: number(chunk)?,
            })
        }
        ["0", sectors, "thin-pool", meta, data, block_sectors, low] => {
            DmTable::ThinPool(ThinPoolTable {
                sectors: number(sectors)?,
                metadata: looped(meta)?,
                data: looped(data)?,
                block_sectors: number(block_sectors)?,
                low_water: number(low)?,
            })
        }
        ["0", sectors, "thin", pool, id, origin @ ..] if origin.len() <= 1 => {
            DmTable::Thin(ThinTable {
                sectors: number(sectors)?,
                pool: block(pool)?,
                id: thin_id(id)?,
                origin: origin.first().map(|o| block(o)).transpose()?,
            })
        }
        _ => return Err(malformed()),
    })
}
