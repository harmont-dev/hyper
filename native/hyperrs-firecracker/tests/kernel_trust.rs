// SPDX-License-Identifier: MIT
//! Trust contract of the guest kernel handed to a jail: [`KernelImage::open`] decides whether a
//! host file may become a VM's `vmlinux`, and [`JailRoot::stage_kernel`] puts it in the jail.
//!
//! Laws:
//! - refusal oracle: for every owner-readable mode, a kernel is accepted exactly when it carries
//!   no group- or other-write bit, and a refusal is always `GroupOrOtherWritable`;
//! - only root or the caller may own an accepted kernel: as root, every non-zero owner uid is
//!   refused with `Owner { uid }` naming exactly that uid;
//! - a non-regular source (directory, FIFO, character device, socket) is refused, and refusing it
//!   never blocks;
//! - staging round-trips bytes: the jail's `vmlinux` equals the opened source, both by hard link
//!   on one filesystem and by copy across filesystems (`EXDEV`), however many jails one opened
//!   image is staged into;
//! - staging is bound to the inode that was opened and vetted, never the path: replacing the
//!   path afterwards cannot put the replacement into the jail;
//! - a staged kernel is never writable by group or other, so a jail cannot rewrite the kernel
//!   other VMs boot.

use assert_fs::prelude::*;
use assert_fs::TempDir;
use hyperrs_firecracker::jailer::chroot::{JailLayout, JailRoot, KernelError, KernelImage};
use hyperrs_firecracker::VmId;
use hyperrs_fs::file::ValidationError;
use hyperrs_fs::path::{IsAbsolute, SafePathBuf, StrictComponents};
use nix::sys::stat::Mode;
use nix::unistd::{geteuid, mkfifo};
use proptest::prelude::*;
use std::fs;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::thread;
use std::time::Duration;
use test_strategy::proptest;

type Strict = SafePathBuf<IsAbsolute, StrictComponents>;

const REFUSAL_DEADLINE: Duration = Duration::from_secs(3);

fn strict(p: impl AsRef<Path>) -> Strict {
    p.as_ref().to_path_buf().try_into().unwrap()
}

fn write_kernel(path: &Path, bytes: &[u8], mode: u32) {
    fs::write(path, bytes).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(mode)).unwrap();
}

fn jail_root(base: &Path, id: &str) -> (JailRoot, PathBuf) {
    let id: VmId = id.parse().unwrap();
    let root = JailLayout::new(&strict(base), &id).create_root().unwrap();
    (
        root,
        base.join("firecracker").join(id.to_string()).join("root"),
    )
}

/// Staging hard-links by fd (`AT_EMPTY_PATH`), which needs `CAP_DAC_READ_SEARCH` before Linux
/// 6.10; the helper always stages elevated, so these laws are proven as root.
fn skip_unless_root() -> bool {
    let skip = !geteuid().is_root();
    if skip {
        eprintln!("SKIP: needs root");
    }
    skip
}

fn shm_dir() -> Option<TempDir> {
    let shm = Path::new("/dev/shm");
    let other_fs = fs::metadata(shm).ok()?.dev() != fs::metadata(std::env::temp_dir()).ok()?.dev();
    other_fs.then(|| TempDir::new_in(shm).unwrap())
}

#[proptest(cases = 256)]
fn kernel_is_accepted_exactly_when_no_group_or_other_write_bit_is_set(
    #[strategy(0u32..=0o7777)] bits: u32,
) {
    let mode = bits | 0o400;
    let tmp = TempDir::new().unwrap();
    let src = tmp.child("vmlinux");
    write_kernel(&src, b"kernel", mode);
    let actual_mode = fs::metadata(&src).unwrap().mode() & 0o7777;

    let got = KernelImage::open(&strict(&src));

    if actual_mode & 0o022 == 0 {
        prop_assert!(
            got.is_ok(),
            "mode {:o} refused: {:?}",
            actual_mode,
            got.err()
        );
    } else {
        prop_assert!(
            matches!(
                got,
                Err(KernelError::Open {
                    source: ValidationError::GroupOrOtherWritable,
                    ..
                })
            ),
            "mode {:o} not refused as group/other-writable: {:?}",
            actual_mode,
            got.err()
        );
    }
}

#[proptest(cases = 64)]
fn kernel_owned_by_any_non_root_uid_is_refused_naming_that_uid_as_root(
    #[strategy(1u32..u32::MAX - 1)] uid: u32,
) {
    if skip_unless_root() {
        return Ok(());
    }
    let tmp = TempDir::new().unwrap();
    let src = tmp.child("vmlinux");
    write_kernel(&src, b"kernel", 0o644);
    std::os::unix::fs::chown(&src, Some(uid), None).unwrap();

    match KernelImage::open(&strict(&src)) {
        Err(KernelError::Owner { uid: refused, .. }) => prop_assert_eq!(refused.as_raw(), uid),
        other => prop_assert!(false, "uid {} not refused as owner: {:?}", uid, other.err()),
    }
}

/// Runs `open` on another thread so a blocking `open(2)` fails the test instead of hanging it;
/// `unblock` is then given the chance to release the stuck thread.
fn open_within_deadline(path: &Path, unblock: impl FnOnce()) -> Option<Result<(), String>> {
    let (tx, rx) = mpsc::channel();
    let target = strict(path);
    let worker = thread::spawn(move || {
        let _ = tx.send(
            KernelImage::open(&target)
                .map(drop)
                .map_err(|e| e.to_string()),
        );
    });
    let got = rx.recv_timeout(REFUSAL_DEADLINE).ok();
    if got.is_none() {
        unblock();
    }
    let _ = worker.join();
    got
}

