//! CLI interface of the setuid helper.

pub mod dm;
mod host_init;
mod sys_test;
pub mod thin_copy;
mod version;
pub mod vm;

use crate::config::Config;
use crate::dm::HyperDmName;
use enum_dispatch::enum_dispatch;
use hyperrs_linux::dm::ThinId;
use hyperrs_process::privilege::{self, Unprivileged};
use serde::{de, Deserialize, Deserializer, Serialize};
use serde_with::DeserializeAs;
use std::ffi::OsString;
use std::process::ExitCode;
use thiserror::Error as ThisError;

/// Errors of the dispatch layer: an invalid configured binary (`RootSafeBin`), the
/// privilege guard, or the chosen tool's own failure on the way out. (Operand
/// validation is handled by clap at parse time, so it never reaches here.)
#[derive(Debug, ThisError)]
pub enum DispatchError {
    #[error(transparent)]
    Privilege(#[from] privilege::PrivilegeError),
    /// A tool's own error (operand validation or execution), boxed so this layer
    /// stays decoupled from each tool's concrete error type.
    #[error(transparent)]
    Tool(Box<dyn std::error::Error>),
    #[error(transparent)]
    Retryable(Box<dyn std::error::Error>),
}

pub const EXIT_FAILURE: u8 = 2;
pub const EXIT_RETRYABLE: u8 = 75;

impl DispatchError {
    pub fn tool(e: impl std::error::Error + 'static) -> Self {
        DispatchError::Tool(Box::new(e))
    }

    pub fn exit_code(&self) -> u8 {
        match self {
            DispatchError::Retryable(_) => EXIT_RETRYABLE,
            DispatchError::Privilege(_) | DispatchError::Tool(_) => EXIT_FAILURE,
        }
    }
}

pub trait OpError: std::error::Error + 'static {}

impl OpError for std::convert::Infallible {}

pub trait Op {
    type Output: Serialize;
    type Error: Into<DispatchError>;

    fn run(self, token: Unprivileged) -> Result<Self::Output, Self::Error>;
}

#[enum_dispatch]
pub trait Dispatch {
    fn dispatch(self, token: Unprivileged) -> Result<serde_json::Value, DispatchError>;
}

impl<T: Op> Dispatch for T {
    fn dispatch(self, token: Unprivileged) -> Result<serde_json::Value, DispatchError> {
        to_json(self.run(token).map_err(Into::into)?)
    }
}

impl<E: OpError> From<E> for DispatchError {
    fn from(e: E) -> Self {
        DispatchError::tool(e)
    }
}

pub fn to_json(out: impl Serialize) -> Result<serde_json::Value, DispatchError> {
    serde_json::to_value(out).map_err(DispatchError::tool)
}

pub struct MapperPath;

impl<'de> DeserializeAs<'de, HyperDmName> for MapperPath {
    fn deserialize_as<D: Deserializer<'de>>(deserializer: D) -> Result<HyperDmName, D::Error> {
        HyperDmName::from_device_path(&String::deserialize(deserializer)?)
            .map_err(de::Error::custom)
    }
}

pub struct ThinIdNumber;

impl<'de> DeserializeAs<'de, ThinId> for ThinIdNumber {
    fn deserialize_as<D: Deserializer<'de>>(deserializer: D) -> Result<ThinId, D::Error> {
        ThinId::new(u32::deserialize(deserializer)?).map_err(de::Error::custom)
    }
}

