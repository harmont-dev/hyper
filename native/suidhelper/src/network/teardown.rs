//! `network teardown`: remove a VM's netns, reclaiming its veth peer, TAP
//! device, and in-netns nftables state, plus any lingering host-side veth end.
use super::args;
use super::exec;
use super::prepare;
use hyperrs_firecracker::VmId;
use hyperrs_process::binary::RootSafeBin;
use hyperrs_process::privilege::{PrivilegeError, Unprivileged};
use thiserror::Error as ThisError;

#[derive(Debug, ThisError)]
pub enum NetworkTeardownError {
    #[error(transparent)]
    Plan(#[from] prepare::NetworkPrepareError),
    #[error(transparent)]
    Exec(#[from] exec::ExecError),
    #[error(transparent)]
    Privilege(#[from] PrivilegeError),
}

pub struct Teardown {
    plan: super::addr::Plan,
    ip: RootSafeBin<"ip">,
    nft: RootSafeBin<"nft">,
}

impl Teardown {
    pub fn new(uid: u32, vm_id: &VmId) -> Result<Self, NetworkTeardownError> {
        // Teardown only deletes the netns/veth (no in-netns sysctl), so the
        // resolved sysctl path is unused here.
        let (plan, ip, nft, _sysctl) = prepare::resolve(uid, vm_id)?;
        Ok(Self { plan, ip, nft })
    }
}

impl Teardown {
    pub fn run(&self, token: &mut Unprivileged) -> Result<(), NetworkTeardownError> {
        let commands = args::teardown_commands(&self.plan);
        let root = token.elevate()?;
        exec::run_all(&commands, &root, &[], |which| match which {
            args::Which::Ip => self.ip.command(),
            args::Which::Nft => self.nft.command(),
        })?;
        Ok(())
    }
}
