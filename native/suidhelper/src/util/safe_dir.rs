// SPDX-License-Identifier: AGPL-3.0-only
//! Directory handles with fd-relative operations.
//!
//! A [`SafeDir`] owns a directory fd (closed on drop). It is two things at once:
//!
//!   * the **walk** primitive - [`SafeDir::openat_dir`] descends one component
//!     with `O_NOFOLLOW|O_DIRECTORY`, so a symlinked component is rejected and
//!     every step is resolved relative to the previous pinned fd (never re-walked
//!     from `/`). Chaining it from a trusted base proves confinement, race-free.
//!   * the home for **fd-relative deletion** - `unlink`/`rmdir` operate via the
//!     held dir fd (`unlinkat`), and [`SafeDir::remove_dir_all`] recurses with
//!     freshly `openat`-ed subdir fds, so no step ever re-resolves a path by name
//!     (unlike `std::fs::remove_dir_all`, which is a by-name TOCTOU footgun).

use super::safe_file::{Any, SafeFile};
use super::safe_path::SafePath;
use nix::dir::{Dir, Type};
use nix::fcntl::{openat, AtFlags, OFlag};
use nix::libc::dev_t;
use nix::sys::stat::{fchmod, fchmodat, fstatat, mknodat, FchmodatFlags, FileStat, Mode, SFlag};
use nix::unistd::{dup, fchown, fchownat, linkat, unlinkat, write, Gid, Uid, UnlinkatFlags};
use std::ffi::OsStr;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::io::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::path::{Path, PathBuf};
use thiserror::Error as ThisError;

