// SPDX-License-Identifier: MIT
//! Safe directory operations.

use super::dev::{DeviceNode, DeviceNumber};
use super::file::{
    Any, DeviceType, FileType, IsDirectory, IsRegularFile, OpenFlags, Owner, Ownership, SafeFile,
    ValidationError, Writability,
};
use super::path::{StrictComponent, StrictComponentBuf};
use nix::dir::{Dir, Type};
use nix::errno::Errno;
use nix::fcntl::{openat2, AtFlags, OFlag, OpenHow, ResolveFlag};
use nix::libc;
use nix::sys::stat::{fstat, mkdirat, mknodat, FileStat, Mode, SFlag};
use nix::unistd::{linkat, unlinkat, UnlinkatFlags};
use std::ffi::OsStr;
use std::fs::File;
use std::io;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::io::{AsRawFd, FromRawFd, OwnedFd};
use std::path::Path;
use thiserror::Error as ThisError;

/// Failure of an operation that both opens (verifying the result) and makes
/// further syscalls: [`SafeDir::write_file`] and [`SafeDir::remove_dir_all`].
/// Every other operation returns [`ValidationError`] (opens) or
/// [`nix::Error`] (plain syscalls) directly.
#[derive(Debug, ThisError)]
pub enum Error {
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

impl Error {
    /// The underlying errno, for callers that treat some failures as success
    /// (e.g. idempotent removal on `ENOENT`).
    pub fn errno(&self) -> Option<Errno> {
        match self {
            Error::Open(ValidationError::Open(errno) | ValidationError::Fstat(errno))
            | Error::Sys(errno) => Some(*errno),
            Error::Open(_) | Error::Io(_) | Error::DeviceMismatch { .. } => None,
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

    pub fn ensure_dir(&self, name: &StrictComponent, mode: Mode) -> Result<SafeDir, Error> {
        self.mkdirat(name, mode)?;
        Ok(self.openat(name, OpenFlags::RDONLY, Mode::empty())?)
    }

    pub fn make_device<T: DeviceType>(
        &self,
        name: &StrictComponent,
        node: DeviceNode<T>,
        owner: Owner,
    ) -> Result<SafeFile<T, Any, Any>, Error> {
        match self.mknodat(name, T::KIND, node.mode(), node.rdev()) {
            Ok(()) | Err(Errno::EEXIST) => {}
            Err(errno) => return Err(errno.into()),
        }
        let device: SafeFile<T, Any, Any> = self.openat(name, OpenFlags::PATH, Mode::empty())?;
        let found = device.rdev()?;
        if found != node.rdev() {
            return Err(Error::DeviceMismatch {
                expected: node.rdev(),
                found,
            });
        }
        device.chown(Some(owner.uid), Some(owner.gid))?;
        device.chmod(node.mode())?;
        Ok(device)
    }

    pub fn link_or_copy<R2, O2>(
        &self,
        src: SafeFile<IsRegularFile, R2, O2>,
        name: &StrictComponent,
        copy_mode: Mode,
    ) -> Result<(), Error> {
        match self.linkat(&src, name) {
            Ok(()) => Ok(()),
            Err(Errno::EXDEV) => {
                let dest = self.mkfileat(name, copy_mode)?;
                io::copy(
                    &mut File::from(OwnedFd::from(src)),
                    &mut File::from(OwnedFd::from(dest)),
                )?;
                Ok(())
            }
            Err(errno) => Err(errno.into()),
        }
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
    pub fn rmdirat_recursive(&self, name: &StrictComponent) -> Result<(), Error> {
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
    ) -> Result<impl Iterator<Item = nix::Result<(StrictComponentBuf, Type)>> + '_, Error> {
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
