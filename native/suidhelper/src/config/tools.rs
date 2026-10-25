// SPDX-License-Identifier: MIT
//! The `[tools]` table and the validated-binary accessors over it.

use super::Config;
use crate::safe::bin::{self, SafeBin};
use serde::Deserialize;
use std::path::PathBuf;
use thiserror::Error;

/// Error returned by config accessors for tool binaries derived from config.
#[derive(Debug, Error)]
pub enum BinError {
    #[error("required binary `{0}` is not configured in /etc/hyper/config.toml")]
    Unconfigured(&'static str),
    #[error(transparent)]
    Bin(#[from] bin::Error),
}

/// Paths to the external binaries the helper runs, the `[tools]` table.
///
/// The device tools (`dmsetup`, `losetup`, `blockdev`, `thin_dump`) carry
/// built-in defaults; `firecracker` and `jailer` have none and must be
/// configured before any VM can launch — their absence surfaces as
/// [`BinError::Unconfigured`] at use time, not at load. Every path is
/// validated as a root-owned, correctly-named [`SafeBin`] when accessed,
/// never at parse time (the file is read unprivileged). A missing `[tools]`
/// table, or any missing key within it, falls back to these defaults.
#[derive(Debug, Deserialize)]
#[serde(default)]
pub struct Tools {
    dmsetup: PathBuf,
    losetup: PathBuf,
    blockdev: PathBuf,
    ip: PathBuf,
    nft: PathBuf,
    sysctl: PathBuf,
    thin_dump: PathBuf,
    firecracker: Option<PathBuf>,
    jailer: Option<PathBuf>,
}

impl Default for Tools {
    fn default() -> Self {
        Self {
            dmsetup: "/usr/sbin/dmsetup".into(),
            losetup: "/usr/sbin/losetup".into(),
            blockdev: "/usr/sbin/blockdev".into(),
            // /usr/bin/ip, not /usr/sbin/ip: on merged-usr distros the latter
            // is a symlink to the former, and SafeBin rejects symlinked tool
            // paths. iproute2's real binary lives at /usr/bin/ip.
            ip: "/usr/bin/ip".into(),
            nft: "/usr/sbin/nft".into(),
            sysctl: "/usr/sbin/sysctl".into(),
            thin_dump: "/usr/sbin/thin_dump".into(),
            firecracker: None,
            jailer: None,
        }
    }
}

fn required<const NAME: &'static str>(path: Option<&PathBuf>) -> Result<SafeBin<NAME>, BinError> {
    let path = path.ok_or(BinError::Unconfigured(NAME))?;
    Ok(SafeBin::from_path(path)?)
}

impl Config {
    /// The validated `dmsetup` binary the helper will run.
    pub fn dmsetup(&self) -> Result<SafeBin<"dmsetup">, bin::Error> {
        SafeBin::from_path(&self.tools.dmsetup)
    }

    /// The validated `losetup` binary the helper will run.
    pub fn losetup(&self) -> Result<SafeBin<"losetup">, bin::Error> {
        SafeBin::from_path(&self.tools.losetup)
    }

    /// The validated `blockdev` binary the helper will run.
    pub fn blockdev(&self) -> Result<SafeBin<"blockdev">, bin::Error> {
        SafeBin::from_path(&self.tools.blockdev)
    }

    /// The validated `ip` (iproute2) binary the network tool runs.
    pub fn ip(&self) -> Result<SafeBin<"ip">, bin::Error> {
        SafeBin::from_path(&self.tools.ip)
    }

    /// The validated `nft` (nftables) binary the network tool runs.
    pub fn nft(&self) -> Result<SafeBin<"nft">, bin::Error> {
        SafeBin::from_path(&self.tools.nft)
    }

    /// The `sysctl` binary, used to enable IPv4 forwarding inside a VM's netns
    /// (a fresh netns defaults `net.ipv4.ip_forward` to 0, independent of the
    /// host, so the netns would not route the guest's egress without it).
    pub fn sysctl(&self) -> Result<SafeBin<"sysctl">, bin::Error> {
        SafeBin::from_path(&self.tools.sysctl)
    }

    /// The validated `thin_dump` binary (thin-provisioning-tools) the helper
    /// will run.
    pub fn thin_dump(&self) -> Result<SafeBin<"thin_dump">, bin::Error> {
        SafeBin::from_path(&self.tools.thin_dump)
    }

    /// The Firecracker VMM binary, validated as root-owned and correctly named.
    /// Errors [`BinError::Unconfigured`] when absent from config — an operator
    /// must set `[tools] firecracker` before any VM can be launched.
    pub fn firecracker(&self) -> Result<SafeBin<"firecracker">, BinError> {
        required(self.tools.firecracker.as_ref())
    }

    /// The Firecracker jailer binary, validated as root-owned and correctly named.
    /// Errors [`BinError::Unconfigured`] when absent from config — an operator
    /// must set `[tools] jailer` before any VM can be launched.
    pub fn jailer(&self) -> Result<SafeBin<"jailer">, BinError> {
        required(self.tools.jailer.as_ref())
    }
}
