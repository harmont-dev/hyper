//! `network teardown-orphan`: reclaim a crashed node's leaked VM netns by
//! vm_id alone. Unlike [`super::teardown`], this takes no `uid` — a crashed
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
use super::NetworkOut;
use crate::config::Config;
use crate::firecracker::jailer::VmId;
use crate::process::binary::{self, RootSafeBin};
use crate::process::privilege::{Root, Unprivileged};
use crate::tools::IsTool;
use clap::Args;
use thiserror::Error as ThisError;

#[derive(Args)]
pub struct TeardownOrphanArgs {
    /// Microvm id; names the netns to remove. No `uid` — see the module doc.
    #[arg(long)]
    vm_id: VmId,
}

#[derive(Debug, ThisError)]
pub enum Error {
    #[error(transparent)]
    NetworkingDisabled(#[from] super::NetworkingDisabled),
    #[error(transparent)]
    Bin(#[from] binary::Error),
    #[error("running ip {argv:?}: {source}")]
    Spawn {
        argv: Vec<String>,
        #[source]
        source: std::io::Error,
    },
    #[error("ip {argv:?} failed: {stderr}")]
    Failed { argv: Vec<String>, stderr: String },
}

pub fn run(
    args: TeardownOrphanArgs,
    token: &mut Unprivileged,
) -> Result<serde_json::Value, crate::tools::Error> {
    TeardownOrphan::new(args)
        .map_err(|e| crate::tools::Error::Tool(Box::new(e)))?
        .run(token)
}

struct TeardownOrphan {
    netns: String,
    ip: RootSafeBin<"ip">,
}

impl TeardownOrphan {
    fn new(args: TeardownOrphanArgs) -> Result<Self, Error> {
        let config = Config::get();
        super::resolve_network(config.network())?;
        Ok(Self {
            netns: args.vm_id.to_string(),
            ip: config.ip()?,
        })
    }
}

impl IsTool for TeardownOrphan {
    type Args = TeardownOrphanArgs;
    type Output = NetworkOut;
    type RunT = Result<(), Error>;

    fn run_privileged(&self, _root: &Root<'_>) -> Self::RunT {
        run_idempotent(&args::teardown_orphan_commands(&self.netns), &self.ip)
    }

    fn parse(&self, res: Self::RunT) -> Result<NetworkOut, Box<dyn std::error::Error>> {
        res?;
        Ok(NetworkOut::ToreDown)
    }
}

/// Run each command against `ip`, tolerating an ENOENT-shaped failure (the
/// namespace is already gone) as success. Kept separate from
/// `super::exec::run_all`, whose contract for `prepare`/`teardown` is that
/// any non-`allow_failure` non-zero exit is a real error — this op's whole
/// point is that a missing netns is *not* an error.
fn run_idempotent(commands: &[Command], ip: &RootSafeBin<"ip">) -> Result<(), Error> {
    for command in commands {
        let output = ip
            .command()
            .args(&command.argv)
            .env_clear()
            .output()
            .map_err(|source| Error::Spawn {
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

        return Err(Error::Failed {
            argv: command.argv.clone(),
            stderr,
        });
    }
    Ok(())
}

fn is_enoent(stderr: &str) -> bool {
    stderr.to_lowercase().contains("no such file or directory")
}
