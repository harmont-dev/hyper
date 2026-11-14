// SPDX-License-Identifier: MIT
//! `vm teardown`: kill a VM's cgroup and delete its chroot, network and socket pins, before a
//! relaunch or when the VM stops. Waits for the VM's lock, so it never overlaps a `vm_launch` of
//! the same VM still staging, and removes the lock file afterwards.

use super::claim::{PinError, SocketPin};
use super::{VmOut, API_SOCKET, VSOCK_SOCKET};
use crate::cli::Op;
use crate::config::Config;
use crate::lock::{Locks, LocksError};
use crate::net::vm::{VmNet, VmNetError};
use derive_more::Constructor;
use hyperrs_firecracker::jailer::chroot::{JailLayout, RemoveError};
use hyperrs_firecracker::VmId;
use hyperrs_fs::dir::SafeDir;
use hyperrs_fs::file::{self, OpenFlags};
use hyperrs_fs::path::{IsAbsolute, SafePath, StrictComponents};
use hyperrs_linux::cgroup::{self, Cgroup};
use hyperrs_process::privilege::{PrivilegeError, Unprivileged};
use nix::errno::Errno;
use serde::Deserialize;
use std::time::Duration;
use thiserror::Error as ThisError;

const KILL_TIMEOUT: Duration = Duration::from_secs(5);

type LexicalPath = SafePath<IsAbsolute, StrictComponents>;

#[derive(Debug, ThisError)]
pub enum TeardownError {
    #[error(transparent)]
    Jail(#[from] JailRemoveError),
    #[error(transparent)]
    Net(#[from] VmNetError),
    #[error(transparent)]
    Unpin(#[from] PinError),
    #[error(transparent)]
    Lock(#[from] LocksError),
    #[error(transparent)]
    Privilege(#[from] PrivilegeError),
}

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

#[derive(Deserialize, Constructor)]
#[serde(deny_unknown_fields)]
pub struct Teardown {
    id: VmId,
}

impl Op for Teardown {
    type Output = VmOut;
    type Error = TeardownError;

    fn run(self, mut token: Unprivileged) -> Result<VmOut, TeardownError> {
        let root = token.elevate()?;
        let locks = Locks::open(&root)?;
        let lock = locks.vm(&root, &self.id)?;
        drop(root);
        let torn_down = self.teardown(&mut token);
        let _root = token.elevate()?;
        lock.remove().map_err(LocksError::Remove)?;
        torn_down.map(|()| VmOut::ToreDown)
    }
}

impl Teardown {
    pub fn teardown(&self, token: &mut Unprivileged) -> Result<(), TeardownError> {
        let config = Config::get();
        let cgroup_parent = config.parent_cgroup_dir();
        let jail_base = config.jail_base();
        let layout = JailLayout::new(&jail_base, &self.id);
        let _root = token.elevate().map_err(JailRemoveError::from)?;
        let cgroup = self
            .remove_cgroup(&cgroup_parent)
            .map_err(|e| TeardownError::from(JailRemoveError::from(e)));
        let jail = layout
            .remove()
            .map_err(|e| TeardownError::from(JailRemoveError::from(e)));
        let net = self
            .net()
            .teardown(config.net().ok())
            .map_err(TeardownError::from);
        let pins = self
            .unpin_sockets(&config.socket_dir())
            .map_err(TeardownError::from);
        cgroup.and(jail).and(net).and(pins)
    }

    pub fn unpin_sockets(&self, socket_dir: &LexicalPath) -> Result<(), PinError> {
        let dir = match SafeDir::open(socket_dir, OpenFlags::RDONLY) {
            Ok(dir) => dir,
            Err(file::ValidationError::Open(Errno::ENOENT)) => return Ok(()),
            Err(e) => return Err(PinError::Open(e)),
        };
        [API_SOCKET, VSOCK_SOCKET]
            .into_iter()
            .try_for_each(|socket| SocketPin::new(&self.id, socket).unpin(&dir))
    }

    /// The VM's network, as [`VmNet`] sees it.
    pub fn net(&self) -> VmNet<'_> {
        VmNet { id: &self.id }
    }

    pub fn remove_cgroup(&self, parent: &LexicalPath) -> Result<(), CgroupError> {
        let cgroup = match Cgroup::open(&parent.join(&self.id)) {
            Ok(cgroup) => cgroup,
            Err(cgroup::OpenError::Open(file::ValidationError::Open(Errno::ENOENT))) => {
                return Ok(())
            }
            Err(e) => return Err(CgroupError::Open(e)),
        };
        cgroup.kill_procs(KILL_TIMEOUT).map_err(CgroupError::Kill)?;
        cgroup.remove().map_err(CgroupError::Remove)
    }
}

#[cfg(test)]
mod tests {
    use super::Teardown;
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
        let teardown = Teardown::new(id);
        teardown
            .remove_cgroup(&strict(&parent))
            .expect("missing parent must be Ok");
        parent.create_dir_all().unwrap();
        teardown
            .remove_cgroup(&strict(&parent))
            .expect("missing leaf must be Ok");
        assert!(parent.exists(), "cgroup parent must survive");
    }
}
