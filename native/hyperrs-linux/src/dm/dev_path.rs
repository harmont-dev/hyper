use super::name::MAPPER_PREFIX;
use derive_more::{Deref, Into};
use hyperrs_fs::path::{self, IsAbsolute, SafePathBuf, StrictComponents};
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::str::FromStr;
use thiserror::Error as ThisError;

// The kernel's `isspace` (lib/ctype.c) classes the Latin-1 byte 0xA0 as a
// space, so `dm_split_args` splits a UTF-8 path through any char holding it.
const KERNEL_SPACE: u8 = 0xa0;

/// A table `<dev path>` operand: an absolute path to a block device.
#[derive(Debug, Clone, PartialEq, Eq, Deref, Into)]
#[cfg_attr(
    feature = "serde",
    derive(serde::Deserialize),
    serde(try_from = "PathBuf")
)]
pub struct DevPath(SafePathBuf<IsAbsolute, StrictComponents>);

#[derive(Debug, ThisError)]
pub enum DevPathError {
    #[error(transparent)]
    Path(#[from] path::ValidationError),
    #[error("{}: whitespace would split it into several table operands", .0.display())]
    Splits(PathBuf),
    #[error("{}: a dm device is a table operand by name, not by path", .0.display())]
    DmDevice(PathBuf),
}

impl TryFrom<SafePathBuf<IsAbsolute, StrictComponents>> for DevPath {
    type Error = DevPathError;

    fn try_from(path: SafePathBuf<IsAbsolute, StrictComponents>) -> Result<Self, Self::Error> {
        let bytes = path.as_path().as_os_str().as_bytes();
        if bytes.contains(&KERNEL_SPACE)
            || String::from_utf8_lossy(bytes).contains(char::is_whitespace)
        {
            return Err(DevPathError::Splits(path.into()));
        }
        if path.as_path().starts_with(Path::new(MAPPER_PREFIX)) {
            return Err(DevPathError::DmDevice(path.into()));
        }
        Ok(Self(path))
    }
}

impl TryFrom<PathBuf> for DevPath {
    type Error = DevPathError;

    fn try_from(path: PathBuf) -> Result<Self, Self::Error> {
        SafePathBuf::try_from(path)?.try_into()
    }
}

impl FromStr for DevPath {
    type Err = DevPathError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        PathBuf::from(s).try_into()
    }
}
