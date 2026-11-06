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
use crate::tools::chroot_jail::grant::{caller, grant_socket, GrantSocketError};
use crate::tools::IsTool;
use clap::Args;
use hyperrs_firecracker::jailer::chroot::{GrantError, JailLayout};
use hyperrs_firecracker::VmId;
use hyperrs_fs::path::StrictComponent;
use hyperrs_process::privilege::{Root, Unprivileged};

/// The fixed in-jail socket name Firecracker opens for vsock (mirrors the Elixir
/// `Hyper.Node.FireVMM.Jailer` `@jail_vsock`).
const VSOCK_NAME: &StrictComponent = StrictComponent::from_static("vsock.sock");

#[derive(Args)]
pub struct GrantVsockArgs {
    #[arg(long)]
    id: VmId,
}

pub fn run(
    args: GrantVsockArgs,
    token: &mut Unprivileged,
) -> Result<serde_json::Value, crate::tools::DispatchError> {
    GrantVsock { args }.run(token)
}

struct GrantVsock {
    args: GrantVsockArgs,
}

impl IsTool for GrantVsock {
    type Args = GrantVsockArgs;
    type Output = ();
    type RunT = Result<(), GrantSocketError>;

    fn run_privileged(&self, _root: &Root<'_>) -> Self::RunT {
        let jail_base = Config::get().jail_base();
        grant_socket(
            &JailLayout::new(&jail_base, &self.args.id),
            VSOCK_NAME,
            caller(),
        )
    }

    fn parse(&self, res: Self::RunT) -> Result<(), Box<dyn std::error::Error>> {
        Ok(res?)
    }

    fn is_retryable(&self, res: &Self::RunT) -> bool {
        matches!(res, Err(GrantSocketError::Grant(GrantError::Missing)))
    }
}
