use super::Error;
use std::fmt;
use std::str::FromStr;

/// A thin-pool message we permit: provision, snapshot, or drop a thin device by id, or pin/unpin the pool's metadata snapshot.
#[derive(Clone)]
pub enum ThinMessage {
    CreateThin(u64),
    CreateSnap(u64, u64),
    Delete(u64),
    ReserveMetadataSnap,
    ReleaseMetadataSnap,
}

impl FromStr for ThinMessage {
    type Err = Error;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let id = |t: &str| t.parse().map_err(|_| Error::BadTable(s.to_string()));
        match s.split_whitespace().collect::<Vec<_>>().as_slice() {
            ["create_thin", i] => Ok(ThinMessage::CreateThin(id(i)?)),
            ["create_snap", new, orig] => Ok(ThinMessage::CreateSnap(id(new)?, id(orig)?)),
            ["delete", i] => Ok(ThinMessage::Delete(id(i)?)),
            ["reserve_metadata_snap"] => Ok(ThinMessage::ReserveMetadataSnap),
            ["release_metadata_snap"] => Ok(ThinMessage::ReleaseMetadataSnap),
            _ => Err(Error::BadTable(s.to_string())),
        }
    }
}

impl fmt::Display for ThinMessage {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ThinMessage::CreateThin(id) => write!(f, "create_thin {id}"),
            ThinMessage::CreateSnap(new, orig) => write!(f, "create_snap {new} {orig}"),
            ThinMessage::Delete(id) => write!(f, "delete {id}"),
            ThinMessage::ReserveMetadataSnap => write!(f, "reserve_metadata_snap"),
            ThinMessage::ReleaseMetadataSnap => write!(f, "release_metadata_snap"),
        }
    }
}
