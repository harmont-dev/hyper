// SPDX-License-Identifier: MIT
//! Runtime host configuration, read from a single root-owned TOML file.
//!
//! TODO(markovejnoivc): This file is a little bit sloppy, and needs some cleanup.
//!
//! ## UID/GID range divergence
//!
//! Elixir keeps a default `{900_000, 999_999}` that governs which UIDs the node
//! hands *out*; this helper reads `[jails] uid_gid_range` from config.toml to
//! decide which UIDs it *accepts* (default `{900_000, 999_999}` when the key is
//! absent). Operators narrowing the range must set **both**.

use crate::id::UidGidRange;
use crate::net::{Blocked, NodePrefix, Resolver};
use hyperrs_fs::file::{self, IsRegularFile, OpenFlags, OwnerOnlyWritable, RootOwner, SafeFile};
use hyperrs_fs::path::{
    self, IsAbsolute, SafePath, SafePathBuf, StrictComponent, StrictComponentBuf, StrictComponents,
};
use hyperrs_linux::cgroup;
use hyperrs_linux::net::{IfName, IpNet, Ipv4Net};
use hyperrs_process::binary::{self, RootSafeBin, RootSafeBinPathBuf};
use serde::{Deserialize, Deserializer};
use serde_with::{serde_as, DisplayFromStr};
use smart_default::SmartDefault;
use std::os::unix::io::OwnedFd;
use std::path::{Path, PathBuf};
use std::sync::LazyLock;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum LoadingError {
    #[error(transparent)]
    Path(#[from] path::ValidationError),
    #[error(transparent)]
    File(#[from] file::ValidationError),
    #[error("{0:?} could not be read")]
    Unreadable(PathBuf),
    #[error("{0:?} is not valid TOML: {1}")]
    Malformed(PathBuf, #[source] toml::de::Error),
}

/// Error returned by config accessors for tool binaries derived from config.
#[derive(Debug, Error)]
pub enum BinError {
    #[error("required binary `{0}` is not configured in /etc/hyper/config.toml")]
    Unconfigured(&'static str),
    #[error(transparent)]
    Bin(#[from] binary::RootSafeBinError),
}

#[derive(Debug, Error)]
#[error("VM networking needs a [net] table in /etc/hyper/config.toml")]
pub struct NetUnconfigured;

const CONFIG_PATHSTR: &str = "/etc/hyper/config.toml";
const INSECURE_CONFIG_PATH_ENV: &str = "HYPER_SETUIDHELPER_CONFIG_PATH";

/// The config file path. In production this is the fixed `/etc/hyper/config.toml`.
/// Only in INSECURE TEST MODE (both gates open) may an env var redirect it — the
/// secure arm is always the hardcoded path, so a release build cannot be steered.
fn config_path() -> PathBuf {
    crate::insecure_mode::select(
        || PathBuf::from(CONFIG_PATHSTR),
        || {
            std::env::var(INSECURE_CONFIG_PATH_ENV)
                .map(PathBuf::from)
                .unwrap_or_else(|_| PathBuf::from(CONFIG_PATHSTR))
        },
    )
}

/// Hyper's /etc/hyper/config.toml file format.
#[derive(Debug, Clone, Deserialize, SmartDefault)]
pub struct Config {
    #[default(default_work_dir())]
    #[serde(deserialize_with = "safe_path")]
    work_dir: SafePathBuf<IsAbsolute, StrictComponents>,
    #[serde(default)]
    tools: Tools,
    #[serde(default)]
    jails: Jails,
    #[serde(default)]
    net: Option<Net>,
}

/// The `[net]` table: where VM traffic leaves the host, and which IPv6 prefix it uses.
///
/// `uplink` is the host interface VMs reach the outside world through (`if0` in the
/// networking cookbook); `ipv6_prefix` is the routed prefix on it, `/64` or shorter.
#[derive(Debug, Clone, Deserialize)]
#[serde(try_from = "RawNet")]
pub struct Net {
    uplink: IfName,
    ipv6_prefix: NodePrefix,
    resolver: Resolver,
    blocked: Blocked,
}

#[serde_as]
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RawNet {
    #[serde_as(as = "DisplayFromStr")]
    uplink: IfName,
    #[serde_as(as = "DisplayFromStr")]
    ipv6_prefix: NodePrefix,
    #[serde_as(as = "DisplayFromStr")]
    #[serde(default)]
    resolver: Resolver,
    #[serde(default)]
    blocked: Blocked,
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum NetError {
    #[error("ipv6_prefix {0} overlaps blocked range {1}, so VMs could not reach each other")]
    PrefixBlocked(NodePrefix, IpNet),
    #[error("resolver {0} is in blocked range {1}, so VMs could not reach it")]
    ResolverBlocked(Resolver, IpNet),
}

impl TryFrom<RawNet> for Net {
    type Error = NetError;

    fn try_from(raw: RawNet) -> Result<Self, NetError> {
        if let Some(range) = raw.blocked.overlapping(IpNet::V6(raw.ipv6_prefix.get())) {
            return Err(NetError::PrefixBlocked(raw.ipv6_prefix, range));
        }
        let resolver = IpNet::V4(Ipv4Net {
            addr: raw.resolver.addr(),
            prefix: 32.try_into().expect("/32 is a valid IPv4 prefix"),
        });
        if let Some(range) = raw.blocked.overlapping(resolver) {
            return Err(NetError::ResolverBlocked(raw.resolver, range));
        }
        Ok(Self {
            uplink: raw.uplink,
            ipv6_prefix: raw.ipv6_prefix,
            resolver: raw.resolver,
            blocked: raw.blocked,
        })
    }
}

impl Net {
    pub fn uplink(&self) -> &IfName {
        &self.uplink
    }

    pub fn ipv6_prefix(&self) -> NodePrefix {
        self.ipv6_prefix
    }

    pub fn resolver(&self) -> Resolver {
        self.resolver
    }

    pub fn blocked(&self) -> &Blocked {
        &self.blocked
    }
}

/// The `[jails]` table: how the helper places and confines each VM jail.
///
/// `cgroup` is the parent cgroup the jailer nests every VM beneath (default
/// `"hyper"`). `uid_gid_range` is the `[min, max]` band of UIDs/GIDs the helper
/// accepts from the BEAM; absent means the built-in default. A missing `[jails]`
/// table, or any missing key within it, falls back to these defaults.
#[derive(Debug, Clone, Deserialize, SmartDefault)]
#[serde(default)]
pub struct Jails {
    #[default(default_parent_cgroup())]
    #[serde(deserialize_with = "strict_component")]
    cgroup: StrictComponentBuf,
    #[serde(deserialize_with = "uid_gid_range")]
    uid_gid_range: UidGidRange,
}

fn uid_gid_range<'de, D: Deserializer<'de>>(deserializer: D) -> Result<UidGidRange, D::Error> {
    UidGidRange::try_from(<[u32; 2]>::deserialize(deserializer)?).map_err(serde::de::Error::custom)
}

fn safe_path<'de, D: Deserializer<'de>>(
    deserializer: D,
) -> Result<SafePathBuf<IsAbsolute, StrictComponents>, D::Error> {
    PathBuf::deserialize(deserializer)?
        .try_into()
        .map_err(serde::de::Error::custom)
}

fn strict_component<'de, D: Deserializer<'de>>(
    deserializer: D,
) -> Result<StrictComponentBuf, D::Error> {
    let raw = String::deserialize(deserializer)?;
    let component: &StrictComponent = raw.as_str().try_into().map_err(serde::de::Error::custom)?;
    Ok(component.to_owned())
}

/// Paths to the external binaries the helper runs, the `[tools]` table.
///
/// The device tools (`dmsetup`, `losetup`, `thin_dump`) carry
/// built-in defaults; `firecracker` and `jailer` have none and must be
/// configured before any VM can launch — their absence surfaces as
/// [`BinError::Unconfigured`] at use time, not at load. Every path is
/// validated as a root-owned, correctly-named [`RootSafeBin`] when accessed,
/// never at parse time (the file is read unprivileged). A missing `[tools]`
/// table, or any missing key within it, falls back to these defaults.
#[derive(Debug, Clone, Deserialize, SmartDefault)]
#[serde(default)]
pub struct Tools {
    #[default("/usr/sbin/dmsetup".into())]
    dmsetup: PathBuf,
    #[default("/usr/sbin/thin_dump".into())]
    thin_dump: PathBuf,
    #[default("/usr/sbin/nft".into())]
    nft: PathBuf,
    firecracker: Option<PathBuf>,
    jailer: Option<PathBuf>,
}

fn required<const NAME: &'static str>(path: &Option<PathBuf>) -> Result<&Path, BinError> {
    path.as_deref().ok_or(BinError::Unconfigured(NAME))
}

// The default data root. Must match the Elixir node's `@dev_work_dir`, which it
// uses when the same config file is absent, so both sides agree (see
// `Hyper.Node.check_helper_base`).
fn default_work_dir() -> SafePathBuf<IsAbsolute, StrictComponents> {
    SafePath::from_static::<"/srv/hyper">().to_owned()
}

const JAILS: &StrictComponent = StrictComponent::from_static("jails");

const SOCKS: &StrictComponent = StrictComponent::from_static("socks");

fn default_parent_cgroup() -> StrictComponentBuf {
    // Must match Elixir node's `@parent_cgroup`; operators need to keep them in sync.
    StrictComponent::from_static("hyper").to_owned()
}

impl Config {
    /// The process-wide config, loaded once (and forced unprivileged by
    /// [`Config::init`]). An absent file yields the built-in defaults; a
    /// *present but untrusted* file (wrong owner/mode, malformed) is fatal —
    /// the helper prints the error and exits rather than trusting it.
    pub fn get() -> &'static Config {
        CONFIG
            .as_ref()
            .expect("Config::init must succeed before the config is read")
    }

    /// Force the config to load now. Call this once at the very start of `main`,
    /// after privileges have already been dropped (the `.preinit_array` entry in
    /// `setuid_privileged` runs before `main`), so the file is never first read
    /// lazily from inside a `Privileged` scope — i.e. it is guaranteed to be read
    /// as the real uid, not as root.
    pub fn init() -> Result<&'static Config, &'static LoadingError> {
        CONFIG.as_ref()
    }

    /// Hyper's data root.
    pub fn hyper_base(&self) -> &SafePath<IsAbsolute, StrictComponents> {
        &self.work_dir
    }

    /// Hyper's jail root, `<work_dir>/jails`.
    pub fn jail_base(&self) -> SafePathBuf<IsAbsolute, StrictComponents> {
        self.work_dir.join(JAILS)
    }

    pub fn socket_dir(&self) -> SafePathBuf<IsAbsolute, StrictComponents> {
        self.work_dir.join(SOCKS)
    }

    /// The validated `dmsetup` binary the helper will run.
    pub fn dmsetup(&self) -> Result<RootSafeBin<"dmsetup">, binary::RootSafeBinError> {
        RootSafeBin::open(&self.tools.dmsetup)
    }

    /// The validated `thin_dump` binary (thin-provisioning-tools) the helper
    /// will run.
    pub fn thin_dump(&self) -> Result<RootSafeBin<"thin_dump">, binary::RootSafeBinError> {
        RootSafeBin::open(&self.tools.thin_dump)
    }

    /// The validated `nft` binary (nftables) the helper will run.
    pub fn nft(&self) -> Result<RootSafeBin<"nft">, binary::RootSafeBinError> {
        RootSafeBin::open(&self.tools.nft)
    }

    /// The `[net]` table. Errors [`NetUnconfigured`] when absent: no VM can be networked
    /// without it.
    pub fn net(&self) -> Result<&Net, NetUnconfigured> {
        self.net.as_ref().ok_or(NetUnconfigured)
    }

    /// The Firecracker VMM binary, validated as root-owned and correctly named.
    /// Errors [`BinError::Unconfigured`] when absent from config — an operator
    /// must set `[tools] firecracker` before any VM can be launched.
    pub fn firecracker(&self) -> Result<RootSafeBinPathBuf<"firecracker">, BinError> {
        Ok(RootSafeBinPathBuf::open(required::<"firecracker">(
            &self.tools.firecracker,
        )?)?)
    }

    /// The Firecracker jailer binary, validated as root-owned and correctly named.
    /// Errors [`BinError::Unconfigured`] when absent from config — an operator
    /// must set `[tools] jailer` before any VM can be launched.
    pub fn jailer(&self) -> Result<RootSafeBin<"jailer">, BinError> {
        Ok(RootSafeBin::open(required::<"jailer">(
            &self.tools.jailer,
        )?)?)
    }

    /// The jailer `--parent-cgroup` value, from `[jails] cgroup`. Defaults to
    /// `"hyper"`, matching the Elixir node's default.
    pub fn parent_cgroup(&self) -> &StrictComponent {
        &self.jails.cgroup
    }

    pub fn parent_cgroup_dir(&self) -> SafePathBuf<IsAbsolute, StrictComponents> {
        SafePath::from_static::<{ cgroup::ROOT }>().join(&self.jails.cgroup)
    }

    /// The UID/GID band the helper accepts from the BEAM. Defaults to
    /// `(900_000, 999_999)` when the key is absent (matching Elixir's defaults).
    /// A present range with min==0 or min>max is rejected at load time by
    /// [`Config::safe_load`], so this accessor is always total.
    pub fn uid_gid_range(&self) -> UidGidRange {
        self.jails.uid_gid_range
    }

    /// Read, ownership-check, parse, and validate the config file. See the module
    /// docs for the trust model.
    pub fn safe_load() -> Result<Self, LoadingError> {
        let path = config_path();

        let safe_path: &SafePath<IsAbsolute, StrictComponents> = path.as_path().try_into()?;

        let file: SafeFile<IsRegularFile, RootOwner, OwnerOnlyWritable> =
            match SafeFile::open(safe_path, OpenFlags::RDONLY) {
                Ok(file) => file,
                // A genuinely-absent file means "use the built-in defaults": those
                // are compiled into this root-owned binary, so they are trusted. Any
                // OTHER failure — a present but wrong-owner/mode file, an I/O error —
                // stays fatal, because it is a signal (someone put an untrusted file
                // there), not an absence.
                Err(file::ValidationError::Open(nix::errno::Errno::ENOENT)) => {
                    return Ok(Self::default())
                }
                Err(e) => return Err(e.into()),
            };

        let body = std::io::read_to_string(std::fs::File::from(OwnedFd::from(file)))
            .map_err(|_| LoadingError::Unreadable(path.clone()))?;
        let config: Config =
            toml::from_str(&body).map_err(|e| LoadingError::Malformed(path.clone(), e))?;

        Ok(config)
    }
}

/// The process-wide config, loaded once on first access via [`Config::get`].
static CONFIG: LazyLock<Result<Config, LoadingError>> = LazyLock::new(Config::safe_load);

#[cfg(test)]
mod tests {
    use super::Net;
    use crate::net::{Blocked, Resolver};
    use pretty_assertions::assert_eq;
    use proptest::prelude::*;
    use rstest::rstest;
    use std::assert_matches;
    use std::net::Ipv4Addr;
    use test_strategy::proptest;

    fn net(prefix: &str, lines: &str) -> Result<Net, toml::de::Error> {
        toml::from_str(&format!(
            "uplink = \"eth0\"\nipv6_prefix = \"{prefix}\"\n{lines}"
        ))
    }

    fn refusal(prefix: &str, lines: &str) -> Option<String> {
        net(prefix, lines).err().map(|e| e.message().to_owned())
    }

    #[rstest]
    #[case::an_operator_prefix_range(
        "2001:db8:1::/48",
        "blocked = [\"2001:db8::/32\"]",
        "overlaps blocked range 2001:db8::/32"
    )]
    #[case::six_to_four_prefix("2002:c000:204::/48", "", "overlaps blocked range 2002::/16")]
    #[case::private_resolver(
        "2001:db8::/64",
        "resolver = \"10.0.0.53\"",
        "in blocked range 10.0.0.0/8"
    )]
    #[case::metadata_resolver(
        "2001:db8::/64",
        "resolver = \"169.254.169.254\"",
        "in blocked range 169.254.0.0/16"
    )]
    #[case::an_operator_range(
        "2001:db8::/64",
        "resolver = \"203.0.113.5\"\nblocked = [\"203.0.113.0/24\"]",
        "in blocked range 203.0.113.0/24"
    )]
    fn a_prefix_or_resolver_vms_could_not_reach_is_refused(
        #[case] prefix: &str,
        #[case] lines: &str,
        #[case] message: &str,
    ) {
        let refusal = refusal(prefix, lines).expect("the [net] table must be refused");
        assert!(refusal.contains(message), "{refusal}");
    }

    #[rstest]
    #[case::opted_out_prefix("2002:c000:204::/48", "blocked = []")]
    #[case::opted_out_resolver("2001:db8::/64", "resolver = \"10.0.0.53\"\nblocked = []")]
    #[case::replaced_list(
        "2001:db8::/64",
        "resolver = \"10.0.0.53\"\nblocked = [\"203.0.113.0/24\"]"
    )]
    fn an_operator_list_replaces_the_default(#[case] prefix: &str, #[case] lines: &str) {
        assert_matches!(net(prefix, lines), Ok(_));
    }

    #[rstest]
    #[case::defaulted("", Blocked::default())]
    #[case::configured(
        "blocked = [\"203.0.113.0/24\"]",
        Blocked::try_from(vec!["203.0.113.0/24".to_owned()]).unwrap()
    )]
    fn the_net_table_yields_its_blocked_ranges(#[case] lines: &str, #[case] blocked: Blocked) {
        assert_eq!(net("2001:db8::/64", lines).unwrap().blocked(), &blocked);
    }

    #[rstest]
    fn a_blocked_entry_must_be_a_cidr() {
        assert!(refusal("2001:db8::/64", "blocked = [\"10.0.0.0\"]").is_some());
    }

    #[proptest]
    fn every_address_in_a_default_blocked_ipv4_range_is_refused_as_a_resolver(
        #[strategy(prop_oneof![
            (0u32..1 << 24).prop_map(|host| (10u32 << 24) | host),
            (0u32..1 << 20).prop_map(|host| ((172u32 << 24) | (16 << 16)) | host),
            (0u32..1 << 16).prop_map(|host| ((192u32 << 24) | (168 << 16)) | host),
            (0u32..1 << 22).prop_map(|host| ((100u32 << 24) | (64 << 16)) | host),
            (0u32..1 << 16).prop_map(|host| ((169u32 << 24) | (254 << 16)) | host),
        ])]
        addr: u32,
    ) {
        let addr = Ipv4Addr::from(addr);
        let err = net("2001:db8::/64", &format!("resolver = \"{addr}\""));
        prop_assert!(err.is_err(), "{addr} was accepted");
    }

    #[rstest]
    #[case::configured("resolver = \"9.9.9.9\"", "9.9.9.9")]
    #[case::defaulted("", "1.1.1.1")]
    fn the_net_table_yields_its_resolver(#[case] line: &str, #[case] resolver: &str) {
        let net: Net = toml::from_str(&format!(
            "uplink = \"eth0\"\nipv6_prefix = \"2001:db8::/64\"\n{line}"
        ))
        .unwrap();

        assert_eq!(net.resolver(), resolver.parse::<Resolver>().unwrap());
    }
}
