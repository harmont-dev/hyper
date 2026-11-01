//! L5: the `chroot-jail` ops observed end to end through the binary (exit code +
//! stdout JSON), with the config-path seam pointing `work_dir` at a tempdir so we
//! never touch /etc/hyper or /srv. Root-gated: the helper acquires privileges for
//! mknod/chown, so these self-skip without root. The cgroup half is exercised
//! only with a MISSING leaf (idempotent, mutates nothing on the real host).
//!
//! The `dev/net/tun` node `prepare` creates when `[network]` is configured is
//! likewise privileged `mknod` — no unit-level substitute exists; it is proven
//! only here, root-gated, with the insecure config seam supplying a `[network]`
//! table.
#![cfg(feature = "insecure_mode")]

use std::fs;
use std::os::unix::fs::{FileTypeExt, MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::Command;

mod support;
use support::{is_root, run, stdout_json};

/// Write a root-owned (because this test runs as root) config whose work_dir is
/// `work_dir`, 0644 so the OwnerOnlyWritable axis passes.
fn write_config(dir: &Path, work_dir: &Path) -> PathBuf {
    let p = dir.join("config.toml");
    fs::write(&p, format!("work_dir = \"{}\"\n", work_dir.display())).unwrap();
    fs::set_permissions(&p, fs::Permissions::from_mode(0o644)).unwrap();
    p
}

/// Same as [`write_config`], plus a `[network]` table — the gate that makes
/// `chroot-jail prepare` also mknod `dev/net/tun` into the jail.
fn write_config_with_parent_cgroup(dir: &Path, work_dir: &Path, parent: &str) -> PathBuf {
    let p = dir.join("config.toml");
    fs::write(
        &p,
        format!(
            "work_dir = \"{}\"\n[jails]\ncgroup = \"{parent}\"\n",
            work_dir.display()
        ),
    )
    .unwrap();
    fs::set_permissions(&p, fs::Permissions::from_mode(0o644)).unwrap();
    p
}

fn write_config_with_network(dir: &Path, work_dir: &Path) -> PathBuf {
    let p = dir.join("config.toml");
    fs::write(
        &p,
        format!(
            "work_dir = \"{}\"\n[network]\nuplink = \"eth0\"\n",
            work_dir.display()
        ),
    )
    .unwrap();
    fs::set_permissions(&p, fs::Permissions::from_mode(0o644)).unwrap();
    p
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

struct MapperDev {
    loop_dev: PathBuf,
    name: String,
}

impl MapperDev {
    fn setup(tmp: &Path, test: &str) -> Option<Self> {
        let loop_dev = setup_loop(tmp)?;
        let name = format!("hyper-e2e-{test}-{}", std::process::id());
        let table = format!("0 2048 linear {} 0", loop_dev.display());
        let created = Command::new("dmsetup")
            .args(["create", &name, "--table", &table])
            .status()
            .is_ok_and(|status| status.success());
        if !created {
            teardown_loop(&loop_dev);
            return None;
        }
        Some(Self { loop_dev, name })
    }

    fn path(&self) -> String {
        format!("/dev/mapper/{}", self.name)
    }
}

impl Drop for MapperDev {
    fn drop(&mut self) {
        let _ = Command::new("dmsetup")
            .args(["remove", "--retry", &self.name])
            .output();
        teardown_loop(&self.loop_dev);
    }
}

// `chroot-jail prepare` stages the kernel and creates the rootfs node, exiting 0
// with {"result":"prepared"}.
#[test]
fn prepare_succeeds_and_builds_jail_as_root() {
    if !is_root() {
        eprintln!("SKIP prepare_succeeds_and_builds_jail: needs root");
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let work = tmp.path().join("srv");
    let chroot = work.join("jails").join("exec").join("id").join("root");
    fs::create_dir_all(&chroot).unwrap();
    let kernel = work.join("vmlinux-src");
    fs::write(&kernel, b"kernel image").unwrap();
    let cfg = write_config(tmp.path(), &work);

    let Some(dev) = MapperDev::setup(tmp.path(), "prepare") else {
        eprintln!("SKIP prepare: losetup/dmsetup unavailable");
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
            &dev.path(),
            "--uid",
            "900000",
            "--gid",
            "900000",
        ],
    );
    let dev_rdev = fs::metadata(dev.path()).map(|m| m.rdev());
    drop(dev);

    let json = stdout_json(&out.success());
    assert_eq!(json["result"], "prepared");
    assert_eq!(fs::read(chroot.join("vmlinux")).unwrap(), b"kernel image");
    assert_eq!(
        fs::metadata(chroot.join("rootfs")).unwrap().rdev(),
        dev_rdev.unwrap(),
    );
}

// `chroot-jail prepare` against a config with `[network]` set also mknods
// `dev/net/tun` into the jail: char device 10:200, mode 0666, owned uid:gid.
#[test]
fn prepare_creates_tun_node_when_networking_enabled_as_root() {
    if !is_root() {
        eprintln!("SKIP prepare_creates_tun_node_when_networking_enabled: needs root");
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let work = tmp.path().join("srv");
    let chroot = work.join("jails").join("exec").join("id").join("root");
    fs::create_dir_all(&chroot).unwrap();
    let kernel = work.join("vmlinux-src");
    fs::write(&kernel, b"kernel image").unwrap();
    let cfg = write_config_with_network(tmp.path(), &work);

    let Some(dev) = MapperDev::setup(tmp.path(), "tun") else {
        eprintln!("SKIP prepare_creates_tun_node: losetup/dmsetup unavailable");
        return;
    };

    let uid = 900_001;
    let gid = 900_002;
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
            &dev.path(),
            "--uid",
            &uid.to_string(),
            "--gid",
            &gid.to_string(),
        ],
    );
    drop(dev);
    out.success();

    let tun = chroot.join("dev").join("net").join("tun");
    let meta = fs::metadata(&tun).expect("dev/net/tun must exist");
    assert!(meta.file_type().is_char_device(), "must be a char device");
    assert_eq!(nix::sys::stat::major(meta.rdev()), 10);
    assert_eq!(nix::sys::stat::minor(meta.rdev()), 200);
    assert_eq!(meta.uid(), uid);
    assert_eq!(meta.gid(), gid);
    assert_eq!(meta.permissions().mode() & 0o777, 0o666);
}

#[test]
fn prepare_refuses_ids_outside_range_as_root() {
    if !is_root() {
        eprintln!("SKIP prepare_refuses_ids_outside_range: needs root");
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let work = tmp.path().join("srv");
    let chroot = work.join("jails").join("exec").join("id").join("root");
    fs::create_dir_all(&chroot).unwrap();
    let kernel = work.join("vmlinux-src");
    fs::write(&kernel, b"kernel image").unwrap();
    let cfg = write_config(tmp.path(), &work);

    for (uid, gid) in [
        ("0", "900000"),
        ("900000", "0"),
        ("1000", "900000"),
        ("900000", "1000000"),
    ] {
        run(
            &cfg,
            &[
                "chroot-jail",
                "prepare",
                "--chroot",
                chroot.to_str().unwrap(),
                "--kernel",
                kernel.to_str().unwrap(),
                "--device",
                "/dev/loop0",
                "--uid",
                uid,
                "--gid",
                gid,
            ],
        )
        .code(2)
        .stderr(predicates::str::contains("outside the configured range"));
        assert!(
            !chroot.join("vmlinux").exists(),
            "uid={uid} gid={gid}: nothing may be staged"
        );
    }
}

// `chroot-jail prepare` with a system device (not a loop / hyper-* dm) is
// rejected by BlockDev parsing at clap parse time — exit 2, nothing built. This
// case needs no root (clap rejects before the privilege boundary) but also no
// device, so it always runs.
#[test]
fn prepare_rejects_system_device_operand() {
    let tmp = tempfile::tempdir().unwrap();
    let cfg = write_config(tmp.path(), tmp.path());
    run(
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
            "900000",
            "--gid",
            "900000",
        ],
    )
    .failure();
}

// `chroot-jail remove` of a real chroot succeeds; the cgroup leaf is given as a
// missing path so removal is idempotent and touches nothing on the host.
#[test]
fn remove_succeeds_and_is_idempotent_as_root() {
    if !is_root() {
        eprintln!("SKIP remove_succeeds_and_is_idempotent: needs root");
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let work = tmp.path().join("srv");
    let chroot = work.join("jails").join("exec").join("id");
    fs::create_dir_all(chroot.join("inner")).unwrap();
    fs::write(chroot.join("vmlinux"), b"x").unwrap();
    let cfg = write_config_with_parent_cgroup(tmp.path(), &work, "hyper-e2e-does-not-exist");

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
    )
    .success();
    let json = stdout_json(&out);
    assert_eq!(json["result"], "removed");
    assert!(!chroot.exists(), "chroot must be gone");
}

#[test]
fn remove_refuses_cgroup_outside_parent_as_root() {
    if !is_root() {
        eprintln!("SKIP remove_refuses_cgroup_outside_parent: needs root");
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let work = tmp.path().join("srv");
    let chroot = work.join("jails").join("exec").join("id");
    fs::create_dir_all(&chroot).unwrap();
    let cfg = write_config_with_parent_cgroup(tmp.path(), &work, "hyper-e2e-does-not-exist");

    for cgroup in [
        "/sys/fs/cgroup/hyper-e2e-other/leaf",
        "/sys/fs/cgroup/hyper-e2e-does-not-exist",
        "/sys/fs/cgroup/hyper-e2e-does-not-exist/leaf/deeper",
        "/sys/fs/cgroup/hyper-e2e-does-not-exist/not.a.vm.id",
    ] {
        run(
            &cfg,
            &[
                "chroot-jail",
                "remove",
                "--chroot",
                chroot.to_str().unwrap(),
                "--cgroup",
                cgroup,
            ],
        )
        .code(2);
        assert!(
            chroot.exists(),
            "{cgroup}: chroot must survive a refused remove"
        );
    }
}
