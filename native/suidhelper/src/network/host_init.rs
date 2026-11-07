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
use crate::config::Config;
use hyperrs_process::binary::{self, RootSafeBin};
use hyperrs_process::privilege::{PrivilegeError, Unprivileged};
use thiserror::Error as ThisError;

/// `/proc` file the kernel exposes IPv4 forwarding through: `1` when enabled.
const IP_FORWARD_PATH: &str = "/proc/sys/net/ipv4/ip_forward";

#[derive(Debug, ThisError)]
pub enum HostInitError {
    #[error(transparent)]
    NetworkingDisabled(#[from] super::NetworkingDisabled),
    #[error(transparent)]
    Bin(#[from] binary::RootSafeBinError),
    #[error(transparent)]
    Exec(#[from] exec::ExecError),
    #[error("failed to read {IP_FORWARD_PATH}: {0}")]
    IpForwardRead(#[source] std::io::Error),
    #[error(
        "net.ipv4.ip_forward is disabled ({IP_FORWARD_PATH} != 1); provision the host with \
         `sysctl -w net.ipv4.ip_forward=1` (see docs/cookbook/install.md) before VM networking \
         can be enabled"
    )]
    IpForwardDisabled,
    #[error(transparent)]
    Privilege(#[from] PrivilegeError),
}

/// Whether `contents` (the raw text of `/proc/sys/net/ipv4/ip_forward`) says
/// forwarding is on. Pure so the parsing rule is testable without root or a
/// real `/proc`; the privileged read itself lives in `run_privileged`.
pub fn ip_forward_enabled(contents: &str) -> bool {
    contents.trim() == "1"
}

pub struct HostInit {
    uplink: String,
    clone_pool: String,
    nft: RootSafeBin<"nft">,
}

impl HostInit {
    pub fn new() -> Result<Self, HostInitError> {
        let config = Config::get();
        let network = super::resolve_network(config.network())?;
        Ok(Self {
            // `Config::network()` only ever returns `Some` when `uplink` is
            // set (see its doc), so `resolve_network`'s `Ok` carries that same
            // guarantee.
            uplink: network
                .uplink
                .clone()
                .expect("Config::network() guarantees uplink is set"),
            clone_pool: network.clone_pool.clone(),
            nft: config.nft()?,
        })
    }
}

impl HostInit {
    pub fn run(&self, token: &mut Unprivileged) -> Result<(), HostInitError> {
        let ip_forward =
            std::fs::read_to_string(IP_FORWARD_PATH).map_err(HostInitError::IpForwardRead)?;
        if !ip_forward_enabled(&ip_forward) {
            return Err(HostInitError::IpForwardDisabled);
        }

        let commands = args::host_init_commands(&self.uplink, &self.clone_pool);
        let root = token.elevate()?;
        // host_init_commands only ever issues `nft` commands (see args.rs).
        exec::run_all(&commands, &root, &[], |_which| self.nft.command())?;
        Ok(())
    }
}
