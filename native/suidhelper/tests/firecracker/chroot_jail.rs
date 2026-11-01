use hyper_suidhelper::firecracker::chroot_jail::{JailRoot, KernelError, KernelImage, OpenError};
use hyper_suidhelper::firecracker::id::{JailOwner, UidGidRange};
use hyper_suidhelper::fs::dir;
use hyper_suidhelper::fs::path::{IsAbsolute, RelativeError, SafePathBuf, StrictComponents};
use hyper_suidhelper::linux::dm::DmName;
use nix::errno::Errno;
use nix::sys::stat::{makedev, mknod, Mode, SFlag};
use std::fs;
use std::os::unix::fs::{symlink, FileTypeExt, MetadataExt};
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

// A source that lives entirely outside hyper_base is refused.
#[test]
fn kernel_outside_base_is_refused() {
    let tmp = tempfile::tempdir().unwrap();
    let hyper_base = tmp.path().join("hyper");
    fs::create_dir(&hyper_base).unwrap();
    let outside = tmp.path().join("outside-kernel");
    fs::write(&outside, b"kernel").unwrap();

    let err = KernelImage::open(&strict(&outside), &strict(&hyper_base)).err();
    assert!(
        matches!(err, Some(KernelError::OutsideBase { .. })),
        "got {err:?}"
    );
}

// A source UNDER hyper_base but which is a symlink RESOLVING outside it is
// refused: confinement is enforced after canonicalization, not on the lexical
// path. This is the key source-confinement invariant.
#[test]
fn kernel_symlink_escaping_base_is_refused() {
    let tmp = tempfile::tempdir().unwrap();
    let hyper_base = tmp.path().join("hyper");
    fs::create_dir(&hyper_base).unwrap();
    let real_target = tmp.path().join("secret");
    fs::write(&real_target, b"secret kernel").unwrap();
    let link = hyper_base.join("kernel-link");
    symlink(&real_target, &link).unwrap();

    let err = KernelImage::open(&strict(&link), &strict(&hyper_base)).err();
    assert!(
        matches!(err, Some(KernelError::OutsideBase { .. })),
        "got {err:?}"
    );
}

#[test]
fn missing_kernel_is_a_resolve_error() {
    let tmp = tempfile::tempdir().unwrap();
    let missing = tmp.path().join("nope");
    let err = KernelImage::open(&strict(&missing), &strict(tmp.path())).err();
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

    let kernel = KernelImage::open(&strict(&src), &strict(base)).unwrap();
    root.stage_kernel(kernel).expect("first stage");
    assert_eq!(
        fs::read(root_dir.join("vmlinux")).unwrap(),
        b"\x7fELF fake kernel bytes"
    );

    let kernel = KernelImage::open(&strict(&src), &strict(base)).unwrap();
    let err = root.stage_kernel(kernel).unwrap_err();
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
    let kernel = KernelImage::open(&strict(&src), &strict(base)).unwrap();
    root.stage_kernel(kernel).unwrap();

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

fn setup_dm(loop_dev: &Path) -> Option<DmName> {
    let name = format!("hyper-test-chroot-{}", std::process::id());
    let table = format!("0 2048 linear {} 0", loop_dev.display());
    let created = Command::new("dmsetup")
        .args(["create", &name, "--table", &table])
        .status()
        .ok()?
        .success();
    if !created {
        return None;
    }
    name.parse().ok()
}

fn teardown_dm(name: &DmName) {
    let _ = Command::new("dmsetup")
        .args(["remove", "--retry"])
        .arg(name.as_os_str())
        .output();
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
    let Some(block) = setup_dm(&dev) else {
        teardown_loop(&dev);
        eprintln!("SKIP add_rootfs: dmsetup unavailable");
        return;
    };

    let root = JailRoot::open(&strict(base), &strict(&root_dir)).unwrap();
    let res = block.open().map_err(|e| e.to_string()).and_then(|device| {
        root.add_rootfs(&device, owner(12345, 12346))
            .map_err(|e| e.to_string())
    });
    let dev_rdev = fs::metadata(block.path().as_path()).map(|m| m.rdev());
    teardown_dm(&block);
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
        matches!(err, dir::Error::DeviceMismatch { .. }),
        "got {err:?}"
    );
    assert_eq!(
        fs::metadata(&planted).unwrap().uid(),
        0,
        "planted node must not be chowned"
    );
}
