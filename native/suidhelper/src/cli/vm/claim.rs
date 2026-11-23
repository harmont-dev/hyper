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
use hyperrs_fs::file::{self, Any, CallerOwned, IsSocket, OpenFlags, Owner, SafeFile};
use hyperrs_fs::path::{ComponentError, StrictComponent, StrictComponentBuf};
use hyperrs_process::privilege::{PrivilegeError, Unprivileged};
use nix::errno::Errno;
use nix::sys::stat::Mode;
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
    #[error("opening the node's socket: {0}")]
    Socket(#[source] file::ValidationError),
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
        dir.linkat(socket, &self.name()?).map_err(PinError::Link)
    }

    pub fn unpin(&self, dir: &SafeDir) -> Result<(), PinError> {
        match dir.unlinkat(&self.name()?) {
            Ok(()) | Err(Errno::ENOENT) => Ok(()),
            Err(e) => Err(PinError::Unlink(e)),
        }
    }

    pub fn open(
        &self,
        dir: &SafeDir,
    ) -> Result<Option<SafeFile<IsSocket, CallerOwned, Any>>, PinError> {
        match dir.openat(&self.name()?, OpenFlags::PATH, Mode::empty()) {
            Ok(socket) => Ok(Some(socket)),
            Err(file::ValidationError::Open(Errno::ENOENT)) => Ok(None),
            Err(e) => Err(PinError::Socket(e)),
        }
    }

    fn name(&self) -> Result<StrictComponentBuf, ComponentError> {
        let name = format!("fc-{}-{}", self.id, self.socket);
        <&StrictComponent>::try_from(name.as_str()).map(ToOwned::to_owned)
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

#[cfg(test)]
mod tests {
    use super::{PinError, SocketPin};
    use crate::cli::vm::GUEST_SOCKET;
    use assert_fs::prelude::*;
    use assert_fs::TempDir;
    use hyperrs_firecracker::VmId;
    use hyperrs_fs::dir::SafeDir;
    use hyperrs_fs::file::OpenFlags;
    use hyperrs_fs::path::{IsAbsolute, SafePathBuf, StrictComponents};
    use rstest::rstest;
    use std::assert_matches;
    use std::os::unix::fs::symlink;
    use std::os::unix::net::UnixListener;
    use std::path::Path;

    fn dir(path: &Path) -> SafeDir {
        let path: SafePathBuf<IsAbsolute, StrictComponents> =
            path.to_path_buf().try_into().unwrap();
        SafeDir::open(&path, OpenFlags::RDONLY).unwrap()
    }

    fn pin(id: &VmId) -> SocketPin<'_> {
        SocketPin::new(id, GUEST_SOCKET)
    }

    #[rstest]
    fn open_finds_the_callers_socket_and_reports_a_missing_one_as_none() {
        let tmp = TempDir::new().unwrap();
        let (present, absent): (VmId, VmId) = ("v1".parse().unwrap(), "v2".parse().unwrap());
        let _listener = UnixListener::bind(tmp.child("fc-v1-guest.sock")).unwrap();

        let dir = dir(tmp.path());
        assert!(pin(&present).open(&dir).unwrap().is_some());
        assert!(pin(&absent).open(&dir).unwrap().is_none());
    }

    fn symlink_to_a_socket(tmp: &TempDir) {
        let target = tmp.child("elsewhere.sock");
        UnixListener::bind(&target).unwrap();
        symlink(target.path(), tmp.child("fc-v1-guest.sock")).unwrap();
    }

    fn regular_file(tmp: &TempDir) {
        tmp.child("fc-v1-guest.sock")
            .write_str("not a socket")
            .unwrap();
    }

    #[rstest]
    #[case::symlink_to_a_socket(symlink_to_a_socket)]
    #[case::regular_file(regular_file)]
    fn open_refuses_a_name_that_is_not_a_socket_itself(#[case] plant: fn(&TempDir)) {
        let tmp = TempDir::new().unwrap();
        plant(&tmp);
        let id: VmId = "v1".parse().unwrap();

        assert_matches!(pin(&id).open(&dir(tmp.path())), Err(PinError::Socket(_)));
    }

    #[rstest]
    fn a_socket_name_that_is_not_one_component_is_an_error_not_a_panic() {
        let tmp = TempDir::new().unwrap();
        let id: VmId = "v1".parse().unwrap();

        assert_matches!(
            SocketPin::new(&id, "a/b").open(&dir(tmp.path())),
            Err(PinError::Name(_))
        );
    }
}
