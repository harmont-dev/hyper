//! `network teardown`: remove a VM's netns, reclaiming its veth peer, TAP
//! device, and in-netns nftables state, plus any lingering host-side veth end.
use super::args;
use super::exec;
use super::prepare;
use super::NetworkOut;
use crate::tools::jailer::VmId;
use crate::tools::IsTool;
use clap::Args;
use std::path::PathBuf;
use thiserror::Error as ThisError;

#[derive(Args)]
pub struct TeardownArgs {
    /// Microvm id; names the netns to remove.
    #[arg(long)]
    vm_id: VmId,
    /// Unprivileged uid the VM ran as; derives its clone-pool `/30` slot.
    #[arg(long)]
    uid: u32,
}

#[derive(Debug, ThisError)]
pub enum Error {
    #[error(transparent)]
    Plan(#[from] prepare::Error),
    #[error(transparent)]
    Exec(#[from] exec::Error),
}

pub fn run(args: TeardownArgs) -> Result<serde_json::Value, crate::tools::Error> {
    Teardown::new(args)
        .map_err(|e| crate::tools::Error::Tool(Box::new(e)))?
        .run()
}

struct Teardown {
    plan: super::addr::Plan,
    ip: PathBuf,
    nft: PathBuf,
}

impl Teardown {
    fn new(args: TeardownArgs) -> Result<Self, Error> {
        let (plan, ip, nft) = prepare::resolve(args.uid, &args.vm_id)?;
        Ok(Self { plan, ip, nft })
    }
}

impl IsTool for Teardown {
    type Args = TeardownArgs;
    type Output = NetworkOut;
    type RunT = Result<(), Error>;

    fn run_privileged(&self) -> Self::RunT {
        let commands = args::teardown_commands(&self.plan);
        exec::run_all(&commands, |which| match which {
            args::Which::Ip => self.ip.as_path(),
            args::Which::Nft => self.nft.as_path(),
        })?;
        Ok(())
    }

    fn parse(&self, res: Self::RunT) -> Result<NetworkOut, Box<dyn std::error::Error>> {
        res?;
        Ok(NetworkOut::ToreDown)
    }
}
