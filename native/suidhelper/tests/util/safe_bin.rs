//! `SafeBin<NAME>` is what stops a configured path from pointing the helper at
//! an attacker-controlled binary it would then run as root. The constructor demands
//! an absolute path, exact basename, a real (non-symlink) regular file owned by
//! root and not group/other-writable. These assert the refusal axes; the symlink
//! axis is root-independent, the owner axis is asserted both ways.

use hyper_suidhelper::util::safe_bin::SafeBin;
use std::fs;
use std::os::unix::fs::{symlink, PermissionsExt};

fn is_root() -> bool {
    nix::unistd::geteuid().is_root()
}

#[test]
fn rejects_relative_path() {
    assert!("losetup".parse::<SafeBin<"losetup">>().is_err());
    assert!("./losetup".parse::<SafeBin<"losetup">>().is_err());
}

#[test]
fn rejects_wrong_basename() {
    // An absolute, existing, root-owned system file with the WRONG basename fails.
    assert!("/usr/bin/env".parse::<SafeBin<"losetup">>().is_err());
}

#[test]
fn rejects_symlink_with_correct_basename() {
    let dir = tempfile::tempdir().unwrap();
    let target = dir.path().join("target");
    fs::write(&target, b"x").unwrap();
    let link = dir.path().join("losetup");
    symlink(&target, &link).unwrap();
    // Symlink is checked before ownership, so this holds regardless of who runs it.
    assert!(link
        .to_str()
        .unwrap()
        .parse::<SafeBin<"losetup">>()
        .is_err());
}

#[test]
fn owner_axis_root_owned_accepted_else_rejected() {
    let dir = tempfile::tempdir().unwrap();
    let f = dir.path().join("losetup");
    fs::write(&f, b"#!/bin/true\n").unwrap();
    fs::set_permissions(&f, fs::Permissions::from_mode(0o755)).unwrap();
    let got = f.to_str().unwrap().parse::<SafeBin<"losetup">>();
    if is_root() {
        // root-owned, 0755, absolute, correct basename, not a symlink → valid.
        assert!(got.is_ok(), "root-owned valid bin rejected: {got:?}");
    } else {
        // We own it (uid != 0) → NotRoot.
        assert!(got.is_err(), "non-root-owned bin accepted");
    }
}

#[test]
fn rejects_group_or_other_writable() {
    if is_root() {
        let dir = tempfile::tempdir().unwrap();
        let f = dir.path().join("losetup");
        fs::write(&f, b"x").unwrap();
        // root-owned but group/other-writable → Writable rejection.
        fs::set_permissions(&f, fs::Permissions::from_mode(0o757)).unwrap();
        assert!(f.to_str().unwrap().parse::<SafeBin<"losetup">>().is_err());
    } else {
        eprintln!("SKIP rejects_group_or_other_writable: needs root to own a 0757 file");
    }
}
