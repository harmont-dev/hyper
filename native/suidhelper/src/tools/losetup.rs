use super::IsTool;
use crate::util::safe_dev::LoopDev;
use crate::util::safe_file::{self, Any, IsRegularFile, SafeFile};
use crate::util::safe_path::{self, IsAbsolute, SafePath, StrictComponents};
use clap::{Args, Subcommand};
use nix::errno::Errno;
use nix::fcntl::OFlag;
use nix::unistd::dup;
use serde::Serialize;
use std::io;
use std::os::unix::io::AsRawFd;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use thiserror::Error as ThisError;

#[derive(Debug, ThisError)]
pub enum Error {
    #[error("backing file {path}: {source}")]
    Canonicalize { path: PathBuf, #[source] source: io::Error },
    #[error("backing file must be under {}: {path}", .base.display())]
    OutsideBase { base: &'static Path, path: PathBuf },
    #[error("backing path: {0}")]
    BackingPath(#[from] safe_path::ValidationError),
    #[error("backing file: {0}")]
    Backing(#[from] safe_file::ValidationError),
    #[error("duplicating backing fd {path}: {errno}")]
    OpenBacking { path: PathBuf, errno: Errno },
    #[error("running losetup: {0}")]
    Spawn(#[source] io::Error),
    #[error("losetup failed: {0}")]
    Failed(String),
}

#[derive(Args)]
pub struct LosetupArgs {
    #[command(subcommand)]
    op: LosetupOp,
}

#[derive(Args)]
struct AttachArgs {
    /// Attach read-write (default is read-only).
    #[arg(long)]
    rw: bool,
    #[arg(value_parser = ok_backing_file)]
    path: PathBuf,
}

impl AttachArgs {
    fn enrich_command(&self, cmd: &mut Command) {
        cmd.arg("--find").arg("--show");
        if !self.rw {
            cmd.arg("--read-only");
        }
        cmd.arg(&self.path);
    }
}

#[derive(Subcommand)]
enum LosetupOp {
    /// Attach a backing file to the next free loop device.
    Attach(AttachArgs),
    /// Detach a loop device.
    Detach {
        dev: LoopDev,
    },
}

#[derive(Serialize)]
#[serde(tag = "result", rename_all = "snake_case")]
pub enum LosetupOut {
    Attached { device: PathBuf },
    Detached,
}

pub struct Losetup {
    bin: PathBuf,
    op: LosetupOp,
}

impl Losetup {
    pub fn new(bin: PathBuf, args: LosetupArgs) -> Self {
        Self { bin, op: args.op }
    }
}

impl IsTool for Losetup {
    type Args = LosetupArgs;
    type Output = LosetupOut;
    type RunT = io::Result<Output>;

    fn run_privileged(&self) -> Self::RunT {
        let mut cmd = Command::new(&self.bin);
        match &self.op {
            LosetupOp::Attach(args) => {
                args.enrich_command(&mut cmd);
            }
            LosetupOp::Detach { dev } => {
                let dev: &Path = dev.as_ref();
                cmd.arg("-d").arg(dev);
            }
        }

        cmd.env_clear().output()
    }

    fn parse(&self, res: Self::RunT) -> Result<LosetupOut, Box<dyn std::error::Error>> {
        let out = res.map_err(Error::Spawn)?;
        if !out.status.success() {
            return Err(Error::Failed(String::from_utf8_lossy(&out.stderr).trim().to_string()).into());
        }

        Ok(match &self.op {
            LosetupOp::Attach(_) => LosetupOut::Attached {
                device: PathBuf::from(String::from_utf8_lossy(&out.stdout).trim()),
            },
            LosetupOp::Detach { .. } => LosetupOut::Detached,
        })
    }
}

/// losetup backing files must live under Hyper's data root. Resolve symlinks,
/// check the real path is in-bounds, then open *that* inode and return
/// `/proc/self/fd/N`. Operating on the validated fd (not the path) closes the
/// TOCTOU window: a swap after the check can't redirect losetup elsewhere.
fn ok_backing_file(p: &str) -> Result<PathBuf, Error> {
    let real =
        std::fs::canonicalize(p).map_err(|source| Error::Canonicalize { path: PathBuf::from(p), source })?;

    let base = crate::config::Config::get().hyper_base();
    if !real.starts_with(base) {
        return Err(Error::OutsideBase { base, path: real });
    }

    // `canonicalize` already resolved every symlink and `..`, so the result is
    // absolute and component-strict. Open it as a verified regular-file handle
    // (O_PATH to identify; SafeFile fstats the held fd and O_NOFOLLOW refuses a
    // final-component swap raced in after the check).
    let safe: SafePath<IsAbsolute, StrictComponents> = real.clone().try_into()?;
    let file = SafeFile::<IsRegularFile, Any, Any>::open(&safe, OFlag::O_PATH)?;

    // losetup runs as a child and reopens the *validated inode* via /proc/self/fd.
    // SafeFile's fd is O_CLOEXEC (it would vanish on exec), so dup an inheritable
    // copy that survives into the child; the dup is intentionally leaked, and the
    // SafeFile's own fd closes on drop.
    let inheritable =
        dup(file.as_raw_fd()).map_err(|errno| Error::OpenBacking { path: real, errno })?;
    Ok(PathBuf::from(format!("/proc/self/fd/{inheritable}")))
}
