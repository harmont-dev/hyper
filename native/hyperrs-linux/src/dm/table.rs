use super::name::MAPPER_PREFIX;
use super::{DmName, ParseDmDeviceError, ParseThinIdError, ThinId};
use derive_more::{Display, TryUnwrap};
use hyperrs_fs::path::{self, IsAbsolute, SafePathBuf, StrictComponents};
use std::num::ParseIntError;
use std::str::FromStr;
use thiserror::Error as ThisError;

/// A table `<dev path>` operand: an absolute path to a block device.
pub type DevPath = SafePathBuf<IsAbsolute, StrictComponents>;

/// Dmsetup tables. See `man dmsetup` for more info, under the `--table` docs.
#[derive(Debug, Clone, PartialEq, Eq, Display)]
pub enum DmTable {
    /// `linear`: maps the device straight onto its origin.
    Linear(LinearTable),
    /// `snapshot`: a copy-on-write view of an origin.
    Snapshot(SnapshotTable),
    /// `thin-pool`: the shared store thin devices allocate from.
    ThinPool(ThinPoolTable),
    /// `thin`: a thinly provisioned device inside a pool.
    Thin(ThinTable),
}

/// Which table argument a [`DevPath`] operand fills.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, serde::Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Role {
    /// The device read from: linear `<dev path>`, snapshot `<origin>`, thin `<external origin dev>`.
    Origin,
    /// Snapshot `<COW device>`, where written chunks land.
    Cow,
    /// Thin-pool `<metadata dev>`.
    Metadata,
    /// Thin-pool `<data dev>`.
    Data,
}

/// The device a table reads from.
#[derive(Debug, Clone, PartialEq, Eq, Display, TryUnwrap)]
#[try_unwrap(ref, ref_mut)]
pub enum Origin {
    /// An existing dm device, rendered as `/dev/mapper/<name>`.
    #[display("{}", _0.path().as_path().display())]
    Device(DmName),
    /// Any other block device, by path.
    #[display("{}", _0.as_path().display())]
    Path(DevPath),
}

/// The snapshot `<persistent?>` flag.
#[derive(Debug, Clone, Copy, PartialEq, Eq, strum::Display, strum::EnumString)]
pub enum Persistence {
    /// `P`: exceptions are stored on the COW device and survive reboot.
    #[strum(serialize = "P")]
    Persistent,
    /// `N`: exceptions are kept in memory only.
    #[strum(serialize = "N")]
    Transient,
}

#[derive(Debug, Clone, PartialEq, Eq, Display)]
#[display("0 {sectors} linear {origin} 0")]
pub struct LinearTable {
    pub sectors: u64,
    pub origin: Origin,
}

#[derive(Debug, Clone, PartialEq, Eq, Display)]
#[display(
    "0 {sectors} snapshot {origin} {} {persistence} {chunk}",
    cow.as_path().display()
)]
pub struct SnapshotTable {
    pub sectors: u64,
    pub origin: Origin,
    pub cow: DevPath,
    pub persistence: Persistence,
    pub chunk: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Display)]
#[display(
    "0 {sectors} thin-pool {} {} {block_sectors} {low_water}",
    metadata.as_path().display(),
    data.as_path().display()
)]
pub struct ThinPoolTable {
    pub sectors: u64,
    pub metadata: DevPath,
    pub data: DevPath,
    pub block_sectors: u64,
    pub low_water: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Display)]
#[display(
    "0 {sectors} thin {} {id}{}",
    pool.path().as_path().display(),
    origin.as_ref().map(|o| format!(" {o}")).unwrap_or_default()
)]
pub struct ThinTable {
    pub sectors: u64,
    pub pool: DmName,
    pub id: ThinId,
    pub origin: Option<Origin>,
}

