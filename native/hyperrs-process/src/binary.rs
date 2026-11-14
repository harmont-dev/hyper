//! Utilities for interacting with binaries.
use hyperrs_fs::file::{self, IsRegularFile, OpenFlags, OwnerOnlyWritable, RootOwner, SafeFile};
use hyperrs_fs::path::{self, IsAbsolute, SafePath, StrictComponent, StrictComponents};
use nix::errno::Errno;
use nix::fcntl::{fcntl, FcntlArg, FdFlag};
use nix::sys::stat::{lstat, Mode, SFlag};
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
    #[error("binary {path}: stat-ing parent {dir}: {errno}")]
    ParentStat {
        path: PathBuf,
        dir: PathBuf,
        errno: Errno,
    },
    #[error("binary {path}: parent {dir} is not a directory only root can write")]
    UnsafeParent { path: PathBuf, dir: PathBuf },
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
        let safe = strict(bin)?;

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
        // The binary is handed on by path, so no one but root may be able to rewrite any
        // directory above it. Checked from `/` down: once a directory is vetted its entries
        // cannot be swapped, so the path cannot change under the checks that follow.
        let mut parents: Vec<&Path> = strict(bin)?.as_path().ancestors().skip(1).collect();
        parents.reverse();
        for dir in parents {
            root_only_writable(bin, dir)?;
        }
        RootSafeBin::<NAME>::open(bin)?;
        Ok(Self(bin.to_path_buf()))
    }

    pub fn as_path(&self) -> &Path {
        &self.0
    }
}

fn strict(bin: &Path) -> Result<&SafePath<IsAbsolute, StrictComponents>, RootSafeBinError> {
    bin.try_into().map_err(|source| RootSafeBinError::Path {
        path: bin.to_path_buf(),
        source,
    })
}

fn root_only_writable(bin: &Path, dir: &Path) -> Result<(), RootSafeBinError> {
    let stat = lstat(dir).map_err(|errno| RootSafeBinError::ParentStat {
        path: bin.to_path_buf(),
        dir: dir.to_path_buf(),
        errno,
    })?;
    let is_dir = stat.st_mode & SFlag::S_IFMT.bits() == SFlag::S_IFDIR.bits();
    let mode = Mode::from_bits_truncate(stat.st_mode);
    // In a sticky directory only root can rename or unlink a root-owned entry, and every entry
    // on the path must be root-owned, so a shared sticky directory (`/tmp`) is still safe.
    let shared = mode.intersects(Mode::S_IWGRP | Mode::S_IWOTH) && !mode.contains(Mode::S_ISVTX);
    if is_dir && stat.st_uid == 0 && !shared {
        Ok(())
    } else {
        Err(RootSafeBinError::UnsafeParent {
            path: bin.to_path_buf(),
            dir: dir.to_path_buf(),
        })
    }
}

#[cfg(test)]
mod tests {
    //! `RootSafeBin<NAME>` is what stops a configured path from pointing the helper at
    //! an attacker-controlled binary it would then run as root. The constructor demands
    //! an absolute path, exact basename, a real (non-symlink) regular file owned by
    //! root and not group/other-writable. These assert the refusal axes; the symlink
    //! axis is root-independent, the owner axis is asserted both ways.

    use super::{RootSafeBin, RootSafeBinError, RootSafeBinPathBuf};
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

    // `RootSafeBinPathBuf` hands the jailer a path, and the release flow leaves the install
    // directory owned by the node user, who could rename their own file over the vetted binary
    // after it was checked. Any directory on the path that someone other than root can rewrite
    // is refused, at any depth; a sticky one is not, since its root-owned entries stay put.
    #[rstest]
    #[case::root_0755(0o755, 0, true)]
    #[case::root_sticky_world_writable(0o1777, 0, true)]
    #[case::owned_by_another_user(0o755, 65_534, false)]
    #[case::group_writable(0o775, 0, false)]
    #[case::other_writable(0o757, 0, false)]
    fn path_binary_is_accepted_exactly_when_only_root_can_rewrite_its_parents_as_root(
        dir: TempDir,
        #[case] mode: u32,
        #[case] uid: u32,
        #[case] accepted: bool,
        #[values(0, 1)] depth: usize,
    ) {
        if !is_root() {
            eprintln!("SKIP path_binary_is_accepted_exactly_when_only_root_can_rewrite_its_parents_as_root");
            return;
        }
        let outer = dir.child("outer");
        let inner = outer.child("bin");
        inner.create_dir_all().unwrap();
        fs::set_permissions(&outer, fs::Permissions::from_mode(0o755)).unwrap();
        fs::set_permissions(&inner, fs::Permissions::from_mode(0o755)).unwrap();
        let bin = inner.child("dmsetup");
        bin.write_str("#!/bin/true\n").unwrap();
        fs::set_permissions(&bin, fs::Permissions::from_mode(0o755)).unwrap();
        let loose = [&outer, &inner][depth];
        std::os::unix::fs::chown(loose, Some(uid), None).unwrap();
        fs::set_permissions(loose, fs::Permissions::from_mode(mode)).unwrap();

        let got = RootSafeBinPathBuf::<"dmsetup">::open(&bin);

        if accepted {
            assert!(got.is_ok(), "{got:?}");
        } else {
            assert!(
                matches!(got, Err(RootSafeBinError::UnsafeParent { ref dir, .. }) if dir == loose.path()),
                "{got:?}"
            );
        }
    }
}
