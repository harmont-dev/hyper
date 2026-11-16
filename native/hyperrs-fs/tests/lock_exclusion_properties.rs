// SPDX-License-Identifier: MIT
//! Contract of [`FileLock`], the per-VM lock the suidhelper uses to serialize `vm_launch` against
//! `vm_teardown` (#135).
//!
//! Laws under test:
//! - **Mutual exclusion survives removal.** However many contenders race, and whichever holders
//!   `remove()` the lock file on their way out (as `vm_teardown` does), at most one contender is
//!   ever inside the critical section, and every contender eventually gets in. A waiter that
//!   flocked an inode which was unlinked under it must not count as a holder.
//! - **Never follows a planted name.** A symlink at the lock name is refused, and the open never
//!   creates the symlink's target.
//! - **The timeout bounds the call.** A lock name occupied by something that is not a lock file
//!   ends in an error within the timeout, never a hang.

use assert_fs::TempDir;
use hyperrs_fs::dir::SafeDir;
use hyperrs_fs::file::{OpenFlags, SafeFile};
use hyperrs_fs::lock::{FileLock, LockError};
use hyperrs_fs::path::{IsAbsolute, SafePathBuf, StrictComponent, StrictComponents};
use nix::sys::stat::Mode;
use nix::unistd::mkfifo;
use proptest::prelude::*;
use std::assert_matches;
use std::os::unix::fs::symlink;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc;
use std::thread;
use std::time::Duration;

const NAME_STR: &str = "vm-lock";
const NAME: &StrictComponent = StrictComponent::from_static(NAME_STR);
const WAIT: Duration = Duration::from_secs(20);

fn open(path: &Path) -> SafeDir {
    let path: SafePathBuf<IsAbsolute, StrictComponents> = path.to_path_buf().try_into().unwrap();
    SafeFile::open(&path, OpenFlags::RDONLY).unwrap()
}

#[derive(Debug, Clone)]
struct Contender {
    rounds: Vec<(bool, u8)>,
}

fn contender() -> impl Strategy<Value = Contender> {
    prop::collection::vec((any::<bool>(), 0u8..8), 1..5).prop_map(|rounds| Contender { rounds })
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(24))]

    #[test]
    fn at_most_one_holder_even_when_holders_remove_the_file(
        contenders in prop::collection::vec(contender(), 2..7),
    ) {
        let tmp = TempDir::new().unwrap();
        let inside = AtomicUsize::new(0);
        let peak = AtomicUsize::new(0);
        let entered = AtomicUsize::new(0);
        let failures = AtomicUsize::new(0);
        let expected: usize = contenders.iter().map(|c| c.rounds.len()).sum();

        thread::scope(|scope| {
            for contender in &contenders {
                let (inside, peak, entered, failures) = (&inside, &peak, &entered, &failures);
                let base = tmp.path().to_path_buf();
                scope.spawn(move || {
                    let dir = open(&base);
                    for &(remove, hold_ms) in &contender.rounds {
                        let lock = match FileLock::acquire(&dir, NAME, WAIT) {
                            Ok(lock) => lock,
                            Err(_) => {
                                failures.fetch_add(1, Ordering::SeqCst);
                                continue;
                            }
                        };
                        let now = inside.fetch_add(1, Ordering::SeqCst) + 1;
                        peak.fetch_max(now, Ordering::SeqCst);
                        entered.fetch_add(1, Ordering::SeqCst);
                        thread::sleep(Duration::from_millis(u64::from(hold_ms) * 3));
                        inside.fetch_sub(1, Ordering::SeqCst);
                        if remove {
                            lock.remove().unwrap();
                        } else {
                            drop(lock);
                        }
                    }
                });
            }
        });

        prop_assert_eq!(peak.load(Ordering::SeqCst), 1, "two contenders held the lock at once");
        prop_assert_eq!(failures.load(Ordering::SeqCst), 0);
        prop_assert_eq!(entered.load(Ordering::SeqCst), expected);
    }
}

#[test]
fn a_symlink_at_the_lock_name_is_refused_and_its_target_never_created() {
    let tmp = TempDir::new().unwrap();
    let target: PathBuf = tmp.path().join("victim");
    symlink(&target, tmp.path().join(NAME_STR)).unwrap();
    let dir = open(tmp.path());

    let got = FileLock::acquire(&dir, NAME, Duration::from_millis(200));

    assert_matches!(got.err(), Some(LockError::Open(_)));
    assert!(
        !target.exists(),
        "acquire must not create through a symlink"
    );
}

#[test]
fn a_directory_at_the_lock_name_is_refused_not_locked() {
    let tmp = TempDir::new().unwrap();
    std::fs::create_dir(tmp.path().join(NAME_STR)).unwrap();
    let dir = open(tmp.path());

    assert_matches!(
        FileLock::acquire(&dir, NAME, Duration::from_millis(200)).err(),
        Some(LockError::Open(_))
    );
}

#[test]
fn a_fifo_at_the_lock_name_errors_within_the_timeout_instead_of_hanging() {
    let tmp = TempDir::new().unwrap();
    mkfifo(&tmp.path().join(NAME_STR), Mode::from_bits_truncate(0o600)).unwrap();
    let base = tmp.path().to_path_buf();
    let (sent, received) = mpsc::channel();
    thread::spawn(move || {
        let dir = open(&base);
        let _ = sent.send(FileLock::acquire(&dir, NAME, Duration::from_millis(200)).map(drop));
    });

    let got = received.recv_timeout(Duration::from_secs(5));

    assert_matches!(got, Ok(Err(_)), "acquire must not block past its timeout");
}
