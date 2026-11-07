//! Utilities for operating on linux `dsetup`.

mod device;
mod name;
mod table;
mod thin;
pub mod thin_dump;

use super::Access;
use derive_more::Constructor;
pub use device::Device;
use hyperrs_process::binary::RootSafeBin;
pub use name::{DmName, InvalidDmName, OpenDeviceError, ParseDmDeviceError};
use std::ffi::OsStr;
use std::io;
pub use table::{
    DevPath, DmTable, LinearTable, Origin, ParseTableError, Persistence, Role, SnapshotTable,
    ThinPoolTable, ThinTable,
};
pub use thin::{
    Active, Inactive, OpenThinError, ParseThinIdError, ParseThinMessageError, SnapshotError, Thin,
    ThinId, ThinIdOutOfRange, ThinMessage, ThinPool, ThinPoolError,
};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum RunError {
    #[error("running dmsetup: {0}")]
    Spawn(#[source] io::Error),
    #[error("dmsetup failed: {0}")]
    Failed(String),
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
        let mut args = vec![OsStr::new("create"), name.as_ref()];
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
