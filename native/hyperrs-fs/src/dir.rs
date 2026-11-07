// SPDX-License-Identifier: MIT
//! Safe directory operations.

use super::dev::{DeviceNode, DeviceNumber};
use super::file::{
    Any, DeviceType, FileType, IsDirectory, OpenFlags, Owner, Ownership, SafeFile, ValidationError,
    Writability,
};
use super::path::{StrictComponent, StrictComponentBuf};
use nix::dir::{Dir, Type};
use nix::errno::Errno;
use nix::fcntl::{openat2, AtFlags, OFlag, OpenHow, ResolveFlag};
use nix::libc;
use nix::sys::stat::{fstat, mkdirat, mknodat, FileStat, Mode, SFlag};
use nix::unistd::{linkat, unlinkat, UnlinkatFlags};
use std::ffi::OsStr;
use std::io;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::io::{AsRawFd, FromRawFd, OwnedFd};
use std::path::Path;
use thiserror::Error as ThisError;

#[derive(Debug, ThisError)]
pub enum DirError {
    #[error(transparent)]
    Open(#[from] ValidationError),
    #[error(transparent)]
    Sys(#[from] Errno),
    #[error(transparent)]
    Io(#[from] io::Error),
    #[error("existing device node is {found}, expected {expected}")]
    DeviceMismatch {
        expected: DeviceNumber,
        found: DeviceNumber,
    },
}

impl DirError {
    /// The underlying errno.
    pub fn errno(&self) -> Option<Errno> {
        match self {
            DirError::Open(ValidationError::Open(errno) | ValidationError::Fstat(errno))
            | DirError::Sys(errno) => Some(*errno),
            DirError::Open(_) | DirError::Io(_) | DirError::DeviceMismatch { .. } => None,
        }
    }
}

/// See [`SafeFile<IsDirectory, R, O>`].
pub type SafeDir = SafeFile<IsDirectory, Any, Any>;

impl<R: Ownership, O: Writability> SafeFile<IsDirectory, R, O> {
    /// Open `name` relative to this directory and verify it as a [`SafeFile<T, R2, O2>`].
    pub fn openat<T: FileType, R2: Ownership, O2: Writability>(
        &self,
        name: impl AsRef<Path>,
        flags: OpenFlags,
        mode: Mode,
    ) -> Result<SafeFile<T, R2, O2>, ValidationError> {
        let how = OpenHow::new()
            .flags(OFlag::from(flags) | T::OPEN_FLAGS | OFlag::O_CLOEXEC)
            .mode(mode)
            .resolve(ResolveFlag::RESOLVE_NO_SYMLINKS | ResolveFlag::RESOLVE_BENEATH);
        let raw = openat2(self.as_raw_fd(), name.as_ref(), how).map_err(ValidationError::Open)?;
        // SAFETY: openat2 just handed us this fd; nobody else owns it.
        SafeFile::try_from(unsafe { OwnedFd::from_raw_fd(raw) })
    }

    /// Create file `name` in this directory, failing if it exists.
    pub fn mkfileat(
        &self,
        name: &StrictComponent,
        mode: Mode,
    ) -> Result<SafeFile<Any, Any, Any>, ValidationError> {
        self.openat(name, OpenFlags::WRONLY | OpenFlags::CREATE_NEW, mode)
    }

    /// Create a device file.
    pub fn mknodat(
        &self,
        name: &StrictComponent,
        kind: SFlag,
        mode: Mode,
        rdev: DeviceNumber,
    ) -> nix::Result<()> {
        mknodat(
            Some(self.as_raw_fd()),
            name.as_path(),
            kind,
            mode,
            rdev.into(),
        )
    }

    /// Create directory `name` in this directory with `mode`, tolerating `EEXIST`.
    pub fn mkdirat(&self, name: &StrictComponent, mode: Mode) -> nix::Result<()> {
        match mkdirat(Some(self.as_raw_fd()), name.as_path(), mode) {
            Ok(()) | Err(Errno::EEXIST) => Ok(()),
            Err(errno) => Err(errno),
        }
    }

    /// Hard link the `src` file into `name`.
    pub fn linkat<T, R2, O2>(
        &self,
        src: &SafeFile<T, R2, O2>,
        name: &StrictComponent,
    ) -> nix::Result<()> {
        linkat(
            Some(src.as_raw_fd()),
            Path::new(""),
            Some(self.as_raw_fd()),
            name.as_path(),
            AtFlags::AT_EMPTY_PATH,
        )
    }

    /// Create a directory `name` under this directory, with the given `mode`, if it does not exist.
    pub fn ensure_dir(&self, name: &StrictComponent, mode: Mode) -> Result<SafeDir, DirError> {
        self.mkdirat(name, mode)?;
        Ok(self.openat(name, OpenFlags::RDONLY, Mode::empty())?)
    }

    /// Create a device `name` under `self`, with the given `node` device type and the given
    /// `owner`.
    pub fn make_device<T: DeviceType>(
        &self,
        name: &StrictComponent,
        node: DeviceNode<T>,
        owner: Owner,
    ) -> Result<SafeFile<T, Any, Any>, DirError> {
        match self.mknodat(name, T::KIND, node.mode(), node.rdev()) {
            Ok(()) | Err(Errno::EEXIST) => {}
            Err(errno) => return Err(errno.into()),
        }

        let device: SafeFile<T, Any, Any> = self.openat(name, OpenFlags::PATH, Mode::empty())?;

        let found = device.rdev()?;
        if found != node.rdev() {
            return Err(DirError::DeviceMismatch {
                expected: node.rdev(),
                found,
            });
        }

        device.chown(Some(owner.uid), Some(owner.gid))?;
        device.chmod(node.mode())?;

        Ok(device)
    }

    /// Stat a file at the current directory.
    ///
    /// Note that this must remain private as this function is a footgun. It's very dangerous and
    /// risky to use this function as it causes an array of TOCTOU bugs.
    fn statat(&self, name: &StrictComponent) -> nix::Result<FileStat> {
        let how = OpenHow::new()
            .flags(OFlag::O_PATH | OFlag::O_NOFOLLOW | OFlag::O_CLOEXEC)
            .resolve(ResolveFlag::RESOLVE_NO_SYMLINKS | ResolveFlag::RESOLVE_BENEATH);
        let raw = openat2(self.as_raw_fd(), name.as_path(), how)?;
        // SAFETY: openat2 just handed us this fd; nobody else owns it.
        let fd = unsafe { OwnedFd::from_raw_fd(raw) };
        fstat(fd.as_raw_fd())
    }

    /// Remove the non-directory entry `name` from this directory.
    pub fn unlinkat(&self, name: &StrictComponent) -> nix::Result<()> {
        unlinkat(
            Some(self.as_raw_fd()),
            name.as_path(),
            UnlinkatFlags::NoRemoveDir,
        )
    }

    /// Remove the empty child directory `name` from this directory.
    pub fn rmdirat(&self, name: &StrictComponent) -> nix::Result<()> {
        unlinkat(
            Some(self.as_raw_fd()),
            name.as_path(),
            UnlinkatFlags::RemoveDir,
        )
    }

    /// Recursively, without following symlinks, remove child `name` and everything under it.
    pub fn rmdirat_recursive(&self, name: &StrictComponent) -> Result<(), DirError> {
        let child: SafeDir = self.openat(name, OpenFlags::RDONLY, Mode::empty())?;
        let entries = child.entries()?.collect::<nix::Result<Vec<_>>>()?;
        for (entry, ty) in entries {
            match ty {
                Type::Directory => child.rmdirat_recursive(&entry)?,
                _ => child.unlinkat(&entry)?,
            }
        }
        Ok(self.rmdirat(name)?)
    }

    /// Get an iterator through all the entries in this directory.
    pub fn entries(
        &self,
    ) -> Result<impl Iterator<Item = nix::Result<(StrictComponentBuf, Type)>> + '_, DirError> {
        let fresh: SafeDir = self.openat(Path::new("."), OpenFlags::RDONLY, Mode::empty())?;

        Ok(Dir::from(OwnedFd::from(fresh))?
            .into_iter()
            .filter_map(move |entry| {
                let entry = match entry {
                    Ok(entry) => entry,
                    Err(errno) => return Some(Err(errno)),
                };

                let bytes = entry.file_name().to_bytes();
                if bytes == b"." || bytes == b".." {
                    return None;
                }

                let name: &StrictComponent = match OsStr::from_bytes(bytes).try_into() {
                    Ok(name) => name,
                    Err(_) => return Some(Err(Errno::EINVAL)),
                };
                let ty = match entry.file_type() {
                    Some(ty) => Ok(ty),
                    None => self
                        .statat(name)
                        .and_then(|stat| match stat.st_mode & libc::S_IFMT {
                            libc::S_IFDIR => Ok(Type::Directory),
                            libc::S_IFREG => Ok(Type::File),
                            libc::S_IFLNK => Ok(Type::Symlink),
                            libc::S_IFBLK => Ok(Type::BlockDevice),
                            libc::S_IFCHR => Ok(Type::CharacterDevice),
                            libc::S_IFIFO => Ok(Type::Fifo),
                            libc::S_IFSOCK => Ok(Type::Socket),
                            _ => Err(Errno::EINVAL),
                        }),
                };

                Some(ty.map(|ty| (name.to_owned(), ty)))
            }))
    }
}

#[cfg(test)]
mod tests {
    use super::SafeDir;
    use crate::file::{Any, IsRegularFile, OpenFlags, ValidationError};
    use crate::path::{IsAbsolute, SafePathBuf, StrictComponent, StrictComponents};
    use assert_fs::prelude::*;
    use assert_fs::TempDir;
    use nix::dir::Type;
    use nix::errno::Errno;
    use nix::sys::stat::Mode;
    use predicates::prelude::*;
    use pretty_assertions::assert_eq;
    use rstest::{fixture, rstest};
    use std::assert_matches;
    use std::collections::BTreeMap;
    use std::ffi::OsString;
    use std::os::unix::net::UnixListener;
    use std::path::{Path, PathBuf};

    type Strict = SafePathBuf<IsAbsolute, StrictComponents>;

    fn safe(p: &Path) -> Strict {
        p.to_path_buf()
            .try_into()
            .expect("test path must be strict-absolute")
    }

    fn open(p: &Path) -> SafeDir {
        SafeDir::open(&safe(p), OpenFlags::RDONLY).unwrap()
    }

    #[fixture]
    fn tmp() -> TempDir {
        TempDir::new().unwrap()
    }

    struct Anchored {
        tmp: TempDir,
        anchor: SafeDir,
    }

    #[fixture]
    fn anchored(tmp: TempDir) -> Anchored {
        tmp.child("outside").write_str("x").unwrap();
        let anchor_dir = tmp.child("anchor");
        anchor_dir.child("real/f").write_str("x").unwrap();
        anchor_dir
            .child("link")
            .symlink_to_dir(anchor_dir.child("real"))
            .unwrap();
        Anchored {
            anchor: open(&anchor_dir),
            tmp,
        }
    }

    #[rstest]
    fn rmdirat_recursive_does_not_follow_symlinks_out_of_tree(tmp: TempDir) {
        let sentinel = tmp.child("sentinel");
        sentinel
            .child("keep.txt")
            .write_str("do not delete me")
            .unwrap();

        let tree = tmp.child("tree");
        tree.child("a.txt").write_str("x").unwrap();
        tree.child("escape").symlink_to_dir(&sentinel).unwrap();

        open(tmp.path())
            .rmdirat_recursive(StrictComponent::from_static("tree"))
            .unwrap();

        tree.assert(predicate::path::missing());
        sentinel.assert(predicate::path::is_dir());
        sentinel.child("keep.txt").assert("do not delete me");
    }

    #[rstest]
    #[case::parent_traversal(|_: &Path| PathBuf::from("../outside"), Errno::EXDEV)]
    #[case::absolute(|tmp: &Path| tmp.join("outside"), Errno::EXDEV)]
    #[case::symlinked_component(|_: &Path| PathBuf::from("link/f"), Errno::ELOOP)]
    #[case::missing(|_: &Path| PathBuf::from("missing"), Errno::ENOENT)]
    fn openat_refuses_escape_and_symlinked_components(
        anchored: Anchored,
        #[case] name: fn(&Path) -> PathBuf,
        #[case] expected: Errno,
    ) {
        let name = name(anchored.tmp.path());
        assert_matches!(
            anchored
                .anchor
                .openat::<Any, Any, Any>(&name, OpenFlags::PATH, Mode::empty()),
            Err(ValidationError::Open(errno)) if errno == expected,
            "{name:?}"
        );
    }

    #[rstest]
    fn openat_opens_a_file_below_the_anchor(anchored: Anchored) {
        assert!(anchored
            .anchor
            .openat::<IsRegularFile, Any, Any>(Path::new("real/f"), OpenFlags::PATH, Mode::empty())
            .is_ok());
    }

    #[rstest]
    fn rmdirat_recursive_clears_nested_tree(tmp: TempDir) {
        let tree = tmp.child("tree");
        tree.child("a/b/c/deep.txt").write_str("x").unwrap();
        tree.child("a/top.txt").write_str("y").unwrap();

        open(tmp.path())
            .rmdirat_recursive(StrictComponent::from_static("tree"))
            .unwrap();
        tree.assert(predicate::path::missing());
    }

    #[rstest]
    fn entries_reports_each_child_with_its_own_type(tmp: TempDir) {
        tmp.child("file").touch().unwrap();
        tmp.child("dir").create_dir_all().unwrap();
        tmp.child("link").symlink_to_dir(tmp.child("dir")).unwrap();
        let _sock = UnixListener::bind(tmp.child("sock")).unwrap();

        let got: BTreeMap<OsString, Type> = open(tmp.path())
            .entries()
            .unwrap()
            .map(|entry| entry.map(|(name, ty)| (name.as_os_str().to_os_string(), ty)))
            .collect::<nix::Result<_>>()
            .unwrap();

        let want = BTreeMap::from([
            (OsString::from("dir"), Type::Directory),
            (OsString::from("file"), Type::File),
            (OsString::from("link"), Type::Symlink),
            (OsString::from("sock"), Type::Socket),
        ]);
        assert_eq!(got, want);
    }
}
