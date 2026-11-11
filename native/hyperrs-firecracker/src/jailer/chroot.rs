// SPDX-License-Identifier: MIT
//! Module responsible for preparing a `chroot` jail to the firecracker jailer.

use super::FIRECRACKER;
use crate::VmId;
use hyperrs_fs::dev::DeviceNode;
use hyperrs_fs::dir::{self, SafeDir};
use hyperrs_fs::file::{
    self, Any, FileType, IsBlockDevice, IsRegularFile, IsSocket, OpenFlags, Owner,
    OwnerOnlyWritable, SafeFile,
};
use hyperrs_fs::path::{
    self, IsAbsolute, SafePath, SafePathBuf, StrictComponent, StrictComponents,
};
use nix::errno::Errno;
use nix::sys::stat::{fstat, Mode};
use nix::unistd::{getuid, Uid};
use std::fs::File;
use std::io::{self, Seek};
use std::os::unix::io::{AsFd, AsRawFd, OwnedFd};
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
    #[error("stat-ing kernel source {path:?}: {source}")]
    Stat {
        path: PathBuf,
        #[source]
        source: Errno,
    },
    #[error("kernel source {path:?} is owned by uid {uid}; only root or the caller may own it")]
    Owner { path: PathBuf, uid: Uid },
}

#[derive(Debug, ThisError)]
pub enum BuildError {
    #[error("staging kernel: {0}")]
    Kernel(#[source] dir::DirError),
    #[error("creating rootfs node: {0}")]
    Rootfs(#[source] dir::DirError),
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
pub struct KernelImage(SafeFile<IsRegularFile, Any, OwnerOnlyWritable>);

impl KernelImage {
    pub fn open(path: &SafePath<IsAbsolute, StrictComponents>) -> Result<Self, KernelError> {
        let real =
            std::fs::canonicalize(path.as_path()).map_err(|source| KernelError::Resolve {
                path: path.as_path().to_path_buf(),
                source,
            })?;
        let real: SafePathBuf<IsAbsolute, StrictComponents> = real.try_into()?;
        let file: SafeFile<IsRegularFile, Any, OwnerOnlyWritable> =
            SafeFile::open(&real, OpenFlags::RDONLY).map_err(|source| KernelError::Open {
                path: real.as_path().to_path_buf(),
                source,
            })?;
        let uid = fstat(file.as_raw_fd())
            .map(|stat| Uid::from_raw(stat.st_uid))
            .map_err(|source| KernelError::Stat {
                path: real.as_path().to_path_buf(),
                source,
            })?;
        if !uid.is_root() && uid != getuid() {
            return Err(KernelError::Owner {
                path: real.as_path().to_path_buf(),
                uid,
            });
        }
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

    pub fn create_root(&self) -> Result<JailRoot, dir::DirError> {
        let base: SafeDir = SafeFile::open(self.base, OpenFlags::RDONLY)?;
        base.ensure_dir(EXEC_NAME, DIR_MODE)?
            .ensure_dir(self.id, DIR_MODE)?
            .ensure_dir(ROOT_NAME, DIR_MODE)
            .map(JailRoot)
    }

    /// Grant access to a socket `name` to the `owner`.
    pub fn grant_socket(
        &self,
        name: &StrictComponent,
        owner: Owner,
    ) -> Result<SafeFile<IsSocket, Any, Any>, GrantError> {
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
    ) -> Result<(), BuildError> {
        self.stage_kernel(kernel).map_err(BuildError::Kernel)?;
        self.add_rootfs(rootfs, owner).map_err(BuildError::Rootfs)?;
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

    /// Confirm that a path leaf `<name>`, under the jail, is the given [`FileType`] and then grant
    /// ownership to the given `owner`, under the given `mode.
    pub fn grant<T: FileType>(
        &self,
        name: &StrictComponent,
        owner: Owner,
        mode: Mode,
    ) -> Result<SafeFile<T, Any, Any>, GrantError> {
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

        Ok(file)
    }
}

type BlockDevice = SafeFile<IsBlockDevice, Any, Any>;

#[cfg(test)]
mod tests {
    use super::{GrantError, JailLayout, JailRoot, KernelError, KernelImage};
    use crate::VmId;
    use assert_fs::fixture::ChildPath;
    use assert_fs::prelude::*;
    use assert_fs::TempDir;
    use hyperrs_fs::file;
    use hyperrs_fs::file::Owner;
    use hyperrs_fs::file::{Any, IsBlockDevice, OpenFlags, SafeFile};
    use hyperrs_fs::path::{IsAbsolute, SafePathBuf, StrictComponent, StrictComponents};
    use nix::errno::Errno;
    use nix::unistd::{Gid, Uid};
    use predicates::prelude::*;
    use pretty_assertions::assert_eq;
    use proptest::prelude::*;
    use rstest::{fixture, rstest};
    use std::assert_matches;
    use std::fs;
    use std::os::unix::fs::{FileTypeExt, MetadataExt, PermissionsExt};
    use std::os::unix::net::UnixListener;
    use std::path::{Path, PathBuf};
    use std::process::Command;
    use test_strategy::proptest;

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
        TempDir::new().unwrap()
    }

    struct Jail {
        base: TempDir,
        root_dir: ChildPath,
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

        fn kernel_source(&self, name: &str, contents: &str) -> ChildPath {
            let src = self.base.child(name);
            src.write_str(contents).unwrap();
            src
        }
    }

    #[fixture]
    fn jail(tmp: TempDir) -> Jail {
        let root_dir = tmp.child("firecracker/id/root");
        root_dir.create_dir_all().unwrap();
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

    #[proptest]
    fn layout_root_is_exactly_firecracker_id_root_below_base(
        #[strategy("[A-Za-z0-9][A-Za-z0-9-]{0,63}")] id: String,
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
            ["firecracker", &id.to_string(), "root"]
                .map(std::ffi::OsString::from)
                .to_vec()
        );
    }

    struct Escape {
        _tmp: TempDir,
        jail: ChildPath,
        sentinel_root: ChildPath,
    }

    #[fixture]
    fn escape(tmp: TempDir) -> Escape {
        let jail = tmp.child("jail");
        jail.create_dir_all().unwrap();
        let sentinel_root = tmp.child("sentinel/id/root");
        sentinel_root.create_dir_all().unwrap();
        jail.child("firecracker")
            .symlink_to_dir(tmp.child("sentinel"))
            .unwrap();
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
        assert_matches!(err, Some(file::ValidationError::Open(Errno::ELOOP)));
    }

    #[rstest]
    fn kernel_the_caller_cannot_read_is_refused(tmp: TempDir) {
        if is_root() {
            eprintln!("SKIP kernel_the_caller_cannot_read_is_refused: root reads everything");
            return;
        }
        let src = tmp.child("vmlinux");
        src.write_str("kernel").unwrap();
        fs::set_permissions(&src, fs::Permissions::from_mode(0o000)).unwrap();

        let err = KernelImage::open(&strict(&src)).err();
        assert_matches!(
            err,
            Some(KernelError::Open {
                source: file::ValidationError::Open(Errno::EACCES),
                ..
            })
        );
    }

    #[rstest]
    fn kernel_symlink_stages_its_target(jail: Jail) {
        let real = jail.kernel_source("vmlinux-6.1", "real kernel");
        let link = jail.base.child("vmlinux");
        link.symlink_to_file(&real).unwrap();

        jail.open_root()
            .stage_kernel(&KernelImage::open(&strict(&link)).unwrap())
            .unwrap();
        jail.root_dir.child("vmlinux").assert("real kernel");
    }

    #[rstest]
    fn missing_kernel_is_a_resolve_error(tmp: TempDir) {
        let err = KernelImage::open(&strict(tmp.child("nope"))).err();
        assert_matches!(err, Some(KernelError::Resolve { .. }));
    }

    #[rstest]
    #[case::group_writable(0o664)]
    #[case::other_writable(0o646)]
    #[case::world_writable(0o666)]
    fn kernel_writable_by_group_or_other_is_refused(tmp: TempDir, #[case] mode: u32) {
        let src = tmp.child("vmlinux");
        src.write_str("kernel").unwrap();
        fs::set_permissions(&src, fs::Permissions::from_mode(mode)).unwrap();

        let err = KernelImage::open(&strict(&src)).err();
        assert_matches!(
            err,
            Some(KernelError::Open {
                source: file::ValidationError::GroupOrOtherWritable,
                ..
            })
        );
    }

    #[rstest]
    #[case::jail_uid(900_001, Some(900_001))]
    #[case::root_owned(0, None)]
    fn kernel_owned_by_neither_root_nor_the_caller_is_refused_as_root(
        tmp: TempDir,
        #[case] uid: u32,
        #[case] refused_uid: Option<u32>,
    ) {
        if !is_root() {
            eprintln!("SKIP kernel_owned_by_neither_root_nor_the_caller_is_refused_as_root: needs root to chown");
            return;
        }
        let src = tmp.child("vmlinux");
        src.write_str("kernel").unwrap();
        fs::set_permissions(&src, fs::Permissions::from_mode(0o644)).unwrap();
        std::os::unix::fs::chown(&src, Some(uid), Some(uid)).unwrap();

        let got = KernelImage::open(&strict(&src)).err().map(|e| match e {
            KernelError::Owner { uid, .. } => uid.as_raw(),
            other => panic!("expected an owner refusal, got {other:?}"),
        });
        assert_eq!(got, refused_uid);
    }

    #[rstest]
    fn stage_kernel_materializes_then_refuses_overwrite(jail: Jail) {
        let src = jail.kernel_source("vmlinux-src", "\x7fELF fake kernel bytes");
        let root = jail.open_root();

        let kernel = KernelImage::open(&strict(&src)).unwrap();
        root.stage_kernel(&kernel).expect("first stage");
        jail.root_dir
            .child("vmlinux")
            .assert("\x7fELF fake kernel bytes");

        let err = root.stage_kernel(&kernel).unwrap_err();
        assert_eq!(err.errno(), Some(Errno::EEXIST), "got {err:?}");
    }

    #[rstest]
    fn stage_kernel_never_changes_the_source(jail: Jail) {
        let src = jail.kernel_source("vmlinux-src", "kernel");
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

    const API_SOCKET: &StrictComponent = StrictComponent::from_static("api.socket");

    fn grant(jail_base: &Path) -> Result<(), GrantError> {
        JailLayout::new(&strict(jail_base), &vm())
            .grant_socket(API_SOCKET, Owner::caller())
            .map(drop)
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
            tmp.child("firecracker/id/root").create_dir_all().unwrap();
        }
        assert_matches!(grant(tmp.path()), Err(GrantError::Missing));
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
        let imposter = jail.root_dir.child("api.socket");
        imposter.write_str("not a socket").unwrap();
        fs::set_permissions(&imposter, fs::Permissions::from_mode(0o600)).unwrap();
        imposter.to_path_buf()
    }

    fn plant_symlink_to_outside_socket(jail: &Jail) -> PathBuf {
        let outside = jail.base().join("outside.sock");
        socket_with_mode(&outside, 0o600);
        jail.root_dir
            .child("api.socket")
            .symlink_to_file(&outside)
            .unwrap();
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

        assert_matches!(grant(jail.base()), Err(GrantError::WrongType));
        assert_eq!(mode_of(&untouched), 0o600);
    }

    #[rstest]
    fn grant_through_a_symlinked_component_does_not_escape(escape: Escape) {
        let outside_socket = escape.sentinel_root.child("api.socket");
        socket_with_mode(&outside_socket, 0o700);

        assert_matches!(grant(&escape.jail), Err(GrantError::Walk(_)));
        assert_eq!(mode_of(&outside_socket), 0o700);
    }

    #[rstest]
    fn grant_on_an_unreadable_jail_base_is_a_walk_error_not_missing(tmp: TempDir) {
        if is_root() {
            return;
        }
        let jail = tmp.child("jail");
        jail.create_dir_all().unwrap();
        fs::set_permissions(&jail, fs::Permissions::from_mode(0o000)).unwrap();

        let res = grant(&jail);
        fs::set_permissions(&jail, fs::Permissions::from_mode(0o755)).unwrap();

        assert_matches!(res, Err(GrantError::Walk(_)));
    }

    #[rstest]
    fn remove_of_a_missing_chroot_is_ok(tmp: TempDir) {
        JailLayout::new(&strict(tmp.path()), &vm())
            .remove()
            .expect("missing chroot must be Ok");
    }

    #[rstest]
    fn remove_deletes_the_chroot_tree_and_spares_siblings(jail: Jail) {
        jail.root_dir.child("vmlinux").write_str("kernel").unwrap();
        let exec = jail.base.child("firecracker");
        let sibling = exec.child("other");
        sibling.create_dir_all().unwrap();

        JailLayout::new(&strict(jail.base()), &vm())
            .remove()
            .unwrap();
        exec.child("id").assert(predicate::path::missing());
        sibling.assert(predicate::path::exists());
    }

    #[rstest]
    fn remove_through_a_symlinked_exec_component_does_not_escape(escape: Escape) {
        let keep = escape.sentinel_root.child("keep.txt");
        keep.write_str("do not delete").unwrap();

        let _ = JailLayout::new(&strict(&escape.jail), &vm()).remove();
        keep.assert(predicate::path::exists());
    }
}
