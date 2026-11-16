// SPDX-License-Identifier: MIT
//! Refusal contract of [`SafeFile::open`] and [`SafeDir::openat`]: a refused open is free of side
//! effects.
//!
//! The helper runs as root and opens caller-named paths, so validating a file only *after* the
//! open syscall is only safe if that open itself can neither hang nor change anything. Laws under
//! test:
//! - **A type mismatch never blocks.** Opening a FIFO as a regular file, block device or char
//!   device returns [`ValidationError::WrongFileType`] promptly for every access mode, instead of
//!   parking the (root, lock-holding) helper until some peer opens the other end.
//! - **A type mismatch is invisible to a peer.** A writer blocked on a FIFO is never released by a
//!   refused open: no reader ever appears on the pipe.
//! - **A refused open never truncates.** For any file contents and any refusal reason (wrong type,
//!   group/other-writable), an open with `O_TRUNC` that is refused leaves the bytes intact.
//! - **A refused open never creates.** An `O_CREAT` open refused for its type leaves no new entry.

use assert_fs::prelude::*;
use assert_fs::TempDir;
use hyperrs_fs::dir::SafeDir;
use hyperrs_fs::file::{
    Any, IsBlockDevice, IsCharDevice, IsRegularFile, OpenFlags, OwnerOnlyWritable, SafeFile,
    ValidationError,
};
use hyperrs_fs::path::{IsAbsolute, SafePathBuf, StrictComponents};
use nix::fcntl::{open, OFlag};
use nix::sys::stat::Mode;
use nix::unistd::mkfifo;
use proptest::prelude::*;
use std::assert_matches;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::thread;
use std::time::Duration;

type Strict = SafePathBuf<IsAbsolute, StrictComponents>;

const PROMPT: Duration = Duration::from_secs(3);

fn strict(p: &Path) -> Strict {
    p.to_path_buf()
        .try_into()
        .expect("strict-absolute temp path")
}

fn fifo(tmp: &TempDir) -> PathBuf {
    let p = tmp.child("pipe").path().to_path_buf();
    mkfifo(&p, Mode::from_bits_truncate(0o600)).unwrap();
    p
}

/// Unblock any opener parked on `fifo` so a hung worker thread can finish.
fn release(fifo: &Path) {
    let _ = open(fifo, OFlag::O_RDWR | OFlag::O_NONBLOCK, Mode::empty());
}

#[derive(Debug, Clone, Copy)]
enum Want {
    Regular,
    Block,
    Char,
}

fn open_as(want: Want, p: &Strict, flags: OpenFlags) -> Result<(), ValidationError> {
    match want {
        Want::Regular => SafeFile::<IsRegularFile, Any, Any>::open(p, flags).map(drop),
        Want::Block => SafeFile::<IsBlockDevice, Any, Any>::open(p, flags).map(drop),
        Want::Char => SafeFile::<IsCharDevice, Any, Any>::open(p, flags).map(drop),
    }
}

#[test]
fn a_fifo_opened_as_any_non_fifo_type_is_refused_promptly_for_every_access_mode() {
    let mut hung = Vec::new();
    for want in [Want::Regular, Want::Block, Want::Char] {
        for (label, flags) in [
            ("RDONLY", OpenFlags::RDONLY),
            ("WRONLY", OpenFlags::WRONLY),
            ("RDWR", OpenFlags::RDWR),
        ] {
            let tmp = TempDir::new().unwrap();
            let pipe = fifo(&tmp);
            let target = strict(&pipe);
            let (tx, rx) = mpsc::channel();
            let worker = thread::spawn(move || tx.send(open_as(want, &target, flags)).unwrap());

            match rx.recv_timeout(PROMPT) {
                Ok(got) => {
                    assert_matches!(got, Err(ValidationError::WrongFileType), "{want:?} {label}")
                }
                Err(_) => {
                    hung.push(format!("{want:?}/{label}"));
                    release(&pipe);
                }
            }
            worker.join().unwrap();
        }
    }
    assert!(hung.is_empty(), "refusal blocked on a FIFO for: {hung:?}");
}

