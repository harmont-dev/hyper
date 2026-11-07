// SPDX-License-Identifier: MIT
//! `vm grant-api`: hand the firecracker API socket to the node user so the unprivileged controller
//! can `connect()` to it.

use super::{VmOut, API_SOCKET, VSOCK_SOCKET};
use crate::cli::Op;
use crate::config::Config;
use hyperrs_firecracker::jailer::chroot::{GrantError, JailLayout};
use hyperrs_firecracker::VmId;
use hyperrs_fs::file::Owner;
use hyperrs_fs::path::StrictComponent;
use hyperrs_process::privilege::{PrivilegeError, Unprivileged};
use serde::Deserialize;
use thiserror::Error as ThisError;

#[derive(Debug, ThisError)]
pub enum ClaimError {
    #[error(transparent)]
    Grant(#[from] GrantError),
    #[error(transparent)]
    Privilege(#[from] PrivilegeError),
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
        let jail_base = Config::get().jail_base();
        let layout = JailLayout::new(&jail_base, &self.id);
        let owner = Owner::caller();

        let root = token.elevate()?;
        let res = layout.grant_socket(StrictComponent::from_static(SOCKET), owner);
        drop(root);

        match res {
            Ok(()) => Ok(VmOut::Claimed),
            Err(GrantError::Missing) => Ok(VmOut::Pending),
            Err(e) => Err(e.into()),
        }
    }
}
