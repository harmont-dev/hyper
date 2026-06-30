// SPDX-License-Identifier: AGPL-3.0-only
// TODO: slop
//! The `jailer` subcommand: validate the BEAM's arguments, re-acquire root
//! permanently, and `execve` the firecracker jailer in our place.
//!
//! Unlike the device tools this is **not** an [`crate::tools::IsTool`]: it does
//! not run a child and parse JSON, it *becomes* the jailer via `execve`, so the
//! unprivileged BEAM's MuonTrap port keeps supervising the resulting process
//! across the image replacement. There is no output and no return on success.
//!
//! Threat model: the BEAM is untrusted. It supplies only `--id`, `--uid`,
//! `--gid`, repeated `--cgroup KEY=VALUE`, and `--api-sock`. Every privileged
//! path (the jailer binary, the firecracker `--exec-file`, the chroot base, the
//! parent cgroup) comes from the root-owned config, never the caller. The
//! refusal contracts on the newtypes below are the security core: a compromised
//! BEAM must not be able to name a privileged path, request uid 0, traverse out
//! of the chroot base, inject a flag, or smuggle an environment/fd into root.
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

use crate::config::{BinError, Config};
use crate::util::setuid_privileged;
use clap::Args;
use nix::errno::Errno;
use std::ffi::CString;
use std::fmt;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::str::FromStr;
use thiserror::Error as ThisError;

/// The jailer protects at most a handful of controllers; an unbounded `--cgroup`
/// list is a caller trying something. Cap it well above any legitimate need.
const MAX_CGROUPS: usize = 16;

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
    Bin(#[from] BinError),
    #[error(transparent)]
    Privilege(#[from] setuid_privileged::Error),
    #[error("argument contains an interior NUL byte")]
    NulArgument,
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

#[derive(Args)]
pub struct JailerArgs {
    /// Microvm id; becomes the chroot subdirectory name.
    #[arg(long)]
    id: VmId,
    /// Unprivileged uid the jailer drops to (rejected if 0 or out of range).
    #[arg(long)]
    uid: u32,
    /// Unprivileged gid the jailer drops to (rejected if 0 or out of range).
    #[arg(long)]
    gid: u32,
    /// Repeatable `KEY=VALUE` cgroup setting from the allowlist.
    #[arg(long = "cgroup")]
    cgroup: Vec<CgroupSetting>,
    /// Absolute firecracker API socket path (single filename under `/`).
    #[arg(long = "api-sock")]
    api_sock: JailSock,
}

fn cstr_bytes(bytes: &[u8]) -> Result<CString, Error> {
    CString::new(bytes).map_err(|_| Error::NulArgument)
}

fn cstr_str(s: &str) -> Result<CString, Error> {
    cstr_bytes(s.as_bytes())
}

fn cstr_path(p: &Path) -> Result<CString, Error> {
    cstr_bytes(p.as_os_str().as_bytes())
}

/// Build the exact argv handed to the jailer. argv[0] is the jailer path. The
/// caller never names the jailer, the `--exec-file`, the chroot base, the cgroup
/// version, or the parent cgroup — those are derived from trusted config here.
#[allow(clippy::too_many_arguments)]
fn build_argv(
    jailer: &Path,
    id: &VmId,
    firecracker: &Path,
    uid: u32,
    gid: u32,
    jail_base: &Path,
    parent_cgroup: &str,
    cgroups: &[CgroupSetting],
    api_sock: &JailSock,
) -> Result<Vec<CString>, Error> {
    let mut argv = vec![
        cstr_path(jailer)?,
        cstr_str("--id")?,
        cstr_str(&id.to_string())?,
        cstr_str("--exec-file")?,
        cstr_path(firecracker)?,
        cstr_str("--uid")?,
        cstr_str(&uid.to_string())?,
        cstr_str("--gid")?,
        cstr_str(&gid.to_string())?,
        cstr_str("--chroot-base-dir")?,
        cstr_path(jail_base)?,
        cstr_str("--cgroup-version")?,
        cstr_str("2")?,
        cstr_str("--parent-cgroup")?,
        cstr_str(parent_cgroup)?,
    ];

    for cg in cgroups {
        argv.push(cstr_str("--cgroup")?);
        argv.push(cstr_str(&cg.to_string())?);
    }

    argv.push(cstr_str("--")?);
    argv.push(cstr_str("--api-sock")?);
    argv.push(cstr_str(&api_sock.to_string())?);

    Ok(argv)
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

/// Validate the caller's args, then permanently become root and `execve` the
/// jailer. On success this never returns (the process image is replaced); the
/// `Ok` arm is therefore [`std::convert::Infallible`]. Every failure is returned
/// as [`Error`] for the caller to print and exit non-zero.
pub fn run(args: JailerArgs) -> Result<std::convert::Infallible, Error> {
    let config = Config::get();

    // Resolve everything that can fail as the REAL uid, before any privilege is
    // raised: config accessors, binary validation, range, and arg validation.
    let jailer: PathBuf = config.jailer()?.into();
    let firecracker: PathBuf = config.firecracker()?.into();
    let jail_base = config.jail_base();
    let parent_cgroup = config.parent_cgroup();
    let range = config.uid_gid_range();

    let uid = validate_id_number(args.uid, range)?;
    let gid = validate_id_number(args.gid, range)?;

    if args.cgroup.len() > MAX_CGROUPS {
        return Err(Error::TooManyCgroups(args.cgroup.len()));
    }

    let argv = build_argv(
        &jailer,
        &args.id,
        &firecracker,
        uid,
        gid,
        &jail_base,
        parent_cgroup,
        &args.cgroup,
        &args.api_sock,
    )?;
    let jailer_cstr = cstr_path(&jailer)?;

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
        path: jailer,
        errno,
    })
}
