//! RAII privilege guard.
//!
//! The helper is installed setuid root, so the kernel makes it euid=0 at `exec`.
//! A `.preinit_array` entry ([`drop_to_real`]) immediately drops the effective uid
//! to the caller while keeping the saved-uid (root) so we can re-raise. From then
//! on the process is unprivileged, and **the only way back to root is a
//! [`Privileged`] guard** - raising to root lives nowhere else. The guard lowers
//! privileges again when it goes out of scope, so the root window is exactly the
//! guard's lifetime.
//!
//! Root is not all-or-nothing: each guard carries a [`Caps`] mask, and only that
//! mask is effective inside its scope. Children spawned through the guard
//! ([`Privileged::command`]) exec with exactly that mask too - see
//! [`crate::util::caps`] for why that needs separate handling.
//!
//! If privileges can't be lowered we abort rather than continue as root: neither a
//! constructor nor a Drop impl can report an error, and silently staying root
//! would defeat the point.

use crate::util::caps::{self, Caps};
use nix::unistd::{getuid, seteuid, setgroups, setresgid, setresuid, Gid, Uid};
use std::ffi::OsStr;
use std::io;
use std::os::unix::process::CommandExt;
use std::process::Command;
use thiserror::Error as ThisError;

/// Failures of the privilege transitions. All fatal: if we can't raise we aren't
/// installed setuid root, if we can't lower we refuse to keep running, and if we
/// can't seal permanent root we refuse to hand off to the execve target.
#[derive(Debug, ThisError)]
pub enum Error {
    #[error("not installed setuid root")]
    NotSetuidRoot,
    #[error("failed to drop privileges")]
    DropPrivileges,
    #[error("failed to acquire permanent root for execve handoff")]
    PermanentRoot,
    #[error("failed to restrict capabilities")]
    Capabilities,
}

/// `.preinit_array` runs before `.init_array` and before any shared-library
/// initializer, so this is the first userspace code the process executes - earlier
/// than a normal constructor. It drops effective privileges to the real uid, so
/// root is never held outside a `Privileged` scope.
#[cfg(target_os = "linux")]
#[used]
#[link_section = ".preinit_array"]
static PREINIT_DROP_PRIVILEGES: extern "C" fn() = drop_to_real;

// Runs before the Rust runtime is initialized, so it must avoid std entirely: no
// allocation, no std I/O, and no `std::process::abort` - those assume runtime
// state that doesn't exist this early. `seteuid`/`getuid`/`write`/`_exit` are
// bare syscalls (async-signal-safe) and valid here.
extern "C" fn drop_to_real() {
    if seteuid(getuid()).is_err() {
        const MSG: &[u8] = b"hyper-suidhelper: failed to drop privileges at startup\n";
        // SAFETY: raw FFI to async-signal-safe libc calls; MSG is a static buffer.
        unsafe {
            let _ = nix::libc::write(2, MSG.as_ptr().cast(), MSG.len());
            nix::libc::_exit(1);
        }
    }
}

/// Clear the effective set explicitly before lowering euid. When the caller is
/// genuinely root (ruid 0, as under the e2e suite) `seteuid(getuid())` changes
/// nothing, so the kernel's euid-0-to-non-zero clearing never fires.
fn lower() -> Result<(), Error> {
    caps::set_effective(Caps::empty()).map_err(|_| Error::DropPrivileges)?;
    seteuid(getuid()).map_err(|_| Error::DropPrivileges)
}

#[must_use = "privileges are dropped when the guard is dropped; bind it for the privileged scope"]
pub struct Privileged {
    // Private so a guard can only be built via `acquire`.
    caps: Caps,
}

impl Privileged {
    /// Raise to root (euid=0) with exactly `caps` effective, for the lifetime of
    /// the guard. This is the only place the process ever becomes root; the
    /// guard lowers back on drop.
    pub fn acquire(caps: Caps) -> Result<Self, Error> {
        seteuid(Uid::from_raw(0)).map_err(|_| Error::NotSetuidRoot)?;
        // Built before narrowing so a failed narrowing still lowers on drop.
        let guard = Self { caps };
        caps::set_effective(caps).map_err(|_| Error::Capabilities)?;
        Ok(guard)
    }

