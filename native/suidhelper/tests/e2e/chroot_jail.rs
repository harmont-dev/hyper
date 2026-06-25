//! L5: the `chroot-jail` ops observed end to end through the binary (exit code +
//! stdout JSON), with the config-path seam pointing `work_dir` at a tempdir so we
//! never touch /etc/hyper or /srv. Root-gated: the helper acquires privileges for
//! mknod/chown, so these self-skip without root. The cgroup half is exercised
//! only with a MISSING leaf (idempotent, mutates nothing on the real host).
#![cfg(feature = "insecure_test_seams")]

use std::fs;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

const BIN: &str = env!("CARGO_BIN_EXE_hyper-suidhelper");

fn is_root() -> bool {
    nix::unistd::geteuid().is_root()
}

/// Write a root-owned (because this test runs as root) config whose work_dir is
/// `work_dir`, 0644 so the OnlyRootWritable axis passes.
fn write_config(dir: &Path, work_dir: &Path) -> PathBuf {
    let p = dir.join("config.toml");
    fs::write(&p, format!("work_dir = \"{}\"\n", work_dir.display())).unwrap();
    fs::set_permissions(&p, fs::Permissions::from_mode(0o644)).unwrap();
    p
}

fn run(config: &Path, args: &[&str]) -> Output {
    Command::new(BIN)
        .args(args)
        .env_clear()
        .env("HYPER_SETUIDHELPER_IS_INSECURE_MODE", "1")
        .env("HYPER_SETUIDHELPER_CONFIG_PATH", config)
        .output()
        .expect("spawn helper")
}

fn setup_loop(tmp: &Path) -> Option<PathBuf> {
    let backing = tmp.join("backing.img");
    let f = fs::File::create(&backing).ok()?;
    f.set_len(1024 * 1024).ok()?;
    let out = Command::new("losetup")
        .args(["--find", "--show"])
        .arg(&backing)
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let dev = String::from_utf8(out.stdout).ok()?.trim().to_string();
    if dev.is_empty() {
        None
    } else {
        Some(PathBuf::from(dev))
    }
}

fn teardown_loop(dev: &Path) {
    let _ = Command::new("losetup").arg("-d").arg(dev).output();
}

// `chroot-jail prepare` stages the kernel and creates the rootfs node, exiting 0
// with {"result":"prepared"}.
#[test]
fn prepare_succeeds_and_builds_jail() {
    if !is_root() {
        eprintln!("SKIP prepare_succeeds_and_builds_jail: needs root");
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let work = tmp.path().join("srv");
    let chroot = work.join("jails").join("exec").join("id");
    fs::create_dir_all(&chroot).unwrap();
    let kernel = work.join("vmlinux-src");
    fs::write(&kernel, b"kernel image").unwrap();
    let cfg = write_config(tmp.path(), &work);

    let Some(dev) = setup_loop(tmp.path()) else {
        eprintln!("SKIP prepare: losetup unavailable");
        return;
    };

    let out = run(
        &cfg,
        &[
            "chroot-jail",
            "prepare",
            "--chroot",
            chroot.to_str().unwrap(),
            "--kernel",
            kernel.to_str().unwrap(),
            "--device",
            dev.to_str().unwrap(),
            "--uid",
            "0",
            "--gid",
            "0",
        ],
    );
    let dev_rdev = fs::metadata(&dev).map(|m| m.rdev());
    teardown_loop(&dev);

    assert_eq!(
        out.status.code(),
        Some(0),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let json: serde_json::Value = serde_json::from_slice(&out.stdout).expect("stdout JSON");
    assert_eq!(json["result"], "prepared");
    assert_eq!(fs::read(chroot.join("vmlinux")).unwrap(), b"kernel image");
    assert_eq!(
        fs::metadata(chroot.join("rootfs")).unwrap().rdev(),
        dev_rdev.unwrap(),
    );
}

// `chroot-jail prepare` with a system device (not a loop / hyper-* dm) is
// rejected by BlockDev parsing at clap parse time — exit 2, nothing built. This
// case needs no root (clap rejects before the privilege boundary) but also no
// device, so it always runs.
#[test]
fn prepare_rejects_system_device_operand() {
    let tmp = tempfile::tempdir().unwrap();
    let cfg = write_config(tmp.path(), tmp.path());
    let out = run(
        &cfg,
        &[
            "chroot-jail",
            "prepare",
            "--chroot",
            "/srv/jails/exec/id",
            "--kernel",
            "/srv/vmlinux",
            "--device",
            "/dev/sda",
            "--uid",
            "0",
            "--gid",
            "0",
        ],
    );
    assert_ne!(out.status.code(), Some(0), "must reject /dev/sda");
}

// `chroot-jail remove` of a real chroot succeeds; the cgroup leaf is given as a
// missing path so removal is idempotent and touches nothing on the host.
#[test]
fn remove_succeeds_and_is_idempotent() {
    if !is_root() {
        eprintln!("SKIP remove_succeeds_and_is_idempotent: needs root");
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let work = tmp.path().join("srv");
    let chroot = work.join("jails").join("exec").join("id");
    fs::create_dir_all(chroot.join("inner")).unwrap();
    fs::write(chroot.join("vmlinux"), b"x").unwrap();
    let cfg = write_config(tmp.path(), &work);

    // A cgroup leaf that does not exist under the real /sys/fs/cgroup: removal of
    // a missing target is success, and nothing on the host is modified.
    let missing_cgroup = "/sys/fs/cgroup/hyper-e2e-does-not-exist/leaf";

    let out = run(
        &cfg,
        &[
            "chroot-jail",
            "remove",
            "--chroot",
            chroot.to_str().unwrap(),
            "--cgroup",
            missing_cgroup,
        ],
    );
    assert_eq!(
        out.status.code(),
        Some(0),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let json: serde_json::Value = serde_json::from_slice(&out.stdout).expect("stdout JSON");
    assert_eq!(json["result"], "removed");
    assert!(!chroot.exists(), "chroot must be gone");
}
