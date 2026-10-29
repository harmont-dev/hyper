use super::{DmName, ThinId};
use crate::fs::path::{IsAbsolute, SafePathBuf, StrictComponents};
use derive_more::Display;

/// Dmsetup tables. See `man dmsetup` for more info, under the `--table` docs.
#[derive(Debug, Clone, Display)]
pub enum DmTable {
    Linear(LinearTable),
    Snapshot(SnapshotTable),
    ThinPool(ThinPoolTable),
    Thin(ThinTable),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Display)]
pub enum Persistence {
    #[display("P")]
    Persistent,
    #[display("N")]
    Transient,
}

#[derive(Debug, Clone, Display)]
#[display("0 {sectors} linear {} 0", origin.as_path().display())]
pub struct LinearTable {
    pub sectors: u64,
    pub origin: SafePathBuf<IsAbsolute, StrictComponents>,
}

/// `dm-snapshot` table.
#[derive(Debug, Clone, Display)]
#[display("0 {sectors} snapshot {} {} {persistence} {chunk}", origin.as_path().display(), cow.as_path().display())]
pub struct SnapshotTable {
    pub sectors: u64,
    pub origin: SafePathBuf<IsAbsolute, StrictComponents>,
    pub cow: SafePathBuf<IsAbsolute, StrictComponents>,
    pub persistence: Persistence,
    pub chunk: u64,
}

/// `dm-thin` pool table.
#[derive(Debug, Clone, Display)]
#[display(
    "0 {sectors} thin-pool {} {} {block_sectors} {low_water}",
    metadata.as_path().display(),
    data.as_path().display()
)]
pub struct ThinPoolTable {
    pub sectors: u64,
    pub metadata: SafePathBuf<IsAbsolute, StrictComponents>,
    pub data: SafePathBuf<IsAbsolute, StrictComponents>,
    pub block_sectors: u64,
    pub low_water: u64,
}

/// `dm-thin` tables.
#[derive(Debug, Clone, Display)]
#[display(
    "0 {sectors} thin {} {id}{}",
    pool.path().as_path().display(),
    origin.as_ref().map(|o| format!(" {}", o.as_path().display())).unwrap_or_default()
)]
pub struct ThinTable {
    pub sectors: u64,
    pub pool: DmName,
    pub id: ThinId,
    pub origin: Option<SafePathBuf<IsAbsolute, StrictComponents>>,
}
