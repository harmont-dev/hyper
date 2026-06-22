// SPDX-License-Identifier: AGPL-3.0-only
//! Typestate-validated file descriptors.
//!
//! A [`SafeFile`] owns an open fd (closing it on drop, never before) and proves,
//! in its type, which `fstat`-verified properties that fd has. It is the fd half
//! of the safety story: once a name is resolved to a descriptor, the descriptor
//! is what you verify and operate through, immune to the by-name
//! time-of-check/time-of-use races - the checks ride the same fd you go on to
//! use.
//!
//! Each type parameter is an independent axis (file type, ownership, mode); the
//! marker in each slot says whether it is enforced, and [`Any`] turns an axis
//! off. Verification happens once, in `TryFrom<OwnedFd>`, sharing a single
//! `fstat`. Existence is NOT an axis: a `SafeFile` holds an open fd, so the file
//! provably exists by construction.

use super::safe_path::SafePath;
use nix::fcntl::{open as nix_open, OFlag};
use nix::sys::stat::{fstat, FileStat, Mode, SFlag};
use std::marker::PhantomData;
use std::os::unix::io::{AsFd, AsRawFd, BorrowedFd, FromRawFd, OwnedFd, RawFd};
use thiserror::Error as ThisError;

/// The single error type shared by every `SafeFile` flavor. A given flavor only
/// ever yields the variants for the axes it actually enforces.
#[derive(Debug, ThisError)]
pub enum ValidationError {
    #[error("open failed: {0}")]
    Open(#[source] nix::Error),
    #[error("file is not of the required type")]
    WrongFileType,
    #[error("file is not owned by root:root")]
    NotRootOwned,
    #[error("file is writable by group or other")]
    NonRootWritable,
    #[error("fstat failed: {0}")]
    Fstat(#[source] nix::Error),
}

/// The universal "axis off" marker: implements every axis trait as a no-op.
pub struct Any;

/// File-type axis: require a regular file.
pub struct IsRegularFile;
/// Ownership axis: require `root:root` (uid 0, gid 0).
pub struct RootOwner;
/// Mode axis: require the file not be writable by group or other.
pub struct OnlyRootWritable;

/// File-type axis.
pub trait FileType {
    fn check(stat: &FileStat) -> Result<(), ValidationError>;
}

/// Ownership axis.
pub trait Ownership {
    fn check(stat: &FileStat) -> Result<(), ValidationError>;
}

/// Mode/writability axis.
pub trait Writability {
    fn check(stat: &FileStat) -> Result<(), ValidationError>;
}

// ── `Any` turns every axis off ──────────────────────────────────────────────

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

// ── The concrete checks (all read the one shared fstat) ──────────────────────

impl FileType for IsRegularFile {
    fn check(stat: &FileStat) -> Result<(), ValidationError> {
        if stat.st_mode & SFlag::S_IFMT.bits() == SFlag::S_IFREG.bits() {
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

impl Writability for OnlyRootWritable {
    fn check(stat: &FileStat) -> Result<(), ValidationError> {
        if stat.st_mode & 0o022 == 0 {
            Ok(())
        } else {
            Err(ValidationError::NonRootWritable)
        }
    }
}

/// An open fd, owned (closed on drop), proven to satisfy the axes named by its
/// type parameters.
pub struct SafeFile<T, R, O>(OwnedFd, PhantomData<(T, R, O)>);

impl SafeFile<Any, Any, Any> {
    /// Wrap an already-open raw fd WITHOUT verifying anything (axes all `Any`).
    ///
    /// # Safety
    /// `fd` must be open and not owned by anything else, and must not be used
    /// (or closed) afterwards except through the returned `SafeFile`.
    pub unsafe fn from_raw_fd(fd: RawFd) -> Self {
        Self(OwnedFd::from_raw_fd(fd), PhantomData)
    }
}

impl<T, R, O> SafeFile<T, R, O> {
    /// Relinquish ownership, returning the inner [`OwnedFd`] (not closed here).
    pub fn into_owned_fd(self) -> OwnedFd {
        self.0
    }
}

impl<T, R, O> SafeFile<T, R, O>
where
    T: FileType,
    R: Ownership,
    O: Writability,
{
    /// Open `path` and verify it. A successful open proves existence (you hold an
    /// fd); the shared `fstat` then proves the type/owner/mode axes - all recorded
    /// in the returned type. `O_NOFOLLOW` and `O_CLOEXEC` are always added, so a
    /// symlinked final component is rejected; pass `OFlag::O_PATH` to only
    /// identify/verify, or `OFlag::O_RDONLY` to also read the contents.
    ///
    /// NOTE: `O_NOFOLLOW` guards only the final component - parent directories are
    /// still followed, so this is for paths with trusted parents (e.g. a fixed
    /// `/etc` file). A confined tree needs the fd-by-fd parent walk instead.
    pub fn open<A, S>(path: &SafePath<A, S>, flags: OFlag) -> Result<Self, ValidationError> {
        let raw = nix_open(
            path.as_ref(),
            flags | OFlag::O_NOFOLLOW | OFlag::O_CLOEXEC,
            Mode::empty(),
        )
        .map_err(ValidationError::Open)?;
        // SAFETY: `nix_open` just handed us this fd; nobody else owns it.
        let owned = unsafe { OwnedFd::from_raw_fd(raw) };
        Self::try_from(owned)
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

/// Verify an owned fd against every enforced axis with one shared `fstat`,
/// proving the result in the returned type.
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
