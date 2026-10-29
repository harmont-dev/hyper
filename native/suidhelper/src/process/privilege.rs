//! Setuid privilege utilities.

use derive_more::Display;
use nix::errno::Errno;
use nix::libc::{self, c_uint};
use nix::unistd::{
    getegid, geteuid, getgid, getuid, setegid, seteuid, setgroups, setresgid, setresuid, Gid, Uid,
};
use std::io;
use std::marker::PhantomData;
use std::os::unix::process::CommandExt;
use std::process::Command;
use std::sync::atomic::{AtomicBool, Ordering};
use thiserror::Error as ThisError;

static TAKEN: AtomicBool = AtomicBool::new(false);

#[macro_export]
macro_rules! setuid_main {
    ($entry:path) => {
        #[used]
        #[link_section = ".init_array"]
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
    if setegid(getgid()).is_err() || seteuid(getuid()).is_err() {
        const MSG: &[u8] = b"hyper-suidhelper: failed to drop privileges at startup\n";
        // SAFETY: raw FFI to async-signal-safe libc calls; MSG is a static buffer.
        unsafe {
            let _ = libc::write(2, MSG.as_ptr().cast(), MSG.len());
            libc::_exit(1);
        }
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
    fn spawn_as_root(&mut self, root: &Root<'_>) -> &mut Self;
}

fn seal_root() -> io::Result<()> {
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
}

impl RootCommandExt for Command {
    fn exec_as_root(&mut self, token: Unprivileged) -> ! {
        let Unprivileged { _seal: () } = token;

        self.env_clear();
        // SAFETY: `exec` runs this hook in the current process (there is no fork), right before
        // `execve`.
        unsafe { self.pre_exec(seal_root) };
        let err = self.exec();

        eprintln!("hyper-suidhelper: exec as root failed: {err}");
        // SAFETY: `_exit` terminates without unwinding or running atexit handlers.
        unsafe { libc::_exit(2) }
    }

    fn spawn_as_root(&mut self, _root: &Root<'_>) -> &mut Self {
        self.env_clear();
        // SAFETY: the hook runs in the forked child right before `execve`, and `seal_root` makes
        // only async-signal-safe syscalls and allocates nothing on its success path.
        unsafe { self.pre_exec(seal_root) };
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