#[derive(Debug, ThisError)]
pub enum ParseTableError {
    /// Not one of the four supported target grammars.
    #[error("unsupported dm table: {0}")]
    Malformed(String),
    /// A `/dev/mapper/` operand that is not a valid dm name.
    #[error(transparent)]
    Device(#[from] ParseDmDeviceError),
    /// A backing operand that is not an absolute, strict path.
    #[error("backing file path: {0}")]
    Path(#[from] path::ValidationError),
    /// A sector count, chunk size, block size, or low-water mark that is not a `u64`.
    #[error("table number: {0}")]
    Number(#[from] ParseIntError),
    /// A snapshot `<persistent?>` flag other than `P` or `N`.
    #[error("snapshot persistence must be `P` or `N`")]
    Persistence(#[from] strum::ParseError),
    /// A thin device id that is not a 24-bit integer.
    #[error(transparent)]
    ThinId(#[from] ParseThinIdError),
}

impl DmTable {
    /// The non-dm block device operands, each with the table argument it fills.
    pub fn paths(&self) -> impl Iterator<Item = (Role, &DevPath)> {
        let (origin, first, second) = match self {
            DmTable::Linear(LinearTable { origin, .. }) => (Some(origin), None, None),
            DmTable::Snapshot(SnapshotTable { origin, cow, .. }) => {
                (Some(origin), Some((Role::Cow, cow)), None)
            }
            DmTable::ThinPool(ThinPoolTable { metadata, data, .. }) => (
                None,
                Some((Role::Metadata, metadata)),
                Some((Role::Data, data)),
            ),
            DmTable::Thin(ThinTable { origin, .. }) => (origin.as_ref(), None, None),
        };
        let origin = origin
            .and_then(|o| o.try_unwrap_path_ref().ok())
            .map(|p| (Role::Origin, p));
        origin.into_iter().chain(first).chain(second)
    }

    /// [`Self::paths`], mutably.
    pub fn paths_mut(&mut self) -> impl Iterator<Item = (Role, &mut DevPath)> {
        let (origin, first, second) = match self {
            DmTable::Linear(LinearTable { origin, .. }) => (Some(origin), None, None),
            DmTable::Snapshot(SnapshotTable { origin, cow, .. }) => {
                (Some(origin), Some((Role::Cow, cow)), None)
            }
            DmTable::ThinPool(ThinPoolTable { metadata, data, .. }) => (
                None,
                Some((Role::Metadata, metadata)),
                Some((Role::Data, data)),
            ),
            DmTable::Thin(ThinTable { origin, .. }) => (origin.as_mut(), None, None),
        };
        let origin = origin
            .and_then(|o| o.try_unwrap_path_mut().ok())
            .map(|p| (Role::Origin, p));
        origin.into_iter().chain(first).chain(second)
    }

    /// The dm devices this table references, by name.
    pub fn devices(&self) -> impl Iterator<Item = &DmName> {
        let (first, second) = match self {
            DmTable::Linear(LinearTable { origin, .. })
            | DmTable::Snapshot(SnapshotTable { origin, .. }) => {
                (origin.try_unwrap_device_ref().ok(), None)
            }
            DmTable::ThinPool(_) => (None, None),
            DmTable::Thin(ThinTable { pool, origin, .. }) => (
                Some(pool),
                origin.as_ref().and_then(|o| o.try_unwrap_device_ref().ok()),
            ),
        };
        first.into_iter().chain(second)
    }
}

impl FromStr for Origin {
    type Err = ParseTableError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Ok(if s.starts_with(MAPPER_PREFIX) {
            Origin::Device(DmName::from_device_path(s)?)
        } else {
            Origin::Path(s.parse()?)
        })
    }
}

impl FromStr for DmTable {
    type Err = ParseTableError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Ok(match s.split_whitespace().collect::<Vec<_>>()[..] {
            ["0", sectors, "linear", origin, "0"] => DmTable::Linear(LinearTable {
                sectors: sectors.parse()?,
                origin: origin.parse()?,
            }),
            ["0", sectors, "snapshot", origin, cow, persistence, chunk] => {
                DmTable::Snapshot(SnapshotTable {
                    sectors: sectors.parse()?,
                    origin: origin.parse()?,
                    cow: cow.parse()?,
                    persistence: persistence.parse()?,
                    chunk: chunk.parse()?,
                })
            }
            ["0", sectors, "thin-pool", metadata, data, block_sectors, low_water] => {
                DmTable::ThinPool(ThinPoolTable {
                    sectors: sectors.parse()?,
                    metadata: metadata.parse()?,
                    data: data.parse()?,
                    block_sectors: block_sectors.parse()?,
                    low_water: low_water.parse()?,
                })
            }
            ["0", sectors, "thin", pool, id, ref origin @ ..] if origin.len() <= 1 => {
                DmTable::Thin(ThinTable {
                    sectors: sectors.parse()?,
                    pool: DmName::from_device_path(pool)?,
                    id: id.parse()?,
                    origin: origin.first().map(|o| o.parse()).transpose()?,
                })
            }
            _ => return Err(ParseTableError::Malformed(s.into())),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::{
        DevPath, DmTable, LinearTable, Origin, ParseTableError, Persistence, SnapshotTable,
        ThinPoolTable, ThinTable,
    };
    use crate::dm::{DmName, ThinId};
    use proptest::prelude::*;
    use std::path::PathBuf;

    fn file() -> impl Strategy<Value = DevPath> {
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

    fn origin() -> impl Strategy<Value = Origin> {
        prop_oneof![
            dm_name().prop_map(Origin::Device),
            file().prop_map(Origin::Path)
        ]
    }

    fn thin_id() -> impl Strategy<Value = ThinId> {
        (0..=ThinId::MAX).prop_map(|n| ThinId::new(n).unwrap())
    }

    fn persistence() -> impl Strategy<Value = Persistence> {
        prop_oneof![Just(Persistence::Persistent), Just(Persistence::Transient)]
    }

    fn table() -> impl Strategy<Value = DmTable> {
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

    proptest! {
        #[test]
        fn parse_is_the_inverse_of_render(t in table()) {
            let back: DmTable = t.to_string().parse().unwrap();
            prop_assert_eq!(back, t);
        }

        #[test]
        fn render_is_canonical_regardless_of_input_spacing(t in table(), pad in "[ \t]{1,3}") {
            let spaced = t.to_string().split(' ').collect::<Vec<_>>().join(&pad);
            let back: DmTable = format!("{pad}{spaced}{pad}").parse().unwrap();
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
            assert!(bad.parse::<DmTable>().is_err(), "accepted {bad:?}");
        }
    }

    #[test]
    fn a_mapper_operand_is_always_a_device_never_a_file() {
        let got: DmTable = "0 100 linear /dev/mapper/img 0".parse().unwrap();
        assert!(matches!(
            got,
            DmTable::Linear(LinearTable {
                origin: Origin::Device(_),
                ..
            })
        ));
        assert!(matches!(
            "0 100 linear /dev/mapper/a/b 0".parse::<DmTable>(),
            Err(ParseTableError::Device(_))
        ));
    }
}
