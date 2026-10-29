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

#[cfg(test)]
mod tests {
    use super::{Events, EventsState, ReadError};
    use crate::fs::file::{OpenFlags, SafeFile};
    use crate::fs::path::{IsAbsolute, SafePath, StrictComponents};
    use proptest::prelude::*;
    use std::fs;
    use tempfile::NamedTempFile;

    fn events_over(contents: &[u8]) -> (NamedTempFile, Events<'static>) {
        let tmp = NamedTempFile::new().unwrap();
        fs::write(tmp.path(), contents).unwrap();
        let path: &SafePath<IsAbsolute, StrictComponents> = tmp.path().try_into().unwrap();
        let events = Events::new(SafeFile::open(path, OpenFlags::RDONLY).unwrap());
        (tmp, events)
    }

    fn render(populated: bool, frozen: bool, populated_first: bool, decoys: &[String]) -> String {
        let mut lines = vec![
            format!("populated {}", u8::from(populated)),
            format!("frozen {}", u8::from(frozen)),
        ];
        if !populated_first {
            lines.reverse();
        }
        for (i, decoy) in decoys.iter().enumerate() {
            lines.insert(i % (lines.len() + 1), decoy.clone());
        }
        lines.iter().map(|l| format!("{l}\n")).collect()
    }

    fn decoy() -> impl Strategy<Value = String> {
        prop_oneof![
            "[a-z_]{1,12} [0-9]{1,3}".prop_filter("real key", |s| {
                !s.starts_with("populated ") && !s.starts_with("frozen ")
            }),
            "(populated|frozen)[a-z_]{1,6} [01]",
            "[a-z_]{1,6}(populated|frozen) [01]",
        ]
    }

    proptest! {
        #[test]
        fn reads_exactly_the_populated_and_frozen_flags(
            populated in any::<bool>(),
            frozen in any::<bool>(),
            populated_first in any::<bool>(),
            decoys in proptest::collection::vec(decoy(), 0..4),
        ) {
            let (_tmp, events) = events_over(render(populated, frozen, populated_first, &decoys).as_bytes());
            prop_assert_eq!(events.read().unwrap(), EventsState { populated, frozen });
        }

        #[test]
        fn a_missing_or_non_boolean_flag_is_malformed(
            value in "[^\r\n]{0,32}".prop_filter("boolean", |v| v != "0" && v != "1"),
            corrupt_populated in any::<bool>(),
            drop_line in any::<bool>(),
        ) {
            let (key, other) = if corrupt_populated {
                ("populated", "frozen 0")
            } else {
                ("frozen", "populated 0")
            };
            let contents = if drop_line {
                format!("{other}\n")
            } else {
                format!("{key} {value}\n{other}\n")
            };
            let (_tmp, events) = events_over(contents.as_bytes());
            let got = events.read();
            prop_assert!(matches!(got, Err(ReadError::Malformed(_))), "{:?}: {:?}", contents, got);
        }

        #[test]
        fn every_read_reflects_the_current_contents(
            states in proptest::collection::vec((any::<bool>(), any::<bool>()), 1..8),
        ) {
            let (tmp, events) = events_over(b"");
            for (populated, frozen) in states {
                fs::write(tmp.path(), render(populated, frozen, true, &[])).unwrap();
                prop_assert_eq!(events.read().unwrap(), EventsState { populated, frozen });
            }
        }
    }

    #[test]
    fn non_utf8_contents_are_an_error() {
        let (_tmp, events) = events_over(b"populated \xff\nfrozen 0\n");
        assert!(matches!(events.read(), Err(ReadError::Utf8(_))));
    }
}
