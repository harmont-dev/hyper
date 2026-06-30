//! L5: the binary's startup config contract, observed end to end (exit code +
//! stderr + stdout JSON). Uses the config-path seam to point at a per-test
//! tempfile instead of /etc/hyper, so tests never touch the real host.
#![cfg(feature = "insecure_test_seams")]

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process::{Command, Output};

const BIN: &str = env!("CARGO_BIN_EXE_hyper-suidhelper");

fn is_root() -> bool {
    nix::unistd::geteuid().is_root()
}

/// Run the helper with the gate open and the config path redirected.
fn run_with_config(config_path: &Path, args: &[&str]) -> Output {
    Command::new(BIN)
        .args(args)
        .env_clear()
        .env("HYPER_SETUIDHELPER_IS_INSECURE_MODE", "1")
        .env("HYPER_SETUIDHELPER_CONFIG_PATH", config_path)
        .output()
        .expect("spawn helper")
}

/// Write a config file owned root:root, 0644. Requires the test run as root.
fn write_root_config(dir: &Path, body: &str) -> std::path::PathBuf {
    let p = dir.join("config.toml");
    fs::write(&p, body).unwrap();
    fs::set_permissions(&p, fs::Permissions::from_mode(0o644)).unwrap();
    // Owned by root because the test process is root (checked by callers).
    p
}

/// A genuinely-absent config file is NOT an error: the helper falls back to the
/// built-in defaults (compiled into this root-owned binary, hence trusted). The
/// default `work_dir` is `/srv/hyper`. Needs root because `sys-test` then
/// acquires privileges to prove it can promote.
#[test]
fn missing_config_falls_back_to_defaults_as_root() {
    if !is_root() {
        eprintln!("SKIP missing_config defaults: sys-test needs root");
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let missing = tmp.path().join("nope.toml");
    let out = run_with_config(&missing, &["sys-test"]);
    assert_eq!(
        out.status.code(),
        Some(0),
        "absent config should use defaults; stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let json: serde_json::Value = serde_json::from_slice(&out.stdout).expect("stdout is JSON");
    assert_eq!(json["sys_test"], "ok");
    assert_eq!(json["hyper_base"], "/srv/hyper");
}

#[test]
fn non_root_owned_config_is_rejected() {
    // A config file owned by a non-root user must be refused. If the test runs
    // as root, chown it away from root to exercise the owner check.
    let tmp = tempfile::tempdir().unwrap();
    let p = tmp.path().join("config.toml");
    fs::write(&p, "work_dir = \"/srv/hyper\"\n").unwrap();
    fs::set_permissions(&p, fs::Permissions::from_mode(0o644)).unwrap();
    if is_root() {
        // Drop ownership to uid/gid 65534 (nobody) so it is no longer root-owned.
        let nobody = nix::unistd::Uid::from_raw(65534);
        let nogrp = nix::unistd::Gid::from_raw(65534);
        nix::unistd::chown(&p, Some(nobody), Some(nogrp)).unwrap();
    }
    let out = run_with_config(&p, &["sys-test"]);
    assert_eq!(out.status.code(), Some(2));
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(
        err.contains("root:root") || err.contains("not owned"),
        "expected an ownership rejection, stderr: {err}",
    );
}

#[test]
fn malformed_config_exits_2_malformed_as_root() {
    if !is_root() {
        eprintln!("SKIP malformed_config: needs root to own the config file");
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let p = write_root_config(tmp.path(), "this is not = valid = toml ===");
    let out = run_with_config(&p, &["sys-test"]);
    assert_eq!(out.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&out.stderr).contains("not valid TOML"));
}

#[test]
fn relative_work_dir_exits_2_relative_as_root() {
    if !is_root() {
        eprintln!("SKIP relative_work_dir: needs root to own the config file");
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let p = write_root_config(tmp.path(), "work_dir = \"relative/path\"\n");
    let out = run_with_config(&p, &["sys-test"]);
    assert_eq!(out.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&out.stderr).contains("must be an absolute path"));
}

#[test]
fn valid_config_and_setuid_yields_sys_test_ok_as_root() {
    if !is_root() {
        eprintln!("SKIP valid_config sys-test: needs root to acquire privileges");
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let p = write_root_config(tmp.path(), "work_dir = \"/srv/hyper\"\n");
    let out = run_with_config(&p, &["sys-test"]);
    assert_eq!(
        out.status.code(),
        Some(0),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let json: serde_json::Value = serde_json::from_slice(&out.stdout).expect("stdout is JSON");
    assert_eq!(json["sys_test"], "ok");
    assert_eq!(json["hyper_base"], "/srv/hyper");
}
