// SPDX-License-Identifier: MIT
//! Runtime host configuration, read from a single root-owned TOML file.
//!
//! ## UID/GID range divergence
//!
//! Elixir keeps a default `{900_000, 999_999}` that governs which UIDs the node
//! hands *out*; this helper reads `[jails] uid_gid_range` from config.toml to
//! decide which UIDs it *accepts* (default `{900_000, 999_999}` when the key is
//! absent). Operators narrowing the range must set **both**.

use crate::util::safe_bin::{self, SafeBin};
use crate::util::safe_file::{self, IsRegularFile, OnlyRootWritable, RootOwner, SafeFile};
use crate::util::safe_path::{self, IsAbsolute, SafePath, StrictComponents};
use nix::fcntl::OFlag;
use serde::Deserialize;
use std::path::PathBuf;
use std::sync::LazyLock;
use thiserror::Error;

#[derive(Debug, Clone, Error)]
pub enum LoadingError {
    #[error(transparent)]
    Path(#[from] safe_path::ValidationError),
    #[error(transparent)]
    File(#[from] safe_file::ValidationError),
    #[error("{0:?} could not be read")]
    Unreadable(PathBuf),
    #[error("{0:?} is not valid TOML")]
    Malformed(PathBuf),
    #[error("work_dir in {0:?} must be an absolute path")]
    Relative(PathBuf),
    #[error("uid_gid_range.min must be >= 1 and <= max (got min={min}, max={max})")]
    BadUidGidRange { min: u32, max: u32 },
}

/// Error returned by config accessors for tool binaries derived from config.
#[derive(Debug, Error)]
pub enum BinError {
    #[error("required binary `{0}` is not configured in /etc/hyper/config.toml")]
    Unconfigured(&'static str),
    #[error(transparent)]
    Bin(#[from] safe_bin::Error),
}

const CONFIG_PATHSTR: &str = "/etc/hyper/config.toml";
const INSECURE_CONFIG_PATH_ENV: &str = "HYPER_SETUIDHELPER_CONFIG_PATH";

/// UID/GID allocation band, read from `[jails] uid_gid_range` in config.toml as
/// a two-element `[min, max]` array. Controls which UIDs the helper *accepts*
/// from the BEAM — see module docs.
#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(from = "[u32; 2]")]
pub struct UidGidRange {
    pub min: u32,
    pub max: u32,
}

impl From<[u32; 2]> for UidGidRange {
    fn from([min, max]: [u32; 2]) -> Self {
        Self { min, max }
    }
}

// Band defaults match Elixir's `compile_env` allocation defaults so that an
// unconfigured helper and an unconfigured node agree out of the box.
const DEFAULT_UID_GID: (u32, u32) = (900_000, 999_999);

/// Validate a uid_gid_range value. A present range where min==0 or min>max is
/// treated as a config trust violation — fatal at load, consistent with the
/// "present but untrusted" model. Exposed so tests can verify the contract
/// without touching the file system.
pub fn validate_uid_gid_range(r: &UidGidRange) -> Result<(), LoadingError> {
    if r.min == 0 || r.min > r.max {
        return Err(LoadingError::BadUidGidRange {
            min: r.min,
            max: r.max,
        });
    }
    Ok(())
}

/// The config file path. In production this is the fixed `/etc/hyper/config.toml`.
/// Only in INSECURE TEST MODE (both gates open) may an env var redirect it — the
/// secure arm is always the hardcoded path, so a release build cannot be steered.
fn config_path() -> PathBuf {
    crate::security_gate::split(
        || PathBuf::from(CONFIG_PATHSTR),
        || {
            std::env::var(INSECURE_CONFIG_PATH_ENV)
                .map(PathBuf::from)
                .unwrap_or_else(|_| PathBuf::from(CONFIG_PATHSTR))
        },
    )
}

/// Hyper's /etc/hyper/config.toml file format.
#[derive(Debug, Clone, Deserialize)]
pub struct Config {
    work_dir: PathBuf,
    #[serde(default)]
    tools: Tools,
    #[serde(default)]
    jails: Jails,
    #[serde(default)]
    network: Option<Network>,
}

/// The `[jails]` table: how the helper places and confines each VM jail.
///
/// `cgroup` is the parent cgroup the jailer nests every VM beneath (default
/// `"hyper"`). `uid_gid_range` is the `[min, max]` band of UIDs/GIDs the helper
/// accepts from the BEAM; absent means the built-in default. A missing `[jails]`
/// table, or any missing key within it, falls back to these defaults.
#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
pub struct Jails {
    cgroup: String,
    uid_gid_range: Option<UidGidRange>,
}

impl Default for Jails {
    fn default() -> Self {
        Self {
            cgroup: default_parent_cgroup(),
            uid_gid_range: None,
        }
    }
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
#[derive(Debug, Clone, Deserialize)]
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

// The default data root. Must match the Elixir node's `@dev_work_dir`, which it
// uses when the same config file is absent, so both sides agree (see
// `Hyper.Node.check_helper_base`).
fn default_work_dir() -> PathBuf {
    PathBuf::from("/srv/hyper")
}

fn default_parent_cgroup() -> String {
    // Must match Elixir node's `@parent_cgroup`; operators need to keep them in sync.
    "hyper".into()
}

impl Default for Config {
    fn default() -> Self {
        Self {
            work_dir: default_work_dir(),
            tools: Tools::default(),
            jails: Jails::default(),
            network: None,
        }
    }
}

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
#[derive(Debug, Clone, Deserialize)]
pub struct Network {
    pub uplink: Option<String>,
    #[serde(default = "default_clone_pool")]
    pub clone_pool: String,
}

fn default_clone_pool() -> String {
    "172.31.0.0/16".into()
}

impl Config {
    /// The process-wide config, loaded once (and forced unprivileged by
    /// [`Config::init`]). An absent file yields the built-in defaults; a
    /// *present but untrusted* file (wrong owner/mode, malformed) is fatal —
    /// the helper prints the error and exits rather than trusting it.
    pub fn get() -> &'static Config {
        LazyLock::force(&CONFIG)
    }

    /// Force the config to load now. Call this once at the very start of `main`,
    /// after privileges have already been dropped (the `.preinit_array` entry in
    /// `setuid_privileged` runs before `main`), so the file is never first read
    /// lazily from inside a `Privileged` scope — i.e. it is guaranteed to be read
    /// as the real uid, not as root.
    pub fn init() {
        let _ = Self::get();
    }

    /// Hyper's data root.
    pub fn hyper_base(&self) -> &std::path::Path {
        self.work_dir.as_path()
    }

    /// Hyper's jail root, `<work_dir>/jails`.
    pub fn jail_base(&self) -> PathBuf {
        self.work_dir.join("jails")
    }

    /// The validated `dmsetup` binary the helper will run.
    pub fn dmsetup(&self) -> Result<SafeBin<"dmsetup">, safe_bin::Error> {
        SafeBin::from_path(&self.tools.dmsetup)
    }

    /// The validated `losetup` binary the helper will run.
    pub fn losetup(&self) -> Result<SafeBin<"losetup">, safe_bin::Error> {
        SafeBin::from_path(&self.tools.losetup)
    }

    /// The validated `blockdev` binary the helper will run.
    pub fn blockdev(&self) -> Result<SafeBin<"blockdev">, safe_bin::Error> {
        SafeBin::from_path(&self.tools.blockdev)
    }

    /// The validated `ip` (iproute2) binary the network tool runs.
    pub fn ip(&self) -> Result<SafeBin<"ip">, safe_bin::Error> {
        SafeBin::from_path(&self.tools.ip)
    }

    /// The validated `nft` (nftables) binary the network tool runs.
    pub fn nft(&self) -> Result<SafeBin<"nft">, safe_bin::Error> {
        SafeBin::from_path(&self.tools.nft)
    }

    /// The `sysctl` binary, used to enable IPv4 forwarding inside a VM's netns
    /// (a fresh netns defaults `net.ipv4.ip_forward` to 0, independent of the
    /// host, so the netns would not route the guest's egress without it).
    pub fn sysctl(&self) -> Result<SafeBin<"sysctl">, safe_bin::Error> {
        SafeBin::from_path(&self.tools.sysctl)
    }

    /// The `[network]` table, or `None` when VM networking is disabled — either
    /// because `[network]` is absent entirely, or because it is present but
    /// `uplink` is not set.
    ///
    /// The latter case matters on its own: `Config` is a process-wide
    /// [`LazyLock`] that exits the whole helper on any parse failure (every
    /// subcommand — dmsetup, losetup, chroot-jail, jailer, not just
    /// networking — calls [`Config::get`] first), so if `uplink` were a
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

    /// The validated `thin_dump` binary (thin-provisioning-tools) the helper
    /// will run.
    pub fn thin_dump(&self) -> Result<SafeBin<"thin_dump">, safe_bin::Error> {
        SafeBin::from_path(&self.tools.thin_dump)
    }

    /// The Firecracker VMM binary, validated as root-owned and correctly named.
    /// Errors [`BinError::Unconfigured`] when absent from config — an operator
    /// must set `[tools] firecracker` before any VM can be launched.
    pub fn firecracker(&self) -> Result<SafeBin<"firecracker">, BinError> {
        self.tools
            .firecracker
            .as_deref()
            .ok_or(BinError::Unconfigured("firecracker"))
            .and_then(|p| SafeBin::from_path(p).map_err(BinError::Bin))
    }

    /// The Firecracker jailer binary, validated as root-owned and correctly named.
    /// Errors [`BinError::Unconfigured`] when absent from config — an operator
    /// must set `[tools] jailer` before any VM can be launched.
    pub fn jailer(&self) -> Result<SafeBin<"jailer">, BinError> {
        self.tools
            .jailer
            .as_deref()
            .ok_or(BinError::Unconfigured("jailer"))
            .and_then(|p| SafeBin::from_path(p).map_err(BinError::Bin))
    }

    /// The jailer `--parent-cgroup` value, from `[jails] cgroup`. Defaults to
    /// `"hyper"`, matching the Elixir node's default.
    pub fn parent_cgroup(&self) -> &str {
        &self.jails.cgroup
    }

    /// The UID/GID band the helper accepts from the BEAM. Defaults to
    /// `(900_000, 999_999)` when the key is absent (matching Elixir's defaults).
    /// A present range with min==0 or min>max is rejected at load time by
    /// [`Config::safe_load`], so this accessor is always total.
    pub fn uid_gid_range(&self) -> (u32, u32) {
        self.jails
            .uid_gid_range
            .map(|r| (r.min, r.max))
            .unwrap_or(DEFAULT_UID_GID)
    }

    /// Read, ownership-check, parse, and validate the config file. See the module
    /// docs for the trust model.
    pub fn safe_load() -> Result<Self, LoadingError> {
        let path = config_path();

        let safe_path: SafePath<IsAbsolute, StrictComponents> = path.clone().try_into()?;

        let file: SafeFile<IsRegularFile, RootOwner, OnlyRootWritable> =
            match SafeFile::open(&safe_path, OFlag::O_RDONLY) {
                Ok(file) => file,
                // A genuinely-absent file means "use the built-in defaults": those
                // are compiled into this root-owned binary, so they are trusted. Any
                // OTHER failure — a present but wrong-owner/mode file, an I/O error —
                // stays fatal, because it is a signal (someone put an untrusted file
                // there), not an absence.
                Err(safe_file::ValidationError::Open(nix::errno::Errno::ENOENT)) => {
                    return Ok(Self::default())
                }
                Err(e) => return Err(e.into()),
            };

        let body = std::io::read_to_string(std::fs::File::from(file.into_owned_fd()))
            .map_err(|_| LoadingError::Unreadable(path.clone()))?;
        let config: Config =
            toml::from_str(&body).map_err(|_| LoadingError::Malformed(path.clone()))?;

        if !config.work_dir.is_absolute() {
            return Err(LoadingError::Relative(path));
        }

        if let Some(r) = &config.jails.uid_gid_range {
            validate_uid_gid_range(r)?;
        }

        Ok(config)
    }
}

/// The process-wide config, loaded once on first access via [`Config::get`].
static CONFIG: LazyLock<Config> = LazyLock::new(|| {
    Config::safe_load().unwrap_or_else(|e| {
        eprintln!("hyper-suidhelper: {e}");
        std::process::exit(2);
    })
});
