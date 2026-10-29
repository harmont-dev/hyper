use crate::linux::dm::{DmName, InvalidDmName};
use thiserror::Error as ThisError;

const HYPER_PREFIX: &str = "hyper-";
const MAPPER_PREFIX: &str = "/dev/mapper/";

#[derive(Debug, ThisError)]
pub enum NameError {
    #[error(transparent)]
    Invalid(#[from] InvalidDmName),
    #[error("dm device name must start with `{HYPER_PREFIX}`: {0}")]
    NotHyper(DmName),
    #[error("expected a `{MAPPER_PREFIX}<name>` device: {0:?}")]
    NotMapper(String),
}

pub fn parse_dm_name(s: &str) -> Result<DmName, NameError> {
    let name: DmName = s.parse()?;
    if s.starts_with(HYPER_PREFIX) {
        Ok(name)
    } else {
        Err(NameError::NotHyper(name))
    }
}

pub fn parse_dm_device(s: &str) -> Result<DmName, NameError> {
    let name = s
        .strip_prefix(MAPPER_PREFIX)
        .ok_or_else(|| NameError::NotMapper(s.to_string()))?;
    parse_dm_name(name)
}
