// SPDX-License-Identifier: MIT
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

use super::grant;
use crate::config::Config;
use crate::fs::dir::SafeDir;
use crate::fs::file::{self, OpenFlags};
use crate::fs::path::{self, IsAbsolute, SafePathBuf, StrictComponent, StrictComponents};
use crate::process::privilege::{Root, Unprivileged};
use crate::tools::IsTool;
use clap::Args;
use nix::errno::Errno;
use std::path::{Path, PathBuf};
use std::str::FromStr;
use thiserror::Error as ThisError;

pub use super::grant::{GrantError, GrantOut};

/// The fixed in-jail socket name firecracker opens (mirrors the Elixir
/// `Hyper.Node.FireVMM.Jailer` `@jail_socket`).
const SOCKET_NAME: &StrictComponent = StrictComponent::from_static("api.socket");

#[derive(Debug, ThisError)]
pub enum Error {
    #[error("--socket path: {0}")]
    SocketPath(#[source] path::ValidationError),
    #[error("--socket path: {0}")]
    SocketBase(#[source] path::RelativeError),
    #[error("--socket must be exactly <exec>/<id>/root/api.socket below JAIL_BASE: {0:?}")]
    SocketShape(PathBuf),
    #[error("--socket leaf must be {SOCKET_NAME:?}: {0:?}")]
    SocketName(PathBuf),
    #[error("walking to the jail root: {0}")]
    Walk(#[source] crate::fs::file::ValidationError),
    #[error(transparent)]
    Grant(#[from] GrantError),
}

/// A `--socket` value validated at clap-parse time to be an absolute,
/// strictly-componented path whose leaf is exactly `api.socket`. The
/// base-relative shape (`<exec>/<id>/root/<leaf>` below `JAIL_BASE`) needs the
/// runtime `jail_base`, so it is *not* enforced here — `grant_api_under` checks
/// it. Mirrors `jailer::JailSock`: the parse stays pure, reading no config.
#[derive(Debug, Clone)]
pub struct ApiSocket(SafePathBuf<IsAbsolute, StrictComponents>);

impl FromStr for ApiSocket {
    type Err = Error;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let path: SafePathBuf<IsAbsolute, StrictComponents> =
            PathBuf::from(s).try_into().map_err(Error::SocketPath)?;
        if path.file_name() != Some(SOCKET_NAME) {
            return Err(Error::SocketName(PathBuf::from(s)));
        }
        Ok(Self(path))
    }
}

#[derive(Args)]
pub struct GrantApiArgs {
    /// Host path of the firecracker API socket, shape
    /// <JAIL_BASE>/<exec>/<id>/root/api.socket.
    #[arg(long)]
    socket: ApiSocket,
}

/// Run the `grant-api` op in its own privileged scope (returns its serialized `Value`).
pub fn run(
    args: GrantApiArgs,
    token: &mut Unprivileged,
) -> Result<serde_json::Value, crate::tools::Error> {
    GrantApi { args }.run(token)
}

struct GrantApi {
    args: GrantApiArgs,
}

impl IsTool for GrantApi {
    type Args = GrantApiArgs;
    type Output = GrantOut;
    type RunT = Result<GrantOut, Error>;

    fn run_privileged(&self, _root: &Root<'_>) -> Self::RunT {
        grant_api_under(&Config::get().jail_base(), &self.args.socket)
    }

    fn parse(&self, res: Self::RunT) -> Result<GrantOut, Box<dyn std::error::Error>> {
        Ok(res?)
    }
}

/// Hand `socket` (`<jail_base>/<exec>/<id>/root/api.socket`) to the helper's
/// caller, fd-relative after an `O_NOFOLLOW` walk from `jail_base`. Returns
/// `Pending` if any path component or the socket itself is not yet present.
pub fn grant_api_under(jail_base: &Path, socket: &ApiSocket) -> Result<GrantOut, Error> {
    let rel = socket.0.strip_base(jail_base).map_err(Error::SocketBase)?;
    let (4, Some((root, leaf))) = (rel.segments().count(), socket.0.split_last()) else {
        return Err(Error::SocketShape(socket.0.as_ref().to_path_buf()));
    };

    let root = match SafeDir::open(root, OpenFlags::RDONLY) {
        Ok(root) => root,
        Err(file::ValidationError::Open(Errno::ENOENT)) => return Ok(GrantOut::Pending),
        Err(e) => return Err(Error::Walk(e)),
    };

    grant::grant_to_caller(root, leaf).map_err(Error::from)
}
