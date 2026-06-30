//! Contracts of the `chroot-jail grant-api` op, driven through the base-injected
//! `grant_api_under` seam so they run unprivileged in a tempdir. The promises
//! under test (refusal contracts first — they are the security boundary):
//!   * shape — the socket is accepted iff it is exactly
//!     `<exec>/<id>/root/api.socket` below the jail base; any other depth or a
//!     leaf that is not `api.socket` is refused before any chown;
//!   * lexical — a `.`/`..`/empty component or a relative path is always rejected
//!     before any filesystem access;
//!   * type — a regular file or a symlink planted at `api.socket` is refused
//!     (`NotASocket`) and left untouched, never chmod'd; only a real socket is
//!     granted;
//!   * confinement — a symlinked path component is never followed, so the chown
//!     can never escape the anchored jail tree (the core TOCTOU guarantee);
//!   * pending — a not-yet-created socket (or half-built jail) is `Pending`, not
//!     an error, so the controller keeps probing;
//!   * grant — a real socket is chowned to the caller and left mode 0660, and
//!     its parent `root` dir is opened for the caller's group to traverse
//!     (chgrp'd to the caller, chmod'd 0710) so the node can reach the socket.

use hyper_suidhelper::tools::chroot_jail::grant_api::{grant_api_under, Error, GrantOut};
use hyper_suidhelper::util::safe_path::ValidationError;
use proptest::prelude::*;
use std::os::unix::fs::{symlink, PermissionsExt};
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::{fs, os::unix::fs::MetadataExt};

/// Build the canonical `<jail>/exec/id/root` parent dirs and return that dir.
fn make_root(jail: &Path) -> PathBuf {
    let root = jail.join("exec").join("id").join("root");
    fs::create_dir_all(&root).unwrap();
    root
}

#[test]
fn socket_outside_jail_base_is_rejected() {
    let tmp = tempfile::tempdir().unwrap();
    let jail = tmp.path().join("jail");
    fs::create_dir(&jail).unwrap();
    let outside = tmp.path().join("elsewhere/exec/id/root/api.socket");
    let err = grant_api_under(&jail, &outside).unwrap_err();
    assert!(
        matches!(err, Error::SocketPath(ValidationError::NotUnderBase)),
        "got {err:?}",
    );
}

#[test]
fn wrong_leaf_basename_is_rejected() {
    let tmp = tempfile::tempdir().unwrap();
    let jail = tmp.path();
    let bad = jail.join("exec").join("id").join("root").join("evil.sock");
    let err = grant_api_under(jail, &bad).unwrap_err();
    assert!(matches!(err, Error::SocketName(_)), "got {err:?}");
}

#[test]
fn too_shallow_is_shape_error() {
    let tmp = tempfile::tempdir().unwrap();
    let jail = tmp.path();
    let bad = jail.join("exec").join("id").join("api.socket"); // missing root/
    let err = grant_api_under(jail, &bad).unwrap_err();
    assert!(matches!(err, Error::SocketShape(_)), "got {err:?}");
}

#[test]
fn too_deep_is_shape_error() {
    let tmp = tempfile::tempdir().unwrap();
    let jail = tmp.path();
    let bad = jail
        .join("exec")
        .join("id")
        .join("root")
        .join("extra")
        .join("api.socket");
    let err = grant_api_under(jail, &bad).unwrap_err();
    assert!(matches!(err, Error::SocketShape(_)), "got {err:?}");
}

#[test]
fn dotdot_traversal_is_rejected() {
    let tmp = tempfile::tempdir().unwrap();
    let jail = tmp.path();
    let bad = PathBuf::from(format!("{}/exec/../id/root/api.socket", jail.display()));
    let err = grant_api_under(jail, &bad).unwrap_err();
    assert!(
        matches!(err, Error::SocketPath(ValidationError::LooseComponents)),
        "got {err:?}",
    );
}

#[test]
fn relative_socket_is_rejected() {
    let tmp = tempfile::tempdir().unwrap();
    let err = grant_api_under(tmp.path(), Path::new("exec/id/root/api.socket")).unwrap_err();
    assert!(
        matches!(err, Error::SocketPath(ValidationError::NotAbsolute)),
        "got {err:?}",
    );
}

#[test]
fn missing_socket_is_pending() {
    let tmp = tempfile::tempdir().unwrap();
    let jail = tmp.path();
    let root = make_root(jail);
    let socket = root.join("api.socket"); // never created
    let out = grant_api_under(jail, &socket).expect("missing socket must be Ok(Pending)");
    assert!(matches!(out, GrantOut::Pending), "got {out:?}");
}

#[test]
fn missing_jail_tree_is_pending() {
    let tmp = tempfile::tempdir().unwrap();
    let jail = tmp.path();
    let socket = jail.join("exec").join("id").join("root").join("api.socket"); // nothing created
    let out = grant_api_under(jail, &socket).expect("half-built jail must be Ok(Pending)");
    assert!(matches!(out, GrantOut::Pending), "got {out:?}");
}

