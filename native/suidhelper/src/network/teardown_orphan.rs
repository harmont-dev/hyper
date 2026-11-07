//! `network teardown-orphan`: reclaim a crashed node's leaked VM netns by
//! vm_id alone. Unlike [`super::teardown`](mod@super::teardown), this takes no `uid` — a crashed
//! node never persisted one for `Hyper.Node.Reaper` to pass back in — so it
//! cannot derive a full [`super::addr::Plan`] and instead runs the one
//! command that needs no derived address or interface name: `ip netns del
//! <vm_id>`, which reclaims the ns-side veth peer, TAP device, and in-netns
//! nftables state with it (see `args::teardown_orphan_commands`).
//!
//! Idempotent by design, not by accident: the reaper races a normal
//! `teardown/2` that may already have deleted the netns (or one that never
//! finished being created), so `ip netns del` failing with "No such file or
//! directory" is treated as success rather than propagated. Any other
//! failure (wrong permissions, `ip` itself unusable) still errors. The real
//! ENOENT path only exists once a genuine `/var/run/netns` entry is deleted
//! out from under a concurrent call, which needs root and a real netns to
//! exercise — covered by the root e2e / reaper e2e suites, not this crate's
//! unit tests.
use super::args::{self, Command};
use crate::config::Config;
use hyperrs_firecracker::VmId;
use hyperrs_process::binary::{self, RootSafeBin};
use hyperrs_process::privilege::{PrivilegeError, Unprivileged};
use thiserror::Error as ThisError;

#[derive(Debug, ThisError)]
pub enum OrphanTeardownError {
    #[error(transparent)]
    NetworkingDisabled(#[from] super::NetworkingDisabled),
    #[error(transparent)]
    Bin(#[from] binary::RootSafeBinError),
    #[error("running ip {argv:?}: {source}")]
    Spawn {
        argv: Vec<String>,
        #[source]
        source: std::io::Error,
    },
    #[error("ip {argv:?} failed: {stderr}")]
    Failed { argv: Vec<String>, stderr: String },
    #[error(transparent)]
    Privilege(#[from] PrivilegeError),
}

pub(super) struct TeardownOrphan {
    netns: String,
    ip: RootSafeBin<"ip">,
}

impl TeardownOrphan {
    pub(super) fn new(vm_id: &VmId) -> Result<Self, OrphanTeardownError> {
        let config = Config::get();
        super::resolve_network(config.network())?;
        Ok(Self {
            netns: vm_id.to_string(),
            ip: config.ip()?,
        })
    }
}

impl TeardownOrphan {
    pub(super) fn run(&self, token: &mut Unprivileged) -> Result<(), OrphanTeardownError> {
        let commands = args::teardown_orphan_commands(&self.netns);
        let _root = token.elevate()?;
        run_idempotent(&commands, &self.ip)
    }
}

/// Run each command against `ip`, tolerating an ENOENT-shaped failure (the
/// namespace is already gone) as success. Kept separate from
/// `super::exec::run_all`, whose contract for `prepare`/`teardown` is that
/// any non-`allow_failure` non-zero exit is a real error — this op's whole
/// point is that a missing netns is *not* an error.
fn run_idempotent(commands: &[Command], ip: &RootSafeBin<"ip">) -> Result<(), OrphanTeardownError> {
    for command in commands {
        let output = ip
            .command()
            .args(&command.argv)
            .env_clear()
            .output()
            .map_err(|source| OrphanTeardownError::Spawn {
                argv: command.argv.clone(),
                source,
            })?;

        if output.status.success() {
            continue;
        }

        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        if is_enoent(&stderr) {
            continue;
        }

        return Err(OrphanTeardownError::Failed {
            argv: command.argv.clone(),
            stderr,
        });
    }
    Ok(())
}

fn is_enoent(stderr: &str) -> bool {
    stderr.to_lowercase().contains("no such file or directory")
}
