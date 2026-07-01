use hyper_guest_agent::wire::{
    read_request, read_response, write_request, write_response, Request, Response,
};
use proptest::prelude::*;

proptest! {
    #[test]
    fn request_roundtrips(argv in prop::collection::vec(".*", 1..5),
                          env in prop::collection::btree_map(".*", ".*", 0..4),
                          cwd in prop::option::of(".*"),
                          timeout in prop::option::of(any::<u64>())) {
        let req = Request { argv, env, cwd, timeout_ms: timeout };
        let mut buf = Vec::new();
        write_request(&mut buf, &req).unwrap();
        let got = read_request(&buf[..]).unwrap();
        prop_assert_eq!(req.argv, got.argv);
        prop_assert_eq!(req.env, got.env);
        prop_assert_eq!(req.cwd, got.cwd);
        prop_assert_eq!(req.timeout_ms, got.timeout_ms);
    }

    #[test]
    fn response_roundtrips(code in any::<i32>(),
                           out in prop::collection::vec(any::<u8>(), 0..256),
                           err in prop::collection::vec(any::<u8>(), 0..256)) {
        let resp = Response { exit_code: code, stdout: out, stderr: err };
        let mut buf = Vec::new();
        write_response(&mut buf, &resp).unwrap();
        let got = read_response(&buf[..]).unwrap();
        prop_assert_eq!(resp.exit_code, got.exit_code);
        prop_assert_eq!(resp.stdout, got.stdout);
        prop_assert_eq!(resp.stderr, got.stderr);
    }
}

/// Pins the cross-language response contract: the exact bytes produced here by
/// ciborium must decode identically on the Elixir side. The anchor is mirrored
/// in `test/hyper/node/fire_vmm/exec_test.exs` — both sides use the same hex.
///
/// `stdout` is `[0xff, 0x00, 0x68, 0x69]`, which is invalid UTF-8: a text-string
/// (major type 3) encoder would either corrupt or reject it, so this anchor
/// catches a regression where `serde_bytes` is removed from `stdout`/`stderr`
/// and ciborium falls back to emitting a CBOR array-of-integers instead of a
/// byte string (major type 2). hex: A369657869745F636F646503667374646F757444FF0068696673746465727240
#[test]
fn rust_encodes_response_anchor() {
    const ANCHOR: &[u8] = &[
        0xa3, 0x69, 0x65, 0x78, 0x69, 0x74, 0x5f, 0x63, 0x6f, 0x64, 0x65, 0x03, 0x66, 0x73, 0x74,
        0x64, 0x6f, 0x75, 0x74, 0x44, 0xff, 0x00, 0x68, 0x69, 0x66, 0x73, 0x74, 0x64, 0x65, 0x72,
        0x72, 0x40,
    ];
    let resp = Response {
        exit_code: 3,
        stdout: vec![0xff, 0x00, 0x68, 0x69],
        stderr: vec![],
    };
    let mut buf = Vec::new();
    write_response(&mut buf, &resp).unwrap();
    assert_eq!(buf.as_slice(), ANCHOR);
}

/// Pins the cross-language contract: the exact bytes produced by Elixir's
/// `CBOR.encode(%{"argv" => ["uname","-a"], "env" => %{"PATH" => "/bin"}})`
/// must deserialize into a valid `Request` on the Rust side, confirming that
/// Elixir text-string CBOR encoding is directly readable as Rust `String` /
/// `BTreeMap<String,String>` fields.
#[test]
fn elixir_anchor_decodes_as_cbor_request() {
    // hex: a264617267768265756e616d65622d6163656e76a16450415448642f62696e
    const ANCHOR: &[u8] = &[
        0xa2, 0x64, 0x61, 0x72, 0x67, 0x76, 0x82, 0x65, 0x75, 0x6e, 0x61, 0x6d, 0x65, 0x62, 0x2d,
        0x61, 0x63, 0x65, 0x6e, 0x76, 0xa1, 0x64, 0x50, 0x41, 0x54, 0x48, 0x64, 0x2f, 0x62, 0x69,
        0x6e,
    ];
    let req = read_request(ANCHOR).expect("must decode the Elixir-produced CBOR anchor");
    assert_eq!(req.argv, vec!["uname".to_string(), "-a".to_string()]);
    assert_eq!(req.env.get("PATH").map(String::as_str), Some("/bin"));
}
