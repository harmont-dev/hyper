mod events;

pub use events::{Events, EventsState, ReadError};

use crate::fs::dir::SafeDir;
use crate::fs::file::{self, Any, IsDirectory, OpenFlags, SafeFile};
use crate::fs::path::{
    IsAbsolute, SafePath, StrictComponent, StrictComponentBuf, StrictComponents,
};
use nix::errno::Errno;
use nix::sys::stat::Mode;
use nix::sys::statfs::{fstatfs, CGROUP2_SUPER_MAGIC};
use std::io::{self, Write};
use std::path::PathBuf;
use std::time::{Duration, Instant};
use thiserror::Error as ThisError;

pub const ROOT: &str = "/sys/fs/cgroup";

const KILL: &StrictComponent = StrictComponent::from_static("cgroup.kill");
const EVENTS: &StrictComponent = StrictComponent::from_static("cgroup.events");

#[derive(Debug, ThisError)]
pub enum OpenError {
    #[error("cgroup path has no parent: {0:?}")]
    NoParent(PathBuf),
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
    name: StrictComponentBuf,
}

impl Cgroup {
    /// Open a handle to this cgroup.
    pub fn open(path: &SafePath<IsAbsolute, StrictComponents>) -> Result<Self, OpenError> {
        let Some((parent, name)) = path.split_last() else {
            return Err(OpenError::NoParent(path.as_ref().to_path_buf()));
        };
        let parent = SafeDir::open(parent, OpenFlags::RDONLY)?;

        let leaf: SafeDir = parent.openat(name, OpenFlags::RDONLY, Mode::empty())?;
        if fstatfs(&leaf).map_err(OpenError::Statfs)?.filesystem_type() != CGROUP2_SUPER_MAGIC {
            return Err(OpenError::NotCgroup(path.as_ref().to_path_buf()));
        }

        Ok(Self {
            parent,
            name: name.to_owned(),
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

        let kill_path = self.name.as_path().join(KILL);
        let mut kill: SafeFile<Any, Any, Any> =
            match self
                .parent
                .openat(&kill_path, OpenFlags::WRONLY, Mode::empty())
            {
                Ok(kill) => kill,
                Err(file::ValidationError::Open(Errno::ENODEV)) => return Ok(()),
                Err(file::ValidationError::Open(Errno::ENOENT)) => {
                    return match self.parent.openat::<IsDirectory, Any, Any>(
                        &*self.name,
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
            self.name.as_path().join(EVENTS),
            OpenFlags::RDONLY,
            Mode::empty(),
        )?;
        Ok(Events::new(file))
    }

    /// Remove the cgroup.
    pub fn remove(self) -> Result<(), Errno> {
        match self.parent.rmdirat(&self.name) {
            Ok(()) | Err(Errno::ENOENT) => Ok(()),
            Err(e) => Err(e),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{Cgroup, OpenError, ROOT};
    use crate::fs::path::{IsAbsolute, SafePath, StrictComponents};
    use nix::errno::Errno;
    use nix::libc::SIGKILL;
    use std::fs;
    use std::os::unix::process::ExitStatusExt;
    use std::path::{Path, PathBuf};
    use std::process::{Child, Command};
    use std::time::Duration;

    const TIMEOUT: Duration = Duration::from_secs(5);

    fn open(path: &Path) -> Result<Cgroup, OpenError> {
        let path: &SafePath<IsAbsolute, StrictComponents> = path.try_into().unwrap();
        Cgroup::open(path)
    }

    struct Scratch(PathBuf);

    impl Scratch {
        fn new(test: &str) -> Option<Self> {
            if !nix::unistd::geteuid().is_root() {
                eprintln!("SKIP {test}: needs root to create a cgroup");
                return None;
            }
            let path = Path::new(ROOT).join(format!("hyper-test-{}-{test}", std::process::id()));
            match fs::create_dir(&path) {
                Ok(()) => Some(Self(path)),
                Err(e) => {
                    eprintln!("SKIP {test}: creating {path:?}: {e}");
                    None
                }
            }
        }

        fn spawn_member(&self) -> Child {
            let child = Command::new("sleep").arg("600").spawn().unwrap();
            fs::write(self.0.join("cgroup.procs"), child.id().to_string()).unwrap();
            child
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = fs::write(self.0.join("cgroup.kill"), "1");
            for _ in 0..50 {
                if fs::remove_dir(&self.0).is_ok() || !self.0.exists() {
                    return;
                }
                std::thread::sleep(Duration::from_millis(100));
            }
        }
    }

    #[test]
    fn open_refuses_a_directory_that_is_not_on_cgroup2() {
        let dir = tempfile::tempdir().unwrap();
        let leaf = dir.path().join("leaf");
        fs::create_dir(&leaf).unwrap();

        let got = open(&leaf);

        assert!(
            matches!(got, Err(OpenError::NotCgroup(ref p)) if *p == leaf),
            "{:?}",
            got.err()
        );
    }

    #[test]
    fn a_populated_cgroup_is_only_removable_after_kill_procs_as_root() {
        let Some(scratch) = Scratch::new("kill-then-remove") else {
            return;
        };
        let mut members = [scratch.spawn_member(), scratch.spawn_member()];

        assert_eq!(open(&scratch.0).unwrap().remove(), Err(Errno::EBUSY));

        let cgroup = open(&scratch.0).unwrap();
        cgroup.kill_procs(TIMEOUT).unwrap();
        assert!(!cgroup.events().unwrap().read().unwrap().populated);
        cgroup.remove().unwrap();

        assert!(!scratch.0.exists());
        for member in &mut members {
            assert_eq!(member.wait().unwrap().signal(), Some(SIGKILL));
        }
    }

    #[test]
    fn kill_procs_and_remove_succeed_once_the_cgroup_is_gone_as_root() {
        let Some(scratch) = Scratch::new("vanished") else {
            return;
        };
        let cgroup = open(&scratch.0).unwrap();
        fs::remove_dir(&scratch.0).unwrap();

        cgroup.kill_procs(TIMEOUT).unwrap();
        cgroup.remove().unwrap();
    }
}
