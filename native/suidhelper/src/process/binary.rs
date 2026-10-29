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

#[cfg(test)]
mod tests {
    //! `RootSafeBin<NAME>` is what stops a configured path from pointing the helper at
    //! an attacker-controlled binary it would then run as root. The constructor demands
    //! an absolute path, exact basename, a real (non-symlink) regular file owned by
    //! root and not group/other-writable. These assert the refusal axes; the symlink
    //! axis is root-independent, the owner axis is asserted both ways.

    use super::RootSafeBin;
    use std::fs;
    use std::os::unix::fs::{symlink, PermissionsExt};
    use std::path::Path;

    fn is_root() -> bool {
        nix::unistd::geteuid().is_root()
    }

    #[test]
    fn rejects_relative_path() {
        assert!(RootSafeBin::<"dmsetup">::open(Path::new("dmsetup")).is_err());
        assert!(RootSafeBin::<"dmsetup">::open(Path::new("./dmsetup")).is_err());
    }

    #[test]
    fn rejects_wrong_basename() {
        // An absolute, existing, root-owned system file with the WRONG basename fails.
        assert!(RootSafeBin::<"dmsetup">::open(Path::new("/usr/bin/env")).is_err());
    }

    #[test]
    fn rejects_symlink_with_correct_basename() {
        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("target");
        fs::write(&target, b"x").unwrap();
        let link = dir.path().join("dmsetup");
        symlink(&target, &link).unwrap();
        // Symlink is checked before ownership, so this holds regardless of who runs it.
        assert!(RootSafeBin::<"dmsetup">::open(&link).is_err());
    }

    #[test]
    fn owner_axis_root_owned_accepted_else_rejected() {
        let dir = tempfile::tempdir().unwrap();
        let f = dir.path().join("dmsetup");
        fs::write(&f, b"#!/bin/true\n").unwrap();
        fs::set_permissions(&f, fs::Permissions::from_mode(0o755)).unwrap();
        let got = RootSafeBin::<"dmsetup">::open(&f);
        if is_root() {
            // root-owned, 0755, absolute, correct basename, not a symlink → valid.
            assert!(got.is_ok(), "root-owned valid bin rejected: {got:?}");
        } else {
            // We own it (uid != 0) → NotRoot.
            assert!(got.is_err(), "non-root-owned bin accepted");
        }
    }

    #[test]
    fn rejects_group_or_other_writable() {
        if is_root() {
            let dir = tempfile::tempdir().unwrap();
            let f = dir.path().join("dmsetup");
            fs::write(&f, b"x").unwrap();
            // root-owned but group/other-writable → Writable rejection.
            fs::set_permissions(&f, fs::Permissions::from_mode(0o757)).unwrap();
            assert!(RootSafeBin::<"dmsetup">::open(&f).is_err());
        } else {
            eprintln!("SKIP rejects_group_or_other_writable: needs root to own a 0757 file");
        }
    }
}
