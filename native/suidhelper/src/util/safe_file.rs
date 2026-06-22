// SPDX-License-Identifier: AGPL-3.0-only
//! RAII ownership of a file descriptor.
//!
//! A [`SafeFile`] wraps an open fd and closes it exactly once, on drop - never
//! before. This is the fd half of the path-safety story: once a name has been
//! resolved to a descriptor (ideally with `O_NOFOLLOW`), the descriptor is the
//! handle you verify (`fstat`) and operate through (`*at`), immune to the
//! time-of-check/time-of-use races that plague by-name operations. Holding the
//! fd alive for the whole operation is what makes that immunity real, so the
//! close is tied to the value's lifetime rather than scattered manual `close`
//! calls (which leak on early return and risk double-close).

use std::os::unix::io::{AsFd, AsRawFd, BorrowedFd, FromRawFd, OwnedFd, RawFd};

/// Owns an open file descriptor; closes it on drop, not before.
pub struct SafeFile(OwnedFd);

impl SafeFile {
    /// Take ownership of an already-open raw fd (e.g. one returned by
    /// `nix::fcntl::openat`).
    ///
    /// # Safety
    /// `fd` must be open and not owned by anything else, and must not be used
    /// directly (or closed) afterwards except through the returned `SafeFile` -
    /// the `SafeFile` now owns it and will close it on drop.
    pub unsafe fn from_raw_fd(fd: RawFd) -> Self {
        Self(OwnedFd::from_raw_fd(fd))
    }

    /// Relinquish ownership, returning the inner [`OwnedFd`] (still RAII, just no
    /// longer wrapped). The fd is NOT closed by this call.
    pub fn into_owned_fd(self) -> OwnedFd {
        self.0
    }
}

impl From<OwnedFd> for SafeFile {
    fn from(fd: OwnedFd) -> Self {
        Self(fd)
    }
}

impl AsFd for SafeFile {
    fn as_fd(&self) -> BorrowedFd<'_> {
        self.0.as_fd()
    }
}

impl AsRawFd for SafeFile {
    fn as_raw_fd(&self) -> RawFd {
        self.0.as_raw_fd()
    }
}
