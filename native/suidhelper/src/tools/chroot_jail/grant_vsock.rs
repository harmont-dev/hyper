// SPDX-License-Identifier: AGPL-3.0-only
//! `chroot-jail grant-vsock`: hand the firecracker vsock Unix-domain socket to
//! the node user so the unprivileged controller can connect the guest via AF_VSOCK.
//!
//! Firecracker creates its vsock socket at `<jail>/root/<leaf>.vsock` owned by
//! the per-VM uid/gid assigned by the jailer. The node user (a different uid)
//! gets `EACCES` on connect. This op is the sibling of `grant-api`: it chowns
//! just that one socket to the helper's CALLER and chmods it `0660`, then opens
//! the immediate parent `root` dir for the caller's group to traverse (`0710`).
//!
//! Security: the socket path is confined to `JAIL_BASE` via `SafePath`, reached
//! by an `O_NOFOLLOW` walk, and validated to be at exactly
//! `<exec>/<id>/root/<leaf>.vsock` below the base. `fstatat(AT_SYMLINK_NOFOLLOW)`
//! must report a real socket — a regular file or symlink at that name is refused.
//! A missing socket (`ENOENT`, anywhere on the path) is `Pending`: firecracker has
//! not configured vsock yet, so the controller keeps probing.

use super::grant::{self, GrantError};
use crate::config::Config;
use crate::tools::IsTool;
use crate::util::safe_path::{self, IsAbsolute, SafePath, StrictComponents};
use clap::Args;
use std::path::{Path, PathBuf};
use thiserror::Error as ThisError;

pub use super::grant::GrantOut;

type LexicalPath = SafePath<IsAbsolute, StrictComponents>;

#[derive(Debug, ThisError)]
pub enum Error {
    #[error("--socket path: {0}")]
    SocketPath(#[source] safe_path::ValidationError),
    #[error("--socket must be exactly <exec>/<id>/root/<name>.vsock below JAIL_BASE: {0:?}")]
    SocketShape(PathBuf),
    #[error("--socket leaf must end with `.vsock`: {0:?}")]
    SocketName(PathBuf),
    #[error("walking to the jail root: {0}")]
    Walk(#[source] crate::util::safe_dir::Error),
    #[error("vsock socket is not a socket (or is a symlink); refusing to touch it")]
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
pub struct GrantVsockArgs {
    /// Host path of the firecracker vsock socket, shape
    /// <JAIL_BASE>/<exec>/<id>/root/<name>.vsock.
    #[arg(long)]
    socket: PathBuf,
}

/// Run the `grant-vsock` op in its own privileged scope (returns its serialized `Value`).
pub fn run(args: GrantVsockArgs) -> Result<serde_json::Value, crate::tools::Error> {
    GrantVsock { args }.run()
}

struct GrantVsock {
    args: GrantVsockArgs,
}

impl IsTool for GrantVsock {
    type Args = GrantVsockArgs;
    type Output = GrantOut;
    type RunT = Result<GrantOut, Error>;

    fn run_privileged(&self) -> Self::RunT {
        grant_vsock_under(&Config::get().jail_base(), &self.args.socket)
    }

    fn parse(&self, res: Self::RunT) -> Result<GrantOut, Box<dyn std::error::Error>> {
        Ok(res?)
    }
}

/// Hand `socket` (`<jail_base>/<exec>/<id>/root/<name>.vsock`) to the helper's
/// caller, fd-relative after an `O_NOFOLLOW` walk from `jail_base`. Returns
/// `Pending` if any path component or the socket itself is not yet present.
pub fn grant_vsock_under(jail_base: &Path, socket: &Path) -> Result<GrantOut, Error> {
    let path: LexicalPath = socket.to_path_buf().try_into().map_err(Error::SocketPath)?;
    let (parents, leaf) = path.relative_to(jail_base).map_err(Error::SocketPath)?;
    if parents.len() != grant::SOCKET_PARENT_DEPTH {
        return Err(Error::SocketShape(socket.to_path_buf()));
    }
    if !leaf
        .to_str()
        .map(|s| s.ends_with(".vsock"))
        .unwrap_or(false)
    {
        return Err(Error::SocketName(socket.to_path_buf()));
    }

    let base_path: LexicalPath = jail_base
        .to_path_buf()
        .try_into()
        .map_err(Error::SocketPath)?;
    let Some(root) = grant::walk_to(&base_path, &parents).map_err(Error::Walk)? else {
        return Ok(GrantOut::Pending);
    };

    grant::grant_to_caller(root, &leaf).map_err(map_grant_err)
}