#[derive(Debug, ThisError)]
pub enum Error {
    #[error("openat {name:?}: {source}")]
    Open { name: PathBuf, source: nix::Error },
    #[error("readdir: {0}")]
    ReadDir(#[source] nix::Error),
    #[error("unlinkat {name:?}: {source}")]
    Unlink { name: PathBuf, source: nix::Error },
    #[error("write {name:?}: {source}")]
    Write { name: PathBuf, source: nix::Error },
    #[error("mknodat {name:?}: {source}")]
    Mknod { name: PathBuf, source: nix::Error },
    #[error("fchownat {name:?}: {source}")]
    Chown { name: PathBuf, source: nix::Error },
    #[error("fchmodat {name:?}: {source}")]
    Chmod { name: PathBuf, source: nix::Error },
    #[error("fstatat {name:?}: {source}")]
    Stat { name: PathBuf, source: nix::Error },
    #[error("linkat -> {name:?}: {source}")]
    Link { name: PathBuf, source: nix::Error },
    #[error("dup: {0}")]
    Dup(#[source] nix::Error),
}

impl Error {
    /// The underlying errno, for callers that treat some failures as success
    /// (e.g. idempotent removal on `ENOENT`).
    pub fn errno(&self) -> Option<nix::errno::Errno> {
        match self {
            Error::Open { source, .. }
            | Error::Unlink { source, .. }
            | Error::Write { source, .. }
            | Error::Mknod { source, .. }
            | Error::Chown { source, .. }
            | Error::Chmod { source, .. }
            | Error::Stat { source, .. }
            | Error::Link { source, .. } => Some(*source),
            Error::ReadDir(source) | Error::Dup(source) => Some(*source),
        }
    }
}

/// Flags every directory open uses: read (to `readdir`), confined to directories,
/// never follow a symlink, close-on-exec.
fn dir_flags() -> OFlag {
    OFlag::O_RDONLY | OFlag::O_DIRECTORY | OFlag::O_NOFOLLOW | OFlag::O_CLOEXEC
}

/// An owned directory fd (closed on drop).
pub struct SafeDir(OwnedFd);

impl SafeDir {
    /// Open `path` as an anchor directory. This is the one absolute open; it
    /// should be a fixed, trusted root (e.g. the jail base or `/sys/fs/cgroup`).
    pub fn open<A, S>(path: &SafePath<A, S>) -> Result<Self, Error> {
        let raw =
            openat(None::<RawFd>, path.as_ref(), dir_flags(), Mode::empty()).map_err(|source| {
                Error::Open {
                    name: path.as_ref().to_path_buf(),
                    source,
                }
            })?;
        // SAFETY: openat just handed us this fd; nobody else owns it.
        Ok(Self(unsafe { OwnedFd::from_raw_fd(raw) }))
    }

    /// Descend into child directory `name` - one step of the walk. `O_NOFOLLOW`
    /// rejects a symlinked component; the open is relative to this dir's fd.
    pub fn openat_dir(&self, name: &Path) -> Result<SafeDir, Error> {
        let raw = openat(Some(self.0.as_raw_fd()), name, dir_flags(), Mode::empty()).map_err(
            |source| Error::Open {
                name: name.to_path_buf(),
                source,
            },
        )?;
        // SAFETY: as above.
        Ok(SafeDir(unsafe { OwnedFd::from_raw_fd(raw) }))
    }

    /// Walk `components` from this dir, one `openat_dir` step each, returning the
    /// directory they name. Every step is `O_NOFOLLOW` and relative to the
    /// previous pinned fd, so arriving proves confinement under this anchor.
    pub fn descend(&self, components: &[PathBuf]) -> Result<SafeDir, Error> {
        let mut dir = match components.first() {
            None => return self.try_clone(),
            Some(first) => self.openat_dir(first)?,
        };
        for component in &components[1..] {
            dir = dir.openat_dir(component)?;
        }
        Ok(dir)
    }

    /// Duplicate this directory handle (its own independent fd).
    pub fn try_clone(&self) -> Result<SafeDir, Error> {
        let raw = dup(self.0.as_raw_fd()).map_err(Error::Dup)?;
        // SAFETY: dup just handed us a fresh owned fd.
        Ok(SafeDir(unsafe { OwnedFd::from_raw_fd(raw) }))
    }

    /// Create file `name` in this directory, failing if it exists
    /// (`O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW`).
    pub fn create_file(&self, name: &Path, mode: u32) -> Result<SafeFile<Any, Any, Any>, Error> {
        let raw = openat(
            Some(self.0.as_raw_fd()),
            name,
            OFlag::O_WRONLY | OFlag::O_CREAT | OFlag::O_EXCL | OFlag::O_NOFOLLOW | OFlag::O_CLOEXEC,
            Mode::from_bits_truncate(mode),
        )
        .map_err(|source| Error::Open {
            name: name.to_path_buf(),
            source,
        })?;
        // SAFETY: as above.
        Ok(unsafe { SafeFile::from_raw_fd(raw) })
    }

    /// Open existing file `name` write-only (`O_WRONLY|O_NOFOLLOW|O_CLOEXEC`, no
    /// `O_CREAT`/`O_TRUNC`) and write `contents`. For kernel pseudo-files such as
    /// `cgroup.kill` where a single `write` is the whole API. `O_NOFOLLOW` rejects a
    /// symlinked `name`, so the write cannot be redirected out of this pinned dir.
    pub fn write_file(&self, name: &Path, contents: &[u8]) -> Result<(), Error> {
        let raw = openat(
            Some(self.0.as_raw_fd()),
            name,
            OFlag::O_WRONLY | OFlag::O_NOFOLLOW | OFlag::O_CLOEXEC,
            Mode::empty(),
        )
        .map_err(|source| Error::Open {
            name: name.to_path_buf(),
            source,
        })?;
        // SAFETY: openat just handed us this fd; nobody else owns it.
        let fd = unsafe { OwnedFd::from_raw_fd(raw) };
        let mut off = 0;
        while off < contents.len() {
            match write(&fd, &contents[off..]) {
                Ok(0) => break,
                Ok(n) => off += n,
                Err(source) => {
                    return Err(Error::Write {
                        name: name.to_path_buf(),
                        source,
                    })
                }
            }
        }
        Ok(())
    }

    /// Create a block device node `name` in this directory with the given
    /// `rdev`, then chown it to `uid:gid`.
    pub fn mknod_block(&self, name: &Path, rdev: dev_t, uid: u32, gid: u32) -> Result<(), Error> {
        mknodat(
            Some(self.0.as_raw_fd()),
            name,
            SFlag::S_IFBLK,
            Mode::from_bits_truncate(0o600),
            rdev,
        )
        .map_err(|source| Error::Mknod {
            name: name.to_path_buf(),
            source,
        })?;
        self.chown(name, uid, gid)
    }

    /// Hard-link the file at host path `src` into this directory as `name`.
    pub fn link_from(&self, src: &Path, name: &Path) -> Result<(), Error> {
        linkat(
            None::<RawFd>,
            src,
            Some(self.0.as_raw_fd()),
            name,
            AtFlags::empty(),
        )
        .map_err(|source| Error::Link {
            name: name.to_path_buf(),
            source,
        })
    }

    /// `chown` entry `name` to `uid:gid` without following a final symlink.
    pub fn chown(&self, name: &Path, uid: u32, gid: u32) -> Result<(), Error> {
        fchownat(
            Some(self.0.as_raw_fd()),
            name,
            Some(Uid::from_raw(uid)),
            Some(Gid::from_raw(gid)),
            AtFlags::AT_SYMLINK_NOFOLLOW,
        )
        .map_err(|source| Error::Chown {
            name: name.to_path_buf(),
            source,
        })
    }

    /// `fstat` entry `name` relative to this dir's fd without following a final
    /// symlink (`AT_SYMLINK_NOFOLLOW`). A symlink stats as itself (`S_IFLNK`),
    /// never its target, so a caller inspecting the file type can reject one.
    pub fn stat(&self, name: &Path) -> Result<FileStat, Error> {
        fstatat(Some(self.0.as_raw_fd()), name, AtFlags::AT_SYMLINK_NOFOLLOW).map_err(|source| {
            Error::Stat {
                name: name.to_path_buf(),
                source,
            }
        })
    }

    /// `chmod` entry `name` to `mode`. Linux's `fchmodat` has no working
    /// no-follow mode (it returns `ENOTSUP`), so this follows a final symlink;
    /// call it only after [`stat`](Self::stat) has proven `name` is not a
    /// symlink, so the follow is a no-op on a real (non-link) entry.
    pub fn chmod(&self, name: &Path, mode: u32) -> Result<(), Error> {
        fchmodat(
            Some(self.0.as_raw_fd()),
            name,
            Mode::from_bits_truncate(mode),
            FchmodatFlags::FollowSymlink,
        )
        .map_err(|source| Error::Chmod {
            name: name.to_path_buf(),
            source,
        })
    }

    /// `fchmod` this directory through its own held fd. Unlike [`chmod`](Self::chmod),
    /// which re-resolves a *name*, this targets the fd we already opened
    /// `O_NOFOLLOW`, so there is no path component to swap - TOCTOU-safe on the
    /// directory itself.
    pub fn chmod_self(&self, mode: u32) -> Result<(), Error> {
        fchmod(self.0.as_raw_fd(), Mode::from_bits_truncate(mode)).map_err(|source| Error::Chmod {
            name: PathBuf::from("."),
            source,
        })
    }

    /// `fchown` this directory's group through its own held fd, preserving its
    /// owner (no uid passed). Same TOCTOU guarantee as [`chmod_self`](Self::chmod_self).
    pub fn chgrp_self(&self, gid: u32) -> Result<(), Error> {
        fchown(self.0.as_raw_fd(), None, Some(Gid::from_raw(gid))).map_err(|source| Error::Chown {
            name: PathBuf::from("."),
            source,
        })
    }

    /// Remove the non-directory entry `name` from this directory.
    pub fn unlink(&self, name: &Path) -> Result<(), Error> {
        unlinkat(Some(self.0.as_raw_fd()), name, UnlinkatFlags::NoRemoveDir).map_err(|source| {
            Error::Unlink {
                name: name.to_path_buf(),
                source,
            }
        })
    }

    /// Remove the (empty) child directory `name` from this directory.
    pub fn rmdir(&self, name: &Path) -> Result<(), Error> {
        unlinkat(Some(self.0.as_raw_fd()), name, UnlinkatFlags::RemoveDir).map_err(|source| {
            Error::Unlink {
                name: name.to_path_buf(),
                source,
            }
        })
    }

    /// Recursively remove child `name` and everything under it, fd-relative the
    /// whole way: descend with `O_NOFOLLOW` (so symlinked subdirs are unlinked,
    /// never followed), empty each level, then `rmdir` it.
    pub fn remove_dir_all(&self, name: &Path) -> Result<(), Error> {
        let child = self.openat_dir(name)?;
        child.clear()?;
        self.rmdir(name)
    }

    /// Unlink everything inside this directory (leaving the directory itself).
    fn clear(&self) -> Result<(), Error> {
        for (entry, is_dir) in self.entries()? {
            if is_dir {
                self.remove_dir_all(&entry)?;
            } else {
                self.unlink(&entry)?;
            }
        }
        Ok(())
    }

    /// Read this directory's entries (skipping `.`/`..`) into `(name, is_dir)`
    /// pairs - fully drained before any caller mutates the directory, so we never
    /// `readdir` and unlink concurrently. Reads through a fresh fd (`openat "."`)
    /// so this dir's own offset is untouched.
    fn entries(&self) -> Result<Vec<(PathBuf, bool)>, Error> {
        let raw = openat(
            Some(self.0.as_raw_fd()),
            ".",
            OFlag::O_RDONLY | OFlag::O_DIRECTORY | OFlag::O_CLOEXEC,
            Mode::empty(),
        )
        .map_err(Error::ReadDir)?;
        // `Dir::from_fd` takes ownership of `raw` and closes it on drop.
        let mut dir = Dir::from_fd(raw).map_err(Error::ReadDir)?;

        let mut out = Vec::new();
        for entry in dir.iter() {
            let entry = entry.map_err(Error::ReadDir)?;
            let bytes = entry.file_name().to_bytes();
            if bytes == b"." || bytes == b".." {
                continue;
            }
            let name = PathBuf::from(OsStr::from_bytes(bytes));
            // A symlink reports as Symlink (not Directory) so it is unlinked, never
            // descended. DT_UNKNOWN falls back to a confined open probe below.
            let is_dir = match entry.file_type() {
                Some(Type::Directory) => true,
                Some(_) => false,
                None => self.probe_is_dir(&name),
            };
            out.push((name, is_dir));
        }
        Ok(out)
    }

    /// Fallback for filesystems that return `DT_UNKNOWN`: a confined `openat`
    /// with `O_DIRECTORY|O_NOFOLLOW` succeeds iff `name` is a real directory.
    fn probe_is_dir(&self, name: &Path) -> bool {
        self.openat_dir(name).is_ok()
    }
}
