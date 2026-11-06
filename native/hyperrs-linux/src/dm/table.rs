use super::name::MAPPER_PREFIX;
use super::{DmName, ParseDmDeviceError, ParseThinIdError, ThinId};
use crate::loopdev::LoopDevice;
use hyperrs_fs::path::{self, IsAbsolute, SafePath, SafePathBuf, StrictComponents};
use std::fmt;
use std::path::PathBuf;
use std::str::FromStr;
use thiserror::Error as ThisError;

/// Dmsetup tables. See `man dmsetup` for more info, under the `--table` docs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DmTable<F> {
    Linear(LinearTable<F>),
    Snapshot(SnapshotTable<F>),
    ThinPool(ThinPoolTable<F>),
    Thin(ThinTable<F>),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, serde::Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Slot {
    Origin,
    Cow,
    Metadata,
    Data,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Source<F> {
    Device(DmName),
    File(F),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, derive_more::Display)]
pub enum Persistence {
    #[display("P")]
    Persistent,
    #[display("N")]
    Transient,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LinearTable<F> {
    pub sectors: u64,
    pub origin: Source<F>,
}

/// `dm-snapshot` table.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SnapshotTable<F> {
    pub sectors: u64,
    pub origin: Source<F>,
    pub cow: F,
    pub persistence: Persistence,
    pub chunk: u64,
}

/// `dm-thin` pool table.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ThinPoolTable<F> {
    pub sectors: u64,
    pub metadata: F,
    pub data: F,
    pub block_sectors: u64,
    pub low_water: u64,
}

/// `dm-thin` tables.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ThinTable<F> {
    pub sectors: u64,
    pub pool: DmName,
    pub id: ThinId,
    pub origin: Option<Source<F>>,
}

#[derive(Debug, ThisError)]
pub enum ParseTableError {
    #[error("unsupported dm table: {0}")]
    Malformed(String),
    #[error(transparent)]
    Device(#[from] ParseDmDeviceError),
    #[error("backing file path {0:?}: {1}")]
    Path(String, #[source] path::ValidationError),
    #[error(transparent)]
    ThinId(#[from] ParseThinIdError),
}

pub trait SlotPath {
    fn slot_path(&self) -> &SafePath<IsAbsolute, StrictComponents>;
}

impl SlotPath for SafePathBuf<IsAbsolute, StrictComponents> {
    fn slot_path(&self) -> &SafePath<IsAbsolute, StrictComponents> {
        self
    }
}

impl SlotPath for LoopDevice {
    fn slot_path(&self) -> &SafePath<IsAbsolute, StrictComponents> {
        self.path()
    }
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

    fn device(&self) -> Option<&DmName> {
        match self {
            Source::Device(dev) => Some(dev),
            Source::File(_) => None,
        }
    }
}

impl<F> DmTable<F> {
    pub fn try_map<G, E>(
        &self,
        mut f: impl FnMut(&F, Slot) -> Result<G, E>,
    ) -> Result<DmTable<G>, E> {
        Ok(match self {
            DmTable::Linear(LinearTable { sectors, origin }) => DmTable::Linear(LinearTable {
                sectors: *sectors,
                origin: origin.try_map(Slot::Origin, &mut f)?,
            }),
            DmTable::Snapshot(SnapshotTable {
                sectors,
                origin,
                cow,
                persistence,
                chunk,
            }) => DmTable::Snapshot(SnapshotTable {
                sectors: *sectors,
                origin: origin.try_map(Slot::Origin, &mut f)?,
                cow: f(cow, Slot::Cow)?,
                persistence: *persistence,
                chunk: *chunk,
            }),
            DmTable::ThinPool(ThinPoolTable {
                sectors,
                metadata,
                data,
                block_sectors,
                low_water,
            }) => DmTable::ThinPool(ThinPoolTable {
                sectors: *sectors,
                metadata: f(metadata, Slot::Metadata)?,
                data: f(data, Slot::Data)?,
                block_sectors: *block_sectors,
                low_water: *low_water,
            }),
            DmTable::Thin(ThinTable {
                sectors,
                pool,
                id,
                origin,
            }) => DmTable::Thin(ThinTable {
                sectors: *sectors,
                pool: pool.clone(),
                id: *id,
                origin: origin
                    .as_ref()
                    .map(|origin| origin.try_map(Slot::Origin, &mut f))
                    .transpose()?,
            }),
        })
    }

    pub fn devices(&self) -> impl Iterator<Item = &DmName> {
        let (first, second) = match self {
            DmTable::Linear(LinearTable { origin, .. })
            | DmTable::Snapshot(SnapshotTable { origin, .. }) => (origin.device(), None),
            DmTable::ThinPool(_) => (None, None),
            DmTable::Thin(ThinTable { pool, origin, .. }) => {
                (Some(pool), origin.as_ref().and_then(Source::device))
            }
        };
        first.into_iter().chain(second)
    }
}

impl<F: SlotPath> fmt::Display for Source<F> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Source::Device(dev) => write!(f, "{}", dev.path().as_path().display()),
            Source::File(file) => write!(f, "{}", file.slot_path().as_path().display()),
        }
    }
}

