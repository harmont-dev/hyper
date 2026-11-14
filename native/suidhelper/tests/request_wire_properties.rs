//! The node's JSON encoder (Jason) and this parser must read every request the same way, so
//! [`Request::from_args`] is held to JSON semantics and to exact numeric limits.
//!
//! Laws:
//! - JSON semantics, not bytes: any key order and any insignificant whitespace, at any depth,
//!   parses exactly when the canonical form does, and routes to the same op;
//! - every op name routes to its own variant, never to a sibling with the same fields (the two
//!   socket claims share `{id}`);
//! - a key repeated in any object, at any depth, is refused even when both values agree, so no
//!   two JSON parsers can disagree on which value wins;
//! - bounded integers are accepted exactly up to their documented maximum and refused past it;
//!   zero is refused exactly where a field is non-zero.

use hyper_suidhelper::cli::{Request, RequestError};
use proptest::prelude::*;
use rstest::rstest;
use serde_json::{json, Map, Value};
use std::ffi::OsString;
use test_strategy::proptest;

const OPS: &[&str] = &[
    "vm_launch",
    "vm_claim_api_socket",
    "vm_claim_vsock_socket",
    "vm_teardown",
    "vm_firewall",
    "img_activate",
    "dm_remove",
    "thin_pool_create",
    "thin_volume_create",
    "thin_destroy",
    "thin_fork_delta",
    "host_init",
    "version",
];

fn parse_raw(raw: &str) -> Result<Request, RequestError> {
    Request::from_args([OsString::from(raw)].into_iter())
}

fn parse(request: &Value) -> Result<Request, RequestError> {
    parse_raw(&request.to_string())
}

fn fixture() -> Vec<(String, Value)> {
    let fixture: Map<String, Value> =
        serde_json::from_str(include_str!("fixtures/requests.json")).unwrap();
    fixture.into_iter().collect()
}

fn request(which: usize) -> Value {
    let mut all = fixture();
    let len = all.len();
    all.swap_remove(which % len).1
}

fn routes_to(request: &Request, op: &str) -> bool {
    op == match request {
        Request::VmLaunch(_) => "vm_launch",
        Request::VmClaimApiSocket(_) => "vm_claim_api_socket",
        Request::VmClaimVsockSocket(_) => "vm_claim_vsock_socket",
        Request::VmTeardown(_) => "vm_teardown",
        Request::VmFirewall(_) => "vm_firewall",
        Request::ImgActivate(_) => "img_activate",
        Request::DmRemove(_) => "dm_remove",
        Request::ThinPoolCreate(_) => "thin_pool_create",
        Request::ThinVolumeCreate(_) => "thin_volume_create",
        Request::ThinDestroy(_) => "thin_destroy",
        Request::ThinForkDelta(_) => "thin_fork_delta",
        Request::HostInit(_) => "host_init",
        Request::Version(_) => "version",
    }
}

/// One generated seed drives every shuffle and spacing choice of a rendering.
struct Lcg(u64);

impl Lcg {
    fn next(&mut self) -> u64 {
        self.0 = self
            .0
            .wrapping_mul(6_364_136_223_846_793_005)
            .wrapping_add(1_442_695_040_888_963_407);
        self.0 >> 33
    }

    fn below(&mut self, n: usize) -> usize {
        (self.next() % n as u64) as usize
    }

    fn space(&mut self) -> &'static str {
        [" ", "\n", "\t", "\r\n", "", "  "][self.below(6)]
    }
}

fn render(value: &Value, rng: &mut Lcg) -> String {
    match value {
        Value::Object(map) => {
            let mut entries: Vec<(&String, &Value)> = map.iter().collect();
            for i in (1..entries.len()).rev() {
                entries.swap(i, rng.below(i + 1));
            }
            let body: Vec<String> = entries
                .into_iter()
                .map(|(k, v)| {
                    let key = Value::String(k.clone());
                    let (a, b, c) = (rng.space(), rng.space(), rng.space());
                    format!("{a}{key}{b}:{c}{}", render(v, rng))
                })
                .collect();
            format!("{{{}{}}}", body.join(","), rng.space())
        }
        Value::Array(items) => {
            let body: Vec<String> = items
                .iter()
                .map(|v| format!("{}{}", rng.space(), render(v, rng)))
                .collect();
            format!("[{}{}]", body.join(","), rng.space())
        }
        scalar => scalar.to_string(),
    }
}

fn object_paths(value: &Value, at: String, out: &mut Vec<String>) {
    match value {
        Value::Object(map) => {
            out.push(at.clone());
            for (k, v) in map {
                object_paths(v, format!("{at}/{k}"), out);
            }
        }
        Value::Array(items) => {
            for (i, v) in items.iter().enumerate() {
                object_paths(v, format!("{at}/{i}"), out);
            }
        }
        _ => {}
    }
}

/// `value` rendered with the first key of the object at `path` written twice, same value both.
fn with_duplicate_key(value: &Value, path: &str) -> Option<String> {
    const MARKER: &str = "__duplicate_marker__";
    let (key, repeated) = value.pointer(path)?.as_object()?.iter().next()?;
    let duplicate = format!("{}:{}", Value::String(key.clone()), repeated);
    let mut marked = value.clone();
    marked
        .pointer_mut(path)?
        .as_object_mut()?
        .insert(MARKER.into(), json!(0));
    Some(
        marked
            .to_string()
            .replacen(&format!("\"{MARKER}\":0"), &duplicate, 1),
    )
}

