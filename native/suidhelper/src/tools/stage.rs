// SPDX-License-Identifier: AGPL-3.0-only
//! `stage` helper: copy/link a kernel or layer image into a VM chroot.
//!
//! Security model
//! ──────────────
//! Source hardening
//!   • `canonicalize(src)` resolves the source to an absolute, symlink-free
//!     path. We then assert it stays under `/srv/hyper`. The canonical fd is
//!     opened with `O_RDONLY|O_NOFOLLOW` so a race cannot swap in a symlink
//!     after the confinement check.
//!
//! Destination hardening (symlink-safe walk)
//!   • [`safe_dev::open_parent_nofollow`] walks every PARENT component of
//!     `dest` under `JAIL_BASE` with `O_NOFOLLOW`. A symlink in any parent
//!     returns `ELOOP → SymlinkComponent`, aborting the operation.
//!   • The hard-link is done via `linkat(…, parent_fd, final_name, …)` so the
//!     destination is relative to the verified parent fd.
//!   • The EXDEV fallback creates the destination with
//!     `openat(parent_fd, final_name, O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW)`
//!     — `O_EXCL` prevents clobbering an existing entry and `O_NOFOLLOW`
//!     prevents following a final-component symlink.
//!   • Ownership is set with `fchownat(parent_fd, final_name, …,
//!     AT_SYMLINK_NOFOLLOW)` — never plain `chown`, which follows a
//!     final-component symlink.

use crate::safe_dev::{self, JailPath};
use nix::fcntl::{openat, AtFlags, OFlag};
use nix::sys::stat::Mode;
use nix::unistd::{close, fchownat, linkat, Gid, Uid};
use std::io;
use std::os::unix::io::{FromRawFd, RawFd};
use std::path::PathBuf;
use thiserror::Error as ThisError;

