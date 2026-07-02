// SPDX-License-Identifier: AGPL-3.0-only
//! `chroot-jail grant-api`: hand the firecracker API socket to the node user so
//! the unprivileged controller can `connect()` to it.
//!
//! The jailer drops firecracker to a per-VM uid/gid and chroots it; firecracker
//! then creates its API socket at `<jail>/root/api.socket` owned by that per-VM
//! id. Connecting a unix socket needs *write* permission on the node, so the
//! node user (a different uid) gets `EACCES`. This op chowns just that one
//! socket to the helper's CALLER — `getuid()`/`getgid()`, which inside the
//! privileged scope are the real (caller) ids while euid is 0 — and chmods it
//! `0660`. The node thus connects as owner, and humans added to the node's
//! group connect via the group bit.
//!
//! That alone is not enough: the jailer leaves `<id>/root` as `0700` owned by
//! the per-VM uid, and connecting needs *search* (`+x`) on every ancestor, so
//! the node cannot even traverse into `root` to reach the (now its own) socket.
//! So this op also opens just that one directory to the caller's group: it keeps
//! the per-VM uid as owner (firecracker still needs it), chgrps `root` to the
//! caller's gid, and chmods it `0710` — owner `rwx`, group `--x` (traverse, not
//! list), other none. Per-VM isolation is otherwise untouched: only this socket
//! and its immediate parent's group/mode move, nothing else in the jail, and
//! unrelated users stay locked out.
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

use super::grant::{self, GrantError};
use crate::config::Config;
use crate::tools::IsTool;
use crate::util::safe_path::{self, IsAbsolute, SafePath, StrictComponents};
use clap::Args;
use std::path::{Path, PathBuf};
use thiserror::Error as ThisError;

pub use super::grant::GrantOut;

/// The fixed in-jail socket name firecracker opens (mirrors the Elixir
/// `Hyper.Node.FireVMM.Jailer` `@jail_socket`).
const SOCKET_NAME: &str = "api.socket";

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
    Walk(#[source] crate::util::safe_dir::Error),
    #[error("api.socket is not a socket (or is a symlink); refusing to touch it")]
    NotASocket,
    #[error("statting the socket: {0}")]
    Stat(#[source] crate::util::safe_dir::Error),
    #[error("chowning the socket to the caller: {0}")]
    Chown(#[source] crate::util::safe_dir::Error),
    #[error("chmoding the socket: {0}")]
    Chmod(#[source] crate::util::safe_dir::Error),
    #[error("chgrp-ing the jail root dir to the caller: {0}")]
    ChgrpRoot(#[source] crate::util::safe_dir::Error),
    #[error("chmoding the jail root dir for traversal: {0}")]
    ChmodRoot(#[source] crate::util::safe_dir::Error),
}

fn map_grant_err(e: GrantError) -> Error {
    match e {
        GrantError::NotASocket => Error::NotASocket,
        GrantError::Stat(e) => Error::Stat(e),
        GrantError::Chown(e) => Error::Chown(e),
        GrantError::Chmod(e) => Error::Chmod(e),
        GrantError::ChgrpRoot(e) => Error::ChgrpRoot(e),
        GrantError::ChmodRoot(e) => Error::ChmodRoot(e),
    }
}

#[derive(Args)]
pub struct GrantApiArgs {
    /// Host path of the firecracker API socket, shape
    /// <JAIL_BASE>/<exec>/<id>/root/api.socket.
    #[arg(long)]
    socket: PathBuf,
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
    if parents.len() != grant::SOCKET_PARENT_DEPTH {
        return Err(Error::SocketShape(socket.to_path_buf()));
    }
    if leaf != Path::new(SOCKET_NAME) {
        return Err(Error::SocketName(socket.to_path_buf()));
    }

    let base_path: LexicalPath = jail_base
        .to_path_buf()
        .try_into()
        .map_err(Error::SocketPath)?;
    let Some(root) = grant::walk_to(&base_path, &parents).map_err(Error::Walk)? else {
        return Ok(GrantOut::Pending);
    };

    grant::grant_to_caller(root, Path::new(SOCKET_NAME)).map_err(map_grant_err)
}
