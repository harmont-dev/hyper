use super::backing::{BackingError, BackingFile};
use super::name::{parse_dm_name, NameError};
use crate::config::Config;
use crate::fs::path::{self, IsAbsolute, SafePath, SafePathBuf, StrictComponents};
use crate::linux::dm::{
    DmName, DmTable, LinearTable, ParseThinIdError, Persistence, SnapshotTable, ThinId,
    ThinPoolTable, ThinTable,
};
use crate::linux::loopdev::LoopDevice;
use crate::util::safe_dev::{self, BlockDev};
use serde::Serialize;
use std::fmt;
use std::path::PathBuf;
use thiserror::Error as ThisError;

pub type FilePath = SafePathBuf<IsAbsolute, StrictComponents>;

#[derive(Debug, ThisError)]
pub enum TableError {
    #[error("unsupported dm table: {0}")]
    Malformed(String),
    #[error(transparent)]
    Device(#[from] safe_dev::Error),
    #[error(transparent)]
    Name(#[from] NameError),
    #[error("expected a backing file, got a device: {0}")]
    NotAFile(String),
    #[error("backing file path {0:?}: {1}")]
    FilePath(String, #[source] path::ValidationError),
    #[error(transparent)]
    Backing(#[from] BackingError),
    #[error(transparent)]
    ThinId(#[from] ParseThinIdError),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Slot {
    Origin,
    Cow,
    Metadata,
    Data,
}

#[derive(Debug, Clone)]
pub enum Source<F> {
    Device(BlockDev),
    File(F),
}

#[derive(Debug, Clone)]
pub enum TableSpec<F> {
    Linear {
        sectors: u64,
        origin: Source<F>,
    },
    Snapshot {
        sectors: u64,
        origin: Source<F>,
        cow: F,
        persistence: Persistence,
        chunk: u64,
    },
    ThinPool {
        sectors: u64,
        metadata: F,
        data: F,
        block_sectors: u64,
        low_water: u64,
    },
    Thin {
        sectors: u64,
        pool: DmName,
        id: ThinId,
        origin: Option<Source<F>>,
    },
}

impl<F> Source<F> {
    fn try_map<G, E>(
        &self,
        slot: Slot,
        f: &mut impl FnMut(&F, Slot) -> Result<G, E>,
    ) -> Result<Source<G>, E> {
        Ok(match self {
            Source::Device(dev) => Source::Device(dev.clone()),
            Source::File(file) => Source::File(f(file, slot)?),
        })
    }
}

impl<F> TableSpec<F> {
    pub fn try_map<G, E>(
        &self,
        mut f: impl FnMut(&F, Slot) -> Result<G, E>,
    ) -> Result<TableSpec<G>, E> {
        Ok(match self {
            TableSpec::Linear { sectors, origin } => TableSpec::Linear {
                sectors: *sectors,
                origin: origin.try_map(Slot::Origin, &mut f)?,
            },
            TableSpec::Snapshot {
                sectors,
                origin,
                cow,
                persistence,
                chunk,
            } => TableSpec::Snapshot {
                sectors: *sectors,
                origin: origin.try_map(Slot::Origin, &mut f)?,
                cow: f(cow, Slot::Cow)?,
                persistence: *persistence,
                chunk: *chunk,
            },
            TableSpec::ThinPool {
                sectors,
                metadata,
                data,
                block_sectors,
                low_water,
            } => TableSpec::ThinPool {
                sectors: *sectors,
                metadata: f(metadata, Slot::Metadata)?,
                data: f(data, Slot::Data)?,
                block_sectors: *block_sectors,
                low_water: *low_water,
            },
            TableSpec::Thin {
                sectors,
                pool,
                id,
                origin,
            } => TableSpec::Thin {
                sectors: *sectors,
                pool: pool.clone(),
                id: *id,
                origin: origin
                    .as_ref()
                    .map(|origin| origin.try_map(Slot::Origin, &mut f))
                    .transpose()?,
            },
        })
    }
}

pub trait SlotPath {
    fn slot_path(&self) -> &SafePath<IsAbsolute, StrictComponents>;
}

impl SlotPath for FilePath {
    fn slot_path(&self) -> &SafePath<IsAbsolute, StrictComponents> {
        self
    }
}

impl SlotPath for LoopDevice {
    fn slot_path(&self) -> &SafePath<IsAbsolute, StrictComponents> {
        self.path()
    }
}

impl<F: SlotPath> Source<F> {
    fn path(&self) -> FilePath {
        match self {
            Source::Device(dev) => dev.path().to_owned(),
            Source::File(file) => file.slot_path().to_owned(),
        }
    }
}

impl<F: SlotPath> TableSpec<F> {
    pub fn to_dm(&self) -> DmTable {
        match self {
            TableSpec::Linear { sectors, origin } => DmTable::Linear(LinearTable {
                sectors: *sectors,
                origin: origin.path(),
            }),
            TableSpec::Snapshot {
                sectors,
                origin,
                cow,
                persistence,
                chunk,
            } => DmTable::Snapshot(SnapshotTable {
                sectors: *sectors,
                origin: origin.path(),
                cow: cow.slot_path().to_owned(),
                persistence: *persistence,
                chunk: *chunk,
            }),
            TableSpec::ThinPool {
                sectors,
                metadata,
                data,
                block_sectors,
                low_water,
            } => DmTable::ThinPool(ThinPoolTable {
                sectors: *sectors,
                metadata: metadata.slot_path().to_owned(),
                data: data.slot_path().to_owned(),
                block_sectors: *block_sectors,
                low_water: *low_water,
            }),
            TableSpec::Thin {
                sectors,
                pool,
                id,
                origin,
            } => DmTable::Thin(ThinTable {
                sectors: *sectors,
                pool: pool.clone(),
                id: *id,
                origin: origin.as_ref().map(Source::path),
            }),
        }
    }
}

impl<F: SlotPath> fmt::Display for TableSpec<F> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.to_dm().fmt(f)
    }
}

pub fn parse_table(s: &str) -> Result<TableSpec<FilePath>, TableError> {
    let malformed = || TableError::Malformed(s.to_string());
    let number = |t: &str| t.parse::<u64>().map_err(|_| malformed());
    let is_device = |t: &str| t.starts_with("/dev/");
    let file = |t: &str| -> Result<FilePath, TableError> {
        if is_device(t) {
            return Err(TableError::NotAFile(t.to_string()));
        }
        PathBuf::from(t)
            .try_into()
            .map_err(|e| TableError::FilePath(t.to_string(), e))
    };
    let dm_device = |t: &str| -> Result<DmName, TableError> {
        let name = t.strip_prefix("/dev/mapper/").ok_or_else(malformed)?;
        Ok(parse_dm_name(name)?)
    };
    let source = |t: &str| -> Result<Source<FilePath>, TableError> {
        if is_device(t) {
            Ok(Source::Device(t.parse()?))
        } else {
            Ok(Source::File(file(t)?))
        }
    };

    let fields: Vec<&str> = s.split_whitespace().collect();
    Ok(match fields.as_slice() {
        ["0", sectors, "linear", origin, "0"] => TableSpec::Linear {
            sectors: number(sectors)?,
            origin: source(origin)?,
        },
        ["0", sectors, "snapshot", origin, cow, mode, chunk] => {
            let persistence = match *mode {
                "P" => Persistence::Persistent,
                "N" => Persistence::Transient,
                _ => return Err(malformed()),
            };
            TableSpec::Snapshot {
                sectors: number(sectors)?,
                origin: source(origin)?,
                cow: file(cow)?,
                persistence,
                chunk: number(chunk)?,
            }
        }
        ["0", sectors, "thin-pool", meta, data, block_sectors, low] => TableSpec::ThinPool {
            sectors: number(sectors)?,
            metadata: file(meta)?,
            data: file(data)?,
            block_sectors: number(block_sectors)?,
            low_water: number(low)?,
        },
        ["0", sectors, "thin", pool, id, origin @ ..] if origin.len() <= 1 => TableSpec::Thin {
            sectors: number(sectors)?,
            pool: dm_device(pool)?,
            id: id.parse()?,
            origin: origin.first().map(|o| source(o)).transpose()?,
        },
        _ => return Err(malformed()),
    })
}

pub fn resolve_table(s: &str) -> Result<TableSpec<BackingFile>, TableError> {
    let base = Config::get().hyper_base();
    Ok(parse_table(s)?.try_map(|path, _| BackingFile::open(path.slot_path().as_path(), base))?)
}
