use super::Error;
use crate::util::safe_dev::LoopDev;
use derive_more::Display;
use std::str::FromStr;

/// A dm-thin-pool table: `0 <sectors> thin-pool <meta> <data> <block_sectors> <low_water>`.
/// meta/data are our own loop devices; no feature args are accepted.
#[derive(Clone, Display)]
#[display("0 {sectors} thin-pool {metadata} {data} {block_sectors} {low_water}")]
pub struct ThinPoolTable {
    sectors: u64,
    metadata: LoopDev,
    data: LoopDev,
    block_sectors: u64,
    low_water: u64,
}

impl FromStr for ThinPoolTable {
    type Err = Error;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let f: Vec<&str> = s.split_whitespace().collect();
        let ["0", sectors, "thin-pool", meta, data, block, low] = f.as_slice() else {
            return Err(Error::BadTable(s.to_string()));
        };
        Ok(Self {
            sectors: sectors
                .parse()
                .map_err(|_| Error::BadTable(s.to_string()))?,
            metadata: meta.parse()?,
            data: data.parse()?,
            block_sectors: block.parse().map_err(|_| Error::BadTable(s.to_string()))?,
            low_water: low.parse().map_err(|_| Error::BadTable(s.to_string()))?,
        })
    }
}
