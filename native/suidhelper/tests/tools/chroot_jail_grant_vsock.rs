//! Contracts of the `chroot-jail grant-vsock` op. The lexical refusal contracts
//! (absoluteness, strict components, exact leaf name) are enforced at clap-parse
//! time by `VsockSocket`'s `FromStr` and are tested there; the base-relative
//! shape and the privileged filesystem behavior are driven through the
//! base-injected `grant_vsock_under` seam so they run unprivileged in a tempdir.
//! The promises under test (refusal contracts first — they are the security
//! boundary):
//!   * lexical (parse time) — a relative path, a `.`/`..`/empty component, or a
//!     leaf that is not exactly `vsock.sock` is rejected constructing a
//!     `VsockSocket`, before any filesystem access;
//!   * shape — a valid `VsockSocket` is granted iff it is exactly
//!     `<exec>/<id>/root/vsock.sock` below the jail base; any other depth is
//!     refused (`SocketShape`) before any chown;
//!   * type — a regular file or a symlink planted at the socket path is refused
//!     (`NotASocket`) and left untouched, never chmod'd; only a real socket is
//!     granted;
//!   * confinement — a symlinked path component is never followed, so the chown
//!     can never escape the anchored jail tree (the core TOCTOU guarantee);
//!   * pending — a not-yet-created socket (or half-built jail) is `Pending`, not
//!     an error, so the controller keeps probing;
//!   * grant — a real socket is chowned to the caller and left mode 0660, and
//!     its parent `root` dir is opened for the caller's group to traverse
//!     (chgrp'd to the caller, chmod'd 0710) so the node can reach the socket.

use hyper_suidhelper::tools::chroot_jail::grant_vsock::{
    grant_vsock_under, Error, GrantOut, VsockSocket,
};
use hyper_suidhelper::util::safe_path::ValidationError;
use proptest::prelude::*;
use std::os::unix::fs::{symlink, PermissionsExt};
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::str::FromStr;
use std::{fs, os::unix::fs::MetadataExt};

/// Parse an absolute socket path into a validated `VsockSocket`, panicking if
/// the lexical gate rejects it — for tests whose subject is the base-relative
/// or filesystem behavior, not the parse.
fn sock(p: &Path) -> VsockSocket {
    VsockSocket::from_str(p.to_str().unwrap()).unwrap()
}

/// Build the canonical `<jail>/exec/id/root` parent dirs and return that dir.
fn make_root(jail: &Path) -> PathBuf {
    let root = jail.join("exec").join("id").join("root");
    fs::create_dir_all(&root).unwrap();
    root
}

#[test]
fn wrong_leaf_name_is_rejected_at_parse() {
    let tmp = tempfile::tempdir().unwrap();
    // `evil.vsock` would have passed a suffix check — the exact-name gate must
    // reject it, before any filesystem access.
    let bad = tmp.path().join("exec/id/root/evil.vsock");
    let err = VsockSocket::from_str(bad.to_str().unwrap()).unwrap_err();
    assert!(matches!(err, Error::SocketName(_)), "got {err:?}");
}

#[test]
fn api_socket_name_is_rejected_at_parse() {
    let tmp = tempfile::tempdir().unwrap();
    let bad = tmp.path().join("exec/id/root/api.socket");
    let err = VsockSocket::from_str(bad.to_str().unwrap()).unwrap_err();
    assert!(matches!(err, Error::SocketName(_)), "got {err:?}");
}

#[test]
fn dotdot_traversal_is_rejected_at_parse() {
    let tmp = tempfile::tempdir().unwrap();
    let bad = format!("{}/exec/../id/root/vsock.sock", tmp.path().display());
    let err = VsockSocket::from_str(&bad).unwrap_err();
    assert!(
        matches!(err, Error::SocketPath(ValidationError::LooseComponents)),
        "got {err:?}",
    );
}

#[test]
fn relative_socket_is_rejected_at_parse() {
    let err = VsockSocket::from_str("exec/id/root/vsock.sock").unwrap_err();
    assert!(
        matches!(err, Error::SocketPath(ValidationError::NotAbsolute)),
        "got {err:?}",
    );
}

