//! Hostile-request refusal laws for the helper's single JSON argument, the one input every
//! local caller controls before the privilege gate runs. Every valid request in
//! `fixtures/requests.json` is mutated at every leaf and every nested object; each law says the
//! mutated request is always refused as `RequestError::Json`, never accepted and never a crash:
//!
//! - nesting deeper than the parser's recursion limit, at the top level or in any field;
//! - any top-level value that is not an object;
//! - an `op` that is not byte-for-byte a known op (case, whitespace, separators, homoglyphs);
//! - a string field carrying NUL, ASCII whitespace, a traversal or a leading `-`, which would
//!   split a dmsetup table or argv, escape a confined path, or read as a flag;
//! - an integer field given as a negative, a fraction, a string, a bool, a list or an exponent;
//! - a bool field given as anything but a JSON bool;
//! - an unknown key in any nested object, not just the top level, so a misspelled limit or
//!   firewall key can never be silently dropped.

use hyper_suidhelper::cli::{Request, RequestError};
use proptest::prelude::*;
use rstest::rstest;
use serde_json::{json, Value};
use std::ffi::OsString;
use test_strategy::proptest;

const PARSER_DEPTH_LIMIT: usize = 128;
const MAX_ARG_STRLEN: usize = 128 * 1024;
const PLACEHOLDER: &str = "__hostile_placeholder__";

fn parse_raw(raw: &str) -> Result<Request, RequestError> {
    Request::from_args([OsString::from(raw)].into_iter())
}

fn parse(request: &Value) -> Result<Request, RequestError> {
    parse_raw(&request.to_string())
}

fn refused(raw: &str) -> bool {
    matches!(parse_raw(raw), Err(RequestError::Json(_)))
}

fn valid_requests() -> Vec<Value> {
    let fixture: serde_json::Map<String, Value> =
        serde_json::from_str(include_str!("fixtures/requests.json")).unwrap();
    fixture.into_iter().map(|(_, request)| request).collect()
}

fn pointers(value: &Value, at: String, out: &mut Vec<(String, Value)>) {
    out.push((at.clone(), value.clone()));
    match value {
        Value::Object(map) => {
            for (key, child) in map {
                pointers(child, format!("{at}/{key}"), out);
            }
        }
        Value::Array(items) => {
            for (idx, child) in items.iter().enumerate() {
                pointers(child, format!("{at}/{idx}"), out);
            }
        }
        _ => {}
    }
}

fn every_node() -> Vec<(Value, String, Value)> {
    valid_requests()
        .into_iter()
        .flat_map(|request| {
            let mut nodes = Vec::new();
            pointers(&request, String::new(), &mut nodes);
            nodes
                .into_iter()
                .filter(|(at, _)| !at.is_empty())
                .map(move |(at, node)| (request.clone(), at, node))
        })
        .collect()
}

fn replaced(request: &Value, at: &str, with: Value) -> Value {
    let mut request = request.clone();
    *request.pointer_mut(at).unwrap() = with;
    request
}

fn op_node(at: &str) -> bool {
    at == "/op"
}

#[test]
fn every_fixture_request_is_accepted_unmutated() {
    for request in valid_requests() {
        assert!(parse(&request).is_ok(), "{request}");
    }
}

#[rstest]
#[case::arrays("[", "]")]
#[case::objects("{\"k\":", "}")]
#[case::unclosed_arrays("[", "")]
fn nesting_past_the_parser_limit_is_refused_in_every_field(
    #[case] open: &str,
    #[case] close: &str,
    #[values(PARSER_DEPTH_LIMIT + 1, 4_096, MAX_ARG_STRLEN / 8)] depth: usize,
) {
    let deep = format!("{}0{}", open.repeat(depth), close.repeat(depth));
    let top_level = deep.clone();
    assert!(refused(&top_level), "top-level nesting depth {depth}");
    for (request, at, _) in every_node() {
        if op_node(&at) {
            continue;
        }
        let marked = replaced(&request, &at, json!(PLACEHOLDER)).to_string();
        let raw = marked.replace(&format!("\"{PLACEHOLDER}\""), &deep);
        assert!(refused(&raw), "depth {depth} at {at} of {request}");
    }
}

