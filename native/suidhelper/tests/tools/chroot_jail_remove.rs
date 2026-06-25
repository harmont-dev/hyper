//! Contracts of the `chroot-jail remove` op, driven through the base-injected
//! seams so they run unprivileged in a tempdir. The promises under test:
//!   * depth — `--chroot` is accepted iff it is exactly `<exec>/<id>` below the
//!     jail base; `--cgroup` iff it is at least two components below its base;
//!   * lexical — a `.`/`..`/empty component or a relative path is always rejected
//!     before any filesystem access;
//!   * idempotency — a missing chroot/cgroup (and a non-empty cgroup leaf) is
//!     success, never an error;
//!   * confinement — a symlinked path component is never followed, so a delete
//!     can never escape the anchored tree (the core TOCTOU guarantee);
//!   * removal — a real `<exec>/<id>` tree is gone afterward, and its siblings
//!     and the cgroup parent survive.

use hyper_suidhelper::tools::chroot_jail::remove::{
    remove_cgroup_under, remove_chroot_under, Error,
};
use hyper_suidhelper::util::safe_path::ValidationError;
use proptest::prelude::*;
use std::fs;
use std::os::unix::fs::symlink;
use std::path::{Path, PathBuf};

// --- depth contracts -------------------------------------------------------

// `--chroot` must be exactly <exec>/<id>: a single component below the base is
// too shallow.
#[test]
fn chroot_too_shallow_is_depth_error() {
    let tmp = tempfile::tempdir().unwrap();
    let jail = tmp.path();
    let chroot = jail.join("only-one");
    let err = remove_chroot_under(jail, &chroot).unwrap_err();
    assert!(matches!(err, Error::ChrootDepth(_)), "got {err:?}");
}

// Three components below the base is too deep.
#[test]
fn chroot_too_deep_is_depth_error() {
    let tmp = tempfile::tempdir().unwrap();
    let jail = tmp.path();
    let chroot = jail.join("exec").join("id").join("extra");
    let err = remove_chroot_under(jail, &chroot).unwrap_err();
    assert!(matches!(err, Error::ChrootDepth(_)), "got {err:?}");
}

// `--cgroup` must be at least two components below its base: a direct child is
// too shallow.
#[test]
fn cgroup_too_shallow_is_depth_error() {
    let tmp = tempfile::tempdir().unwrap();
    let base = tmp.path();
    let cgroup = base.join("leaf");
    let err = remove_cgroup_under(base, &cgroup).unwrap_err();
    assert!(matches!(err, Error::CgroupDepth(_)), "got {err:?}");
}

// --- lexical contracts -----------------------------------------------------

// A `..` component is rejected by the real SafePath gate, before any FS access.
#[test]
fn chroot_with_dotdot_is_rejected() {
    let tmp = tempfile::tempdir().unwrap();
    let jail = tmp.path();
    let chroot = PathBuf::from(format!("{}/exec/../escape", jail.display()));
    let err = remove_chroot_under(jail, &chroot).unwrap_err();
    assert!(
        matches!(err, Error::ChrootPath(ValidationError::LooseComponents)),
        "got {err:?}",
    );
}

// A relative `--chroot` is rejected (IsAbsolute axis).
#[test]
fn relative_chroot_is_rejected() {
    let tmp = tempfile::tempdir().unwrap();
    let err = remove_chroot_under(tmp.path(), Path::new("exec/id")).unwrap_err();
    assert!(
        matches!(err, Error::ChrootPath(ValidationError::NotAbsolute)),
        "got {err:?}",
    );
}

// --- idempotency contracts -------------------------------------------------

// Removing a chroot whose target does not exist (correct depth) is success.
#[test]
fn missing_chroot_is_ok() {
    let tmp = tempfile::tempdir().unwrap();
    let jail = tmp.path();
    let chroot = jail.join("exec").join("id"); // never created
    remove_chroot_under(jail, &chroot).expect("missing chroot must be Ok");
}

// Removing a cgroup leaf whose ancestor is missing is success.
#[test]
fn missing_cgroup_is_ok() {
    let tmp = tempfile::tempdir().unwrap();
    let base = tmp.path();
    let cgroup = base.join("slice").join("leaf"); // slice/ never created
    remove_cgroup_under(base, &cgroup).expect("missing cgroup must be Ok");
}

