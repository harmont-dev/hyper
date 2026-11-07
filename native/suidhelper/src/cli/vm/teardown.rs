// SPDX-License-Identifier: MIT
//! `vm teardown`: delete a VM's stale chroot and cgroup leaf before
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

use super::VmOut;
use crate::cli::{DispatchError, Op};
use crate::config::Config;
use crate::network;
use hyperrs_firecracker::jailer::chroot::{JailLayout, RemoveError};
use hyperrs_firecracker::VmId;
use hyperrs_fs::file;
use hyperrs_fs::path::{IsAbsolute, SafePath, StrictComponents};
use hyperrs_linux::cgroup::{self, Cgroup};
use hyperrs_process::privilege::{PrivilegeError, Unprivileged};
use nix::errno::Errno;
use serde::Deserialize;
use serde_with::{serde_as, DisplayFromStr};
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
    #[error(transparent)]
    Privilege(#[from] PrivilegeError),
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

#[serde_as]
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Teardown {
    #[serde_as(as = "DisplayFromStr")]
    id: VmId,
    uid: Option<u32>,
}

impl Op for Teardown {
    type Output = VmOut;
    type Error = DispatchError;

    fn run(self, mut token: Unprivileged) -> Result<VmOut, DispatchError> {
        let Teardown { id, uid } = self;
        teardown(&id, uid, &mut token)?;
        Ok(VmOut::ToreDown)
    }
}

pub fn teardown(
    id: &VmId,
    uid: Option<u32>,
    token: &mut Unprivileged,
) -> Result<(), DispatchError> {
    let jail = remove_jail(id, token).map_err(DispatchError::tool);
    let net = if network::enabled() {
        network::teardown(id, uid, token).map_err(DispatchError::tool)
    } else {
        Ok(())
    };
    jail.and(net)
}

fn remove_jail(id: &VmId, token: &mut Unprivileged) -> Result<(), JailRemoveError> {
    let config = Config::get();
    let cgroup_parent = config.parent_cgroup_dir();
    let jail_base = config.jail_base();
    let layout = JailLayout::new(&jail_base, id);
    let _root = token.elevate()?;
    // Cgroup first: it SIGKILLs any firecracker still alive in the leaf, so the
    // chroot teardown below is not yanking files out from under a live process.
    remove_cgroup(&cgroup_parent, id)?;
    Ok(layout.remove()?)
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