fn non_object() -> impl Strategy<Value = Value> {
    let leaf = prop_oneof![
        Just(Value::Null),
        any::<bool>().prop_map(Value::from),
        any::<i64>().prop_map(Value::from),
        any::<f64>()
            .prop_filter("finite", |f| f.is_finite())
            .prop_map(Value::from),
        ".{0,16}".prop_map(Value::from),
    ];
    let nested = leaf.clone().prop_recursive(3, 16, 4, |inner| {
        prop_oneof![
            prop::collection::vec(inner.clone(), 0..4).prop_map(Value::Array),
            prop::collection::btree_map("op|id|[a-z]{1,4}", inner, 0..3)
                .prop_map(|map| Value::Array(vec![Value::Object(map.into_iter().collect())])),
        ]
    });
    prop_oneof![leaf, nested]
}

#[proptest]
fn a_top_level_value_that_is_not_an_object_is_refused(#[strategy(non_object())] request: Value) {
    prop_assert!(refused(&request.to_string()), "{request}");
}

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

fn near_miss(op: &str, how: usize) -> String {
    match how {
        0 => op.to_uppercase(),
        1 => format!(" {op}"),
        2 => format!("{op}\n"),
        3 => op.replace('_', "-"),
        4 => op.replacen('o', "\u{43e}", 1),
        5 => format!("{op}\0"),
        6 => op.replace('_', ""),
        _ => {
            let mut chars: Vec<char> = op.chars().collect();
            chars[0] = chars[0].to_ascii_uppercase();
            chars.into_iter().collect()
        }
    }
}

#[proptest]
fn an_op_that_is_not_exactly_a_known_op_is_refused(
    #[strategy(0..OPS.len())] which: usize,
    #[strategy(0usize..8)] how: usize,
) {
    let canonical = valid_requests()
        .into_iter()
        .find(|request| request["op"] == OPS[which])
        .unwrap();
    let op = near_miss(OPS[which], how);
    prop_assume!(op != OPS[which]);
    let request = replaced(&canonical, "/op", json!(op));
    prop_assert!(refused(&request.to_string()), "{request}");
}

#[proptest]
fn an_arbitrary_op_name_is_refused(#[strategy("[ -~]{0,24}")] op: String) {
    prop_assume!(!OPS.contains(&op.as_str()));
    let request = json!({ "op": op });
    prop_assert!(refused(&request.to_string()), "{request}");
}

const SPLITTING_BYTES: &[&str] = &["\0", " ", "\t", "\n", "\r", "\u{b}", "\u{c}"];

fn spliced(original: &str, fragment: &str, cut: usize) -> String {
    format!("{}{fragment}{}", &original[..cut], &original[cut..])
}

fn char_boundaries(s: &str) -> impl Iterator<Item = usize> + '_ {
    s.char_indices().map(|(idx, _)| idx).chain([s.len()])
}

fn traversals(original: &str) -> Vec<String> {
    let after_separators = original
        .match_indices('/')
        .map(|(idx, _)| spliced(original, "../", idx + 1));
    after_separators
        .chain([
            format!("{original}/.."),
            format!("../{original}"),
            "..".to_owned(),
        ])
        .collect()
}

#[test]
fn a_splitting_byte_anywhere_in_any_string_field_is_refused() {
    for (request, at, node) in every_node() {
        let Value::String(original) = node else {
            continue;
        };
        for fragment in SPLITTING_BYTES {
            for cut in char_boundaries(&original) {
                let hostile = spliced(&original, fragment, cut);
                let mutated = replaced(&request, &at, json!(hostile));
                assert!(
                    refused(&mutated.to_string()),
                    "accepted {hostile:?} at {at}: {mutated}"
                );
            }
        }
    }
}

#[test]
fn a_traversal_component_in_any_string_field_is_refused() {
    for (request, at, node) in every_node() {
        let Value::String(original) = node else {
            continue;
        };
        for hostile in traversals(&original) {
            let mutated = replaced(&request, &at, json!(hostile));
            assert!(
                refused(&mutated.to_string()),
                "accepted {hostile:?} at {at}: {mutated}"
            );
        }
    }
}

