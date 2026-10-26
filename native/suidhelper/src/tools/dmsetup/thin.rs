use super::Error;
use crate::util::safe_dev::BlockDev;
use derive_more::Display;
use std::str::FromStr;

/// A dm-thin table: `0 <sectors> thin <pool> <dev_id> [<external_origin>]`.
/// pool + origin are anchored to our own dm/loop devices.
#[derive(Clone, Display)]
#[display(
    "0 {sectors} thin {pool} {dev_id}{}",
    origin.as_ref().map(|o| format!(" {o}")).unwrap_or_default()
)]
pub struct ThinTable {
    sectors: u64,
    pool: BlockDev,
    dev_id: u64,
    origin: Option<BlockDev>,
}

impl FromStr for ThinTable {
    type Err = Error;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let f: Vec<&str> = s.split_whitespace().collect();
        let (sectors, pool, dev_id, origin) = match f.as_slice() {
            ["0", sectors, "thin", pool, id] => (sectors, pool, id, None),
            ["0", sectors, "thin", pool, id, origin] => (sectors, pool, id, Some(origin)),
            _ => return Err(Error::BadTable(s.to_string())),
        };
        Ok(Self {
            sectors: sectors
                .parse()
                .map_err(|_| Error::BadTable(s.to_string()))?,
            pool: pool.parse()?,
            dev_id: dev_id.parse().map_err(|_| Error::BadTable(s.to_string()))?,
            origin: origin.map(|o| o.parse()).transpose()?,
        })
    }
}
