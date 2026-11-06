use super::IsTool;
use crate::tools::HyperDmName;
use clap::Args;
use hyperrs_fs::file::{self, Any, IsBlockDevice, OpenFlags, SafeFile};
use hyperrs_fs::path::{self, IsAbsolute, SafePath, StrictComponents};
use hyperrs_process::privilege::Root;
use serde::Serialize;
use std::io;
use std::path::PathBuf;
use thiserror::Error as ThisError;

#[derive(Debug, ThisError)]
pub enum BlockdevError {
    #[error("resolving {path}: {source}")]
    Resolve {
        path: PathBuf,
        #[source]
        source: io::Error,
    },
    #[error("device path: {0}")]
    Path(#[from] path::ValidationError),
    #[error("opening device: {0}")]
    Open(#[from] file::ValidationError),
    #[error("querying device size: {0}")]
    Size(#[source] nix::Error),
}

#[derive(Args)]
pub struct BlockdevArgs {
    /// Only the size query is permitted, so clap requires it.
    #[arg(long = "getsz", required = true)]
    getsz: bool,
    #[arg(value_parser = HyperDmName::from_device_path)]
    path: HyperDmName,
}

#[derive(Serialize)]
pub struct BlockdevOut {
    pub sectors: u64,
}

pub struct Blockdev {
    path: HyperDmName,
}

impl Blockdev {
    pub fn new(args: BlockdevArgs) -> Self {
        // clap required --getsz; the path was validated as a BlockDev.
        let BlockdevArgs { getsz: _, path } = args;
        Self { path }
    }
}

impl IsTool for Blockdev {
    type Args = BlockdevArgs;
    type Output = BlockdevOut;
    type RunT = Result<BlockdevOut, BlockdevError>;

    fn run_privileged(&self, _root: &Root<'_>) -> Self::RunT {
        let dev = self.path.path();
        let dev = dev.as_path();
        let real = std::fs::canonicalize(dev).map_err(|source| BlockdevError::Resolve {
            path: dev.to_path_buf(),
            source,
        })?;
        let safe: &SafePath<IsAbsolute, StrictComponents> = real.as_path().try_into()?;
        let file = SafeFile::<IsBlockDevice, Any, Any>::open(safe, OpenFlags::RDONLY)?;
        let sectors = file.sectors().map_err(BlockdevError::Size)?;
        Ok(BlockdevOut { sectors })
    }

    fn parse(&self, res: Self::RunT) -> Result<BlockdevOut, Box<dyn std::error::Error>> {
        Ok(res?)
    }
}
