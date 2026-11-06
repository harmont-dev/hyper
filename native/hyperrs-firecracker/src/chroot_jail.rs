// SPDX-License-Identifier: MIT
//! Module responsible for preparing a `chroot` jail to the firecracker jailer.

use crate::id::JailOwner;
use crate::jailer::VmId;
use crate::tun;
use hyperrs_fs::dev::DeviceNode;
use hyperrs_fs::dir::{self, SafeDir};
use hyperrs_fs::file::{self, Any, IsBlockDevice, IsRegularFile, IsSocket, OpenFlags, SafeFile};
use hyperrs_fs::path::{
    self, IsAbsolute, SafePath, SafePathBuf, StrictComponent, StrictComponents,
};
use nix::errno::Errno;
use nix::sys::stat::Mode;
use nix::unistd::{getgid, getuid};
use std::fs::File;
use std::io::{self, Seek};
use std::os::unix::io::{AsFd, OwnedFd};
use std::path::PathBuf;
use thiserror::Error as ThisError;

/// The name of the kernel image in the chrooted directory.
const KERNEL_NAME: &StrictComponent = StrictComponent::from_static("vmlinux");

/// The name of the rootfs block device in the chroot jail.
const ROOTFS_NAME: &StrictComponent = StrictComponent::from_static("rootfs");

/// The jail directory's own path.
const ROOT_NAME: &StrictComponent = StrictComponent::from_static("root");

/// The mode the `vmlinux` image is stored as in the chrooted jail.
const KERNEL_MODE: Mode = Mode::from_bits_truncate(0o444);

/// The mode for the `ROOTFS_NAME`.
const ROOTFS_MODE: Mode = Mode::from_bits_truncate(0o600);

/// The mode of directories created by this utility in the chrooted jail.
const DIR_MODE: Mode = Mode::from_bits_truncate(0o755);

/// Mode handed to the node: owner+group read/write, no world access.
const SOCKET_MODE: Mode = Mode::from_bits_truncate(0o660);

/// Mode set on `ROOT_NAME`.
const JAIL_ROOT_MODE: Mode = Mode::from_bits_truncate(0o710);

