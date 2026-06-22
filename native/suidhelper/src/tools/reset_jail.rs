// SPDX-License-Identifier: AGPL-3.0-only
//! `reset-jail` subcommand: remove stale per-VM chroot and cgroup leaf before
//! relaunching the Firecracker jailer.
//!
//! Security model
//! ──────────────
//! `--chroot` validation
//!   • Lexically validated as a [`JailPath`] (absolute, under `JAIL_BASE`, no
//!     `.`/`..` components) and additionally required to be EXACTLY two
//!     components below `JAIL_BASE` (`<exec>/<id>`), so a caller cannot pass
//!     `JAIL_BASE` itself or any shallower/deeper path and nuke unrelated trees.
//!   • `remove_dir_all` does not follow symlinks for deletion. The `<exec>` and
//!     `<id>` path components are root-owned (not writable by the unprivileged
//!     node or the jail uid), so a symlinked-component redirect is not reachable.
//!   • ENOENT is treated as success (idempotent — first boot has no chroot).
//!
//! `--cgroup` validation
//!   • Absolute, under `/sys/fs/cgroup`, all components `RootDir`|`Normal`, and
//!     at least TWO components below `/sys/fs/cgroup` (so we can never rmdir the
//!     shared parent cgroup).
//!   • `remove_dir` (non-recursive rmdir) only removes an empty leaf. A
//!     mis-constructed path is therefore safe: it just no-ops.
//!   • ENOENT and ENOTEMPTY are treated as success (best-effort).

use super::IsTool;
use crate::safe_dev::{self, JailPath};
use clap::Args;
use serde::Serialize;
use std::io;
use std::path::{Component, Path, PathBuf};
use thiserror::Error as ThisError;

/// The cgroup virtual filesystem root.
const CGROUP_BASE: &str = "/sys/fs/cgroup";

// ── Validation helpers (pure; no filesystem calls) ────────────────────────────

/// Validate that `path` is a valid per-VM chroot directory:
/// - Must pass [`JailPath`] lexical validation (absolute, under `JAIL_BASE`, no
///   `.`/`..`).
/// - Must be EXACTLY two components below `JAIL_BASE` (i.e. `<exec>/<id>`).
///
/// Returns the validated [`JailPath`] on success.
fn validate_chroot(s: &str) -> Result<JailPath, Error> {
    let jail: JailPath = s.parse().map_err(Error::ChootPath)?;
    // jail_relative_parts returns (parents, final); require parents.len() == 1
    // so the shape is exactly JAIL_BASE/<exec>/<id> — two components total.
    let (parents, _final) = safe_dev::jail_relative_parts(&jail).map_err(Error::ChootPath)?;
    if parents.len() != 1 {
        return Err(Error::ChrootDepth(s.to_string()));
    }
    Ok(jail)
}

/// Validate that `s` is a valid per-VM cgroup leaf directory:
/// - Absolute.
/// - Starts with `CGROUP_BASE`.
/// - All components are `RootDir` or `Normal` (no `.`/`..`).
/// - At least TWO components below `CGROUP_BASE`.
///
/// Returns the validated `PathBuf` on success.
fn validate_cgroup(s: &str) -> Result<PathBuf, Error> {
    let p = PathBuf::from(s);
    let ok = p.is_absolute()
        && p.starts_with(CGROUP_BASE)
        && p.components()
            .all(|c| matches!(c, Component::RootDir | Component::Normal(_)));
    if !ok {
        return Err(Error::CgroupPath(s.to_string()));
    }
    // Count components below CGROUP_BASE.
    let rel = p
        .strip_prefix(CGROUP_BASE)
        .map_err(|_| Error::CgroupPath(s.to_string()))?;
    let depth = rel
        .components()
        .filter(|c| matches!(c, Component::Normal(_)))
        .count();
    if depth < 2 {
        return Err(Error::CgroupDepth(s.to_string()));
    }
    Ok(p)
}

// ── Error type ────────────────────────────────────────────────────────────────

