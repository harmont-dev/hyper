// SPDX-License-Identifier: MIT
//! `vm_firewall`: replace a running VM's port policy.

use super::VmOut;
use crate::cli::Op;
use crate::config::{BinError, Config};
use crate::net::firewall::Firewall;
use crate::net::vm::{VmNet, VmNetError};
use hyperrs_firecracker::VmId;
use hyperrs_linux::net::nft::Nft;
use hyperrs_process::privilege::{PrivilegeError, Unprivileged};
use serde::Deserialize;
use thiserror::Error as ThisError;

#[derive(Debug, ThisError)]
pub enum SetFirewallError {
    #[error(transparent)]
    Bin(#[from] BinError),
    #[error(transparent)]
    Privilege(#[from] PrivilegeError),
    #[error(transparent)]
    Net(#[from] VmNetError),
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SetFirewall {
    id: VmId,
    firewall: Firewall,
}

impl Op for SetFirewall {
    type Output = VmOut;
    type Error = SetFirewallError;

    fn run(self, mut token: Unprivileged) -> Result<VmOut, SetFirewallError> {
        let nft = Nft::new(Config::get().nft().map_err(BinError::from)?);
        let _root = token.elevate()?;
        VmNet { id: &self.id }.set_firewall(&nft, &self.firewall)?;
        Ok(VmOut::FirewallSet)
    }
}
