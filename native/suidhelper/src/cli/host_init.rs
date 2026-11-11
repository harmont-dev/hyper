use crate::cli::Op;
use crate::config::{BinError, Config, NetUnconfigured};
use crate::net::host::{HostNet, HostNetError};
use crate::net::NetId;
use hyperrs_linux::net::nft::Nft;
use hyperrs_linux::net::{IfName, Ipv4Net, Ipv6Net};
use hyperrs_process::privilege::{PrivilegeError, Unprivileged};
use serde::{Deserialize, Serialize};
use serde_with::{serde_as, DisplayFromStr};
use std::path::PathBuf;
use thiserror::Error as ThisError;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct HostInit {}

#[derive(Debug, ThisError)]
pub enum HostInitError {
    #[error(transparent)]
    Net(#[from] NetUnconfigured),
    #[error(transparent)]
    Bin(#[from] BinError),
    #[error(transparent)]
    HostNet(#[from] HostNetError),
    #[error(transparent)]
    Privilege(#[from] PrivilegeError),
}

#[derive(Serialize)]
#[serde(tag = "result", rename_all = "snake_case")]
pub enum HostInitOut {
    HostReady {
        hyper_base: PathBuf,
        net: HostNetOut,
    },
}

/// The host-wide network facts the BEAM derives each VM's addresses from.
#[serde_as]
#[derive(Serialize)]
pub struct HostNetOut {
    #[serde_as(as = "DisplayFromStr")]
    uplink: IfName,
    #[serde_as(as = "DisplayFromStr")]
    transit_prefix: Ipv4Net,
    #[serde_as(as = "DisplayFromStr")]
    vm_prefix: Ipv6Net,
}

impl Op for HostInit {
    type Output = HostInitOut;
    type Error = HostInitError;

    fn run(self, mut token: Unprivileged) -> Result<HostInitOut, HostInitError> {
        let config = Config::get();
        let net = config.net()?;
        let nft = Nft::new(config.nft().map_err(BinError::from)?);

        {
            let root = token.elevate()?;
            HostNet {
                uplink: net.uplink(),
                prefix: net.ipv6_prefix(),
            }
            .init(&root, &nft)?;
        }

        Ok(HostInitOut::HostReady {
            hyper_base: config.hyper_base().as_path().to_path_buf(),
            net: HostNetOut {
                uplink: net.uplink().clone(),
                transit_prefix: NetId::transit_range(),
                vm_prefix: net.ipv6_prefix().vm_range(),
            },
        })
    }
}
