use hyper_guest_agent::wire::{
    read_request, read_response, write_request, write_response, Request, Response,
};
use proptest::prelude::*;

proptest! {
    #[test]
    fn request_roundtrips(argv in prop::collection::vec(".*", 1..5),
                          cwd in prop::option::of(".*"),
                          timeout in prop::option::of(any::<u64>())) {
        let req = Request { argv, env: vec![("K".into(), "V".into())], cwd, timeout_ms: timeout };
        let mut buf = Vec::new();
        write_request(&mut buf, &req).unwrap();
        let got = read_request(&mut &buf[..]).unwrap();
        prop_assert_eq!(req.argv, got.argv);
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