#[enum_dispatch(Dispatch)]
#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
pub enum Request {
    VmPrepare(vm::prepare::Prepare),
    VmLaunch(vm::launch::Launch),
    VmStage(vm::stage::Stage),
    VmGrantApi(vm::grant::GrantApi),
    VmGrantVsock(vm::grant::GrantVsock),
    VmTeardown(vm::teardown::Teardown),
    DmLinear(dm::Linear),
    DmSnapshot(dm::Snapshot),
    DmThinPool(dm::ThinPool),
    DmThin(dm::Thin),
    DmRemove(dm::Remove),
    DmSuspend(dm::Suspend),
    DmResume(dm::Resume),
    DmMessage(dm::Message),
    ThinCopy(thin_copy::ThinCopy),
    HostInit(host_init::HostInit),
    SysTest(sys_test::SysTest),
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

pub fn parse_request(mut args: impl Iterator<Item = OsString>) -> Result<Request, RequestError> {
    let (Some(request), None) = (args.next(), args.next()) else {
        return Err(RequestError::Arity);
    };
    let request = request.into_string().map_err(|_| RequestError::Utf8)?;
    Ok(serde_json::from_str(&request)?)
}

pub fn run(token: Unprivileged) -> ExitCode {
    let request = match parse_request(std::env::args_os().skip(1)) {
        Ok(request) => request,
        Err(e) => return fail(&DispatchError::tool(e)),
    };

    // `version` is a pure self-report: it touches neither config nor privileges,
    // so render it before any setup that could fail (e.g. a missing config file).
    // Privileges are already dropped to the real uid by a pre-main constructor
    // (see `setuid_privileged`); root is only re-acquired inside `Privileged`.
    if !matches!(request, Request::Version(_)) {
        if let Err(e) = Config::init() {
            eprintln!("hyper-suidhelper: {e}");
            return ExitCode::from(EXIT_FAILURE);
        }
    }

    let output = request
        .dispatch(token)
        .and_then(|value| serde_json::to_string(&value).map_err(DispatchError::tool));
    match output {
        Ok(json) => {
            println!("{json}");
            ExitCode::SUCCESS
        }
        Err(e) => fail(&e),
    }
}

fn fail(e: &DispatchError) -> ExitCode {
    eprintln!("{e}");
    ExitCode::from(e.exit_code())
}

#[cfg(test)]
mod tests {
    use super::{parse_request, Request, RequestError};
    use proptest::prelude::*;
    use rstest::rstest;
    use serde_json::{json, Value};
    use std::ffi::OsString;
    use std::os::unix::ffi::OsStringExt;
    use test_strategy::proptest;

    fn parse(request: &Value) -> Result<Request, RequestError> {
        parse_request([OsString::from(request.to_string())].into_iter())
    }