#[test]
fn a_fifo_kernel_is_refused_without_blocking() {
    let tmp = TempDir::new().unwrap();
    let fifo = tmp.child("vmlinux");
    mkfifo(fifo.path(), Mode::from_bits_truncate(0o644)).unwrap();

    let fifo_path = fifo.to_path_buf();
    let got = open_within_deadline(fifo.path(), move || {
        let _ = fs::OpenOptions::new()
            .write(true)
            .custom_flags(nix::libc::O_NONBLOCK)
            .open(&fifo_path);
    });

    match got {
        None => panic!("KernelImage::open blocked on a FIFO for over {REFUSAL_DEADLINE:?}"),
        Some(result) => assert!(result.is_err(), "a FIFO was accepted as a kernel"),
    }
}

#[test]
fn non_regular_kernel_sources_are_refused() {
    let tmp = TempDir::new().unwrap();
    let dir = tmp.child("dir");
    dir.create_dir_all().unwrap();
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o755)).unwrap();
    let sock = tmp.child("sock");
    let _listener = UnixListener::bind(&sock).unwrap();
    fs::set_permissions(&sock, fs::Permissions::from_mode(0o644)).unwrap();

    let rows: [(&str, PathBuf); 3] = [
        ("directory", dir.to_path_buf()),
        ("character device", PathBuf::from("/dev/null")),
        ("socket", sock.to_path_buf()),
    ];

    for (name, path) in rows {
        let got = open_within_deadline(&path, || {});
        match got {
            None => panic!("{name}: KernelImage::open blocked"),
            Some(result) => assert!(result.is_err(), "{name} was accepted as a kernel"),
        }
    }
}

#[proptest(cases = 24)]
fn staging_round_trips_the_kernel_bytes_on_one_filesystem_and_across_two_as_root(
    #[strategy(proptest::collection::vec(any::<u8>(), 0..65_536))] bytes: Vec<u8>,
    #[strategy(1usize..4)] jails: usize,
    cross_fs: bool,
) {
    if skip_unless_root() {
        return Ok(());
    }
    let shm = if cross_fs { shm_dir() } else { None };
    let src_dir = shm.unwrap_or_else(|| TempDir::new().unwrap());
    let src = src_dir.child("vmlinux-src");
    write_kernel(&src, &bytes, 0o644);
    let kernel = KernelImage::open(&strict(&src)).unwrap();
    let base = TempDir::new().unwrap();

    for n in 0..jails {
        let (root, root_path) = jail_root(base.path(), &format!("vm{n}"));
        root.stage_kernel(&kernel).unwrap();
        let staged = root_path.join("vmlinux");
        prop_assert_eq!(fs::read(&staged).unwrap(), bytes.clone(), "jail {}", n);
        let mode = fs::metadata(&staged).unwrap().mode();
        prop_assert_eq!(
            mode & 0o022,
            0,
            "jail {} staged a kernel with mode {:o}",
            n,
            mode
        );
    }
}

#[test]
fn a_cross_filesystem_stage_is_read_only_for_everyone_as_root() {
    if skip_unless_root() {
        return;
    }
    let Some(src_dir) = shm_dir() else {
        eprintln!("SKIP: /dev/shm is not a separate filesystem");
        return;
    };
    let src = src_dir.child("vmlinux-src");
    write_kernel(&src, b"cross-fs kernel", 0o644);
    let kernel = KernelImage::open(&strict(&src)).unwrap();
    let base = TempDir::new().unwrap();

    let (root, root_path) = jail_root(base.path(), "vm");
    root.stage_kernel(&kernel).unwrap();

    let meta = fs::metadata(root_path.join("vmlinux")).unwrap();
    assert_ne!(meta.ino(), fs::metadata(&src).unwrap().ino());
    assert_eq!(
        meta.mode() & 0o222,
        0,
        "copied kernel mode {:o}",
        meta.mode()
    );
}

#[test]
fn replacing_the_kernel_path_after_open_never_stages_the_replacement_as_root() {
    if skip_unless_root() {
        return;
    }
    let shm = shm_dir();
    let dirs: Vec<(&str, TempDir)> = [
        ("same fs", Some(TempDir::new().unwrap())),
        ("cross fs", shm),
    ]
    .into_iter()
    .filter_map(|(name, dir)| dir.map(|d| (name, d)))
    .collect();

    for (name, src_dir) in dirs {
        let src = src_dir.child("vmlinux");
        write_kernel(&src, b"vetted kernel", 0o644);
        let kernel = KernelImage::open(&strict(&src)).unwrap();

        let swap = src_dir.child("swap");
        write_kernel(&swap, b"swapped-in kernel", 0o644);
        fs::rename(&swap, &src).unwrap();

        let base = TempDir::new().unwrap();
        let (root, root_path) = jail_root(base.path(), "vm");
        let staged = root
            .stage_kernel(&kernel)
            .ok()
            .map(|()| fs::read(root_path.join("vmlinux")).unwrap());

        assert!(
            staged.as_deref().is_none_or(|b| b == b"vetted kernel"),
            "{name}: staged {:?} after the path was swapped",
            staged.map(|b| String::from_utf8_lossy(&b).into_owned())
        );
    }
}
