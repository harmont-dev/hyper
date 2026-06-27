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
//! If privileges can't be lowered we abort rather than continue as root: neither a
//! constructor nor a Drop impl can report an error, and silently staying root
//! would defeat the point.

use nix::unistd::{getuid, seteuid, setgroups, setresgid, setresuid, Gid, Uid};
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

fn lower() -> Result<(), Error> {
    seteuid(getuid()).map_err(|_| Error::DropPrivileges)
}

#[must_use = "privileges are dropped when the guard is dropped; bind it for the privileged scope"]
pub struct Privileged {
    // Private so a guard can only be built via `acquire`.
    _seal: (),
}

impl Privileged {
    /// Raise to root (euid=0) for the lifetime of the guard. This is the only
    /// place the process ever becomes root; the guard lowers back on drop.
    pub fn acquire() -> Result<Self, Error> {
        seteuid(Uid::from_raw(0)).map_err(|_| Error::NotSetuidRoot)?;
        Ok(Self { _seal: () })
    }

    /// Verify we can promote to root and back down. Used by the `sys-test`
    /// command to check the helper is correctly installed.
    pub fn smoke_test() -> Result<(), Error> {
        // Raises here, and the guard lowers again when dropped at end of scope.
        let _guard = Self::acquire()?;
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
/// Order matters and each step needs the privilege the previous one preserves:
///   1. `seteuid(0)` — regain effective root; without it the rest are EPERM.
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
