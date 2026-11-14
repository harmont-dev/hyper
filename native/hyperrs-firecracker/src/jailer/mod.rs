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
#[cfg_attr(
    feature = "serde",
    derive(serde::Deserialize),
    serde(deny_unknown_fields)
)]
pub struct CpuMax {
    /// How many microseconds this cgroup can run for.
    pub quota_us: NonZeroU64,
    /// Out of how many microseconds is `quota_us` configured.
    pub period_us: NonZeroU64,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Builder)]
#[cfg_attr(
    feature = "serde",
    derive(serde::Deserialize),
    serde(deny_unknown_fields)
)]
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
    /// The pinned network namespace the jailer joins before starting Firecracker.
    netns: &'a SafePath<IsAbsolute, StrictComponents>,
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
            .arg(self.parent_cgroup)
            .arg("--netns")
            .arg(self.netns.as_path());

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
    //! The jailer runs as root with the argv built here, so the laws are about what it is told:
    //!
    //! - argv round-trip: the flags before `--` parse back, pair by pair, into exactly the VM id,
    //!   uid, gid, chroot base, parent cgroup, netns and cgroup limits the invocation was built
    //!   from; `--` occurs once and is followed by nothing but `--api-sock <api_sock>`;
    //! - `--exec-file` is the vetted Firecracker's own path, which `RootSafeBinPathBuf` only
    //!   accepts when no one but root can rewrite a directory above it.

    use super::chroot::JailLayout;
    use super::{CgroupLimits, CpuMax, Jailer};
    use crate::VmId;
    use assert_fs::TempDir;
    use hyperrs_fs::path::{IsAbsolute, SafePathBuf, StrictComponent, StrictComponents};
    use hyperrs_process::binary::{RootSafeBin, RootSafeBinPathBuf};
    use nix::unistd::{Gid, Uid};
    use proptest::prelude::*;
    use std::collections::BTreeMap;
    use std::ffi::OsString;
    use std::fs;
    use std::num::NonZeroU64;
    use std::os::unix::fs::PermissionsExt;
    use std::path::{Path, PathBuf};
    use test_strategy::proptest;

    type Strict = SafePathBuf<IsAbsolute, StrictComponents>;

    const BASE: &str = "/srv/jails";
    const API: &str = "/api.socket";
    const NETNS: &str = "/run/netns/hyper-x";

    fn strict(p: impl AsRef<Path>) -> Strict {
        p.as_ref().to_path_buf().try_into().unwrap()
    }

    fn is_root() -> bool {
        nix::unistd::geteuid().is_root()
    }

    fn root_binary(dir: &Path, name: &str, body: &str) -> PathBuf {
        let p = dir.join(name);
        fs::write(&p, body).unwrap();
        fs::set_permissions(&p, fs::Permissions::from_mode(0o755)).unwrap();
        std::os::unix::fs::chown(&p, Some(0), Some(0)).unwrap();
        p
    }

    struct Bins {
        _dir: TempDir,
        dir: PathBuf,
        jailer: RootSafeBin<"jailer">,
        firecracker: RootSafeBinPathBuf<"firecracker">,
    }

    fn bins() -> Bins {
        let tmp = TempDir::new().unwrap();
        let dir = tmp.path().to_path_buf();
        let jailer = RootSafeBin::open(&root_binary(&dir, "jailer", "jailer")).unwrap();
        let firecracker =
            RootSafeBinPathBuf::open(&root_binary(&dir, "firecracker", "vetted")).unwrap();
        Bins {
            _dir: tmp,
            dir,
            jailer,
            firecracker,
        }
    }

    fn argv(bins: &Bins, id: &VmId, uid: u32, gid: u32, limits: CgroupLimits) -> Vec<OsString> {
        let (base, api, netns) = (strict(BASE), strict(API), strict(NETNS));
        let layout = JailLayout::new(&base, id);
        Jailer::builder()
            .jailer(&bins.jailer)
            .firecracker(&bins.firecracker)
            .layout(&layout)
            .parent_cgroup(StrictComponent::from_static("hyper"))
            .uid(Uid::from_raw(uid))
            .gid(Gid::from_raw(gid))
            .limits(limits)
            .api_sock(&api)
            .netns(&netns)
            .build()
            .command()
            .get_args()
            .map(|a| a.to_os_string())
            .collect()
    }

    fn limits() -> impl Strategy<Value = CgroupLimits> {
        let nz = || (1u64..=u64::MAX).prop_map(|n| NonZeroU64::new(n).unwrap());
        (
            proptest::option::of(nz()),
            proptest::option::of((nz(), nz()).prop_map(|(quota_us, period_us)| CpuMax {
                quota_us,
                period_us,
            })),
        )
            .prop_map(|(memory_max, cpu_max)| CgroupLimits {
                memory_max,
                cpu_max,
            })
    }

    #[proptest(cases = 128)]
    fn argv_round_trips_every_input_and_ends_with_only_the_api_socket_as_root(
        #[strategy("[A-Za-z0-9][A-Za-z0-9-]{0,63}")] id: String,
        uid: u32,
        gid: u32,
        #[strategy(limits())] limits: CgroupLimits,
    ) {
        if !is_root() {
            eprintln!(
                "SKIP argv_round_trips_every_input_and_ends_with_only_the_api_socket_as_root"
            );
            return Ok(());
        }
        let bins = bins();
        let id: VmId = id.parse().unwrap();

        let args = argv(&bins, &id, uid, gid, limits);

        let split = args.iter().position(|a| a == "--").expect("no `--`");
        prop_assert_eq!(args.iter().filter(|a| *a == "--").count(), 1);
        prop_assert_eq!(
            &args[split + 1..],
            &[OsString::from("--api-sock"), API.into()][..]
        );
        let flags = &args[..split];
        prop_assert_eq!(flags.len() % 2, 0, "{:?}", flags);
        let mut got: BTreeMap<String, Vec<OsString>> = BTreeMap::new();
        for pair in flags.chunks(2) {
            let flag = pair[0].to_str().unwrap().to_owned();
            prop_assert!(flag.starts_with("--"), "{:?}", pair);
            prop_assert!(!pair[1].to_string_lossy().starts_with('-'), "{:?}", pair);
            got.entry(flag).or_default().push(pair[1].clone());
        }

        let mut want: BTreeMap<String, Vec<OsString>> = [
            ("--id", id.to_string().into()),
            ("--exec-file", bins.dir.join("firecracker").into_os_string()),
            ("--uid", uid.to_string().into()),
            ("--gid", gid.to_string().into()),
            ("--chroot-base-dir", BASE.into()),
            ("--cgroup-version", "2".into()),
            ("--parent-cgroup", "hyper".into()),
            ("--netns", NETNS.into()),
        ]
        .into_iter()
        .map(|(k, v)| (k.to_owned(), vec![v]))
        .collect();
        let cgroups: Vec<OsString> = limits
            .memory_max
            .map(|m| format!("memory.max={m}").into())
            .into_iter()
            .chain(
                limits
                    .cpu_max
                    .map(|c| format!("cpu.max={} {}", c.quota_us, c.period_us).into()),
            )
            .collect();
        if !cgroups.is_empty() {
            want.insert("--cgroup".to_owned(), cgroups);
        }
        prop_assert_eq!(got, want);
    }
}
