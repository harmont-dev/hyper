use crate::linux::dm::{ParseThinIdError, ThinId};
use thiserror::Error as ThisError;

/// A thin-pool message we permit: provision, snapshot, or drop a thin device by id, or pin/unpin the pool's metadata snapshot.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ThinMessage {
    CreateThin(ThinId),
    CreateSnap { id: ThinId, origin: ThinId },
    Delete(ThinId),
    ReserveMetadataSnap,
    ReleaseMetadataSnap,
}

#[derive(Debug, ThisError)]
pub enum MessageError {
    #[error("unsupported thin-pool message: {0}")]
    Malformed(String),
    #[error(transparent)]
    ThinId(#[from] ParseThinIdError),
}

pub fn parse_message(s: &str) -> Result<ThinMessage, MessageError> {
    match s.split_whitespace().collect::<Vec<_>>().as_slice() {
        ["create_thin", i] => Ok(ThinMessage::CreateThin(i.parse()?)),
        ["create_snap", new, orig] => Ok(ThinMessage::CreateSnap {
            id: new.parse()?,
            origin: orig.parse()?,
        }),
        ["delete", i] => Ok(ThinMessage::Delete(i.parse()?)),
        ["reserve_metadata_snap"] => Ok(ThinMessage::ReserveMetadataSnap),
        ["release_metadata_snap"] => Ok(ThinMessage::ReleaseMetadataSnap),
        _ => Err(MessageError::Malformed(s.to_string())),
    }
}
