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

use hyper_suidhelper::fs::path::{
    ComponentError, IsAbsolute, RelativeError, SafePathBuf, StrictComponents, ValidationError,
};
use hyper_suidhelper::tools::chroot_jail::remove::{
    remove_cgroup_under, remove_chroot_under, CgroupError, ChrootError,
};
use proptest::prelude::*;
use std::fs;
use std::os::unix::fs::symlink;
use std::path::{Path, PathBuf};

fn strict(p: impl AsRef<Path>) -> SafePathBuf<IsAbsolute, StrictComponents> {
    p.as_ref().to_path_buf().try_into().unwrap()
}

// `--chroot` must be exactly <exec>/<id>: a single component below the base is
// too shallow.
#[test]
fn chroot_too_shallow_is_depth_error() {
    let tmp = tempfile::tempdir().unwrap();
    let jail = tmp.path();
    let chroot = jail.join("only-one");
    let err = remove_chroot_under(&strict(jail), &chroot).unwrap_err();
    assert!(matches!(err, ChrootError::Depth(_)), "got {err:?}");
}

// Three components below the base is too deep.
#[test]
fn chroot_too_deep_is_depth_error() {
    let tmp = tempfile::tempdir().unwrap();
    let jail = tmp.path();
    let chroot = jail.join("exec").join("id").join("extra");
    let err = remove_chroot_under(&strict(jail), &chroot).unwrap_err();
    assert!(matches!(err, ChrootError::Depth(_)), "got {err:?}");
}

#[test]
fn cgroup_parent_itself_is_refused() {
    let tmp = tempfile::tempdir().unwrap();
    let parent = tmp.path().join("hyper");
    let err = remove_cgroup_under(&strict(&parent), &parent).unwrap_err();
    assert!(
        matches!(err, CgroupError::Base(RelativeError::EqualsBase)),
        "got {err:?}"
    );
}

#[test]
fn cgroup_leaf_that_is_not_a_vm_id_is_refused() {
    let tmp = tempfile::tempdir().unwrap();
    let parent = tmp.path().join("hyper");
    for leaf in ["-leaf", "a.b", "sshd.service", &"a".repeat(65)] {
        let err = remove_cgroup_under(&strict(&parent), &parent.join(leaf)).unwrap_err();
        assert!(matches!(err, CgroupError::Leaf(_)), "{leaf:?}: got {err:?}");
    }
}

// A `..` component is rejected by the real SafePath gate, before any FS access.
#[test]
fn chroot_with_dotdot_is_rejected() {
    let tmp = tempfile::tempdir().unwrap();
    let jail = tmp.path();
    let chroot = PathBuf::from(format!("{}/exec/../escape", jail.display()));
    let err = remove_chroot_under(&strict(jail), &chroot).unwrap_err();
    assert!(
        matches!(
            err,
            ChrootError::Path(ValidationError::Component(ComponentError::ParentDir))
        ),
        "got {err:?}",
    );
}

// A relative `--chroot` is rejected (IsAbsolute axis).
#[test]
fn relative_chroot_is_rejected() {
    let tmp = tempfile::tempdir().unwrap();
    let err = remove_chroot_under(&strict(tmp.path()), Path::new("exec/id")).unwrap_err();
    assert!(
        matches!(err, ChrootError::Path(ValidationError::NotAbsolute)),
        "got {err:?}",
    );
}

// Removing a chroot whose target does not exist (correct depth) is success.
#[test]
fn missing_chroot_is_ok() {
    let tmp = tempfile::tempdir().unwrap();
    let jail = tmp.path();
    let chroot = jail.join("exec").join("id"); // never created
    remove_chroot_under(&strict(jail), &chroot).expect("missing chroot must be Ok");
}

// Removing a cgroup leaf whose parent is missing is success.
#[test]
fn missing_cgroup_is_ok() {
    let tmp = tempfile::tempdir().unwrap();
    let parent = tmp.path().join("hyper"); // never created
    let cgroup = parent.join("leaf");
    remove_cgroup_under(&strict(&parent), &cgroup).expect("missing cgroup must be Ok");
}

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

    remove_chroot_under(&strict(jail), &victim).unwrap();
    assert!(!victim.exists(), "victim chroot must be gone");
    assert!(sibling.exists(), "sibling chroot must survive");
}

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
    let _ = remove_chroot_under(&strict(&jail), &chroot);

    assert!(
        sentinel.join("id").join("keep.txt").exists(),
        "removal escaped through a symlinked component",
    );
}

// The leaf is already gone but its parent survives: the new openat_dir(leaf)
// ENOENT branch returns Ok without touching the parent.
#[test]
fn missing_leaf_with_present_parent_is_ok() {
    let tmp = tempfile::tempdir().unwrap();
    let parent = tmp.path().join("hyper");
    fs::create_dir(&parent).unwrap();
    let leaf = parent.join("leaf"); // never created

    remove_cgroup_under(&strict(&parent), &leaf).expect("missing leaf must be Ok");
    assert!(parent.exists(), "parent must survive");
}

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
        let res = remove_chroot_under(&strict(jail), &chroot);
        if comps.len() == 2 {
            prop_assert!(res.is_ok(), "depth 2 must be Ok, got {res:?}");
        } else {
            prop_assert!(matches!(res, Err(ChrootError::Depth(_))), "got {res:?}");
        }
    }

    #[test]
    fn cgroup_shape_classification(
        comps in prop::collection::vec("[a-z][a-z0-9]{0,5}", 1..6)
    ) {
        let tmp = tempfile::tempdir().unwrap();
        let parent = tmp.path().join("hyper");
        let mut cgroup = parent.clone();
        for c in &comps {
            cgroup.push(c);
        }
        let res = remove_cgroup_under(&strict(&parent), &cgroup);
        if comps.len() == 1 {
            prop_assert!(res.is_ok(), "parent/<id> must be Ok, got {res:?}");
        } else {
            prop_assert!(matches!(res, Err(CgroupError::Shape(_))), "got {res:?}");
        }
    }

    #[test]
    fn cgroup_outside_parent_is_refused(
        other in "[a-z][a-z0-9]{0,5}",
        comps in prop::collection::vec("[a-z][a-z0-9]{0,5}", 0..4),
    ) {
        prop_assume!(other != "hyper");
        let tmp = tempfile::tempdir().unwrap();
        let parent = tmp.path().join("hyper");
        let mut cgroup = tmp.path().join(&other);
        for c in &comps {
            cgroup.push(c);
        }
        let res = remove_cgroup_under(&strict(&parent), &cgroup);
        prop_assert!(
            matches!(res, Err(CgroupError::Base(RelativeError::NotUnderBase))),
            "got {res:?}"
        );
    }
}
