// SPDX-License-Identifier: AGPL-3.0-only
//! `stage` helper: hard-link (or copy) a kernel/layer image into a VM chroot.
//!
//! Security model
//! ──────────────
//! Source: `canonicalize(src)` resolves to an absolute, symlink-free path, which
//! we confine under `HYPER_BASE`; the copy fallback opens it `O_RDONLY|O_NOFOLLOW`
//! so a post-check swap can't redirect it.
//!
//! Destination: the caller hands us the chroot directory as a `SafeDir` reached by
//! an `O_NOFOLLOW` walk, so it is already confined. We only touch the leaf,
//! relative to that dir fd: `link_from` (hard-link) or `create_file`
//! (`O_CREAT|O_EXCL|O_NOFOLLOW`) + copy on `EXDEV`, then `chown`
//! (`AT_SYMLINK_NOFOLLOW`) - all RAII, no manual `close`.

use crate::util::safe_dir::{self, SafeDir};
use nix::errno::Errno;
use nix::fcntl::{open as nix_open, OFlag};
use nix::sys::stat::Mode;
use std::io;
use std::os::unix::io::{FromRawFd, RawFd};
use std::path::{Path, PathBuf};
use thiserror::Error as ThisError;

#[derive(Debug, ThisError)]
pub enum Error {
    #[error("source {path}: {source}")]
    Source {
        path: PathBuf,
        #[source]
        source: io::Error,
    },
    #[error("source must be under {}: {path}", .base.display())]
    OutsideBase { base: &'static Path, path: PathBuf },
    #[error("open source {path}: {source}")]
    OpenSrc {
        path: PathBuf,
        #[source]
        source: nix::Error,
    },
    #[error("staging into {name:?}: {source}")]
    Stage {
        name: String,
        #[source]
        source: safe_dir::Error,
    },
    #[error("copy into {name:?}: {source}")]
    Copy {
        name: String,
        #[source]
        source: io::Error,
    },
}

/// Stage host file `src` into `parent` as `name`, owned `uid:gid`. `parent` is an
/// already-confined chroot directory fd; `src` is canonicalized and confined under
/// `HYPER_BASE`.
pub(crate) fn stage_into(
    parent: &SafeDir,
    name: &str,
    src: &str,
    uid: u32,
    gid: u32,
) -> Result<(), Error> {
    let src_canon = std::fs::canonicalize(src).map_err(|source| Error::Source {
        path: PathBuf::from(src),
        source,
    })?;
    let base = crate::config::Config::get().hyper_base();
    if !src_canon.starts_with(base) {
        return Err(Error::OutsideBase {
            base,
            path: src_canon,
        });
    }

    // Hard-link first; fall back to a copy across filesystems (EXDEV).
    match parent.link_from(&src_canon, name) {
        Ok(()) => {}
        Err(safe_dir::Error::Link { source, .. }) if source == Errno::EXDEV => {
            copy_into(parent, name, &src_canon)?;
        }
        Err(source) => return Err(Error::Stage { name: name.to_string(), source }),
    }

    parent
        .chown(name, uid, gid)
        .map_err(|source| Error::Stage { name: name.to_string(), source })
}

/// EXDEV fallback: open the confined source `O_RDONLY|O_NOFOLLOW`, create the dest
/// `O_CREAT|O_EXCL|O_NOFOLLOW` under `parent`, and copy. Both fds are RAII.
fn copy_into(parent: &SafeDir, name: &str, src_canon: &Path) -> Result<(), Error> {
    let src_raw: RawFd = nix_open(
        src_canon,
        OFlag::O_RDONLY | OFlag::O_NOFOLLOW | OFlag::O_CLOEXEC,
        Mode::empty(),
    )
    .map_err(|source| Error::OpenSrc {
        path: src_canon.to_path_buf(),
        source,
    })?;
    // SAFETY: nix_open just handed us this fd; File takes ownership and closes it.
    let mut src_file = unsafe { std::fs::File::from_raw_fd(src_raw) };

    let dest = parent
        .create_file(name, 0o600)
        .map_err(|source| Error::Stage { name: name.to_string(), source })?;
    let mut dest_file = std::fs::File::from(dest.into_owned_fd());

    io::copy(&mut src_file, &mut dest_file).map_err(|source| Error::Copy {
        name: name.to_string(),
        source,
    })?;
    Ok(())
}
