//! Utilities for interacting with binaries.
use crate::fs::file::{self, IsRegularFile, OpenFlags, OwnerOnlyWritable, RootOwner, SafeFile};
use crate::fs::path::{self, IsAbsolute, SafePath, StrictComponent, StrictComponents};
use nix::errno::Errno;
use nix::fcntl::{fcntl, FcntlArg, FdFlag};
use std::os::unix::io::{AsFd, AsRawFd, BorrowedFd};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use thiserror::Error as ThisError;

#[derive(Debug, ThisError)]
pub enum Error {
    #[error("binary path {path}: {source}")]
    Path {
        path: PathBuf,
        #[source]
        source: path::ValidationError,
    },
    #[error("binary basename must be `{expected}`: {got}")]
    Name {
        expected: &'static str,
        got: PathBuf,
    },
    #[error("binary {path}: {source}")]
    File {
        path: PathBuf,
        #[source]
        source: file::ValidationError,
    },
    #[error("binary {path}: clearing FD_CLOEXEC: {errno}")]
    Inherit { path: PathBuf, errno: Errno },
}

type Executable = SafeFile<IsRegularFile, RootOwner, OwnerOnlyWritable>;

/// A binary that's safe for the root user to use.
#[derive(Debug)]
pub struct RootSafeBin<const NAME: &'static str>(Executable);

#[derive(Debug, Clone)]
pub struct RootSafeBinPathBuf<const NAME: &'static str>(PathBuf);

impl<const NAME: &'static str> RootSafeBin<NAME> {
    /// Validate that the given path is a safe binary, owned by root, non-symlink, not writable by
    /// everyone and matches `NAME`.
    pub fn open(bin: &Path) -> Result<Self, Error> {
        let safe: &SafePath<IsAbsolute, StrictComponents> =
            bin.try_into().map_err(|source| Error::Path {
                path: bin.to_path_buf(),
                source,
            })?;

        if safe.file_name() != Some(const { StrictComponent::from_static(NAME) }) {
            return Err(Error::Name {
                expected: NAME,
                got: bin.to_path_buf(),
            });
        }

        let file = Executable::open(safe, OpenFlags::PATH).map_err(|source| Error::File {
            path: bin.to_path_buf(),
            source,
        })?;
        fcntl(file.as_raw_fd(), FcntlArg::F_SETFD(FdFlag::empty())).map_err(|errno| {
            Error::Inherit {
                path: bin.to_path_buf(),
                errno,
            }
        })?;

        Ok(Self(file))
    }

    pub fn fd_path(&self) -> PathBuf {
        PathBuf::from(format!("/proc/self/fd/{}", self.0.as_raw_fd()))
    }

    pub fn command(&self) -> Command {
        let mut cmd = Command::new(self.fd_path());
        cmd.arg0(NAME);
        cmd
    }
}

impl<const NAME: &'static str> AsFd for RootSafeBin<NAME> {
    fn as_fd(&self) -> BorrowedFd<'_> {
        self.0.as_fd()
    }
}

impl<const NAME: &'static str> RootSafeBinPathBuf<NAME> {
    pub fn open(bin: &Path) -> Result<Self, Error> {
        RootSafeBin::<NAME>::open(bin)?;
        Ok(Self(bin.to_path_buf()))
    }

    pub fn as_path(&self) -> &Path {
        &self.0
    }
}
