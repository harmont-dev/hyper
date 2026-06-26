// SPDX-License-Identifier: AGPL-3.0-only
//! `chroot-jail grant-api`: hand the firecracker API socket to the node user so
//! the unprivileged controller can `connect()` to it.
//!
//! The jailer drops firecracker to a per-VM uid/gid and chroots it; firecracker
//! then creates its API socket at `<jail>/root/api.socket` owned by that per-VM
//! id, mode `0755`. Connecting a unix socket needs *write* permission on the
//! node, so the node user (a different uid) gets `EACCES`. This op chowns just
//! that one socket to the helper's CALLER — `getuid()`/`getgid()`, which inside
//! the privileged scope are the real (caller) ids while euid is 0 — and chmods
//! it `0660`. The node thus connects as owner, and humans added to the node's
//! group connect via the group bit. Per-VM isolation is otherwise untouched:
//! only this single socket moves, nothing else in the jail.
//!
//! Security: the socket path is validated as a `SafePath` and reached by an
//! `O_NOFOLLOW` walk from `JAIL_BASE`, so a symlinked component cannot redirect
//! the chown outside the jail, and every op is fd-relative on the pinned `root`
//! dir fd, never by re-resolved name. The leaf must be exactly `api.socket`
//! `<exec>/<id>/root` below the base, and `fstatat(AT_SYMLINK_NOFOLLOW)` must
//! report a *socket* — a regular file or symlink planted at that name is an
//! attack and is refused, never chmod'd. A missing socket (`ENOENT`, anywhere on
//! the path) is `Pending`, not an error: firecracker has not created it yet, so
//! the controller keeps probing.

use crate::config::Config;
use crate::tools::IsTool;
use crate::util::safe_dir::{self, SafeDir};
use crate::util::safe_path::{self, IsAbsolute, SafePath, StrictComponents};
use clap::Args;
use nix::errno::Errno;
use nix::sys::stat::SFlag;
use nix::unistd::{getgid, getuid};
use serde::Serialize;
use std::path::{Path, PathBuf};
use thiserror::Error as ThisError;

/// The fixed in-jail socket name firecracker opens (mirrors the Elixir
/// `Hyper.Node.FireVMM.Jailer` `@jail_socket`).
const SOCKET_NAME: &str = "api.socket";

/// The socket sits at `<JAIL_BASE>/<exec>/<id>/root/api.socket`: three parent
/// components (`<exec>`, `<id>`, `root`) before the leaf.
const SOCKET_PARENT_DEPTH: usize = 3;

/// Mode handed to the node: owner+group read/write, no world access.
const SOCKET_MODE: u32 = 0o660;

type LexicalPath = SafePath<IsAbsolute, StrictComponents>;

#[derive(Debug, ThisError)]
pub enum Error {
    #[error("--socket path: {0}")]
    SocketPath(#[source] safe_path::ValidationError),
    #[error("--socket must be exactly <exec>/<id>/root/api.socket below JAIL_BASE: {0:?}")]
    SocketShape(PathBuf),
    #[error("--socket leaf must be {SOCKET_NAME:?}: {0:?}")]
    SocketName(PathBuf),
    #[error("walking to the jail root: {0}")]
    Walk(#[source] safe_dir::Error),
    #[error("api.socket is not a socket (or is a symlink); refusing to touch it")]
    NotASocket,
    #[error("statting the socket: {0}")]
    Stat(#[source] safe_dir::Error),
    #[error("chowning the socket to the caller: {0}")]
    Chown(#[source] safe_dir::Error),
    #[error("chmoding the socket: {0}")]
    Chmod(#[source] safe_dir::Error),
}

#[derive(Args)]
pub struct GrantApiArgs {
    /// Host path of the firecracker API socket, shape
    /// <JAIL_BASE>/<exec>/<id>/root/api.socket.
    #[arg(long)]
    socket: PathBuf,
}

#[derive(Debug, Serialize)]
#[serde(tag = "result", rename_all = "snake_case")]
pub enum GrantOut {
    /// The socket was handed to the caller (chowned + chmoded).
    Granted,
    /// The socket does not exist yet; the caller should keep waiting.
    Pending,
}

/// Run the `grant-api` op in its own privileged scope (returns its serialized `Value`).
pub fn run(args: GrantApiArgs) -> Result<serde_json::Value, crate::tools::Error> {
    GrantApi { args }.run()
}

struct GrantApi {
    args: GrantApiArgs,
}

impl IsTool for GrantApi {
    type Args = GrantApiArgs;
    type Output = GrantOut;
    type RunT = Result<GrantOut, Error>;

    fn run_privileged(&self) -> Self::RunT {
        grant_api_under(&Config::get().jail_base(), &self.args.socket)
    }

    fn parse(&self, res: Self::RunT) -> Result<GrantOut, Box<dyn std::error::Error>> {
        Ok(res?)
    }
}

/// Hand `socket` (`<jail_base>/<exec>/<id>/root/api.socket`) to the helper's
/// caller, fd-relative after an `O_NOFOLLOW` walk from `jail_base`. Returns
/// `Pending` if any path component or the socket itself is not yet present.
pub fn grant_api_under(jail_base: &Path, socket: &Path) -> Result<GrantOut, Error> {
    let path: LexicalPath = socket.to_path_buf().try_into().map_err(Error::SocketPath)?;
    let (parents, leaf) = path.relative_to(jail_base).map_err(Error::SocketPath)?;
    if parents.len() != SOCKET_PARENT_DEPTH {
        return Err(Error::SocketShape(socket.to_path_buf()));
    }
    if leaf != Path::new(SOCKET_NAME) {
        return Err(Error::SocketName(socket.to_path_buf()));
    }

    let Some(root) = walk(jail_base.to_path_buf(), &parents)? else {
        return Ok(GrantOut::Pending); // jail not fully created yet
    };

    let leaf = Path::new(SOCKET_NAME);
    let stat = match root.stat(leaf) {
        Ok(stat) => stat,
        Err(e) if e.errno() == Some(Errno::ENOENT) => return Ok(GrantOut::Pending),
        Err(e) => return Err(Error::Stat(e)),
    };
    // `stat` used AT_SYMLINK_NOFOLLOW, so a symlink reports as S_IFLNK and fails
    // this check too: only a real socket is accepted, anything else is refused.
    if stat.st_mode & SFlag::S_IFMT.bits() != SFlag::S_IFSOCK.bits() {
        return Err(Error::NotASocket);
    }

    root.chown(leaf, getuid().as_raw(), getgid().as_raw())
        .map_err(Error::Chown)?;
    root.chmod(leaf, SOCKET_MODE).map_err(Error::Chmod)?;
    Ok(GrantOut::Granted)
}

/// Open `base` and walk `parents` from it (`O_NOFOLLOW` each step). Returns
/// `Ok(None)` if `base` or any parent is not yet present (`ENOENT`), so the
/// caller can treat a half-built jail as `Pending` rather than an error.
fn walk(base: PathBuf, parents: &[PathBuf]) -> Result<Option<SafeDir>, Error> {
    let base_path: LexicalPath = base.try_into().map_err(Error::SocketPath)?;
    let anchor = match SafeDir::open(&base_path) {
        Ok(dir) => dir,
        Err(e) if e.errno() == Some(Errno::ENOENT) => return Ok(None),
        Err(e) => return Err(Error::Walk(e)),
    };
    match anchor.descend(parents) {
        Ok(dir) => Ok(Some(dir)),
        Err(e) if e.errno() == Some(Errno::ENOENT) => Ok(None),
        Err(e) => Err(Error::Walk(e)),
    }
}
