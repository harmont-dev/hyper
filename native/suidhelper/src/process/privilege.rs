//! Setuid privilege utilities.

use derive_more::Display;
use nix::errno::Errno;
use nix::fcntl::{fcntl, FcntlArg, FdFlag};
use nix::libc::{self, c_uint};
use nix::unistd::{
    getegid, geteuid, getgid, getuid, setegid, seteuid, setgroups, setresgid, setresuid, Gid, Uid,
};
use std::io;
use std::marker::PhantomData;
use std::os::unix::io::{AsRawFd, BorrowedFd, RawFd};
use std::os::unix::process::CommandExt;
use std::process::Command;
use std::sync::atomic::{AtomicBool, Ordering};
use thiserror::Error as ThisError;

static TAKEN: AtomicBool = AtomicBool::new(false);

#[macro_export]
macro_rules! setuid_main {
    ($entry:path) => {
        #[used]
        #[link_section = ".init_array.00000"]
        static __HYPER_DROP_PRIVILEGES: extern "C" fn() = $crate::process::privilege::drop_to_real;

        fn main() {
            let token = match $crate::process::privilege::Unprivileged::take() {
                Ok(token) => token,
                Err(e) => {
                    ::std::eprintln!("hyper-suidhelper: {e}");
                    ::std::process::exit(2);
                }
            };
            $entry(token)
        }
    };
}

/// Drop to the real user id. This runs before the Rust runtime is initialized in `.init_array`.
///
/// You shouldn't need to call this yourself. Use `setuid_main!`.
///
/// Exits if it fails.
pub extern "C" fn drop_to_real() {
    // SAFETY: getauxval only reads the auxiliary vector libc saved at startup.
    let (secure, interpreter) = unsafe {
        (
            libc::getauxval(libc::AT_SECURE),
            libc::getauxval(libc::AT_BASE),
        )
    };
    if secure != 0 && interpreter != 0 {
        startup_abort(b"hyper-suidhelper: refusing to run setuid as a dynamically linked binary\n");
    }

    if setegid(getgid()).is_err() || seteuid(getuid()).is_err() {
        startup_abort(b"hyper-suidhelper: failed to drop privileges at startup\n");
    }
}

fn startup_abort(msg: &[u8]) -> ! {
    // SAFETY: raw FFI to async-signal-safe libc calls on a caller-owned buffer.
    unsafe {
        let _ = libc::write(2, msg.as_ptr().cast(), msg.len());
        libc::_exit(1)
    }
}

const ROOT_UID: Uid = Uid::from_raw(0);
const ROOT_GID: Gid = Gid::from_raw(0);
const FIRST_INHERITED_FD: c_uint = 3;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Display)]
pub enum SealStep {
    #[display("euid")]
    Euid,
    #[display("gids")]
    Gids,
    #[display("supplementary groups")]
    Groups,
    #[display("uids")]
    Uids,
}

#[derive(Debug, ThisError)]
pub enum Error {
    #[error("raising euid to root: {0}")]
    RaiseUser(#[source] Errno),
    #[error("raising egid to root: {0}")]
    RaiseGroup(#[source] Errno),
    #[error("sealing permanent root ({step}): {errno}")]
    Seal {
        step: SealStep,
        #[source]
        errno: Errno,
    },
    #[error("marking inherited fds close-on-exec: {0}")]
    MarkCloexec(#[source] Errno),
    #[error("inheriting fd {fd}: {errno}")]
    Inherit {
        fd: RawFd,
        #[source]
        errno: Errno,
    },
}

#[derive(Debug, ThisError)]
pub enum TakeError {
    #[error("the privilege token was already taken")]
    AlreadyTaken,
    #[error("still privileged at startup (euid {euid}, egid {egid}): the pre-main privilege drop did not run")]
    StillPrivileged { euid: Uid, egid: Gid },
}

#[derive(Debug)]
pub struct Unprivileged {
    _seal: (),
}

#[must_use = "privileges are lowered when the guard is dropped; bind it for the privileged scope"]
#[derive(Debug)]
pub struct Root<'a> {
    _token: PhantomData<&'a mut Unprivileged>,
}

impl Unprivileged {
    #[doc(hidden)]
    pub fn take() -> Result<Self, TakeError> {
        let (euid, egid) = (geteuid(), getegid());
        if euid != getuid() || egid != getgid() {
            return Err(TakeError::StillPrivileged { euid, egid });
        }

        if TAKEN.swap(true, Ordering::Relaxed) {
            return Err(TakeError::AlreadyTaken);
        }

        Ok(Self { _seal: () })
    }

    pub fn elevate(&mut self) -> Result<Root<'_>, Error> {
        seteuid(ROOT_UID).map_err(Error::RaiseUser)?;
        setegid(ROOT_GID).map_err(Error::RaiseGroup)?;

        let root = Root {
            _token: PhantomData,
        };

        Ok(root)
    }
}

pub trait RootCommandExt {
    /// Replace this process with the command, as genuine root (real, effective
    /// and saved ids all 0, groups `[0]`, fds above stdio close-on-exec).
    /// Consumes the token. Exits on failure, possibly already root.
    fn exec_as_root(&mut self, token: Unprivileged) -> !;

