//! `network host-init`: one-time host setup of the `hyper` nftables table,
//! its masquerade rule, and the forward-chain default-drop policy.
//!
//! Idempotency: host-init reconciles to desired state rather than diffing.
//! [`args::host_init_commands`] always leads with a (failure-tolerant) delete
//! of the `hyper` table, then rebuilds it from scratch. A presence check
//! (e.g. "does `nft list table ip hyper` already mention masquerade?") looks
//! idempotent but isn't: masquerade is added partway through the sequence, so
//! a crash between that step and the later forward-chain drop policy would
//! leave the table permanently short a security rule — every subsequent
//! host-init would see masquerade present and skip, never adding the missing
//! policy. Delete-then-recreate has no such window: the table is always
//! either fully absent or fully complete.
use super::args;
use super::exec;
use super::NetworkOut;
use crate::config::Config;
use crate::tools::IsTool;
use crate::util::safe_bin;
use clap::Args;
use std::path::PathBuf;
use thiserror::Error as ThisError;

#[derive(Args)]
pub struct HostInitArgs {}

#[derive(Debug, ThisError)]
pub enum Error {
    #[error(transparent)]
    NetworkingDisabled(#[from] super::NetworkingDisabled),
    #[error(transparent)]
    Bin(#[from] safe_bin::Error),
    #[error(transparent)]
    Exec(#[from] exec::Error),
}

pub fn run(args: HostInitArgs) -> Result<serde_json::Value, crate::tools::Error> {
    HostInit::new(args)
        .map_err(|e| crate::tools::Error::Tool(Box::new(e)))?
        .run()
}

struct HostInit {
    uplink: String,
    clone_pool: String,
    nft: PathBuf,
}

impl HostInit {
    fn new(_args: HostInitArgs) -> Result<Self, Error> {
        let config = Config::get();
        let network = super::resolve_network(config.network())?;
        Ok(Self {
            uplink: network.uplink.clone(),
            clone_pool: network.clone_pool.clone(),
            nft: config.nft()?.into(),
        })
    }
}

impl IsTool for HostInit {
    type Args = HostInitArgs;
    type Output = NetworkOut;
    type RunT = Result<(), Error>;

    fn run_privileged(&self) -> Self::RunT {
        let commands = args::host_init_commands(&self.uplink, &self.clone_pool);
        // host_init_commands only ever issues `nft` commands (see args.rs).
        exec::run_all(&commands, |_which| self.nft.as_path())?;
        Ok(())
    }

    fn parse(&self, res: Self::RunT) -> Result<NetworkOut, Box<dyn std::error::Error>> {
        res?;
        Ok(NetworkOut::HostReady)
    }
}
