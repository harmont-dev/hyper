//! L4: prove the exact argv (and empty env) the helper hands to the child tool —
//! the one thing the design deliberately hides from the caller. We point the
//! tool's config path at a root-owned fake that writes its argv+env to a file as
//! JSON, then assert on the reconstructed command line.
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

/// Write a root-owned config that points the named tools at the given (fake)
/// binaries, so the helper resolves each tool's path from config rather than a
/// caller argument.
fn write_root_config(dir: &Path, bins: &[(&str, &Path)]) -> PathBuf {
    let p = dir.join("config.toml");
    // Every key here is a tool name, so they live under the `[tools]` table.
    let mut body = String::from("work_dir = \"/srv/hyper\"\n[tools]\n");
    for (key, path) in bins {
        body.push_str(&format!("{key} = \"{}\"\n", path.display()));
    }
    fs::write(&p, body).unwrap();
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
fn dmsetup_create_snapshot_reconstructs_canonical_table_as_root() {
    if !is_root() {
        eprintln!("SKIP dmsetup_create: needs root to acquire + own the fake bin");
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let rec = tmp.path().join("argv.json");
    let bin = install_fake(tmp.path(), "dmsetup", &rec, "");
    let cfg = write_root_config(tmp.path(), &[("dmsetup", &bin)]);

    // Deliberately weird inner spacing; the helper must re-render canonically.
    let out = run(
        &cfg,
        &[
            "dmsetup",
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
fn dmsetup_remove_retry_toggle_as_root() {
    if !is_root() {
        eprintln!("SKIP dmsetup_remove: needs root");
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let rec = tmp.path().join("argv.json");
    let bin = install_fake(tmp.path(), "dmsetup", &rec, "");
    let cfg = write_root_config(tmp.path(), &[("dmsetup", &bin)]);

    let out = run(&cfg, &["dmsetup", "remove", "--retry", "hyper-vm1"]);
    assert_eq!(out.status.code(), Some(0));
    assert_eq!(recorded_argv(&rec), vec!["remove", "--retry", "hyper-vm1"]);
}

#[test]
fn dmsetup_message_create_thin_as_root() {
    if !is_root() {
        eprintln!("SKIP dmsetup_message: needs root");
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let rec = tmp.path().join("argv.json");
    let bin = install_fake(tmp.path(), "dmsetup", &rec, "");
    let cfg = write_root_config(tmp.path(), &[("dmsetup", &bin)]);

    let out = run(
        &cfg,
        &[
            "dmsetup",
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
fn dmsetup_targets_argv_and_parse_as_root() {
    if !is_root() {
        eprintln!("SKIP dmsetup_targets: needs root");
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let rec = tmp.path().join("argv.json");
    // Fake prints one `dmsetup targets` row; the helper returns it verbatim.
    let bin = install_fake(tmp.path(), "dmsetup", &rec, "snapshot         v1.16.0");
    let cfg = write_root_config(tmp.path(), &[("dmsetup", &bin)]);

    let out = run(&cfg, &["dmsetup", "targets"]);
    assert_eq!(
        out.status.code(),
        Some(0),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert_eq!(recorded_argv(&rec), vec!["targets"]);
    let json: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(json["result"], "targets");
    assert_eq!(json["output"], "snapshot         v1.16.0\n");
}

#[test]
fn dmsetup_ls_argv_and_parse_as_root() {
    if !is_root() {
        eprintln!("SKIP dmsetup_ls: needs root");
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let rec = tmp.path().join("argv.json");
    let bin = install_fake(tmp.path(), "dmsetup", &rec, "hyper-thinpool\\nhyper-rw-abc");
    let cfg = write_root_config(tmp.path(), &[("dmsetup", &bin)]);

    let out = run(&cfg, &["dmsetup", "ls"]);
    assert_eq!(
        out.status.code(),
        Some(0),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert_eq!(recorded_argv(&rec), vec!["ls"]);
    let json: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(json["result"], "listed");
    assert_eq!(json["output"], "hyper-thinpool\nhyper-rw-abc\n");
}

#[test]
fn losetup_list_argv_and_parse_as_root() {
    if !is_root() {
        eprintln!("SKIP losetup_list: needs root");
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let rec = tmp.path().join("argv.json");
    let bin = install_fake(
        tmp.path(),
        "losetup",
        &rec,
        "/dev/loop0 /srv/hyper/scratch/thinpool.meta",
    );
    let cfg = write_root_config(tmp.path(), &[("losetup", &bin)]);

    let out = run(&cfg, &["losetup", "list"]);
    assert_eq!(
        out.status.code(),
        Some(0),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert_eq!(
        recorded_argv(&rec),
        vec![
            "--list",
            "--noheadings",
            "--raw",
            "--output",
            "NAME,BACK-FILE"
        ]
    );
    let json: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(json["result"], "listed");
    assert_eq!(
        json["output"],
        "/dev/loop0 /srv/hyper/scratch/thinpool.meta\n"
    );
}

#[test]
fn dmsetup_rejects_configured_bin_with_wrong_basename_as_root() {
    if !is_root() {
        eprintln!("SKIP dmsetup_rejects_bin: needs root to own the config file");
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    // A real, root-owned system file, but the wrong basename for `dmsetup`.
    let cfg = write_root_config(tmp.path(), &[("dmsetup", Path::new("/usr/bin/env"))]);

    let out = run(&cfg, &["dmsetup", "targets"]);
    assert_ne!(
        out.status.code(),
        Some(0),
        "a configured binary with the wrong basename must be refused"
    );
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(err.contains("basename must be"), "stderr: {err}");
}

#[test]
fn blockdev_getsz_argv_and_parse_as_root() {
    if !is_root() {
        eprintln!("SKIP blockdev: needs root");
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let rec = tmp.path().join("argv.json");
    // Fake prints "2048" as the sector count for the helper to parse.
    let bin = install_fake(tmp.path(), "blockdev", &rec, "2048");
    let cfg = write_root_config(tmp.path(), &[("blockdev", &bin)]);

    let out = run(&cfg, &["blockdev", "--getsz", "/dev/loop0"]);
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
