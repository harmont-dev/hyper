//! A validated tool-binary path.
//!
//! The path of each device tool (`losetup`, `dmsetup`, `blockdev`) comes from
//! the root-owned config file, never from the unprivileged caller. [`RootSafeBin`]
//! is a newtype whose only constructor runs the safety checks, so holding one is
//! proof the path was validated. The const string parameter `NAME` is the
//! basename it was validated against - a `RootSafeBin<"losetup">` can never be
//! passed where a `RootSafeBin<"dmsetup">` is wanted.
//!
//! These checks are what keep this from being arbitrary-root-execution: even a
//! mistaken config entry cannot point us at a binary a non-root user controls
//! (must be an absolute path, the exact basename, root-owned, not a symlink, not
//! group/other-writable).

use crate::fs::file::{self, IsRegularFile, OpenFlags, OwnerOnlyWritable, RootOwner, SafeFile};
use crate::fs::path::{self, IsAbsolute, SafePath, StrictComponents};
use nix::errno::Errno;
use nix::fcntl::{fcntl, FcntlArg, FdFlag};
use std::convert::Infallible;
use std::ffi::{CStr, OsStr};
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

        if bin.file_name() != Some(OsStr::new(NAME)) {
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

    pub fn exec<SA: AsRef<CStr>, SE: AsRef<CStr>>(
        &self,
        args: &[SA],
        env: &[SE],
    ) -> nix::Result<Infallible> {
        nix::unistd::fexecve(self.0.as_raw_fd(), args, env)
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
