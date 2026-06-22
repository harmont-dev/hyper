// SPDX-License-Identifier: AGPL-3.0-only
//! `chroot-jail remove`: delete a VM's stale chroot and cgroup leaf before
//! relaunching the jailer.
//!
//! Security: `--chroot` must be EXACTLY two components below `JAIL_BASE`
//! (`<exec>/<id>`) so a caller cannot pass a shallower/deeper path and nuke an
//! unrelated tree; `remove_dir_all` does not follow symlinks for deletion (and
//! the path components are root-owned). `--cgroup` must be at least two
//! components below `/sys/fs/cgroup`, removed with a non-recursive rmdir (empty
//! leaf only). Both deletes are idempotent: `ENOENT` (and, for the cgroup,
//! `ENOTEMPTY`) are treated as success.

use crate::safe_dev::{self, JailPath};
use crate::tools::IsTool;
use clap::Args;
use serde::Serialize;
use std::io;
use std::path::{Component, Path, PathBuf};
use thiserror::Error as ThisError;

/// The cgroup virtual filesystem root.
const CGROUP_BASE: &str = "/sys/fs/cgroup";

#[derive(Debug, ThisError)]
pub enum Error {
    #[error("--chroot path is not a valid jail path: {0}")]
    ChrootPath(#[source] safe_dev::Error),
    #[error("--chroot must be exactly <exec>/<id> below JAIL_BASE: {0}")]
    ChrootDepth(String),
    #[error("--cgroup path must be absolute under /sys/fs/cgroup with no . or ..: {0}")]
    CgroupPath(String),
    #[error("--cgroup must be at least two components below /sys/fs/cgroup: {0}")]
    CgroupDepth(String),
    #[error("remove_dir_all {path}: {source}")]
    RemoveChroot {
        path: PathBuf,
        #[source]
        source: io::Error,
    },
    #[error("rmdir {path}: {source}")]
    RemoveCgroup {
        path: PathBuf,
        #[source]
        source: io::Error,
    },
}

#[derive(Args)]
pub struct RemoveArgs {
    /// Per-VM chroot directory to remove, shape <JAIL_BASE>/<exec>/<id>.
    #[arg(long)]
    chroot: String,
    /// Per-VM cgroup leaf directory to remove, under /sys/fs/cgroup.
    #[arg(long)]
    cgroup: String,
}

#[derive(Serialize)]
#[serde(tag = "result", rename_all = "snake_case")]
pub enum RemoveOut {
    Removed,
}

/// Run the `remove` op in its own privileged scope.
pub fn run(args: RemoveArgs) -> Result<RemoveOut, crate::tools::Error> {
    Remove { args }.run()
}

struct Remove {
    args: RemoveArgs,
}

impl IsTool for Remove {
    type Args = RemoveArgs;
    type Output = RemoveOut;
    type RunT = Result<(), Error>;

    fn run_privileged(&self) -> Self::RunT {
        let chroot = validate_chroot(&self.args.chroot)?;
        let cgroup = validate_cgroup(&self.args.cgroup)?;

        let chroot_path: &Path = chroot.as_ref();
        match std::fs::remove_dir_all(chroot_path) {
            Ok(()) => {}
            // Idempotent: a first boot has no chroot yet.
            Err(e) if e.kind() == io::ErrorKind::NotFound => {}
            Err(source) => {
                return Err(Error::RemoveChroot {
                    path: chroot_path.to_path_buf(),
                    source,
                })
            }
        }

        match std::fs::remove_dir(&cgroup) {
            Ok(()) => {}
            // Best-effort: the leaf may not exist, or the process may still hold it.
            Err(e)
                if e.kind() == io::ErrorKind::NotFound
                    || e.raw_os_error() == Some(nix::libc::ENOTEMPTY) => {}
            Err(source) => return Err(Error::RemoveCgroup { path: cgroup, source }),
        }

        Ok(())
    }

    fn parse(&self, res: Self::RunT) -> Result<RemoveOut, Box<dyn std::error::Error>> {
        res?;
        Ok(RemoveOut::Removed)
    }
}

/// Validate `s` is a per-VM chroot dir: a [`JailPath`] (absolute, under
/// `JAIL_BASE`, no `.`/`..`) that is EXACTLY two components below `JAIL_BASE`
/// (`<exec>/<id>`).
fn validate_chroot(s: &str) -> Result<JailPath, Error> {
    let jail: JailPath = s.parse().map_err(Error::ChrootPath)?;
    let (parents, _final) = safe_dev::jail_relative_parts(&jail).map_err(Error::ChrootPath)?;
    if parents.len() != 1 {
        return Err(Error::ChrootDepth(s.to_string()));
    }
    Ok(jail)
}

/// Validate `s` is a per-VM cgroup leaf: absolute, under `CGROUP_BASE`, no
/// `.`/`..`, and at least two components below `CGROUP_BASE`.
fn validate_cgroup(s: &str) -> Result<PathBuf, Error> {
    let p = PathBuf::from(s);
    let ok = p.is_absolute()
        && p.starts_with(CGROUP_BASE)
        && p.components()
            .all(|c| matches!(c, Component::RootDir | Component::Normal(_)));
    if !ok {
        return Err(Error::CgroupPath(s.to_string()));
    }
    let rel = p
        .strip_prefix(CGROUP_BASE)
        .map_err(|_| Error::CgroupPath(s.to_string()))?;
    let depth = rel
        .components()
        .filter(|c| matches!(c, Component::Normal(_)))
        .count();
    if depth < 2 {
        return Err(Error::CgroupDepth(s.to_string()));
    }
    Ok(p)
}
