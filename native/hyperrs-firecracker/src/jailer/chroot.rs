// SPDX-License-Identifier: MIT
//! Module responsible for preparing a `chroot` jail to the firecracker jailer.

use super::FIRECRACKER;
use crate::tun;
use crate::VmId;
use hyperrs_fs::dev::DeviceNode;
use hyperrs_fs::dir::{self, SafeDir};
use hyperrs_fs::file::{
    self, Any, FileType, IsBlockDevice, IsRegularFile, IsSocket, OpenFlags, Owner, SafeFile,
};
use hyperrs_fs::path::{
    self, IsAbsolute, SafePath, SafePathBuf, StrictComponent, StrictComponents,
};
use nix::errno::Errno;
use nix::sys::stat::Mode;
use std::fs::File;
use std::io::{self, Seek};
use std::os::unix::io::{AsFd, OwnedFd};
use std::path::PathBuf;
use thiserror::Error as ThisError;

/// The name of the kernel image in the chrooted directory.
const KERNEL_NAME: &StrictComponent = StrictComponent::from_static("vmlinux");

/// The name of the rootfs block device in the chroot jail.
const ROOTFS_NAME: &StrictComponent = StrictComponent::from_static("rootfs");

const EXEC_NAME: &StrictComponent = StrictComponent::from_static(FIRECRACKER);

/// The jail directory's own path.
const ROOT_NAME: &StrictComponent = StrictComponent::from_static("root");

/// The mode the `vmlinux` image is stored as in the chrooted jail.
const KERNEL_MODE: Mode = Mode::from_bits_truncate(0o444);

/// The mode for the `ROOTFS_NAME`.
const ROOTFS_MODE: Mode = Mode::from_bits_truncate(0o600);

/// The mode of directories created by this utility in the chrooted jail.
const DIR_MODE: Mode = Mode::from_bits_truncate(0o755);

/// Mode set on `ROOT_NAME`.
const JAIL_ROOT_MODE: Mode = Mode::from_bits_truncate(0o710);

