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
use hyperrs_firecracker::jailer::chroot::JailLayout;
use hyperrs_firecracker::VmId;
use hyperrs_fs::dir::{self, SafeDir};
use hyperrs_fs::file::{self, OpenFlags};
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
    Chroot(#[from] ChrootError),
    #[error(transparent)]
    Cgroup(#[from] CgroupError),
}

#[derive(Debug, ThisError)]
pub enum ChrootError {
    #[error("opening chroot parent: {0}")]
    Open(#[source] file::ValidationError),
    #[error("removing chroot: {0}")]
    Remove(#[source] dir::DirError),
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
        remove_chroot(&JailLayout::new(&jail_base, &self.args.id))?;
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
pub fn remove_chroot(layout: &JailLayout<'_>) -> Result<(), ChrootError> {
    let parent = match SafeDir::open(&layout.exec_dir(), OpenFlags::RDONLY) {
        Ok(parent) => parent,
        Err(file::ValidationError::Open(Errno::ENOENT)) => return Ok(()),
        Err(e) => return Err(ChrootError::Open(e)),
    };
    match parent.rmdirat_recursive(layout.id()) {
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
    use super::{remove_cgroup, remove_chroot};
    use hyperrs_firecracker::jailer::chroot::JailLayout;
    use hyperrs_firecracker::VmId;
    use hyperrs_fs::path::{IsAbsolute, SafePathBuf, StrictComponents};
    use std::fs;
    use std::os::unix::fs::symlink;
    use std::path::Path;

    fn strict(p: &Path) -> SafePathBuf<IsAbsolute, StrictComponents> {
        p.to_path_buf().try_into().unwrap()
    }

    fn vm() -> VmId {
        "id".parse().unwrap()
    }

    #[test]
    fn missing_targets_are_ok() {
        let tmp = tempfile::tempdir().unwrap();
        let jail = strict(tmp.path());
        let id = vm();
        remove_chroot(&JailLayout::new(&jail, &id)).expect("missing chroot must be Ok");

        let parent = tmp.path().join("hyper");
        remove_cgroup(&strict(&parent), &id).expect("missing parent must be Ok");
        fs::create_dir(&parent).unwrap();
        remove_cgroup(&strict(&parent), &id).expect("missing leaf must be Ok");
        assert!(parent.exists(), "cgroup parent must survive");
    }

    #[test]
    fn removes_chroot_tree_and_spares_siblings() {
        let tmp = tempfile::tempdir().unwrap();
        let exec = tmp.path().join("firecracker");
        let victim = exec.join("id");
        fs::create_dir_all(victim.join("root")).unwrap();
        fs::write(victim.join("root").join("vmlinux"), b"kernel").unwrap();
        let sibling = exec.join("other");
        fs::create_dir_all(&sibling).unwrap();

        let jail = strict(tmp.path());
        let id = vm();
        remove_chroot(&JailLayout::new(&jail, &id)).unwrap();
        assert!(!victim.exists(), "victim chroot must be gone");
        assert!(sibling.exists(), "sibling chroot must survive");
    }

    #[test]
    fn symlinked_exec_component_does_not_escape() {
        let tmp = tempfile::tempdir().unwrap();
        let jail = tmp.path().join("jail");
        fs::create_dir(&jail).unwrap();
        let sentinel = tmp.path().join("sentinel");
        fs::create_dir_all(sentinel.join("id")).unwrap();
        fs::write(sentinel.join("id").join("keep.txt"), b"do not delete").unwrap();
        symlink(&sentinel, jail.join("firecracker")).unwrap();

        let jail = strict(&jail);
        let id = vm();
        let _ = remove_chroot(&JailLayout::new(&jail, &id));
        assert!(sentinel.join("id").join("keep.txt").exists());
    }
}
