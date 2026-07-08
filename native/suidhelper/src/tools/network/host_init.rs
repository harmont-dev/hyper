//! `network host-init`: one-time host setup of the `hyper` nftables table,
//! its masquerade rule, and the forward-chain default-drop policy.
//!
//! Idempotency: before building the program, list the `hyper` table (`nft
//! list table ip hyper`). If it already exists and its listing contains the
//! masquerade rule, host-init has already run and nothing more is added. This
//! is coarser than a per-rule list-then-add guard, but the whole program is
//! only ever created here as one atomic unit (never hand-edited), so "the
//! masquerade rule is present" is equivalent to "the whole program already
//! ran" — a single check covers every rule below it.
use super::args;
use super::exec;
use super::NetworkOut;
use crate::config::Config;
use crate::tools::IsTool;
use crate::util::safe_bin;
use clap::Args;
use std::path::PathBuf;
use std::process::Command;
use thiserror::Error as ThisError;

#[derive(Args)]
pub struct HostInitArgs {}

#[derive(Debug, ThisError)]
pub enum Error {
    #[error("VM networking is not configured ([network] absent from config)")]
    NetworkingDisabled,
    #[error(transparent)]
    Bin(#[from] safe_bin::Error),
    #[error(transparent)]
    Exec(#[from] exec::Error),
    #[error("listing the existing hyper nft table: {0}")]
    List(#[source] std::io::Error),
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
        let network = config.network().ok_or(Error::NetworkingDisabled)?;
        Ok(Self {
            uplink: network.uplink.clone(),
            clone_pool: network.clone_pool.clone(),
            nft: config.nft()?.into(),
        })
    }

    /// `true` iff the `hyper` table already carries the masquerade rule, i.e.
    /// host-init has already run.
    fn already_done(&self) -> Result<bool, Error> {
        let output = Command::new(&self.nft)
            .args(["list", "table", "ip", "hyper"])
            .env_clear()
            .output()
            .map_err(Error::List)?;
        Ok(output.status.success()
            && String::from_utf8_lossy(&output.stdout).contains("masquerade"))
    }
}

impl IsTool for HostInit {
    type Args = HostInitArgs;
    type Output = NetworkOut;
    type RunT = Result<(), Error>;

    fn run_privileged(&self) -> Self::RunT {
        if self.already_done()? {
            return Ok(());
        }
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
