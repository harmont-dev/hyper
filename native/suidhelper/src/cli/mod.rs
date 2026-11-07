//! CLI interface of the setuid helper.

pub mod dm;
pub mod fork_delta;
mod host_init;
pub mod img;
pub mod thin;
mod version;
pub mod vm;

use crate::config::Config;
use crate::dm::HyperDmName;
use enum_dispatch::enum_dispatch;
use hyperrs_process::privilege::Unprivileged;
use serde::{de, Deserialize, Deserializer, Serialize};
use serde_with::DeserializeAs;
use std::ffi::OsString;
use std::fmt::Display;
use thiserror::Error as ThisError;

const EXIT_FAILURE: i32 = 2;

pub trait Op {
    type Output: Serialize;
    type Error: Display;

    fn run(self, token: Unprivileged) -> Result<Self::Output, Self::Error>;
}

#[enum_dispatch]
pub trait Dispatch {
    fn dispatch(self, token: Unprivileged) -> Result<String, String>;
}

impl<T: Op> Dispatch for T {
    fn dispatch(self, token: Unprivileged) -> Result<String, String> {
        let output = self.run(token).map_err(|e| e.to_string())?;
        serde_json::to_string(&output).map_err(|e| e.to_string())
    }
}

pub struct MapperPath;

impl<'de> DeserializeAs<'de, HyperDmName> for MapperPath {
    fn deserialize_as<D: Deserializer<'de>>(deserializer: D) -> Result<HyperDmName, D::Error> {
        HyperDmName::from_device_path(&String::deserialize(deserializer)?)
            .map_err(de::Error::custom)
    }
}

#[enum_dispatch(Dispatch)]
#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
pub enum Request {
    VmLaunch(vm::launch::Launch),
    VmClaimApiSocket(vm::claim::ClaimApiSocket),
    VmClaimVsockSocket(vm::claim::ClaimVsockSocket),
    VmTeardown(vm::teardown::Teardown),
    ImgActivate(img::ImgActivate),
    DmRemove(dm::Remove),
    ThinPoolCreate(thin::ThinPoolCreate),
    ThinVolumeCreate(thin::ThinVolumeCreate),
    ThinDestroy(thin::ThinDestroy),
    ThinForkDelta(fork_delta::ThinForkDelta),
    HostInit(host_init::HostInit),
    Version(version::Version),
}

#[derive(Debug, ThisError)]
pub enum RequestError {
    #[error("expected exactly one argument: the JSON request")]
    Arity,
    #[error("the request is not UTF-8")]
    Utf8,
    #[error("invalid request: {0}")]
    Json(#[from] serde_json::Error),
}

impl Request {
    pub fn from_args(mut args: impl Iterator<Item = OsString>) -> Result<Self, RequestError> {
        let (Some(request), None) = (args.next(), args.next()) else {
            return Err(RequestError::Arity);
        };
        let request = request.into_string().map_err(|_| RequestError::Utf8)?;
        Ok(serde_json::from_str(&request)?)
    }

