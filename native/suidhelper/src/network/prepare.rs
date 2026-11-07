//! `network prepare`: create a VM's netns, host/ns veth pair, TAP device, and
//! in-netns NAT so the guest's inner address can reach the host's uplink.
use super::addr::{AddrError, Plan};
use super::args;
use super::exec;
use crate::config::Config;
use crate::id::{IdError, UidGidRange};
use hyperrs_firecracker::VmId;
use hyperrs_process::binary::{self, RootSafeBin};
use hyperrs_process::privilege::{PrivilegeError, Unprivileged};
use std::net::Ipv4Addr;
use std::os::unix::io::AsFd;
use thiserror::Error as ThisError;

#[derive(Debug, ThisError)]
pub enum NetworkPrepareError {
    #[error(transparent)]
    NetworkingDisabled(#[from] super::NetworkingDisabled),
    #[error("clone_pool {0:?} is not a valid IPv4 CIDR")]
    InvalidClonePool(String),
    #[error(transparent)]
    Uid(#[from] IdError),
    #[error(transparent)]
    Addr(#[from] AddrError),
    #[error(transparent)]
    Bin(#[from] binary::RootSafeBinError),
    #[error(transparent)]
    Exec(#[from] exec::ExecError),
    #[error(transparent)]
    Privilege(#[from] PrivilegeError),
}

/// Derive the [`Plan`] for `uid`, refusing before any command is ever run.
/// `uid` must satisfy [`UidGidRange::uid`] against `range` — the
/// same check the jailer itself applies to `--uid`, so a uid the jailer would
/// refuse is refused here too — and `clone_pool_str` must be a parseable IPv4
/// CIDR.
pub fn plan_from(
    uid: u32,
    range: UidGidRange,
    clone_pool_str: &str,
    vm_id: &VmId,
) -> Result<Plan, NetworkPrepareError> {
    let uid = range.uid(uid)?;
    let clone_pool = parse_cidr_base(clone_pool_str)?;
    Ok(Plan::derive(uid, range, clone_pool, vm_id)?)
}

/// Parse an IPv4 CIDR's base address, e.g. `"172.31.0.0/16"` -> `172.31.0.0`.
/// The prefix length is validated (`0..=32`) but otherwise unused: `Plan::derive`
/// only needs the pool's base address, not its width.
fn parse_cidr_base(s: &str) -> Result<Ipv4Addr, NetworkPrepareError> {
    let reject = || NetworkPrepareError::InvalidClonePool(s.to_string());
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
pub(super) fn resolve(
    uid: u32,
    vm_id: &VmId,
) -> Result<
    (
        Plan,
        RootSafeBin<"ip">,
        RootSafeBin<"nft">,
        RootSafeBin<"sysctl">,
    ),
    NetworkPrepareError,
> {
    let config = Config::get();
    let network = super::resolve_network(config.network())?;
    let plan = plan_from(uid, config.uid_gid_range(), &network.clone_pool, vm_id)?;
    Ok((plan, config.ip()?, config.nft()?, config.sysctl()?))
}

pub struct Prepare {
    plan: Plan,
    ip: RootSafeBin<"ip">,
    nft: RootSafeBin<"nft">,
    sysctl: RootSafeBin<"sysctl">,
}

impl Prepare {
    pub fn new(uid: u32, vm_id: &VmId) -> Result<Self, NetworkPrepareError> {
        let (plan, ip, nft, sysctl) = resolve(uid, vm_id)?;
        Ok(Self {
            plan,
            ip,
            nft,
            sysctl,
        })
    }
}

impl Prepare {
    pub fn run(&self, token: &mut Unprivileged) -> Result<(), NetworkPrepareError> {
        let commands = args::prepare_commands(
            &self.plan,
            &self.nft.fd_path().to_string_lossy(),
            &self.sysctl.fd_path().to_string_lossy(),
        );
        let inherit = [self.nft.as_fd(), self.sysctl.as_fd()];
        let root = token.elevate()?;
        exec::run_all(&commands, &root, &inherit, |which| match which {
            args::Which::Ip => self.ip.command(),
            args::Which::Nft => self.nft.command(),
        })?;
        Ok(())
    }
}
