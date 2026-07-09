//! Contracts of `ok_backing_file`, the losetup backing-file confinement gate.
//! Laws:
//!   * a path that does not canonicalize (absent file) is refused as
//!     `Canonicalize`, never accepted;
//!   * an existing path whose *resolved* real location is outside the
//!     configured data root is ALWAYS refused as `OutsideBase`, regardless of
//!     the spelling used to reach it (direct, symlink, `..` traversal);
//!   * (as-root, Task 2) an in-base regular file is accepted as an
//!     inheritable `/proc/self/fd/N` handle naming exactly the validated inode.
#![cfg(feature = "insecure_test_seams")]

use hyper_suidhelper::security_gate;
use hyper_suidhelper::tools::losetup::{ok_backing_file, Error};
use proptest::prelude::*;
use std::os::unix::fs::PermissionsExt;

// An absolute, lexically-strict path that never exists: `safe_load` sees
// ENOENT and falls back to the built-in defaults (hyper_base = /srv/hyper),
// making the base deterministic even on hosts that have a real
// /etc/hyper/config.toml.
const ABSENT_CONFIG: &str = "/hyper-suidhelper-test-absent/config.toml";

fn init_default_config() {
    std::env::set_var("HYPER_SETUIDHELPER_IS_INSECURE_MODE", "1");
    std::env::set_var("HYPER_SETUIDHELPER_CONFIG_PATH", ABSENT_CONFIG);
    security_gate::init();
}

proptest! {
    /// Any existing regular file outside the data root is refused as
    /// `OutsideBase`, whatever its name.
    #[test]
    fn any_existing_file_outside_base_is_refused(
        name in "[A-Za-z0-9][A-Za-z0-9._-]{0,31}",
    ) {
        init_default_config();
        let tmp = tempfile::tempdir().unwrap();
        let p = tmp.path().join(&name);
        std::fs::write(&p, b"x").unwrap();

        let err = ok_backing_file(p.to_str().unwrap())
            .expect_err("out-of-base backing file accepted");
        prop_assert!(matches!(err, Error::OutsideBase { .. }), "got {err:?}");
    }
}

#[test]
fn absent_path_is_refused_as_canonicalize() {
    init_default_config();
    let tmp = tempfile::tempdir().unwrap();
    let absent = tmp.path().join("nope.img");

    let err = ok_backing_file(absent.to_str().unwrap()).expect_err("absent backing file accepted");
    assert!(matches!(err, Error::Canonicalize { .. }), "got {err:?}");
}

#[test]
fn refusal_is_decided_on_the_resolved_path() {
    init_default_config();
    let tmp = tempfile::tempdir().unwrap();
    let target = tmp.path().join("target.img");
    std::fs::write(&target, b"x").unwrap();

    // A symlink and a `..` traversal both resolve to the same out-of-base
    // inode; the resolved path (not the spelling) must decide.
    let link = tmp.path().join("link.img");
    std::os::unix::fs::symlink(&target, &link).unwrap();
    std::fs::create_dir(tmp.path().join("sub")).unwrap();
    let dotdot = format!("{}/sub/../target.img", tmp.path().display());

    for spelling in [link.to_str().unwrap(), &dotdot] {
        let err = ok_backing_file(spelling).expect_err("out-of-base spelling accepted");
        assert!(
            matches!(err, Error::OutsideBase { .. }),
            "{spelling}: got {err:?}",
        );
    }
}

fn is_root() -> bool {
    nix::unistd::geteuid().is_root()
}

/// Point the config seam at a root-owned config whose work_dir is the (real,
/// canonicalized) tempdir, so in-base acceptance is testable. Root-only: the
/// config file must be root-owned to pass `SafeFile`'s owner check.
fn init_config_with_base(tmp: &std::path::Path) -> std::path::PathBuf {
    let base = std::fs::canonicalize(tmp).unwrap();
    let cfg = tmp.join("config.toml");
    std::fs::write(&cfg, format!(r#"work_dir = "{}""#, base.display()) + "\n").unwrap();
    std::fs::set_permissions(&cfg, std::fs::Permissions::from_mode(0o644)).unwrap();
    std::env::set_var("HYPER_SETUIDHELPER_IS_INSECURE_MODE", "1");
    std::env::set_var("HYPER_SETUIDHELPER_CONFIG_PATH", &cfg);
    security_gate::init();
    base
}

#[test]
fn in_base_file_yields_inheritable_fd_to_same_inode_as_root() {
    if !is_root() {
        eprintln!("SKIP in_base_file accept: needs root to own the config file");
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let base = init_config_with_base(tmp.path());
    let backing = base.join("disk.img");
    std::fs::write(&backing, b"data").unwrap();

    let got =
        ok_backing_file(backing.to_str().unwrap()).expect("in-base regular file must be accepted");

    // Round-trip: the returned handle names exactly the validated inode.
    let fd: i32 = got
        .to_str()
        .unwrap()
        .strip_prefix("/proc/self/fd/")
        .expect("must return a /proc/self/fd/N handle")
        .parse()
        .unwrap();
    assert_eq!(std::fs::read_link(&got).unwrap(), backing);

    // The whole point of the dup: the fd must survive exec into the losetup
    // child, i.e. CLOEXEC must be OFF. (raw libc keeps this independent of
    // nix's fcntl fd-type churn across versions)
    let flags = unsafe { nix::libc::fcntl(fd, nix::libc::F_GETFD) };
    assert!(flags >= 0, "F_GETFD failed on the returned fd");
    assert_eq!(
        flags & nix::libc::FD_CLOEXEC,
        0,
        "backing fd must be inheritable across exec",
    );
}

#[test]
fn directory_under_base_is_refused_as_root() {
    if !is_root() {
        eprintln!("SKIP directory refusal: needs root to own the config file");
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let base = init_config_with_base(tmp.path());
    let dir = base.join("subdir");
    std::fs::create_dir(&dir).unwrap();

    let err = ok_backing_file(dir.to_str().unwrap())
        .expect_err("a directory must never be a backing file");
    assert!(matches!(err, Error::Backing(_)), "got {err:?}");
}

#[test]
fn in_base_symlink_to_outside_is_refused_as_root() {
    if !is_root() {
        eprintln!("SKIP symlink-escape refusal: needs root to own the config file");
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let outside = tempfile::tempdir().unwrap();
    let base = init_config_with_base(tmp.path());

    // The link LIVES under base but its target does not — the resolved real
    // path must decide, so this in-base-looking name is refused.
    let target = outside.path().join("escape.img");
    std::fs::write(&target, b"x").unwrap();
    let link = base.join("innocent.img");
    std::os::unix::fs::symlink(&target, &link).unwrap();

    let err = ok_backing_file(link.to_str().unwrap())
        .expect_err("in-base symlink to an out-of-base target accepted");
    assert!(matches!(err, Error::OutsideBase { .. }), "got {err:?}");
}
