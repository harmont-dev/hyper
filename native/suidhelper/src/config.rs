// SPDX-License-Identifier: AGPL-3.0-only
//! Runtime host configuration, read from a single root-owned TOML file.

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
}

impl Config {
    /// The process-wide config, loaded once (and forced unprivileged by
    /// [`Config::init`]). A load failure is fatal: the helper cannot safely
    /// operate without a trusted data root, so it prints the error and exits
    /// rather than guessing a default.
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

    /// Read, ownership-check, parse, and validate the config file. See the module
    /// docs for the trust model.
    pub fn safe_load() -> Result<Self, LoadingError> {
        let path = config_path();

        let body = crate::security_gate::split(
            || -> Result<String, LoadingError> {
                let safe_path: SafePath<IsAbsolute, StrictComponents> =
                    path.clone().try_into()?;
                let file: SafeFile<IsRegularFile, RootOwner, OnlyRootWritable> =
                    SafeFile::open(&safe_path, OFlag::O_RDONLY)?;
                std::io::read_to_string(std::fs::File::from(file.into_owned_fd()))
                    .map_err(|_| LoadingError::Unreadable(path.clone()))
            },
            || -> Result<String, LoadingError> {
                std::fs::read_to_string(&path)
                    .map_err(|_| LoadingError::Unreadable(path.clone()))
            },
        )?;

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
