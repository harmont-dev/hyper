use super::snapshot::SnapshotTable;
use super::thin::ThinTable;
use super::thin_pool::ThinPoolTable;
use super::Error;
use std::fmt;
use std::str::FromStr;

/// Any dm table we are willing to create. The variant is chosen by the target
/// keyword; every variant re-renders from validated fields so dmsetup only ever
/// sees a table we reconstructed.
#[derive(Clone)]
pub enum DmTable {
    Snapshot(SnapshotTable),
    ThinPool(ThinPoolTable),
    Thin(ThinTable),
}

impl FromStr for DmTable {
    type Err = Error;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.split_whitespace().nth(2) {
            Some("snapshot") => Ok(DmTable::Snapshot(s.parse()?)),
            Some("thin-pool") => Ok(DmTable::ThinPool(s.parse()?)),
            Some("thin") => Ok(DmTable::Thin(s.parse()?)),
            _ => Err(Error::BadTable(s.to_string())),
        }
    }
}

impl fmt::Display for DmTable {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            DmTable::Snapshot(t) => t.fmt(f),
            DmTable::ThinPool(t) => t.fmt(f),
            DmTable::Thin(t) => t.fmt(f),
        }
    }
}
