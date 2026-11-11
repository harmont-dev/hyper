//! L5: the `vm` jail ops observed end to end through the binary (exit code +
//! stdout JSON), with the config-path seam pointing `work_dir` at a tempdir so we
//! never touch /etc/hyper or /srv. Root-gated: the helper acquires privileges for
//! mknod/chown, so these self-skip without root. The cgroup half is exercised
//! only with a MISSING leaf (idempotent, mutates nothing on the real host).
#![cfg(feature = "insecure_mode")]

use assert_fs::prelude::*;
use assert_fs::TempDir;
use pretty_assertions::assert_eq;
use rstest::{fixture, rstest};
use serde_json::json;
use std::fs;
use std::io::ErrorKind;
use std::os::unix::fs::{symlink, MetadataExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};

mod support;
use support::{is_root, run, stdout_json, ScratchNs};

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

struct Work {
    tmp: TempDir,
    dir: PathBuf,
    chroot: PathBuf,
}

impl Work {
    fn config(&self, tables: &str) -> PathBuf {
        write_config(self.tmp.path(), &self.dir, tables)
    }

    fn socks(&self) -> PathBuf {
        let socks = self.dir.join("socks");
        fs::create_dir_all(&socks).unwrap();
        socks
    }
}

#[fixture]
fn work() -> Work {
    let tmp = TempDir::new().unwrap();
    let chroot = tmp.child("srv/jails/firecracker/id/root");
    chroot.create_dir_all().unwrap();
    Work {
        dir: tmp.child("srv").to_path_buf(),
        chroot: chroot.to_path_buf(),
        tmp,
    }
}

fn listen(path: &Path) -> UnixListener {
    let listener = UnixListener::bind(path).unwrap();
    listener.set_nonblocking(true).unwrap();
    listener
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

    let out = ScratchNs::new("chroot-remove")
        .run(&cfg, json!({"op": "vm_teardown", "id": "id"}))
        .success();
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
#[case::api_not_yet("vm_claim_api_socket")]
#[case::vsock_not_yet("vm_claim_vsock_socket")]
fn claim_reports_a_socket_not_created_yet_as_pending_as_root(work: Work, #[case] op: &str) {
    if !is_root() {
        eprintln!("SKIP grant pending: needs root");
        return;
    }
    let cfg = work.config("");

    let out = run(&cfg, json!({"op": op, "id": "id"})).success();
    assert_eq!(stdout_json(&out)["result"], "pending");
}

#[rstest]
#[case::api_traversal("vm_claim_api_socket", "../id")]
#[case::vsock_nested("vm_claim_vsock_socket", "a/b")]
fn claim_refuses_an_invalid_id(work: Work, #[case] op: &str, #[case] id: &str) {
    let cfg = work.config("");

    run(&cfg, json!({"op": op, "id": id})).code(2).stdout("");
}

#[rstest]
#[case::api("vm_claim_api_socket", "api.socket")]
#[case::vsock("vm_claim_vsock_socket", "vsock.sock")]
fn claim_pins_the_socket_against_a_later_swap_until_teardown_as_root(
    work: Work,
    #[case] op: &str,
    #[case] socket: &str,
) {
    if !is_root() {
        eprintln!("SKIP claim pin: needs root");
        return;
    }
    let pinned = work.socks().join(format!("fc-id-{socket}"));
    let in_jail = work.chroot.join(socket);
    let own = listen(&in_jail);
    let other_vm = listen(&work.tmp.path().join("other-vm.sock"));
    let cfg = work.config("[jails]\ncgroup = \"hyper-e2e-does-not-exist\"\n");

    let out = run(&cfg, json!({"op": op, "id": "id"})).success();
    assert_eq!(stdout_json(&out)["result"], "claimed");

    fs::remove_file(&in_jail).unwrap();
    symlink(work.tmp.path().join("other-vm.sock"), &in_jail).unwrap();
    UnixStream::connect(&pinned).expect("pinned socket must still accept");

    own.accept()
        .expect("the claimed socket must receive the connection");
    assert_eq!(
        other_vm.accept().err().map(|e| e.kind()),
        Some(ErrorKind::WouldBlock),
        "a swapped jail entry must not redirect the pinned socket"
    );

    ScratchNs::new("claim-pin")
        .run(&cfg, json!({"op": "vm_teardown", "id": "id"}))
        .success();
    assert!(!pinned.exists(), "teardown must remove the pinned socket");
}

#[rstest]
fn claim_replaces_a_stale_pin_as_root(work: Work) {
    if !is_root() {
        eprintln!("SKIP claim stale pin: needs root");
        return;
    }
    let pinned = work.socks().join("fc-id-api.socket");
    fs::write(&pinned, b"stale").unwrap();
    let in_jail = work.chroot.join("api.socket");
    let _own = listen(&in_jail);
    let cfg = work.config("");

    run(&cfg, json!({"op": "vm_claim_api_socket", "id": "id"})).success();

    assert_eq!(
        fs::symlink_metadata(&pinned).unwrap().ino(),
        fs::symlink_metadata(&in_jail).unwrap().ino()
    );
}