#[rstest]
fn every_op_routes_to_its_own_variant() {
    for (name, request) in fixture() {
        let parsed = parse(&request).unwrap_or_else(|e| panic!("{name}: {e}"));
        assert!(
            routes_to(&parsed, request["op"].as_str().unwrap()),
            "{name} routed to another op"
        );
    }
}

#[rstest]
fn the_fixture_names_every_op() {
    let mut named: Vec<String> = fixture()
        .into_iter()
        .map(|(_, r)| r["op"].as_str().unwrap().to_owned())
        .collect();
    named.sort();
    named.dedup();
    let mut ops = OPS.to_vec();
    ops.sort();
    assert_eq!(named, ops);
}

#[proptest]
fn key_order_and_whitespace_never_change_the_parse(which: usize, seed: u64) {
    let request = request(which);
    let raw = render(&request, &mut Lcg(seed));
    let parsed = parse_raw(&raw);
    prop_assert!(parsed.is_ok(), "{raw}: {:?}", parsed.err());
    prop_assert!(
        routes_to(&parsed.unwrap(), request["op"].as_str().unwrap()),
        "{raw}"
    );
}

#[proptest]
fn a_repeated_key_in_any_object_is_refused(which: usize, pick: usize) {
    let request = request(which);
    let mut paths = Vec::new();
    object_paths(&request, String::new(), &mut paths);
    let path = &paths[pick % paths.len()];
    prop_assume!(!request
        .pointer(path)
        .unwrap()
        .as_object()
        .unwrap()
        .is_empty());
    let raw = with_duplicate_key(&request, path).unwrap();
    prop_assert!(
        matches!(parse_raw(&raw), Err(RequestError::Json(_))),
        "accepted a repeated key at {path:?}: {raw}"
    );
}

fn launch_with(field: &str, value: Value) -> Value {
    let mut request = fixture()
        .into_iter()
        .find(|(name, _)| name == "vm_launch")
        .unwrap()
        .1;
    request[field] = value;
    request
}

fn volume_with_thin_id(id: Value) -> Value {
    json!({"op": "thin_volume_create", "pool": "hyper-pool", "thin_id": id,
        "name": "hyper-v1", "origin": "/dev/mapper/hyper-img"})
}

#[proptest]
fn a_net_id_is_accepted_exactly_below_the_transit_capacity(#[strategy(0u32..=70_000)] id: u32) {
    let accepted = parse(&launch_with("net_id", json!(id))).is_ok();
    prop_assert_eq!(accepted, id < 16_384, "net_id {}", id);
}

#[proptest]
fn a_thin_id_is_accepted_exactly_within_24_bits(
    #[strategy(prop_oneof![0u64..1 << 25, (1u64 << 24) - 4..(1 << 24) + 4, any::<u64>()])] id: u64,
) {
    let accepted = parse(&volume_with_thin_id(json!(id))).is_ok();
    prop_assert_eq!(accepted, id < 1 << 24, "thin_id {}", id);
}

#[rstest]
#[case::uid_max(launch_with("uid", json!(u32::MAX)), true)]
#[case::uid_past_u32(launch_with("uid", json!(u64::from(u32::MAX) + 1)), false)]
#[case::gid_zero_parses_and_is_left_to_the_range_check(launch_with("gid", json!(0)), true)]
#[case::thin_id_max(volume_with_thin_id(json!((1u64 << 24) - 1)), true)]
#[case::limits_empty(launch_with("limits", json!({})), true)]
#[case::limits_null_entries(launch_with("limits", json!({"memory_max": null, "cpu_max": null})), true)]
#[case::memory_max_u64(launch_with("limits", json!({"memory_max": u64::MAX})), true)]
#[case::memory_max_zero(launch_with("limits", json!({"memory_max": 0})), false)]
#[case::cpu_quota_zero(launch_with("limits", json!({"cpu_max": {"quota_us": 0, "period_us": 1}})), false)]
#[case::cpu_period_zero(launch_with("limits", json!({"cpu_max": {"quota_us": 1, "period_us": 0}})), false)]
#[case::cpu_max_missing_period(launch_with("limits", json!({"cpu_max": {"quota_us": 1}})), false)]
#[case::vm_id_64_chars(launch_with("id", json!("a".repeat(64))), true)]
#[case::vm_id_65_chars(launch_with("id", json!("a".repeat(65))), false)]
#[case::vm_id_inner_dash(launch_with("id", json!("v-1")), true)]
#[case::vm_id_non_ascii_digit(launch_with("id", json!("v\u{0661}")), false)]
#[case::device_traversing_mapper(launch_with("device", json!("/dev/mapper/../sda1")), false)]
fn bounded_fields_are_accepted_exactly_up_to_their_limit(
    #[case] request: Value,
    #[case] accepted: bool,
) {
    assert_eq!(
        parse(&request).is_ok(),
        accepted,
        "{request}: {:?}",
        parse(&request).err()
    );
}
