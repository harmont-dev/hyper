// SPDX-License-Identifier: AGPL-3.0-only
//! Shared grant-socket logic reused by `grant-api` and `grant-vsock`.
//!
//! Both ops chown a jail-confined Unix-domain socket to the helper's caller and
//! chmod it `0660`, then open the immediate parent `root` dir for group traversal.
//! This module holds the common constants, the `GrantOut` result type, the
//! `O_NOFOLLOW` walk helper, and the core grant execution so neither op duplicates
//! the logic block.

use crate::util::safe_dir::{self, SafeDir};
use crate::util::safe_path::{IsAbsolute, SafePath, StrictComponents};
use nix::errno::Errno;
use nix::sys::stat::SFlag;
use nix::unistd::{getgid, getuid};
use serde::Serialize;
use std::path::{Path, PathBuf};
use thiserror::Error as ThisError;

/// Number of parent components between the jail base and the socket leaf:
/// `<exec>/<id>/root/<leaf>` — three parents.
pub const SOCKET_PARENT_DEPTH: usize = 3;

/// Mode handed to the node: owner+group read/write, no world access.
pub const SOCKET_MODE: u32 = 0o660;

/// Mode set on the jail `root` dir so the node's group can traverse it to
/// reach the socket: owner `rwx`, group `--x` (traverse, not list), other none.
pub const JAIL_ROOT_MODE: u32 = 0o710;

/// Result type shared by all `chroot-jail grant-*` ops.
#[derive(Debug, Serialize)]
#[serde(tag = "result", rename_all = "snake_case")]
pub enum GrantOut {
    /// The socket was handed to the caller (chowned + chmoded).
    Granted,
    /// The socket does not exist yet; the caller should keep waiting.
    Pending,
}

/// Errors that can arise in the shared grant execution (stat / chown / chmod).
/// Each `grant-*` op wraps these into its own `Error` enum so callers see
/// op-specific messages; the variants are matched by identity in each op's
/// `Error` mapping.
#[derive(Debug, ThisError)]
pub enum GrantError {
    #[error("not a socket (or is a symlink); refusing to touch it")]
    NotASocket,
    #[error("statting the socket: {0}")]
    Stat(#[source] safe_dir::Error),
    #[error("chowning the socket to the caller: {0}")]
    Chown(#[source] safe_dir::Error),
    #[error("chmoding the socket: {0}")]
    Chmod(#[source] safe_dir::Error),
    #[error("chgrp-ing the jail root dir to the caller: {0}")]
    ChgrpRoot(#[source] safe_dir::Error),
    #[error("chmoding the jail root dir for traversal: {0}")]
    ChmodRoot(#[source] safe_dir::Error),
}

/// Open `base` and walk `parents` from it (`O_NOFOLLOW` each step). Returns
/// `Ok(None)` if `base` or any parent is not yet present (`ENOENT`), so the
/// caller can treat a half-built jail as `Pending` rather than an error. On any
/// other failure the raw `safe_dir::Error` is returned for the caller to wrap in
/// its own error type.
pub fn walk_to(
    base: &SafePath<IsAbsolute, StrictComponents>,
    parents: &[PathBuf],
) -> Result<Option<SafeDir>, safe_dir::Error> {
    let anchor = match SafeDir::open(base) {
        Ok(dir) => dir,
        Err(e) if e.errno() == Some(Errno::ENOENT) => return Ok(None),
        Err(e) => return Err(e),
    };
    match anchor.descend(parents) {
        Ok(dir) => Ok(Some(dir)),
        Err(e) if e.errno() == Some(Errno::ENOENT) => Ok(None),
        Err(e) => Err(e),
    }
}

/// Stat `leaf` under `root` (`AT_SYMLINK_NOFOLLOW`), verify it is a real socket
/// (`S_IFSOCK`; a symlink reports `S_IFLNK` and is refused), then chown it to
/// the caller and chmod `0660`. Also open the parent `root` dir for the caller's
/// group to traverse (chgrp'd to the caller, chmod'd `0710`) so the node can
/// reach the socket even though the jailer left `root` at `0700`. Returns
/// `Pending` if `leaf` is not yet present (`ENOENT`).
pub fn grant_to_caller(root: SafeDir, leaf: &Path) -> Result<GrantOut, GrantError> {
    let stat = match root.stat(leaf) {
        Ok(stat) => stat,
        Err(e) if e.errno() == Some(Errno::ENOENT) => return Ok(GrantOut::Pending),
        Err(e) => return Err(GrantError::Stat(e)),
    };
    // `stat` used `AT_SYMLINK_NOFOLLOW`, so a symlink reports as `S_IFLNK`
    // and fails this check — only a real socket is accepted, never a symlink.
    if stat.st_mode & SFlag::S_IFMT.bits() != SFlag::S_IFSOCK.bits() {
        return Err(GrantError::NotASocket);
    }
    root.chown(leaf, getuid().as_raw(), getgid().as_raw())
        .map_err(GrantError::Chown)?;
    root.chmod(leaf, SOCKET_MODE).map_err(GrantError::Chmod)?;
    // Operate on the pinned `root` fd (opened `O_NOFOLLOW`), never by
    // name — TOCTOU-safe on the directory itself.
    root.chgrp_self(getgid().as_raw())
        .map_err(GrantError::ChgrpRoot)?;
    root.chmod_self(JAIL_ROOT_MODE)
        .map_err(GrantError::ChmodRoot)?;
    Ok(GrantOut::Granted)
}
