// SPDX-License-Identifier: MIT
//! Typesafer file descriptors.

use super::path::{IsAbsolute, SafePath, StrictComponents};
use derive_more::{BitOr, Into};
use nix::fcntl::{openat2, AtFlags, OFlag, OpenHow, ResolveFlag};
use nix::libc::{dev_t, AT_FDCWD};
use nix::sys::stat::{
    fchmodat, fstat, major, makedev, minor, FchmodatFlags, FileStat, Mode, SFlag,
};
use nix::unistd::{dup, fchownat, Gid, Uid};
use std::io;
use std::marker::PhantomData;
use std::os::unix::io::{AsFd, AsRawFd, BorrowedFd, FromRawFd, OwnedFd, RawFd};
use std::path::PathBuf;
use thiserror::Error as ThisError;

const SECTOR_BYTES: u64 = 512;

mod ioctl {
    nix::ioctl_read_bad!(
        blkgetsize64,
        nix::request_code_read!(0x12, 114, std::mem::size_of::<usize>()),
        u64
    );
}

/// The single error type shared by every `SafeFile` flavor. A given flavor only ever yields the
/// variants for the axes it actually enforces.
#[derive(Debug, Clone, Copy, ThisError)]
pub enum ValidationError {
    #[error("open failed: {0}")]
    Open(#[source] nix::Error),
    #[error("file is not of the required type")]
    WrongFileType,
    #[error("file is not owned by root:root")]
    NotRootOwned,
    #[error("file is writable by group or other")]
    GroupOrOtherWritable,
    #[error("fstat failed: {0}")]
    Fstat(#[source] nix::Error),
}

/// The universal "axis off" marker: implements every axis trait as a no-op.
pub struct Any;

/// File must be a regular file.
pub struct IsRegularFile;
/// File must be a block device.
pub struct IsBlockDevice;
/// File must be a char device.
pub struct IsCharDevice;
/// File must be a socket device.
pub struct IsSocket;
/// File must be a directory.
pub struct IsDirectory;
/// Require `root:root` owner (uid 0, gid 0).
pub struct RootOwner;
/// Require the file not be writable by group or other.
pub struct OwnerOnlyWritable;

/// What's the type of the file?
pub trait FileType {
    const OPEN_FLAGS: OFlag = OFlag::empty();

    fn check(stat: &FileStat) -> Result<(), ValidationError>;
}

/// Who owns the file?
pub trait Ownership {
    fn check(stat: &FileStat) -> Result<(), ValidationError>;
}

/// Is the file writable?
pub trait Writability {
    fn check(stat: &FileStat) -> Result<(), ValidationError>;
}

impl FileType for Any {
    fn check(_: &FileStat) -> Result<(), ValidationError> {
        Ok(())
    }
}

impl Ownership for Any {
    fn check(_: &FileStat) -> Result<(), ValidationError> {
        Ok(())
    }
}

impl Writability for Any {
    fn check(_: &FileStat) -> Result<(), ValidationError> {
        Ok(())
    }
}

impl FileType for IsRegularFile {
    fn check(stat: &FileStat) -> Result<(), ValidationError> {
        if stat.st_mode & SFlag::S_IFMT.bits() == SFlag::S_IFREG.bits() {
            Ok(())
        } else {
            Err(ValidationError::WrongFileType)
        }
    }
}

impl FileType for IsBlockDevice {
    fn check(stat: &FileStat) -> Result<(), ValidationError> {
        if stat.st_mode & SFlag::S_IFMT.bits() == SFlag::S_IFBLK.bits() {
            Ok(())
        } else {
            Err(ValidationError::WrongFileType)
        }
    }
}

impl FileType for IsCharDevice {
    fn check(stat: &FileStat) -> Result<(), ValidationError> {
        if stat.st_mode & SFlag::S_IFMT.bits() == SFlag::S_IFCHR.bits() {
            Ok(())
        } else {
            Err(ValidationError::WrongFileType)
        }
    }
}

impl FileType for IsSocket {
    fn check(stat: &FileStat) -> Result<(), ValidationError> {
        if stat.st_mode & SFlag::S_IFMT.bits() == SFlag::S_IFSOCK.bits() {
            Ok(())
        } else {
            Err(ValidationError::WrongFileType)
        }
    }
}

impl FileType for IsDirectory {
    const OPEN_FLAGS: OFlag = OFlag::O_DIRECTORY;

    fn check(stat: &FileStat) -> Result<(), ValidationError> {
        if stat.st_mode & SFlag::S_IFMT.bits() == SFlag::S_IFDIR.bits() {
            Ok(())
        } else {
            Err(ValidationError::WrongFileType)
        }
    }
}

impl Ownership for RootOwner {
    fn check(stat: &FileStat) -> Result<(), ValidationError> {
        if stat.st_uid == 0 && stat.st_gid == 0 {
            Ok(())
        } else {
            Err(ValidationError::NotRootOwned)
        }
    }
}

impl Writability for OwnerOnlyWritable {
    fn check(stat: &FileStat) -> Result<(), ValidationError> {
        if stat.st_mode & 0o022 == 0 {
            Ok(())
        } else {
            Err(ValidationError::GroupOrOtherWritable)
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, BitOr, Into)]
pub struct OpenFlags(OFlag);

impl OpenFlags {
    pub const RDONLY: Self = Self(OFlag::O_RDONLY);
    pub const WRONLY: Self = Self(OFlag::O_WRONLY);
    pub const RDWR: Self = Self(OFlag::O_RDWR);
    pub const PATH: Self = Self(OFlag::O_PATH);
    pub const TRUNC: Self = Self(OFlag::O_TRUNC);
    pub const CREATE_NEW: Self = Self(OFlag::O_CREAT.union(OFlag::O_EXCL));
}

/// An [`OwnedFd`] with compile-time refinements.
#[derive(derive_more::Debug, Into)]
pub struct SafeFile<T, R, O>(
    OwnedFd,
    #[debug(skip)]
    #[into(skip)]
    PhantomData<(T, R, O)>,
);

impl<T, R, O> SafeFile<T, R, O> {
    pub fn try_clone(&self) -> io::Result<Self> {
        Ok(Self(self.0.try_clone()?, PhantomData))
    }

    pub fn inheritable(&self) -> nix::Result<OwnedFd> {
        let raw = dup(self.0.as_raw_fd())?;
        // SAFETY: `dup` just returned this fd and nothing else owns it.
        Ok(unsafe { OwnedFd::from_raw_fd(raw) })
    }

    pub fn chmod(&self, mode: Mode) -> nix::Result<()> {
        let path = PathBuf::from(format!("/proc/self/fd/{}", self.0.as_raw_fd()));
        // The FollowSymlink here is necessary because glibc can't not follow symlinks
        fchmodat(None, &path, mode, FchmodatFlags::FollowSymlink)
    }

    pub fn chown(&self, owner: Option<Uid>, group: Option<Gid>) -> nix::Result<()> {
        fchownat(
            Some(self.0.as_raw_fd()),
            "",
            owner,
            group,
            AtFlags::AT_EMPTY_PATH,
        )
    }
}

impl<R, O> SafeFile<IsBlockDevice, R, O> {
    /// The device's `rdev` (major:minor), ready for `mknod`.
    pub fn rdev(&self) -> Result<dev_t, ValidationError> {
        let stat = fstat(self.0.as_raw_fd()).map_err(ValidationError::Fstat)?;
        Ok(makedev(major(stat.st_rdev), minor(stat.st_rdev)))
    }

    pub fn size(&self) -> nix::Result<u64> {
        let mut bytes = 0u64;
        // SAFETY: BLKGETSIZE64 writes exactly one u64 through the pointer.
        unsafe { ioctl::blkgetsize64(self.0.as_raw_fd(), &mut bytes) }?;
        Ok(bytes)
    }

    pub fn sectors(&self) -> nix::Result<u64> {
        Ok(self.size()? / SECTOR_BYTES)
    }
}

impl<T, R, O> SafeFile<T, R, O>
where
    T: FileType,
    R: Ownership,
    O: Writability,
{
    /// Open `path` and verify it against the type traits.
    pub fn open(
        path: &SafePath<IsAbsolute, StrictComponents>,
        flags: OpenFlags,
    ) -> Result<Self, ValidationError> {
        let how = OpenHow::new()
            .flags(flags.0 | T::OPEN_FLAGS | OFlag::O_CLOEXEC)
            .resolve(ResolveFlag::RESOLVE_NO_SYMLINKS);
        let raw = openat2(AT_FDCWD, path.as_ref(), how).map_err(ValidationError::Open)?;
        // SAFETY: `openat2` just handed us this fd; nobody else owns it.
        let owned = unsafe { OwnedFd::from_raw_fd(raw) };

        Self::try_from(owned)
    }
}

impl<T, R, O> io::Write for SafeFile<T, R, O> {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        Ok(nix::unistd::write(&self.0, buf)?)
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

impl<T, R, O> AsFd for SafeFile<T, R, O> {
    fn as_fd(&self) -> BorrowedFd<'_> {
        self.0.as_fd()
    }
}

impl<T, R, O> AsRawFd for SafeFile<T, R, O> {
    fn as_raw_fd(&self) -> RawFd {
        self.0.as_raw_fd()
    }
}

impl<T, R, O> TryFrom<OwnedFd> for SafeFile<T, R, O>
where
    T: FileType,
    R: Ownership,
    O: Writability,
{
    type Error = ValidationError;

    fn try_from(fd: OwnedFd) -> Result<Self, Self::Error> {
        let stat = fstat(fd.as_raw_fd()).map_err(ValidationError::Fstat)?;
        T::check(&stat)?;
        R::check(&stat)?;
        O::check(&stat)?;
        Ok(Self(fd, PhantomData))
    }
}