    fn valid_requests() -> Vec<Value> {
        vec![
            json!({"op": "vm_prepare", "id": "v1", "uid": 900_001}),
            json!({"op": "vm_launch", "id": "v1", "uid": 900_001, "gid": 900_001}),
            json!({"op": "vm_stage", "id": "v1", "kernel": "/srv/hyper/vmlinux",
                   "device": "/dev/mapper/hyper-v1", "uid": 900_001, "gid": 900_001}),
            json!({"op": "vm_grant_api", "id": "v1"}),
            json!({"op": "vm_grant_vsock", "id": "v1"}),
            json!({"op": "vm_teardown", "id": "v1", "uid": 900_001}),
            json!({"op": "vm_teardown", "id": "v1"}),
            json!({"op": "dm_linear", "name": "hyper-img", "readonly": true, "sectors": 8,
                   "origin": "/srv/hyper/base.img"}),
            json!({"op": "dm_snapshot", "name": "hyper-img-1", "readonly": true, "sectors": 8,
                   "origin": "/dev/mapper/hyper-img", "cow": "/srv/hyper/cow.img", "chunk_sectors": 8}),
            json!({"op": "dm_thin_pool", "name": "hyper-pool", "sectors": 8, "metadata": "/srv/hyper/meta",
                   "data": "/srv/hyper/data", "block_sectors": 128, "low_water": 0}),
            json!({"op": "dm_thin", "name": "hyper-v1", "sectors": 8, "pool": "hyper-pool", "thin_id": 1,
                   "origin": "/dev/mapper/hyper-img"}),
            json!({"op": "dm_remove", "name": "hyper-v1", "retry": true}),
            json!({"op": "dm_suspend", "name": "hyper-v1"}),
            json!({"op": "dm_resume", "name": "hyper-v1"}),
            json!({"op": "dm_message", "name": "hyper-pool", "message": "create_thin 1"}),
            json!({"op": "thin_copy", "pool": "hyper-pool", "meta": "/dev/loop3", "thin_id": 7,
                   "src": "/dev/mapper/hyper-a", "dst": "/dev/mapper/hyper-b"}),
            json!({"op": "host_init"}),
            json!({"op": "sys_test"}),
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
                "dm_thin" => &["origin"],
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
    #[case::traversing_vm_id(json!({"op": "vm_grant_api", "id": "../v1"}))]
    #[case::relative_kernel(json!({"op": "vm_stage", "id": "v1", "kernel": "vmlinux",
        "device": "/dev/mapper/hyper-v1", "uid": 900_001, "gid": 900_001}))]
    #[case::stage_device_by_name(json!({"op": "vm_stage", "id": "v1", "kernel": "/srv/hyper/vmlinux",
        "device": "hyper-v1", "uid": 900_001, "gid": 900_001}))]
    #[case::thin_copy_src_outside_mapper(json!({"op": "thin_copy", "pool": "hyper-pool",
        "meta": "/dev/loop3", "thin_id": 7, "src": "/dev/sda", "dst": "/dev/mapper/hyper-b"}))]
    #[case::thin_copy_chunk_bytes(json!({"op": "thin_copy", "pool": "hyper-pool", "meta": "/dev/loop3",
        "thin_id": 7, "src": "/dev/mapper/hyper-a", "dst": "/dev/mapper/hyper-b", "chunk_bytes": 1}))]
    #[case::thin_id_as_string(json!({"op": "dm_thin", "name": "hyper-v1", "sectors": 8,
        "pool": "hyper-pool", "thin_id": "1"}))]
    #[case::relative_cow(json!({"op": "dm_snapshot", "name": "hyper-v1", "readonly": true,
        "sectors": 8, "origin": "/dev/mapper/hyper-img", "cow": "cow.img", "chunk_sectors": 8}))]
    #[case::thin_id_past_24_bits(json!({"op": "dm_thin", "name": "hyper-v1", "sectors": 8,
        "pool": "hyper-pool", "thin_id": 16_777_216}))]
    #[case::negative_sectors(json!({"op": "dm_linear", "name": "hyper-img", "readonly": true,
        "sectors": -8, "origin": "/srv/hyper/base.img"}))]
    #[case::readonly_thin_pool(json!({"op": "dm_thin_pool", "name": "hyper-pool", "readonly": true,
        "sectors": 8, "metadata": "/srv/hyper/meta", "data": "/srv/hyper/data",
        "block_sectors": 128, "low_water": 0}))]
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
        assert!(matches!(parse_request(args), Err(RequestError::Arity)));
    }

    #[rstest]
    #[case::trailing_garbage(r#"{"op":"version"} x"#)]
    #[case::two_requests(r#"{"op":"version"}{"op":"version"}"#)]
    #[case::duplicate_op(r#"{"op":"version","op":"sys_test"}"#)]
    #[case::duplicate_field(r#"{"op":"vm_grant_api","id":"v1","id":"v2"}"#)]
    #[case::empty("")]
    fn the_argument_must_be_exactly_one_json_object(#[case] raw: &str) {
        assert!(matches!(
            parse_request([OsString::from(raw)].into_iter()),
            Err(RequestError::Json(_))
        ));
    }

    #[test]
    fn non_utf8_is_refused() {
        let raw = OsString::from_vec(b"{\"op\":\"version\xff\"}".to_vec());
        assert!(matches!(
            parse_request([raw].into_iter()),
            Err(RequestError::Utf8)
        ));
    }
}
