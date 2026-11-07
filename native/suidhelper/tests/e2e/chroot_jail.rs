//! L5: the `vm` jail ops observed end to end through the binary (exit code +
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

use assert_fs::prelude::*;
use assert_fs::TempDir;
use pretty_assertions::assert_eq;
use rstest::{fixture, rstest};
use serde_json::json;
use std::fs;
use std::os::unix::fs::{FileTypeExt, MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::Command;

mod support;
use support::{is_root, run, stdout_json};

/// Write a root-owned (because this test runs as root) config whose work_dir is
/// `work_dir`, followed by `tables`, 0644 so the OwnerOnlyWritable axis passes.
fn write_config(dir: &Path, work_dir: &Path, tables: &str) -> PathBuf {
    let p = dir.join("config.toml");
    fs::write(
        &p,
        format!("work_dir = \"{}\"\n{tables}", work_dir.display()),
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

struct Work {
    tmp: TempDir,
    dir: PathBuf,
    chroot: PathBuf,
    kernel: PathBuf,
}

impl Work {
    fn config(&self, tables: &str) -> PathBuf {
        write_config(self.tmp.path(), &self.dir, tables)
    }

    fn prepare(&self, cfg: &Path, device: &str, uid: u32, gid: u32) -> assert_cmd::assert::Assert {
        run(
            cfg,
            json!({
                "op": "vm_stage",
                "id": "id",
                "kernel": self.kernel,
                "device": device,
                "uid": uid,
                "gid": gid,
            }),
        )
    }
}

#[fixture]
fn work() -> Work {
    let tmp = TempDir::new().unwrap();
    let chroot = tmp.child("srv/jails/firecracker/id/root");
    chroot.create_dir_all().unwrap();
    let kernel = tmp.child("srv/vmlinux-src");
    kernel.write_binary(b"kernel image").unwrap();
    Work {
        dir: tmp.child("srv").to_path_buf(),
        chroot: chroot.to_path_buf(),
        kernel: kernel.to_path_buf(),
        tmp,
    }
}

// `vm stage` stages the kernel and creates the rootfs node, exiting 0
// with {"result":"staged"}.
#[rstest]
fn prepare_succeeds_and_builds_jail_as_root(work: Work) {
    if !is_root() {
        eprintln!("SKIP prepare_succeeds_and_builds_jail: needs root");
        return;
    }
    let cfg = work.config("");

    let Some(dev) = MapperDev::setup(work.tmp.path(), "prepare") else {
        eprintln!("SKIP prepare: losetup/dmsetup unavailable");
        return;
    };

    let out = work.prepare(&cfg, &dev.path(), 900_000, 900_000);
    let dev_rdev = fs::metadata(dev.path()).map(|m| m.rdev());
    drop(dev);

    let json = stdout_json(&out.success());
    assert_eq!(json["result"], "staged");
    assert_eq!(
        fs::read(work.chroot.join("vmlinux")).unwrap(),
        b"kernel image"
    );
    assert_eq!(
        fs::metadata(work.chroot.join("rootfs")).unwrap().rdev(),
        dev_rdev.unwrap(),
    );
}

// `vm stage` against a config with `[network]` set also mknods
// `dev/net/tun` into the jail: char device 10:200, mode 0666, owned uid:gid.
#[rstest]
fn prepare_creates_tun_node_when_networking_enabled_as_root(work: Work) {
    if !is_root() {
        eprintln!("SKIP prepare_creates_tun_node_when_networking_enabled: needs root");
        return;
    }
    let cfg = work.config("[network]\nuplink = \"eth0\"\n");

    let Some(dev) = MapperDev::setup(work.tmp.path(), "tun") else {
        eprintln!("SKIP prepare_creates_tun_node: losetup/dmsetup unavailable");
        return;
    };

    let uid = 900_001;
    let gid = 900_002;
    let out = work.prepare(&cfg, &dev.path(), uid, gid);
    drop(dev);
    out.success();

    let tun = work.chroot.join("dev").join("net").join("tun");
    let meta = fs::metadata(&tun).expect("dev/net/tun must exist");
    assert!(meta.file_type().is_char_device(), "must be a char device");
    assert_eq!(nix::sys::stat::major(meta.rdev()), 10);
    assert_eq!(nix::sys::stat::minor(meta.rdev()), 200);
    assert_eq!(meta.uid(), uid);
    assert_eq!(meta.gid(), gid);
    assert_eq!(meta.permissions().mode() & 0o777, 0o666);
}

#[rstest]
#[case::root_uid(0, 900_000)]
#[case::root_gid(900_000, 0)]
#[case::uid_below_range(1000, 900_000)]
#[case::gid_above_range(900_000, 1_000_000)]
fn prepare_refuses_ids_outside_range_as_root(work: Work, #[case] uid: u32, #[case] gid: u32) {
    if !is_root() {
        eprintln!("SKIP prepare_refuses_ids_outside_range: needs root");
        return;
    }
    let cfg = work.config("");

    work.prepare(&cfg, "/dev/mapper/hyper-unused", uid, gid)
        .code(2)
        .stderr(predicates::str::contains("outside the configured range"));
    assert!(
        !work.chroot.join("vmlinux").exists(),
        "nothing may be staged"
    );
}

// `vm stage` with a system device (not a loop / hyper-* dm) is
// rejected by BlockDev parsing at request parse time — exit 2, nothing built. This
// case needs no root (parsing rejects before the privilege boundary) but also no
// device, so it always runs.
#[rstest]
fn prepare_rejects_system_device_operand(work: Work) {
    let cfg = work.config("");
    work.prepare(&cfg, "/dev/sda", 900_000, 900_000).failure();
}

// `vm teardown` of a real chroot succeeds; the cgroup leaf is given as a
// missing path so removal is idempotent and touches nothing on the host.
#[rstest]
fn remove_succeeds_and_is_idempotent_as_root(work: Work) {
    if !is_root() {
        eprintln!("SKIP remove_succeeds_and_is_idempotent: needs root");
        return;
    }
    let chroot = work.chroot.parent().unwrap();
    fs::create_dir_all(chroot.join("inner")).unwrap();
    fs::write(chroot.join("vmlinux"), b"x").unwrap();
    let cfg = work.config("[jails]\ncgroup = \"hyper-e2e-does-not-exist\"\n");

    let out = run(&cfg, json!({"op": "vm_teardown", "id": "id"})).success();
    let json = stdout_json(&out);
    assert_eq!(json["result"], "tore_down");
    assert!(!chroot.exists(), "chroot must be gone");
}

#[rstest]
#[case::traversal("../id")]
#[case::separator("a/b")]
#[case::parent_dir("..")]
#[case::leading_dash("-id")]
#[case::underscore("a_b")]
#[case::empty("")]
fn remove_refuses_an_invalid_id(work: Work, #[case] id: &str) {
    let cfg = work.config("");

    run(&cfg, json!({"op": "vm_teardown", "id": id})).code(2);
    assert!(work.chroot.exists(), "chroot must survive a refused remove");
}

#[rstest]
#[case::api_not_yet("vm_grant_api", "id", 75)]
#[case::vsock_not_yet("vm_grant_vsock", "id", 75)]
#[case::api_refused("vm_grant_api", "../id", 2)]
#[case::vsock_refused("vm_grant_vsock", "a/b", 2)]
fn grant_exit_code_separates_not_yet_from_refused_as_root(
    work: Work,
    #[case] op: &str,
    #[case] id: &str,
    #[case] code: i32,
) {
    if !is_root() {
        eprintln!("SKIP grant_exit_code_separates_not_yet_from_refused: needs root");
        return;
    }
    let cfg = work.config("");

    run(&cfg, json!({"op": op, "id": id})).code(code);
}
