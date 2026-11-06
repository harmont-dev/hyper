// SPDX-License-Identifier: MIT

use hyperrs_firecracker::chroot_jail::{GrantError, JailLayout};
use hyperrs_fs::file;
use hyperrs_fs::path::StrictComponent;
use nix::errno::Errno;
use thiserror::Error as ThisError;

#[derive(Debug, ThisError)]
pub enum GrantSocketError {
    #[error("walking to the jail root: {0}")]
    Walk(#[source] file::ValidationError),
    #[error(transparent)]
    Grant(#[from] GrantError),
}

pub fn grant_socket(
    layout: &JailLayout<'_>,
    socket: &StrictComponent,
) -> Result<(), GrantSocketError> {
    let root = match layout.open_root() {
        Ok(root) => root,
        Err(file::ValidationError::Open(Errno::ENOENT)) => return Err(GrantError::Missing.into()),
        Err(e) => return Err(GrantSocketError::Walk(e)),
    };
    Ok(root.grant_to_caller(socket)?)
}

#[cfg(test)]
mod tests {
    use super::{grant_socket, GrantSocketError};
    use hyperrs_firecracker::chroot_jail::{GrantError, JailLayout};
    use hyperrs_firecracker::jailer::VmId;
    use hyperrs_fs::path::{IsAbsolute, SafePathBuf, StrictComponent, StrictComponents};
    use std::fs;
    use std::os::unix::fs::{symlink, MetadataExt, PermissionsExt};
    use std::os::unix::net::UnixListener;
    use std::path::{Path, PathBuf};

    const LEAF: &StrictComponent = StrictComponent::from_static("api.socket");

    fn grant(jail: &Path) -> Result<(), GrantSocketError> {
        let base: SafePathBuf<IsAbsolute, StrictComponents> =
            jail.to_path_buf().try_into().unwrap();
        let id: VmId = "id".parse().unwrap();
        grant_socket(&JailLayout::new(&base, &id), LEAF)
    }

    fn make_root(jail: &Path) -> PathBuf {
        let root = jail.join("firecracker").join("id").join("root");
        fs::create_dir_all(&root).unwrap();
        root
    }

    #[test]
    fn not_yet_created_is_missing() {
        for create_root in [false, true] {
            let tmp = tempfile::tempdir().unwrap();
            if create_root {
                make_root(tmp.path());
            }
            let res = grant(tmp.path());
            assert!(
                matches!(res, Err(GrantSocketError::Grant(GrantError::Missing))),
                "create_root={create_root}: got {res:?}"
            );
        }
    }

    #[test]
    fn real_socket_is_granted_and_root_opened_for_traversal() {
        let tmp = tempfile::tempdir().unwrap();
        let root = make_root(tmp.path());
        let socket = root.join("api.socket");
        let _listener = UnixListener::bind(&socket).unwrap();
        fs::set_permissions(&socket, fs::Permissions::from_mode(0o755)).unwrap();

        grant(tmp.path()).expect("real socket must grant");

        let meta = fs::symlink_metadata(&socket).unwrap();
        assert_eq!(meta.mode() & 0o777, 0o660);
        assert_eq!(meta.uid(), nix::unistd::getuid().as_raw());
        assert_eq!(meta.gid(), nix::unistd::getgid().as_raw());
        let root_meta = fs::symlink_metadata(&root).unwrap();
        assert_eq!(root_meta.mode() & 0o777, 0o710);
        assert_eq!(root_meta.gid(), nix::unistd::getgid().as_raw());
    }

    #[test]
    fn regular_file_at_leaf_is_refused_and_untouched() {
        let tmp = tempfile::tempdir().unwrap();
        let imposter = make_root(tmp.path()).join("api.socket");
        fs::write(&imposter, b"not a socket").unwrap();
        fs::set_permissions(&imposter, fs::Permissions::from_mode(0o600)).unwrap();

        let err = grant(tmp.path()).unwrap_err();
        assert!(
            matches!(err, GrantSocketError::Grant(GrantError::NotASocket)),
            "got {err:?}"
        );
        assert_eq!(
            fs::symlink_metadata(&imposter).unwrap().mode() & 0o777,
            0o600
        );
    }

    #[test]
    fn symlink_to_real_socket_at_leaf_is_refused_and_target_untouched() {
        let tmp = tempfile::tempdir().unwrap();
        let root = make_root(tmp.path());
        let outside = tmp.path().join("outside.sock");
        let _listener = UnixListener::bind(&outside).unwrap();
        fs::set_permissions(&outside, fs::Permissions::from_mode(0o700)).unwrap();
        symlink(&outside, root.join("api.socket")).unwrap();

        let err = grant(tmp.path()).unwrap_err();
        assert!(
            matches!(err, GrantSocketError::Grant(GrantError::NotASocket)),
            "got {err:?}"
        );
        assert_eq!(
            fs::symlink_metadata(&outside).unwrap().mode() & 0o777,
            0o700
        );
    }

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
        symlink(&sentinel, jail.join("firecracker")).unwrap();

        let res = grant(&jail);
        assert!(matches!(res, Err(GrantSocketError::Walk(_))), "got {res:?}");
        assert_eq!(
            fs::symlink_metadata(&outside_socket).unwrap().mode() & 0o777,
            0o700
        );
    }

    #[test]
    fn unreadable_jail_base_is_a_walk_error_not_missing() {
        if nix::unistd::geteuid().is_root() {
            return;
        }
        let tmp = tempfile::tempdir().unwrap();
        let jail = tmp.path().join("jail");
        fs::create_dir(&jail).unwrap();
        fs::set_permissions(&jail, fs::Permissions::from_mode(0o000)).unwrap();

        let res = grant(&jail);
        fs::set_permissions(&jail, fs::Permissions::from_mode(0o755)).unwrap();

        assert!(matches!(res, Err(GrantSocketError::Walk(_))), "got {res:?}");
    }
}
