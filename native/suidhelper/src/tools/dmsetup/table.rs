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
    Padded(PaddedTable),
}

impl FromStr for DmTable {
    type Err = Error;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        if s.contains('\n') {
            return Ok(DmTable::Padded(s.parse()?));
        }

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
            DmTable::Padded(t) => t.fmt(f),
        }
    }
}

/// A two-segment table which exposes `base` followed by zero-filled sectors.
/// It is the only multi-line mapping accepted by the helper, allowing an image
/// layer to retain a VM's logical disk size without opening arbitrary devices.
#[derive(Clone)]
pub struct PaddedTable {
    base_sectors: u64,
    sectors: u64,
    base: crate::util::safe_dev::BlockDev,
}

impl FromStr for PaddedTable {
    type Err = Error;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let lines: Vec<&str> = s.lines().collect();
        let [first, second] = lines.as_slice() else {
            return Err(Error::BadTable(s.to_string()));
        };
        let a: Vec<&str> = first.split_whitespace().collect();
        let b: Vec<&str> = second.split_whitespace().collect();
        let ["0", base_sectors, "linear", base, "0"] = a.as_slice() else {
            return Err(Error::BadTable(s.to_string()));
        };
        let base_sectors: u64 = base_sectors
            .parse()
            .map_err(|_| Error::BadTable(s.to_string()))?;
        let [start, extra, "zero"] = b.as_slice() else {
            return Err(Error::BadTable(s.to_string()));
        };
        let start: u64 = start.parse().map_err(|_| Error::BadTable(s.to_string()))?;
        let extra: u64 = extra.parse().map_err(|_| Error::BadTable(s.to_string()))?;
        if start != base_sectors || extra == 0 {
            return Err(Error::BadTable(s.to_string()));
        }
        Ok(Self {
            base_sectors,
            sectors: base_sectors
                .checked_add(extra)
                .ok_or_else(|| Error::BadTable(s.to_string()))?,
            base: base.parse()?,
        })
    }
}

impl fmt::Display for PaddedTable {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        use std::path::Path;
        let base: &Path = self.base.as_ref();
        write!(
            f,
            "0 {} linear {} 0\n{} {} zero",
            self.base_sectors,
            base.display(),
            self.base_sectors,
            self.sectors - self.base_sectors
        )
    }
}
