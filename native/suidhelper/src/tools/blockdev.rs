use super::IsTool;
use crate::fs::file::{self, Any, IsBlockDevice, OpenFlags, SafeFile};
use crate::fs::path::{self, IsAbsolute, SafePath, StrictComponents};
use crate::process::privilege::Root;
use crate::util::safe_dev::BlockDev;
use clap::Args;
use serde::Serialize;
use std::io;
use std::path::PathBuf;
use thiserror::Error as ThisError;

#[derive(Debug, ThisError)]
pub enum Error {
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
    path: BlockDev,
}

#[derive(Serialize)]
pub struct BlockdevOut {
    pub sectors: u64,
}

pub struct Blockdev {
    path: BlockDev,
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
    type RunT = Result<BlockdevOut, Error>;

    fn run_privileged(&self, _root: &Root<'_>) -> Self::RunT {
        let dev: &std::path::Path = self.path.as_ref();
        let real = std::fs::canonicalize(dev).map_err(|source| Error::Resolve {
            path: dev.to_path_buf(),
            source,
        })?;
        let safe: &SafePath<IsAbsolute, StrictComponents> = real.as_path().try_into()?;
        let file = SafeFile::<IsBlockDevice, Any, Any>::open(safe, OpenFlags::RDONLY)?;
        let sectors = file.sectors().map_err(Error::Size)?;
        Ok(BlockdevOut { sectors })
    }

    fn parse(&self, res: Self::RunT) -> Result<BlockdevOut, Box<dyn std::error::Error>> {
        Ok(res?)
    }
}
