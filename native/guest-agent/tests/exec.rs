use hyper_guest_agent::exec::run;
use std::collections::BTreeMap;

#[test]
fn runs_and_captures() {
    let (code, out, err) = run(&["/bin/echo".into(), "hi".into()], &BTreeMap::new(), None);
    assert_eq!(code, 0);
    assert_eq!(out, b"hi\n");
    assert!(err.is_empty());
}

#[test]
fn missing_command_is_127() {
    let (code, out, err) = run(&["/definitely/not/here".into()], &BTreeMap::new(), None);
    assert_eq!(code, 127);
    assert!(out.is_empty());
    assert!(!err.is_empty());
}

#[test]
fn honors_cwd() {
    let (code, out, _) = run(&["/bin/pwd".into()], &BTreeMap::new(), Some("/tmp"));
    assert_eq!(code, 0);
    assert_eq!(out, b"/tmp\n");
}