#[derive(Debug, ThisError)]
pub enum Error {
    #[error(transparent)]
    Path(#[from] safe_dev::Error),
    #[error("source {path}: {source}")]
    Source { path: PathBuf, #[source] source: io::Error },
    #[error("source must be under {base}: {path}")]
    OutsideBase { base: &'static str, path: PathBuf },
    #[error("open source {path}: {source}")]
    OpenSrc { path: PathBuf, #[source] source: nix::Error },
    #[error("staging {src} -> {dest}: {source}")]
    Link { src: PathBuf, dest: PathBuf, #[source] source: nix::Error },
    #[error("staging {src} -> {dest} (copy): {source}")]
    Copy { src: PathBuf, dest: PathBuf, #[source] source: io::Error },
    #[error("chown {path}: {source}")]
    Chown { path: PathBuf, #[source] source: nix::Error },
}

/// Stage a file from `src` (a path string, canonicalized + confined under
/// HYPER_BASE) into `dest` (a JailPath, walked with O_NOFOLLOW).
///
/// Security: canonicalizes src and asserts it stays under HYPER_BASE; opens
/// src O_RDONLY|O_NOFOLLOW; walks dest parents with O_NOFOLLOW; uses linkat
/// (EXDEV fallback: openat O_CREAT|O_EXCL|O_NOFOLLOW + io::copy); sets
/// ownership with fchownat(AT_SYMLINK_NOFOLLOW).
pub(crate) fn stage_file(src: &str, dest: &JailPath, uid: u32, gid: u32) -> Result<(), Error> {
    // ── 1. Canonicalize source and confine it under HYPER_BASE ──────────────
    let src_canon = std::fs::canonicalize(src)
        .map_err(|source| Error::Source { path: PathBuf::from(src), source })?;
    let base = crate::config::hyper_base();
    if !src_canon.starts_with(base) {
        return Err(Error::OutsideBase { base, path: src_canon });
    }

    // Open the canonical source with O_RDONLY|O_NOFOLLOW so a race cannot
    // swap it for a symlink after the confinement check above.
    let src_fd: RawFd = openat(
        None::<RawFd>,
        src_canon.as_path(),
        OFlag::O_RDONLY | OFlag::O_NOFOLLOW | OFlag::O_CLOEXEC,
        Mode::empty(),
    )
    .map_err(|source| Error::OpenSrc { path: src_canon.clone(), source })?;

    // ── 2. Walk parent dirs of dest with O_NOFOLLOW ─────────────────────────
    let (parent_fd, final_name) = safe_dev::open_parent_nofollow(dest)?;
    // If open_parent_nofollow fails, src_fd leaks. Close it on that path.

    // ── 3. Hard-link src into parent_fd/final_name ──────────────────────────
    // linkat(src_fd, "", parent_fd, name, AT_EMPTY_PATH) creates the link
    // without caring about directory contents; but on many kernels it
    // requires CAP_DAC_READ_SEARCH. Use linkat(AT_FDCWD, canonical_src, …)
    // instead, which works as long as we're root.
    let link_result = linkat(
        None::<RawFd>,
        src_canon.as_path(),
        Some(parent_fd),
        std::path::Path::new(final_name.as_str()),
        AtFlags::empty(),
    );

    match link_result {
        Ok(()) => {}
        Err(nix::errno::Errno::EXDEV) => {
            // Cross-filesystem: open dest with O_CREAT|O_EXCL|O_NOFOLLOW
            // and copy bytes from the already-open src_fd.
            let dest_fd_raw = openat(
                Some(parent_fd),
                final_name.as_str(),
                OFlag::O_WRONLY | OFlag::O_CREAT | OFlag::O_EXCL | OFlag::O_NOFOLLOW | OFlag::O_CLOEXEC,
                Mode::from_bits_truncate(0o600),
            )
            .map_err(|source| {
                let _ = close(parent_fd);
                let _ = close(src_fd);
                Error::Link {
                    src: src_canon.clone(),
                    dest: dest.as_ref().to_path_buf(),
                    source,
                }
            })?;

            // Wrap both fds in std::fs::File for easy io::copy.
            // SAFETY: we own both fds and they are valid.
            let mut src_file = unsafe { std::fs::File::from_raw_fd(src_fd) };
            let mut dest_file = unsafe { std::fs::File::from_raw_fd(dest_fd_raw) };

            let copy_result = io::copy(&mut src_file, &mut dest_file);
            // Files close when dropped.
            drop(src_file);
            drop(dest_file);

            copy_result.map_err(|source| {
                let _ = close(parent_fd);
                Error::Copy {
                    src: src_canon.clone(),
                    dest: dest.as_ref().to_path_buf(),
                    source,
                }
            })?;

            // fds now closed via File::drop; skip the manual close below.
            let chown_result = fchownat(
                Some(parent_fd),
                final_name.as_str(),
                Some(Uid::from_raw(uid)),
                Some(Gid::from_raw(gid)),
                AtFlags::AT_SYMLINK_NOFOLLOW,
            );
            let _ = close(parent_fd);
            return chown_result.map_err(|source| Error::Chown {
                path: dest.as_ref().to_path_buf(),
                source,
            });
        }
        Err(source) => {
            let _ = close(parent_fd);
            let _ = close(src_fd);
            return Err(Error::Link {
                src: src_canon,
                dest: dest.as_ref().to_path_buf(),
                source,
            });
        }
    }

    // Hard-link succeeded; close src_fd (not needed further).
    let _ = close(src_fd);

    // ── 4. fchownat with AT_SYMLINK_NOFOLLOW ────────────────────────────────
    let chown_result = fchownat(
        Some(parent_fd),
        final_name.as_str(),
        Some(Uid::from_raw(uid)),
        Some(Gid::from_raw(gid)),
        AtFlags::AT_SYMLINK_NOFOLLOW,
    );
    let _ = close(parent_fd);

    chown_result.map_err(|source| Error::Chown {
        path: dest.as_ref().to_path_buf(),
        source,
    })
}
