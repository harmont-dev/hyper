use super::Error;
use crate::util::safe_dev::{BlockDev, LoopDev};
use std::fmt;
use std::path::Path;
use std::str::FromStr;

/// A dm-snapshot table line: `0 <sectors> snapshot <origin> <cow> P|N <chunk>`.
/// Only this target is accepted - other dm targets (linear, crypt, ...) could map
/// arbitrary devices - and origin/cow are anchored to loop / hyper-* devices by
/// their types. Parsed from the caller's string, then rendered back via
/// `Display` so dmsetup only ever sees a table we reconstructed ourselves.
#[derive(Clone)]
pub struct SnapshotTable {
    sectors: u64,
    origin: BlockDev,
    cow: LoopDev,
    persistent: bool,
    chunk: u64,
}

impl FromStr for SnapshotTable {
    type Err = Error;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let fields: Vec<&str> = s.split_whitespace().collect();
        let [start, sectors, "snapshot", origin, cow, mode, chunk] = fields.as_slice() else {
            return Err(Error::BadTable(s.to_string()));
        };

        let persistent = match *mode {
            "P" => true,
            "N" => false,
            _ => return Err(Error::BadTable(s.to_string())),
        };

        if *start != "0" {
            return Err(Error::BadTable(s.to_string()));
        }

        Ok(Self {
            sectors: sectors.parse().map_err(|_| Error::BadTable(s.to_string()))?,
            origin: origin.parse()?,
            cow: cow.parse()?,
            persistent,
            chunk: chunk.parse().map_err(|_| Error::BadTable(s.to_string()))?,
        })
    }
}

impl fmt::Display for SnapshotTable {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let origin: &Path = self.origin.as_ref();
        let cow: &Path = self.cow.as_ref();
        write!(
            f,
            "0 {} snapshot {} {} {} {}",
            self.sectors,
            origin.display(),
            cow.display(),
            if self.persistent { "P" } else { "N" },
            self.chunk,
        )
    }
}
