//! Utilities for interacting with binaries.
use hyperrs_fs::file::{self, IsRegularFile, OpenFlags, OwnerOnlyWritable, RootOwner, SafeFile};
use hyperrs_fs::path::{self, IsAbsolute, SafePath, StrictComponent, StrictComponents};
use nix::errno::Errno;
use nix::fcntl::{fcntl, FcntlArg, FdFlag};
use std::os::unix::io::{AsFd, AsRawFd, BorrowedFd};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use thiserror::Error as ThisError;

#[derive(Debug, ThisError)]
pub enum RootSafeBinError {
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
    pub fn open(bin: &Path) -> Result<Self, RootSafeBinError> {
        let safe: &SafePath<IsAbsolute, StrictComponents> =
            bin.try_into().map_err(|source| RootSafeBinError::Path {
                path: bin.to_path_buf(),
                source,
            })?;

        if safe.file_name() != Some(const { StrictComponent::from_static(NAME) }) {
            return Err(RootSafeBinError::Name {
                expected: NAME,
                got: bin.to_path_buf(),
            });
        }

        let file =
            Executable::open(safe, OpenFlags::PATH).map_err(|source| RootSafeBinError::File {
                path: bin.to_path_buf(),
                source,
            })?;
        fcntl(file.as_raw_fd(), FcntlArg::F_SETFD(FdFlag::empty())).map_err(|errno| {
            RootSafeBinError::Inherit {
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
    pub fn open(bin: &Path) -> Result<Self, RootSafeBinError> {
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
    use assert_fs::prelude::*;
    use assert_fs::TempDir;
    use rstest::{fixture, rstest};
    use std::fs;
    use std::os::unix::fs::PermissionsExt;
    use std::path::{Path, PathBuf};

    fn is_root() -> bool {
        nix::unistd::geteuid().is_root()
    }

    #[fixture]
    fn dir() -> TempDir {
        TempDir::new().unwrap()
    }

    fn dmsetup_with_mode(dir: &TempDir, mode: u32) -> PathBuf {
        let f = dir.child("dmsetup");
        f.write_str("#!/bin/true\n").unwrap();
        fs::set_permissions(&f, fs::Permissions::from_mode(mode)).unwrap();
        f.to_path_buf()
    }

    #[rstest]
    #[case::bare_name("dmsetup")]
    #[case::dot_relative("./dmsetup")]
    #[case::wrong_basename("/usr/bin/env")]
    fn rejects_relative_path_or_wrong_basename(#[case] path: &str) {
        assert!(RootSafeBin::<"dmsetup">::open(Path::new(path)).is_err());
    }

    #[rstest]
    fn rejects_symlink_with_correct_basename(dir: TempDir) {
        let target = dir.child("target");
        target.write_str("x").unwrap();
        let link = dir.child("dmsetup");
        link.symlink_to_file(&target).unwrap();
        // Symlink is checked before ownership, so this holds regardless of who runs it.
        assert!(RootSafeBin::<"dmsetup">::open(&link).is_err());
    }

    #[rstest]
    fn owner_axis_root_owned_accepted_else_rejected(dir: TempDir) {
        let got = RootSafeBin::<"dmsetup">::open(&dmsetup_with_mode(&dir, 0o755));
        if is_root() {
            // root-owned, 0755, absolute, correct basename, not a symlink → valid.
            assert!(got.is_ok(), "root-owned valid bin rejected: {got:?}");
        } else {
            // We own it (uid != 0) → NotRoot.
            assert!(got.is_err(), "non-root-owned bin accepted");
        }
    }

    #[rstest]
    fn rejects_group_or_other_writable(dir: TempDir) {
        if is_root() {
            // root-owned but group/other-writable → Writable rejection.
            assert!(RootSafeBin::<"dmsetup">::open(&dmsetup_with_mode(&dir, 0o757)).is_err());
        } else {
            eprintln!("SKIP rejects_group_or_other_writable: needs root to own a 0757 file");
        }
    }
}
