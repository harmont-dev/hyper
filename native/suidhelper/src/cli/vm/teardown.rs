// SPDX-License-Identifier: MIT
//! `vm teardown`: delete a VM's stale chroot and cgroup leaf before relaunching the jailer.

use super::VmOut;
use crate::cli::Op;
use crate::config::Config;
use crate::network;
use derive_more::Constructor;
use hyperrs_firecracker::jailer::chroot::{JailLayout, RemoveError};
use hyperrs_firecracker::VmId;
use hyperrs_fs::file;
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
    Network(#[from] network::TeardownError),
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
    uid: Option<u32>,
}

impl Op for Teardown {
    type Output = VmOut;
    type Error = TeardownError;

    fn run(self, mut token: Unprivileged) -> Result<VmOut, TeardownError> {
        self.teardown(&mut token)?;
        Ok(VmOut::ToreDown)
    }
}

impl Teardown {
    pub fn teardown(&self, token: &mut Unprivileged) -> Result<(), TeardownError> {
        let config = Config::get();
        let jail = (|| {
            let cgroup_parent = config.parent_cgroup_dir();
            let jail_base = config.jail_base();
            let layout = JailLayout::new(&jail_base, &self.id);
            let _root = token.elevate()?;
            self.remove_cgroup(&cgroup_parent)?;
            Ok::<_, JailRemoveError>(layout.remove()?)
        })()
        .map_err(TeardownError::from);
        let net = match (config.network(), self.uid) {
            (None, _) => Ok(()),
            (Some(_), Some(uid)) => network::teardown::Teardown::new(uid, &self.id)
                .and_then(|net| net.run(token))
                .map_err(|e| TeardownError::Network(e.into())),
            (Some(_), None) => network::teardown_orphan::TeardownOrphan::new(&self.id)
                .and_then(|net| net.run(token))
                .map_err(|e| TeardownError::Network(e.into())),
        };
        jail.and(net)
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
        let teardown = Teardown::new(id, None);
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
