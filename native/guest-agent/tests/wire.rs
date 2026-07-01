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
        let got = read_request(&mut &buf[..]).unwrap();
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
        let got = read_response(&mut &buf[..]).unwrap();
        prop_assert_eq!(resp.exit_code, got.exit_code);
        prop_assert_eq!(resp.stdout, got.stdout);
        prop_assert_eq!(resp.stderr, got.stderr);
    }
}

/// Pins the cross-language contract: the Elixir client sends `env` as a JSON
/// object (`{"K":"V"}`), not an array of pairs. This byte sequence is exactly
/// what `Hyper.Node.FireVMM.Exec` produces — a big-endian u32 length prefix
/// followed by the JSON payload. With `Vec<(String,String)>` serde would
/// reject this with "invalid type: map, expected a sequence".
#[test]
fn elixir_client_env_object_is_decoded() {
    let json = br#"{"argv":["x"],"env":{"K":"V"}}"#;
    let len = (json.len() as u32).to_be_bytes();
    let mut frame = Vec::new();
    frame.extend_from_slice(&len);
    frame.extend_from_slice(json);

    let req = read_request(&mut &frame[..]).expect("must decode the Elixir client payload");
    assert_eq!(req.argv, vec!["x".to_string()]);
    assert_eq!(req.env.get("K").map(String::as_str), Some("V"));
}
