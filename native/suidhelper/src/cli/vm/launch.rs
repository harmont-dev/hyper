// SPDX-License-Identifier: MIT
//! Spawn a jailer instance.

use super::teardown::{Teardown, TeardownError};
use super::VmOut;
use crate::cli::{MapperPath, Op};
use crate::config::{BinError, Config};
use crate::dm::HyperDmName;
use crate::id::{IdError, JailOwner};
use hyperrs_firecracker::jailer::chroot::{BuildError, JailLayout, KernelError, KernelImage};
use hyperrs_firecracker::jailer::{CgroupLimits, Jailer};
use hyperrs_firecracker::VmId;
use hyperrs_fs::dir::DirError;
use hyperrs_fs::path::{IsAbsolute, SafePath, SafePathBuf, StrictComponent, StrictComponents};
use hyperrs_linux::dm::OpenDeviceError;
use hyperrs_process::privilege::{PrivilegeError, Unprivileged};
use serde::Deserialize;
use serde_with::serde_as;
use thiserror::Error as ThisError;

#[derive(Debug, ThisError)]
pub enum LaunchError {
    #[error(transparent)]
    Bin(#[from] BinError),
    #[error(transparent)]
    Id(#[from] IdError),
    #[error(transparent)]
    Kernel(#[from] KernelError),
    #[error(transparent)]
    Teardown(#[from] TeardownError),
    #[error("creating the jail root: {0}")]
    Root(#[from] DirError),
    #[error("opening rootfs device: {0}")]
    Device(#[from] OpenDeviceError),
    #[error(transparent)]
    Build(#[from] BuildError),
    #[error(transparent)]
    Privilege(#[from] PrivilegeError),
}

#[serde_as]
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Launch {
    id: VmId,
    uid: u32,
    gid: u32,
    kernel: SafePathBuf<IsAbsolute, StrictComponents>,
    #[serde_as(as = "MapperPath")]
    device: HyperDmName,
    limits: CgroupLimits,
}

impl Op for Launch {
    type Output = VmOut;
    type Error = LaunchError;

    fn run(self, mut token: Unprivileged) -> Result<VmOut, LaunchError> {
        let config = Config::get();

        let jailer = config.jailer()?;
        let firecracker = config.firecracker()?;
        let jail_base = config.jail_base();
        let range = config.uid_gid_range();
        let uid = range.uid(self.uid)?;
        let gid = range.gid(self.gid)?;
        let kernel = KernelImage::open(&self.kernel)?;

        let layout = JailLayout::new(&jail_base, &self.id);
        let api_sock =
            SafePath::from_static::<"/">().join(StrictComponent::from_static(super::API_SOCKET));

        Teardown::new(self.id.clone()).teardown(&mut token)?;

        {
            let _root = token.elevate()?;
            let device = self.device.open()?;
            layout
                .create_root()?
                .builder(JailOwner { uid, gid }.into())
                .kernel(&kernel)
                .rootfs(&device)
                .build()?;
        }

        Jailer::builder()
            .jailer(&jailer)
            .firecracker(&firecracker)
            .layout(&layout)
            .parent_cgroup(config.parent_cgroup())
            .uid(uid.into())
            .gid(gid.into())
            .limits(self.limits)
            .api_sock(&api_sock)
            .build()
            .invoke(token)
    }
}

#[cfg(test)]
mod tests {
    use super::Launch;
    use pretty_assertions::assert_eq;
    use rstest::rstest;
    use serde_json::{json, Value};

    fn parse(id: &str, extra: Value) -> Result<Launch, serde_json::Error> {
        let mut request = json!({
            "id": id,
            "uid": 900_001,
            "gid": 900_001,
            "kernel": "/srv/hyper/vmlinux",
            "device": "/dev/mapper/hyper-vm1",
            "limits": {},
        });
        request
            .as_object_mut()
            .unwrap()
            .extend(extra.as_object().unwrap().clone());
        serde_json::from_value(request)
    }

    fn limits(limits: Value) -> Value {
        json!({ "limits": limits })
    }

    #[rstest]
    #[case::unlimited(limits(json!({})), true)]
    #[case::memory_max(limits(json!({"memory_max": 1_048_576})), true)]
    #[case::cpu_max(limits(json!({"cpu_max": {"quota_us": 50_000, "period_us": 100_000}})), true)]
    #[case::all_minimal(limits(json!({"memory_max": 1, "cpu_max": {"quota_us": 1, "period_us": 1}})), true)]
    #[case::explicit_nulls(limits(json!({"memory_max": null, "cpu_max": null})), true)]
    #[case::no_limits(json!({"limits": null}), false)]
    #[case::zero_memory(limits(json!({"memory_max": 0})), false)]
    #[case::negative_memory(limits(json!({"memory_max": -1})), false)]
    #[case::string_memory(limits(json!({"memory_max": "max"})), false)]
    #[case::memory_past_u64(limits(json!({"memory_max": 18_446_744_073_709_551_616_f64})), false)]
    #[case::quota_without_period(limits(json!({"cpu_max": {"quota_us": 50_000}})), false)]
    #[case::period_without_quota(limits(json!({"cpu_max": {"period_us": 100_000}})), false)]
    #[case::zero_quota(limits(json!({"cpu_max": {"quota_us": 0, "period_us": 100_000}})), false)]
    #[case::zero_period(limits(json!({"cpu_max": {"quota_us": 50_000, "period_us": 0}})), false)]
    #[case::extra_cpu_field(limits(json!({"cpu_max": {"quota_us": 1, "period_us": 1, "burst_us": 1}})), false)]
    #[case::raw_cgroup_in_limits(limits(json!({"cgroup": "memory.max=1"})), false)]
    #[case::limits_at_top_level(json!({"memory_max": 1}), false)]
    #[case::caller_named_api_socket(json!({"api_sock": "/api.socket"}), false)]
    #[case::caller_named_netns(json!({"netns": "/var/run/netns/other"}), false)]
    #[case::caller_named_exec_file(json!({"exec_file": "/bin/sh"}), false)]
    #[case::caller_named_chroot_base(json!({"chroot_base_dir": "/"}), false)]
    #[case::negative_uid(json!({"uid": -1}), false)]
    #[case::string_uid(json!({"uid": "900001"}), false)]
    fn fields(#[case] extra: Value, #[case] accepted: bool) {
        assert_eq!(parse("vm1", extra.clone()).is_ok(), accepted, "{extra}");
    }

    #[rstest]
    #[case::plain("vm1", true)]
    #[case::dashed("vm-1", true)]
    #[case::empty("", false)]
    #[case::parent("..", false)]
    #[case::traversal("../vm1", false)]
    #[case::nested("a/b", false)]
    #[case::leading_dash("-vm1", false)]
    #[case::underscore("a_b", false)]
    fn vm_id(#[case] id: &str, #[case] accepted: bool) {
        assert_eq!(parse(id, json!({})).is_ok(), accepted, "{id:?}");
    }
}
