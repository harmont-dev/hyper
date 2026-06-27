// SPDX-License-Identifier: AGPL-3.0-only
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
use crate::tools::IsTool;
use crate::util::safe_dir::{self, SafeDir};
use crate::util::safe_path::{self, IsAbsolute, SafePath, StrictComponents};
use clap::Args;
use nix::errno::Errno;
use serde::Serialize;
use std::path::{Path, PathBuf};
use std::time::Duration;
use thiserror::Error as ThisError;

/// The cgroup virtual filesystem root.
const CGROUP_BASE: &str = "/sys/fs/cgroup";

/// How many times to retry the leaf `rmdir` while a killed cgroup drains, and the
/// pause between tries: ~`ATTEMPTS * BACKOFF` total (a cgroup reaps in a few ms),
/// after which a still-busy leaf is left for a later sweep rather than failing.
const RMDIR_ATTEMPTS: u32 = 20;
const RMDIR_BACKOFF_MS: u64 = 5;

type LexicalPath = SafePath<IsAbsolute, StrictComponents>;

#[derive(Debug, ThisError)]
pub enum Error {
    #[error("--chroot path: {0}")]
    ChrootPath(#[source] safe_path::ValidationError),
    #[error("--chroot must be exactly <exec>/<id> below JAIL_BASE: {0:?}")]
    ChrootDepth(PathBuf),
    #[error("--cgroup path: {0}")]
    CgroupPath(#[source] safe_path::ValidationError),
    #[error("--cgroup must be at least two components below /sys/fs/cgroup: {0:?}")]
    CgroupDepth(PathBuf),
    #[error("walking: {0}")]
    Walk(#[source] safe_dir::Error),
    #[error("removing chroot: {0}")]
    RemoveChroot(#[source] safe_dir::Error),
    #[error("removing cgroup: {0}")]
    RemoveCgroup(#[source] safe_dir::Error),
    #[error("killing cgroup procs: {0}")]
    KillCgroup(#[source] safe_dir::Error),
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
    let path: LexicalPath = chroot.to_path_buf().try_into().map_err(Error::ChrootPath)?;
    let (parents, leaf) = path.relative_to(jail_base).map_err(Error::ChrootPath)?;
    if parents.len() != 1 {
        return Err(Error::ChrootDepth(chroot.to_path_buf()));
    }

    let Some(parent) = walk(jail_base.to_path_buf(), &parents)? else {
        return Ok(()); // an ancestor is already gone
    };
    match parent.remove_dir_all(&leaf) {
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
    let path: LexicalPath = cgroup.to_path_buf().try_into().map_err(Error::CgroupPath)?;
    let (parents, leaf) = path.relative_to(base).map_err(Error::CgroupPath)?;
    if parents.is_empty() {
        return Err(Error::CgroupDepth(cgroup.to_path_buf()));
    }

    let Some(parent) = walk(base.to_path_buf(), &parents)? else {
        return Ok(()); // an ancestor is already gone
    };

    // Kill any process still in the leaf cgroup before removing it. Open the leaf
    // O_NOFOLLOW (one step past the parent walk) and write "1" to cgroup.kill.
    match parent.openat_dir(&leaf) {
        Ok(leaf_dir) => kill_cgroup(&leaf_dir)?,
        Err(e) if e.errno() == Some(Errno::ENOENT) => return Ok(()), // leaf already gone
        Err(e) => return Err(Error::Walk(e)),
    }

    rmdir_drained(&parent, &leaf)
}

/// `rmdir` the killed cgroup leaf, retrying while it drains. `cgroup.kill` signals
/// SIGKILL synchronously but the kernel reaps the processes and offlines the
/// cgroup asynchronously, so the `rmdir` briefly returns `EBUSY`/`ENOTEMPTY`.
/// Retry a bounded number of times; if it still has not drained, the processes are
/// already dead (the kill is the load-bearing op) and a later sweep or the next
/// relaunch clears the empty leaf, so a persistent busy is success — never fail
/// the caller (a relaunch) over leftover-dir cleanup. `ENOENT` means already gone.
fn rmdir_drained(parent: &SafeDir, leaf: &Path) -> Result<(), Error> {
    for attempt in 0..RMDIR_ATTEMPTS {
        match parent.rmdir(leaf) {
            Ok(()) => return Ok(()),
            Err(e) if e.errno() == Some(Errno::ENOENT) => return Ok(()),
            Err(e) if matches!(e.errno(), Some(Errno::EBUSY | Errno::ENOTEMPTY)) => {
                if attempt + 1 < RMDIR_ATTEMPTS {
                    std::thread::sleep(Duration::from_millis(RMDIR_BACKOFF_MS));
                }
            }
            Err(e) => return Err(Error::RemoveCgroup(e)),
        }
    }
    Ok(())
}

/// Best-effort SIGKILL of every process in the v2 cgroup `leaf_dir`: write "1" to
/// its `cgroup.kill` pseudo-file. A missing file (`ENOENT`: pre-5.14/non-v2
/// kernel, or already-emptied leaf) or a cgroup torn down concurrently (`ENODEV`)
/// is tolerated — killing must not hard-fail the remove.
fn kill_cgroup(leaf_dir: &SafeDir) -> Result<(), Error> {
    match leaf_dir.write_file(Path::new("cgroup.kill"), b"1") {
        Ok(()) => Ok(()),
        Err(e) if matches!(e.errno(), Some(Errno::ENOENT | Errno::ENODEV)) => Ok(()),
        Err(e) => Err(Error::KillCgroup(e)),
    }
}

/// Open `base` and walk `parents` from it (`O_NOFOLLOW` each step). Returns
/// `Ok(None)` if `base` or any parent is already gone (`ENOENT`), so callers can
/// treat removal as idempotent.
fn walk(base: PathBuf, parents: &[PathBuf]) -> Result<Option<SafeDir>, Error> {
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
