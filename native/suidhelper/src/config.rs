// SPDX-License-Identifier: AGPL-3.0-only
//! Runtime host configuration, read from a single root-owned TOML file.

use crate::util::safe_file::{self, IsRegularFile, OnlyRootWritable, RootOwner, SafeFile};
use crate::util::safe_path::{self, IsAbsolute, SafePath, StrictComponents};
use nix::fcntl::OFlag;
use serde::Deserialize;
use std::path::{Path, PathBuf};
use std::sync::LazyLock;
use thiserror::Error;

#[derive(Debug, Copy, Clone, Error)]
pub enum LoadingError {
    #[error(transparent)]
    Path(#[from] safe_path::ValidationError),
    #[error(transparent)]
    File(#[from] safe_file::ValidationError),
    #[error("{0:?} could not be read")]
    Unreadable(&'static Path),
    #[error("{0:?} is not valid TOML")]
    Malformed(&'static Path),
    #[error("work_dir in {0:?} must be an absolute path")]
    Relative(&'static Path),
}

const CONFIG_PATHSTR: &str = "/etc/hyper/config.toml";
static CONFIG_PATH: LazyLock<PathBuf> = LazyLock::new(|| PathBuf::from(CONFIG_PATHSTR));

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
    pub fn hyper_base(&self) -> &Path {
        self.work_dir.as_path()
    }

    /// Hyper's jail root, `<work_dir>/jails`.
    pub fn jail_base(&self) -> PathBuf {
        self.work_dir.join("jails")
    }

    /// Read, ownership-check, parse, and validate the config file. See the module
    /// docs for the trust model.
    pub fn safe_load() -> Result<Self, LoadingError> {
        let path = CONFIG_PATH.as_path();

        let safe_path: SafePath<IsAbsolute, StrictComponents> =
            PathBuf::from(CONFIG_PATHSTR).try_into()?;

        let file: SafeFile<IsRegularFile, RootOwner, OnlyRootWritable> =
            SafeFile::open(&safe_path, OFlag::O_RDONLY)?;

        let body = std::io::read_to_string(std::fs::File::from(file.into_owned_fd()))
            .map_err(|_| LoadingError::Unreadable(path))?;
        let config: Config = toml::from_str(&body).map_err(|_| LoadingError::Malformed(path))?;

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
