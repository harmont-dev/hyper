// SPDX-License-Identifier: MIT
//! Safe directory operations.

use super::file::{
    Any, FileType, IsDirectory, OpenFlags, Ownership, SafeFile, ValidationError, Writability,
};
use nix::dir::{Dir, Type};
use nix::errno::Errno;
use nix::fcntl::{openat2, AtFlags, OFlag, OpenHow, ResolveFlag};
use nix::libc::{self, dev_t};
use nix::sys::stat::{fchmodat, fstat, mkdirat, mknodat, FchmodatFlags, FileStat, Mode, SFlag};
use nix::unistd::{fchownat, linkat, unlinkat, Gid, Uid, UnlinkatFlags};
use std::ffi::{OsStr, OsString};
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
}

impl Error {
    /// The underlying errno, for callers that treat some failures as success
    /// (e.g. idempotent removal on `ENOENT`).
    pub fn errno(&self) -> Option<Errno> {
        match self {
            Error::Open(ValidationError::Open(errno) | ValidationError::Fstat(errno))
            | Error::Sys(errno) => Some(*errno),
            Error::Open(_) => None,
        }
    }
}

/// See [`SafeFile<IsDirectory, R, O>`].
pub type SafeDir = SafeFile<IsDirectory, Any, Any>;

impl<R: Ownership, O: Writability> SafeFile<IsDirectory, R, O> {
    /// Open `name` relative to this directory and verify it as a [`SafeFile<T, R2, O2>`].
    pub fn openat<T: FileType, R2: Ownership, O2: Writability>(
        &self,
        name: &Path,
        flags: OpenFlags,
        mode: Mode,
    ) -> Result<SafeFile<T, R2, O2>, ValidationError> {
        let how = OpenHow::new()
            .flags(flags.0 | T::OPEN_FLAGS | OFlag::O_CLOEXEC)
            .mode(mode)
            .resolve(ResolveFlag::RESOLVE_NO_SYMLINKS | ResolveFlag::RESOLVE_BENEATH);
        let raw = openat2(self.as_raw_fd(), name, how).map_err(ValidationError::Open)?;
        // SAFETY: openat2 just handed us this fd; nobody else owns it.
        SafeFile::try_from(unsafe { OwnedFd::from_raw_fd(raw) })
    }

    /// Create file `name` in this directory, failing if it exists.
    pub fn mkfileat(
        &self,
        name: &Path,
        mode: Mode,
    ) -> Result<SafeFile<Any, Any, Any>, ValidationError> {
        self.openat(name, OpenFlags::WRONLY | OpenFlags::CREATE_NEW, mode)
    }

    /// Create a device file.
    pub fn mknodat(&self, name: &Path, kind: SFlag, mode: Mode, rdev: dev_t) -> nix::Result<()> {
        mknodat(Some(self.as_raw_fd()), name, kind, mode, rdev)
    }

    /// Create directory `name` in this directory with `mode`, tolerating `EEXIST`.
    pub fn mkdirat(&self, name: &Path, mode: Mode) -> nix::Result<()> {
        match mkdirat(Some(self.as_raw_fd()), name, mode) {
            Ok(()) | Err(Errno::EEXIST) => Ok(()),
            Err(errno) => Err(errno),
        }
    }

    /// Hard link the `src` file into `name`.
    pub fn linkat<T, R2, O2>(&self, src: &SafeFile<T, R2, O2>, name: &Path) -> nix::Result<()> {
        linkat(
            Some(src.as_raw_fd()),
            Path::new(""),
            Some(self.as_raw_fd()),
            name,
            AtFlags::AT_EMPTY_PATH,
        )
    }

    /// `chown` entry `name` to `uid:gid` without following a final symlink.
    pub fn chownat(&self, name: &Path, uid: u32, gid: u32) -> nix::Result<()> {
        fchownat(
            Some(self.as_raw_fd()),
            name,
            Some(Uid::from_raw(uid)),
            Some(Gid::from_raw(gid)),
            AtFlags::AT_SYMLINK_NOFOLLOW,
        )
    }

    /// Stat a file at the current directory.
    ///
    /// Note that this must remain private as this function is a footgun. It's very dangerous and
    /// risky to use this function as it causes an array of TOCTOU bugs.
    fn statat(&self, name: &Path) -> nix::Result<FileStat> {
        let how = OpenHow::new()
            .flags(OFlag::O_PATH | OFlag::O_NOFOLLOW | OFlag::O_CLOEXEC)
            .resolve(ResolveFlag::RESOLVE_NO_SYMLINKS | ResolveFlag::RESOLVE_BENEATH);
        let raw = openat2(self.as_raw_fd(), name, how)?;
        // SAFETY: openat2 just handed us this fd; nobody else owns it.
        let fd = unsafe { OwnedFd::from_raw_fd(raw) };
        fstat(fd.as_raw_fd())
    }

    /// Remove the non-directory entry `name` from this directory.
    pub fn unlinkat(&self, name: &Path) -> nix::Result<()> {
        unlinkat(Some(self.as_raw_fd()), name, UnlinkatFlags::NoRemoveDir)
    }

    /// Remove the empty child directory `name` from this directory.
    pub fn rmdirat(&self, name: &Path) -> nix::Result<()> {
        unlinkat(Some(self.as_raw_fd()), name, UnlinkatFlags::RemoveDir)
    }

    /// Recursively, without following symlinks, remove child `name` and everything under it.
    pub fn rmdirat_recursive(&self, name: &Path) -> Result<(), Error> {
        let child: SafeDir = self.openat(name, OpenFlags::RDONLY, Mode::empty())?;
        let entries = child.entries()?.collect::<nix::Result<Vec<_>>>()?;
        for (entry, ty) in entries {
            match ty {
                Type::Directory => child.rmdirat_recursive(Path::new(&entry))?,
                _ => child.unlinkat(Path::new(&entry))?,
            }
        }
        Ok(self.rmdirat(name)?)
    }

    /// Get an iterator through all the entries in this directory.
    pub fn entries(
        &self,
    ) -> Result<impl Iterator<Item = nix::Result<(OsString, Type)>> + '_, Error> {
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

                let name = OsStr::from_bytes(bytes).to_os_string();
                let ty = match entry.file_type() {
                    Some(ty) => Ok(ty),
                    None => self.statat(Path::new(&name)).and_then(|stat| {
                        match stat.st_mode & libc::S_IFMT {
                            libc::S_IFDIR => Ok(Type::Directory),
                            libc::S_IFREG => Ok(Type::File),
                            libc::S_IFLNK => Ok(Type::Symlink),
                            libc::S_IFBLK => Ok(Type::BlockDevice),
                            libc::S_IFCHR => Ok(Type::CharacterDevice),
                            libc::S_IFIFO => Ok(Type::Fifo),
                            libc::S_IFSOCK => Ok(Type::Socket),
                            _ => Err(Errno::EINVAL),
                        }
                    }),
                };

                Some(ty.map(|ty| (name, ty)))
            }))
    }
}
