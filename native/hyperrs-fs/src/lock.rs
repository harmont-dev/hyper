// SPDX-License-Identifier: MIT

use super::file::{
    Any, IsDirectory, IsRegularFile, OpenFlags, Ownership, SafeFile, ValidationError, Writability,
};
use super::path::{StrictComponent, StrictComponentBuf};
use nix::errno::Errno;
use nix::fcntl::{AtFlags, Flock, FlockArg};
use nix::sys::stat::{fstat, fstatat, Mode};
use std::os::unix::io::{AsRawFd, OwnedFd};
use std::thread;
use std::time::{Duration, Instant};
use thiserror::Error as ThisError;

const POLL: Duration = Duration::from_millis(10);

#[derive(Debug, ThisError)]
pub enum LockError {
    #[error("opening the lock file: {0}")]
    Open(#[from] ValidationError),
    #[error("locking: {0}")]
    Lock(#[source] Errno),
    #[error("checking the lock file is still linked: {0}")]
    Stat(#[source] Errno),
    #[error("lock still held by another process after {0:?}")]
    TimedOut(Duration),
}

pub struct FileLock<'d, R, O> {
    dir: &'d SafeFile<IsDirectory, R, O>,
    name: StrictComponentBuf,
    _flock: Flock<OwnedFd>,
}

impl<'d, R: Ownership, O: Writability> FileLock<'d, R, O> {
    pub fn acquire(
        dir: &'d SafeFile<IsDirectory, R, O>,
        name: &StrictComponent,
        timeout: Duration,
    ) -> Result<Self, LockError> {
        let deadline = Instant::now() + timeout;
        loop {
            let mut fd: OwnedFd = dir
                .openat::<IsRegularFile, Any, Any>(
                    name,
                    OpenFlags::RDONLY | OpenFlags::CREATE,
                    Mode::from_bits_truncate(0o600),
                )?
                .into();
            let flock = loop {
                match Flock::lock(fd, FlockArg::LockExclusiveNonblock) {
                    Ok(flock) => break flock,
                    Err((_, Errno::EWOULDBLOCK)) if Instant::now() >= deadline => {
                        return Err(LockError::TimedOut(timeout))
                    }
                    Err((back, Errno::EWOULDBLOCK)) => {
                        thread::sleep(POLL);
                        fd = back;
                    }
                    Err((_, errno)) => return Err(LockError::Lock(errno)),
                }
            };
            let held = fstat(flock.as_raw_fd()).map_err(LockError::Stat)?;
            match fstatat(
                Some(dir.as_raw_fd()),
                name.as_path(),
                AtFlags::AT_SYMLINK_NOFOLLOW,
            ) {
                Ok(linked) if (linked.st_dev, linked.st_ino) == (held.st_dev, held.st_ino) => {
                    return Ok(Self {
                        dir,
                        name: name.to_owned(),
                        _flock: flock,
                    })
                }
                Ok(_) | Err(Errno::ENOENT) => {}
                Err(errno) => return Err(LockError::Stat(errno)),
            }
        }
    }

    pub fn remove(self) -> nix::Result<()> {
        self.dir.unlinkat(&self.name)
    }
}

#[cfg(test)]
mod tests {
    use super::{FileLock, LockError};
    use crate::dir::SafeDir;
    use crate::file::{OpenFlags, SafeFile};
    use crate::path::{IsAbsolute, SafePathBuf, StrictComponent, StrictComponents};
    use assert_fs::prelude::*;
    use assert_fs::TempDir;
    use rstest::{fixture, rstest};
    use std::assert_matches;
    use std::process::Command;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::mpsc;
    use std::thread;
    use std::time::Duration;

    const NAME: &StrictComponent = StrictComponent::from_static("vm.lock");
    const WAIT: Duration = Duration::from_secs(10);
    const HELD_FOR: Duration = Duration::from_millis(300);

    struct Dir {
        tmp: TempDir,
        dir: SafeDir,
    }

    #[fixture]
    fn dir() -> Dir {
        let tmp = TempDir::new().unwrap();
        let path: SafePathBuf<IsAbsolute, StrictComponents> =
            tmp.path().to_path_buf().try_into().unwrap();
        let dir = SafeFile::open(&path, OpenFlags::RDONLY).unwrap();
        Dir { tmp, dir }
    }

    #[rstest]
    fn acquire_waits_until_the_holder_releases(dir: Dir) {
        let released = AtomicBool::new(false);
        let (held, wait_held) = mpsc::channel();

        thread::scope(|scope| {
            scope.spawn(|| {
                let lock = FileLock::acquire(&dir.dir, NAME, WAIT).unwrap();
                held.send(()).unwrap();
                thread::sleep(HELD_FOR);
                released.store(true, Ordering::SeqCst);
                drop(lock);
            });
            wait_held.recv().unwrap();

            let _lock = FileLock::acquire(&dir.dir, NAME, WAIT).unwrap();
            assert!(released.load(Ordering::SeqCst));
        });
    }

    #[rstest]
    fn acquire_times_out_while_another_holder_keeps_it(dir: Dir) {
        let _held = FileLock::acquire(&dir.dir, NAME, WAIT).unwrap();

        assert_matches!(
            FileLock::acquire(&dir.dir, NAME, HELD_FOR).err(),
            Some(LockError::TimedOut(_))
        );
    }

    #[rstest]
    fn an_execed_child_does_not_keep_the_lock(dir: Dir) {
        let held = FileLock::acquire(&dir.dir, NAME, WAIT).unwrap();
        let mut child = Command::new("sleep").arg("30").spawn().unwrap();
        drop(held);

        let reacquired = FileLock::acquire(&dir.dir, NAME, Duration::ZERO);
        child.kill().unwrap();
        child.wait().unwrap();

        assert!(reacquired.is_ok(), "{:?}", reacquired.err());
    }

    #[rstest]
    fn a_waiter_on_a_removed_lock_takes_a_fresh_linked_one(dir: Dir) {
        let held = FileLock::acquire(&dir.dir, NAME, WAIT).unwrap();

        thread::scope(|scope| {
            let waiter = scope.spawn(|| FileLock::acquire(&dir.dir, NAME, WAIT).unwrap());
            thread::sleep(HELD_FOR);
            held.remove().unwrap();
            let _waiter = waiter.join().unwrap();

            dir.tmp.child("vm.lock").assert(predicates::path::exists());
            assert_matches!(
                FileLock::acquire(&dir.dir, NAME, Duration::ZERO).err(),
                Some(LockError::TimedOut(_))
            );
        });
    }
}
