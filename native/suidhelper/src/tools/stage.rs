use super::IsTool;
use crate::safe_dev::{self, JailPath};
use clap::Args;
use nix::unistd::{chown, Gid, Uid};
use serde::Serialize;
use std::io;
use std::path::PathBuf;
use thiserror::Error as ThisError;

// Source files (kernels, layer images) live under Hyper's data root.
const HYPER_BASE: &str = "/srv/hyper";

#[derive(Debug, ThisError)]
pub enum Error {
    #[error(transparent)]
    Path(#[from] safe_dev::Error),
    #[error("source {path}: {source}")]
    Source { path: PathBuf, #[source] source: io::Error },
    #[error("source must be under {base}: {path}")]
    OutsideBase { base: &'static str, path: PathBuf },
    #[error("staging {src} -> {dest}: {source}")]
    Link { src: PathBuf, dest: PathBuf, #[source] source: io::Error },
    #[error("chown {path}: {source}")]
    Chown { path: PathBuf, #[source] source: nix::Error },
}

#[derive(Args)]
pub struct StageArgs {
    #[arg(long)]
    src: String,
    #[arg(long)]
    dest: JailPath,
    #[arg(long)]
    uid: u32,
    #[arg(long)]
    gid: u32,
}

#[derive(Serialize)]
#[serde(tag = "result", rename_all = "snake_case")]
pub enum StageOut {
    Staged,
}

pub struct Stage {
    args: StageArgs,
}

impl Stage {
    pub fn new(args: StageArgs) -> Self {
        Self { args }
    }
}

impl IsTool for Stage {
    type Args = StageArgs;
    type Output = StageOut;
    type RunT = Result<(), Error>;

    fn run_privileged(&self) -> Self::RunT {
        let src = std::fs::canonicalize(&self.args.src)
            .map_err(|source| Error::Source { path: PathBuf::from(&self.args.src), source })?;
        if !src.starts_with(HYPER_BASE) {
            return Err(Error::OutsideBase { base: HYPER_BASE, path: src });
        }
        let dest: &std::path::Path = self.args.dest.as_ref();

        // Hardlink is cheap; fall back to a copy across filesystems (EXDEV).
        match std::fs::hard_link(&src, dest) {
            Ok(()) => {}
            Err(e) if e.raw_os_error() == Some(libc::EXDEV) => {
                std::fs::copy(&src, dest)
                    .map_err(|source| Error::Link { src: src.clone(), dest: dest.to_path_buf(), source })?;
            }
            Err(source) => {
                return Err(Error::Link { src, dest: dest.to_path_buf(), source });
            }
        }

        chown(dest, Some(Uid::from_raw(self.args.uid)), Some(Gid::from_raw(self.args.gid)))
            .map_err(|source| Error::Chown { path: dest.to_path_buf(), source })?;
        Ok(())
    }

    fn parse(&self, res: Self::RunT) -> Result<StageOut, Box<dyn std::error::Error>> {
        res?;
        Ok(StageOut::Staged)
    }
}
