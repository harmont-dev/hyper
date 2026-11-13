// SPDX-License-Identifier: MIT
//! `vm_claim_api_socket` / `vm_claim_vsock_socket`: hand one of firecracker's sockets to the node
//! user (0600) and hard-link it into the node's socket dir as `fc-<id>-<socket>`, the only path the
//! BEAM dials. `pending` until firecracker has created the socket.

use super::{VmOut, API_SOCKET, VSOCK_SOCKET};
use crate::cli::Op;
use crate::config::Config;
use derive_more::Constructor;
use hyperrs_firecracker::jailer::chroot::{GrantError, JailLayout};
use hyperrs_firecracker::VmId;
use hyperrs_fs::dir::SafeDir;
use hyperrs_fs::file::{self, Any, IsSocket, OpenFlags, Owner, SafeFile};
use hyperrs_fs::path::{ComponentError, StrictComponent};
use hyperrs_process::privilege::{PrivilegeError, Unprivileged};
use nix::errno::Errno;
use serde::Deserialize;
use thiserror::Error as ThisError;

#[derive(Debug, ThisError)]
pub enum ClaimError {
    #[error(transparent)]
    Grant(#[from] GrantError),
    #[error(transparent)]
    Privilege(#[from] PrivilegeError),
    #[error(transparent)]
    Pin(#[from] PinError),
}

#[derive(Debug, ThisError)]
pub enum PinError {
    #[error("opening the node socket dir: {0}")]
    Open(#[source] file::ValidationError),
    #[error("naming the pinned socket: {0}")]
    Name(#[from] ComponentError),
    #[error("removing the stale pinned socket: {0}")]
    Unlink(#[source] Errno),
    #[error("pinning the socket: {0}")]
    Link(#[source] Errno),
}

#[derive(Constructor)]
pub struct SocketPin<'a> {
    id: &'a VmId,
    socket: &'static str,
}

impl SocketPin<'_> {
    pub fn pin(
        &self,
        dir: &SafeDir,
        socket: &SafeFile<IsSocket, Any, Any>,
    ) -> Result<(), PinError> {
        self.unpin(dir)?;
        let name = self.name();
        dir.linkat(socket, name.as_str().try_into()?)
            .map_err(PinError::Link)
    }

    pub fn unpin(&self, dir: &SafeDir) -> Result<(), PinError> {
        let name = self.name();
        match dir.unlinkat(name.as_str().try_into()?) {
            Ok(()) | Err(Errno::ENOENT) => Ok(()),
            Err(e) => Err(PinError::Unlink(e)),
        }
    }

    fn name(&self) -> String {
        format!("fc-{}-{}", self.id, self.socket)
    }
}

pub type ClaimApiSocket = Claim<API_SOCKET>;
pub type ClaimVsockSocket = Claim<VSOCK_SOCKET>;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Claim<const SOCKET: &'static str> {
    id: VmId,
}

impl<const SOCKET: &'static str> Op for Claim<SOCKET> {
    type Output = VmOut;
    type Error = ClaimError;

    fn run(self, mut token: Unprivileged) -> Result<VmOut, ClaimError> {
        let config = Config::get();
        let jail_base = config.jail_base();
        let layout = JailLayout::new(&jail_base, &self.id);
        let owner = Owner::caller();

        let _root = token.elevate()?;
        let socket = match layout.grant_socket(StrictComponent::from_static(SOCKET), owner) {
            Ok(socket) => socket,
            Err(GrantError::Missing) => return Ok(VmOut::Pending),
            Err(e) => return Err(e.into()),
        };
        let dir = SafeDir::open(&config.socket_dir(), OpenFlags::RDONLY).map_err(PinError::Open)?;
        SocketPin::new(&self.id, SOCKET).pin(&dir, &socket)?;
        Ok(VmOut::Claimed)
    }
}
