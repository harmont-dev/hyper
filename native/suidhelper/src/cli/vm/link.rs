// SPDX-License-Identifier: MIT

use super::claim::SocketPin;
use super::{VmOut, GUEST_LINK, GUEST_SOCKET};
use crate::cli::Op;
use crate::config::Config;
use crate::id::IdError;
use crate::lock::{Locks, LocksError};
use hyperrs_firecracker::jailer::chroot::{JailLayout, LinkError};
use hyperrs_firecracker::VmId;
use hyperrs_fs::dir::SafeDir;
use hyperrs_fs::file::{self, OpenFlags};
use hyperrs_process::privilege::{PrivilegeError, Unprivileged};
use nix::errno::Errno;
use serde::Deserialize;
use thiserror::Error as ThisError;

#[derive(Debug, ThisError)]
pub enum LinkGuestSocketError {
    #[error(transparent)]
    Id(#[from] IdError),
    #[error(transparent)]
    Privilege(#[from] PrivilegeError),
    #[error(transparent)]
    Lock(#[from] LocksError),
    #[error("opening the node socket dir: {0}")]
    SocketDir(#[source] file::ValidationError),
    #[error("no guest socket is listening for this VM")]
    NoListener,
    #[error("opening the guest socket: {0}")]
    Open(#[source] file::ValidationError),
    #[error(transparent)]
    Link(LinkError),
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LinkGuestSocket {
    id: VmId,
    gid: u32,
}

impl Op for LinkGuestSocket {
    type Output = VmOut;
    type Error = LinkGuestSocketError;

    fn run(self, mut token: Unprivileged) -> Result<VmOut, LinkGuestSocketError> {
        let config = Config::get();
        let gid = config.uid_gid_range().gid(self.gid)?;
        let jail_base = config.jail_base();
        let layout = JailLayout::new(&jail_base, &self.id);
        let dir = SafeDir::open(&config.socket_dir(), OpenFlags::RDONLY)
            .map_err(LinkGuestSocketError::SocketDir)?;
        let socket = match SocketPin::new(&self.id, GUEST_SOCKET).open(&dir) {
            Ok(socket) => socket,
            Err(file::ValidationError::Open(Errno::ENOENT)) => {
                return Err(LinkGuestSocketError::NoListener)
            }
            Err(e) => return Err(LinkGuestSocketError::Open(e)),
        };

        let root = token.elevate()?;
        let locks = Locks::open(&root)?;
        let _vm = locks.vm(&root, &self.id)?;
        match layout.link_socket(&socket, GUEST_LINK, gid.into()) {
            Ok(()) => Ok(VmOut::Linked),
            Err(LinkError::Missing) => Ok(VmOut::Pending),
            Err(e) => Err(LinkGuestSocketError::Link(e)),
        }
    }
}
