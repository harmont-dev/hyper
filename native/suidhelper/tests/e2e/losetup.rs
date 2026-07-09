//! L4 for `losetup attach`/`detach`: prove the helper hands the child a
//! validated `/proc/self/fd/N` handle (never the caller's path string), that
//! the handle names the caller's real inode, that the rw toggle and detach
//! argv render exactly, and that out-of-base or malformed operands are refused
//! BEFORE the tool binary ever runs.
#![cfg(feature = "insecure_test_seams")]

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

mod support;
use support::{is_root, run};

/// A root-owned fake `losetup` that records its argv (minus argv[0]) into
/// `record` as a JSON array, resolves its LAST argument with readlink into
/// `resolved` (proving an fd handle points at the real backing inode), and
/// prints `stdout_line` for the helper's parser. Absolute /usr/bin/readlink
/// because the helper spawns the child with a cleared environment (no PATH).
fn install_fake_losetup(dir: &Path, record: &Path, resolved: &Path, stdout_line: &str) -> PathBuf {
    let path = dir.join("losetup");
    let script = format!(
        r#"#!/bin/sh
printf '%s' "$(
  printf '['
  sep=''
  for a in "$@"; do printf '%s"%s"' "$sep" "$a"; sep=','; done
  printf ']'
)" > '{record}'
for a in "$@"; do last=$a; done
/usr/bin/readlink "$last" > '{resolved}' 2>/dev/null || true
printf '{stdout_line}\n'
"#,
        record = record.display(),
        resolved = resolved.display(),
    );
    fs::write(&path, script).unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
    path // root-owned because these tests run as root
}

/// A root-owned fake `losetup` that fails with a message, to prove the
/// helper's non-zero-exit arm surfaces the child's stderr.
fn install_failing_losetup(dir: &Path) -> PathBuf {
    let path = dir.join("losetup");
    fs::write(
        &path,
        r"#!/bin/sh
echo 'boom: no free loop device' >&2
exit 1
",
    )
    .unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
    path
}

/// Root-owned config: work_dir is the REAL (canonicalized) tempdir so a
/// backing file inside it passes confinement, and losetup points at the fake.
fn write_root_config(dir: &Path, work_dir: &Path, losetup_bin: &Path) -> PathBuf {
    let p = dir.join("config.toml");
    let body = format!(
        r#"work_dir = "{work_dir}"
[tools]
losetup = "{losetup}"
"#,
        work_dir = work_dir.display(),
        losetup = losetup_bin.display(),
    );
    fs::write(&p, body).unwrap();
    fs::set_permissions(&p, fs::Permissions::from_mode(0o644)).unwrap();
    p
}

fn recorded_argv(record: &Path) -> Vec<String> {
    let body = fs::read_to_string(record).expect("fake recorded argv");
    serde_json::from_str(&body).expect("argv json")
}

