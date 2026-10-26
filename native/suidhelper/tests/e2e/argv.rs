//! L4: prove the exact argv (and empty env) the helper hands to the child tool —
//! the one thing the design deliberately hides from the caller. We point the
//! tool's config path at a root-owned fake that writes its argv+env to a file as
//! JSON, then assert on the reconstructed command line.
#![cfg(feature = "insecure_test_seams")]

use predicates::str::contains;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

mod support;
use support::{is_root, run, stdout_json};

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
    run(
        &cfg,
        &[
            "dmsetup",
            "create",
            "hyper-vm1",
            "--readonly",
            "--table",
            "0   100  snapshot  /dev/loop0   /dev/loop1 P 8",
        ],
    )
    .success();

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

    run(&cfg, &["dmsetup", "remove", "--retry", "hyper-vm1"]).success();
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
    let bin = install_fake(
        tmp.path(),
        "dmsetup",
        &rec,
        "0 100 thin-pool 7:0 7:1 128 0 0",
    );
    let cfg = write_root_config(tmp.path(), &[("dmsetup", &bin)]);

    run(
        &cfg,
        &[
            "dmsetup",
            "message",
            "hyper-pool",
            "--message",
            "create_thin 7",
        ],
    )
    .success();
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

    let out = run(&cfg, &["dmsetup", "targets"]).success();
    assert_eq!(recorded_argv(&rec), vec!["targets"]);
    let json = stdout_json(&out);
    assert_eq!(json["result"], "targets");
    assert_eq!(json["output"], "snapshot v1.16.0\n");
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

    let out = run(&cfg, &["dmsetup", "ls"]).success();
    assert_eq!(recorded_argv(&rec), vec!["ls"]);
    let json = stdout_json(&out);
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

    let out = run(&cfg, &["losetup", "list"]).success();
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
    let json = stdout_json(&out);
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

    run(&cfg, &["dmsetup", "targets"])
        .failure()
        .stderr(contains("basename must be"));
}

struct LoopDevice(String);

impl LoopDevice {
    fn attach(backing: &Path) -> Self {
        let out = std::process::Command::new("losetup")
            .args(["--find", "--show"])
            .arg(backing)
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
        Self(String::from_utf8(out.stdout).unwrap().trim().to_string())
    }
}

impl Drop for LoopDevice {
    fn drop(&mut self) {
        let _ = std::process::Command::new("losetup")
            .args(["--detach", &self.0])
            .status();
    }
}

#[test]
fn blockdev_getsz_reports_a_loop_devices_size_as_root() {
    if !is_root() {
        eprintln!("SKIP blockdev: needs root");
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let backing = tmp.path().join("backing");
    fs::File::create(&backing)
        .unwrap()
        .set_len(3 * 1024 * 1024 + 512)
        .unwrap();
    let dev = LoopDevice::attach(&backing);
    let cfg = write_root_config(tmp.path(), &[]);

    let out = run(&cfg, &["blockdev", "--getsz", &dev.0]).success();
    let json = stdout_json(&out);
    assert_eq!(json["sectors"], 6145);
}
