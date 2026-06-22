// SPDX-License-Identifier: AGPL-3.0-only
//! Validated device-path operands.
//!
//! The privileged tools must only ever touch Hyper's own devices, never
//! arbitrary system storage like `/dev/sda`. These newtypes encode that: each
//! wraps a `PathBuf` and is constructed only through its [`FromStr`] impl (the
//! check is a textual match on the device-node name), so holding one is proof
//! the path is in-bounds. Because they parse via `FromStr`, clap validates the
//! operands at argument-parse time; borrow them as a `Path` via `AsRef`.
//!
//! `JailPath` adds a second layer: a `no_symlink_walk` helper that re-opens
//! every parent component with `O_NOFOLLOW`, making the security boundary rest
//! on kernel semantics rather than lexical analysis alone.

use std::fmt;
use std::os::unix::io::RawFd;
use std::path::{Path, PathBuf};
use std::str::FromStr;
use thiserror::Error as ThisError;

#[derive(Debug, ThisError)]
pub enum Error {
    #[error("expected /dev/loopN: {0}")]
    Loop(String),
    #[error("expected a loop or hyper-* dm device: {0}")]
    Block(String),
    #[error("dm device name must be a safe hyper-* name: {0}")]
    Name(String),
    #[error("path must be a non-traversing path under /srv/hyper/jails: {0}")]
    Jail(String),
    #[error("uid/gid must be >= 1000 and non-zero: uid={uid} gid={gid}")]
    SystemUid { uid: u32, gid: u32 },
    #[error("symlinked component in jail path: {0}")]
    SymlinkComponent(String),
    #[error("could not stat device {path}: {source}")]
    DeviceStat { path: PathBuf, #[source] source: nix::Error },
}

// `/dev/loop` followed by its number and nothing else. Matching the digit suffix
// (not just the prefix) rejects path tricks like `/dev/loop0/../sda`.
fn is_loop(p: &str) -> bool {
    p.strip_prefix("/dev/loop")
        .is_some_and(|n| !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()))
}

// `/dev/mapper/` plus a `hyper-*` name with no path separators, so the device
// is always a direct child of `/dev/mapper` (the charset excludes `/`, so no
// traversal).
fn is_hyper_dm(p: &str) -> bool {
    p.strip_prefix("/dev/mapper/").is_some_and(is_hyper_name)
}

// A device-mapper name we own: `hyper-*`, restricted to a charset with no path
// separators. Shared by `is_hyper_dm` and [`DmName`] so the two never drift.
fn is_hyper_name(name: &str) -> bool {
    name.starts_with("hyper-") && name.bytes().all(|b| b.is_ascii_alphanumeric() || b"-_.".contains(&b))
}

/// A loop device path, `/dev/loopN`.
#[derive(Debug, Clone)]
pub struct LoopDev(PathBuf);

impl FromStr for LoopDev {
    type Err = Error;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        if is_loop(s) {
            Ok(Self(PathBuf::from(s)))
        } else {
            Err(Error::Loop(s.to_string()))
        }
    }
}

impl AsRef<Path> for LoopDev {
    fn as_ref(&self) -> &Path {
        &self.0
    }
}

/// A block-device operand: a loop device or one of our own dm devices — never
/// arbitrary system storage.
#[derive(Debug, Clone)]
pub struct BlockDev(PathBuf);

impl FromStr for BlockDev {
    type Err = Error;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        if is_loop(s) || is_hyper_dm(s) {
            Ok(Self(PathBuf::from(s)))
        } else {
            Err(Error::Block(s.to_string()))
        }
    }
}

impl AsRef<Path> for BlockDev {
    fn as_ref(&self) -> &Path {
        &self.0
    }
}

impl From<BlockDev> for PathBuf {
    fn from(dev: BlockDev) -> Self {
        dev.0
    }
}

/// A device-mapper device name we create/remove: a `hyper-*` name we own.
#[derive(Debug, Clone)]
pub struct DmName(String);

impl FromStr for DmName {
    type Err = Error;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        if is_hyper_name(s) {
            Ok(Self(s.to_string()))
        } else {
            Err(Error::Name(s.to_string()))
        }
    }
}

