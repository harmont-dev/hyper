use super::{DmName, Dmsetup, RemoveMode, RunError};
use hyperrs_fs::path::{IsAbsolute, SafePathBuf, StrictComponents};
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

    pub fn number(&self) -> Result<String, RunError> {
        let out = self.dmsetup.run([
            OsStr::new("info"),
            OsStr::new("-c"),
            OsStr::new("--noheadings"),
            OsStr::new("-o"),
            OsStr::new("major,minor"),
            self.name.as_ref(),
        ])?;
        Ok(out.trim().to_string())
    }

    pub fn suspend(&self) -> Result<(), RunError> {
        self.dmsetup
            .run([OsStr::new("suspend"), self.name.as_ref()])
            .map(drop)
    }

    pub fn resume(&self) -> Result<(), RunError> {
        self.dmsetup
            .run([OsStr::new("resume"), self.name.as_ref()])
            .map(drop)
    }

    pub fn remove(self, mode: RemoveMode) -> Result<(), RunError> {
        let mut args = vec![OsStr::new("remove")];
        if mode == RemoveMode::Retry {
            args.push(OsStr::new("--retry"));
        }
        args.push(self.name.as_ref());
        self.dmsetup.run(args).map(drop)
    }
}