/// Mode handed to the node: owner+group read/write, no world access.
const SOCKET_MODE: Mode = Mode::from_bits_truncate(0o660);

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
    #[error("file does not exist yet")]
    Missing,
    #[error("walking to the jail root: {0}")]
    Walk(#[source] file::ValidationError),
    #[error("not the expected file type (or is a symlink); refusing to touch it")]
    WrongType,
    #[error("opening the file: {0}")]
    Stat(#[source] file::ValidationError),
    #[error("chowning the file to the caller: {0}")]
    Chown(#[source] Errno),
    #[error("chmoding the file: {0}")]
    Chmod(#[source] Errno),
    #[error("chgrp-ing the jail root dir to the caller: {0}")]
    ChgrpRoot(#[source] Errno),
    #[error("chmoding the jail root dir for traversal: {0}")]
    ChmodRoot(#[source] Errno),
}

#[derive(Debug, ThisError)]
pub enum RemoveError {
    #[error("opening chroot parent: {0}")]
    Open(#[source] file::ValidationError),
    #[error("removing chroot: {0}")]
    Remove(#[source] dir::DirError),
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

/// The overal layout of the jail path. See [`JailLayout::new`].
pub struct JailLayout<'a> {
    base: &'a SafePath<IsAbsolute, StrictComponents>,
    id: &'a VmId,
}

impl<'a> JailLayout<'a> {
    /// Create a new filesystem layout from the given `base` directory and the VM id.
    ///
    /// This manages a directory of the layout.
    ///
    /// ```text
    /// <base>/
    ///   firecracker/
    ///     <id>/ <- this is what firecracker chroot's into
    ///       root/
    /// ```
    ///
    /// Please note that the firecracker jailer will create this directory layout, as opposed to
    /// this utility.
    pub fn new(base: &'a SafePath<IsAbsolute, StrictComponents>, id: &'a VmId) -> Self {
        Self { base, id }
    }

    pub fn base(&self) -> &'a SafePath<IsAbsolute, StrictComponents> {
        self.base
    }

    pub fn id(&self) -> &'a VmId {
        self.id
    }

    pub fn exec_dir(&self) -> SafePathBuf<IsAbsolute, StrictComponents> {
        self.base.join(EXEC_NAME)
    }

    pub fn chroot_dir(&self) -> SafePathBuf<IsAbsolute, StrictComponents> {
        self.exec_dir().join(self.id)
    }

    pub fn root(&self) -> SafePathBuf<IsAbsolute, StrictComponents> {
        self.chroot_dir().join(ROOT_NAME)
    }

    pub fn open_root(&self) -> Result<JailRoot, file::ValidationError> {
        SafeDir::open(&self.root(), OpenFlags::RDONLY).map(JailRoot)
    }

    /// Grant access to a socket `name` to the `owner`.
    pub fn grant_socket(&self, name: &StrictComponent, owner: Owner) -> Result<(), GrantError> {
        let root = match self.open_root() {
            Ok(root) => root,
            Err(file::ValidationError::Open(Errno::ENOENT)) => return Err(GrantError::Missing),
            Err(e) => return Err(GrantError::Walk(e)),
        };
        root.grant::<IsSocket>(name, owner, SOCKET_MODE)
    }

    /// Recursively remove the per-VM chroot `<base>/<exec>/<id>`, fd-relative
    /// after an `O_NOFOLLOW` walk from `base`. Idempotent on a missing target.
    pub fn remove(&self) -> Result<(), RemoveError> {
        let parent = match SafeDir::open(&self.exec_dir(), OpenFlags::RDONLY) {
            Ok(parent) => parent,
            Err(file::ValidationError::Open(Errno::ENOENT)) => return Ok(()),
            Err(e) => return Err(RemoveError::Open(e)),
        };
        match parent.rmdirat_recursive(self.id) {
            Ok(()) => Ok(()),
            Err(e) if e.errno() == Some(Errno::ENOENT) => Ok(()),
            Err(e) => Err(RemoveError::Remove(e)),
        }
    }
}

/// The root directory of the chroot jail.
pub struct JailRoot(SafeDir);

#[bon::bon]
impl JailRoot {
    #[builder(finish_fn = build)]
    pub fn builder(
        &self,
        #[builder(start_fn)] owner: Owner,
        kernel: &KernelImage,
        rootfs: &BlockDevice,
        #[builder(default)] tun: bool,
    ) -> Result<(), BuildError> {
        self.stage_kernel(kernel).map_err(BuildError::Kernel)?;
        self.add_rootfs(rootfs, owner).map_err(BuildError::Rootfs)?;

        if tun {
            self.add_tun(owner).map_err(BuildError::Tun)?;
        }

        Ok(())
    }

    /// Put the kernel image in the chroot jail.
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

    /// Add the rootfs block device into the chroot jail.
    pub fn add_rootfs<R, O>(
        &self,
        device: &SafeFile<IsBlockDevice, R, O>,
        owner: Owner,
    ) -> Result<(), dir::DirError> {
        let node = DeviceNode::<IsBlockDevice>::new(device.rdev()?, ROOTFS_MODE);
        self.0.make_device(ROOTFS_NAME, node, owner)?;
        Ok(())
    }

    /// TODO(markovejnovic): Remove this slop
    pub fn add_tun(&self, owner: Owner) -> Result<(), dir::DirError> {
        let net = self
            .0
            .ensure_dir(tun::DEV, DIR_MODE)?
            .ensure_dir(tun::NET, DIR_MODE)?;
        net.make_device(tun::NAME, tun::NODE, owner)?;
        Ok(())
    }

    /// Confirm that a path leaf `<name>`, under the jail, is the given [`FileType`] and then grant
    /// ownership to the given `owner`, under the given `mode.
    pub fn grant<T: FileType>(
        &self,
        name: &StrictComponent,
        owner: Owner,
        mode: Mode,
    ) -> Result<(), GrantError> {
        let file: SafeFile<T, Any, Any> = match self.0.openat(name, OpenFlags::PATH, Mode::empty())
        {
            Ok(file) => file,
            Err(file::ValidationError::Open(Errno::ENOENT)) => return Err(GrantError::Missing),
            Err(
                file::ValidationError::Open(Errno::ELOOP) | file::ValidationError::WrongFileType,
            ) => return Err(GrantError::WrongType),
            Err(e) => return Err(GrantError::Stat(e)),
        };

        file.chown(Some(owner.uid), Some(owner.gid))
            .map_err(GrantError::Chown)?;
        file.chmod(mode).map_err(GrantError::Chmod)?;

        self.0
            .chown(None, Some(owner.gid))
            .map_err(GrantError::ChgrpRoot)?;

        self.0
            .chmod(JAIL_ROOT_MODE)
            .map_err(GrantError::ChmodRoot)?;

        Ok(())
    }
}

type BlockDevice = SafeFile<IsBlockDevice, Any, Any>;

#[cfg(test)]
mod tests {
    use super::{GrantError, JailLayout, JailRoot, KernelError, KernelImage};
    use crate::VmId;
    use hyperrs_fs::file::Owner;
    use hyperrs_fs::file::{Any, IsBlockDevice, OpenFlags, SafeFile};
    use hyperrs_fs::path::{IsAbsolute, SafePathBuf, StrictComponent, StrictComponents};
    use hyperrs_fs::{dir, file};
    use nix::errno::Errno;
    use nix::sys::stat::{makedev, mknod, Mode, SFlag};
    use nix::unistd::{Gid, Uid};
    use proptest::prelude::*;
    use rstest::{fixture, rstest};
    use std::fs;
    use std::os::unix::fs::{symlink, FileTypeExt, MetadataExt, PermissionsExt};
    use std::os::unix::net::UnixListener;
    use std::path::{Path, PathBuf};
    use std::process::Command;
    use tempfile::TempDir;

    type Strict = SafePathBuf<IsAbsolute, StrictComponents>;

    fn strict(p: impl AsRef<Path>) -> Strict {
        p.as_ref().to_path_buf().try_into().unwrap()
    }

    fn is_root() -> bool {
        nix::unistd::geteuid().is_root()
    }

    fn owner(uid: u32, gid: u32) -> Owner {
        Owner {
            uid: Uid::from_raw(uid),
            gid: Gid::from_raw(gid),
        }
    }

    fn vm() -> VmId {
        "id".parse().unwrap()
    }

    #[fixture]
    fn tmp() -> TempDir {
        tempfile::tempdir().unwrap()
    }

    struct Jail {
        base: TempDir,
        root_dir: PathBuf,
    }

    impl Jail {
        fn base(&self) -> &Path {
            self.base.path()
        }

        fn open_root(&self) -> JailRoot {
            JailLayout::new(&strict(self.base()), &vm())
                .open_root()
                .unwrap()
        }

        fn kernel_source(&self, name: &str, contents: &[u8]) -> PathBuf {
            let src = self.base().join(name);
            fs::write(&src, contents).unwrap();
            src
        }
    }

    #[fixture]
    fn jail(tmp: TempDir) -> Jail {
        let root_dir = tmp.path().join("firecracker").join("id").join("root");
        fs::create_dir_all(&root_dir).unwrap();
        Jail {
            base: tmp,
            root_dir,
        }
    }

    #[rstest]
    fn layout_opens_the_jailer_root(jail: Jail) {
        assert!(JailLayout::new(&strict(jail.base()), &vm())
            .open_root()
            .is_ok());
    }

    proptest! {
        #[test]
        fn layout_root_is_exactly_firecracker_id_root_below_base(
            id in "[A-Za-z0-9][A-Za-z0-9-]{0,63}"
        ) {
            let base = strict("/srv/jails");
            let id: VmId = id.parse().unwrap();
            let root = JailLayout::new(&base, &id).root();
            let segments: Vec<_> = root
                .strip_base(&base)
                .unwrap()
                .segments()
                .map(|c| c.as_os_str().to_owned())
                .collect();
            prop_assert_eq!(
                segments,
                ["firecracker", &id.to_string(), "root"].map(std::ffi::OsString::from).to_vec()
            );
        }
    }

    struct Escape {
        _tmp: TempDir,
        jail: PathBuf,
        sentinel_root: PathBuf,
    }

    #[fixture]
    fn escape(tmp: TempDir) -> Escape {
        let jail = tmp.path().join("jail");
        fs::create_dir(&jail).unwrap();
        let sentinel = tmp.path().join("sentinel");
        let sentinel_root = sentinel.join("id").join("root");
        fs::create_dir_all(&sentinel_root).unwrap();
        symlink(&sentinel, jail.join("firecracker")).unwrap();
        Escape {
            _tmp: tmp,
            jail,
            sentinel_root,
        }
    }

    #[rstest]
    fn layout_refuses_symlinked_component(escape: Escape) {
        let err = JailLayout::new(&strict(&escape.jail), &vm())
            .open_root()
            .err();
        assert!(
            matches!(err, Some(file::ValidationError::Open(Errno::ELOOP))),
            "got {err:?}"
        );
    }

    #[rstest]
    fn kernel_the_caller_cannot_read_is_refused(tmp: TempDir) {
        if is_root() {
            eprintln!("SKIP kernel_the_caller_cannot_read_is_refused: root reads everything");
            return;
        }
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

    #[rstest]
    fn kernel_symlink_stages_its_target(jail: Jail) {
        let real = jail.kernel_source("vmlinux-6.1", b"real kernel");
        let link = jail.base().join("vmlinux");
        symlink(&real, &link).unwrap();

        jail.open_root()
            .stage_kernel(&KernelImage::open(&strict(&link)).unwrap())
            .unwrap();
        assert_eq!(
            fs::read(jail.root_dir.join("vmlinux")).unwrap(),
            b"real kernel"
        );
    }

    #[rstest]
    fn missing_kernel_is_a_resolve_error(tmp: TempDir) {
        let missing = tmp.path().join("nope");
        let err = KernelImage::open(&strict(&missing)).err();
        assert!(
            matches!(err, Some(KernelError::Resolve { .. })),
            "got {err:?}"
        );
    }

    #[rstest]
    fn stage_kernel_materializes_then_refuses_overwrite(jail: Jail) {
        let src = jail.kernel_source("vmlinux-src", b"\x7fELF fake kernel bytes");
        let root = jail.open_root();

        let kernel = KernelImage::open(&strict(&src)).unwrap();
        root.stage_kernel(&kernel).expect("first stage");
        assert_eq!(
            fs::read(jail.root_dir.join("vmlinux")).unwrap(),
            b"\x7fELF fake kernel bytes"
        );

        let err = root.stage_kernel(&kernel).unwrap_err();
        assert_eq!(err.errno(), Some(Errno::EEXIST), "got {err:?}");
    }

    #[rstest]
    fn stage_kernel_never_changes_the_source(jail: Jail) {
        let src = jail.kernel_source("vmlinux-src", b"kernel");
        let before = fs::metadata(&src).unwrap();

        let kernel = KernelImage::open(&strict(&src)).unwrap();
        jail.open_root().stage_kernel(&kernel).unwrap();

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

    #[rstest]
    fn add_rootfs_mirrors_the_device_as_root(jail: Jail) {
        if !is_root() {
            eprintln!("SKIP add_rootfs_mirrors_the_device: needs root for mknod/chown");
            return;
        }
        let Some(dev) = setup_loop(jail.base()) else {
            eprintln!("SKIP add_rootfs: losetup unavailable");
            return;
        };

        let root = jail.open_root();
        let res = SafeFile::<IsBlockDevice, Any, Any>::open(&strict(&dev), OpenFlags::PATH)
            .map_err(|e| e.to_string())
            .and_then(|device| {
                root.add_rootfs(&device, owner(12345, 12346))
                    .map_err(|e| e.to_string())
            });
        let dev_rdev = fs::metadata(&dev).map(|m| m.rdev());
        teardown_loop(&dev);
        res.expect("add_rootfs must succeed as root against a real device");

        let meta = fs::metadata(jail.root_dir.join("rootfs")).unwrap();
        assert!(meta.file_type().is_block_device());
        assert_eq!(meta.rdev(), dev_rdev.unwrap());
        assert_eq!((meta.uid(), meta.gid()), (12345, 12346));
        assert_eq!(meta.mode() & 0o777, 0o600);
    }

    #[rstest]
    fn add_tun_is_idempotent_as_root(jail: Jail) {
        if !is_root() {
            eprintln!("SKIP add_tun_is_idempotent: needs root for mknod/chown");
            return;
        }
        let root = jail.open_root();

        root.add_tun(owner(12345, 12346)).unwrap();
        root.add_tun(owner(12345, 12346)).unwrap();

        let meta = fs::metadata(jail.root_dir.join("dev/net/tun")).unwrap();
        assert!(meta.file_type().is_char_device());
        assert_eq!(meta.rdev(), makedev(10, 200));
        assert_eq!((meta.uid(), meta.gid()), (12345, 12346));
        assert_eq!(meta.mode() & 0o777, 0o666);
    }

    #[rstest]
    fn add_tun_refuses_a_preexisting_node_with_another_number_as_root(jail: Jail) {
        if !is_root() {
            eprintln!("SKIP add_tun_refuses_a_preexisting_node: needs root for mknod");
            return;
        }
        fs::create_dir_all(jail.root_dir.join("dev/net")).unwrap();
        let planted = jail.root_dir.join("dev/net/tun");
        mknod(
            &planted,
            SFlag::S_IFCHR,
            Mode::from_bits_truncate(0o666),
            makedev(1, 3),
        )
        .unwrap();

        let err = jail.open_root().add_tun(owner(12345, 12346)).unwrap_err();
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

    const API_SOCKET: &StrictComponent = StrictComponent::from_static("api.socket");

    fn grant(jail_base: &Path) -> Result<(), GrantError> {
        JailLayout::new(&strict(jail_base), &vm()).grant_socket(API_SOCKET, Owner::caller())
    }

    fn socket_with_mode(path: &Path, mode: u32) {
        UnixListener::bind(path).unwrap();
        fs::set_permissions(path, fs::Permissions::from_mode(mode)).unwrap();
    }

    fn mode_of(path: &Path) -> u32 {
        fs::symlink_metadata(path).unwrap().mode() & 0o777
    }

    #[rstest]
    fn grant_before_the_socket_exists_is_missing(
        tmp: TempDir,
        #[values(false, true)] create_root: bool,
    ) {
        if create_root {
            fs::create_dir_all(tmp.path().join("firecracker").join("id").join("root")).unwrap();
        }
        let res = grant(tmp.path());
        assert!(matches!(res, Err(GrantError::Missing)), "got {res:?}");
    }

    #[rstest]
    fn grant_hands_the_socket_over_and_opens_root_for_traversal(jail: Jail) {
        let socket = jail.root_dir.join("api.socket");
        socket_with_mode(&socket, 0o755);

        grant(jail.base()).expect("real socket must grant");

        let meta = fs::symlink_metadata(&socket).unwrap();
        assert_eq!(meta.mode() & 0o777, 0o660);
        assert_eq!(meta.uid(), nix::unistd::getuid().as_raw());
        assert_eq!(meta.gid(), nix::unistd::getgid().as_raw());
        let root_meta = fs::symlink_metadata(&jail.root_dir).unwrap();
        assert_eq!(root_meta.mode() & 0o777, 0o710);
        assert_eq!(root_meta.gid(), nix::unistd::getgid().as_raw());
    }

    fn plant_regular_file(jail: &Jail) -> PathBuf {
        let imposter = jail.root_dir.join("api.socket");
        fs::write(&imposter, b"not a socket").unwrap();
        fs::set_permissions(&imposter, fs::Permissions::from_mode(0o600)).unwrap();
        imposter
    }

    fn plant_symlink_to_outside_socket(jail: &Jail) -> PathBuf {
        let outside = jail.base().join("outside.sock");
        socket_with_mode(&outside, 0o600);
        symlink(&outside, jail.root_dir.join("api.socket")).unwrap();
        outside
    }

    #[rstest]
    #[case::regular_file(plant_regular_file)]
    #[case::symlink_to_outside_socket(plant_symlink_to_outside_socket)]
    fn grant_refuses_a_non_socket_leaf_and_leaves_it_untouched(
        jail: Jail,
        #[case] plant: fn(&Jail) -> PathBuf,
    ) {
        let untouched = plant(&jail);

        let err = grant(jail.base()).unwrap_err();
        assert!(matches!(err, GrantError::WrongType), "got {err:?}");
        assert_eq!(mode_of(&untouched), 0o600);
    }

    #[rstest]
    fn grant_through_a_symlinked_component_does_not_escape(escape: Escape) {
        let outside_socket = escape.sentinel_root.join("api.socket");
        socket_with_mode(&outside_socket, 0o700);

        let res = grant(&escape.jail);
        assert!(matches!(res, Err(GrantError::Walk(_))), "got {res:?}");
        assert_eq!(mode_of(&outside_socket), 0o700);
    }

    #[rstest]
    fn grant_on_an_unreadable_jail_base_is_a_walk_error_not_missing(tmp: TempDir) {
        if is_root() {
            return;
        }
        let jail = tmp.path().join("jail");
        fs::create_dir(&jail).unwrap();
        fs::set_permissions(&jail, fs::Permissions::from_mode(0o000)).unwrap();

        let res = grant(&jail);
        fs::set_permissions(&jail, fs::Permissions::from_mode(0o755)).unwrap();

        assert!(matches!(res, Err(GrantError::Walk(_))), "got {res:?}");
    }

    #[rstest]
    fn remove_of_a_missing_chroot_is_ok(tmp: TempDir) {
        JailLayout::new(&strict(tmp.path()), &vm())
            .remove()
            .expect("missing chroot must be Ok");
    }

    #[rstest]
    fn remove_deletes_the_chroot_tree_and_spares_siblings(jail: Jail) {
        fs::write(jail.root_dir.join("vmlinux"), b"kernel").unwrap();
        let exec = jail.base().join("firecracker");
        let sibling = exec.join("other");
        fs::create_dir_all(&sibling).unwrap();

        JailLayout::new(&strict(jail.base()), &vm())
            .remove()
            .unwrap();
        assert!(!exec.join("id").exists(), "victim chroot must be gone");
        assert!(sibling.exists(), "sibling chroot must survive");
    }

    #[rstest]
    fn remove_through_a_symlinked_exec_component_does_not_escape(escape: Escape) {
        let keep = escape.sentinel_root.join("keep.txt");
        fs::write(&keep, b"do not delete").unwrap();

        let _ = JailLayout::new(&strict(&escape.jail), &vm()).remove();
        assert!(keep.exists());
    }
}
