mod events;

pub use events::{Events, EventsState, ReadError};

use crate::fs::dir::SafeDir;
use crate::fs::file::{self, Any, IsDirectory, OpenFlags, SafeFile};
use crate::fs::path::{self, IsAbsolute, SafePath, StrictComponents};
use nix::errno::Errno;
use nix::sys::stat::Mode;
use nix::sys::statfs::{fstatfs, CGROUP2_SUPER_MAGIC};
use std::ffi::OsString;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};
use thiserror::Error as ThisError;

#[derive(Debug, ThisError)]
pub enum OpenError {
    #[error("cgroup path has no parent: {0:?}")]
    NoParent(PathBuf),
    #[error("cgroup parent path: {0}")]
    Path(#[from] path::ValidationError),
    #[error(transparent)]
    Open(#[from] file::ValidationError),
    #[error("statfs on cgroup: {0}")]
    Statfs(#[source] Errno),
    #[error("{0:?} is not on a cgroup2 filesystem")]
    NotCgroup(PathBuf),
}

#[derive(Debug, ThisError)]
pub enum KillError {
    #[error("this kernel has no cgroup.kill (needs Linux 5.14+)")]
    Unsupported,
    #[error("opening cgroup.kill: {0}")]
    Open(#[source] file::ValidationError),
    #[error("writing cgroup.kill: {0}")]
    Write(#[source] io::Error),
    #[error("opening cgroup.events: {0}")]
    Events(#[source] file::ValidationError),
    #[error(transparent)]
    Read(#[from] ReadError),
    #[error("waiting on cgroup.events: {0}")]
    Wait(#[source] Errno),
    #[error("cgroup still has processes {0:?} after SIGKILL")]
    TimedOut(Duration),
}

pub struct Cgroup {
    parent: SafeDir,
    name: OsString,
}

impl Cgroup {
    /// Open a handle to this cgroup.
    pub fn open(path: &SafePath<IsAbsolute, StrictComponents>) -> Result<Self, OpenError> {
        let full: &Path = path.as_ref();
        let (Some(parent), Some(name)) = (full.parent(), full.file_name()) else {
            return Err(OpenError::NoParent(full.to_path_buf()));
        };

        let parent: &SafePath<IsAbsolute, StrictComponents> = parent.try_into()?;
        let parent = SafeDir::open(parent, OpenFlags::RDONLY)?;

        let leaf: SafeDir = parent.openat(Path::new(name), OpenFlags::RDONLY, Mode::empty())?;
        if fstatfs(&leaf).map_err(OpenError::Statfs)?.filesystem_type() != CGROUP2_SUPER_MAGIC {
            return Err(OpenError::NotCgroup(full.to_path_buf()));
        }

        Ok(Self {
            parent,
            name: name.to_os_string(),
        })
    }

    /// Kill all processes under this cgroup.
    pub fn kill_procs(&self, timeout: Duration) -> Result<(), KillError> {
        let deadline = Instant::now() + timeout;

        let events = match self.events() {
            Ok(events) => events,
            Err(file::ValidationError::Open(Errno::ENOENT | Errno::ENODEV)) => return Ok(()),
            Err(e) => return Err(KillError::Events(e)),
        };

        let kill_path = Path::new(&self.name).join("cgroup.kill");
        let mut kill: SafeFile<Any, Any, Any> =
            match self
                .parent
                .openat(&kill_path, OpenFlags::WRONLY, Mode::empty())
            {
                Ok(kill) => kill,
                Err(file::ValidationError::Open(Errno::ENODEV)) => return Ok(()),
                Err(file::ValidationError::Open(Errno::ENOENT)) => {
                    return match self.parent.openat::<IsDirectory, Any, Any>(
                        Path::new(&self.name),
                        OpenFlags::PATH,
                        Mode::empty(),
                    ) {
                        Err(file::ValidationError::Open(Errno::ENOENT)) => Ok(()),
                        _ => Err(KillError::Unsupported),
                    };
                }
                Err(e) => return Err(KillError::Open(e)),
            };

        match kill.write_all(b"1") {
            Ok(()) => {}
            Err(e) if e.raw_os_error().map(Errno::from_raw) == Some(Errno::ENODEV) => return Ok(()),
            Err(e) => return Err(KillError::Write(e)),
        }

        loop {
            match events.read() {
                Ok(state) if !state.populated => return Ok(()),
                Ok(_) => {}
                Err(ReadError::Removed) => return Ok(()),
                Err(e) => return Err(e.into()),
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return Err(KillError::TimedOut(timeout));
            }
            events.wait(remaining).map_err(KillError::Wait)?;
        }
    }

    /// Fetch a handle to the events of this cgroup.
    pub fn events(&self) -> Result<Events<'_>, file::ValidationError> {
        let file = self.parent.openat(
            &Path::new(&self.name).join("cgroup.events"),
            OpenFlags::RDONLY,
            Mode::empty(),
        )?;
        Ok(Events::new(file))
    }

    /// Remove the cgroup.
    pub fn remove(self) -> Result<(), Errno> {
        match self.parent.rmdirat(Path::new(&self.name)) {
            Ok(()) | Err(Errno::ENOENT) => Ok(()),
            Err(e) => Err(e),
        }
    }
}
