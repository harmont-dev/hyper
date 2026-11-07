#![cfg(feature = "insecure_mode")]

use assert_fs::TempDir;
use predicates::str::contains;
use rstest::rstest;
use serde_json::{json, Value};

mod support;
use support::run;

#[rstest]
#[case::net_prepare(json!({"op": "net_prepare", "id": "v1"}))]
#[case::net_teardown(json!({"op": "net_teardown", "id": "v1"}))]
#[case::net_ip_host_init(json!({"op": "net_ip_host_init"}))]
#[case::net_ip_prepare(json!({"op": "net_ip_prepare", "id": "v1", "uid": 900_001}))]
#[case::net_ip_teardown(json!({"op": "net_ip_teardown", "id": "v1"}))]
fn every_net_op_refuses_as_unimplemented(#[case] request: Value) {
    let tmp = TempDir::new().unwrap();
    run(&tmp.path().join("absent.toml"), request)
        .code(2)
        .stdout("")
        .stderr(contains("unimplemented"));
}