impl<F: SlotPath> fmt::Display for DmTable<F> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fn path<F: SlotPath>(p: &F) -> std::path::Display<'_> {
            p.slot_path().as_path().display()
        }
        match self {
            DmTable::Linear(LinearTable { sectors, origin }) => {
                write!(f, "0 {sectors} linear {origin} 0")
            }
            DmTable::Snapshot(SnapshotTable {
                sectors,
                origin,
                cow,
                persistence,
                chunk,
            }) => write!(
                f,
                "0 {sectors} snapshot {origin} {} {persistence} {chunk}",
                path(cow)
            ),
            DmTable::ThinPool(ThinPoolTable {
                sectors,
                metadata,
                data,
                block_sectors,
                low_water,
            }) => write!(
                f,
                "0 {sectors} thin-pool {} {} {block_sectors} {low_water}",
                path(metadata),
                path(data)
            ),
            DmTable::Thin(ThinTable {
                sectors,
                pool,
                id,
                origin,
            }) => {
                write!(
                    f,
                    "0 {sectors} thin {} {id}",
                    pool.path().as_path().display()
                )?;
                match origin {
                    Some(origin) => write!(f, " {origin}"),
                    None => Ok(()),
                }
            }
        }
    }
}

type FilePath = SafePathBuf<IsAbsolute, StrictComponents>;

impl FromStr for DmTable<FilePath> {
    type Err = ParseTableError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let malformed = || ParseTableError::Malformed(s.to_string());
        let number = |t: &str| t.parse::<u64>().map_err(|_| malformed());
        let file = |t: &str| -> Result<FilePath, ParseTableError> {
            PathBuf::from(t)
                .try_into()
                .map_err(|e| ParseTableError::Path(t.to_string(), e))
        };
        let source = |t: &str| -> Result<Source<FilePath>, ParseTableError> {
            if t.starts_with(MAPPER_PREFIX) {
                Ok(Source::Device(DmName::from_device_path(t)?))
            } else {
                Ok(Source::File(file(t)?))
            }
        };

