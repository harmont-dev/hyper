// SPDX-License-Identifier: MIT
//! Typed invocation of the firecracker jailer: the validated argument newtypes
//! and the `execve` mechanics behind the `jailer` subcommand.
//!
//! Threat model: the BEAM is untrusted. It supplies only the VM id, uid/gid,
//! cgroup settings, and the API socket path — each guarded by a newtype below.
//! Every privileged path (the jailer binary, the firecracker `--exec-file`, the
//! chroot base, the parent cgroup) comes from the root-owned config, never the
//! caller. The refusal contracts on these newtypes are the security core: a
//! compromised BEAM must not be able to name a privileged path, request uid 0,
//! traverse out of the chroot base, inject a flag, or smuggle an
//! environment/fd into root.
//!
//! ## Validator laws (property-tested in `tests/tools/jailer.rs`)
//! - [`validate_id_number`] accepts iff `n != 0 && lo <= n <= hi`; 0 is rejected
//!   for *every* range (uid 0 makes the jailer skip its privilege drop).
//! - [`VmId`] round-trips exactly the allowed charset/length and rejects any
//!   separator, dot, NUL, whitespace, leading dash, empty, or over-long input.
//! - [`CgroupSetting`] re-renders a valid pair to its canonical `key=value` and
//!   rejects unknown keys and values outside the per-key grammar.
//! - [`JailSock`] accepts exactly `/` + one filename and rejects multi-component,
//!   relative, `..`, and NUL/whitespace inputs.

use crate::util::path::ToCStringExt;
use crate::util::setuid_privileged;
use bon::Builder;
use nix::errno::Errno;
use std::ffi::{CString, NulError};
use std::fmt;
use std::path::{Path, PathBuf};
use std::str::FromStr;
use thiserror::Error as ThisError;

/// The jailer protects at most a handful of controllers; an unbounded `--cgroup`
/// list is a caller trying something. Cap it well above any legitimate need.
pub const MAX_CGROUPS: usize = 16;

/// `sun_path` in `sockaddr_un` is 108 bytes on Linux; a socket path longer than
/// that can never be bound, so reject it up front.
const MAX_SOCK_LEN: usize = 108;