#[test]
fn a_refused_fifo_open_never_releases_a_blocked_peer_writer() {
    let tmp = TempDir::new().unwrap();
    let pipe = fifo(&tmp);
    let peer_path = pipe.clone();
    let (tx, rx) = mpsc::channel();
    let peer = thread::spawn(move || {
        let opened = open(&peer_path, OFlag::O_WRONLY, Mode::empty()).is_ok();
        tx.send(opened).unwrap();
    });
    thread::sleep(Duration::from_millis(100));

    let target = strict(&pipe);
    let opener = thread::spawn(move || {
        let _ = SafeFile::<IsRegularFile, Any, Any>::open(&target, OpenFlags::RDONLY);
    });

    let released = rx.recv_timeout(Duration::from_millis(500)).is_ok();
    release(&pipe);
    peer.join().unwrap();
    opener.join().unwrap();
    assert!(
        !released,
        "a SafeFile<IsRegularFile> open that must be refused acted as the FIFO's reader"
    );
}

#[derive(Debug, Clone, Copy)]
enum Refusal {
    WrongTypeAsBlock,
    WrongTypeAsChar,
    GroupWritable,
    OtherWritable,
}

fn refusal() -> impl Strategy<Value = Refusal> {
    prop_oneof![
        Just(Refusal::WrongTypeAsBlock),
        Just(Refusal::WrongTypeAsChar),
        Just(Refusal::GroupWritable),
        Just(Refusal::OtherWritable),
    ]
}

fn refused_trunc_open(why: Refusal, p: &Strict) -> Result<(), ValidationError> {
    let flags = OpenFlags::WRONLY | OpenFlags::TRUNC;
    match why {
        Refusal::WrongTypeAsBlock => SafeFile::<IsBlockDevice, Any, Any>::open(p, flags).map(drop),
        Refusal::WrongTypeAsChar => SafeFile::<IsCharDevice, Any, Any>::open(p, flags).map(drop),
        Refusal::GroupWritable | Refusal::OtherWritable => {
            SafeFile::<IsRegularFile, Any, OwnerOnlyWritable>::open(p, flags).map(drop)
        }
    }
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(64))]

    #[test]
    fn a_refused_truncating_open_leaves_the_file_bytes_intact(
        bytes in prop::collection::vec(any::<u8>(), 1..4096),
        why in refusal(),
    ) {
        let tmp = TempDir::new().unwrap();
        let f = tmp.child("victim");
        f.write_binary(&bytes).unwrap();
        let mode = match why {
            Refusal::GroupWritable => 0o620,
            Refusal::OtherWritable => 0o602,
            _ => 0o600,
        };
        fs::set_permissions(f.path(), fs::Permissions::from_mode(mode)).unwrap();

        let got = refused_trunc_open(why, &strict(f.path()));

        prop_assert!(got.is_err(), "{why:?} was accepted");
        prop_assert_eq!(fs::read(f.path()).unwrap(), bytes, "{:?} truncated the file", why);
    }
}

#[test]
fn a_create_refused_for_its_type_leaves_no_new_entry() {
    let tmp = TempDir::new().unwrap();
    let dir = SafeDir::open(&strict(tmp.path()), OpenFlags::RDONLY).unwrap();

    let via_open = SafeFile::<IsBlockDevice, Any, Any>::open(
        &strict(&tmp.path().join("by-open")),
        OpenFlags::WRONLY | OpenFlags::CREATE,
    );
    let via_openat = dir.openat::<IsCharDevice, Any, Any>(
        Path::new("by-openat"),
        OpenFlags::WRONLY | OpenFlags::CREATE_NEW,
        Mode::from_bits_truncate(0o600),
    );

    assert_matches!(via_open, Err(_));
    assert_matches!(via_openat, Err(ValidationError::WrongFileType));
    let left: Vec<_> = fs::read_dir(tmp.path())
        .unwrap()
        .map(|e| e.unwrap().file_name())
        .collect();
    assert!(left.is_empty(), "refused creates left entries: {left:?}");
}