// A real socket is granted: chowned to the caller (our own uid/gid, which a
// non-root process is allowed to set on a file it owns) and chmod'd 0660.
#[test]
fn real_socket_is_granted_and_chmod_0660() {
    let tmp = tempfile::tempdir().unwrap();
    let jail = tmp.path();
    let root = make_root(jail);
    let socket = root.join("api.socket");
    let _listener = UnixListener::bind(&socket).unwrap();
    fs::set_permissions(&socket, fs::Permissions::from_mode(0o755)).unwrap();

    let out = grant_api_under(jail, &socket).expect("real socket must grant");
    assert!(matches!(out, GrantOut::Granted), "got {out:?}");

    let meta = fs::symlink_metadata(&socket).unwrap();
    assert_eq!(meta.mode() & 0o777, 0o660, "socket must be chmod'd 0660");
    assert_eq!(meta.uid(), nix::unistd::getuid().as_raw());
    assert_eq!(meta.gid(), nix::unistd::getgid().as_raw());

    // The parent `root` dir must also be opened for the caller's group to
    // traverse, else the node could not reach the socket: chgrp'd to the caller,
    // chmod'd 0710 (owner rwx, group --x, other none).
    let root_meta = fs::symlink_metadata(&root).unwrap();
    assert_eq!(
        root_meta.mode() & 0o777,
        0o710,
        "jail root must be chmod'd 0710 for traversal",
    );
    assert_eq!(
        root_meta.gid(),
        nix::unistd::getgid().as_raw(),
        "jail root must be chgrp'd to the caller",
    );
}

// A regular file planted at api.socket is refused and left untouched (not chmod'd).
#[test]
fn regular_file_at_leaf_is_refused_and_untouched() {
    let tmp = tempfile::tempdir().unwrap();
    let jail = tmp.path();
    let root = make_root(jail);
    let imposter = root.join("api.socket");
    fs::write(&imposter, b"not a socket").unwrap();
    fs::set_permissions(&imposter, fs::Permissions::from_mode(0o600)).unwrap();

    let err = grant_api_under(jail, &imposter).unwrap_err();
    assert!(matches!(err, Error::NotASocket), "got {err:?}");
    assert_eq!(
        fs::symlink_metadata(&imposter).unwrap().mode() & 0o777,
        0o600,
        "imposter file must not be chmod'd",
    );
}

// A symlink planted at api.socket is refused: fstatat(AT_SYMLINK_NOFOLLOW) stats
// the link itself (S_IFLNK), so it is never seen as a socket and never followed.
#[test]
fn symlink_at_leaf_is_refused() {
    let tmp = tempfile::tempdir().unwrap();
    let jail = tmp.path();
    let root = make_root(jail);
    let target = tmp.path().join("real-target");
    fs::write(&target, b"secret").unwrap();
    let link = root.join("api.socket");
    symlink(&target, &link).unwrap();

    let err = grant_api_under(jail, &link).unwrap_err();
    assert!(matches!(err, Error::NotASocket), "got {err:?}");
}

// A symlinked path component must NOT be followed: the walk fails rather than
// reaching through it, so nothing outside the jail is touched.
#[test]
fn symlinked_component_does_not_escape() {
    let tmp = tempfile::tempdir().unwrap();
    let jail = tmp.path().join("jail");
    fs::create_dir(&jail).unwrap();

    let sentinel = tmp.path().join("sentinel");
    fs::create_dir_all(sentinel.join("id").join("root")).unwrap();
    let outside_socket = sentinel.join("id").join("root").join("api.socket");
    let _listener = UnixListener::bind(&outside_socket).unwrap();
    fs::set_permissions(&outside_socket, fs::Permissions::from_mode(0o700)).unwrap();

    // `<jail>/exec` is a symlink to the external sentinel dir.
    symlink(&sentinel, jail.join("exec")).unwrap();

    let socket = jail.join("exec").join("id").join("root").join("api.socket");
    let _ = grant_api_under(&jail, &socket); // O_NOFOLLOW makes the walk refuse

    assert_eq!(
        fs::symlink_metadata(&outside_socket).unwrap().mode() & 0o777,
        0o700,
        "grant escaped through a symlinked component",
    );
}

proptest! {
    // For a socket `depth` components below the jail base with leaf `api.socket`
    // (target never created), grant_api_under returns Ok(Pending) iff depth == 4
    // (i.e. 3 parents), else SocketShape. The generator emits only plain names so
    // the lexical gate never fires and the leaf is always `api.socket`.
    #[test]
    fn shape_classification(
        parents in prop::collection::vec("[a-z][a-z0-9]{0,5}", 1..6)
    ) {
        let tmp = tempfile::tempdir().unwrap();
        let jail = tmp.path();
        let mut socket = jail.to_path_buf();
        for c in &parents {
            socket.push(c);
        }
        socket.push("api.socket");
        let res = grant_api_under(jail, &socket);
        if parents.len() == 3 {
            prop_assert!(matches!(res, Ok(GrantOut::Pending)), "depth 3 must be Pending, got {res:?}");
        } else {
            prop_assert!(matches!(res, Err(Error::SocketShape(_))), "got {res:?}");
        }
    }
}
