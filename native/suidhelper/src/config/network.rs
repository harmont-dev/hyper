// SPDX-License-Identifier: MIT
//! The `[network]` table.

use super::Config;
use serde::Deserialize;

/// The `[network]` table: VM egress networking. Absent, or present without
/// `uplink`, ⇒ networking disabled — see [`Config::network`]. `uplink` is the
/// physical interface guest traffic is masqueraded out of; `clone_pool` is the
/// IPv4 CIDR per-VM /30 clone addresses are carved from (default
/// `172.31.0.0/16`). Both are read identically by the Elixir node
/// (`Hyper.Cfg.Network`) — keep the defaults in sync.
///
/// `uplink` is `Option` rather than required so that a `[network]` table
/// present with only `clone_pool` set (`uplink` omitted) parses as
/// networking-disabled rather than failing to deserialize the whole
/// [`Config`] — see [`Config::network`]'s doc for why that asymmetry would be
/// dangerous.
#[derive(Debug, Deserialize)]
pub struct Network {
    pub uplink: Option<String>,
    #[serde(default = "default_clone_pool")]
    pub clone_pool: String,
}

fn default_clone_pool() -> String {
    "172.31.0.0/16".into()
}

impl Config {
    /// The `[network]` table, or `None` when VM networking is disabled — either
    /// because `[network]` is absent entirely, or because it is present but
    /// `uplink` is not set.
    ///
    /// The latter case matters on its own: `Config` is a process-wide
    /// [`LazyLock`](std::sync::LazyLock) that exits the whole helper on any
    /// parse failure (every subcommand — dmsetup, losetup, chroot-jail, jailer,
    /// not just networking — calls [`Config::get`] first), so if `uplink` were a
    /// required field, an operator who sets `clone_pool` before `uplink` (or
    /// simply omits `uplink` to disable networking, mirroring the Elixir
    /// node's `Hyper.Cfg.Network.enabled?/0`, which treats absent `uplink` as
    /// disabled rather than an error) would brick every tool the helper
    /// offers, not just networking. Filtering here — rather than making
    /// `uplink` required — keeps this side symmetric with Elixir's.
    pub fn network(&self) -> Option<&Network> {
        self.network
            .as_ref()
            .filter(|network| network.uplink.is_some())
    }
}