    /// Make children spawned from this command run as genuine root, like
    /// [`exec_as_root`](Self::exec_as_root). Only the child is affected.
    fn spawn_as_root(&mut self, root: &Root<'_>, inherit: &[BorrowedFd<'_>]) -> &mut Self;
}

fn seal_root(inherit: &[RawFd]) -> io::Result<()> {
    // SAFETY: close_range takes no memory operands.
    let rc = unsafe {
        libc::syscall(
            libc::SYS_close_range,
            FIRST_INHERITED_FD,
            c_uint::MAX,
            libc::CLOSE_RANGE_CLOEXEC,
        )
    };

    if rc != 0 {
        return Err(io::Error::other(Error::MarkCloexec(Errno::last())));
    }

    for &fd in inherit {
        fcntl(fd, FcntlArg::F_SETFD(FdFlag::empty()))
            .map_err(|errno| io::Error::other(Error::Inherit { fd, errno }))?;
    }

    let seal = |step| move |errno| io::Error::other(Error::Seal { step, errno });

    seteuid(ROOT_UID).map_err(seal(SealStep::Euid))?;
    setresgid(ROOT_GID, ROOT_GID, ROOT_GID).map_err(seal(SealStep::Gids))?;
    setgroups(&[ROOT_GID]).map_err(seal(SealStep::Groups))?;
    setresuid(ROOT_UID, ROOT_UID, ROOT_UID).map_err(seal(SealStep::Uids))
}

impl RootCommandExt for Command {
    fn exec_as_root(&mut self, token: Unprivileged) -> ! {
        let Unprivileged { _seal: () } = token;

        self.env_clear();
        // SAFETY: `exec` runs this hook in the current process (there is no fork), right before
        // `execve`.
        unsafe { self.pre_exec(|| seal_root(&[])) };
        let err = self.exec();

        eprintln!("hyper-suidhelper: exec as root failed: {err}");
        // SAFETY: `_exit` terminates without unwinding or running atexit handlers.
        unsafe { libc::_exit(2) }
    }

    fn spawn_as_root(&mut self, _root: &Root<'_>, inherit: &[BorrowedFd<'_>]) -> &mut Self {
        let inherit: Vec<RawFd> = inherit.iter().map(AsRawFd::as_raw_fd).collect();
        self.env_clear();
        // SAFETY: the hook runs in the forked child right before `execve`, and `seal_root` makes
        // only async-signal-safe syscalls and allocates nothing on its success path.
        unsafe { self.pre_exec(move || seal_root(&inherit)) };
        self
    }
}

impl Drop for Root<'_> {
    fn drop(&mut self) {
        let lowered = setegid(getgid()).and_then(|()| seteuid(getuid()));
        if let Err(errno) = lowered {
            eprintln!("hyper-suidhelper: failed to drop privileges ({errno}); aborting");
            std::process::abort();
        }
    }
}

#[cfg(test)]
mod tests {
    //! `Unprivileged` is the single token every privilege transition borrows or
    //! consumes, so nesting is ruled out only if at most one ever exists. Law: the
    //! first `take` in a process yields it and every later `take` refuses, even
    //! after the first token is dropped.

    use super::{RootCommandExt, TakeError, Unprivileged};
    use nix::fcntl::{fcntl, FcntlArg, FdFlag};
    use nix::unistd::geteuid;
    use std::fs::File;
    use std::os::unix::io::{AsFd, AsRawFd};
    use std::process::Command;

    #[test]
    fn at_most_one_token_per_process() {
        {
            let first = Unprivileged::take();
            assert!(first.is_ok(), "first take must yield the token: {first:?}");
            assert!(
                matches!(Unprivileged::take(), Err(TakeError::AlreadyTaken)),
                "second take while held"
            );
        }
        assert!(
            matches!(Unprivileged::take(), Err(TakeError::AlreadyTaken)),
            "take after the first is dropped"
        );
    }

    #[test]
    fn a_root_child_inherits_exactly_the_listed_fds_as_root() {
        if !geteuid().is_root() {
            eprintln!("SKIP a_root_child_inherits: needs root to elevate");
            return;
        }
        let listed = File::open("/dev/null").unwrap();
        let unlisted = File::open("/dev/null").unwrap();
        fcntl(unlisted.as_raw_fd(), FcntlArg::F_SETFD(FdFlag::empty())).unwrap();

        let mut token = Unprivileged::take().unwrap();
        let root = token.elevate().unwrap();
        let out = Command::new("/bin/sh")
            .arg("-c")
            .arg(format!(
                "for fd in {} {}; do if [ -e /proc/self/fd/$fd ]; then printf y; else printf n; fi; done",
                listed.as_raw_fd(),
                unlisted.as_raw_fd()
            ))
            .spawn_as_root(&root, &[listed.as_fd()])
            .output()
            .unwrap();

        assert!(out.status.success(), "{out:?}");
        assert_eq!(String::from_utf8_lossy(&out.stdout), "yn");
    }
}
