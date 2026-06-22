// SPDX-License-Identifier: AGPL-3.0-only
//! `chroot-jail` subcommand: prepare and remove per-VM chroot/jail environments.
//!
//! Security model
//! ──────────────
//! prepare
//!   • `--chroot` is validated as a `JailPath` (absolute, under `JAIL_BASE`,
//!     no `.`/`..` components). The two destination paths (`vmlinux`, `rootfs`)
//!     are constructed by joining the fixed names onto the chroot root and
//!     re-parsed as `JailPath`, re-running lexical validation.
//!   • `uid`/`gid` are validated once at entry via `check_owner`.
//!   • Kernel staging uses `stage_file` (canonicalize + confine under
//!     HYPER_BASE, open O_RDONLY|O_NOFOLLOW, linkat / EXDEV copy,
//!     fchownat AT_SYMLINK_NOFOLLOW).
//!   • Device-node creation uses `make_block_node` (open device O_PATH|O_NOFOLLOW,
//!     fstat for rdev, open_parent_nofollow, mknodat, fchownat AT_SYMLINK_NOFOLLOW).
//!   • The `open_parent_nofollow` walk inside each helper is the real symlink
//!     guard; lexical validation is only a cheap first gate.
//!
//! remove
//!   • `--chroot` validation: must be EXACTLY two components below `JAIL_BASE`
//!     (`<exec>/<id>`), so a caller cannot pass `JAIL_BASE` itself or any
//!     shallower/deeper path and nuke unrelated trees.
//!   • `remove_dir_all` does not follow symlinks for deletion.
//!   • ENOENT is treated as success (idempotent — first boot has no chroot).
//!   • `--cgroup` validation: absolute, under `/sys/fs/cgroup`, all components
//!     `RootDir`|`Normal`, at least TWO components below `/sys/fs/cgroup`.
//!   • `remove_dir` (non-recursive rmdir) only removes an empty leaf.
//!   • ENOENT and ENOTEMPTY are treated as success (best-effort).

use super::{mknod, stage, IsTool};
use crate::safe_dev::{self, BlockDev, JailPath};
use clap::{Args, Subcommand};
use serde::Serialize;
use std::io;
use std::path::{Component, Path, PathBuf};
use thiserror::Error as ThisError;

/// The cgroup virtual filesystem root.
const CGROUP_BASE: &str = "/sys/fs/cgroup";

/// Fixed in-jail filename for the host kernel image.
/// The Elixir side (`Hyper.Node.FireVMM.ChrootJail`) MUST agree with this name.
const KERNEL_NAME: &str = "vmlinux";

/// Fixed in-jail filename for the rootfs block device node.
/// The Elixir side (`Hyper.Node.FireVMM.ChrootJail`) MUST agree with this name.
const ROOT_NAME: &str = "rootfs";

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

/// Build an in-jail destination by joining `name` onto the `chroot` root and
/// parsing it as a [`JailPath`], which re-validates confinement under
/// `JAIL_BASE` (so a bad `--chroot` fails here).
fn dest_path(chroot: &str, name: &str) -> Result<JailPath, Error> {
    let s = format!("{chroot}/{name}");
    s.parse().map_err(|source| Error::DestPath { path: s, source })
}

// ── Error type ────────────────────────────────────────────────────────────────

