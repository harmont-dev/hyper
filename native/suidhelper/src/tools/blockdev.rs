use super::IsTool;
use crate::safe_dev::BlockDev;
use clap::Args;
use serde::Serialize;
use std::io;
use std::num::ParseIntError;
use std::path::PathBuf;
use std::process::{Command, Output};
use thiserror::Error as ThisError;

#[derive(Debug, ThisError)]
pub enum Error {
    #[error("running blockdev: {0}")]
    Spawn(#[source] io::Error),
    #[error("blockdev failed: {0}")]
    Failed(String),
    #[error("parsing size: {0}")]
    ParseSize(#[from] ParseIntError),
}

#[derive(Args)]
pub struct BlockdevArgs {
    /// Only the size query is permitted, so clap requires it.
    #[arg(long = "getsz", required = true)]
    getsz: bool,
    path: BlockDev,
}

#[derive(Serialize)]
pub struct BlockdevOut {
    pub sectors: u64,
}

pub struct Blockdev {
    bin: PathBuf,
    path: PathBuf,
}

impl Blockdev {
    pub fn new(bin: PathBuf, args: BlockdevArgs) -> Self {
        // clap required --getsz; the path was validated as a BlockDev.
        let BlockdevArgs { getsz: _, path } = args;
        Self {
            bin,
            path: path.into(),
        }
    }
}

impl IsTool for Blockdev {
    type Args = BlockdevArgs;
    type Output = BlockdevOut;
    type RunT = io::Result<Output>;

    fn run_privileged(&self) -> Self::RunT {
        Command::new(&self.bin)
            .arg("--getsz")
            .arg(&self.path)
            .env_clear()
            .output()
    }

    fn parse(&self, res: Self::RunT) -> Result<BlockdevOut, Box<dyn std::error::Error>> {
        let out = res.map_err(Error::Spawn)?;
        if !out.status.success() {
            return Err(
                Error::Failed(String::from_utf8_lossy(&out.stderr).trim().to_string()).into(),
            );
        }

        let sectors = String::from_utf8_lossy(&out.stdout)
            .trim()
            .parse::<u64>()
            .map_err(Error::ParseSize)?;
        Ok(BlockdevOut { sectors })
    }
}
