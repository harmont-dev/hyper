//! Laws of the guest side of `Exec` (`exec::run`), which the host's
//! `Hyper.exec/3` contract rests on:
//!
//! - argv round-trips: the program sees exactly the argument vector sent,
//!   with no shell splitting, globbing or re-quoting;
//! - stdout and stderr are each captured byte-for-byte, arbitrary bytes and
//!   outputs larger than a pipe buffer on both streams at once included;
//! - the exit status is the program's own `0..=255` code;
//! - a non-empty env *replaces* the environment: the program sees exactly
//!   that map and nothing inherited.

use hyper_guest_agent::exec::run;
use proptest::collection::{btree_map, vec};
use proptest::prelude::*;
use std::collections::BTreeMap;
use std::io::Write;

fn sh(script: &str, args: &[String]) -> Vec<String> {
    let mut argv = vec!["/bin/sh".into(), "-c".into(), script.into(), "sh".into()];
    argv.extend_from_slice(args);
    argv
}

fn arg() -> impl Strategy<Value = String> {
    any::<String>().prop_map(|s| s.replace('\0', ""))
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(64))]

    #[test]
    fn argv_reaches_the_program_unchanged(args in vec(arg(), 0..8)) {
        let (code, out, _) = run(&sh(r#"for a; do printf '%s\0' "$a"; done"#, &args), &BTreeMap::new(), None);
        prop_assert_eq!(code, 0);
        let expected: Vec<u8> = args.iter().flat_map(|a| a.bytes().chain([0])).collect();
        prop_assert_eq!(out, expected);
    }

    #[test]
    fn exit_status_is_the_programs_own(n in 0u8..=255) {
        let (code, _, _) = run(&sh(&format!("exit {n}"), &[]), &BTreeMap::new(), None);
        prop_assert_eq!(code, i32::from(n));
    }

    #[test]
    fn non_empty_env_is_exactly_what_the_program_sees(
        env in btree_map("[A-Z_][A-Z0-9_]{0,12}", "[ -~]{0,24}", 1..8)
    ) {
        let (code, out, _) = run(&["/usr/bin/env".into()], &env, None);
        prop_assert_eq!(code, 0);
        let seen: BTreeMap<String, String> = std::str::from_utf8(&out)
            .unwrap()
            .lines()
            .map(|l| {
                let (k, v) = l.split_once('=').unwrap();
                (k.to_owned(), v.to_owned())
            })
            .collect();
        prop_assert_eq!(seen, env);
    }
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(16))]

    #[test]
    fn both_streams_are_captured_byte_for_byte(
        stdout in vec(any::<u8>(), 0..300_000),
        stderr in vec(any::<u8>(), 0..300_000),
    ) {
        let dir = std::env::temp_dir();
        let tag = format!("{}-{}", std::process::id(), rand_tag());
        let out_path = dir.join(format!("ga-out-{tag}"));
        let err_path = dir.join(format!("ga-err-{tag}"));
        std::fs::File::create(&out_path).unwrap().write_all(&stdout).unwrap();
        std::fs::File::create(&err_path).unwrap().write_all(&stderr).unwrap();

        let args = [
            out_path.to_string_lossy().into_owned(),
            err_path.to_string_lossy().into_owned(),
        ];
        let (code, out, err) =
            run(&sh(r#"cat "$1" & cat "$2" >&2; wait"#, &args), &BTreeMap::new(), None);
        let _ = std::fs::remove_file(&out_path);
        let _ = std::fs::remove_file(&err_path);

        prop_assert_eq!(code, 0);
        prop_assert!(out == stdout, "stdout differs: {} vs {} bytes", out.len(), stdout.len());
        prop_assert!(err == stderr, "stderr differs: {} vs {} bytes", err.len(), stderr.len());
    }
}

fn rand_tag() -> u64 {
    use std::sync::atomic::{AtomicU64, Ordering};
    static NEXT: AtomicU64 = AtomicU64::new(0);
    NEXT.fetch_add(1, Ordering::Relaxed)
}
