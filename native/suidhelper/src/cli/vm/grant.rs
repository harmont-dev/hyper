// SPDX-License-Identifier: MIT
//! `vm grant-api`: hand the firecracker API socket to the node user so
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

use super::{VmOut, API_SOCKET, VSOCK_SOCKET};
use crate::cli::{DispatchError, Op};
use crate::config::Config;
use hyperrs_firecracker::jailer::chroot::{GrantError, JailLayout};
use hyperrs_firecracker::VmId;
use hyperrs_fs::file::Owner;
use hyperrs_fs::path::StrictComponent;
use hyperrs_process::privilege::{PrivilegeError, Unprivileged};
use serde::Deserialize;
use serde_with::{serde_as, DisplayFromStr};
use thiserror::Error as ThisError;

#[derive(Debug, ThisError)]
pub enum GrantOpError {
    #[error(transparent)]
    Grant(#[from] GrantError),
    #[error(transparent)]
    Privilege(#[from] PrivilegeError),
}

impl GrantOpError {
    fn is_pending(&self) -> bool {
        matches!(self, GrantOpError::Grant(GrantError::Missing))
    }
}

#[serde_as]
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct GrantApi {
    #[serde_as(as = "DisplayFromStr")]
    id: VmId,
}

#[serde_as]
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct GrantVsock {
    #[serde_as(as = "DisplayFromStr")]
    id: VmId,
}

impl From<GrantOpError> for DispatchError {
    fn from(e: GrantOpError) -> Self {
        if e.is_pending() {
            DispatchError::Retryable(Box::new(e))
        } else {
            DispatchError::tool(e)
        }
    }
}

impl Op for GrantApi {
    type Output = VmOut;
    type Error = GrantOpError;

    fn run(self, mut token: Unprivileged) -> Result<VmOut, GrantOpError> {
        grant(&self.id, API_SOCKET, &mut token)
    }
}

impl Op for GrantVsock {
    type Output = VmOut;
    type Error = GrantOpError;

    fn run(self, mut token: Unprivileged) -> Result<VmOut, GrantOpError> {
        grant(&self.id, VSOCK_SOCKET, &mut token)
    }
}

fn grant(
    id: &VmId,
    socket: &StrictComponent,
    token: &mut Unprivileged,
) -> Result<VmOut, GrantOpError> {
    let jail_base = Config::get().jail_base();
    let layout = JailLayout::new(&jail_base, id);
    let owner = Owner::caller();
    let _root = token.elevate()?;
    layout.grant_socket(socket, owner)?;
    Ok(VmOut::Granted)
}
