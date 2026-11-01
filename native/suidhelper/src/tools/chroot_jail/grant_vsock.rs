// SPDX-License-Identifier: MIT
//! `chroot-jail grant-vsock`: hand the firecracker vsock Unix-domain socket to
//! the node user so the unprivileged controller can connect the guest via AF_VSOCK.
//!
//! Firecracker creates its vsock socket at `<jail>/root/vsock.sock` owned by
//! the per-VM uid/gid assigned by the jailer. The node user (a different uid)
//! gets `EACCES` on connect. This op is the sibling of `grant-api`: it chowns
//! just that one socket to the helper's CALLER and chmods it `0660`, then opens
//! the immediate parent `root` dir for the caller's group to traverse (`0710`).
//!
//! Security: the socket path is confined to `JAIL_BASE` via `SafePath`, reached
//! by an `O_NOFOLLOW` walk, and validated to be at exactly
//! `<exec>/<id>/root/vsock.sock` below the base. `fstatat(AT_SYMLINK_NOFOLLOW)`
//! must report a real socket — a regular file or symlink at that name is refused.
//! A missing socket (`ENOENT`, anywhere on the path) is `Pending`: firecracker has
//! not configured vsock yet, so the controller keeps probing.

use crate::config::Config;
use crate::firecracker::chroot_jail::{self, JailRoot};
use crate::fs::file;
use crate::fs::path::{self, IsAbsolute, SafePath, SafePathBuf, StrictComponent, StrictComponents};
use crate::process::privilege::{Root, Unprivileged};
use crate::tools::IsTool;
use clap::Args;
use nix::errno::Errno;
use std::path::PathBuf;
use std::str::FromStr;
use thiserror::Error as ThisError;

pub use crate::firecracker::chroot_jail::{GrantError, GrantOut};

/// The fixed in-jail socket name Firecracker opens for vsock (mirrors the Elixir
/// `Hyper.Node.FireVMM.Jailer` `@jail_vsock`).
const VSOCK_NAME: &StrictComponent = StrictComponent::from_static("vsock.sock");

#[derive(Debug, ThisError)]
pub enum Error {
    #[error("--socket path: {0}")]
    SocketPath(#[source] path::ValidationError),
    #[error("--socket path: {0}")]
    SocketBase(#[source] path::RelativeError),
    #[error("--socket must be exactly <exec>/<id>/root/vsock.sock below JAIL_BASE: {0:?}")]
    SocketShape(PathBuf),
    #[error("--socket leaf must be {VSOCK_NAME:?}: {0:?}")]
    SocketName(PathBuf),
    #[error("walking to the jail root: {0}")]
    Walk(#[source] crate::fs::file::ValidationError),
    #[error(transparent)]
    Grant(#[from] GrantError),
}

/// A `--socket` value validated at clap-parse time to be an absolute,
/// strictly-componented path whose leaf is exactly `vsock.sock`. The
/// base-relative shape (`<exec>/<id>/root/<leaf>` below `JAIL_BASE`) needs the
/// runtime `jail_base`, so it is *not* enforced here — `grant_vsock_under`
/// checks it. Mirrors `jailer::JailSock`: the parse stays pure, reading no
/// config.
#[derive(Debug, Clone)]
pub struct VsockSocket(SafePathBuf<IsAbsolute, StrictComponents>);

impl FromStr for VsockSocket {
    type Err = Error;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let path: SafePathBuf<IsAbsolute, StrictComponents> =
            PathBuf::from(s).try_into().map_err(Error::SocketPath)?;
        if path.file_name() != Some(VSOCK_NAME) {
            return Err(Error::SocketName(PathBuf::from(s)));
        }
        Ok(Self(path))
    }
}

#[derive(Args)]
pub struct GrantVsockArgs {
    /// Host path of the firecracker vsock socket, shape
    /// <JAIL_BASE>/<exec>/<id>/root/vsock.sock.
    #[arg(long)]
    socket: VsockSocket,
}

/// Run the `grant-vsock` op in its own privileged scope (returns its serialized `Value`).
pub fn run(
    args: GrantVsockArgs,
    token: &mut Unprivileged,
) -> Result<serde_json::Value, crate::tools::Error> {
    GrantVsock { args }.run(token)
}

struct GrantVsock {
    args: GrantVsockArgs,
}

impl IsTool for GrantVsock {
    type Args = GrantVsockArgs;
    type Output = GrantOut;
    type RunT = Result<GrantOut, Error>;

    fn run_privileged(&self, _root: &Root<'_>) -> Self::RunT {
        grant_vsock_under(&Config::get().jail_base(), &self.args.socket)
    }

    fn parse(&self, res: Self::RunT) -> Result<GrantOut, Box<dyn std::error::Error>> {
        Ok(res?)
    }
}

/// Hand `socket` (`<jail_base>/<exec>/<id>/root/vsock.sock`) to the helper's
/// caller, fd-relative after an `O_NOFOLLOW` walk from `jail_base`. Returns
/// `Pending` if any path component or the socket itself is not yet present.
pub fn grant_vsock_under(
    jail_base: &SafePath<IsAbsolute, StrictComponents>,
    socket: &VsockSocket,
) -> Result<GrantOut, Error> {
    let shape = || Error::SocketShape(socket.0.as_ref().to_path_buf());
    let (root, leaf) = socket.0.split_last().ok_or_else(shape)?;
    let root = match JailRoot::open(jail_base, root) {
        Ok(root) => root,
        Err(chroot_jail::OpenError::Open(file::ValidationError::Open(Errno::ENOENT))) => {
            return Ok(GrantOut::Pending)
        }
        Err(chroot_jail::OpenError::Base(e)) => return Err(Error::SocketBase(e)),
        Err(chroot_jail::OpenError::Shape(_)) => return Err(shape()),
        Err(chroot_jail::OpenError::Open(e)) => return Err(Error::Walk(e)),
    };
    Ok(root.grant_to_caller(leaf)?)
}
