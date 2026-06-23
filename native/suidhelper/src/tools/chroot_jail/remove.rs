// SPDX-License-Identifier: AGPL-3.0-only
//! `chroot-jail remove`: delete a VM's stale chroot and cgroup leaf before
//! relaunching the jailer.
//!
//! Security: each path is validated as a `SafePath` and reached by an
//! `O_NOFOLLOW` walk from its base (`JAIL_BASE` / `/sys/fs/cgroup`), so a
//! symlinked component cannot redirect the deletion outside the tree, and removal
//! is fd-relative (`unlinkat`), never by re-resolved name. `--chroot` must be
//! exactly `<exec>/<id>` below `JAIL_BASE`; `--cgroup` at least two components
//! below its base (a non-recursive `rmdir`). Both deletes are idempotent: a
//! missing target (`ENOENT`, and for the cgroup `ENOTEMPTY`) is success.

use crate::config::Config;
use crate::tools::IsTool;
use crate::util::safe_dir::{self, SafeDir};
use crate::util::safe_path::{self, IsAbsolute, SafePath, StrictComponents};
use clap::Args;
use nix::errno::Errno;
use serde::Serialize;
use std::path::PathBuf;
use thiserror::Error as ThisError;

/// The cgroup virtual filesystem root.
const CGROUP_BASE: &str = "/sys/fs/cgroup";

type LexicalPath = SafePath<IsAbsolute, StrictComponents>;

#[derive(Debug, ThisError)]
pub enum Error {
    #[error("--chroot path: {0}")]
    ChrootPath(#[source] safe_path::ValidationError),
    #[error("--chroot must be exactly <exec>/<id> below JAIL_BASE: {0}")]
    ChrootDepth(String),
    #[error("--cgroup path: {0}")]
    CgroupPath(#[source] safe_path::ValidationError),
    #[error("--cgroup must be at least two components below /sys/fs/cgroup: {0}")]
    CgroupDepth(String),
    #[error("walking: {0}")]
    Walk(#[source] safe_dir::Error),
    #[error("removing chroot: {0}")]
    RemoveChroot(#[source] safe_dir::Error),
    #[error("removing cgroup: {0}")]
    RemoveCgroup(#[source] safe_dir::Error),
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

/// Run the `remove` op in its own privileged scope (returns its serialized `Value`).
pub fn run(args: RemoveArgs) -> Result<serde_json::Value, crate::tools::Error> {
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
        remove_chroot(&self.args.chroot)?;
        remove_cgroup(&self.args.cgroup)?;
        Ok(())
    }

    fn parse(&self, res: Self::RunT) -> Result<RemoveOut, Box<dyn std::error::Error>> {
        res?;
        Ok(RemoveOut::Removed)
    }
}

/// Recursively remove the per-VM chroot `<JAIL_BASE>/<exec>/<id>`, fd-relative
/// after an `O_NOFOLLOW` walk from `JAIL_BASE`. Idempotent on a missing target.
fn remove_chroot(chroot: &str) -> Result<(), Error> {
    let jail_base = Config::get().jail_base();
    let path: LexicalPath = PathBuf::from(chroot).try_into().map_err(Error::ChrootPath)?;
    let (parents, leaf) = path.relative_to(&jail_base).map_err(Error::ChrootPath)?;
    // Exactly <exec>/<id>: one parent component, one leaf.
    if parents.len() != 1 {
        return Err(Error::ChrootDepth(chroot.to_string()));
    }

    let Some(parent) = walk(jail_base, &parents)? else {
        return Ok(()); // an ancestor is already gone
    };
    match parent.remove_dir_all(&leaf) {
        Ok(()) => Ok(()),
        Err(e) if e.errno() == Some(Errno::ENOENT) => Ok(()),
        Err(e) => Err(Error::RemoveChroot(e)),
    }
}

/// Remove the (empty) per-VM cgroup leaf, fd-relative after an `O_NOFOLLOW` walk
/// from `/sys/fs/cgroup`. Idempotent on `ENOENT`/`ENOTEMPTY`.
fn remove_cgroup(cgroup: &str) -> Result<(), Error> {
    let base = PathBuf::from(CGROUP_BASE);
    let path: LexicalPath = PathBuf::from(cgroup).try_into().map_err(Error::CgroupPath)?;
    let (parents, leaf) = path.relative_to(&base).map_err(Error::CgroupPath)?;
    // At least two components below the base: one or more parents, plus the leaf.
    if parents.is_empty() {
        return Err(Error::CgroupDepth(cgroup.to_string()));
    }

    let Some(parent) = walk(base, &parents)? else {
        return Ok(()); // an ancestor is already gone
    };
    match parent.rmdir(&leaf) {
        Ok(()) => Ok(()),
        Err(e) if matches!(e.errno(), Some(Errno::ENOENT | Errno::ENOTEMPTY)) => Ok(()),
        Err(e) => Err(Error::RemoveCgroup(e)),
    }
}

/// Open `base` and walk `parents` from it (`O_NOFOLLOW` each step). Returns
/// `Ok(None)` if `base` or any parent is already gone (`ENOENT`), so callers can
/// treat removal as idempotent.
fn walk(base: PathBuf, parents: &[String]) -> Result<Option<SafeDir>, Error> {
    let base_path: LexicalPath = base.try_into().map_err(Error::CgroupPath)?;
    let anchor = match SafeDir::open(&base_path) {
        Ok(dir) => dir,
        Err(e) if e.errno() == Some(Errno::ENOENT) => return Ok(None),
        Err(e) => return Err(Error::Walk(e)),
    };
    match anchor.descend(parents) {
        Ok(dir) => Ok(Some(dir)),
        Err(e) if e.errno() == Some(Errno::ENOENT) => Ok(None),
        Err(e) => Err(Error::Walk(e)),
    }
}