// A non-empty cgroup leaf yields ENOTEMPTY, which the op treats as success
// (something else is still using it; not our job to force-empty it).
#[test]
fn nonempty_cgroup_leaf_is_ok() {
    let tmp = tempfile::tempdir().unwrap();
    let base = tmp.path();
    let leaf = base.join("slice").join("leaf");
    fs::create_dir_all(&leaf).unwrap();
    fs::create_dir(leaf.join("child")).unwrap(); // makes rmdir return ENOTEMPTY
    remove_cgroup_under(base, &leaf).expect("non-empty leaf must be Ok (ENOTEMPTY)");
    assert!(leaf.exists(), "non-empty leaf must survive");
}

// --- removal contracts -----------------------------------------------------

// A real <exec>/<id> tree with contents is fully removed; a sibling id survives.
#[test]
fn removes_chroot_tree_and_spares_siblings() {
    let tmp = tempfile::tempdir().unwrap();
    let jail = tmp.path();
    let victim = jail.join("exec").join("id");
    fs::create_dir_all(victim.join("rootfs-dir")).unwrap();
    fs::write(victim.join("vmlinux"), b"kernel").unwrap();
    let sibling = jail.join("exec").join("other");
    fs::create_dir_all(&sibling).unwrap();

    remove_chroot_under(jail, &victim).unwrap();
    assert!(!victim.exists(), "victim chroot must be gone");
    assert!(sibling.exists(), "sibling chroot must survive");
}

// A real cgroup leaf is removed; its parent survives.
#[test]
fn removes_cgroup_leaf_and_spares_parent() {
    let tmp = tempfile::tempdir().unwrap();
    let base = tmp.path();
    let parent = base.join("slice");
    let leaf = parent.join("leaf");
    fs::create_dir_all(&leaf).unwrap();

    remove_cgroup_under(base, &leaf).unwrap();
    assert!(!leaf.exists(), "cgroup leaf must be gone");
    assert!(parent.exists(), "cgroup parent must survive");
}

// --- confinement contract (the security-critical one) ----------------------

// A symlinked <exec> component must NOT be followed: removal must fail (or no-op)
// without deleting through the symlink. A sentinel outside the jail must survive.
#[test]
fn symlinked_chroot_component_does_not_escape() {
    let tmp = tempfile::tempdir().unwrap();
    let jail = tmp.path().join("jail");
    fs::create_dir(&jail).unwrap();

    // Sentinel OUTSIDE the jail, with contents that must not be deleted.
    let sentinel = tmp.path().join("sentinel");
    fs::create_dir(&sentinel).unwrap();
    fs::create_dir(sentinel.join("id")).unwrap();
    fs::write(sentinel.join("id").join("keep.txt"), b"do not delete").unwrap();

    // `<jail>/exec` is a symlink to the external sentinel dir.
    symlink(&sentinel, jail.join("exec")).unwrap();

    let chroot = jail.join("exec").join("id");
    // O_NOFOLLOW on the `exec` component makes the walk fail rather than follow.
    let _ = remove_chroot_under(&jail, &chroot);

    assert!(
        sentinel.join("id").join("keep.txt").exists(),
        "removal escaped through a symlinked component",
    );
}

// --- property: depth classification ---------------------------------------

proptest! {
    // For a chroot `depth` components below the jail base (target never created),
    // remove_chroot_under returns Ok iff depth == 2, else ChrootDepth. The
    // generator only emits plain components, so the lexical gate never fires.
    #[test]
    fn chroot_depth_classification(
        comps in prop::collection::vec("[a-z][a-z0-9]{0,5}", 1..6)
    ) {
        let tmp = tempfile::tempdir().unwrap();
        let jail = tmp.path();
        let mut chroot = jail.to_path_buf();
        for c in &comps {
            chroot.push(c);
        }
        let res = remove_chroot_under(jail, &chroot);
        if comps.len() == 2 {
            prop_assert!(res.is_ok(), "depth 2 must be Ok, got {res:?}");
        } else {
            prop_assert!(matches!(res, Err(Error::ChrootDepth(_))), "got {res:?}");
        }
    }

    // For a cgroup `depth` components below its base, remove_cgroup_under returns
    // CgroupDepth iff depth == 1, else Ok (target missing -> idempotent).
    #[test]
    fn cgroup_depth_classification(
        comps in prop::collection::vec("[a-z][a-z0-9]{0,5}", 1..6)
    ) {
        let tmp = tempfile::tempdir().unwrap();
        let base = tmp.path();
        let mut cgroup = base.to_path_buf();
        for c in &comps {
            cgroup.push(c);
        }
        let res = remove_cgroup_under(base, &cgroup);
        if comps.len() == 1 {
            prop_assert!(matches!(res, Err(Error::CgroupDepth(_))), "got {res:?}");
        } else {
            prop_assert!(res.is_ok(), "depth >= 2 must be Ok, got {res:?}");
        }
    }
}
