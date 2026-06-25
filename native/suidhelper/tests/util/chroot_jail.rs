//! Contracts of the VM jail builder (`util::chroot_jail`), driven through the
//! base-injected seams. Non-root, in a tempdir, the promises under test:
//!   * confinement — `open_chroot_under` follows no symlinked component and
//!     refuses a chroot that is not under the jail base;
//!   * source confinement — `stage_kernel_under` canonicalizes the source and
//!     refuses anything resolving outside `hyper_base` (a symlink that escapes
//!     is caught after resolution, not before);
//!   * staging — a confined source is materialized as `vmlinux`, byte-identical,
//!     and re-staging into an occupied slot is refused (O_EXCL / EEXIST).
//!
//! Root-gated (self-skip without root): a full `build_under` against a real loop
//! device stages the kernel AND creates the `rootfs` block node whose major:minor
//! mirrors the source device, owned by the requested uid:gid.

use hyper_suidhelper::util::chroot_jail::{
    open_chroot_under, stage_kernel_under, ChrootJail, Error,
};
use hyper_suidhelper::util::safe_dev::BlockDev;
use hyper_suidhelper::util::safe_dir::SafeDir;
use hyper_suidhelper::util::safe_path::{IsAbsolute, SafePath, StrictComponents, ValidationError};
use std::fs;
use std::os::unix::fs::{symlink, MetadataExt};
use std::path::{Path, PathBuf};
use std::process::Command;

type Strict = SafePath<IsAbsolute, StrictComponents>;

fn safe(p: &Path) -> Strict {
    p.to_path_buf()
        .try_into()
        .expect("test path is strict-absolute")
}

fn is_root() -> bool {
    nix::unistd::geteuid().is_root()
}

fn own_ids() -> (u32, u32) {
    (
        nix::unistd::getuid().as_raw(),
        nix::unistd::getgid().as_raw(),
    )
}

// A valid <exec>/<id> tree under the jail base opens successfully.
#[test]
fn open_chroot_descends_valid_tree() {
    let tmp = tempfile::tempdir().unwrap();
    let jail = tmp.path();
    let chroot = jail.join("exec").join("id");
    fs::create_dir_all(&chroot).unwrap();
    assert!(open_chroot_under(jail, &chroot).is_ok());
}

// A symlinked component is not followed (O_NOFOLLOW): open must fail.
#[test]
fn open_chroot_rejects_symlinked_component() {
    let tmp = tempfile::tempdir().unwrap();
    let jail = tmp.path();
    let real_exec = tmp.path().join("real-exec");
    fs::create_dir_all(real_exec.join("id")).unwrap();
    symlink(&real_exec, jail.join("exec")).unwrap();

    let chroot = jail.join("exec").join("id");
    assert!(
        open_chroot_under(jail, &chroot).is_err(),
        "open_chroot followed a symlinked component",
    );
}

// A chroot that is not under the jail base is rejected.
#[test]
fn open_chroot_rejects_path_outside_base() {
    let tmp = tempfile::tempdir().unwrap();
    let jail = tmp.path().join("jail");
    fs::create_dir(&jail).unwrap();
    let outside = tmp.path().join("elsewhere").join("id");
    let result = open_chroot_under(&jail, &outside);
    let err = result
        .err()
        .expect("expected an error for path outside base");
    assert!(
        matches!(err, Error::Path(ValidationError::NotUnderBase)),
        "got {err:?}",
    );
}

// A source that lives entirely outside hyper_base is refused.
#[test]
fn stage_kernel_rejects_source_outside_base() {
    let tmp = tempfile::tempdir().unwrap();
    let hyper_base = tmp.path().join("hyper");
    let chroot_dir = hyper_base.join("jail");
    fs::create_dir_all(&chroot_dir).unwrap();
    let outside = tmp.path().join("outside-kernel");
    fs::write(&outside, b"kernel").unwrap();

    let chroot = SafeDir::open(&safe(&chroot_dir)).unwrap();
    let (uid, gid) = own_ids();
    let err = stage_kernel_under(&chroot, &outside, &hyper_base, uid, gid).unwrap_err();
    assert!(matches!(err, Error::OutsideBase { .. }), "got {err:?}");
}

// A source UNDER hyper_base but which is a symlink RESOLVING outside it is
// refused: confinement is enforced after canonicalization, not on the lexical
// path. This is the key source-confinement invariant.
#[test]
fn stage_kernel_rejects_symlink_escaping_base() {
    let tmp = tempfile::tempdir().unwrap();
    let hyper_base = tmp.path().join("hyper");
    let chroot_dir = hyper_base.join("jail");
    fs::create_dir_all(&chroot_dir).unwrap();

    let real_target = tmp.path().join("secret"); // OUTSIDE hyper_base
    fs::write(&real_target, b"secret kernel").unwrap();
    let link = hyper_base.join("kernel-link"); // INSIDE hyper_base, escapes
    symlink(&real_target, &link).unwrap();

    let chroot = SafeDir::open(&safe(&chroot_dir)).unwrap();
    let (uid, gid) = own_ids();
    let err = stage_kernel_under(&chroot, &link, &hyper_base, uid, gid).unwrap_err();
    assert!(
        matches!(err, Error::OutsideBase { .. }),
        "symlink escaping the base must be refused, got {err:?}",
    );
}

