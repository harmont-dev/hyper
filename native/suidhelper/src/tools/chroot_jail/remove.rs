// SPDX-License-Identifier: MIT
//! `chroot-jail remove`: delete a VM's stale chroot and cgroup leaf before
//! relaunching the jailer.
//!
//! Security: each path is validated as a `SafePath` and reached by an
//! `O_NOFOLLOW` walk from its base (`JAIL_BASE` / `/sys/fs/cgroup`), so a
//! symlinked component cannot redirect the deletion outside the tree, and removal
//! is fd-relative (`unlinkat`), never by re-resolved name. `--chroot` must be
//! exactly `<exec>/<id>` below `JAIL_BASE`; `--cgroup` at least two components
//! below its base. Before removing the cgroup leaf we write `cgroup.kill` to
//! SIGKILL any process still in the subtree (a still-live firecracker would
//! otherwise keep the leaf non-empty and leak its loop/dm devices), then
//! `rmdir` it (non-recursive). Both deletes are idempotent: a missing target
//! (`ENOENT`, and for the cgroup `ENOTEMPTY`) is success.

use crate::config::Config;
use crate::fs::dir::{self, SafeDir};
use crate::fs::file::{self, OpenFlags};
use crate::fs::path::{self, IsAbsolute, SafePath, StrictComponents};
use crate::linux::cgroup::{self, Cgroup};
use crate::tools::IsTool;
use clap::Args;
use nix::errno::Errno;
use serde::Serialize;
use std::path::{Path, PathBuf};
use std::time::Duration;
use thiserror::Error as ThisError;

const KILL_TIMEOUT: Duration = Duration::from_secs(5);

type LexicalPath = SafePath<IsAbsolute, StrictComponents>;

#[derive(Debug, ThisError)]
pub enum Error {
    #[error(transparent)]
    Chroot(#[from] ChrootError),
    #[error(transparent)]
    Cgroup(#[from] CgroupError),
}

#[derive(Debug, ThisError)]
pub enum ChrootError {
    #[error("--chroot path: {0}")]
    Path(#[source] path::ValidationError),
    #[error("--chroot path: {0}")]
    Base(#[source] path::RelativeError),
    #[error("--chroot must be exactly <exec>/<id> below JAIL_BASE: {0:?}")]
    Depth(PathBuf),
    #[error("opening chroot parent: {0}")]
    Open(#[source] file::ValidationError),
    #[error("removing chroot: {0}")]
    Remove(#[source] dir::Error),
}

#[derive(Debug, ThisError)]
pub enum CgroupError {
    #[error("--cgroup path: {0}")]
    Path(#[source] path::ValidationError),
    #[error("--cgroup path: {0}")]
    Base(#[source] path::RelativeError),
    #[error("--cgroup must be at least two components below /sys/fs/cgroup: {0:?}")]
    Depth(PathBuf),
    #[error("opening cgroup: {0}")]
    Open(#[source] cgroup::OpenError),
    #[error("killing cgroup procs: {0}")]
    Kill(#[source] cgroup::KillError),
    #[error("removing cgroup: {0}")]
    Remove(#[source] Errno),
}

#[derive(Args)]
pub struct RemoveArgs {
    /// Per-VM chroot directory to remove, shape <JAIL_BASE>/<exec>/<id>.
    #[arg(long)]
    chroot: PathBuf,
    /// Per-VM cgroup leaf directory to remove, under /sys/fs/cgroup.
    #[arg(long)]
    cgroup: PathBuf,
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
        // Cgroup first: it SIGKILLs any firecracker still alive in the leaf, so the
        // chroot teardown below is not yanking files out from under a live process.
        remove_cgroup_under(Path::new(cgroup::ROOT), &self.args.cgroup)?;
        remove_chroot_under(&Config::get().jail_base(), &self.args.chroot)?;
        Ok(())
    }

    fn parse(&self, res: Self::RunT) -> Result<RemoveOut, Box<dyn std::error::Error>> {
        res?;
        Ok(RemoveOut::Removed)
    }
}

/// Recursively remove the per-VM chroot `<jail_base>/<exec>/<id>`, fd-relative
/// after an `O_NOFOLLOW` walk from `jail_base`. Idempotent on a missing target.
/// `--chroot` must be exactly `<exec>/<id>` (one parent component, one leaf).
pub fn remove_chroot_under(jail_base: &Path, chroot: &Path) -> Result<(), ChrootError> {
    let path: &LexicalPath = chroot.try_into().map_err(ChrootError::Path)?;
    let rel = path.strip_base(jail_base).map_err(ChrootError::Base)?;
    let (2, Some((parent, id))) = (rel.segments().count(), path.split_last()) else {
        return Err(ChrootError::Depth(chroot.to_path_buf()));
    };

    let parent = match SafeDir::open(parent, OpenFlags::RDONLY) {
        Ok(parent) => parent,
        Err(file::ValidationError::Open(Errno::ENOENT)) => return Ok(()),
        Err(e) => return Err(ChrootError::Open(e)),
    };
    match parent.rmdirat_recursive(id) {
        Ok(()) => Ok(()),
        Err(e) if e.errno() == Some(Errno::ENOENT) => Ok(()),
        Err(e) => Err(ChrootError::Remove(e)),
    }
}

/// SIGKILL any process still in the per-VM cgroup leaf (via `cgroup.kill`), then
/// `rmdir` it, fd-relative after an `O_NOFOLLOW` walk from `base`. `--cgroup` must
/// be at least two components below `base` (one or more parents, plus the leaf).
/// Idempotent: a missing leaf is success, and a leaf that has not finished
/// draining after the kill (`EBUSY`/`ENOTEMPTY`) is left for a later sweep.
pub fn remove_cgroup_under(base: &Path, cgroup: &Path) -> Result<(), CgroupError> {
    let path: &LexicalPath = cgroup.try_into().map_err(CgroupError::Path)?;
    let rel = path.strip_base(base).map_err(CgroupError::Base)?;
    if rel.segments().count() < 2 {
        return Err(CgroupError::Depth(cgroup.to_path_buf()));
    }

    // Kill any process still in the leaf cgroup before removing it. Open the leaf
    // O_NOFOLLOW (one step past the parent walk) and write "1" to cgroup.kill.
    let cgroup = match Cgroup::open(path) {
        Ok(cgroup) => cgroup,
        Err(cgroup::OpenError::Open(file::ValidationError::Open(Errno::ENOENT))) => return Ok(()),
        Err(e) => return Err(CgroupError::Open(e)),
    };
    cgroup.kill_procs(KILL_TIMEOUT).map_err(CgroupError::Kill)?;
    cgroup.remove().map_err(CgroupError::Remove)
}
