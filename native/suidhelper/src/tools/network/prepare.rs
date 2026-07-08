//! `network prepare`: create a VM's netns, host/ns veth pair, TAP device, and
//! in-netns NAT so the guest's inner address can reach the host's uplink.
use super::addr::{AddrError, Plan};
use super::args;
use super::exec;
use super::NetworkOut;
use crate::config::Config;
use crate::tools::jailer::{self, VmId};
use crate::tools::IsTool;
use crate::util::safe_bin;
use clap::Args;
use std::net::Ipv4Addr;
use std::path::PathBuf;
use thiserror::Error as ThisError;

#[derive(Args)]
pub struct PrepareArgs {
    /// Microvm id; becomes the netns name.
    #[arg(long)]
    vm_id: VmId,
    /// Unprivileged uid the VM runs as; derives its clone-pool `/30` slot.
    #[arg(long)]
    uid: u32,
}

#[derive(Debug, ThisError)]
pub enum Error {
    #[error(transparent)]
    NetworkingDisabled(#[from] super::NetworkingDisabled),
    #[error("clone_pool {0:?} is not a valid IPv4 CIDR")]
    InvalidClonePool(String),
    #[error(transparent)]
    Uid(#[from] jailer::Error),
    #[error(transparent)]
    Addr(#[from] AddrError),
    #[error(transparent)]
    Bin(#[from] safe_bin::Error),
    #[error(transparent)]
    Exec(#[from] exec::Error),
}

/// Derive the [`Plan`] for `uid`, refusing before any command is ever run.
/// `uid` must satisfy [`jailer::validate_id_number`] against `range` — the
/// same check the jailer itself applies to `--uid`, so a uid the jailer would
/// refuse is refused here too — and `clone_pool_str` must be a parseable IPv4
/// CIDR.
pub fn plan_from(
    uid: u32,
    range: (u32, u32),
    clone_pool_str: &str,
    vm_id: &VmId,
) -> Result<Plan, Error> {
    jailer::validate_id_number(uid, range)?;
    let clone_pool = parse_cidr_base(clone_pool_str)?;
    Ok(Plan::derive(uid, range, clone_pool, vm_id)?)
}

/// Parse an IPv4 CIDR's base address, e.g. `"172.31.0.0/16"` -> `172.31.0.0`.
/// The prefix length is validated (`0..=32`) but otherwise unused: `Plan::derive`
/// only needs the pool's base address, not its width.
fn parse_cidr_base(s: &str) -> Result<Ipv4Addr, Error> {
    let reject = || Error::InvalidClonePool(s.to_string());
    let mut parts = s.splitn(2, '/');
    let addr: Ipv4Addr = parts
        .next()
        .ok_or_else(reject)?
        .parse()
        .map_err(|_| reject())?;
    let prefix: u8 = parts
        .next()
        .ok_or_else(reject)?
        .parse()
        .map_err(|_| reject())?;
    if prefix > 32 {
        return Err(reject());
    }
    Ok(addr)
}

/// Resolve the [`Plan`] and the config's `ip`/`nft` binaries for a `prepare` or
/// `teardown` op. Shared by both since they derive the identical `Plan` from
/// the same `uid` + config; only the argv sequence they run differs. Every
/// refusal here (`[network]` absent, uid out of range, malformed CIDR, a
/// misconfigured binary) happens before any privileged command is spawned.
pub(super) fn resolve(uid: u32, vm_id: &VmId) -> Result<(Plan, PathBuf, PathBuf), Error> {
    let config = Config::get();
    let network = super::resolve_network(config.network())?;
    let plan = plan_from(uid, config.uid_gid_range(), &network.clone_pool, vm_id)?;
    Ok((plan, config.ip()?.into(), config.nft()?.into()))
}

pub fn run(args: PrepareArgs) -> Result<serde_json::Value, crate::tools::Error> {
    Prepare::new(args)
        .map_err(|e| crate::tools::Error::Tool(Box::new(e)))?
        .run()
}

struct Prepare {
    plan: Plan,
    ip: PathBuf,
    nft: PathBuf,
}

impl Prepare {
    fn new(args: PrepareArgs) -> Result<Self, Error> {
        let (plan, ip, nft) = resolve(args.uid, &args.vm_id)?;
        Ok(Self { plan, ip, nft })
    }
}

impl IsTool for Prepare {
    type Args = PrepareArgs;
    type Output = NetworkOut;
    type RunT = Result<(), Error>;

    fn run_privileged(&self) -> Self::RunT {
        let commands = args::prepare_commands(&self.plan);
        exec::run_all(&commands, |which| match which {
            args::Which::Ip => self.ip.as_path(),
            args::Which::Nft => self.nft.as_path(),
        })?;
        Ok(())
    }

    fn parse(&self, res: Self::RunT) -> Result<NetworkOut, Box<dyn std::error::Error>> {
        res?;
        Ok(NetworkOut::Prepared)
    }
}
