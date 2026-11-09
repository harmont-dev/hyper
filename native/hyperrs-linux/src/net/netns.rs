// SPDX-License-Identifier: MIT

use super::{IfName, Rtnl, RtnlOpenError, IFNAMSIZ};
use hyperrs_fs::dev::DeviceNumber;
use hyperrs_fs::dir::{DirError, SafeDir};
use hyperrs_fs::file::{self, Any, IsCharDevice, OpenFlags, SafeFile};
use hyperrs_fs::path::{
    IsAbsolute, SafePath, SafePathBuf, StrictComponent, StrictComponentBuf, StrictComponents,
};
use nix::errno::Errno;
use nix::libc::{c_short, IFF_NO_PI, IFF_TAP, IFF_TUN_EXCL};
use nix::mount::{mount, umount2, MntFlags, MsFlags};
use nix::sched::{setns, unshare, CloneFlags};
use nix::sys::stat::Mode;
use nix::sys::statfs::{fstatfs, NSFS_MAGIC};
use nix::unistd::{Gid, Uid};
use std::array;
use std::io;
use std::os::fd::{AsFd, AsRawFd, BorrowedFd};
use std::panic;
use std::path::PathBuf;
use std::thread;
use thiserror::Error as ThisError;

pub const RUN_DIR: &str = "/run/netns";
const TUN_PATH: &str = "/dev/net/tun";
const TUN_DEVICE: DeviceNumber = DeviceNumber::new(10, 200);

mod ioctl {
    use super::IfReq;
    use nix::libc::c_int;
    use std::mem::size_of;

    nix::ioctl_readwrite_bad!(
        set_iff,
        nix::request_code_write!(b'T', 202, size_of::<c_int>()),
        IfReq
    );
    nix::ioctl_write_int_bad!(
        set_persist,
        nix::request_code_write!(b'T', 203, size_of::<c_int>())
    );
    nix::ioctl_write_int_bad!(
        set_owner,
        nix::request_code_write!(b'T', 204, size_of::<c_int>())
    );
    nix::ioctl_write_int_bad!(
        set_group,
        nix::request_code_write!(b'T', 206, size_of::<c_int>())
    );
}

#[repr(C)]
struct IfReq {
    name: [u8; IFNAMSIZ],
    flags: c_short,
    pad: [u8; 22],
}

const _: () = assert!(std::mem::size_of::<IfReq>() == 40);

