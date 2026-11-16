// SPDX-License-Identifier: MIT
//! Teardown contract of [`JailLayout::remove`]: it removes the per-VM chroot whatever the jailed
//! Firecracker left in it, and is idempotent.
//!
//! Laws:
//! - the jail root is owned by the jailed uid, so Firecracker can create any legal file name in
//!   it; `remove` must still delete the whole `<base>/firecracker/<id>` tree for every such name
//!   (whitespace and non-UTF-8 bytes included), or a VM's jail leaks past teardown;
//! - removing an already-removed jail is `Ok`, and sibling jails are never touched;
//! - `remove` succeeds on a tree deeper than the soft fd limit, which a jail process can build
//!   holding one fd at a time, and never follows a link planted in the jail out of the tree.

use assert_fs::TempDir;
use hyperrs_firecracker::jailer::chroot::JailLayout;
use hyperrs_firecracker::VmId;
use hyperrs_fs::path::{IsAbsolute, SafePathBuf, StrictComponents};
use nix::fcntl::{openat, OFlag};
use nix::sys::stat::{mkdirat, Mode};
use nix::unistd::mkfifo;
use std::ffi::OsStr;
use std::fs;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::symlink;
use std::os::unix::net::UnixListener;
use std::path::Path;

type Strict = SafePathBuf<IsAbsolute, StrictComponents>;

fn base(tmp: &TempDir) -> Strict {
    fs::canonicalize(tmp.path()).unwrap().try_into().unwrap()
}

#[test]
fn remove_deletes_the_jail_whatever_names_the_guest_side_left_in_it() {
    let names: [&[u8]; 9] = [
        b"firecracker.log",
        b" ",
        b"-rf",
        &[b'n'; 255],
        b"\xff\xfe",
        b"two words",
        b"line\nbreak",
        b"tab\there",
        b"trailing ",
    ];
    let leaked: Vec<String> = names
        .iter()
        .filter_map(|raw| {
            let tmp = TempDir::new().unwrap();
            let base = base(&tmp);
            let id: VmId = "vm-a".parse().unwrap();
            let sibling: VmId = "vm-b".parse().unwrap();
            let jail = JailLayout::new(&base, &id);
            let other = JailLayout::new(&base, &sibling);
            jail.create_root().unwrap();
            other.create_root().unwrap();
            fs::write(jail.root().as_path().join(OsStr::from_bytes(raw)), b"x").unwrap();

            let got = jail.remove();
            let gone = !jail.chroot_dir().as_path().exists();
            assert!(other.root().as_path().is_dir());
            (got.is_err() || !gone).then(|| format!("{:?}: {got:?}", String::from_utf8_lossy(raw)))
        })
        .collect();
    assert!(
        leaked.is_empty(),
        "jail leaked past teardown for {leaked:#?}"
    );
}

#[test]
fn remove_is_idempotent_and_spares_siblings() {
    let tmp = TempDir::new().unwrap();
    let base = base(&tmp);
    let id: VmId = "vm-a".parse().unwrap();
    let sibling: VmId = "vm-b".parse().unwrap();
    let jail = JailLayout::new(&base, &id);
    let other = JailLayout::new(&base, &sibling);
    jail.create_root().unwrap();
    other.create_root().unwrap();
    fs::write(other.root().as_path().join("keep"), b"keep").unwrap();

    jail.remove().unwrap();
    jail.remove().unwrap();

    assert!(!jail.chroot_dir().as_path().exists());
    assert_eq!(
        fs::read(other.root().as_path().join("keep")).unwrap(),
        b"keep"
    );
}

struct NofileLimit(nix::libc::rlimit);

impl NofileLimit {
    fn lower_to(soft: u64) -> Self {
        let mut old = nix::libc::rlimit {
            rlim_cur: 0,
            rlim_max: 0,
        };
        // SAFETY: getrlimit/setrlimit only read/write the rlimit structs passed in.
        unsafe {
            assert_eq!(nix::libc::getrlimit(nix::libc::RLIMIT_NOFILE, &mut old), 0);
            let new = nix::libc::rlimit {
                rlim_cur: soft.min(old.rlim_max),
                rlim_max: old.rlim_max,
            };
            assert_eq!(nix::libc::setrlimit(nix::libc::RLIMIT_NOFILE, &new), 0);
        }
        Self(old)
    }
}

impl Drop for NofileLimit {
    fn drop(&mut self) {
        // SAFETY: restores the struct getrlimit returned.
        unsafe { nix::libc::setrlimit(nix::libc::RLIMIT_NOFILE, &self.0) };
    }
}

/// Builds `depth` nested directories below `top` holding only one fd at a time, which is how a
/// jail process can nest past any per-process fd limit.
fn nest(top: &Path, depth: usize) {
    let mut cur: OwnedFd = fs::File::open(top).unwrap().into();
    for _ in 0..depth {
        mkdirat(Some(cur.as_raw_fd()), "d", Mode::from_bits_truncate(0o755)).unwrap();
        let next = openat(
            Some(cur.as_raw_fd()),
            "d",
            OFlag::O_RDONLY | OFlag::O_DIRECTORY,
            Mode::empty(),
        )
        .unwrap();
        // SAFETY: openat just returned this fd and nothing else owns it.
        cur = unsafe { OwnedFd::from_raw_fd(next) };
    }
}

#[test]
fn remove_clears_a_tree_deeper_than_the_default_fd_limit() {
    let tmp = TempDir::new().unwrap();
    let base = base(&tmp);
    let id: VmId = "vm-a".parse().unwrap();
    let jail = JailLayout::new(&base, &id);
    jail.create_root().unwrap();
    nest(jail.root().as_path(), 1500);

    let got = {
        let _limit = NofileLimit::lower_to(1024);
        jail.remove()
    };

    assert!(got.is_ok(), "teardown failed on a 1500-deep tree: {got:?}");
    assert!(!jail.chroot_dir().as_path().exists());
}

#[test]
fn remove_never_follows_links_planted_in_the_jail() {
    let tmp = TempDir::new().unwrap();
    let base = base(&tmp);
    let id: VmId = "vm-a".parse().unwrap();
    let jail = JailLayout::new(&base, &id);
    jail.create_root().unwrap();
    let root = jail.root().as_path().to_path_buf();
    let outside = tmp.path().join("outside");
    fs::create_dir(&outside).unwrap();
    fs::write(outside.join("keep.txt"), b"keep").unwrap();
    let outside_file = tmp.path().join("outside-file");
    fs::write(&outside_file, b"keep").unwrap();

    symlink(&outside, root.join("to-dir")).unwrap();
    symlink(&outside_file, root.join("to-file")).unwrap();
    fs::create_dir(root.join("nested")).unwrap();
    symlink(tmp.path(), root.join("nested/up")).unwrap();
    fs::hard_link(&outside_file, root.join("hard")).unwrap();
    mkfifo(&root.join("fifo"), Mode::from_bits_truncate(0o600)).unwrap();
    let _sock = UnixListener::bind(root.join("sock")).unwrap();

    jail.remove().unwrap();

    assert!(!jail.chroot_dir().as_path().exists());
    assert_eq!(fs::read(outside.join("keep.txt")).unwrap(), b"keep");
    assert_eq!(fs::read(&outside_file).unwrap(), b"keep");
}
