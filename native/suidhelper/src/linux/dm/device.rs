use super::{Dmsetup, RemoveMode, RunError};
use std::path::PathBuf;

#[derive(Debug, Clone)]
pub struct Device<'a> {
    pub(super) dmsetup: &'a Dmsetup,
    pub(super) name: String,
}

impl<'a> Device<'a> {
    pub fn name(&self) -> &str {
        &self.name
    }

    pub fn path(&self) -> PathBuf {
        PathBuf::from(format!("/dev/mapper/{}", self.name))
    }

    pub fn suspend(&self) -> Result<(), RunError> {
        self.dmsetup.run(["suspend", self.name.as_str()]).map(drop)
    }

    pub fn resume(&self) -> Result<(), RunError> {
        self.dmsetup.run(["resume", self.name.as_str()]).map(drop)
    }

    pub fn remove(self, mode: RemoveMode) -> Result<(), RunError> {
        let mut args = vec!["remove"];
        if mode == RemoveMode::Retry {
            args.push("--retry");
        }
        args.push(self.name.as_str());
        self.dmsetup.run(args).map(drop)
    }
}
