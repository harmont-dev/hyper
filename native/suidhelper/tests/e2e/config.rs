//! L5: the binary's startup config contract, observed end to end (exit code +
//! stderr + stdout JSON). Uses the config-path seam to point at a per-test
//! tempfile instead of /etc/hyper, so tests never touch the real host.
#![cfg(feature = "insecure_mode")]

use assert_fs::TempDir;
use hyper_suidhelper::config::{BinError, Config};
use hyperrs_process::binary;
use predicates::boolean::PredicateBooleanExt;
use predicates::str::contains;
use pretty_assertions::assert_eq;
use rstest::{fixture, rstest};
use std::assert_matches;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;

mod support;
use support::{is_root, run, stdout_json};

#[fixture]
fn tmp() -> TempDir {
    TempDir::new().unwrap()
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
#[rstest]
#[case::missing_config_falls_back_to_defaults(None)]
#[case::valid_config(Some("work_dir = \"/srv/hyper\"\n"))]
fn sys_test_ok_as_root(tmp: TempDir, #[case] body: Option<&str>) {
    if !is_root() {
        eprintln!("SKIP sys_test_ok: sys-test needs root");
        return;
    }
    let cfg = match body {
        Some(body) => write_root_config(tmp.path(), body),
        None => tmp.path().join("nope.toml"),
    };
    let out = run(&cfg, &["sys-test"]).success();
    let json = stdout_json(&out);
    assert_eq!(json["sys_test"], "ok");
    assert_eq!(json["hyper_base"], "/srv/hyper");
}

#[rstest]
fn non_root_owned_config_is_rejected(tmp: TempDir) {
    // A config file owned by a non-root user must be refused. If the test runs
    // as root, chown it away from root to exercise the owner check.
    let p = tmp.path().join("config.toml");
    fs::write(&p, "work_dir = \"/srv/hyper\"\n").unwrap();
    fs::set_permissions(&p, fs::Permissions::from_mode(0o644)).unwrap();
    if is_root() {
        // Drop ownership to uid/gid 65534 (nobody) so it is no longer root-owned.
        let nobody = nix::unistd::Uid::from_raw(65534);
        let nogrp = nix::unistd::Gid::from_raw(65534);
        nix::unistd::chown(&p, Some(nobody), Some(nogrp)).unwrap();
    }
    run(&p, &["sys-test"])
        .code(2)
        .stderr(contains("root:root").or(contains("not owned")));
}

#[rstest]
#[case::malformed("this is not = valid = toml ===", "not valid TOML")]
#[case::relative_work_dir("work_dir = \"relative/path\"\n", "path is not absolute")]
// min = 0 is the clearest violation: uid 0 is root, which the jailer must
// never receive because it skips its privilege drop when uid == 0.
#[case::bad_uid_gid_range(
    "work_dir = \"/srv/hyper\"\n[jails]\nuid_gid_range = [0, 100]\n",
    "uid_gid_range"
)]
fn invalid_config_exits_2_as_root(tmp: TempDir, #[case] body: &str, #[case] stderr: &str) {
    if !is_root() {
        eprintln!("SKIP invalid_config: needs root to own the config file");
        return;
    }
    let p = write_root_config(tmp.path(), body);
    run(&p, &["sys-test"]).code(2).stderr(contains(stderr));
}

// Config::default() has firecracker == None; the accessor must signal this
// distinctly so callers can report a missing-configuration error rather than
// a binary validation error.
#[rstest]
#[case::firecracker("firecracker", |c: &Config| c.firecracker().map(drop))]
#[case::jailer("jailer", |c: &Config| c.jailer().map(drop))]
fn tool_unconfigured_when_absent(
    #[case] tool: &str,
    #[case] accessor: fn(&Config) -> Result<(), BinError>,
) {
    let err = accessor(&Config::default()).expect_err("absent tool must return Unconfigured");
    assert_matches!(err, BinError::Unconfigured(name) if name == tool);
}

#[rstest]
fn jailer_basename_mismatch_rejected() {
    // The basename check in RootSafeBin::open precedes the stat, so we do not
    // need a real file — any absolute path with the wrong leaf name is enough.
    let body = "work_dir = \"/srv/hyper\"\n[tools]\njailer = \"/usr/local/bin/not-jailer\"\n";
    let config: Config = toml::from_str(body).unwrap();
    let err = config
        .jailer()
        .expect_err("wrong-basename jailer path must be rejected");
    assert_matches!(err, BinError::Bin(binary::RootSafeBinError::Name { .. }));
}

#[rstest]
fn firecracker_and_jailer_return_ok_when_root_owned_as_root(tmp: TempDir) {
    if !is_root() {
        eprintln!("SKIP firecracker_jailer_configured: needs root to create root-owned binaries");
        return;
    }
    let fc = tmp.path().join("firecracker");
    let jr = tmp.path().join("jailer");
    // 0o755: root-owned, not group/other-writable — satisfies RootSafeBin's checks.
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
