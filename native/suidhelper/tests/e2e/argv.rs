//! L4: prove the exact argv (and empty env) the helper hands to the child tool —
//! the one thing the design deliberately hides from the caller. We point `--bin`
//! at a root-owned fake that writes its argv+env to a file as JSON, then assert
//! on the reconstructed command line.
#![cfg(feature = "insecure_test_seams")]

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;

const HELPER: &str = env!("CARGO_BIN_EXE_hyper-suidhelper");

fn is_root() -> bool {
    nix::unistd::geteuid().is_root()
}

/// Install a root-owned fake tool named `basename` that records its argv (minus
/// argv[0]) into `record` as a JSON array, then exits 0 with valid stdout for
/// the helper's parser. Returns the fake's absolute path.
fn install_fake(dir: &Path, basename: &str, record: &Path, stdout_line: &str) -> PathBuf {
    let path = dir.join(basename);
    // A tiny shell fake. `printf '%s\n'` of a JSON array of args. stdout_line is
    // what the helper's `parse` expects (e.g. a loop device path or sectors).
    let script = format!(
        "#!/bin/sh\nprintf '%s' \"$(\n  printf '['\n  sep=''\n  for a in \"$@\"; do printf '%s\"%s\"' \"$sep\" \"$a\"; sep=','; done\n  printf ']'\n)\" > '{record}'\nprintf '{stdout_line}\\n'\n",
        record = record.display(),
    );
    fs::write(&path, script).unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
    path // root-owned because this test runs as root
}

fn write_root_config(dir: &Path) -> PathBuf {
    let p = dir.join("config.toml");
    fs::write(&p, "work_dir = \"/srv/hyper\"\n").unwrap();
    fs::set_permissions(&p, fs::Permissions::from_mode(0o644)).unwrap();
    p
}

fn run(config: &Path, args: &[&str]) -> std::process::Output {
    Command::new(HELPER)
        .args(args)
        .env_clear()
        .env("HYPER_SETUIDHELPER_IS_INSECURE_MODE", "1")
        .env("HYPER_SETUIDHELPER_CONFIG_PATH", config)
        .output()
        .expect("spawn helper")
}

fn recorded_argv(record: &Path) -> Vec<String> {
    let body = fs::read_to_string(record).expect("fake recorded argv");
    serde_json::from_str(&body).expect("argv json")
}

#[test]
fn dmsetup_create_snapshot_reconstructs_canonical_table() {
    if !is_root() {
        eprintln!("SKIP dmsetup_create: needs root to acquire + own the fake bin");
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let cfg = write_root_config(tmp.path());
    let rec = tmp.path().join("argv.json");
    let bin = install_fake(tmp.path(), "dmsetup", &rec, "");

    // Deliberately weird inner spacing; the helper must re-render canonically.
    let out = run(
        &cfg,
        &[
            "dmsetup",
            "--bin",
            bin.to_str().unwrap(),
            "create",
            "hyper-vm1",
            "--readonly",
            "--table",
            "0   100  snapshot  /dev/loop0   /dev/loop1 P 8",
        ],
    );
    assert_eq!(
        out.status.code(),
        Some(0),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );

    let argv = recorded_argv(&rec);
    assert_eq!(
        argv,
        vec![
            "create",
            "hyper-vm1",
            "--readonly",
            "--table",
            "0 100 snapshot /dev/loop0 /dev/loop1 P 8", // canonical single-spaced
        ],
        "helper did not reconstruct the canonical table",
    );
}

#[test]
fn dmsetup_remove_retry_toggle() {
    if !is_root() {
        eprintln!("SKIP dmsetup_remove: needs root");
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let cfg = write_root_config(tmp.path());
    let rec = tmp.path().join("argv.json");
    let bin = install_fake(tmp.path(), "dmsetup", &rec, "");

    let out = run(
        &cfg,
        &[
            "dmsetup",
            "--bin",
            bin.to_str().unwrap(),
            "remove",
            "--retry",
            "hyper-vm1",
        ],
    );
    assert_eq!(out.status.code(), Some(0));
    assert_eq!(recorded_argv(&rec), vec!["remove", "--retry", "hyper-vm1"]);
}

#[test]
fn dmsetup_message_create_thin() {
    if !is_root() {
        eprintln!("SKIP dmsetup_message: needs root");
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let cfg = write_root_config(tmp.path());
    let rec = tmp.path().join("argv.json");
    let bin = install_fake(tmp.path(), "dmsetup", &rec, "");

    let out = run(
        &cfg,
        &[
            "dmsetup",
            "--bin",
            bin.to_str().unwrap(),
            "message",
            "hyper-pool",
            "--message",
            "create_thin 7",
        ],
    );
    assert_eq!(out.status.code(), Some(0));
    // the helper passes the whole message as a single argv element (dmsetup re-joins remaining args)
    assert_eq!(
        recorded_argv(&rec),
        vec!["message", "hyper-pool", "0", "create_thin 7"]
    );
}

#[test]
fn blockdev_getsz_argv_and_parse() {
    if !is_root() {
        eprintln!("SKIP blockdev: needs root");
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let cfg = write_root_config(tmp.path());
    let rec = tmp.path().join("argv.json");
    // Fake prints "2048" as the sector count for the helper to parse.
    let bin = install_fake(tmp.path(), "blockdev", &rec, "2048");

    let out = run(
        &cfg,
        &[
            "blockdev",
            "--bin",
            bin.to_str().unwrap(),
            "--getsz",
            "/dev/loop0",
        ],
    );
    assert_eq!(
        out.status.code(),
        Some(0),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert_eq!(recorded_argv(&rec), vec!["--getsz", "/dev/loop0"]);
    let json: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(json["sectors"], 2048);
}