    pub fn main(token: Unprivileged) -> ! {
        let output = Request::from_args(std::env::args_os().skip(1))
            .map_err(|e| e.to_string())
            .and_then(|request| {
                // `version` is a pure self-report: it touches neither config nor privileges,
                // so render it before any setup that could fail (e.g. a missing config file).
                // Privileges are already dropped to the real uid by a pre-main constructor
                // (see `setuid_privileged`); root is only re-acquired inside `Privileged`.
                if !matches!(request, Request::Version(_)) {
                    Config::init().map_err(|e| format!("hyper-suidhelper: {e}"))?;
                }
                request.dispatch(token)
            });

        match output {
            Ok(json) => {
                println!("{json}");
                std::process::exit(0)
            }
            Err(e) => {
                eprintln!("{e}");
                std::process::exit(EXIT_FAILURE)
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{Request, RequestError};
    use proptest::prelude::*;
    use rstest::rstest;
    use serde_json::{json, Value};
    use std::ffi::OsString;
    use std::os::unix::ffi::OsStringExt;
    use test_strategy::proptest;

    fn parse(request: &Value) -> Result<Request, RequestError> {
        Request::from_args([OsString::from(request.to_string())].into_iter())
    }

    fn valid_requests() -> Vec<Value> {
        vec![
            json!({"op": "vm_launch", "id": "v1", "uid": 900_001, "gid": 900_001,
                   "kernel": "/srv/hyper/vmlinux", "device": "/dev/mapper/hyper-v1",
                   "limits": {"memory_max": 1, "cpu_max": {"quota_us": 1, "period_us": 1}}}),
            json!({"op": "vm_claim_api_socket", "id": "v1"}),
            json!({"op": "vm_claim_vsock_socket", "id": "v1"}),
            json!({"op": "vm_teardown", "id": "v1", "uid": 900_001}),
            json!({"op": "vm_teardown", "id": "v1"}),
            json!({"op": "img_activate", "name": "hyper-img-x", "base": "/srv/hyper/base.img",
                   "deltas": ["/srv/hyper/d1.img"], "chunk_sectors": 8}),
            json!({"op": "thin_pool_create", "name": "hyper-pool", "metadata": "/srv/hyper/meta",
                   "data": "/srv/hyper/data", "block_sectors": 128, "low_water": 0}),
            json!({"op": "dm_remove", "name": "hyper-v1", "retry": true}),
            json!({"op": "thin_volume_create", "pool": "hyper-pool", "thin_id": 1,
                   "name": "hyper-v1", "origin": "/dev/mapper/hyper-img"}),
            json!({"op": "thin_volume_create", "pool": "hyper-pool", "thin_id": 2,
                   "name": "hyper-v2", "origin": "/dev/mapper/hyper-img", "parent": "hyper-v1"}),
            json!({"op": "thin_destroy", "pool": "hyper-pool", "name": "hyper-v1"}),
            json!({"op": "thin_fork_delta", "pool": "hyper-pool", "meta": "/dev/loop3",
                   "parent": "hyper-v1", "scratch_id": 9, "origin": "/dev/mapper/hyper-img",
                   "cow": "/srv/hyper/cow.img", "chunk_sectors": 8}),
            json!({"op": "host_init"}),
            json!({"op": "version"}),
        ]
    }

    #[test]
    fn every_op_accepts_its_canonical_request() {
        for request in valid_requests() {
            assert!(
                parse(&request).is_ok(),
                "{request}: {:?}",
                parse(&request).err()
            );
        }
    }

    #[proptest]
    fn an_unknown_field_is_refused_on_every_op(
        #[strategy(0..valid_requests().len())] which: usize,
        #[strategy("[a-z_]{1,12}")] field: String,
    ) {
        let mut request = valid_requests().swap_remove(which);
        prop_assume!(!request.as_object().unwrap().contains_key(&field));
        request[&field] = json!(1);
        prop_assert!(
            matches!(parse(&request), Err(RequestError::Json(_))),
            "{request}"
        );
    }

    #[test]
    fn dropping_any_required_field_is_refused() {
        for request in valid_requests() {
            let optional: &[&str] = match request["op"].as_str().unwrap() {
                "vm_teardown" => &["uid"],
                "thin_volume_create" => &["parent"],
                _ => &[],
            };
            for field in request.as_object().unwrap().keys() {
                if field == "op" || optional.contains(&field.as_str()) {
                    continue;
                }
                let mut partial = request.clone();
                partial.as_object_mut().unwrap().remove(field);
                assert!(
                    parse(&partial).is_err(),
                    "accepted without {field}: {partial}"
                );
            }
        }
    }

    #[rstest]
    #[case::unknown_op(json!({"op": "dmsetup", "args": ["ls"]}))]
    #[case::missing_op(json!({"id": "v1"}))]
    #[case::not_an_object(json!(["vm_teardown", "v1"]))]
    #[case::op_not_a_string(json!({"op": 1}))]
    #[case::foreign_dm_name(json!({"op": "dm_remove", "name": "sda1", "retry": false}))]
    #[case::traversing_vm_id(json!({"op": "vm_claim_api_socket", "id": "../v1"}))]
    #[case::relative_kernel(json!({"op": "vm_launch", "id": "v1", "uid": 900_001, "gid": 900_001,
        "kernel": "vmlinux", "device": "/dev/mapper/hyper-v1", "limits": {}}))]
    #[case::rootfs_device_by_name(json!({"op": "vm_launch", "id": "v1", "uid": 900_001,
        "gid": 900_001, "kernel": "/srv/hyper/vmlinux", "device": "hyper-v1", "limits": {}}))]
    #[case::retired_prepare_op(json!({"op": "vm_prepare", "id": "v1", "uid": 900_001}))]
    #[case::retired_stage_op(json!({"op": "vm_stage", "id": "v1", "kernel": "/srv/hyper/vmlinux",
        "device": "/dev/mapper/hyper-v1", "uid": 900_001, "gid": 900_001}))]
    #[case::fork_delta_caller_named_source(json!({"op": "thin_fork_delta", "pool": "hyper-pool",
        "meta": "/dev/loop3", "parent": "hyper-v1", "scratch_id": 9, "src": "/dev/mapper/hyper-a",
        "origin": "/dev/mapper/hyper-img", "cow": "/srv/hyper/cow.img", "chunk_sectors": 8}))]
    #[case::fork_delta_scratch_id_past_24_bits(json!({"op": "thin_fork_delta", "pool": "hyper-pool",
        "meta": "/dev/loop3", "parent": "hyper-v1", "scratch_id": 16_777_216,
        "origin": "/dev/mapper/hyper-img", "cow": "/srv/hyper/cow.img", "chunk_sectors": 8}))]
    #[case::retired_thin_copy_op(json!({"op": "thin_copy", "pool": "hyper-pool",
        "meta": "/dev/loop3", "src": "/dev/mapper/hyper-a", "origin": "/dev/mapper/hyper-img",
        "cow": "/srv/hyper/cow.img", "chunk_sectors": 8}))]
    #[case::thin_id_as_string(json!({"op": "thin_volume_create", "pool": "hyper-pool", "thin_id": "1",
        "name": "hyper-v1", "origin": "/dev/mapper/hyper-img"}))]
    #[case::thin_id_past_24_bits(json!({"op": "thin_volume_create", "pool": "hyper-pool",
        "thin_id": 16_777_216, "name": "hyper-v1", "origin": "/dev/mapper/hyper-img"}))]
    #[case::thin_origin_by_name(json!({"op": "thin_volume_create", "pool": "hyper-pool", "thin_id": 1,
        "name": "hyper-v1", "origin": "hyper-img"}))]
    #[case::retired_thin_create_op(json!({"op": "thin_create", "pool": "hyper-pool", "thin_id": 1,
        "name": "hyper-v1", "origin": "/dev/mapper/hyper-img"}))]
    #[case::caller_named_parent_id(json!({"op": "thin_volume_create", "pool": "hyper-pool",
        "parent": "hyper-v1", "parent_id": 1, "thin_id": 2, "name": "hyper-v2",
        "origin": "/dev/mapper/hyper-img"}))]
    #[case::foreign_parent(json!({"op": "thin_volume_create", "pool": "hyper-pool", "parent": "root",
        "thin_id": 2, "name": "hyper-v2", "origin": "/dev/mapper/hyper-img"}))]
    #[case::caller_named_destroy_id(json!({"op": "thin_destroy", "pool": "hyper-pool",
        "name": "hyper-v1", "thin_id": 1}))]
    #[case::relative_delta(json!({"op": "img_activate", "name": "hyper-img-x",
        "base": "/srv/hyper/base.img", "deltas": ["d1.img"], "chunk_sectors": 8}))]
    #[case::caller_chosen_sectors(json!({"op": "img_activate", "name": "hyper-img-x", "sectors": 8,
        "base": "/srv/hyper/base.img", "deltas": [], "chunk_sectors": 8}))]
    #[case::foreign_image_name(json!({"op": "img_activate", "name": "vg0-img",
        "base": "/srv/hyper/base.img", "deltas": [], "chunk_sectors": 8}))]
    #[case::deltas_not_a_list(json!({"op": "img_activate", "name": "hyper-img-x",
        "base": "/srv/hyper/base.img", "deltas": "/srv/hyper/d1.img", "chunk_sectors": 8}))]
    #[case::retired_linear_op(json!({"op": "dm_linear", "name": "hyper-img",
        "origin": "/srv/hyper/base.img"}))]
    #[case::retired_snapshot_op(json!({"op": "dm_snapshot", "name": "hyper-v1",
        "origin": "/dev/mapper/hyper-img", "cow": "/srv/hyper/cow.img", "chunk_sectors": 8}))]
    #[case::retired_thin_pool_op(json!({"op": "dm_thin_pool", "name": "hyper-pool",
        "metadata": "/srv/hyper/meta", "data": "/srv/hyper/data", "block_sectors": 128,
        "low_water": 0}))]
    #[case::retired_message_op(json!({"op": "dm_message", "name": "hyper-pool",
        "message": "delete 1"}))]
    #[case::retired_sys_test_op(json!({"op": "sys_test"}))]
    #[case::retired_suspend_op(json!({"op": "dm_suspend", "name": "hyper-v1"}))]
    #[case::retired_thin_op(json!({"op": "dm_thin", "name": "hyper-v1", "pool": "hyper-pool",
        "thin_id": 1, "origin": "/dev/mapper/hyper-img"}))]
    fn malformed_requests_are_refused(#[case] request: Value) {
        assert!(
            matches!(parse(&request), Err(RequestError::Json(_))),
            "{request}"
        );
    }

    #[rstest]
    #[case::no_argument(vec![])]
    #[case::two_arguments(vec![r#"{"op":"version"}"#, r#"{"op":"version"}"#])]
    fn the_request_must_be_exactly_one_argument(#[case] args: Vec<&str>) {
        let args = args.into_iter().map(OsString::from);
        assert!(matches!(Request::from_args(args), Err(RequestError::Arity)));
    }

    #[rstest]
    #[case::trailing_garbage(r#"{"op":"version"} x"#)]
    #[case::two_requests(r#"{"op":"version"}{"op":"version"}"#)]
    #[case::duplicate_op(r#"{"op":"version","op":"host_init"}"#)]
    #[case::duplicate_field(r#"{"op":"vm_claim_api_socket","id":"v1","id":"v2"}"#)]
    #[case::empty("")]
    fn the_argument_must_be_exactly_one_json_object(#[case] raw: &str) {
        assert!(matches!(
            Request::from_args([OsString::from(raw)].into_iter()),
            Err(RequestError::Json(_))
        ));
    }

    #[test]
    fn non_utf8_is_refused() {
        let raw = OsString::from_vec(b"{\"op\":\"version\xff\"}".to_vec());
        assert!(matches!(
            Request::from_args([raw].into_iter()),
            Err(RequestError::Utf8)
        ));
    }
}
