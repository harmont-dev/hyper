use super::name::MAPPER_PREFIX;
use super::{DmName, ParseDmDeviceError, ParseThinIdError, ThinId};
use crate::loopdev::LoopDevice;
use derive_more::Display;
use hyperrs_fs::path::{self, IsAbsolute, SafePath, SafePathBuf, StrictComponents};
use std::path::PathBuf;
use std::str::FromStr;
use thiserror::Error as ThisError;

/// Dmsetup tables. See `man dmsetup` for more info, under the `--table` docs.
#[derive(Debug, Clone, PartialEq, Eq, Display)]
#[display(bound(B: BackingPath))]
pub enum DmTable<B> {
    Linear(LinearTable<B>),
    Snapshot(SnapshotTable<B>),
    ThinPool(ThinPoolTable<B>),
    Thin(ThinTable<B>),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, serde::Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Role {
    Origin,
    Cow,
    Metadata,
    Data,
}

#[derive(Debug, Clone, PartialEq, Eq, Display)]
pub enum Origin<B> {
    #[display("{}", _0.path().as_path().display())]
    Device(DmName),
    #[display(bound(B: BackingPath))]
    #[display("{}", _0.backing_path().as_path().display())]
    File(B),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Display)]
pub enum Persistence {
    #[display("P")]
    Persistent,
    #[display("N")]
    Transient,
}

#[derive(Debug, Clone, PartialEq, Eq, Display)]
#[display(bound(B: BackingPath))]
#[display("0 {sectors} linear {origin} 0")]
pub struct LinearTable<B> {
    pub sectors: u64,
    pub origin: Origin<B>,
}

/// `dm-snapshot` table.
#[derive(Debug, Clone, PartialEq, Eq, Display)]
#[display(bound(B: BackingPath))]
#[display(
    "0 {sectors} snapshot {origin} {} {persistence} {chunk}",
    cow.backing_path().as_path().display()
)]
pub struct SnapshotTable<B> {
    pub sectors: u64,
    pub origin: Origin<B>,
    pub cow: B,
    pub persistence: Persistence,
    pub chunk: u64,
}

/// `dm-thin` pool table.
#[derive(Debug, Clone, PartialEq, Eq, Display)]
#[display(bound(B: BackingPath))]
#[display(
    "0 {sectors} thin-pool {} {} {block_sectors} {low_water}",
    metadata.backing_path().as_path().display(),
    data.backing_path().as_path().display()
)]
pub struct ThinPoolTable<B> {
    pub sectors: u64,
    pub metadata: B,
    pub data: B,
    pub block_sectors: u64,
    pub low_water: u64,
}

/// `dm-thin` tables.
#[derive(Debug, Clone, PartialEq, Eq, Display)]
#[display(bound(B: BackingPath))]
#[display(
    "0 {sectors} thin {} {id}{}",
    pool.path().as_path().display(),
    origin.as_ref().map(|o| format!(" {o}")).unwrap_or_default()
)]
pub struct ThinTable<B> {
    pub sectors: u64,
    pub pool: DmName,
    pub id: ThinId,
    pub origin: Option<Origin<B>>,
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

pub trait BackingPath {
    fn backing_path(&self) -> &SafePath<IsAbsolute, StrictComponents>;
}

impl BackingPath for SafePathBuf<IsAbsolute, StrictComponents> {
    fn backing_path(&self) -> &SafePath<IsAbsolute, StrictComponents> {
        self
    }
}

impl BackingPath for LoopDevice {
    fn backing_path(&self) -> &SafePath<IsAbsolute, StrictComponents> {
        self.path()
    }
}

impl<B> Origin<B> {
    fn try_map<G, E>(
        &self,
        role: Role,
        f: &mut impl FnMut(&B, Role) -> Result<G, E>,
    ) -> Result<Origin<G>, E> {
        Ok(match self {
            Origin::Device(dev) => Origin::Device(dev.clone()),
            Origin::File(file) => Origin::File(f(file, role)?),
        })
    }

    fn device(&self) -> Option<&DmName> {
        match self {
            Origin::Device(dev) => Some(dev),
            Origin::File(_) => None,
        }
    }
}

impl<B> DmTable<B> {
    pub fn try_map<G, E>(
        &self,
        mut f: impl FnMut(&B, Role) -> Result<G, E>,
    ) -> Result<DmTable<G>, E> {
        Ok(match self {
            DmTable::Linear(LinearTable { sectors, origin }) => DmTable::Linear(LinearTable {
                sectors: *sectors,
                origin: origin.try_map(Role::Origin, &mut f)?,
            }),
            DmTable::Snapshot(SnapshotTable {
                sectors,
                origin,
                cow,
                persistence,
                chunk,
            }) => DmTable::Snapshot(SnapshotTable {
                sectors: *sectors,
                origin: origin.try_map(Role::Origin, &mut f)?,
                cow: f(cow, Role::Cow)?,
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
                metadata: f(metadata, Role::Metadata)?,
                data: f(data, Role::Data)?,
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
                    .map(|origin| origin.try_map(Role::Origin, &mut f))
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
                (Some(pool), origin.as_ref().and_then(Origin::device))
            }
        };
        first.into_iter().chain(second)
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
        let parse_origin = |t: &str| -> Result<Origin<FilePath>, ParseTableError> {
            if t.starts_with(MAPPER_PREFIX) {
                Ok(Origin::Device(DmName::from_device_path(t)?))
            } else {
                Ok(Origin::File(file(t)?))
            }
        };

        let fields: Vec<&str> = s.split_whitespace().collect();
        Ok(match fields.as_slice() {
            ["0", sectors, "linear", origin, "0"] => DmTable::Linear(LinearTable {
                sectors: number(sectors)?,
                origin: parse_origin(origin)?,
            }),
            ["0", sectors, "snapshot", origin, cow, mode, chunk] => {
                let persistence = match *mode {
                    "P" => Persistence::Persistent,
                    "N" => Persistence::Transient,
                    _ => return Err(malformed()),
                };
                DmTable::Snapshot(SnapshotTable {
                    sectors: number(sectors)?,
                    origin: parse_origin(origin)?,
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
                    origin: origin.first().map(|o| parse_origin(o)).transpose()?,
                })
            }
            _ => return Err(malformed()),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::{
        DmTable, FilePath, LinearTable, Origin, ParseTableError, Persistence, SnapshotTable,
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

    fn origin() -> impl Strategy<Value = Origin<FilePath>> {
        prop_oneof![
            dm_name().prop_map(Origin::Device),
            file().prop_map(Origin::File)
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
            (any::<u64>(), origin())
                .prop_map(|(sectors, origin)| DmTable::Linear(LinearTable { sectors, origin })),
            (any::<u64>(), origin(), file(), persistence(), any::<u64>()).prop_map(
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
                prop::option::of(origin())
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
                origin: Origin::Device(_),
                ..
            })
        ));
        assert!(matches!(
            "0 100 linear /dev/mapper/a/b 0".parse::<DmTable<FilePath>>(),
            Err(ParseTableError::Device(_))
        ));
    }
}