#[test]
fn losetup_attach_passes_validated_fd_readonly_as_root() {
    if !is_root() {
        eprintln!("SKIP losetup_attach ro: needs root");
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let base = fs::canonicalize(tmp.path()).unwrap();
    let rec = base.join("argv.json");
    let resolved = base.join("resolved.txt");
    let bin = install_fake_losetup(&base, &rec, &resolved, "/dev/loop9");
    let backing = base.join("disk.img");
    fs::write(&backing, b"data").unwrap();
    let cfg = write_root_config(&base, &base, &bin);

    let out = run(&cfg, &["losetup", "attach", backing.to_str().unwrap()]);
    assert_eq!(
        out.status.code(),
        Some(0),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );

    let argv = recorded_argv(&rec);
    assert_eq!(argv.len(), 4, "argv: {argv:?}");
    assert_eq!(&argv[..3], ["--find", "--show", "--read-only"]);
    assert!(
        argv[3].starts_with("/proc/self/fd/"),
        "backing operand must be an fd handle, got {}",
        argv[3],
    );
    // The child-visible fd names the validated inode — the caller's real file.
    assert_eq!(
        fs::read_to_string(&resolved).unwrap().trim(),
        backing.to_str().unwrap(),
    );

    let json: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(json["result"], "attached");
    assert_eq!(json["device"], "/dev/loop9");
}

#[test]
fn losetup_attach_rw_omits_read_only_as_root() {
    if !is_root() {
        eprintln!("SKIP losetup_attach rw: needs root");
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let base = fs::canonicalize(tmp.path()).unwrap();
    let rec = base.join("argv.json");
    let resolved = base.join("resolved.txt");
    let bin = install_fake_losetup(&base, &rec, &resolved, "/dev/loop9");
    let backing = base.join("disk.img");
    fs::write(&backing, b"data").unwrap();
    let cfg = write_root_config(&base, &base, &bin);

    let out = run(
        &cfg,
        &["losetup", "attach", "--rw", backing.to_str().unwrap()],
    );
    assert_eq!(
        out.status.code(),
        Some(0),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );

    let argv = recorded_argv(&rec);
    assert_eq!(
        argv.len(),
        3,
        "rw attach must not pass --read-only: {argv:?}"
    );
    assert_eq!(&argv[..2], ["--find", "--show"]);
    assert!(argv[2].starts_with("/proc/self/fd/"));
}

#[test]
fn losetup_attach_refuses_out_of_base_before_running_tool_as_root() {
    if !is_root() {
        eprintln!("SKIP losetup_attach refusal: needs root");
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let outside = tempfile::tempdir().unwrap();
    let base = fs::canonicalize(tmp.path()).unwrap();
    let rec = base.join("argv.json");
    let resolved = base.join("resolved.txt");
    let bin = install_fake_losetup(&base, &rec, &resolved, "/dev/loop9");
    let cfg = write_root_config(&base, &base, &bin);

    let escapee = outside.path().join("escape.img");
    fs::write(&escapee, b"x").unwrap();

    let out = run(&cfg, &["losetup", "attach", escapee.to_str().unwrap()]);
    assert_ne!(
        out.status.code(),
        Some(0),
        "out-of-base backing file accepted"
    );
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(err.contains("must be under"), "stderr: {err}");
    // Validation precedes execution: the tool must never have run.
    assert!(!rec.exists(), "fake losetup ran despite refused operand");
}

#[test]
fn losetup_detach_argv_and_parse_as_root() {
    if !is_root() {
        eprintln!("SKIP losetup_detach: needs root");
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let base = fs::canonicalize(tmp.path()).unwrap();
    let rec = base.join("argv.json");
    let resolved = base.join("resolved.txt");
    let bin = install_fake_losetup(&base, &rec, &resolved, "");
    let cfg = write_root_config(&base, &base, &bin);

    let out = run(&cfg, &["losetup", "detach", "/dev/loop7"]);
    assert_eq!(
        out.status.code(),
        Some(0),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert_eq!(recorded_argv(&rec), vec!["-d", "/dev/loop7"]);
    let json: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(json["result"], "detached");
}

#[test]
fn losetup_detach_refuses_non_loop_operands_as_root() {
    if !is_root() {
        eprintln!("SKIP losetup_detach refusal: needs root");
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let base = fs::canonicalize(tmp.path()).unwrap();
    let rec = base.join("argv.json");
    let resolved = base.join("resolved.txt");
    let bin = install_fake_losetup(&base, &rec, &resolved, "");
    let cfg = write_root_config(&base, &base, &bin);

    // System storage and a path trick through a loop-looking prefix: both
    // must be refused at parse time, before the tool binary runs.
    for bad in ["/dev/sda", "/dev/loop0/../sda", "/dev/loop", "/dev/loopX"] {
        let out = run(&cfg, &["losetup", "detach", bad]);
        assert_ne!(out.status.code(), Some(0), "detach accepted {bad}");
        assert!(!rec.exists(), "fake losetup ran for refused operand {bad}");
    }
}

#[test]
fn losetup_child_failure_surfaces_its_stderr_as_root() {
    if !is_root() {
        eprintln!("SKIP losetup failure arm: needs root");
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let base = fs::canonicalize(tmp.path()).unwrap();
    let bin = install_failing_losetup(&base);
    let backing = base.join("disk.img");
    fs::write(&backing, b"data").unwrap();
    let cfg = write_root_config(&base, &base, &bin);

    let out = run(&cfg, &["losetup", "attach", backing.to_str().unwrap()]);
    assert_ne!(out.status.code(), Some(0));
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(
        err.contains("losetup failed: boom: no free loop device"),
        "stderr: {err}",
    );
}
