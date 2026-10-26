use super::ThinId;
use derive_more::Display;
use std::path::PathBuf;

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
#[display("0 {sectors} linear {} 0", origin.display())]
pub struct LinearTable {
    pub sectors: u64,
    pub origin: PathBuf,
}

/// `dm-snapshot` table.
#[derive(Debug, Clone, Display)]
#[display("0 {sectors} snapshot {} {} {persistence} {chunk}", origin.display(), cow.display())]
pub struct SnapshotTable {
    pub sectors: u64,
    pub origin: PathBuf,
    pub cow: PathBuf,
    pub persistence: Persistence,
    pub chunk: u64,
}

/// `dm-thin` pool table.
#[derive(Debug, Clone, Display)]
#[display(
    "0 {sectors} thin-pool {} {} {block_sectors} {low_water}",
    metadata.display(),
    data.display()
)]
pub struct ThinPoolTable {
    pub sectors: u64,
    pub metadata: PathBuf,
    pub data: PathBuf,
    pub block_sectors: u64,
    pub low_water: u64,
}

/// `dm-thin` tables.
#[derive(Debug, Clone, Display)]
#[display(
    "0 {sectors} thin {} {id}{}",
    pool.display(),
    origin.as_ref().map(|o| format!(" {}", o.display())).unwrap_or_default()
)]
pub struct ThinTable {
    pub sectors: u64,
    pub pool: PathBuf,
    pub id: ThinId,
    pub origin: Option<PathBuf>,
}
