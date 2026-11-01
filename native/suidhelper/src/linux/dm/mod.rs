//! Utilities for operating on linux `dsetup`.

mod device;
mod name;
mod table;
mod thin;
pub mod thin_dump;

use super::Access;
use crate::process::binary::RootSafeBin;
use derive_more::Constructor;
pub use device::Device;
pub use name::{DmName, InvalidDmName, OpenDeviceError};
use std::ffi::OsStr;
use std::io;
pub use table::{DmTable, LinearTable, Persistence, SnapshotTable, ThinPoolTable, ThinTable};
pub use thin::{
    Active, Inactive, ParseThinIdError, SnapshotError, Thin, ThinId, ThinIdOutOfRange, ThinPool,
    ThinPoolError,
};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum RunError {
    #[error("running dmsetup: {0}")]
    Spawn(#[source] io::Error),
    #[error("dmsetup failed: {0}")]
    Failed(String),
}

#[derive(Debug, Error)]
pub enum TargetsError {
    #[error(transparent)]
    Run(#[from] RunError),
    #[error("unexpected `dmsetup targets` line: {0:?}")]
    Malformed(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Target {
    pub name: String,
    pub version: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RemoveMode {
    Once,
    Retry,
}

/// Type-safe interface to `dmsetup`.
#[derive(Debug, Constructor)]
pub struct Dmsetup {
    bin: RootSafeBin<"dmsetup">,
}

impl Dmsetup {
    pub fn create(
        &self,
        name: &DmName,
        table: &DmTable,
        access: Access,
    ) -> Result<Device<'_>, RunError> {
        let table = table.to_string();
        let mut args = vec![OsStr::new("create"), name.as_os_str()];
        if access == Access::ReadOnly {
            args.push(OsStr::new("--readonly"));
        }
        args.extend([OsStr::new("--table"), OsStr::new(&table)]);
        self.run(args)?;
        Ok(self.device(name))
    }

    pub fn device(&self, name: &DmName) -> Device<'_> {
        Device {
            dmsetup: self,
            name: name.clone(),
        }
    }

    pub fn thin_pool(&self, name: &DmName) -> Result<ThinPool<'_>, ThinPoolError> {
        ThinPool::open(self, name)
    }

    pub fn targets(&self) -> Result<Vec<Target>, TargetsError> {
        self.run(["targets"])?
            .lines()
            .filter(|line| !line.trim().is_empty())
            .map(
                |line| match line.split_whitespace().collect::<Vec<_>>().as_slice() {
                    [name, version] => Ok(Target {
                        name: name.to_string(),
                        version: version.to_string(),
                    }),
                    _ => Err(TargetsError::Malformed(line.to_string())),
                },
            )
            .collect()
    }

    pub fn list(&self) -> Result<String, RunError> {
        self.run(["ls"])
    }

    fn run<I, S>(&self, args: I) -> Result<String, RunError>
    where
        I: IntoIterator<Item = S>,
        S: AsRef<OsStr>,
    {
        let out = self
            .bin
            .command()
            .args(args)
            .env_clear()
            .output()
            .map_err(RunError::Spawn)?;
        if !out.status.success() {
            return Err(RunError::Failed(
                String::from_utf8_lossy(&out.stderr).trim().to_string(),
            ));
        }
        Ok(String::from_utf8_lossy(&out.stdout).into_owned())
    }
}
