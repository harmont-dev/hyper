//! Utilities for operating on linux `dsetup`.

mod device;
mod name;
mod table;
mod thin;
pub mod thin_dump;

use super::Access;
use derive_more::Constructor;
pub use device::{Device, NumberError};
use hyperrs_process::binary::RootSafeBin;
use hyperrs_process::privilege::{Root, RootCommandExt};
pub use name::{DmName, InvalidDmName, OpenDeviceError, ParseDmDeviceError, SizeError};
use std::ffi::OsStr;
use std::io;
use std::os::unix::io::AsFd;
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
    pub fn create<'a>(
        &'a self,
        root: &'a Root<'a>,
        name: &DmName,
        table: &DmTable,
        access: Access,
    ) -> Result<Device<'a>, RunError> {
        let table = table.to_string();
        let mut args = vec![OsStr::new("create"), name.as_ref()];
        if access == Access::ReadOnly {
            args.push(OsStr::new("--readonly"));
        }
        args.extend([OsStr::new("--table"), OsStr::new(&table)]);
        self.run(root, args)?;
        Ok(self.device(root, name))
    }

    pub fn device<'a>(&'a self, root: &'a Root<'a>, name: &DmName) -> Device<'a> {
        Device {
            dmsetup: self,
            root,
            name: name.clone(),
        }
    }

    pub fn thin_pool<'a>(
        &'a self,
        root: &'a Root<'a>,
        name: &DmName,
    ) -> Result<ThinPool<'a>, ThinPoolError> {
        ThinPool::open(self, root, name)
    }

    fn run<I, S>(&self, root: &Root<'_>, args: I) -> Result<String, RunError>
    where
        I: IntoIterator<Item = S>,
        S: AsRef<OsStr>,
    {
        let out = self
            .bin
            .command()
            .args(args)
            // The binary fd stays open so an interpreted tool can reopen itself via /proc/self/fd.
            .spawn_as_root(root, &[self.bin.as_fd()])
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
