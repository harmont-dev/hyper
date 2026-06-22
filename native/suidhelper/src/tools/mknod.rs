use super::IsTool;
use crate::safe_dev::{self, JailPath};
use clap::Args;
use nix::sys::stat::{mknod, Mode, SFlag};
use nix::unistd::{chown, Gid, Uid};
use serde::Serialize;
use std::path::PathBuf;
use thiserror::Error as ThisError;

#[derive(Debug, ThisError)]
pub enum Error {
    #[error(transparent)]
    Path(#[from] safe_dev::Error),
    #[error("mknod {path}: {source}")]
    Mknod { path: PathBuf, #[source] source: nix::Error },
    #[error("chown {path}: {source}")]
    Chown { path: PathBuf, #[source] source: nix::Error },
}

#[derive(Args)]
pub struct MknodArgs {
    #[arg(long)]
    dest: JailPath,
    #[arg(long)]
    major: u32,
    #[arg(long)]
    minor: u32,
    #[arg(long)]
    uid: u32,
    #[arg(long)]
    gid: u32,
}

#[derive(Serialize)]
#[serde(tag = "result", rename_all = "snake_case")]
pub enum MknodOut {
    Made,
}

pub struct Mknod {
    args: MknodArgs,
}

impl Mknod {
    pub fn new(args: MknodArgs) -> Self {
        Self { args }
    }
}

impl IsTool for Mknod {
    type Args = MknodArgs;
    type Output = MknodOut;
    type RunT = Result<(), Error>;

    fn run_privileged(&self) -> Self::RunT {
        let path: &std::path::Path = self.args.dest.as_ref();
        let dev = nix::sys::stat::makedev(self.args.major as u64, self.args.minor as u64);
        mknod(path, SFlag::S_IFBLK, Mode::from_bits_truncate(0o600), dev)
            .map_err(|source| Error::Mknod { path: path.to_path_buf(), source })?;
        chown(path, Some(Uid::from_raw(self.args.uid)), Some(Gid::from_raw(self.args.gid)))
            .map_err(|source| Error::Chown { path: path.to_path_buf(), source })?;
        Ok(())
    }

    fn parse(&self, res: Self::RunT) -> Result<MknodOut, Box<dyn std::error::Error>> {
        res?;
        Ok(MknodOut::Made)
    }
}
