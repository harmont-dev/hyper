//! Utilities for operating on `/dev` devices.

use thiserror::Error;

#[derive(Debug, Error)]
pub enum LoopDevParsingError {
    #[error("expected /dev/loopN, got: {0}")]
    InvalidDevice(String),
}

/// A loop device path, `/dev/loopN`.
#[derive(Debug, Clone)]
pub struct LoopDev(PathBuf);

impl FromStr for LoopDev {
    type Err = Error;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        if is_loop(s) {
            Ok(Self(PathBuf::from(s)))
        } else {
            Err(Error::Loop(s.to_string()))
        }
    }
}
