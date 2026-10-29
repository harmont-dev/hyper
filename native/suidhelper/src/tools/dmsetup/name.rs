use crate::linux::dm::{DmName, InvalidDmName};
use thiserror::Error as ThisError;

const HYPER_PREFIX: &str = "hyper-";

#[derive(Debug, ThisError)]
pub enum NameError {
    #[error(transparent)]
    Invalid(#[from] InvalidDmName),
    #[error("dm device name must start with `{HYPER_PREFIX}`: {0}")]
    NotHyper(DmName),
}

pub fn parse_dm_name(s: &str) -> Result<DmName, NameError> {
    let name: DmName = s.parse()?;
    if s.starts_with(HYPER_PREFIX) {
        Ok(name)
    } else {
        Err(NameError::NotHyper(name))
    }
}