// A missing source path is reported as a source error, not a confinement one.
#[test]
fn stage_kernel_missing_source_errors() {
    let tmp = tempfile::tempdir().unwrap();
    let hyper_base = tmp.path();
    let chroot_dir = hyper_base.join("jail");
    fs::create_dir_all(&chroot_dir).unwrap();
    let missing = hyper_base.join("nope");

    let chroot = SafeDir::open(&safe(&chroot_dir)).unwrap();
    let (uid, gid) = own_ids();
    let err = stage_kernel_under(&chroot, &missing, hyper_base, uid, gid).unwrap_err();
    assert!(matches!(err, Error::Source { .. }), "got {err:?}");
}

// A confined source is staged byte-identically as `vmlinux`; re-staging into the
// now-occupied slot is refused (O_EXCL / link EEXIST).
#[test]
fn stage_kernel_materializes_then_refuses_overwrite() {
    let tmp = tempfile::tempdir().unwrap();
    let hyper_base = tmp.path();
    let chroot_dir = hyper_base.join("jail");
    fs::create_dir_all(&chroot_dir).unwrap();
    let src = hyper_base.join("vmlinux-src");
    fs::write(&src, b"\x7fELF fake kernel bytes").unwrap();

    let chroot = SafeDir::open(&safe(&chroot_dir)).unwrap();
    let (uid, gid) = own_ids();
    stage_kernel_under(&chroot, &src, hyper_base, uid, gid).expect("first stage");

    let staged = chroot_dir.join("vmlinux");
    assert_eq!(
        fs::read(&staged).unwrap(),
        b"\x7fELF fake kernel bytes",
        "staged kernel bytes must match the source",
    );

    // Re-staging must not silently clobber: the slot is occupied.
    let chroot2 = SafeDir::open(&safe(&chroot_dir)).unwrap();
    let err = stage_kernel_under(&chroot2, &src, hyper_base, uid, gid).unwrap_err();
    assert!(
        matches!(err, Error::Fs(_)),
        "re-stage must be refused, got {err:?}"
    );
}

/// Attach a fresh loop device backed by a 1 MiB temp file. Returns the device
/// path, or None if losetup is unavailable / fails (test self-skips).
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

// A full build stages the kernel AND creates a `rootfs` block node mirroring the
// loop device's major:minor, both owned by the requested uid:gid.
#[test]
fn build_under_stages_kernel_and_mirrors_device_as_root() {
    if !is_root() {
        eprintln!("SKIP build_under_stages_kernel_and_mirrors_device: needs root for mknod/chown");
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let hyper_base = tmp.path();
    let chroot_dir = hyper_base.join("jails").join("exec").join("id");
    fs::create_dir_all(&chroot_dir).unwrap();
    let jail_base = hyper_base.join("jails");
    let kernel_src = hyper_base.join("vmlinux-src");
    fs::write(&kernel_src, b"kernel image").unwrap();

    let Some(dev) = setup_loop(hyper_base) else {
        eprintln!("SKIP build_under: losetup unavailable");
        return;
    };
    let block: BlockDev = dev
        .to_str()
        .unwrap()
        .parse()
        .expect("loop dev is a valid BlockDev");

    let (uid, gid) = (12345u32, 12345u32);
    let res = ChrootJail::new(chroot_dir.clone(), uid, gid)
        .with_kernel(kernel_src.clone())
        .with_rootfs(block)
        .build_under(&jail_base, hyper_base);

    let dev_rdev = fs::metadata(&dev).map(|m| m.rdev());
    teardown_loop(&dev);
    res.expect("build_under must succeed as root against a real device");

    let vmlinux = chroot_dir.join("vmlinux");
    let rootfs = chroot_dir.join("rootfs");
    assert_eq!(fs::read(&vmlinux).unwrap(), b"kernel image");

    let kmeta = fs::metadata(&vmlinux).unwrap();
    assert_eq!((kmeta.uid(), kmeta.gid()), (uid, gid), "kernel ownership");

    let rmeta = fs::metadata(&rootfs).unwrap();
    assert_eq!((rmeta.uid(), rmeta.gid()), (uid, gid), "rootfs ownership");
    assert_eq!(
        rmeta.mode() & 0o170000,
        0o060000,
        "rootfs must be a block device"
    );
    assert_eq!(
        rmeta.rdev(),
        dev_rdev.unwrap(),
        "rootfs node must mirror the source device major:minor",
    );
}
