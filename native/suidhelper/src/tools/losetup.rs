use super::IsTool;
use crate::safe_dev::LoopDev;
use clap::{Args, Subcommand};
use nix::errno::Errno;
use nix::fcntl::{open, OFlag};
use nix::sys::stat::{fstat, Mode as StatMode, SFlag};
use serde::Serialize;
use std::io;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use thiserror::Error as ThisError;

#[derive(Debug, ThisError)]
pub enum Error {
    #[error("backing file {path}: {source}")]
    Canonicalize { path: PathBuf, #[source] source: io::Error },
    #[error("backing file must be under {}: {path}", .base.display())]
    OutsideBase { base: &'static Path, path: PathBuf },
    #[error("opening backing file {path}: {errno}")]
    OpenBacking { path: PathBuf, errno: Errno },
    #[error("{0} is not a regular file")]
    NotRegularFile(PathBuf),
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
    path: String,
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
    Attached { device: String },
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
                device: String::from_utf8_lossy(&out.stdout).trim().to_string(),
            },
            LosetupOp::Detach { .. } => LosetupOut::Detached,
        })
    }
}

/// losetup backing files must live under Hyper's data root. Resolve symlinks,
/// check the real path is in-bounds, then open *that* inode and return
/// `/proc/self/fd/N`. Operating on the validated fd (not the path) closes the
/// TOCTOU window: a swap after the check can't redirect losetup elsewhere.
fn ok_backing_file(p: &str) -> Result<String, Error> {
    let real =
        std::fs::canonicalize(p).map_err(|source| Error::Canonicalize { path: PathBuf::from(p), source })?;

    let base = crate::config::Config::get().hyper_base();
    if !real.starts_with(base) {
        return Err(Error::OutsideBase { base, path: real });
    }

    // O_PATH: no read perms needed; O_NOFOLLOW: refuse if the final component got
    // swapped to a symlink between canonicalize and here.
    let fd = open(&real, OFlag::O_PATH | OFlag::O_NOFOLLOW, StatMode::empty())
        .map_err(|errno| Error::OpenBacking { path: real.clone(), errno })?;

    let st = fstat(fd).map_err(|errno| Error::OpenBacking { path: real.clone(), errno })?;
    if st.st_mode & SFlag::S_IFMT.bits() != SFlag::S_IFREG.bits() {
        return Err(Error::NotRegularFile(real));
    }

    // The fd is a bare RawFd (no CLOEXEC), so a spawned child inherits it; losetup
    // reopens the exact validated inode via /proc/self/fd.
    Ok(format!("/proc/self/fd/{fd}"))
}
