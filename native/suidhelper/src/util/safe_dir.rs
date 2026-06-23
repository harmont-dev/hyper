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
use nix::sys::stat::{mknodat, Mode, SFlag};
use nix::unistd::{dup, fchownat, linkat, unlinkat, Gid, Uid, UnlinkatFlags};
use std::path::Path;
use std::os::unix::io::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use thiserror::Error as ThisError;

#[derive(Debug, ThisError)]
pub enum Error {
    #[error("openat {name:?}: {source}")]
    Open { name: String, source: nix::Error },
    #[error("readdir: {0}")]
    ReadDir(#[source] nix::Error),
    #[error("non-utf8 directory entry")]
    BadName,
    #[error("unlinkat {name:?}: {source}")]
    Unlink { name: String, source: nix::Error },
    #[error("mknodat {name:?}: {source}")]
    Mknod { name: String, source: nix::Error },
    #[error("fchownat {name:?}: {source}")]
    Chown { name: String, source: nix::Error },
    #[error("linkat -> {name:?}: {source}")]
    Link { name: String, source: nix::Error },
    #[error("dup: {0}")]
    Dup(#[source] nix::Error),
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
        let raw = openat(None::<RawFd>, path.as_ref(), dir_flags(), Mode::empty()).map_err(
            |source| Error::Open {
                name: path.as_ref().display().to_string(),
                source,
            },
        )?;
        // SAFETY: openat just handed us this fd; nobody else owns it.
        Ok(Self(unsafe { OwnedFd::from_raw_fd(raw) }))
    }

    /// Descend into child directory `name` - one step of the walk. `O_NOFOLLOW`
    /// rejects a symlinked component; the open is relative to this dir's fd.
    pub fn openat_dir(&self, name: &str) -> Result<SafeDir, Error> {
        let raw = openat(Some(self.0.as_raw_fd()), name, dir_flags(), Mode::empty()).map_err(
            |source| Error::Open {
                name: name.to_string(),
                source,
            },
        )?;
        // SAFETY: as above.
        Ok(SafeDir(unsafe { OwnedFd::from_raw_fd(raw) }))
    }

    /// Walk `components` from this dir, one `openat_dir` step each, returning the
    /// directory they name. Every step is `O_NOFOLLOW` and relative to the
    /// previous pinned fd, so arriving proves confinement under this anchor.
    pub fn descend(&self, components: &[String]) -> Result<SafeDir, Error> {
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

    /// Open file `name` in this directory (`O_NOFOLLOW|O_CLOEXEC` always added).
    /// Returns an unverified handle; `try_into()` it to assert `fstat` axes.
    pub fn openat_file(&self, name: &str, flags: OFlag) -> Result<SafeFile<Any, Any, Any>, Error> {
        let raw = openat(
            Some(self.0.as_raw_fd()),
            name,
            flags | OFlag::O_NOFOLLOW | OFlag::O_CLOEXEC,
            Mode::empty(),
        )
        .map_err(|source| Error::Open {
            name: name.to_string(),
            source,
        })?;
        // SAFETY: openat just handed us this fd; nobody else owns it.
        Ok(unsafe { SafeFile::from_raw_fd(raw) })
    }

    /// Create file `name` in this directory, failing if it exists
    /// (`O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW`).
    pub fn create_file(&self, name: &str, mode: u32) -> Result<SafeFile<Any, Any, Any>, Error> {
        let raw = openat(
            Some(self.0.as_raw_fd()),
            name,
            OFlag::O_WRONLY | OFlag::O_CREAT | OFlag::O_EXCL | OFlag::O_NOFOLLOW | OFlag::O_CLOEXEC,
            Mode::from_bits_truncate(mode),
        )
        .map_err(|source| Error::Open {
            name: name.to_string(),
            source,
        })?;
        // SAFETY: as above.
        Ok(unsafe { SafeFile::from_raw_fd(raw) })
    }

    /// Create a block device node `name` in this directory with the given
    /// `rdev`, then chown it to `uid:gid`.
    pub fn mknod_block(&self, name: &str, rdev: dev_t, uid: u32, gid: u32) -> Result<(), Error> {
        mknodat(
            Some(self.0.as_raw_fd()),
            name,
            SFlag::S_IFBLK,
            Mode::from_bits_truncate(0o600),
            rdev,
        )
        .map_err(|source| Error::Mknod {
            name: name.to_string(),
            source,
        })?;
        self.chown(name, uid, gid)
    }

    /// Hard-link the file at host path `src` into this directory as `name`.
    pub fn link_from(&self, src: &Path, name: &str) -> Result<(), Error> {
        linkat(
            None::<RawFd>,
            src,
            Some(self.0.as_raw_fd()),
            Path::new(name),
            AtFlags::empty(),
        )
        .map_err(|source| Error::Link {
            name: name.to_string(),
            source,
        })
    }

    /// `chown` entry `name` to `uid:gid` without following a final symlink.
    pub fn chown(&self, name: &str, uid: u32, gid: u32) -> Result<(), Error> {
        fchownat(
            Some(self.0.as_raw_fd()),
            name,
            Some(Uid::from_raw(uid)),
            Some(Gid::from_raw(gid)),
            AtFlags::AT_SYMLINK_NOFOLLOW,
        )
        .map_err(|source| Error::Chown {
            name: name.to_string(),
            source,
        })
    }

    /// Remove the non-directory entry `name` from this directory.
    pub fn unlink(&self, name: &str) -> Result<(), Error> {
        unlinkat(Some(self.0.as_raw_fd()), name, UnlinkatFlags::NoRemoveDir).map_err(|source| {
            Error::Unlink {
                name: name.to_string(),
                source,
            }
        })
    }

    /// Remove the (empty) child directory `name` from this directory.
    pub fn rmdir(&self, name: &str) -> Result<(), Error> {
        unlinkat(Some(self.0.as_raw_fd()), name, UnlinkatFlags::RemoveDir).map_err(|source| {
            Error::Unlink {
                name: name.to_string(),
                source,
            }
        })
    }

    /// Recursively remove child `name` and everything under it, fd-relative the
    /// whole way: descend with `O_NOFOLLOW` (so symlinked subdirs are unlinked,
    /// never followed), empty each level, then `rmdir` it.
    pub fn remove_dir_all(&self, name: &str) -> Result<(), Error> {
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
    fn entries(&self) -> Result<Vec<(String, bool)>, Error> {
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
            let name = entry.file_name().to_str().map_err(|_| Error::BadName)?;
            if name == "." || name == ".." {
                continue;
            }
            // A symlink reports as Symlink (not Directory) so it is unlinked, never
            // descended. DT_UNKNOWN falls back to a confined open probe below.
            let is_dir = match entry.file_type() {
                Some(Type::Directory) => true,
                Some(_) => false,
                None => self.probe_is_dir(name),
            };
            out.push((name.to_string(), is_dir));
        }
        Ok(out)
    }

    /// Fallback for filesystems that return `DT_UNKNOWN`: a confined `openat`
    /// with `O_DIRECTORY|O_NOFOLLOW` succeeds iff `name` is a real directory.
    fn probe_is_dir(&self, name: &str) -> bool {
        self.openat_dir(name).is_ok()
    }
}