#[derive(Debug, ThisError)]
pub enum OpenError {
    #[error(transparent)]
    Base(#[from] path::RelativeError),
    #[error("jail root must be exactly <exec>/<vm id>/root below the jail base: {0:?}")]
    Shape(PathBuf),
    #[error("opening jail root: {0}")]
    Open(#[from] file::ValidationError),
}

#[derive(Debug, ThisError)]
pub enum KernelError {
    #[error("resolving kernel source {path:?}: {source}")]
    Resolve {
        path: PathBuf,
        #[source]
        source: io::Error,
    },
    #[error(transparent)]
    Path(#[from] path::ValidationError),
    #[error("opening kernel source {path:?}: {source}")]
    Open {
        path: PathBuf,
        #[source]
        source: file::ValidationError,
    },
}

#[derive(Debug, ThisError)]
pub enum BuildError {
    #[error("staging kernel: {0}")]
    Kernel(#[source] dir::DirError),
    #[error("creating rootfs node: {0}")]
    Rootfs(#[source] dir::DirError),
    #[error("creating /dev/net/tun: {0}")]
    Tun(#[source] dir::DirError),
}

#[derive(Debug, ThisError)]
pub enum GrantError {
    #[error("socket does not exist yet")]
    Missing,
    #[error("not a socket (or is a symlink); refusing to touch it")]
    NotASocket,
    #[error("statting the socket: {0}")]
    Stat(#[source] file::ValidationError),
    #[error("chowning the socket to the caller: {0}")]
    Chown(#[source] Errno),
    #[error("chmoding the socket: {0}")]
    Chmod(#[source] Errno),
    #[error("chgrp-ing the jail root dir to the caller: {0}")]
    ChgrpRoot(#[source] Errno),
    #[error("chmoding the jail root dir for traversal: {0}")]
    ChmodRoot(#[source] Errno),
}

/// Kernel image [`SafeFile`] to be loaded into the firecracker chroot jail.
pub struct KernelImage(SafeFile<IsRegularFile, Any, Any>);

impl KernelImage {
    pub fn open(path: &SafePath<IsAbsolute, StrictComponents>) -> Result<Self, KernelError> {
        let real =
            std::fs::canonicalize(path.as_path()).map_err(|source| KernelError::Resolve {
                path: path.as_path().to_path_buf(),
                source,
            })?;
        let real: SafePathBuf<IsAbsolute, StrictComponents> = real.try_into()?;
        let file =
            SafeFile::open(&real, OpenFlags::RDONLY).map_err(|source| KernelError::Open {
                path: real.as_path().to_path_buf(),
                source,
            })?;
        Ok(Self(file))
    }
}

pub struct JailRoot(SafeDir);

impl JailRoot {
    pub fn open(
        jail_base: &SafePath<IsAbsolute, StrictComponents>,
        path: &SafePath<IsAbsolute, StrictComponents>,
    ) -> Result<Self, OpenError> {
        let mut segments = path.strip_base(jail_base)?.segments();
        let shape_ok = match (
            segments.next(),
            segments.next(),
            segments.next(),
            segments.next(),
        ) {
            (Some(_exec), Some(id), Some(root), None) => {
                root == ROOT_NAME
                    && id
                        .as_os_str()
                        .to_str()
                        .is_some_and(|id| id.parse::<VmId>().is_ok())
            }
            _ => false,
        };
        if !shape_ok {
            return Err(OpenError::Shape(path.as_path().to_path_buf()));
        }
        Ok(Self(SafeDir::open(path, OpenFlags::RDONLY)?))
    }

    pub fn builder(&self, owner: JailOwner) -> JailBuilder<'_, Unset, Unset> {
        JailBuilder {
            root: self,
            owner,
            kernel: Unset,
            rootfs: Unset,
            tun: false,
        }
    }

    pub fn stage_kernel(&self, kernel: &KernelImage) -> Result<(), dir::DirError> {
        self.0
            .linkat(&kernel.0, KERNEL_NAME)
            .or_else(|errno| -> Result<(), dir::DirError> {
                if errno != Errno::EXDEV {
                    return Err(errno.into());
                }
                let dest = self.0.mkfileat(KERNEL_NAME, KERNEL_MODE)?;
                let mut src = File::from(kernel.0.as_fd().try_clone_to_owned()?);
                src.rewind()?;
                io::copy(&mut src, &mut File::from(OwnedFd::from(dest)))?;
                Ok(())
            })
    }

    pub fn add_rootfs<R, O>(
        &self,
        device: &SafeFile<IsBlockDevice, R, O>,
        owner: JailOwner,
    ) -> Result<(), dir::DirError> {
        let node = DeviceNode::<IsBlockDevice>::new(device.rdev()?, ROOTFS_MODE);
        self.0.make_device(ROOTFS_NAME, node, owner.into())?;
        Ok(())
    }

    pub fn add_tun(&self, owner: JailOwner) -> Result<(), dir::DirError> {
        let net = self
            .0
            .ensure_dir(tun::DEV, DIR_MODE)?
            .ensure_dir(tun::NET, DIR_MODE)?;
        net.make_device(tun::NAME, tun::NODE, owner.into())?;
        Ok(())
    }

    /// Stat `leaf` under the jail root (`AT_SYMLINK_NOFOLLOW`), verify it is a real
    /// socket (`S_IFSOCK`; a symlink reports `S_IFLNK` and is refused), then chown it
    /// to the caller and chmod `0660`. Also open the jail root for the caller's
    /// group to traverse (chgrp'd to the caller, chmod'd `0710`) so the node can
    /// reach the socket even though the jailer left `root` at `0700`. Returns
    /// `Pending` if `leaf` is not yet present (`ENOENT`).
    pub fn grant_to_caller(&self, leaf: &StrictComponent) -> Result<(), GrantError> {
        let sock: SafeFile<IsSocket, Any, Any> =
            match self.0.openat(leaf, OpenFlags::PATH, Mode::empty()) {
                Ok(sock) => sock,
                Err(file::ValidationError::Open(Errno::ENOENT)) => return Err(GrantError::Missing),
                Err(
                    file::ValidationError::Open(Errno::ELOOP)
                    | file::ValidationError::WrongFileType,
                ) => return Err(GrantError::NotASocket),
                Err(e) => return Err(GrantError::Stat(e)),
            };
        sock.chown(Some(getuid()), Some(getgid()))
            .map_err(GrantError::Chown)?;
        sock.chmod(SOCKET_MODE).map_err(GrantError::Chmod)?;
        self.0
            .chown(None, Some(getgid()))
            .map_err(GrantError::ChgrpRoot)?;
        self.0
            .chmod(JAIL_ROOT_MODE)
            .map_err(GrantError::ChmodRoot)?;
        Ok(())
    }
}

pub struct Unset;

type BlockDevice = SafeFile<IsBlockDevice, Any, Any>;

pub struct JailBuilder<'a, K, D> {
    root: &'a JailRoot,
    owner: JailOwner,
    kernel: K,
    rootfs: D,
    tun: bool,
}

impl<'a, D> JailBuilder<'a, Unset, D> {
    pub fn kernel(self, kernel: &'a KernelImage) -> JailBuilder<'a, &'a KernelImage, D> {
        JailBuilder {
            root: self.root,
            owner: self.owner,
            kernel,
            rootfs: self.rootfs,
            tun: self.tun,
        }
    }
}

impl<'a, K> JailBuilder<'a, K, Unset> {
    pub fn rootfs(self, device: &'a BlockDevice) -> JailBuilder<'a, K, &'a BlockDevice> {
        JailBuilder {
            root: self.root,
            owner: self.owner,
            kernel: self.kernel,
            rootfs: device,
            tun: self.tun,
        }
    }
}

impl<K, D> JailBuilder<'_, K, D> {
    pub fn tun(self, enabled: bool) -> Self {
        Self {
            tun: enabled,
            ..self
        }
    }
}

impl<'a> JailBuilder<'a, &'a KernelImage, &'a BlockDevice> {
    pub fn build(self) -> Result<(), BuildError> {
        self.root
            .stage_kernel(self.kernel)
            .map_err(BuildError::Kernel)?;
        self.root
            .add_rootfs(self.rootfs, self.owner)
            .map_err(BuildError::Rootfs)?;
        if self.tun {
            self.root.add_tun(self.owner).map_err(BuildError::Tun)?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::{JailRoot, KernelError, KernelImage, OpenError};
    use crate::id::{JailOwner, UidGidRange};
    use hyperrs_fs::file::{Any, IsBlockDevice, OpenFlags, SafeFile};
    use hyperrs_fs::path::{IsAbsolute, RelativeError, SafePathBuf, StrictComponents};
    use hyperrs_fs::{dir, file};
    use nix::errno::Errno;
    use nix::sys::stat::{makedev, mknod, Mode, SFlag};
    use std::fs;
    use std::os::unix::fs::{symlink, FileTypeExt, MetadataExt, PermissionsExt};
    use std::path::{Path, PathBuf};
    use std::process::Command;

    type Strict = SafePathBuf<IsAbsolute, StrictComponents>;

    fn strict(p: impl AsRef<Path>) -> Strict {
        p.as_ref().to_path_buf().try_into().unwrap()
    }

    fn is_root() -> bool {
        nix::unistd::geteuid().is_root()
    }

    fn owner(uid: u32, gid: u32) -> JailOwner {
        let range = UidGidRange::try_from([uid.min(gid), uid.max(gid)]).unwrap();
        JailOwner {
            uid: range.uid(uid).unwrap(),
            gid: range.gid(gid).unwrap(),
        }
    }

    fn jail_root(jail_base: &Path) -> PathBuf {
        let root = jail_base.join("exec").join("id").join("root");
        fs::create_dir_all(&root).unwrap();
        root
    }

    #[test]
    fn jail_root_opens_exec_id_root() {
        let tmp = tempfile::tempdir().unwrap();
        let root = jail_root(tmp.path());
        assert!(JailRoot::open(&strict(tmp.path()), &strict(root)).is_ok());
    }

    #[test]
    fn jail_root_refuses_other_shapes() {
        let tmp = tempfile::tempdir().unwrap();
        let base = tmp.path();
        for rel in [
            "exec",
            "exec/id",
            "exec/id/root/extra",
            "exec/id/notroot",
            "exec/a_b/root",
            "exec/-id/root",
        ] {
            let err = JailRoot::open(&strict(base), &strict(base.join(rel))).err();
            assert!(
                matches!(err, Some(OpenError::Shape(_))),
                "{rel}: got {err:?}"
            );
        }
    }

    #[test]
    fn jail_root_refuses_path_outside_base() {
        let tmp = tempfile::tempdir().unwrap();
        let base = tmp.path().join("jail");
        let outside = tmp.path().join("elsewhere/exec/id/root");
        let err = JailRoot::open(&strict(&base), &strict(outside)).err();
        assert!(
            matches!(err, Some(OpenError::Base(RelativeError::NotUnderBase))),
            "got {err:?}"
        );
    }

    // A symlinked component is not followed (O_NOFOLLOW): open must fail.
    #[test]
    fn jail_root_refuses_symlinked_component() {
        let tmp = tempfile::tempdir().unwrap();
        let jail = tmp.path().join("jail");
        fs::create_dir(&jail).unwrap();
        let real_exec = tmp.path().join("real-exec");
        fs::create_dir_all(real_exec.join("id").join("root")).unwrap();
        symlink(&real_exec, jail.join("exec")).unwrap();

        let err = JailRoot::open(&strict(&jail), &strict(jail.join("exec/id/root"))).err();
        assert!(matches!(err, Some(OpenError::Open(_))), "got {err:?}");
    }

    #[test]
    fn kernel_the_caller_cannot_read_is_refused() {
        if is_root() {
            eprintln!("SKIP kernel_the_caller_cannot_read_is_refused: root reads everything");
            return;
        }
        let tmp = tempfile::tempdir().unwrap();
        let src = tmp.path().join("vmlinux");
        fs::write(&src, b"kernel").unwrap();
        fs::set_permissions(&src, fs::Permissions::from_mode(0o000)).unwrap();

        let err = KernelImage::open(&strict(&src)).err();
        assert!(
            matches!(
                err,
                Some(KernelError::Open {
                    source: file::ValidationError::Open(Errno::EACCES),
                    ..
                })
            ),
            "got {err:?}"
        );
    }

    #[test]
    fn kernel_symlink_stages_its_target() {
        let tmp = tempfile::tempdir().unwrap();
        let base = tmp.path();
        let root_dir = jail_root(base);
        let real = base.join("vmlinux-6.1");
        fs::write(&real, b"real kernel").unwrap();
        let link = base.join("vmlinux");
        symlink(&real, &link).unwrap();

        let root = JailRoot::open(&strict(base), &strict(&root_dir)).unwrap();
        root.stage_kernel(&KernelImage::open(&strict(&link)).unwrap())
            .unwrap();
        assert_eq!(fs::read(root_dir.join("vmlinux")).unwrap(), b"real kernel");
    }

    #[test]
    fn missing_kernel_is_a_resolve_error() {
        let tmp = tempfile::tempdir().unwrap();
        let missing = tmp.path().join("nope");
        let err = KernelImage::open(&strict(&missing)).err();
        assert!(
            matches!(err, Some(KernelError::Resolve { .. })),
            "got {err:?}"
        );
    }

    #[test]
    fn stage_kernel_materializes_then_refuses_overwrite() {
        let tmp = tempfile::tempdir().unwrap();
        let base = tmp.path();
        let root_dir = jail_root(base);
        let src = base.join("vmlinux-src");
        fs::write(&src, b"\x7fELF fake kernel bytes").unwrap();
        let root = JailRoot::open(&strict(base), &strict(&root_dir)).unwrap();

        let kernel = KernelImage::open(&strict(&src)).unwrap();
        root.stage_kernel(&kernel).expect("first stage");
        assert_eq!(
            fs::read(root_dir.join("vmlinux")).unwrap(),
            b"\x7fELF fake kernel bytes"
        );

        let err = root.stage_kernel(&kernel).unwrap_err();
        assert_eq!(err.errno(), Some(Errno::EEXIST), "got {err:?}");
    }

    #[test]
    fn stage_kernel_never_changes_the_source() {
        let tmp = tempfile::tempdir().unwrap();
        let base = tmp.path();
        let root_dir = jail_root(base);
        let src = base.join("vmlinux-src");
        fs::write(&src, b"kernel").unwrap();
        let before = fs::metadata(&src).unwrap();

        let root = JailRoot::open(&strict(base), &strict(&root_dir)).unwrap();
        let kernel = KernelImage::open(&strict(&src)).unwrap();
        root.stage_kernel(&kernel).unwrap();

        let after = fs::metadata(&src).unwrap();
        assert_eq!(
            (after.uid(), after.gid(), after.mode()),
            (before.uid(), before.gid(), before.mode())
        );
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
            return None;
        }
        Some(PathBuf::from(dev))
    }

    fn teardown_loop(dev: &Path) {
        let _ = Command::new("losetup").arg("-d").arg(dev).output();
    }

    #[test]
    fn add_rootfs_mirrors_the_device_as_root() {
        if !is_root() {
            eprintln!("SKIP add_rootfs_mirrors_the_device: needs root for mknod/chown");
            return;
        }
        let tmp = tempfile::tempdir().unwrap();
        let base = tmp.path();
        let root_dir = jail_root(base);

        let Some(dev) = setup_loop(base) else {
            eprintln!("SKIP add_rootfs: losetup unavailable");
            return;
        };

        let root = JailRoot::open(&strict(base), &strict(&root_dir)).unwrap();
        let res = SafeFile::<IsBlockDevice, Any, Any>::open(&strict(&dev), OpenFlags::PATH)
            .map_err(|e| e.to_string())
            .and_then(|device| {
                root.add_rootfs(&device, owner(12345, 12346))
                    .map_err(|e| e.to_string())
            });
        let dev_rdev = fs::metadata(&dev).map(|m| m.rdev());
        teardown_loop(&dev);
        res.expect("add_rootfs must succeed as root against a real device");

        let meta = fs::metadata(root_dir.join("rootfs")).unwrap();
        assert!(meta.file_type().is_block_device());
        assert_eq!(meta.rdev(), dev_rdev.unwrap());
        assert_eq!((meta.uid(), meta.gid()), (12345, 12346));
        assert_eq!(meta.mode() & 0o777, 0o600);
    }

    #[test]
    fn add_tun_is_idempotent_as_root() {
        if !is_root() {
            eprintln!("SKIP add_tun_is_idempotent: needs root for mknod/chown");
            return;
        }
        let tmp = tempfile::tempdir().unwrap();
        let root_dir = jail_root(tmp.path());
        let root = JailRoot::open(&strict(tmp.path()), &strict(&root_dir)).unwrap();

        root.add_tun(owner(12345, 12346)).unwrap();
        root.add_tun(owner(12345, 12346)).unwrap();

        let meta = fs::metadata(root_dir.join("dev/net/tun")).unwrap();
        assert!(meta.file_type().is_char_device());
        assert_eq!(meta.rdev(), makedev(10, 200));
        assert_eq!((meta.uid(), meta.gid()), (12345, 12346));
        assert_eq!(meta.mode() & 0o777, 0o666);
    }

    #[test]
    fn add_tun_refuses_a_preexisting_node_with_another_number_as_root() {
        if !is_root() {
            eprintln!("SKIP add_tun_refuses_a_preexisting_node: needs root for mknod");
            return;
        }
        let tmp = tempfile::tempdir().unwrap();
        let root_dir = jail_root(tmp.path());
        fs::create_dir_all(root_dir.join("dev/net")).unwrap();
        let planted = root_dir.join("dev/net/tun");
        mknod(
            &planted,
            SFlag::S_IFCHR,
            Mode::from_bits_truncate(0o666),
            makedev(1, 3),
        )
        .unwrap();
        let root = JailRoot::open(&strict(tmp.path()), &strict(&root_dir)).unwrap();

        let err = root.add_tun(owner(12345, 12346)).unwrap_err();
        assert!(
            matches!(err, dir::DirError::DeviceMismatch { .. }),
            "got {err:?}"
        );
        assert_eq!(
            fs::metadata(&planted).unwrap().uid(),
            0,
            "planted node must not be chowned"
        );
    }
}
