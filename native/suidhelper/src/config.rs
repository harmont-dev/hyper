// SPDX-License-Identifier: AGPL-3.0-only
//! Runtime host configuration, read from a single root-owned TOML file.
//!
//! `HYPER_BASE`/`JAIL_BASE` used to be compile-time constants kept in lockstep
//! with the Elixir node's `config :hyper, work_dir`. Both sides now read the same
//! file (`/etc/hyper/config.toml`), so the data root has one source of truth.
//!
//! Security: this is a confinement boundary in a setuid-root binary - the value
//! decides which files the helper will chown/mknod/stage. So the file must be
//! trustworthy: it is opened with `O_NOFOLLOW` (its final component cannot be a
//! symlink) and rejected unless it is owned by `root:root` and not writable by
//! group or other - i.e. only root could have written it, exactly like the old
//! compile-time constant. The path is fixed (never taken from argv or the
//! environment, both caller-controlled), and must be world-readable (`0644
//! root:root`) so the unprivileged helper can read it. On any failure the helper
//! exits rather than guessing a default.

use serde::Deserialize;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::LazyLock;
use thiserror::Error;

#[derive(Debug, Copy, Clone, Error)]
pub enum LoadingError {
    #[error("{0:?} does not exist or is unreadable")]
    MissingFile(&'static Path),
    #[error("{0:?} is owned by someone other than root:root")]
    BadOwner(&'static Path),
    #[error("{0:?} is writable by non-owners")]
    BadMode(&'static Path),
    #[error("{0:?} is not valid TOML")]
    Malformed(&'static Path),
    #[error("work_dir in {0:?} must be an absolute path")]
    Relative(&'static Path),
}

const CONFIG_PATHSTR: &str = "/etc/hyper/config.toml";
static CONFIG_PATH: LazyLock<PathBuf> = LazyLock::new(|| PathBuf::from(CONFIG_PATHSTR));

/// Hyper's /etc/hyper/config.toml file format.
#[derive(Debug, Clone, Deserialize)]
struct Config {
    pub work_dir: PathBuf,
}

impl Config {
    /// Read, ownership-check, parse, and validate the config file. See the module
    /// docs for the trust model.
    pub fn safe_load() -> Result<Self, LoadingError> {
        let path = CONFIG_PATH.as_path();

        // O_NOFOLLOW: refuse a symlink swapped in for the file itself.
        let file = std::fs::OpenOptions::new()
            .read(true)
            .custom_flags(nix::libc::O_NOFOLLOW)
            .open(path)
            .map_err(|_| LoadingError::MissingFile(path))?;

        let meta = file.metadata().map_err(|_| LoadingError::MissingFile(path))?;
        // Only root may have authored the confinement root.
        if !meta.is_file() || meta.uid() != 0 || meta.gid() != 0 {
            return Err(LoadingError::BadOwner(path));
        }
        if meta.mode() & 0o022 != 0 {
            return Err(LoadingError::BadMode(path));
        }

        let body = std::io::read_to_string(file).map_err(|_| LoadingError::MissingFile(path))?;
        let config: Config = toml::from_str(&body).map_err(|_| LoadingError::Malformed(path))?;

        if !config.work_dir.is_absolute() {
            return Err(LoadingError::Relative(path));
        }
        Ok(config)
    }
}

/// The process-wide config, loaded once. A load failure is fatal: the helper
/// cannot safely operate without a trusted data root, so it prints the error and
/// exits rather than guessing a default.
static CONFIG: LazyLock<Config> = LazyLock::new(|| {
    Config::safe_load().unwrap_or_else(|e| {
        eprintln!("hyper-suidhelper: {e}");
        std::process::exit(2);
    })
});

/// `<work_dir>/jails`, computed once from the loaded config.
static JAIL_BASE: LazyLock<String> =
    LazyLock::new(|| format!("{}/jails", hyper_base().trim_end_matches('/')));

/// Hyper's data root (formerly the `HYPER_BASE` constant).
pub fn hyper_base() -> &'static str {
    CONFIG
        .work_dir
        .to_str()
        .expect("work_dir must be valid UTF-8")
}

/// Hyper's jail root, `<work_dir>/jails` (formerly the `JAIL_BASE` constant).
pub fn jail_base() -> &'static str {
    JAIL_BASE.as_str()
}
