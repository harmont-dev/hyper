use crate::linux::dm::{ThinId, ThinIdOutOfRange};
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
    ThinId(#[from] ThinIdOutOfRange),
}

pub fn parse_message(s: &str) -> Result<ThinMessage, MessageError> {
    let id = |t: &str| -> Result<ThinId, MessageError> {
        let raw = t
            .parse()
            .map_err(|_| MessageError::Malformed(s.to_string()))?;
        Ok(ThinId::new(raw)?)
    };

    match s.split_whitespace().collect::<Vec<_>>().as_slice() {
        ["create_thin", i] => Ok(ThinMessage::CreateThin(id(i)?)),
        ["create_snap", new, orig] => Ok(ThinMessage::CreateSnap {
            id: id(new)?,
            origin: id(orig)?,
        }),
        ["delete", i] => Ok(ThinMessage::Delete(id(i)?)),
        ["reserve_metadata_snap"] => Ok(ThinMessage::ReserveMetadataSnap),
        ["release_metadata_snap"] => Ok(ThinMessage::ReleaseMetadataSnap),
        _ => Err(MessageError::Malformed(s.to_string())),
    }
}
