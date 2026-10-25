//! Linux capability masks for the privilege guard.
//!
//! Raising euid to 0 hands a process every capability in its permitted set, so
//! euid alone is all-or-nothing. [`Caps`] names the subset an operation actually
//! needs; [`crate::util::setuid_privileged::Privileged`] narrows the effective set
//! to it for in-process work, and [`confine_exec`] narrows a child's bounding,
//! permitted and effective sets to it before `execve`.
//!
//! The child confinement is required, not belt-and-braces: when a process with
//! uid 0 execs, the kernel treats the image as carrying every file capability and
//! computes the new permitted set from the *bounding* set alone, ignoring the
//! parent's effective set. Only shrinking the bounding set in the forked child
//! limits what an exec'd tool receives.
//!
//! Threat model: a confused deputy, not code execution in the helper. A
//! compromised helper can still `seteuid(0)` and raise its own effective set;
//! the mask stops a mis-routed in-process operation (or a subverted `losetup`,
//! `dmsetup`, `ip`, jailer...) from using a capability its operation never needed.
//!
//! ## Laws (tested in `tests/util/caps.rs`)
//! - Inside a guard over mask `m`, the effective set is exactly `m`; after the
//!   guard drops it is empty.
//! - A child spawned under mask `m` execs with effective, permitted and bounding
//!   sets exactly `m`, and empty inheritable and ambient sets.
//! - An operation needing a capability outside the mask fails with `EPERM`.

use nix::errno::Errno;
use nix::libc;
use std::ops::BitOr;

/// A set of Linux capabilities, one bit per capability number (`CAP_CHOWN` = bit
/// 0, as in `<linux/capability.h>`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Caps(u64);

impl Caps {
    pub const CHOWN: Self = Self::nr(0);
    pub const DAC_OVERRIDE: Self = Self::nr(1);
    pub const DAC_READ_SEARCH: Self = Self::nr(2);
    pub const FOWNER: Self = Self::nr(3);
    pub const SETGID: Self = Self::nr(6);
    pub const SETUID: Self = Self::nr(7);
    pub const NET_ADMIN: Self = Self::nr(12);
    pub const SYS_ADMIN: Self = Self::nr(21);
    pub const MKNOD: Self = Self::nr(27);

    const fn nr(n: u32) -> Self {
        Self(1 << n)
    }

    pub const fn empty() -> Self {
        Self(0)
    }

    /// `const`-usable `|`, so tool masks can be declared as associated consts.
    pub const fn union(self, other: Self) -> Self {
        Self(self.0 | other.0)
    }

    pub const fn contains(self, other: Self) -> bool {
        self.0 & other.0 == other.0
    }

    pub const fn from_bits(bits: u64) -> Self {
        Self(bits)
    }

    pub const fn bits(self) -> u64 {
        self.0
    }
}

impl BitOr for Caps {
    type Output = Self;

    fn bitor(self, other: Self) -> Self {
        self.union(other)
    }
}

/// `_LINUX_CAPABILITY_VERSION_3`: 64-bit sets split across two 32-bit words.
const CAP_VERSION_3: u32 = 0x2008_0522;

#[repr(C)]
struct CapHeader {
    version: u32,
    pid: libc::c_int,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct CapWord {
    effective: u32,
    permitted: u32,
    inheritable: u32,
}

struct CapSets {
    effective: u64,
    permitted: u64,
    inheritable: u64,
}

fn join(lo: u32, hi: u32) -> u64 {
    u64::from(lo) | (u64::from(hi) << 32)
}

// Everything below runs in `pre_exec` (post-fork, pre-exec), so it must stay
// async-signal-safe: stack buffers and raw syscalls only, no allocation.

fn capget() -> Result<CapSets, Errno> {
    let mut header = CapHeader {
        version: CAP_VERSION_3,
        pid: 0,
    };
    let mut data = [CapWord::default(); 2];
    // SAFETY: header and data are valid, correctly sized v3 buffers.
    let rc = unsafe { libc::syscall(libc::SYS_capget, &mut header, data.as_mut_ptr()) };
    Errno::result(rc)?;
    Ok(CapSets {
        effective: join(data[0].effective, data[1].effective),
        permitted: join(data[0].permitted, data[1].permitted),
        inheritable: join(data[0].inheritable, data[1].inheritable),
    })
}

fn capset(sets: &CapSets) -> Result<(), Errno> {
    let mut header = CapHeader {
        version: CAP_VERSION_3,
        pid: 0,
    };
    let word = |shift: u32| CapWord {
        effective: (sets.effective >> shift) as u32,
        permitted: (sets.permitted >> shift) as u32,
        inheritable: (sets.inheritable >> shift) as u32,
    };
    let data = [word(0), word(32)];
    // SAFETY: header and data are valid, correctly sized v3 buffers.
    let rc = unsafe { libc::syscall(libc::SYS_capset, &mut header, data.as_ptr()) };
    Errno::result(rc).map(drop)
}

/// Set the calling thread's effective set to `caps` (clamped to the permitted
/// set, which is never touched), leaving permitted and inheritable as they are.
pub fn set_effective(caps: Caps) -> Result<(), Errno> {
    let current = capget()?;
    capset(&CapSets {
        effective: caps.0 & current.permitted,
        ..current
    })
}

/// Raise the calling thread's effective set to its whole permitted set.
pub fn raise_effective() -> Result<(), Errno> {
    let current = capget()?;
    capset(&CapSets {
        effective: current.permitted,
        ..current
    })
}

/// The calling thread's effective set.
pub fn effective() -> Result<Caps, Errno> {
    capget().map(|sets| Caps(sets.effective))
}

/// Irreversibly confine the calling (forked, about-to-exec) process to `caps`:
/// raise effective to permitted so `CAP_SETPCAP` is usable, drop every other
/// capability from the bounding set, clear the ambient set, then set effective
/// and permitted to `caps` and inheritable to empty. Because uid-0 exec derives
/// the new permitted set from the bounding set, the exec'd image gets exactly
/// `caps`. Never call this in the helper's own process.
pub fn confine_exec(caps: Caps) -> Result<(), Errno> {
    raise_effective()?;
    let permitted = capget()?.permitted;

    for nr in 0..64 {
        if caps.contains(Caps::nr(nr)) {
            continue;
        }
        // SAFETY: prctl with integer arguments only.
        let rc = unsafe { libc::prctl(libc::PR_CAPBSET_DROP, nr as libc::c_ulong, 0, 0, 0) };
        match Errno::result(rc) {
            Ok(_) => {}
            // Past CAP_LAST_CAP: no higher capability numbers exist.
            Err(Errno::EINVAL) => break,
            Err(e) => return Err(e),
        }
    }

    // SAFETY: prctl with integer arguments only.
    let rc = unsafe {
        libc::prctl(
            libc::PR_CAP_AMBIENT,
            libc::PR_CAP_AMBIENT_CLEAR_ALL as libc::c_ulong,
            0,
            0,
            0,
        )
    };
    match Errno::result(rc) {
        // EINVAL: pre-4.3 kernel without ambient capabilities, nothing to clear.
        Ok(_) | Err(Errno::EINVAL) => {}
        Err(e) => return Err(e),
    }

    let keep = caps.0 & permitted;
    capset(&CapSets {
        effective: keep,
        permitted: keep,
        inheritable: 0,
    })
}
