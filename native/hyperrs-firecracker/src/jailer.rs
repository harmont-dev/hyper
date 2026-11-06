// SPDX-License-Identifier: MIT
//! API into the Firecracker jailer.

use crate::chroot_jail::JailLayout;
use bon::Builder;
use hyperrs_fs::path::{
    ComponentError, IsAbsolute, SafePath, StrictComponent, StrictComponentBuf, StrictComponents,
};
use hyperrs_process::binary::{RootSafeBin, RootSafeBinPathBuf};
use hyperrs_process::privilege::{RootCommandExt, Unprivileged};
use nix::unistd::{Gid, Uid};
use std::fmt;
use std::num::NonZeroU64;
use std::ops::Deref;
use std::process::Command;
use std::str::FromStr;
use thiserror::Error as ThisError;

pub const FIRECRACKER: &str = "firecracker";

#[derive(Debug, ThisError)]
pub enum VmIdError {
    #[error("invalid --id {0:?}: must be 1..=64 chars of [A-Za-z0-9-], not starting with '-'")]
    VmId(String),
    #[error(transparent)]
    Component(#[from] ComponentError),
}

/// A VM name that can be accepted by Firecracker.
#[derive(Debug, Clone)]
pub struct VmId(
    // This needs to be a path because jailer will expect to chroot into a directory of this name.
    StrictComponentBuf,
);

impl FromStr for VmId {
    type Err = VmIdError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let jailer_grammar = (1..=64).contains(&s.len())
            && !s.starts_with('-')
            && s.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-');

        if !jailer_grammar {
            return Err(VmIdError::VmId(s.to_string()));
        }

        let component: &StrictComponent = s.try_into()?;
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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CpuMax {
    pub quota_us: NonZeroU64,
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

#[cfg(test)]
mod tests {
    use super::VmId;
    use proptest::prelude::*;
    use std::str::FromStr;

    proptest! {
        /// Every string over the allowed charset/length with a non-dash leader parses
        /// and renders back to itself.
        #[test]
        fn vmid_valid_round_trips(s in "[A-Za-z0-9][A-Za-z0-9-]{0,63}") {
            prop_assert_eq!(VmId::from_str(&s).unwrap().to_string(), s);
        }

        /// A leading dash is always rejected (no flag injection via `--id`).
        #[test]
        fn vmid_leading_dash_rejected(s in "-[A-Za-z0-9-]{0,63}") {
            prop_assert!(VmId::from_str(&s).is_err());
        }

        /// Any embedded path separator is rejected (no chroot traversal via `--id`).
        #[test]
        fn vmid_slash_rejected(s in "[A-Za-z0-9_]{0,10}/[A-Za-z0-9_]{0,10}") {
            prop_assert!(VmId::from_str(&s).is_err());
        }

        /// Over-length ids (>64) are rejected.
        #[test]
        fn vmid_too_long_rejected(s in "[A-Za-z][A-Za-z0-9-]{64,90}") {
            prop_assert!(VmId::from_str(&s).is_err());
        }

    }

    #[test]
    fn vmid_rejects_known_bad_shapes() {
        for bad in [
            "",              // empty
            "-leading",      // leading dash
            "a/b",           // separator
            "a.b",           // dot
            ".",             // current dir
            "..",            // parent dir
            "a_b",           // underscore (firecracker rejects it)
            "a b",           // whitespace
            "a\tb",          // tab
            "a\0b",          // NUL
            "naïve",         // non-ascii
            &"x".repeat(65), // too long
        ] {
            assert!(VmId::from_str(bad).is_err(), "VmId accepted {bad:?}");
        }
    }
}
