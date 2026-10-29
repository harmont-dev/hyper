use super::{DmName, Dmsetup, RemoveMode, RunError};
use crate::fs::path::{IsAbsolute, SafePathBuf, StrictComponents};
use std::ffi::OsStr;

#[derive(Debug, Clone)]
pub struct Device<'a> {
    pub(super) dmsetup: &'a Dmsetup,
    pub(super) name: DmName,
}

impl<'a> Device<'a> {
    pub fn name(&self) -> &DmName {
        &self.name
    }

    pub fn path(&self) -> SafePathBuf<IsAbsolute, StrictComponents> {
        self.name.path()
    }

    pub fn suspend(&self) -> Result<(), RunError> {
        self.dmsetup
            .run([OsStr::new("suspend"), self.name.as_os_str()])
            .map(drop)
    }

    pub fn resume(&self) -> Result<(), RunError> {
        self.dmsetup
            .run([OsStr::new("resume"), self.name.as_os_str()])
            .map(drop)
    }

    pub fn remove(self, mode: RemoveMode) -> Result<(), RunError> {
        let mut args = vec![OsStr::new("remove")];
        if mode == RemoveMode::Retry {
            args.push(OsStr::new("--retry"));
        }
        args.push(self.name.as_os_str());
        self.dmsetup.run(args).map(drop)
    }
}
