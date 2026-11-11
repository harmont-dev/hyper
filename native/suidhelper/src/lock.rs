// SPDX-License-Identifier: MIT

use hyperrs_firecracker::VmId;
use hyperrs_fs::dir::{DirError, SafeDir};
use hyperrs_fs::file::{IsDirectory, OpenFlags, OwnerOnlyWritable, RootOwner, SafeFile};
use hyperrs_fs::lock::{FileLock, LockError};
use hyperrs_fs::path::{SafePath, StrictComponent};
use hyperrs_process::privilege::Root;
use nix::errno::Errno;
use nix::sys::stat::Mode;
use std::time::Duration;
use thiserror::Error as ThisError;

const TIMEOUT: Duration = Duration::from_secs(5);
const HYPER: &StrictComponent = StrictComponent::from_static("hyper-suidhelper");
const LOCKS: &StrictComponent = StrictComponent::from_static("locks");

type RootDir = SafeFile<IsDirectory, RootOwner, OwnerOnlyWritable>;

pub type Lock<'a> = FileLock<'a, RootOwner, OwnerOnlyWritable>;

#[derive(Debug, ThisError)]
pub enum LocksError {
    #[error("opening the lock directory: {0}")]
    Dir(#[from] DirError),
    #[error(transparent)]
    Lock(#[from] LockError),
    #[error("removing the lock file: {0}")]
    Remove(#[source] Errno),
}

pub struct Locks(RootDir);

impl Locks {
    pub fn open(_root: &Root<'_>) -> Result<Self, LocksError> {
        let run: SafeDir = SafeFile::open(SafePath::from_static::<"/run">(), OpenFlags::RDONLY)
            .map_err(DirError::from)?;
        run.mkdirat(HYPER, Mode::from_bits_truncate(0o755))
            .map_err(DirError::from)?;
        let hyper: RootDir = run
            .openat(HYPER, OpenFlags::RDONLY, Mode::empty())
            .map_err(DirError::from)?;
        hyper
            .mkdirat(LOCKS, Mode::from_bits_truncate(0o700))
            .map_err(DirError::from)?;
        Ok(Self(
            hyper
                .openat(LOCKS, OpenFlags::RDONLY, Mode::empty())
                .map_err(DirError::from)?,
        ))
    }

    pub fn vm(&self, _root: &Root<'_>, id: &VmId) -> Result<Lock<'_>, LocksError> {
        let name = format!("vm-{id}");
        let name: &StrictComponent = name
            .as_str()
            .try_into()
            .expect("vm-<vm id> is a strict path component");
        Ok(FileLock::acquire(&self.0, name, TIMEOUT)?)
    }
}
