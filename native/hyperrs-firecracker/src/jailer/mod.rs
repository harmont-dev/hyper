// SPDX-License-Identifier: MIT
//! API into Firecracker's jailer.

pub mod chroot;

use bon::Builder;
use chroot::JailLayout;
use hyperrs_fs::path::{IsAbsolute, SafePath, StrictComponent, StrictComponents};
use hyperrs_process::binary::{RootSafeBin, RootSafeBinPathBuf};
use hyperrs_process::privilege::{RootCommandExt, Unprivileged};
use nix::unistd::{Gid, Uid};
use std::num::NonZeroU64;
use std::process::Command;

const FIRECRACKER: &str = "firecracker";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CpuMax {
    /// How many microseconds this cgroup can run for.
    pub quota_us: NonZeroU64,
    /// Out of how many microseconds is `quota_us` configured.
    pub period_us: NonZeroU64,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Builder)]
pub struct CgroupLimits {
    /// The RAM usage, in bytes.
    memory_max: Option<NonZeroU64>,
    /// The CPU limits.
    cpu_max: Option<CpuMax>,
}

/// A fully-resolved jailer invocation.
#[derive(Builder)]
pub struct Jailer<'a> {
    /// The binary to the jailer.
    jailer: &'a RootSafeBin<"jailer">,
    /// The binary to firecracker.
    firecracker: &'a RootSafeBinPathBuf<FIRECRACKER>,
    layout: &'a JailLayout<'a>,
    /// The cgroup in which a new, per-vm cgroup will be created.
    ///
    /// ```text
    /// /sys/fs/cgroup/
    ///   hyper/  <- parent cgroup
    ///     <vm-id-1>/
    ///     <vm-id-2>/
    /// ```
    parent_cgroup: &'a StrictComponent,
    /// The user this VM runs under.
    uid: Uid,
    /// The group this VM runs under.
    gid: Gid,
    /// The explicit cgroup settings.
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
            .arg(self.layout.id().as_os_str())
            .arg("--exec-file")
            .arg(self.firecracker.as_path())
            .arg("--uid")
            .arg(self.uid.to_string())
            .arg("--gid")
            .arg(self.gid.to_string())
            .arg("--chroot-base-dir")
            .arg(self.layout.base().as_path())
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
