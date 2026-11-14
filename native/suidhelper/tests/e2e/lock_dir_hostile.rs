//! The per-VM lock that serializes `vm_launch` and `vm_teardown` (#135) lives in the fixed
//! `/run/hyper-suidhelper/locks`. Whoever controls that directory controls the serialization, so
//! the helper must only ever lock inside a directory chain only root can write. Driven through a
//! real setuid install by a non-root member of its group, each case in a private mount namespace
//! whose `/run` is a fresh tmpfs, so the host's own lock dir is never touched.
//!
//! Laws:
//! - on an empty `/run`, the first member caller (even with umask 000) creates
//!   `/run/hyper-suidhelper` as `root:root 0755` and `locks` as `root:root 0700`, and a teardown
//!   leaves no lock file behind;
//! - a `/run/hyper-suidhelper` or `locks` that is not root-owned, is group- or world-writable, is a
//!   symlink, or is not a directory, and a lock name that is a symlink, are all refused with a lock
//!   error: the teardown then touches nothing (the jail and socket pins survive) and nothing is
//!   created at a symlink's target.
#![cfg(feature = "insecure_mode")]

use pretty_assertions::assert_eq;
use rstest::rstest;
use serde_json::json;
use std::fs;
use std::path::PathBuf;

mod setuid_support;
mod support;
use setuid_support::{run_in_fresh_run, Install, MEMBER};
use support::is_root;

const ID: &str = "v1";

struct Vm {
    install: Install,
    config: PathBuf,
    jail_marker: PathBuf,
    pin: PathBuf,
}

fn vm() -> Vm {
    let install = Install::new();
    let srv = install.path().join("srv");
    let root = srv.join("jails/firecracker").join(ID).join("root");
    fs::create_dir_all(&root).unwrap();
    let jail_marker = root.join("marker");
    fs::write(&jail_marker, b"still here").unwrap();
    let socks = srv.join("socks");
    fs::create_dir_all(&socks).unwrap();
    nix::unistd::chown(
        &socks,
        Some(nix::unistd::Uid::from_raw(MEMBER.uid)),
        Some(nix::unistd::Gid::from_raw(MEMBER.gid)),
    )
    .unwrap();
    let pin = socks.join(format!("fc-{ID}-api.socket"));
    fs::write(&pin, b"").unwrap();
    let config = install.config(&srv);
    Vm {
        install,
        config,
        jail_marker,
        pin,
    }
}

#[test]
fn a_member_on_a_fresh_run_creates_a_root_only_lock_dir_as_root() {
    if !is_root() {
        eprintln!("SKIP fresh lock dir: needs root to install setuid");
        return;
    }
    let vm = vm();

    let out = run_in_fresh_run(
        &vm.install,
        &vm.config,
        MEMBER,
        "umask 000",
        &json!({"op": "vm_teardown", "id": ID}),
        &[
            "/run/hyper-suidhelper",
            "/run/hyper-suidhelper/locks",
            "/run/hyper-suidhelper/locks/vm-v1",
        ],
    );

    assert_eq!(
        (
            out.code,
            out.stdout.trim(),
            out.state.as_str(),
            vm.jail_marker.exists(),
            vm.pin.exists(),
        ),
        (
            Some(0),
            r#"{"result":"tore_down"}"#,
            "/run/hyper-suidhelper directory 755 0 0\n/run/hyper-suidhelper/locks directory 700 0 0\n",
            false,
            false,
        ),
        "{}",
        out.stderr
    );
}

#[rstest]
#[case::member_owned_helper_dir(
    "mkdir -m 755 /run/hyper-suidhelper; chown 62010:62001 /run/hyper-suidhelper",
    ""
)]
#[case::world_writable_sticky_helper_dir("mkdir -m 1777 /run/hyper-suidhelper", "")]
#[case::group_writable_helper_dir("mkdir -m 775 /run/hyper-suidhelper", "")]
#[case::helper_dir_is_a_file("touch /run/hyper-suidhelper", "")]
#[case::helper_dir_symlinked_to_a_member_dir(
    "mkdir -m 755 /run/attacker; mkdir -m 700 /run/attacker/locks; chown 62010 /run/attacker; \
     ln -s /run/attacker /run/hyper-suidhelper",
    "/run/attacker/locks/vm-v1"
)]
#[case::member_owned_locks(
    "mkdir -m 755 /run/hyper-suidhelper; mkdir -m 700 /run/hyper-suidhelper/locks; \
     chown 62010 /run/hyper-suidhelper/locks",
    ""
)]
#[case::group_writable_locks(
    "mkdir -m 755 /run/hyper-suidhelper; mkdir -m 730 /run/hyper-suidhelper/locks",
    ""
)]
#[case::locks_symlinked_to_a_root_dir(
    "mkdir -m 755 /run/hyper-suidhelper; mkdir -m 700 /run/elsewhere; \
     ln -s /run/elsewhere /run/hyper-suidhelper/locks",
    "/run/elsewhere/vm-v1"
)]
#[case::lock_name_symlinked(
    "mkdir -m 755 /run/hyper-suidhelper; mkdir -m 700 /run/hyper-suidhelper/locks; \
     ln -s /run/victim /run/hyper-suidhelper/locks/vm-v1",
    "/run/victim"
)]
fn a_lock_dir_root_does_not_solely_control_is_refused_and_teardown_touches_nothing_as_root(
    #[case] setup: &str,
    #[case] never_created: &str,
) {
    if !is_root() {
        eprintln!("SKIP hostile lock dir: needs root to install setuid");
        return;
    }
    let vm = vm();
    let observe: Vec<&str> = [never_created]
        .into_iter()
        .filter(|p| !p.is_empty())
        .collect();

    let out = run_in_fresh_run(
        &vm.install,
        &vm.config,
        MEMBER,
        setup,
        &json!({"op": "vm_teardown", "id": ID}),
        &observe,
    );

    assert_eq!(
        (
            out.code,
            out.stdout.as_str(),
            out.stderr.contains("lock"),
            vm.jail_marker.exists(),
            vm.pin.exists(),
            out.state.as_str(),
        ),
        (Some(2), "", true, true, true, ""),
        "{setup}: {}",
        out.stderr
    );
}