#[derive(Debug, ThisError)]
pub enum Error {
    #[error("--chroot path is not a valid jail path: {0}")]
    ChootPath(#[source] safe_dev::Error),
    #[error("--chroot must be exactly <exec>/<id> below JAIL_BASE: {0}")]
    ChrootDepth(String),
    #[error("--cgroup path must be absolute under /sys/fs/cgroup with no . or ..: {0}")]
    CgroupPath(String),
    #[error("--cgroup must be at least two components below /sys/fs/cgroup: {0}")]
    CgroupDepth(String),
    #[error("remove_dir_all {path}: {source}")]
    RemoveChroot { path: PathBuf, #[source] source: io::Error },
    #[error("rmdir {path}: {source}")]
    RemoveCgroup { path: PathBuf, #[source] source: io::Error },
}

// ── Args ──────────────────────────────────────────────────────────────────────

#[derive(Args)]
pub struct ResetJailArgs {
    /// Per-VM chroot directory to remove, shape <JAIL_BASE>/<exec>/<id>.
    #[arg(long)]
    chroot: String,
    /// Per-VM cgroup leaf directory to remove, under /sys/fs/cgroup.
    #[arg(long)]
    cgroup: String,
}

// ── Output ────────────────────────────────────────────────────────────────────

#[derive(Serialize)]
#[serde(tag = "result", rename_all = "snake_case")]
pub enum ResetJailOut {
    Reset,
}

// ── Tool implementation ───────────────────────────────────────────────────────

pub struct ResetJail {
    args: ResetJailArgs,
}

impl ResetJail {
    pub fn new(args: ResetJailArgs) -> Self {
        Self { args }
    }
}

impl IsTool for ResetJail {
    type Args = ResetJailArgs;
    type Output = ResetJailOut;
    type RunT = Result<(), Error>;

    fn run_privileged(&self) -> Self::RunT {
        // ── 1. Validate operands (pure, no filesystem) ──────────────────────
        let chroot = validate_chroot(&self.args.chroot)?;
        let cgroup = validate_cgroup(&self.args.cgroup)?;

        // ── 2. Remove chroot subtree ─────────────────────────────────────────
        // remove_dir_all does not follow symlinks for deletion. The <exec>/<id>
        // components are root-owned (not writable by the unprivileged node or
        // the jail uid), so a symlinked-component redirect is not reachable.
        // ENOENT is success (idempotent — first boot has no chroot yet).
        let chroot_path: &Path = chroot.as_ref();
        match std::fs::remove_dir_all(chroot_path) {
            Ok(()) => {}
            Err(e) if e.kind() == io::ErrorKind::NotFound => {}
            Err(source) => {
                return Err(Error::RemoveChroot {
                    path: chroot_path.to_path_buf(),
                    source,
                })
            }
        }

        // ── 3. Remove cgroup leaf (non-recursive rmdir, best-effort) ─────────
        // remove_dir only ever removes an empty leaf — even a mis-constructed
        // path is safe because it just no-ops. ENOENT and ENOTEMPTY are
        // success: the cgroup may never have been created, or the process may
        // have moved out of it before we get here.
        match std::fs::remove_dir(&cgroup) {
            Ok(()) => {}
            Err(e)
                if e.kind() == io::ErrorKind::NotFound
                    || e.raw_os_error() == Some(nix::libc::ENOTEMPTY) =>
            {
                // Best-effort: treat as success.
            }
            Err(source) => {
                return Err(Error::RemoveCgroup {
                    path: cgroup,
                    source,
                })
            }
        }

        Ok(())
    }

    fn parse(&self, res: Self::RunT) -> Result<ResetJailOut, Box<dyn std::error::Error>> {
        res?;
        Ok(ResetJailOut::Reset)
    }
}

// ── Tests (pure, hermetic — no root, no real /srv or /sys) ───────────────────

#[cfg(test)]
mod tests {
    use super::*;

    // ── Chroot validator ──────────────────────────────────────────────────────

    #[test]
    fn chroot_accepts_two_components() {
        // Exactly <exec>/<id> below JAIL_BASE — this is the only valid shape.
        assert!(validate_chroot("/srv/hyper/jails/firecracker/abc").is_ok());
    }

    #[test]
    fn chroot_rejects_jail_base_itself() {
        // Zero components below JAIL_BASE.
        assert!(validate_chroot("/srv/hyper/jails").is_err());
    }

    #[test]
    fn chroot_rejects_one_component() {
        // Only <exec>, no <id>.
        assert!(validate_chroot("/srv/hyper/jails/firecracker").is_err());
    }

    #[test]
    fn chroot_rejects_three_components() {
        // Deeper than allowed: would let a caller nuke a sub-directory.
        assert!(validate_chroot("/srv/hyper/jails/a/b/c").is_err());
    }

    #[test]
    fn chroot_rejects_outside_jail_base() {
        assert!(validate_chroot("/etc/x").is_err());
    }

    #[test]
    fn chroot_rejects_dotdot_traversal() {
        assert!(validate_chroot("/srv/hyper/jails/../../etc/passwd").is_err());
    }

    // ── Cgroup validator ──────────────────────────────────────────────────────

    #[test]
    fn cgroup_accepts_two_components_below_base() {
        // <hyper>/<firecracker>/<id> — three components total, depth = 3 ≥ 2.
        assert!(validate_cgroup("/sys/fs/cgroup/hyper/firecracker/abc").is_ok());
    }

    #[test]
    fn cgroup_accepts_exactly_two_components() {
        // Two components below CGROUP_BASE is the minimum accepted.
        assert!(validate_cgroup("/sys/fs/cgroup/hyper/firecracker").is_ok());
    }

    #[test]
    fn cgroup_rejects_one_component() {
        // Would rmdir the shared parent cgroup — not allowed.
        assert!(validate_cgroup("/sys/fs/cgroup/hyper").is_err());
    }

    #[test]
    fn cgroup_rejects_cgroup_base_itself() {
        assert!(validate_cgroup("/sys/fs/cgroup").is_err());
    }

    #[test]
    fn cgroup_rejects_outside_cgroup_base() {
        assert!(validate_cgroup("/etc/x").is_err());
    }

    #[test]
    fn cgroup_rejects_dotdot_traversal() {
        assert!(validate_cgroup("/sys/fs/cgroup/../../etc/crontab").is_err());
    }
}