#[derive(Debug, ThisError)]
pub enum Error {
    #[error(transparent)]
    Path(#[from] safe_dev::Error),
    #[error("stage kernel: {0}")]
    Stage(#[from] stage::Error),
    #[error("mknod rootfs: {0}")]
    Mknod(#[from] mknod::Error),
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
    #[error("invalid dest path {path}: {source}")]
    DestPath { path: String, #[source] source: safe_dev::Error },
}

// ── Args ──────────────────────────────────────────────────────────────────────

#[derive(Args)]
pub struct PrepareArgs {
    /// Chroot root directory (under JAIL_BASE, shape <JAIL_BASE>/<exec>/<id>).
    #[arg(long)]
    chroot: String,
    /// Host kernel image path (under /srv/hyper); staged as <chroot>/vmlinux.
    #[arg(long)]
    kernel: String,
    /// Host block device to mirror as <chroot>/rootfs (e.g. /dev/loop0 or
    /// /dev/mapper/hyper-vm1). Its major:minor are read by the helper.
    #[arg(long)]
    device: BlockDev,
    /// UID to own the staged files; must be >= 1000 (non-root, non-system).
    #[arg(long)]
    uid: u32,
    /// GID to own the staged files; must be >= 1000 (non-root, non-system).
    #[arg(long)]
    gid: u32,
}

#[derive(Args)]
pub struct RemoveArgs {
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
pub enum PrepareOut {
    Prepared,
}

#[derive(Serialize)]
#[serde(tag = "result", rename_all = "snake_case")]
pub enum RemoveOut {
    Removed,
}

// ── Subcommand enum ───────────────────────────────────────────────────────────

#[derive(Subcommand)]
pub enum ChrootJailOp {
    /// Prepare a VM chroot: stage the kernel and create the rootfs device node.
    Prepare(PrepareArgs),
    /// Remove a VM's stale chroot and cgroup leaf before relaunching the jailer.
    Remove(RemoveArgs),
}

// ── Dispatcher ────────────────────────────────────────────────────────────────
// `chroot-jail` is NOT an `IsTool` - it carries no behaviour of its own. It just
// routes to the selected nested tool, each of which IS an `IsTool` with its own
// privileged scope.

impl ChrootJailOp {
    pub fn run(self) -> Result<super::ToolOutput, super::Error> {
        match self {
            ChrootJailOp::Prepare(args) => {
                Ok(super::ToolOutput::Prepare(Prepare::new(args).run()?))
            }
            ChrootJailOp::Remove(args) => {
                Ok(super::ToolOutput::Remove(Remove::new(args).run()?))
            }
        }
    }
}

// ── prepare ─────────────────────────────────────────────────────────────────────

struct Prepare {
    args: PrepareArgs,
}

impl Prepare {
    fn new(args: PrepareArgs) -> Self {
        Self { args }
    }
}

impl IsTool for Prepare {
    type Args = PrepareArgs;
    type Output = PrepareOut;
    type RunT = Result<(), Error>;

    fn run_privileged(&self) -> Self::RunT {
        let args = &self.args;

        // 1. Reject system/root uid/gid before doing anything.
        safe_dev::check_owner(args.uid, args.gid)?;

        // 2. Construct dest JailPaths for kernel and rootfs. Parsing as a
        //    JailPath re-validates confinement under JAIL_BASE (a bad --chroot
        //    fails here); the open_parent_nofollow walk inside each helper is the
        //    real symlink guard.
        let kernel_dest = dest_path(&args.chroot, KERNEL_NAME)?;
        let rootfs_dest = dest_path(&args.chroot, ROOT_NAME)?;

        // 3. Stage kernel file to <chroot>/vmlinux.
        stage::stage_file(&args.kernel, &kernel_dest, args.uid, args.gid)?;

        // 4. mknod rootfs device node at <chroot>/rootfs.
        mknod::make_block_node(&rootfs_dest, &args.device, args.uid, args.gid)?;

        Ok(())
    }

    fn parse(&self, res: Self::RunT) -> Result<PrepareOut, Box<dyn std::error::Error>> {
        res?;
        Ok(PrepareOut::Prepared)
    }
}

// ── remove ──────────────────────────────────────────────────────────────────────

struct Remove {
    args: RemoveArgs,
}

impl Remove {
    fn new(args: RemoveArgs) -> Self {
        Self { args }
    }
}

impl IsTool for Remove {
    type Args = RemoveArgs;
    type Output = RemoveOut;
    type RunT = Result<(), Error>;

    fn run_privileged(&self) -> Self::RunT {
        let args = &self.args;

        // 1. Validate operands (pure, no filesystem).
        let chroot = validate_chroot(&args.chroot)?;
        let cgroup = validate_cgroup(&args.cgroup)?;

        // 2. Remove chroot subtree. remove_dir_all does not follow symlinks for
        //    deletion, and the <exec>/<id> components are root-owned (not writable
        //    by the node or the jail uid), so a symlinked-component redirect is
        //    unreachable. ENOENT is success (idempotent - first boot has none).
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

        // 3. Remove cgroup leaf (non-recursive rmdir, best-effort). rmdir only
        //    removes an empty leaf, so a mis-constructed path just no-ops.
        //    ENOENT/ENOTEMPTY are treated as success.
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

    fn parse(&self, res: Self::RunT) -> Result<RemoveOut, Box<dyn std::error::Error>> {
        res?;
        Ok(RemoveOut::Removed)
    }
}
