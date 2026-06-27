//! L5: the binary's startup config contract, observed end to end (exit code +
//! stderr + stdout JSON). Uses the config-path seam to point at a per-test
//! tempfile instead of /etc/hyper, so tests never touch the real host.
#![cfg(feature = "insecure_test_seams")]

use hyper_suidhelper::config::{BinError, Config};
use hyper_suidhelper::util::safe_bin;
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

#[test]
fn firecracker_unconfigured_when_absent() {
    // Config::default() has firecracker == None; the accessor must signal this
    // distinctly so callers can report a missing-configuration error rather than
    // a safe_bin validation error.
    let err = Config::default()
        .firecracker()
        .expect_err("absent firecracker must return Unconfigured");
    assert!(
        matches!(err, BinError::Unconfigured("firecracker")),
        "expected Unconfigured(\"firecracker\"), got {err:?}",
    );
}

#[test]
fn jailer_unconfigured_when_absent() {
    let err = Config::default()
        .jailer()
        .expect_err("absent jailer must return Unconfigured");
    assert!(
        matches!(err, BinError::Unconfigured("jailer")),
        "expected Unconfigured(\"jailer\"), got {err:?}",
    );
}

#[test]
fn jailer_basename_mismatch_rejected() {
    // The basename check in SafeBin::from_path precedes the stat, so we do not
    // need a real file — any absolute path with the wrong leaf name is enough.
    let body = "work_dir = \"/srv/hyper\"\n[tools]\njailer = \"/usr/local/bin/not-jailer\"\n";
    let config: Config = toml::from_str(body).unwrap();
    let err = config
        .jailer()
        .expect_err("wrong-basename jailer path must be rejected");
    assert!(
        matches!(err, BinError::Bin(safe_bin::Error::Name { .. })),
        "expected a Name error, got {err:?}",
    );
}

#[test]
fn firecracker_and_jailer_return_ok_when_root_owned_as_root() {
    if !is_root() {
        eprintln!("SKIP firecracker_jailer_configured: needs root to create root-owned binaries");
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let fc = tmp.path().join("firecracker");
    let jr = tmp.path().join("jailer");
    // 0o755: root-owned, not group/other-writable — satisfies SafeBin's checks.
    for p in [&fc, &jr] {
        fs::write(p, b"#!/bin/sh\n").unwrap();
        fs::set_permissions(p, fs::Permissions::from_mode(0o755)).unwrap();
    }
    let body = format!(
        "work_dir = \"/srv/hyper\"\n[tools]\nfirecracker = \"{}\"\njailer = \"{}\"\n",
        fc.display(),
        jr.display(),
    );
    let config: Config = toml::from_str(&body).unwrap();
    assert!(
        config.firecracker().is_ok(),
        "root-owned firecracker with correct basename must be accepted"
    );
    assert!(
        config.jailer().is_ok(),
        "root-owned jailer with correct basename must be accepted"
    );
}

#[test]
fn bad_uid_gid_range_exits_2_as_root() {
    if !is_root() {
        eprintln!("SKIP bad_uid_gid_range: needs root to own the config file");
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    // min = 0 is the clearest violation: uid 0 is root, which the jailer must
    // never receive because it skips its privilege drop when uid == 0.
    let p = write_root_config(
        tmp.path(),
        "work_dir = \"/srv/hyper\"\n[jails]\nuid_gid_range = [0, 100]\n",
    );
    let out = run_with_config(&p, &["sys-test"]);
    assert_eq!(out.status.code(), Some(2));
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(
        err.contains("uid_gid_range"),
        "expected a uid_gid_range error in stderr, got: {err}",
    );
}
