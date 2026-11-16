use super::{DmName, Dmsetup, RemoveMode, RunError};
use hyperrs_fs::dev::{DeviceNumber, ParseDeviceNumberError};
use hyperrs_fs::path::{IsAbsolute, SafePathBuf, StrictComponents};
use hyperrs_process::privilege::Root;
use std::ffi::OsStr;
use thiserror::Error as ThisError;

#[derive(Debug, ThisError)]
pub enum NumberError {
    #[error(transparent)]
    Run(#[from] RunError),
    #[error(transparent)]
    Parse(#[from] ParseDeviceNumberError),
}

#[derive(Debug, Clone)]
pub struct Device<'a> {
    pub(super) dmsetup: &'a Dmsetup,
    pub(super) root: &'a Root<'a>,
    pub(super) name: DmName,
}

impl<'a> Device<'a> {
    pub fn name(&self) -> &DmName {
        &self.name
    }

    pub fn path(&self) -> SafePathBuf<IsAbsolute, StrictComponents> {
        self.name.path()
    }

    pub fn number(&self) -> Result<DeviceNumber, NumberError> {
        let out = self.dmsetup.run(
            self.root,
            [
                OsStr::new("info"),
                OsStr::new("-c"),
                OsStr::new("--noheadings"),
                OsStr::new("-o"),
                OsStr::new("major,minor"),
                self.name.as_ref(),
            ],
        )?;
        Ok(out.trim().parse()?)
    }

    pub fn suspend(&self) -> Result<(), RunError> {
        self.dmsetup
            .run(self.root, [OsStr::new("suspend"), self.name.as_ref()])
            .map(drop)
    }

    pub fn resume(&self) -> Result<(), RunError> {
        self.dmsetup
            .run(self.root, [OsStr::new("resume"), self.name.as_ref()])
            .map(drop)
    }

    pub fn remove(self, mode: RemoveMode) -> Result<(), RunError> {
        let mut args = vec![OsStr::new("remove")];
        if mode == RemoveMode::Retry {
            args.push(OsStr::new("--retry"));
        }
        args.push(self.name.as_ref());
        self.dmsetup.run(self.root, args).map(drop)
    }
}
