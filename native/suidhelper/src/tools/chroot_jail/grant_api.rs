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

use crate::config::Config;
use crate::tools::chroot_jail::grant::{grant_socket, GrantSocketError};
use crate::tools::IsTool;
use clap::Args;
use hyperrs_firecracker::chroot_jail::{GrantError, JailLayout};
use hyperrs_firecracker::jailer::VmId;
use hyperrs_fs::path::StrictComponent;
use hyperrs_process::privilege::{Root, Unprivileged};

/// The fixed in-jail socket name firecracker opens (mirrors the Elixir
/// `Hyper.Node.FireVMM.Jailer` `@jail_socket`).
const SOCKET_NAME: &StrictComponent = StrictComponent::from_static("api.socket");

#[derive(Args)]
pub struct GrantApiArgs {
    #[arg(long)]
    id: VmId,
}

pub fn run(
    args: GrantApiArgs,
    token: &mut Unprivileged,
) -> Result<serde_json::Value, crate::tools::DispatchError> {
    GrantApi { args }.run(token)
}

struct GrantApi {
    args: GrantApiArgs,
}

impl IsTool for GrantApi {
    type Args = GrantApiArgs;
    type Output = ();
    type RunT = Result<(), GrantSocketError>;

    fn run_privileged(&self, _root: &Root<'_>) -> Self::RunT {
        let jail_base = Config::get().jail_base();
        grant_socket(&JailLayout::new(&jail_base, &self.args.id), SOCKET_NAME)
    }

    fn parse(&self, res: Self::RunT) -> Result<(), Box<dyn std::error::Error>> {
        Ok(res?)
    }

    fn is_retryable(&self, res: &Self::RunT) -> bool {
        matches!(res, Err(GrantSocketError::Grant(GrantError::Missing)))
    }
}