#[derive(Debug, ThisError)]
pub enum CreateError {
    #[error("network namespace {0:?} already exists")]
    Exists(StrictComponentBuf),
    #[error("opening {RUN_DIR}: {0}")]
    RunDir(#[source] DirError),
    #[error("creating the mount point for {0:?}: {1}")]
    MountPoint(StrictComponentBuf, #[source] file::ValidationError),
    #[error("spawning the namespace thread: {0}")]
    Spawn(#[source] io::Error),
    #[error("unshare(CLONE_NEWNET): {0}")]
    Unshare(#[source] Errno),
    #[error("bind-mounting the namespace: {0}")]
    Mount(#[source] Errno),
    #[error(transparent)]
    Open(#[from] OpenError),
}

#[derive(Debug, ThisError)]
pub enum OpenError {
    #[error(transparent)]
    Open(#[from] file::ValidationError),
    #[error("statfs on network namespace: {0}")]
    Statfs(#[source] Errno),
    #[error("{0:?} is not a network namespace")]
    NotNetNs(PathBuf),
}

#[derive(Debug, ThisError)]
pub enum RemoveError {
    #[error("opening {RUN_DIR}: {0}")]
    RunDir(#[source] file::ValidationError),
    #[error("unmounting network namespace {0:?}: {1}")]
    Unmount(StrictComponentBuf, #[source] Errno),
    #[error("unlinking network namespace {0:?}: {1}")]
    Unlink(StrictComponentBuf, #[source] Errno),
}

#[derive(Debug, ThisError)]
pub enum EnterError {
    #[error("spawning the namespace thread: {0}")]
    Spawn(#[source] io::Error),
    #[error("setns(CLONE_NEWNET): {0}")]
    Setns(#[source] Errno),
}

#[derive(Debug, ThisError)]
pub enum RtnlError {
    #[error(transparent)]
    Enter(#[from] EnterError),
    #[error(transparent)]
    Open(#[from] RtnlOpenError),
}

#[derive(Debug, ThisError)]
pub enum TapError {
    #[error(transparent)]
    Enter(#[from] EnterError),
    #[error("opening {TUN_PATH}: {0}")]
    Open(#[source] file::ValidationError),
    #[error("{TUN_PATH} is device {0}, not the tun device")]
    WrongDevice(DeviceNumber),
    #[error("tap {0} already exists")]
    Exists(IfName),
    #[error("TUNSETIFF {0}: {1}")]
    SetIff(IfName, #[source] Errno),
    #[error("TUNSETOWNER {0}: {1}")]
    SetOwner(IfName, #[source] Errno),
    #[error("TUNSETGROUP {0}: {1}")]
    SetGroup(IfName, #[source] Errno),
    #[error("TUNSETPERSIST {0}: {1}")]
    Persist(IfName, #[source] Errno),
}

pub struct NetNs {
    file: SafeFile<Any, Any, Any>,
    name: StrictComponentBuf,
}

impl NetNs {
    /// Create a new namespace and pin it at `/run/netns/<name>`.
    pub fn create(name: &StrictComponent) -> Result<Self, CreateError> {
        let run = SafeDir::open(SafePath::from_static::<"/run">(), OpenFlags::RDONLY)
            .map_err(|e| CreateError::RunDir(e.into()))?;
        let netns = run
            .ensure_dir(
                StrictComponent::from_static("netns"),
                Mode::from_bits_truncate(0o755),
            )
            .map_err(CreateError::RunDir)?;
        match netns.mkfileat(name, Mode::from_bits_truncate(0o444)) {
            Ok(_) => {}
            Err(file::ValidationError::Open(Errno::EEXIST)) => {
                return Err(CreateError::Exists(name.to_owned()))
            }
            Err(e) => return Err(CreateError::MountPoint(name.to_owned(), e)),
        }

        let target = Self::path(name);
        let bound = thread::scope(|scope| {
            let worker = thread::Builder::new()
                .spawn_scoped(scope, || {
                    unshare(CloneFlags::CLONE_NEWNET).map_err(CreateError::Unshare)?;
                    mount(
                        Some("/proc/thread-self/ns/net"),
                        target.as_path(),
                        None::<&str>,
                        MsFlags::MS_BIND,
                        None::<&str>,
                    )
                    .map_err(CreateError::Mount)
                })
                .map_err(CreateError::Spawn)?;
            worker.join().unwrap_or_else(|e| panic::resume_unwind(e))
        });

        if let Err(e) = bound {
            let _ = netns.unlinkat(name);
            return Err(e);
        }

        Ok(Self::open(name)?)
    }

    /// Open the namespace pinned at `/run/netns/<name>`.
    pub fn open(name: &StrictComponent) -> Result<Self, OpenError> {
        let path = Self::path(name);
        let file: SafeFile<Any, Any, Any> = SafeFile::open(&path, OpenFlags::RDONLY)?;
        if fstatfs(&file).map_err(OpenError::Statfs)?.filesystem_type() != NSFS_MAGIC {
            return Err(OpenError::NotNetNs(path.as_path().to_path_buf()));
        }
        Ok(Self {
            file,
            name: name.to_owned(),
        })
    }

    /// Unpin the namespace; one that is already gone is `Ok`.
    pub fn remove(self) -> Result<(), RemoveError> {
        let Self { file, name } = self;
        drop(file);
        match umount2(Self::path(&name).as_path(), MntFlags::MNT_DETACH) {
            Ok(()) | Err(Errno::EINVAL | Errno::ENOENT) => {}
            Err(e) => return Err(RemoveError::Unmount(name, e)),
        }
        let netns: SafeDir = SafeFile::open(SafePath::from_static::<RUN_DIR>(), OpenFlags::RDONLY)
            .map_err(RemoveError::RunDir)?;
        match netns.unlinkat(&name) {
            Ok(()) | Err(Errno::ENOENT) => Ok(()),
            Err(e) => Err(RemoveError::Unlink(name, e)),
        }
    }

    fn path(name: &StrictComponent) -> SafePathBuf<IsAbsolute, StrictComponents> {
        SafePath::from_static::<RUN_DIR>().join(name)
    }

    /// The name the namespace is pinned under in `/run/netns`.
    pub fn name(&self) -> &StrictComponent {
        &self.name
    }

    /// Run `f` on a thread inside this namespace and return its result.
    pub fn scoped<T: Send>(&self, f: impl FnOnce() -> T + Send) -> Result<T, EnterError> {
        thread::scope(|scope| {
            let worker = thread::Builder::new()
                .spawn_scoped(scope, || {
                    setns(&self.file, CloneFlags::CLONE_NEWNET).map_err(EnterError::Setns)?;
                    Ok(f())
                })
                .map_err(EnterError::Spawn)?;
            worker.join().unwrap_or_else(|e| panic::resume_unwind(e))
        })
    }

    /// Open an rtnetlink socket bound to this namespace.
    pub fn rtnl(&self) -> Result<Rtnl, RtnlError> {
        self.scoped(Rtnl::open)?.map_err(RtnlError::Open)
    }

    /// Create a persistent tap named `name` in this namespace, owned by `uid`:`gid`.
    pub fn create_tap(&self, name: &IfName, uid: Uid, gid: Gid) -> Result<(), TapError> {
        self.scoped(|| -> Result<(), TapError> {
            let tun: SafeFile<IsCharDevice, Any, Any> =
                SafeFile::open(SafePath::from_static::<TUN_PATH>(), OpenFlags::RDWR)
                    .map_err(TapError::Open)?;

            let device = tun.rdev().map_err(TapError::Open)?;
            if device != TUN_DEVICE {
                return Err(TapError::WrongDevice(device));
            }

            let fd = tun.as_raw_fd();

            let mut request = IfReq {
                name: array::from_fn(|i| name.as_str().as_bytes().get(i).copied().unwrap_or(0)),
                flags: (IFF_TAP | IFF_NO_PI | IFF_TUN_EXCL) as c_short,
                pad: [0; 22],
            };

            // SAFETY: `request` is a fully initialised `struct ifreq` the kernel may write back into.
            match unsafe { ioctl::set_iff(fd, &mut request) } {
                Ok(_) => {}
                Err(Errno::EBUSY) => return Err(TapError::Exists(name.clone())),
                Err(e) => return Err(TapError::SetIff(name.clone(), e)),
            }
            // SAFETY: TUNSETOWNER, TUNSETGROUP and TUNSETPERSIST take their argument by value.
            if let Err(e) = unsafe { ioctl::set_owner(fd, uid.as_raw().cast_signed()) } {
                return Err(TapError::SetOwner(name.clone(), e));
            }
            if let Err(e) = unsafe { ioctl::set_group(fd, gid.as_raw().cast_signed()) } {
                return Err(TapError::SetGroup(name.clone(), e));
            }
            if let Err(e) = unsafe { ioctl::set_persist(fd, 1) } {
                return Err(TapError::Persist(name.clone(), e));
            }

            Ok(())
        })?
    }
}

impl AsFd for NetNs {
    fn as_fd(&self) -> BorrowedFd<'_> {
        self.file.as_fd()
    }
}

#[cfg(test)]
mod tests {
    use super::{NetNs, TapError};
    use crate::net::{IfName, Rtnl};
    use assert_fs::TempDir;
    use nix::mount::{mount, MsFlags};
    use nix::sched::{unshare, CloneFlags};
    use nix::unistd::{Gid, Uid};
    use pretty_assertions::assert_eq;
    use rstest::rstest;
    use std::fs;

    struct ScratchNs(Option<NetNs>);

    impl ScratchNs {
        fn new(test: &str) -> Option<Self> {
            if !nix::unistd::geteuid().is_root() {
                eprintln!("SKIP {test}: needs root to create a network namespace");
                return None;
            }
            let name = format!("hyper-test-{}-{test}", std::process::id());
            Some(Self(Some(
                NetNs::create(name.as_str().try_into().unwrap()).unwrap(),
            )))
        }

        fn get(&self) -> &NetNs {
            self.0.as_ref().expect("the namespace lives until drop")
        }
    }

    impl Drop for ScratchNs {
        fn drop(&mut self) {
            if let Some(ns) = self.0.take() {
                let _ = ns.remove();
            }
        }
    }

    fn tap0() -> IfName {
        "hyper-tap0".parse().unwrap()
    }

    #[rstest]
    fn a_tap_outlives_its_fd_in_the_namespace_it_was_created_in_as_root() {
        let Some(ns) = ScratchNs::new("tap") else {
            return;
        };

        ns.get()
            .create_tap(&tap0(), Uid::from_raw(1234), Gid::from_raw(5678))
            .unwrap();

        let present = |rtnl: Rtnl| rtnl.link(&tap0()).unwrap().is_some();
        assert_eq!(
            [
                present(ns.get().rtnl().unwrap()),
                present(Rtnl::open().unwrap())
            ],
            [true, false]
        );
    }

    #[rstest]
    fn a_tap_belongs_to_the_requested_owner_and_group_as_root() {
        let Some(ns) = ScratchNs::new("tap-owner") else {
            return;
        };
        let sysfs = TempDir::new().unwrap();

        ns.get()
            .create_tap(&tap0(), Uid::from_raw(1234), Gid::from_raw(5678))
            .unwrap();
        let owner = ns
            .get()
            .scoped(|| {
                unshare(CloneFlags::CLONE_NEWNS).unwrap();
                mount(
                    None::<&str>,
                    "/",
                    None::<&str>,
                    MsFlags::MS_REC | MsFlags::MS_PRIVATE,
                    None::<&str>,
                )
                .unwrap();
                mount(
                    Some("sysfs"),
                    sysfs.path(),
                    Some("sysfs"),
                    MsFlags::empty(),
                    None::<&str>,
                )
                .unwrap();
                let read = |attr: &str| {
                    fs::read_to_string(sysfs.path().join(format!("class/net/{}/{attr}", tap0())))
                        .unwrap()
                        .trim()
                        .to_owned()
                };
                (read("owner"), read("group"))
            })
            .unwrap();

        assert_eq!(owner, ("1234".to_owned(), "5678".to_owned()));
    }

    #[rstest]
    fn creating_an_existing_tap_is_exists_as_root() {
        let Some(ns) = ScratchNs::new("tap-dup") else {
            return;
        };
        let create = || {
            ns.get()
                .create_tap(&tap0(), Uid::from_raw(0), Gid::from_raw(0))
        };

        create().unwrap();
        let again = create();

        assert!(matches!(again, Err(TapError::Exists(ref name)) if *name == tap0()));
    }
}