impl fmt::Display for DmName {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

/// Hyper's jail root: staged kernels and device nodes must land under here.
/// MUST equal <config :hyper, work_dir>/jails (config/config.exs).
/// Keep in sync with Elixir config; changing this without rebuilding the helper breaks staging.
pub const JAIL_BASE: &str = "/srv/hyper/jails";

/// A staging destination inside a VM's chroot. Validated lexically first (the
/// file may not exist yet): absolute, under `JAIL_BASE`, no `.`/`..`
/// components.
///
/// The lexical check is a cheap first gate; the real security boundary is
/// [`JailPath::open_parent_nofollow`], which opens each parent component with
/// `O_NOFOLLOW` so a symlinked component causes `ELOOP → SymlinkComponent`.
#[derive(Debug, Clone)]
pub struct JailPath(PathBuf);

impl FromStr for JailPath {
    type Err = Error;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        use std::path::Component;
        let p = PathBuf::from(s);
        let ok = p.is_absolute()
            && p.starts_with(JAIL_BASE)
            && p.components().all(|c| matches!(c, Component::RootDir | Component::Normal(_)));
        if ok {
            Ok(Self(p))
        } else {
            Err(Error::Jail(s.to_string()))
        }
    }
}

impl AsRef<Path> for JailPath {
    fn as_ref(&self) -> &Path {
        &self.0
    }
}

/// Decompose a `JailPath` into the relative parent components under
/// `JAIL_BASE` and the final filename component.
///
/// Returns `(parent_components, final_name)` where every element in
/// `parent_components` is a plain filename (no separators). The final_name is
/// the last path component (the node or file to create).
///
/// Returns `Err(Error::Jail)` if the path has no filename (e.g. is exactly
/// `JAIL_BASE` itself).
pub fn jail_relative_parts(path: &JailPath) -> Result<(Vec<String>, String), Error> {
    let p: &Path = path.as_ref();
    // Strip the JAIL_BASE prefix. The lexical check in FromStr guarantees this
    // succeeds.
    let rel = p
        .strip_prefix(JAIL_BASE)
        .map_err(|_| Error::Jail(p.display().to_string()))?;

    let mut components: Vec<String> = rel
        .components()
        .filter_map(|c| {
            if let std::path::Component::Normal(s) = c {
                s.to_str().map(|s| s.to_string())
            } else {
                None
            }
        })
        .collect();

    if components.is_empty() {
        return Err(Error::Jail(p.display().to_string()));
    }

    let final_name = components.pop().expect("non-empty after check above");
    Ok((components, final_name))
}

/// Walk every PARENT directory component of `path` under `JAIL_BASE` using
/// `O_NOFOLLOW`, so a symlinked component causes `ELOOP` (returned as
/// [`Error::SymlinkComponent`]).
///
/// Returns a file descriptor for the parent directory. The caller is
/// responsible for closing it (via `nix::unistd::close` or by wrapping in an
/// `OwnedFd`).
///
/// This is the real security boundary for symlink traversal: even if lexical
/// validation passes, a raced `symlink()` in a parent directory will cause the
/// `openat(O_NOFOLLOW)` to return `ELOOP`, aborting the operation.
pub fn open_parent_nofollow(path: &JailPath) -> Result<(RawFd, String), Error> {
    use nix::fcntl::{openat, OFlag};
    use nix::sys::stat::Mode;

    let (parents, final_name) = jail_relative_parts(path)?;

    let base_flags = OFlag::O_DIRECTORY | OFlag::O_CLOEXEC | OFlag::O_NOFOLLOW;

    // Open JAIL_BASE itself (absolute path; O_NOFOLLOW only matters for the
    // final component of open(), which is a directory here — a symlink at
    // JAIL_BASE itself is also caught because we request O_DIRECTORY).
    let mut dirfd = openat(None::<RawFd>, JAIL_BASE, base_flags, Mode::empty())
        .map_err(|e| Error::SymlinkComponent(format!("{JAIL_BASE}: {e}")))?;

    // Walk each parent component relative to the previous dirfd.
    for component in &parents {
        let child = openat(Some(dirfd), component.as_str(), base_flags, Mode::empty())
            .map_err(|e| Error::SymlinkComponent(format!("{component}: {e}")));
        // Always close the old dirfd before returning an error.
        let _ = nix::unistd::close(dirfd);
        dirfd = child?;
    }

    Ok((dirfd, final_name))
}