#[test]
fn socket_outside_jail_base_is_rejected() {
    let tmp = tempfile::tempdir().unwrap();
    let jail = tmp.path().join("jail");
    fs::create_dir(&jail).unwrap();
    let outside = tmp.path().join("elsewhere/exec/id/root/vsock.sock");
    let err = grant_vsock_under(&jail, &sock(&outside)).unwrap_err();
    assert!(
        matches!(err, Error::SocketPath(ValidationError::NotUnderBase)),
        "got {err:?}",
    );
}

#[test]
fn too_shallow_is_shape_error() {
    let tmp = tempfile::tempdir().unwrap();
    let jail = tmp.path();
    let bad = jail.join("exec").join("id").join("vsock.sock"); // missing root/
    let err = grant_vsock_under(jail, &sock(&bad)).unwrap_err();
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
        .join("vsock.sock");
    let err = grant_vsock_under(jail, &sock(&bad)).unwrap_err();
    assert!(matches!(err, Error::SocketShape(_)), "got {err:?}");
}

#[test]
fn missing_socket_is_pending() {
    let tmp = tempfile::tempdir().unwrap();
    let jail = tmp.path();
    let root = make_root(jail);
    let socket = root.join("vsock.sock"); // never created
    let out = grant_vsock_under(jail, &sock(&socket)).expect("missing socket must be Ok(Pending)");
    assert!(matches!(out, GrantOut::Pending), "got {out:?}");
}

#[test]
fn missing_jail_tree_is_pending() {
    let tmp = tempfile::tempdir().unwrap();
    let jail = tmp.path();
    let socket = jail.join("exec").join("id").join("root").join("vsock.sock");
    let out = grant_vsock_under(jail, &sock(&socket)).expect("half-built jail must be Ok(Pending)");
    assert!(matches!(out, GrantOut::Pending), "got {out:?}");
}

