// SPDX-License-Identifier: MIT
//! Runtime host configuration, read from a single root-owned TOML file.
//!
//! ## UID/GID range divergence
//!
//! Elixir keeps a default `{900_000, 999_999}` that governs which UIDs the node
//! hands *out*; this helper reads `[jails] uid_gid_range` from config.toml to
//! decide which UIDs it *accepts* (default [`UidGidRange::DEFAULT`] when the key
//! is absent). Operators narrowing the range must set **both**.

mod network;
mod tools;

pub use network::Network;
pub use tools::{BinError, Tools};

use crate::safe::fs::file::{self, IsRegularFile, OnlyRootWritable, RootOwner, SafeFile};
use crate::safe::fs::path::{self, IsAbsolute, SafePath, StrictComponents};
use crate::vm::UidGidRange;
use nix::fcntl::OFlag;
use serde::Deserialize;
use std::path::PathBuf;
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
    /// `reason` carries serde's message, which is where a value-level refusal
    /// (e.g. an incoherent `uid_gid_range`) surfaces to the operator.
    #[error("{path:?} is not a valid config: {reason}")]
    Malformed { path: PathBuf, reason: String },
    #[error("work_dir in {0:?} must be an absolute path")]
    Relative(PathBuf),
}

const CONFIG_PATHSTR: &str = "/etc/hyper/config.toml";
const INSECURE_CONFIG_PATH_ENV: &str = "HYPER_SETUIDHELPER_CONFIG_PATH";

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
#[derive(Debug, Deserialize)]
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
/// accepts from the BEAM. A missing `[jails]` table, or any missing key within
/// it, falls back to these defaults.
#[derive(Debug, Deserialize)]
#[serde(default)]
pub struct Jails {
    cgroup: String,
    uid_gid_range: UidGidRange,
}

impl Default for Jails {
    fn default() -> Self {
        Self {
            // Must match Elixir node's `@parent_cgroup`; operators need to keep them in sync.
            cgroup: "hyper".into(),
            uid_gid_range: UidGidRange::DEFAULT,
        }
    }
}

impl Default for Config {
    fn default() -> Self {
        Self {
            // Must match the Elixir node's `@dev_work_dir`, which it uses when the
            // same config file is absent, so both sides agree (see
            // `Hyper.Node.check_helper_base`).
            work_dir: PathBuf::from("/srv/hyper"),
            tools: Tools::default(),
            jails: Jails::default(),
            network: None,
        }
    }
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
    /// [`crate::privilege`] runs before `main`), so the file is never first read
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

    /// The jailer `--parent-cgroup` value, from `[jails] cgroup`. Defaults to
    /// `"hyper"`, matching the Elixir node's default.
    pub fn parent_cgroup(&self) -> &str {
        &self.jails.cgroup
    }

    /// The UID/GID band the helper accepts from the BEAM.
    pub fn uid_gid_range(&self) -> UidGidRange {
        self.jails.uid_gid_range
    }

    /// Read, ownership-check, parse, and validate the config file. See the module
    /// docs for the trust model.
    pub fn safe_load() -> Result<Self, LoadingError> {
        let path = config_path();

        let safe_path: &SafePath<IsAbsolute, StrictComponents> = path.as_path().try_into()?;

        let file: SafeFile<IsRegularFile, RootOwner, OnlyRootWritable> =
            match SafeFile::open(safe_path, OFlag::O_RDONLY) {
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

        let body = std::io::read_to_string(std::fs::File::from(file.into_owned_fd()))
            .map_err(|_| LoadingError::Unreadable(path.clone()))?;
        let config: Config = toml::from_str(&body).map_err(|e| LoadingError::Malformed {
            path: path.clone(),
            reason: e.message().to_string(),
        })?;

        if !config.work_dir.is_absolute() {
            return Err(LoadingError::Relative(path));
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
