use crate::fs::path::{
    IsAbsolute, SafePath, SafePathBuf, StrictComponent, StrictComponentBuf, StrictComponents,
};
use derive_more::Display;
use std::ffi::OsStr;
use std::str::FromStr;
use thiserror::Error as ThisError;

const DM_NAME_MAX: usize = 127;

#[derive(Debug, ThisError)]
#[error("invalid dm device name: {0:?}")]
pub struct InvalidDmName(String);

#[derive(Debug, Clone, PartialEq, Eq, Display)]
#[display("{}", _0.as_os_str().to_string_lossy())]
pub struct DmName(StrictComponentBuf);

fn is_dm_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= DM_NAME_MAX
        && !name.starts_with('-')
        && !matches!(name, "." | ".." | "control")
        && name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"#+-.:=@_".contains(&b))
}

impl DmName {
    pub fn as_os_str(&self) -> &OsStr {
        self.0.as_os_str()
    }

    pub fn path(&self) -> SafePathBuf<IsAbsolute, StrictComponents> {
        SafePath::from_static::<"/dev/mapper">().join(&self.0)
    }
}

impl FromStr for DmName {
    type Err = InvalidDmName;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let invalid = || InvalidDmName(s.to_string());
        if !is_dm_name(s) {
            return Err(invalid());
        }
        let component: &StrictComponent = s.try_into().map_err(|_| invalid())?;
        Ok(Self(component.to_owned()))
    }
}

impl AsRef<OsStr> for DmName {
    fn as_ref(&self) -> &OsStr {
        self.as_os_str()
    }
}