#[test]
fn real_socket_is_granted_and_chmod_0660() {
    let tmp = tempfile::tempdir().unwrap();
    let jail = tmp.path();
    let root = make_root(jail);
    let socket = root.join("vsock.sock");
    let _listener = UnixListener::bind(&socket).unwrap();
    fs::set_permissions(&socket, fs::Permissions::from_mode(0o755)).unwrap();

    let out = grant_vsock_under(jail, &sock(&socket)).expect("real socket must grant");
    assert!(matches!(out, GrantOut::Granted), "got {out:?}");

    let meta = fs::symlink_metadata(&socket).unwrap();
    assert_eq!(meta.mode() & 0o777, 0o660, "socket must be chmod'd 0660");
    assert_eq!(meta.uid(), nix::unistd::getuid().as_raw());
    assert_eq!(meta.gid(), nix::unistd::getgid().as_raw());

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

#[test]
fn regular_file_at_leaf_is_refused_and_untouched() {
    let tmp = tempfile::tempdir().unwrap();
    let jail = tmp.path();
    let root = make_root(jail);
    // Use the real name so the S_ISSOCK gate — not the name gate — fires.
    let imposter = root.join("vsock.sock");
    fs::write(&imposter, b"not a socket").unwrap();
    fs::set_permissions(&imposter, fs::Permissions::from_mode(0o600)).unwrap();

    let err = grant_vsock_under(jail, &sock(&imposter)).unwrap_err();
    assert!(matches!(err, Error::NotASocket), "got {err:?}");
    assert_eq!(
        fs::symlink_metadata(&imposter).unwrap().mode() & 0o777,
        0o600,
        "imposter file must not be chmod'd",
    );
}

#[test]
fn symlink_at_leaf_is_refused() {
    let tmp = tempfile::tempdir().unwrap();
    let jail = tmp.path();
    let root = make_root(jail);
    let target = tmp.path().join("real-target");
    fs::write(&target, b"secret").unwrap();
    // Use the real name so the S_ISSOCK gate fires, not the name gate.
    let link = root.join("vsock.sock");
    symlink(&target, &link).unwrap();

    let err = grant_vsock_under(jail, &sock(&link)).unwrap_err();
    assert!(matches!(err, Error::NotASocket), "got {err:?}");
}

#[test]
fn symlinked_component_does_not_escape() {
    let tmp = tempfile::tempdir().unwrap();
    let jail = tmp.path().join("jail");
    fs::create_dir(&jail).unwrap();

    let sentinel = tmp.path().join("sentinel");
    fs::create_dir_all(sentinel.join("id").join("root")).unwrap();
    let outside_socket = sentinel.join("id").join("root").join("vsock.sock");
    let _listener = UnixListener::bind(&outside_socket).unwrap();
    fs::set_permissions(&outside_socket, fs::Permissions::from_mode(0o700)).unwrap();

    // `<jail>/exec` is a symlink to the external sentinel dir.
    symlink(&sentinel, jail.join("exec")).unwrap();

    let socket = jail.join("exec").join("id").join("root").join("vsock.sock");
    let _ = grant_vsock_under(&jail, &sock(&socket)); // O_NOFOLLOW makes the walk refuse

    assert_eq!(
        fs::symlink_metadata(&outside_socket).unwrap().mode() & 0o777,
        0o700,
        "grant escaped through a symlinked component",
    );
}

#[test]
fn symlink_to_real_socket_at_leaf_is_refused_and_target_untouched() {
    let tmp = tempfile::tempdir().unwrap();
    let jail = tmp.path();
    let root = make_root(jail);
    // The link target IS a genuine socket outside the jail: a stat that
    // follows the link sees S_IFSOCK and would wrongly grant (chmodding the
    // outside socket). Only the AT_SYMLINK_NOFOLLOW stat (S_IFLNK) refuses.
    let outside = tmp.path().join("outside.sock");
    let _listener = UnixListener::bind(&outside).unwrap();
    fs::set_permissions(&outside, fs::Permissions::from_mode(0o700)).unwrap();
    let link = root.join("vsock.sock");
    symlink(&outside, &link).unwrap();

    let err = grant_vsock_under(jail, &sock(&link)).unwrap_err();
    assert!(matches!(err, Error::NotASocket), "got {err:?}");
    assert_eq!(
        fs::symlink_metadata(&outside).unwrap().mode() & 0o777,
        0o700,
        "grant must never reach through the leaf symlink to the real socket",
    );
}

#[test]
fn unreadable_jail_base_is_a_hard_walk_error_not_pending() {
    // Root bypasses permission checks, so the refusal cannot fire; skip.
    if nix::unistd::geteuid().is_root() {
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let jail = tmp.path().join("jail");
    fs::create_dir(&jail).unwrap();
    let socket = jail.join("exec").join("id").join("root").join("vsock.sock");
    fs::set_permissions(&jail, fs::Permissions::from_mode(0o000)).unwrap();

    let res = grant_vsock_under(&jail, &sock(&socket));
    // Restore before asserting so the tempdir can clean up even on failure.
    fs::set_permissions(&jail, fs::Permissions::from_mode(0o755)).unwrap();

    assert!(
        matches!(res, Err(Error::Walk(_))),
        "EACCES must be a hard Walk error, never Ok(Pending): got {res:?}",
    );
}

proptest! {
    // For a socket `depth` components below the jail base with leaf `vsock.sock`
    // (target never created), grant_vsock_under returns Ok(Pending) iff depth == 4
    // (i.e. 3 parents), else SocketShape. The generator emits only plain names so
    // the lexical parse always succeeds and the leaf is always `vsock.sock`.
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
        socket.push("vsock.sock");
        let res = grant_vsock_under(jail, &sock(&socket));
        if parents.len() == 3 {
            prop_assert!(matches!(res, Ok(GrantOut::Pending)), "depth 3 must be Pending, got {res:?}");
        } else {
            prop_assert!(matches!(res, Err(Error::SocketShape(_))), "got {res:?}");
        }
    }
}