#[test]
fn a_leading_dash_on_any_string_field_is_refused() {
    for (request, at, node) in every_node() {
        let Value::String(original) = node else {
            continue;
        };
        for hostile in [
            format!("-{original}"),
            format!("--{original}"),
            "-".to_owned(),
        ] {
            let mutated = replaced(&request, &at, json!(hostile));
            assert!(
                refused(&mutated.to_string()),
                "accepted {hostile:?} at {at}"
            );
        }
    }
}

#[test]
fn an_integer_field_in_any_other_json_shape_is_refused() {
    let shapes = ["-1", "1.5", "\"1\"", "true", "1e3", "[1]", "{}"];
    for (request, at, node) in every_node() {
        if !node.is_u64() {
            continue;
        }
        for shape in shapes {
            let marked = replaced(&request, &at, json!(PLACEHOLDER)).to_string();
            let raw = marked.replace(&format!("\"{PLACEHOLDER}\""), shape);
            assert!(refused(&raw), "accepted {shape} at {at}: {raw}");
        }
    }
}

#[test]
fn a_bool_field_in_any_other_json_shape_is_refused() {
    for (request, at, node) in every_node() {
        if !node.is_boolean() {
            continue;
        }
        for shape in [
            json!("true"),
            json!(1),
            json!(0),
            Value::Null,
            json!([true]),
        ] {
            let mutated = replaced(&request, &at, shape.clone());
            assert!(refused(&mutated.to_string()), "accepted {shape} at {at}");
        }
    }
}

#[test]
fn a_nested_object_or_list_in_the_wrong_shape_is_refused() {
    for (request, at, node) in every_node() {
        let wrong: &[Value] = match node {
            Value::Object(_) => &[json!([]), json!("x"), json!(1)],
            Value::Array(_) => &[json!({}), json!("x"), json!(1), Value::Null],
            _ => continue,
        };
        for shape in wrong {
            let mutated = replaced(&request, &at, shape.clone());
            assert!(
                refused(&mutated.to_string()),
                "accepted {shape} at {at}: {mutated}"
            );
        }
    }
}

#[proptest]
fn an_unknown_key_in_any_nested_object_is_refused(
    #[strategy("[a-z_]{1,12}")] key: String,
    #[strategy(any::<prop::sample::Index>())] which: prop::sample::Index,
) {
    let objects: Vec<(Value, String, Value)> = every_node()
        .into_iter()
        .filter(|(_, _, node)| node.is_object())
        .collect();
    prop_assume!(!objects.is_empty());
    let (request, at, node) = which.get(&objects).clone();
    prop_assume!(!node.as_object().unwrap().contains_key(&key));
    let mut mutated = request.clone();
    mutated.pointer_mut(&at).unwrap()[&key] = json!(1);
    prop_assert!(
        refused(&mutated.to_string()),
        "accepted {key} at {at}: {mutated}"
    );
}

#[test]
fn every_nested_object_is_mutated_by_the_unknown_key_law() {
    let nested: Vec<String> = every_node()
        .into_iter()
        .filter(|(_, _, node)| node.is_object())
        .map(|(_, at, _)| at)
        .collect();
    for expected in [
        "/limits",
        "/limits/cpu_max",
        "/firewall",
        "/firewall/inbound/0",
    ] {
        assert!(
            nested.iter().any(|at| at == expected),
            "{expected} not covered: {nested:?}"
        );
    }
}

#[test]
fn a_misspelled_nested_key_never_silently_drops_a_limit() {
    let launch = valid_requests()
        .into_iter()
        .find(|request| request["op"] == "vm_launch")
        .unwrap();
    for (at, typo) in [
        ("/limits", json!({"memroy_max": 1})),
        (
            "/limits",
            json!({"memory_max": 1, "cpu": {"quota_us": 1, "period_us": 1}}),
        ),
        ("/limits/cpu_max", json!({"quota_us": 1, "period": 1})),
        ("/firewall", json!({"inbound": [], "outbound_block": []})),
        (
            "/firewall/inbound/0",
            json!({"protocol": "tcp", "port": [22, 22]}),
        ),
    ] {
        let mutated = replaced(&launch, at, typo.clone());
        assert!(refused(&mutated.to_string()), "accepted {typo} at {at}");
    }
}
