use super::Cgroup;
use crate::fs::file::{Any, IsRegularFile, SafeFile};
use nix::errno::Errno;
use nix::poll::{poll, PollFd, PollFlags, PollTimeout};
use nix::unistd::{lseek, read, Whence};
use std::marker::PhantomData;
use std::os::unix::io::{AsFd, AsRawFd};
use std::str::Utf8Error;
use std::time::Duration;
use thiserror::Error as ThisError;

#[derive(Debug, ThisError)]
pub enum ReadError {
    #[error("cgroup was removed")]
    Removed,
    #[error("reading cgroup.events: {0}")]
    Read(#[source] Errno),
    #[error("cgroup.events is not UTF-8: {0}")]
    Utf8(#[source] Utf8Error),
    #[error("unexpected cgroup.events contents: {0:?}")]
    Malformed(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EventsState {
    pub populated: bool,
    pub frozen: bool,
}

pub struct Events<'a> {
    file: SafeFile<IsRegularFile, Any, Any>,
    cgroup: PhantomData<&'a Cgroup>,
}

impl Events<'_> {
    pub(super) fn new(file: SafeFile<IsRegularFile, Any, Any>) -> Self {
        Self {
            file,
            cgroup: PhantomData,
        }
    }

    pub fn read(&self) -> Result<EventsState, ReadError> {
        let mut buf = [0u8; 256];
        let n = match lseek(self.file.as_raw_fd(), 0, Whence::SeekSet)
            .and_then(|_| read(self.file.as_raw_fd(), &mut buf))
        {
            Ok(n) => n,
            Err(Errno::ENODEV) => return Err(ReadError::Removed),
            Err(e) => return Err(ReadError::Read(e)),
        };
        let text = std::str::from_utf8(&buf[..n]).map_err(ReadError::Utf8)?;
        let flag = |key: &str| {
            text.lines()
                .find_map(|line| line.strip_prefix(key)?.strip_prefix(' '))
                .and_then(|value| match value {
                    "0" => Some(false),
                    "1" => Some(true),
                    _ => None,
                })
        };
        match (flag("populated"), flag("frozen")) {
            (Some(populated), Some(frozen)) => Ok(EventsState { populated, frozen }),
            _ => Err(ReadError::Malformed(text.to_string())),
        }
    }

    pub fn wait(&self, timeout: Duration) -> Result<(), Errno> {
        let timeout = PollTimeout::try_from(timeout).unwrap_or(PollTimeout::MAX);
        match poll(
            &mut [PollFd::new(self.file.as_fd(), PollFlags::POLLPRI)],
            timeout,
        ) {
            Ok(_) | Err(Errno::EINTR) => Ok(()),
            Err(e) => Err(e),
        }
    }
}
