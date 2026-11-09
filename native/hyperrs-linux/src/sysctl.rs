// SPDX-License-Identifier: MIT

use derive_more::Display;
use hyperrs_fs::dir::SafeDir;
use hyperrs_fs::file::{self, Any, IsRegularFile, OpenFlags, SafeFile};
use hyperrs_fs::path::{SafePath, StrictComponent};
use nix::sys::stat::Mode;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use thiserror::Error as ThisError;

#[derive(Debug, ThisError)]
pub enum SysctlError {
    #[error("opening /proc/sys: {0}")]
    Root(#[source] file::ValidationError),
    #[error("opening sysctl {0}: {1}")]
    Open(SysctlKey, #[source] file::ValidationError),
    #[error("writing sysctl {0}: {1}")]
    Write(SysctlKey, #[source] io::Error),
}

#[derive(Debug, Clone, PartialEq, Eq, Display)]
#[display("{}", _0.display())]
pub struct SysctlKey(PathBuf);

impl SysctlKey {
    pub fn new<const N: usize>(segments: [&StrictComponent; N]) -> Self {
        const { assert!(N > 0, "a sysctl key has at least one segment") };

        Self(segments.iter().map(|s| s.as_path()).collect())
    }

    pub fn write(&self, value: &str) -> Result<(), SysctlError> {
        let root = SafeDir::open(SafePath::from_static::<"/proc/sys">(), OpenFlags::RDONLY)
            .map_err(SysctlError::Root)?;

        let mut file: SafeFile<IsRegularFile, Any, Any> = root
            .openat(Path::new(&self.0), OpenFlags::WRONLY, Mode::empty())
            .map_err(|e| SysctlError::Open(self.clone(), e))?;

        file.write_all(value.as_bytes())
            .map_err(|e| SysctlError::Write(self.clone(), e))
    }
}
