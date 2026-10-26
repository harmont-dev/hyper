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
use nix::sys::stat::Mode;
use serde::Serialize;
use std::path::{Path, PathBuf};
use std::time::Duration;
use thiserror::Error as ThisError;

/// The cgroup virtual filesystem root.
const CGROUP_BASE: &str = "/sys/fs/cgroup";

const KILL_TIMEOUT: Duration = Duration::from_secs(5);

type LexicalPath = SafePath<IsAbsolute, StrictComponents>;

#[derive(Debug, ThisError)]
pub enum Error {
    #[error("--chroot path: {0}")]
    ChrootPath(#[source] path::ValidationError),
    #[error("--chroot path: {0}")]
    ChrootBase(#[source] path::RelativeError),
    #[error("--chroot must be exactly <exec>/<id> below JAIL_BASE: {0:?}")]
    ChrootDepth(PathBuf),
    #[error("--cgroup path: {0}")]
    CgroupPath(#[source] path::ValidationError),
    #[error("--cgroup path: {0}")]
    CgroupBase(#[source] path::RelativeError),
    #[error("--cgroup must be at least two components below /sys/fs/cgroup: {0:?}")]
    CgroupDepth(PathBuf),
    #[error("walking: {0}")]
    Walk(#[source] file::ValidationError),
    #[error("removing chroot: {0}")]
    RemoveChroot(#[source] dir::Error),
    #[error("removing cgroup: {0}")]
    RemoveCgroup(#[source] Errno),
    #[error("opening cgroup: {0}")]
    OpenCgroup(#[source] cgroup::OpenError),
    #[error("killing cgroup procs: {0}")]
    KillCgroup(#[source] cgroup::KillError),
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
        remove_cgroup_under(Path::new(CGROUP_BASE), &self.args.cgroup)?;
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
pub fn remove_chroot_under(jail_base: &Path, chroot: &Path) -> Result<(), Error> {
    let path: &LexicalPath = chroot.try_into().map_err(Error::ChrootPath)?;
    let rel = path.strip_base(jail_base).map_err(Error::ChrootBase)?;
    let [exec, id] = rel.segments().collect::<Vec<_>>()[..] else {
        return Err(Error::ChrootDepth(chroot.to_path_buf()));
    };

    let Some(parent) = walk(jail_base, Path::new(exec))? else {
        return Ok(()); // an ancestor is already gone
    };
    match parent.rmdirat_recursive(Path::new(id)) {
        Ok(()) => Ok(()),
        Err(e) if e.errno() == Some(Errno::ENOENT) => Ok(()),
        Err(e) => Err(Error::RemoveChroot(e)),
    }
}

/// SIGKILL any process still in the per-VM cgroup leaf (via `cgroup.kill`), then
/// `rmdir` it, fd-relative after an `O_NOFOLLOW` walk from `base`. `--cgroup` must
/// be at least two components below `base` (one or more parents, plus the leaf).
/// Idempotent: a missing leaf is success, and a leaf that has not finished
/// draining after the kill (`EBUSY`/`ENOTEMPTY`) is left for a later sweep.
pub fn remove_cgroup_under(base: &Path, cgroup: &Path) -> Result<(), Error> {
    let path: &LexicalPath = cgroup.try_into().map_err(Error::CgroupPath)?;
    let rel = path.strip_base(base).map_err(Error::CgroupBase)?;
    if rel.segments().count() < 2 {
        return Err(Error::CgroupDepth(cgroup.to_path_buf()));
    }

    // Kill any process still in the leaf cgroup before removing it. Open the leaf
    // O_NOFOLLOW (one step past the parent walk) and write "1" to cgroup.kill.
    let cgroup = match Cgroup::open(path) {
        Ok(cgroup) => cgroup,
        Err(cgroup::OpenError::Open(file::ValidationError::Open(Errno::ENOENT))) => return Ok(()),
        Err(e) => return Err(Error::OpenCgroup(e)),
    };
    cgroup.kill_procs(KILL_TIMEOUT).map_err(Error::KillCgroup)?;
    cgroup.remove().map_err(Error::RemoveCgroup)
}

/// Open `base` and walk `parents` from it (`O_NOFOLLOW` each step). Returns
/// `Ok(None)` if `base` or any parent is already gone (`ENOENT`), so callers can
/// treat removal as idempotent.
fn walk(base: &Path, rel: &Path) -> Result<Option<SafeDir>, Error> {
    let base_path: &LexicalPath = base.try_into().map_err(Error::CgroupPath)?;
    let anchor = match SafeDir::open(base_path, OpenFlags::RDONLY) {
        Ok(dir) => dir,
        Err(file::ValidationError::Open(Errno::ENOENT)) => return Ok(None),
        Err(e) => return Err(Error::Walk(e)),
    };
    match anchor.openat(rel, OpenFlags::RDONLY, Mode::empty()) {
        Ok(dir) => Ok(Some(dir)),
        Err(file::ValidationError::Open(Errno::ENOENT)) => Ok(None),
        Err(e) => Err(Error::Walk(e)),
    }
}