/// Reject uid/gid that would give the node to root or a system account.
///
/// This is a pure check; no syscalls.
pub fn check_owner(uid: u32, gid: u32) -> Result<(), Error> {
    if uid == 0 || gid == 0 || uid < 1000 || gid < 1000 {
        Err(Error::SystemUid { uid, gid })
    } else {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── JailPath lexical tests ──────────────────────────────────────────────

    #[test]
    fn jailpath_rejects_traversal_and_outside() {
        assert!(JailPath::from_str("/srv/hyper/jails/firecracker/v/root/rootfs").is_ok());
        assert!(JailPath::from_str("/etc/passwd").is_err());
        assert!(JailPath::from_str("/srv/hyper/jails/../../etc/x").is_err());
    }

    #[test]
    fn jailpath_dot_normalized_by_pathbuf() {
        // PathBuf::components() normalizes away `.` — "/a/./b" and "/a/b" are
        // the same path. The lexical check therefore accepts them both, which
        // is safe because `open_parent_nofollow` operates component-by-component
        // and a no-op `.` never appears in the output of `jail_relative_parts`.
        let p = JailPath::from_str("/srv/hyper/jails/vm1/./root");
        assert!(p.is_ok(), "dot is normalised away by PathBuf, path is valid");
        // Confirm the relative parts contain no dot component.
        let (parents, name) = jail_relative_parts(&p.unwrap()).unwrap();
        assert_eq!(parents, vec!["vm1"]);
        assert_eq!(name, "root");
    }

    #[test]
    fn jailpath_rejects_exactly_jail_base() {
        // No final component → jail_relative_parts would fail; FromStr allows
        // it but open_parent_nofollow/jail_relative_parts must not.
        let p = JailPath::from_str("/srv/hyper/jails").unwrap();
        assert!(jail_relative_parts(&p).is_err());
    }

    // ── jail_relative_parts pure tests ─────────────────────────────────────

    #[test]
    fn relative_parts_single_component() {
        let p = JailPath::from_str("/srv/hyper/jails/vmroot").unwrap();
        let (parents, name) = jail_relative_parts(&p).unwrap();
        assert!(parents.is_empty(), "no parent components for direct child");
        assert_eq!(name, "vmroot");
    }

    #[test]
    fn relative_parts_deep_path() {
        let p = JailPath::from_str("/srv/hyper/jails/vm1/dev/vda").unwrap();
        let (parents, name) = jail_relative_parts(&p).unwrap();
        assert_eq!(parents, vec!["vm1", "dev"]);
        assert_eq!(name, "vda");
    }

    #[test]
    fn relative_parts_two_levels() {
        let p = JailPath::from_str("/srv/hyper/jails/alpha/vmlinux").unwrap();
        let (parents, name) = jail_relative_parts(&p).unwrap();
        assert_eq!(parents, vec!["alpha"]);
        assert_eq!(name, "vmlinux");
    }

    // ── check_owner pure tests ──────────────────────────────────────────────

    #[test]
    fn owner_rejects_root_uid() {
        assert!(check_owner(0, 1000).is_err());
    }

    #[test]
    fn owner_rejects_root_gid() {
        assert!(check_owner(1000, 0).is_err());
    }

    #[test]
    fn owner_rejects_system_uid() {
        assert!(check_owner(999, 1000).is_err());
    }

    #[test]
    fn owner_rejects_system_gid() {
        assert!(check_owner(1000, 999).is_err());
    }

    #[test]
    fn owner_accepts_normal_user() {
        assert!(check_owner(1000, 1000).is_ok());
        assert!(check_owner(1001, 2000).is_ok());
        assert!(check_owner(65534, 65534).is_ok());
    }
}
