// SPDX-License-Identifier: MIT
//! API into the Firecracker jailer.

use crate::firecracker::id::{JailGid, JailUid};
use crate::fs::path::{
    IsAbsolute, SafePath, StrictComponent, StrictComponentBuf, StrictComponents,
};
use crate::process::binary::{RootSafeBin, RootSafeBinPathBuf};
use crate::process::privilege::{RootCommandExt, Unprivileged};
use bon::Builder;
use std::fmt;
use std::num::NonZeroU64;
use std::ops::Deref;
use std::process::Command;
use std::str::FromStr;
use thiserror::Error as ThisError;

#[derive(Debug, ThisError)]
pub enum Error {
    #[error("invalid --id {0:?}: must be 1..=64 chars of [A-Za-z0-9-], not starting with '-'")]
    VmId(String),
}

/// A VM name that can be accepted by Firecracker.
#[derive(Debug, Clone)]
pub struct VmId(
    // This needs to be a path because jailer will expect to chroot into a directory of this name.
    StrictComponentBuf,
);

impl FromStr for VmId {
    type Err = Error;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let jailer_grammar = (1..=64).contains(&s.len())
            && !s.starts_with('-')
            && s.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-');

        if !jailer_grammar {
            return Err(Error::VmId(s.to_string()));
        }

        let component: &StrictComponent = s.try_into().map_err(|_| Error::VmId(s.to_string()))?;
        Ok(Self(component.to_owned()))
    }
}

impl Deref for VmId {
    type Target = StrictComponent;
    fn deref(&self) -> &StrictComponent {
        &self.0
    }
}

impl fmt::Display for VmId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0.as_os_str().to_string_lossy())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, clap::Args)]
pub struct CpuMax {
    #[arg(long = "cpu-quota-us")]
    pub quota_us: NonZeroU64,
    #[arg(long = "cpu-period-us")]
    pub period_us: NonZeroU64,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Builder)]
pub struct CgroupLimits {
    memory_max: Option<NonZeroU64>,
    cpu_max: Option<CpuMax>,
}

/// A fully-resolved jailer invocation.
#[derive(Builder)]
pub struct Jailer<'a> {
    /// The binary to the jailer.
    jailer: &'a RootSafeBin<"jailer">,
    /// The binary to firecracker.
    firecracker: &'a RootSafeBinPathBuf<"firecracker">,
    /// The base directory for the jail.
    jail_base: &'a SafePath<IsAbsolute, StrictComponents>,
    /// The cgroup in which a new, per-vm cgroup will be created.
    ///
    /// ```text
    /// /sys/fs/cgroup/
    ///   hyper/  <- parent cgroup
    ///     <vm-id-1>/
    ///     <vm-id-2>/
    /// ```
    parent_cgroup: &'a StrictComponent,
    /// A unique name that is passed to the jailer.
    vm: &'a VmId,
    /// The user this VM runs under.
    uid: JailUid,
    /// The group this VM runs under.
    gid: JailGid,
    /// The explicit cgroup settings, given as `KEY=VALUE` pairs.
    limits: CgroupLimits,
    /// The path to the Firecracker API socket.
    api_sock: &'a SafePath<IsAbsolute, StrictComponents>,
    /// The netns the jailer must enter (`--netns`).
    netns: Option<&'a SafePath<IsAbsolute, StrictComponents>>,
}

impl Jailer<'_> {
    fn command(&self) -> Command {
        let mut cmd = self.jailer.command();
        cmd.arg("--id")
            .arg(self.vm.as_os_str())
            .arg("--exec-file")
            .arg(self.firecracker.as_path())
            .arg("--uid")
            .arg(self.uid.to_string())
            .arg("--gid")
            .arg(self.gid.to_string())
            .arg("--chroot-base-dir")
            .arg(self.jail_base.as_path())
            .arg("--cgroup-version")
            .arg("2")
            .arg("--parent-cgroup")
            .arg(self.parent_cgroup);

        if let Some(bytes) = self.limits.memory_max {
            cmd.arg("--cgroup").arg(format!("memory.max={bytes}"));
        }

        if let Some(CpuMax {
            quota_us,
            period_us,
        }) = self.limits.cpu_max
        {
            cmd.arg("--cgroup")
                .arg(format!("cpu.max={quota_us} {period_us}"));
        }

        if let Some(netns) = self.netns {
            cmd.arg("--netns").arg(netns.as_path());
        }

        cmd.arg("--").arg("--api-sock").arg(self.api_sock.as_path());
        cmd
    }

    /// Permanently become root and `execve` the jailer in our place.
    pub fn invoke(self, token: Unprivileged) -> ! {
        self.command().exec_as_root(token)
    }
}
