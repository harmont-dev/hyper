use hyper_guest_agent::exec::{run, Request};

fn req(argv: &[&str]) -> Request {
    Request {
        argv: argv.iter().map(|s| s.to_string()).collect(),
        env: Default::default(),
        cwd: None,
        timeout_ms: None,
    }
}

#[test]
fn runs_a_command_and_captures_stdout_and_exit() {
    let r = run(&req(&["/bin/echo", "hi"]));
    assert_eq!(r.exit_code, 0);
    assert_eq!(r.stdout, b"hi\n");
    assert!(r.stderr.is_empty());
}

#[test]
fn missing_command_is_127_with_stderr() {
    let r = run(&req(&["/definitely/not/here"]));
    assert_eq!(r.exit_code, 127);
    assert!(r.stdout.is_empty());
    assert!(!r.stderr.is_empty());
}

#[test]
fn honors_cwd() {
    let mut rq = req(&["/bin/pwd"]);
    rq.cwd = Some("/tmp".into());
    let r = run(&rq);
    assert_eq!(r.exit_code, 0);
    assert_eq!(r.stdout, b"/tmp\n");
}
