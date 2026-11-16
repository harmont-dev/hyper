//! The jail `root/` is owned by the jail uid, so a Firecracker a hostile guest has taken over can
//! plant any entry there before the helper stages into it. Law: a name the jail uid planted where
//! the helper stages `vmlinux` or `rootfs` is never written through, retyped or re-owned.

use assert_fs::fixture::ChildPath;
use assert_fs::prelude::*;
use assert_fs::TempDir;
use hyperrs_firecracker::jailer::chroot::{JailLayout, JailRoot, KernelImage};
use hyperrs_firecracker::VmId;
use hyperrs_fs::dir::DirError;
use hyperrs_fs::file::{self, Any, IsBlockDevice, OpenFlags, Owner, SafeFile};
use hyperrs_fs::path::{IsAbsolute, SafePathBuf, StrictComponents};
use nix::errno::Errno;
use nix::unistd::{getgid, getuid};
use pretty_assertions::assert_eq;
use rstest::{fixture, rstest};
use std::assert_matches;
use std::fs;
use std::os::unix::fs::{FileTypeExt, MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};

type Strict = SafePathBuf<IsAbsolute, StrictComponents>;

fn strict(p: impl AsRef<Path>) -> Strict {
    p.as_ref().to_path_buf().try_into().unwrap()
}

fn vm() -> VmId {
    "hostile".parse().unwrap()
}

struct Jail {
    base: TempDir,
    root: ChildPath,
}

impl Jail {
    fn open_root(&self) -> JailRoot {
        JailLayout::new(&strict(self.base.path()), &vm())
            .open_root()
            .unwrap()
    }
}

#[fixture]
fn jail() -> Jail {
    let base = TempDir::new().unwrap();
    let root = base.child("firecracker/hostile/root");
    root.create_dir_all().unwrap();
    Jail { base, root }
}

fn any_block_device() -> Option<PathBuf> {
    fs::read_dir("/dev")
        .ok()?
        .flatten()
        .map(|e| e.path())
        .find(|p| {
            fs::symlink_metadata(p)
                .map(|m| m.file_type().is_block_device())
                .unwrap_or(false)
        })
}

fn me() -> Owner {
    Owner {
        uid: getuid(),
        gid: getgid(),
    }
}

fn is_root() -> bool {
    nix::unistd::geteuid().is_root()
}

#[rstest]
fn add_rootfs_over_a_planted_regular_file_refuses_and_leaves_it(jail: Jail) {
    let Some(dev) = any_block_device() else {
        eprintln!(
            "SKIP add_rootfs_over_a_planted_regular_file_refuses_and_leaves_it: no block device"
        );
        return;
    };
    let planted = jail.root.child("rootfs");
    planted.write_str("planted").unwrap();
    fs::set_permissions(&planted, fs::Permissions::from_mode(0o644)).unwrap();
    let device = SafeFile::<IsBlockDevice, Any, Any>::open(&strict(&dev), OpenFlags::PATH).unwrap();

    let err = jail.open_root().add_rootfs(&device, me()).unwrap_err();

    assert_matches!(err, DirError::Open(file::ValidationError::WrongFileType));
    planted.assert("planted");
    assert_eq!(fs::metadata(&planted).unwrap().mode() & 0o7777, 0o644);
}

#[rstest]
fn add_rootfs_over_a_planted_symlink_refuses_and_never_touches_its_target(jail: Jail) {
    let Some(dev) = any_block_device() else {
        eprintln!("SKIP add_rootfs_over_a_planted_symlink: no block device");
        return;
    };
    let victim = jail.base.child("victim");
    victim.write_str("victim").unwrap();
    fs::set_permissions(&victim, fs::Permissions::from_mode(0o640)).unwrap();
    jail.root.child("rootfs").symlink_to_file(&victim).unwrap();
    let device = SafeFile::<IsBlockDevice, Any, Any>::open(&strict(&dev), OpenFlags::PATH).unwrap();

    let err = jail.open_root().add_rootfs(&device, me()).unwrap_err();

    assert_matches!(
        err,
        DirError::Open(file::ValidationError::Open(Errno::ELOOP))
    );
    victim.assert("victim");
    assert_eq!(fs::metadata(&victim).unwrap().mode() & 0o7777, 0o640);
}

/// Root-only: unprivileged `linkat(AT_EMPTY_PATH)` is `ENOENT` before 6.10, so neither the
/// hard-link nor the `EXDEV` copy path would be reached.
#[rstest]
fn stage_kernel_never_writes_through_a_planted_vmlinux_symlink_as_root(
    jail: Jail,
    #[values(false, true)] cross_device: bool,
) {
    if !is_root() {
        eprintln!("SKIP stage_kernel_never_writes_through_a_planted_vmlinux_symlink_as_root");
        return;
    }
    let src_dir = if cross_device {
        match TempDir::new_in("/dev/shm") {
            Ok(d) => d,
            Err(_) => {
                eprintln!("SKIP cross-device staging: no /dev/shm");
                return;
            }
        }
    } else {
        TempDir::new_in(jail.base.path()).unwrap()
    };
    let src = src_dir.child("vmlinux");
    src.write_str("kernel").unwrap();
    fs::set_permissions(&src, fs::Permissions::from_mode(0o644)).unwrap();
    let victim = jail.base.child("victim");
    victim.write_str("victim").unwrap();
    jail.root.child("vmlinux").symlink_to_file(&victim).unwrap();

    let err = jail
        .open_root()
        .stage_kernel(&KernelImage::open(&strict(&src)).unwrap())
        .unwrap_err();

    assert_eq!(err.errno(), Some(Errno::EEXIST), "{err:?}");
    victim.assert("victim");
    assert!(fs::symlink_metadata(jail.root.join("vmlinux"))
        .unwrap()
        .file_type()
        .is_symlink());
}