#[derive(Debug, ThisError)]
pub enum Error {
    #[error("invalid --id {0:?}: must be 1..=64 chars of [A-Za-z0-9_-], not starting with '-'")]
    VmId(String),
    #[error("invalid --cgroup {0:?}: unknown key or value outside its grammar")]
    Cgroup(String),
    #[error("invalid --api-sock {0:?}: must be /<name> with name in [A-Za-z0-9_.-]")]
    Sock(String),
    #[error("--uid/--gid {value} is zero or outside the configured range [{lo}, {hi}]")]
    IdNumber { value: u32, lo: u32, hi: u32 },
    #[error("too many --cgroup settings: {0} (max {MAX_CGROUPS})")]
    TooManyCgroups(usize),
    #[error(transparent)]
    Privilege(#[from] setuid_privileged::Error),
    #[error("argument contains an interior NUL byte")]
    NulArgument(#[from] NulError),
    #[error("execve {path:?} failed: {errno}")]
    Exec { path: PathBuf, errno: Errno },
}

/// `n != 0 && lo <= n <= hi`. uid/gid 0 is rejected unconditionally: a jailer run
/// with uid 0 skips its privilege drop and leaves firecracker running as root.
pub fn validate_id_number(n: u32, range: (u32, u32)) -> Result<u32, Error> {
    let (lo, hi) = range;
    if n != 0 && lo <= n && n <= hi {
        Ok(n)
    } else {
        Err(Error::IdNumber { value: n, lo, hi })
    }
}

/// A VM id used as a chroot subdirectory name: `[A-Za-z0-9_-]`, length `1..=64`,
/// first character not `-` (so it can never be read as a flag). No `/`, `.`, NUL,
/// or whitespace can appear, so it can never traverse out of the chroot base.
#[derive(Debug, Clone)]
pub struct VmId(String);

impl FromStr for VmId {
    type Err = Error;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let reject = || Error::VmId(s.to_string());
        let bytes = s.as_bytes();
        if !(1..=64).contains(&bytes.len()) {
            return Err(reject());
        }
        if bytes[0] == b'-' {
            return Err(reject());
        }
        if !bytes
            .iter()
            .all(|&b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
        {
            return Err(reject());
        }
        Ok(Self(s.to_string()))
    }
}

impl fmt::Display for VmId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

/// `1..=20` ASCII digits — bounds a numeric cgroup limit without pulling in a
/// regex engine. The upper bound comfortably exceeds `u64::MAX`'s 20 digits.
fn is_digits_1_20(s: &str) -> bool {
    !s.is_empty() && s.len() <= 20 && s.bytes().all(|b| b.is_ascii_digit())
}

/// A single `KEY=VALUE` cgroup setting from an allowlist. The helper re-emits
/// `key=value` itself from the canonical key, so the jailer never sees the
/// caller's raw bytes. Per-key value grammar:
///   - `memory.max` : `[0-9]{1,20}` or the literal `max`
///   - `cpu.max`    : `[0-9]{1,20} [0-9]{1,20}` or `max [0-9]{1,20}`
#[derive(Debug, Clone)]
pub struct CgroupSetting {
    key: &'static str,
    value: String,
}

impl FromStr for CgroupSetting {
    type Err = Error;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let reject = || Error::Cgroup(s.to_string());
        // Split on the FIRST `=`. None of the value grammars contains a `=`, so a
        // second `=` lands in `value` and is rejected by the grammar check below.
        let (raw_key, value) = s.split_once('=').ok_or_else(reject)?;

        let key: &'static str = match raw_key {
            "memory.max" => "memory.max",
            "cpu.max" => "cpu.max",
            _ => return Err(reject()),
        };

        let valid = match key {
            "memory.max" => value == "max" || is_digits_1_20(value),
            "cpu.max" => match value.split_once(' ') {
                Some((quota, period)) => {
                    (quota == "max" || is_digits_1_20(quota)) && is_digits_1_20(period)
                }
                None => false,
            },
            _ => false,
        };

        if valid {
            Ok(Self {
                key,
                value: value.to_string(),
            })
        } else {
            Err(reject())
        }
    }
}

impl fmt::Display for CgroupSetting {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}={}", self.key, self.value)
    }
}

/// The firecracker API socket path: an absolute path that is exactly `/` plus one
/// filename in `[A-Za-z0-9_.-]`. The charset excludes `/`, so the value is always
/// a direct child of `/` with no extra components and no traversal; `.`/`..` as
/// the whole filename are rejected explicitly.
#[derive(Debug, Clone)]
pub struct JailSock(String);

impl FromStr for JailSock {
    type Err = Error;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let reject = || Error::Sock(s.to_string());
        if s.len() > MAX_SOCK_LEN {
            return Err(reject());
        }
        let name = s.strip_prefix('/').ok_or_else(reject)?;
        if name.is_empty() || name == "." || name == ".." {
            return Err(reject());
        }
        if !name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'.' || b == b'-')
        {
            return Err(reject());
        }
        Ok(Self(s.to_string()))
    }
}

impl fmt::Display for JailSock {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

/// A fully-resolved jailer invocation. The privileged fields (`jailer`,
/// `firecracker`, `jail_base`, `parent_cgroup`) must come from trusted config;
/// the caller-supplied fields (`vm`, `uid`, `gid`, `cgroups`, `api_sock`) must
/// already have passed their newtype validation.
#[derive(Builder)]
pub struct Jailer<'a> {
    jailer: &'a Path,
    firecracker: &'a Path,
    jail_base: &'a Path,
    parent_cgroup: &'a str,
    vm: &'a VmId,
    uid: u32,
    gid: u32,
    cgroups: &'a [CgroupSetting],
    api_sock: &'a JailSock,
    /// The netns the jailer must enter (`--netns`), `Some` when VM networking is
    /// enabled. Derived by the caller from trusted config + the validated `vm`
    /// id — never from caller input — and must match the `ip netns add <id>`
    /// path the `network` tool creates.
    netns: Option<&'a Path>,
}

