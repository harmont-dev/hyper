//! Utilities for interacting with binaries.
use hyperrs_fs::dir::ParentError;
use hyperrs_fs::file::{
    self, IsDirectory, IsRegularFile, OpenFlags, OwnerOnlyWritable, RootOwner, SafeFile,
    StickyOrOwnerOnlyWritable,
};
use hyperrs_fs::path::{IsAbsolute, SafePath, StrictComponent, StrictComponents};
use nix::errno::Errno;
use nix::fcntl::{fcntl, FcntlArg, FdFlag};
use std::os::unix::io::{AsFd, AsRawFd, BorrowedFd};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use thiserror::Error as ThisError;

#[derive(Debug, ThisError)]
#[error("binary {path}: {kind}")]
pub struct RootSafeBinError {
    pub path: PathBuf,
    #[source]
    pub kind: RootSafeBinErrorKind,
}

#[derive(Debug, ThisError)]
pub enum RootSafeBinErrorKind {
    #[error("basename must be `{0}`")]
    Name(&'static str),
    #[error(transparent)]
    File(#[from] file::ValidationError),
    #[error("clearing FD_CLOEXEC: {0}")]
    Inherit(#[from] Errno),
    #[error(transparent)]
    Parent(#[from] ParentError),
}

type Executable = SafeFile<IsRegularFile, RootOwner, OwnerOnlyWritable>;
type RootOnlyDir = SafeFile<IsDirectory, RootOwner, StickyOrOwnerOnlyWritable>;

/// A binary that's safe for the root user to use.
#[derive(Debug)]
pub struct RootSafeBin<const NAME: &'static str>(Executable);

#[derive(Debug, Clone)]
pub struct RootSafeBinPathBuf<const NAME: &'static str>(PathBuf);

impl<const NAME: &'static str> RootSafeBin<NAME> {
    /// Validate that the given path is a safe binary, owned by root, non-symlink, not writable by
    /// everyone and matches `NAME`.
    pub fn open(bin: &SafePath<IsAbsolute, StrictComponents>) -> Result<Self, RootSafeBinError> {
        Self::vet(bin).map_err(|kind| RootSafeBinError {
            path: bin.as_path().to_path_buf(),
            kind,
        })
    }

    fn vet(bin: &SafePath<IsAbsolute, StrictComponents>) -> Result<Self, RootSafeBinErrorKind> {
        if bin.file_name() != Some(const { StrictComponent::from_static(NAME) }) {
            return Err(RootSafeBinErrorKind::Name(NAME));
        }
        let file = Executable::open(bin, OpenFlags::PATH)?;
        fcntl(file.as_raw_fd(), FcntlArg::F_SETFD(FdFlag::empty()))?;
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
    pub fn open(bin: &SafePath<IsAbsolute, StrictComponents>) -> Result<Self, RootSafeBinError> {
        Self::vet(bin).map_err(|kind| RootSafeBinError {
            path: bin.as_path().to_path_buf(),
            kind,
        })
    }

    fn vet(bin: &SafePath<IsAbsolute, StrictComponents>) -> Result<Self, RootSafeBinErrorKind> {
        // The binary is handed on by path, so no one but root may be able to rewrite any
        // directory above it.
        RootOnlyDir::open_parent(bin)?;
        RootSafeBin::<NAME>::vet(bin)?;
        Ok(Self(bin.as_path().to_path_buf()))
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

    use super::{RootSafeBin, RootSafeBinError, RootSafeBinErrorKind, RootSafeBinPathBuf};
    use assert_fs::prelude::*;
    use assert_fs::TempDir;
    use hyperrs_fs::dir::ParentError;
    use hyperrs_fs::file::ValidationError::{self, GroupOrOtherWritable, NotRootOwned};
    use hyperrs_fs::path::SafePath;
    use rstest::{fixture, rstest};
    use std::fs;
    use std::mem::discriminant;
    use std::os::unix::fs::PermissionsExt;
    use std::path::PathBuf;

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

    #[test]
    fn rejects_wrong_basename() {
        let got = RootSafeBin::<"dmsetup">::open(SafePath::from_static::<"/usr/bin/env">());
        assert!(
            matches!(
                got,
                Err(RootSafeBinError {
                    kind: RootSafeBinErrorKind::Name("dmsetup"),
                    ..
                })
            ),
            "{got:?}"
        );
    }

    #[rstest]
    fn rejects_symlink_with_correct_basename(dir: TempDir) {
        let target = dir.child("target");
        target.write_str("x").unwrap();
        let link = dir.child("dmsetup");
        link.symlink_to_file(&target).unwrap();
        // Symlink is checked before ownership, so this holds regardless of who runs it.
        assert!(RootSafeBin::<"dmsetup">::open(link.path().try_into().unwrap()).is_err());
    }

    #[rstest]
    fn owner_axis_root_owned_accepted_else_rejected(dir: TempDir) {
        let bin = dmsetup_with_mode(&dir, 0o755);
        let got = RootSafeBin::<"dmsetup">::open(bin.as_path().try_into().unwrap());
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
            let bin = dmsetup_with_mode(&dir, 0o757);
            assert!(RootSafeBin::<"dmsetup">::open(bin.as_path().try_into().unwrap()).is_err());
        } else {
            eprintln!("SKIP rejects_group_or_other_writable: needs root to own a 0757 file");
        }
    }

    // `/` is a root-owned 0755 directory and `/tmp` a root-owned sticky world-writable one, so
    // both must be passed and the walk must stop at the first directory the caller owns.
    #[test]
    fn path_binary_is_refused_at_the_first_parent_owned_by_someone_other_than_root() {
        let tmp = TempDir::new_in("/tmp").unwrap();
        let bin = tmp.child("dmsetup");
        bin.write_str("#!/bin/true\n").unwrap();
        fs::set_permissions(&bin, fs::Permissions::from_mode(0o755)).unwrap();
        if is_root() {
            std::os::unix::fs::chown(tmp.path(), Some(65_534), None).unwrap();
        }

        let got = RootSafeBinPathBuf::<"dmsetup">::open(bin.path().try_into().unwrap());

        assert!(
            matches!(got, Err(RootSafeBinError { kind: RootSafeBinErrorKind::Parent(ParentError { ref dir, source: NotRootOwned }), .. }) if dir == tmp.path()),
            "{got:?}"
        );
    }

    // `RootSafeBinPathBuf` hands the jailer a path, and the release flow leaves the install
    // directory owned by the node user, who could rename their own file over the vetted binary
    // after it was checked. Any directory on the path that someone other than root can rewrite
    // is refused, at any depth; a sticky one is not, since its root-owned entries stay put.
    #[rstest]
    #[case::root_0755(0o755, 0, None)]
    #[case::root_sticky_world_writable(0o1777, 0, None)]
    #[case::owned_by_another_user(0o755, 65_534, Some(NotRootOwned))]
    #[case::group_writable(0o775, 0, Some(GroupOrOtherWritable))]
    #[case::other_writable(0o757, 0, Some(GroupOrOtherWritable))]
    fn path_binary_is_accepted_exactly_when_only_root_can_rewrite_its_parents_as_root(
        dir: TempDir,
        #[case] mode: u32,
        #[case] uid: u32,
        #[case] refusal: Option<ValidationError>,
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

        let got = RootSafeBinPathBuf::<"dmsetup">::open(bin.path().try_into().unwrap());

        match refusal {
            None => assert!(got.is_ok(), "{got:?}"),
            Some(want) => assert!(
                matches!(got, Err(RootSafeBinError { kind: RootSafeBinErrorKind::Parent(ParentError { ref dir, source }), .. })
                    if dir == loose.path() && discriminant(&source) == discriminant(&want)),
                "{got:?}"
            ),
        }
    }
}
