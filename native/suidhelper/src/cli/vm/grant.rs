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

use crate::cli::DispatchError;
use crate::config::Config;
use clap::Args;
use hyperrs_firecracker::jailer::chroot::{GrantError, JailLayout};
use hyperrs_firecracker::VmId;
use hyperrs_fs::file::Owner;
use hyperrs_fs::path::StrictComponent;
use hyperrs_process::privilege::{PrivilegeError, Unprivileged};
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

#[derive(Args)]
pub struct GrantArgs {
    #[arg(long)]
    id: VmId,
}

pub fn run(
    args: &GrantArgs,
    socket: &StrictComponent,
    token: &mut Unprivileged,
) -> Result<(), DispatchError> {
    grant(&args.id, socket, token).map_err(|e| {
        if e.is_pending() {
            DispatchError::Retryable(Box::new(e))
        } else {
            DispatchError::tool(e)
        }
    })
}

fn grant(
    id: &VmId,
    socket: &StrictComponent,
    token: &mut Unprivileged,
) -> Result<(), GrantOpError> {
    let jail_base = Config::get().jail_base();
    let layout = JailLayout::new(&jail_base, id);
    let owner = Owner::caller();
    let _root = token.elevate()?;
    Ok(layout.grant_socket(socket, owner)?)
}
