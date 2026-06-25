// SPDX-License-Identifier: AGPL-3.0-only
//! Runtime host configuration, read from a single root-owned TOML file.

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
#[derive(Debug, Clone, Deserialize)]
pub struct Config {
    work_dir: PathBuf,
    #[serde(default = "default_dmsetup")]
    dmsetup: PathBuf,
    #[serde(default = "default_losetup")]
    losetup: PathBuf,
    #[serde(default = "default_blockdev")]
    blockdev: PathBuf,
}

// The default data root. Must match the Elixir node's `@dev_work_dir`, which it
// uses when the same config file is absent, so both sides agree (see
// `Hyper.Node.check_helper_base`).
fn default_work_dir() -> PathBuf {
    PathBuf::from("/srv/hyper")
}

fn default_dmsetup() -> PathBuf {
    PathBuf::from("/usr/sbin/dmsetup")
}

fn default_losetup() -> PathBuf {
    PathBuf::from("/usr/sbin/losetup")
}

fn default_blockdev() -> PathBuf {
    PathBuf::from("/usr/sbin/blockdev")
}

impl Default for Config {
    fn default() -> Self {
        Self {
            work_dir: default_work_dir(),
            dmsetup: default_dmsetup(),
            losetup: default_losetup(),
            blockdev: default_blockdev(),
        }
    }
}

impl Config {
    /// The process-wide config, loaded once (and forced unprivileged by
    /// [`Config::init`]). An absent file yields the built-in defaults; a
    /// *present but untrusted* file (wrong owner/mode, malformed) is fatal -
    /// the helper prints the error and exits rather than trusting it.
    pub fn get() -> &'static Config {
        LazyLock::force(&CONFIG)
    }

    /// Force the config to load now. Call this once at the very start of `main`,
    /// after privileges have already been dropped (the `.preinit_array` entry in
    /// `setuid_privileged` runs before `main`), so the file is never first read
    /// lazily from inside a `Privileged` scope - i.e. it is guaranteed to be read
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
        SafeBin::from_path(&self.dmsetup)
    }

    /// The validated `losetup` binary the helper will run.
    pub fn losetup(&self) -> Result<SafeBin<"losetup">, safe_bin::Error> {
        SafeBin::from_path(&self.losetup)
    }

    /// The validated `blockdev` binary the helper will run.
    pub fn blockdev(&self) -> Result<SafeBin<"blockdev">, safe_bin::Error> {
        SafeBin::from_path(&self.blockdev)
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
                // OTHER failure - a present but wrong-owner/mode file, an I/O error -
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
