use super::Error;
use derive_more::Display;
use std::str::FromStr;

/// A thin-pool message we permit: provision, snapshot, or drop a thin device by id, or pin/unpin the pool's metadata snapshot.
#[derive(Clone, Display)]
pub enum ThinMessage {
    #[display("create_thin {_0}")]
    CreateThin(u64),
    #[display("create_snap {_0} {_1}")]
    CreateSnap(u64, u64),
    #[display("delete {_0}")]
    Delete(u64),
    #[display("reserve_metadata_snap")]
    ReserveMetadataSnap,
    #[display("release_metadata_snap")]
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