impl Jailer<'_> {
    /// Build the exact argv handed to the jailer. argv[0] is the jailer path. The
    /// caller never names the jailer, the `--exec-file`, the chroot base, the
    /// cgroup version, or the parent cgroup — those come from trusted config.
    fn argv(&self) -> Result<Vec<CString>, Error> {
        let mut argv = vec![
            self.jailer.to_cstring()?,
            "--id".to_cstring()?,
            self.vm.to_string().to_cstring()?,
            "--exec-file".to_cstring()?,
            self.firecracker.to_cstring()?,
            "--uid".to_cstring()?,
            self.uid.to_string().to_cstring()?,
            "--gid".to_cstring()?,
            self.gid.to_string().to_cstring()?,
            "--chroot-base-dir".to_cstring()?,
            self.jail_base.to_cstring()?,
            "--cgroup-version".to_cstring()?,
            "2".to_cstring()?,
            "--parent-cgroup".to_cstring()?,
            self.parent_cgroup.to_cstring()?,
        ];

        for cg in self.cgroups {
            argv.push("--cgroup".to_cstring()?);
            argv.push(cg.to_string().to_cstring()?);
        }

        if let Some(netns) = self.netns {
            argv.push("--netns".to_cstring()?);
            argv.push(netns.to_cstring()?);
        }

        argv.push("--".to_cstring()?);
        argv.push("--api-sock".to_cstring()?);
        argv.push(self.api_sock.to_string().to_cstring()?);

        Ok(argv)
    }

    /// Permanently become root and `execve` the jailer in our place. On success
    /// this never returns (the process image is replaced); the `Ok` arm is
    /// therefore [`std::convert::Infallible`]. Every failure is returned as
    /// [`Error`] for the caller to print and exit non-zero.
    pub fn invoke(self) -> Result<std::convert::Infallible, Error> {
        if self.cgroups.len() > MAX_CGROUPS {
            return Err(Error::TooManyCgroups(self.cgroups.len()));
        }

        // Resolve everything that can fail before any privilege is raised.
        let argv = self.argv()?;
        let jailer_cstr = self.jailer.to_cstring()?;

        // Point of no return: from here we are permanently root and must execve.
        setuid_privileged::become_root_permanently()?;
        close_inherited_fds();

        // Empty envp: once ruid==0 the kernel clears AT_SECURE, so a smuggled
        // LD_PRELOAD/LD_LIBRARY_PATH would be honored by the dynamic loader and
        // hijack the root jailer. We pass nothing and let the jailer build its own.
        let empty_env: [CString; 0] = [];
        let errno = nix::unistd::execve(&jailer_cstr, &argv, &empty_env)
            .expect_err("execve only returns on failure");
        Err(Error::Exec {
            path: self.jailer.to_path_buf(),
            errno,
        })
    }
}

/// Close every inherited fd above stdio so a compromised BEAM cannot smuggle an
/// open fd into the root jailer. Keep 0/1/2: MuonTrap supervises the jailer
/// through stdio, and stderr carries our exec-failure message. `close_range(2)`
/// needs Linux 5.9+; on any failure (ENOSYS or otherwise) we fall back to
/// closing each fd individually — fail closed before handing root to the jailer.
fn close_inherited_fds() {
    const FIRST: u32 = 3;
    // SAFETY: raw syscall with no memory operands; closing fds has no UB.
    let rc = unsafe { nix::libc::close_range(FIRST, u32::MAX, 0) };
    if rc == 0 {
        return;
    }

    // SAFETY: sysconf is a pure query of a system limit.
    let max = unsafe { nix::libc::sysconf(nix::libc::_SC_OPEN_MAX) };
    let max = if max < 0 { 4096 } else { max as i32 };
    for fd in (FIRST as i32)..max {
        // SAFETY: closing an arbitrary fd is safe; EBADF for unused fds is ignored.
        unsafe {
            nix::libc::close(fd);
        }
    }
}