    /// The capability mask this guard holds.
    pub fn caps(&self) -> Caps {
        self.caps
    }

    /// A `Command` whose child execs as root confined to this guard's mask
    /// (bounding, permitted and effective sets all equal to it).
    pub fn command(&self, program: impl AsRef<OsStr>) -> Command {
        let caps = self.caps;
        let mut cmd = Command::new(program);
        // SAFETY: `confine_exec` uses only stack buffers and raw capget/capset/
        // prctl syscalls, the async-signal-safe contract `pre_exec` requires.
        unsafe {
            cmd.pre_exec(move || caps::confine_exec(caps).map_err(io::Error::from));
        }
        cmd
    }

    /// Like [`command`](Self::command), but the child first becomes genuine root
    /// (real, effective and saved uid all 0; see [`become_root_permanently`]) for
    /// binaries that refuse to run under `AT_SECURE`, such as `ip` and `nft`.
    pub fn root_command(&self, program: impl AsRef<OsStr>) -> Command {
        let caps = self.caps;
        let mut cmd = Command::new(program);
        // SAFETY: as in `command`; `become_root_permanently` likewise makes only
        // async-signal-safe setresuid/setresgid/setgroups/capset syscalls.
        unsafe {
            cmd.pre_exec(move || {
                become_root_permanently().map_err(io::Error::other)?;
                caps::confine_exec(caps).map_err(io::Error::from)
            });
        }
        cmd
    }

    /// Verify we can promote to root and back down. Used by the `sys-test`
    /// command to check the helper is correctly installed.
    pub fn smoke_test() -> Result<(), Error> {
        // Raises here, and the guard lowers again when dropped at end of scope.
        let _guard = Self::acquire(Caps::empty())?;
        Ok(())
    }
}

/// Re-acquire full root **permanently** for an `execve` handoff and return —
/// there is deliberately no [`Privileged`] Drop guard, because `execve` replaces
/// the entire process image: nothing of this process survives to run a destructor,
/// and the new image (the firecracker jailer) is responsible for dropping its own
/// privileges. We must hand it a *genuine* root process (all of real, effective
/// and saved uid == 0) so the jailer's own privilege-drop is the real thing.
///
/// The caller must confine capabilities before `execve` (see
/// [`caps::confine_exec`]); this only sets ids.
///
/// Order matters and each step needs the privilege the previous one preserves:
///   1. `seteuid(0)` and raise effective to permitted — regain effective root
///      with `CAP_SETGID` (an enclosing guard may have narrowed it away);
///      without them the rest are EPERM.
///   2. `setresgid(0,0,0)` — set every gid to root *before* touching uids, while
///      we still hold euid 0 (gid changes require privilege).
///   3. `setgroups([0])` — `drop_to_real` only lowered euid; it never touched the
///      caller's supplementary groups, so the jailer would otherwise inherit them.
///      Reset to just {0} now, while still privileged.
///   4. `setresuid(0,0,0)` LAST — this seals real+effective+saved uid to root. It
///      goes last because once the saved uid is 0 there is no escape hatch left
///      (which is the point: permanent), and because it must follow the gid/group
///      changes that needed our euid-0 to be permitted.
pub fn become_root_permanently() -> Result<(), Error> {
    let root_uid = Uid::from_raw(0);
    let root_gid = Gid::from_raw(0);

    seteuid(root_uid).map_err(|_| Error::NotSetuidRoot)?;
    caps::raise_effective().map_err(|_| Error::PermanentRoot)?;
    setresgid(root_gid, root_gid, root_gid).map_err(|_| Error::PermanentRoot)?;
    setgroups(&[root_gid]).map_err(|_| Error::PermanentRoot)?;
    setresuid(root_uid, root_uid, root_uid).map_err(|_| Error::PermanentRoot)?;

    Ok(())
}

impl Drop for Privileged {
    fn drop(&mut self) {
        if lower().is_err() {
            eprintln!("hyper-suidhelper: failed to drop privileges; aborting");
            std::process::abort();
        }
    }
}