        let fields: Vec<&str> = s.split_whitespace().collect();
        Ok(match fields.as_slice() {
            ["0", sectors, "linear", origin, "0"] => DmTable::Linear(LinearTable {
                sectors: number(sectors)?,
                origin: source(origin)?,
            }),
            ["0", sectors, "snapshot", origin, cow, mode, chunk] => {
                let persistence = match *mode {
                    "P" => Persistence::Persistent,
                    "N" => Persistence::Transient,
                    _ => return Err(malformed()),
                };
                DmTable::Snapshot(SnapshotTable {
                    sectors: number(sectors)?,
                    origin: source(origin)?,
                    cow: file(cow)?,
                    persistence,
                    chunk: number(chunk)?,
                })
            }
            ["0", sectors, "thin-pool", meta, data, block_sectors, low] => {
                DmTable::ThinPool(ThinPoolTable {
                    sectors: number(sectors)?,
                    metadata: file(meta)?,
                    data: file(data)?,
                    block_sectors: number(block_sectors)?,
                    low_water: number(low)?,
                })
            }
            ["0", sectors, "thin", pool, id, origin @ ..] if origin.len() <= 1 => {
                DmTable::Thin(ThinTable {
                    sectors: number(sectors)?,
                    pool: DmName::from_device_path(pool)?,
                    id: id.parse()?,
                    origin: origin.first().map(|o| source(o)).transpose()?,
                })
            }
            _ => return Err(malformed()),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::{
        DmTable, FilePath, LinearTable, ParseTableError, Persistence, SnapshotTable, Source,
        ThinPoolTable, ThinTable,
    };
    use crate::dm::{DmName, ThinId};
    use proptest::prelude::*;
    use std::path::PathBuf;

    fn file() -> impl Strategy<Value = FilePath> {
        (
            "[a-z]{1,8}",
            prop::collection::vec("[A-Za-z0-9._-]{1,8}", 0..4),
        )
            .prop_filter_map("not a strict path, or under /dev", |(first, rest)| {
                (first != "dev")
                    .then(|| format!("/{first}/{}", rest.join("/")))
                    .and_then(|s| PathBuf::from(s.trim_end_matches('/')).try_into().ok())
            })
    }

    fn dm_name() -> impl Strategy<Value = DmName> {
        "[a-z][a-z0-9_-]{0,15}".prop_filter_map("reserved", |s| s.parse().ok())
    }

    fn source() -> impl Strategy<Value = Source<FilePath>> {
        prop_oneof![
            dm_name().prop_map(Source::Device),
            file().prop_map(Source::File)
        ]
    }

    fn thin_id() -> impl Strategy<Value = ThinId> {
        (0..=ThinId::MAX).prop_map(|n| ThinId::new(n).unwrap())
    }

    fn persistence() -> impl Strategy<Value = Persistence> {
        prop_oneof![Just(Persistence::Persistent), Just(Persistence::Transient)]
    }

    fn table() -> impl Strategy<Value = DmTable<FilePath>> {
        prop_oneof![
            (any::<u64>(), source())
                .prop_map(|(sectors, origin)| DmTable::Linear(LinearTable { sectors, origin })),
            (any::<u64>(), source(), file(), persistence(), any::<u64>()).prop_map(
                |(sectors, origin, cow, persistence, chunk)| DmTable::Snapshot(SnapshotTable {
                    sectors,
                    origin,
                    cow,
                    persistence,
                    chunk,
                })
            ),
            (any::<u64>(), file(), file(), any::<u64>(), any::<u64>()).prop_map(
                |(sectors, metadata, data, block_sectors, low_water)| {
                    DmTable::ThinPool(ThinPoolTable {
                        sectors,
                        metadata,
                        data,
                        block_sectors,
                        low_water,
                    })
                }
            ),
            (
                any::<u64>(),
                dm_name(),
                thin_id(),
                prop::option::of(source())
            )
                .prop_map(|(sectors, pool, id, origin)| DmTable::Thin(ThinTable {
                    sectors,
                    pool,
                    id,
                    origin,
                })),
        ]
    }

    fn plain(t: &DmTable<FilePath>) -> DmTable<PathBuf> {
        t.try_map(|f, _| Ok::<_, ()>(f.as_path().to_path_buf()))
            .unwrap()
    }

    proptest! {
        #[test]
        fn parse_is_the_inverse_of_render(t in table()) {
            let back: DmTable<FilePath> = t.to_string().parse().unwrap();
            prop_assert_eq!(plain(&back), plain(&t));
        }

        #[test]
        fn render_is_canonical_regardless_of_input_spacing(t in table(), pad in "[ \t]{1,3}") {
            let spaced = t.to_string().split(' ').collect::<Vec<_>>().join(&pad);
            let back: DmTable<FilePath> = format!("{pad}{spaced}{pad}").parse().unwrap();
            prop_assert_eq!(back.to_string(), t.to_string());
        }

        #[test]
        fn devices_are_exactly_the_mapper_operands(t in table()) {
            let rendered = t.to_string();
            let mapper: Vec<&str> = rendered
                .split(' ')
                .filter(|tok| tok.starts_with("/dev/mapper/"))
                .collect();
            let devices: Vec<String> = t.devices().map(|d| d.path().as_path().display().to_string()).collect();
            prop_assert_eq!(devices, mapper);
        }
    }

    #[test]
    fn rejects_tables_outside_the_grammar() {
        for bad in [
            "0 100 crypt /dev/loop0 /srv/hyper/a",
            "0 100 linear /srv/hyper/a 8",
            "0 100 snapshot /srv/hyper/o srv/hyper/a P 8",
            "0 100 snapshot /srv/hyper/o /srv/hyper/../a P 8",
            "0 100 snapshot /srv/hyper/o /srv/hyper/a X 8",
            "1 100 snapshot /srv/hyper/o /srv/hyper/a P 8",
            "0 100 snapshot /srv/hyper/o /srv/hyper/a P",
            "0 x linear /srv/hyper/a 0",
            "0 100 thin /srv/hyper/pool 0",
            "0 100 thin /dev/loop0 0",
            "0 100 thin /dev/mapper/pool 16777216",
            "0 100 thin /dev/mapper/pool 0 /dev/loop0 /dev/loop1",
            "0 100 linear /dev/mapper/control 0",
            "",
            "garbage",
        ] {
            assert!(
                bad.parse::<DmTable<FilePath>>().is_err(),
                "accepted {bad:?}"
            );
        }
    }

    #[test]
    fn a_mapper_operand_is_always_a_device_never_a_file() {
        let got: DmTable<FilePath> = "0 100 linear /dev/mapper/img 0".parse().unwrap();
        assert!(matches!(
            got,
            DmTable::Linear(LinearTable {
                origin: Source::Device(_),
                ..
            })
        ));
        assert!(matches!(
            "0 100 linear /dev/mapper/a/b 0".parse::<DmTable<FilePath>>(),
            Err(ParseTableError::Device(_))
        ));
    }
}
