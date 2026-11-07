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
use crate::tools::IsTool;
use clap::Args;
use hyperrs_firecracker::jailer::chroot::{JailLayout, RemoveError};
use hyperrs_firecracker::VmId;
use hyperrs_fs::file;
use hyperrs_fs::path::{IsAbsolute, SafePath, StrictComponents};
use hyperrs_linux::cgroup::{self, Cgroup};
use hyperrs_process::privilege::{Root, Unprivileged};
use nix::errno::Errno;
use serde::Serialize;
use std::time::Duration;
use thiserror::Error as ThisError;

const KILL_TIMEOUT: Duration = Duration::from_secs(5);

type LexicalPath = SafePath<IsAbsolute, StrictComponents>;

#[derive(Debug, ThisError)]
pub enum JailRemoveError {
    #[error(transparent)]
    Chroot(#[from] RemoveError),
    #[error(transparent)]
    Cgroup(#[from] CgroupError),
}

#[derive(Debug, ThisError)]
pub enum CgroupError {
    #[error("opening cgroup: {0}")]
    Open(#[source] cgroup::OpenError),
    #[error("killing cgroup procs: {0}")]
    Kill(#[source] cgroup::KillError),
    #[error("removing cgroup: {0}")]
    Remove(#[source] Errno),
}

#[derive(Args)]
pub struct RemoveArgs {
    #[arg(long)]
    id: VmId,
}

#[derive(Serialize)]
#[serde(tag = "result", rename_all = "snake_case")]
pub enum RemoveOut {
    Removed,
}

/// Run the `remove` op in its own privileged scope (returns its serialized `Value`).
pub fn run(
    args: RemoveArgs,
    token: &mut Unprivileged,
) -> Result<serde_json::Value, crate::tools::DispatchError> {
    Remove { args }.run(token)
}

struct Remove {
    args: RemoveArgs,
}

impl IsTool for Remove {
    type Args = RemoveArgs;
    type Output = RemoveOut;
    type RunT = Result<(), JailRemoveError>;

    fn run_privileged(&self, _root: &Root<'_>) -> Self::RunT {
        // Cgroup first: it SIGKILLs any firecracker still alive in the leaf, so the
        // chroot teardown below is not yanking files out from under a live process.
        let config = Config::get();
        remove_cgroup(&config.parent_cgroup_dir(), &self.args.id)?;
        let jail_base = config.jail_base();
        JailLayout::new(&jail_base, &self.args.id).remove()?;
        Ok(())
    }

    fn parse(&self, res: Self::RunT) -> Result<RemoveOut, Box<dyn std::error::Error>> {
        res?;
        Ok(RemoveOut::Removed)
    }
}

/// SIGKILL any process still in the per-VM cgroup leaf (via `cgroup.kill`), then
/// `rmdir` it, fd-relative after an `O_NOFOLLOW` walk from `base`. `--cgroup` must
/// be at least two components below `base` (one or more parents, plus the leaf).
/// Idempotent: a missing leaf is success, and a leaf that has not finished
/// draining after the kill (`EBUSY`/`ENOTEMPTY`) is left for a later sweep.
pub fn remove_cgroup(parent: &LexicalPath, id: &VmId) -> Result<(), CgroupError> {
    let cgroup = match Cgroup::open(&parent.join(id)) {
        Ok(cgroup) => cgroup,
        Err(cgroup::OpenError::Open(file::ValidationError::Open(Errno::ENOENT))) => return Ok(()),
        Err(e) => return Err(CgroupError::Open(e)),
    };
    cgroup.kill_procs(KILL_TIMEOUT).map_err(CgroupError::Kill)?;
    cgroup.remove().map_err(CgroupError::Remove)
}

#[cfg(test)]
mod tests {
    use super::remove_cgroup;
    use assert_fs::prelude::*;
    use assert_fs::TempDir;
    use hyperrs_firecracker::VmId;
    use hyperrs_fs::path::{IsAbsolute, SafePathBuf, StrictComponents};
    use rstest::rstest;
    use std::path::Path;

    fn strict(p: &Path) -> SafePathBuf<IsAbsolute, StrictComponents> {
        p.to_path_buf().try_into().unwrap()
    }

    #[rstest]
    fn missing_cgroup_targets_are_ok() {
        let tmp = TempDir::new().unwrap();
        let id: VmId = "id".parse().unwrap();
        let parent = tmp.child("hyper");
        remove_cgroup(&strict(&parent), &id).expect("missing parent must be Ok");
        parent.create_dir_all().unwrap();
        remove_cgroup(&strict(&parent), &id).expect("missing leaf must be Ok");
        assert!(parent.exists(), "cgroup parent must survive");
    }
}
