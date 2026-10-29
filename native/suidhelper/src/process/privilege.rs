//! Setuid privilege transitions.
//!
//! A program using this utility runs with privileges lowered to that of the caller. Root is only
//! reachable through the [`Unprivileged`] token.
//!
//! [`Unprivileged::elevate`] returns a [`Root`] guard. While it's in scope, the the process is
//! euid/egid 0. Dropping lowers it back.
//!
//! The helper runs with its effective ids lowered to the caller's. Root is only
//! reachable through the single [`Unprivileged`] token, taken once in `main`:

use derive_more::Display;
use nix::errno::Errno;
use nix::libc::{self, c_uint};
use nix::unistd::{getgid, getuid, setegid, seteuid, setgroups, setresgid, setresuid, Gid, Uid};
use std::io;
use std::marker::PhantomData;
use std::os::unix::process::CommandExt;
use std::process::Command;
use std::sync::atomic::{AtomicBool, Ordering};
use thiserror::Error as ThisError;

static TAKEN: AtomicBool = AtomicBool::new(false);

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
    pub fn take() -> Option<Self> {
        (!TAKEN.swap(true, Ordering::Relaxed)).then_some(Self { _seal: () })
    }

    pub fn elevate(&mut self) -> Result<Root<'_>, Error> {
        seteuid(ROOT_UID).map_err(Error::RaiseUser)?;
        let root = Root {
            _token: PhantomData,
        };
        setegid(ROOT_GID).map_err(Error::RaiseGroup)?;
        Ok(root)
    }
}

pub trait RootCommandExt {
    fn exec_as_root(&mut self, token: Unprivileged) -> io::Error;
}

impl RootCommandExt for Command {
    fn exec_as_root(&mut self, token: Unprivileged) -> io::Error {
        let Unprivileged { _seal: () } = token;
        let hook = || {
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

            let seal = |step| move |errno| io::Error::other(Error::Seal { step, errno });
            seteuid(ROOT_UID).map_err(seal(SealStep::Euid))?;
            setresgid(ROOT_GID, ROOT_GID, ROOT_GID).map_err(seal(SealStep::Gids))?;
            setgroups(&[ROOT_GID]).map_err(seal(SealStep::Groups))?;
            setresuid(ROOT_UID, ROOT_UID, ROOT_UID).map_err(seal(SealStep::Uids))
        };

        self.env_clear();
        // SAFETY: `exec` runs this hook in the current process (there is no
        // fork), right before `execve`.
        unsafe { self.pre_exec(hook) };
        self.exec()
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
