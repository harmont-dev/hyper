// SPDX-License-Identifier: MIT
//! Typed invocation of the firecracker jailer: the validated argument newtypes
//! and the `execve` mechanics behind the `jailer` subcommand.
//!
//! Threat model: the BEAM is untrusted. It supplies only the VM id, uid/gid,
//! cgroup settings, and the API socket path — each guarded by a newtype below.
//! Every privileged path (the jailer binary, the firecracker `--exec-file`, the
//! chroot base, the parent cgroup) comes from the root-owned config, never the
//! caller. The refusal contracts on these newtypes are the security core: a
//! compromised BEAM must not be able to name a privileged path, request uid 0,
//! traverse out of the chroot base, inject a flag, or smuggle an
//! environment/fd into root.
//!
//! ## Validator laws (property-tested in `tests/tools/jailer.rs`)
//! - [`VmId`] round-trips exactly the allowed charset/length and rejects any
//!   separator, dot, NUL, whitespace, leading dash, empty, or over-long input.

use crate::firecracker::id::{JailGid, JailUid};
use crate::fs::path::{IsAbsolute, SafePath, StrictComponent, StrictComponents};
use crate::process::binary::{RootSafeBin, RootSafeBinPathBuf};
use crate::process::privilege::{RootCommandExt, Unprivileged};
use bon::Builder;
use derive_more::{AsRef, Display};
use std::num::NonZeroU64;
use std::path::Path;
use std::process::Command;
use std::str::FromStr;
use thiserror::Error as ThisError;

#[derive(Debug, ThisError)]
pub enum Error {
    #[error("invalid --id {0:?}: must be 1..=64 chars of [A-Za-z0-9_-], not starting with '-'")]
    VmId(String),
}

/// A VM id used as a chroot subdirectory name: `[A-Za-z0-9_-]`, length `1..=64`,
/// first character not `-` (so it can never be read as a flag). No `/`, `.`, NUL,
/// or whitespace can appear, so it can never traverse out of the chroot base.
#[derive(Debug, Clone, Display, AsRef)]
#[as_ref(str)]
pub struct VmId(String);

impl FromStr for VmId {
    type Err = Error;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let reject = || Error::VmId(s.to_string());
        let bytes = s.as_bytes();
        if !(1..=64).contains(&bytes.len()) {
            return Err(reject());
        }
        if bytes[0] == b'-' {
            return Err(reject());
        }
        if !bytes
            .iter()
            .all(|&b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
        {
            return Err(reject());
        }
        Ok(Self(s.to_string()))
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
    netns: Option<&'a Path>,
}

impl Jailer<'_> {
    fn command(&self) -> Command {
        let mut cmd = self.jailer.command();
        cmd.arg("--id")
            .arg::<&str>(self.vm.as_ref())
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
            cmd.arg("--netns").arg(netns);
        }

        cmd.arg("--").arg("--api-sock").arg(self.api_sock.as_path());
        cmd
    }

    /// Permanently become root and `execve` the jailer in our place.
    pub fn invoke(self, token: Unprivileged) -> ! {
        self.command().exec_as_root(token)
    }
}
